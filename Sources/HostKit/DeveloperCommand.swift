import Foundation
import NocturneKit

struct DeveloperCommandResult {
    let data: Data
    let error: String
    let code: Int32
    let truncated: Bool
    var text: String { String(decoding: data, as: UTF8.self) }
}

/// Literal argv, bounded output and finite lifetime. Never exposes command lines or credentials.
final class DeveloperCommand: @unchecked Sendable {
    typealias Run = @Sendable (String, [String], URL, Data?) async throws -> DeveloperCommandResult
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    static let run: Run = { command, arguments, directory, input in
        let job = DeveloperCommand()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { completion.resume(returning: try job.execute(command, arguments, directory, input)) }
                    catch { completion.resume(throwing: error) }
                }
            }
        } onCancel: { job.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if let running, running.isRunning { running.terminate() }
        if let running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if running.isRunning { kill(running.processIdentifier, SIGKILL) } }
        }
    }
    private func execute(_ command: String, _ arguments: [String], _ directory: URL, _ input: Data?) throws -> DeveloperCommandResult {
        let config = ChatAgentConfiguration(name: command, executable: command)
        guard let executable = config.executableURL else {
            throw NocturneError.remote("Install \(command) and sign in on your Mac, then try again.")
        }
        let child = Process(), stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        child.executableURL = executable; child.arguments = arguments; child.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = ChatAgentConfiguration.searchPath
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_PAGER"] = "cat"; environment["PAGER"] = "cat"
        environment["AZURE_CORE_COLLECT_TELEMETRY"] = "0"; environment["AZURE_EXTENSION_USE_DYNAMIC_INSTALL"] = "no"
        child.environment = environment; child.standardOutput = stdout; child.standardError = stderr; child.standardInput = stdin
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close(); try? stdin.fileHandleForReading.close()
        let group = DispatchGroup(), output = CommandBuffer(limit: 4 * 1_048_576), errors = CommandBuffer(limit: 16_384)
        for (handle, buffer) in [(stdout.fileHandleForReading, output), (stderr.fileHandleForReading, errors)] {
            group.enter()
            DispatchQueue.global().async {
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }; buffer.append(data)
                }
                group.leave()
            }
        }
        DispatchQueue.global().async {
            if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
            try? stdin.fileHandleForWriting.close()
        }
        let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: deadline)
        let killDeadline = DispatchWorkItem { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 48, execute: killDeadline)
        child.waitUntilExit(); deadline.cancel(); killDeadline.cancel(); group.wait()
        lock.lock(); let wasCancelled = cancelled; process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        return DeveloperCommandResult(data: output.data, error: Self.sanitize(String(decoding: errors.data, as: UTF8.self)),
            code: child.terminationStatus, truncated: output.truncated)
    }
    static func sanitize(_ raw: String) -> String {
        var text = raw
        for pattern in [#"(?i)Bearer\s+[^\s\"<>]+"#, #"eyJ[A-Za-z0-9_.-]+"#, #"(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]+"#, #"https?://[^/@\s]+:[^/@\s]+@"#] {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))
    }
}

private final class CommandBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private(set) var data = Data()
    private(set) var truncated = false
    init(limit: Int) { self.limit = limit }
    func append(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        let count = min(max(0, limit - data.count), value.count)
        data.append(value.prefix(count)); if count < value.count { truncated = true }
    }
}
