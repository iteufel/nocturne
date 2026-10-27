import Foundation
import NocturneKit

struct AgentRPCError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
    var unsupported: Bool { code == -32601 || message.localizedCaseInsensitiveContains("not supported") || message.localizedCaseInsensitiveContains("unsupported") }
}

/// Bounded newline JSON-RPC over local stdio. No listening port, shell interpolation, or auth copying.
@MainActor
final class AgentRPC {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onRequest: ((Any, String, [String: Any]) -> Void)?
    var onExit: ((Error) -> Void)?
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let writes = DispatchQueue(label: "nocturne.chat.stdin")
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private(set) var closed = false

    init(configuration: ChatAgentConfiguration, directory: URL, chatGPTOnly: Bool = false) throws {
        try configuration.validate()
        guard let executable = configuration.executableURL else { throw NocturneError.remote(configuration.descriptor.detail) }
        process.executableURL = executable; process.arguments = configuration.arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = ChatAgentConfiguration.searchPath
        if configuration.transport == .codex {
            // The embedding app identifies itself in initialize; never inherit a host IDE's override.
            environment.removeValue(forKey: "CODEX_INTERNAL_ORIGINATOR_OVERRIDE")
        }
        if chatGPTOnly {
            for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "AZURE_OPENAI_API_KEY"] { environment.removeValue(forKey: key) }
        }
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        // Drain stderr so a verbose provider cannot deadlock. It may contain private diagnostic data.
        errors.fileHandleForReading.readabilityHandler = { handle in if handle.availableData.isEmpty { handle.readabilityHandler = nil } }
        do { try process.run() } catch { close(); throw error }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
    }
    func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 45) async throws -> [String: Any] {
        guard !closed, pending.count < 16 else { throw NocturneError.disconnected }
        nextID += 1; let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                    self?.finish(id, .failure(NocturneError.remote("The chat provider did not respond. Check its installation and sign-in on your Mac.")))
                }
                send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) } }
    }
    func notify(_ method: String, _ params: [String: Any] = [:]) { send(["jsonrpc": "2.0", "method": method, "params": params]) }
    func respond(_ id: Any, result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
    func reject(_ id: Any, message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": message]]) }

    private func send(_ object: [String: Any]) {
        guard !closed else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            let handle = input.fileHandleForWriting
            writes.async { [weak self] in
                do { try handle.write(contentsOf: data) }
                catch { DispatchQueue.main.async { self?.close(error: NocturneError.disconnected) } }
            }
        } catch { close(error: error) }
    }
    private func receive(_ data: Data) {
        guard !closed else { return }
        guard !data.isEmpty else {
            close(error: NocturneError.remote("The chat provider stopped. Check its installation and sign-in on your Mac, then refresh.")); return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard line.count <= 32 * 1_048_576 else { close(error: NocturneError.invalidFrame); return }
            if line.isEmpty { continue }
            guard let raw = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                close(error: NocturneError.remote("The provider sent invalid JSON. Check that its command starts a stdio agent.")); return
            }
            let object = raw
            if let method = object["method"] as? String {
                let params = object["params"] as? [String: Any] ?? [:]
                if let id = object["id"] { onRequest?(id, method, params) }
                else { onNotification?(method, params) }
            } else if let id = object["id"] as? Int {
                if let error = object["error"] as? [String: Any] {
                    finish(id, .failure(AgentRPCError(code: error["code"] as? Int ?? -1, message: error["message"] as? String ?? "The provider returned an error.")))
                } else { finish(id, .success(object["result"] as? [String: Any] ?? [:])) }
            }
        }
        if buffer.count > 32 * 1_048_576 { close(error: NocturneError.invalidFrame) }
    }
    private func finish(_ id: Int, _ result: Result<[String: Any], Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    func close(error: Error = NocturneError.disconnected) {
        guard !closed else { return }; closed = true
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        buffer.removeAll()
        let active = Array(pending.keys); active.forEach { finish($0, .failure(error)) }
        onExit?(error); onExit = nil; onNotification = nil; onRequest = nil
    }
}
