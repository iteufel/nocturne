import AppKit
import Foundation
import NocturneKit
import Darwin

private struct DisplayCommand: Codable {
    var id = UUID().uuidString
    let operation: String
    var size: StreamDisplaySize?
    var disable = false
}
private struct DisplayReply: Codable {
    let id: String
    var error: String?
}

/// Runs the display owner inside the same signed app executable, with no second
/// application or service to install. The pipe is also its parent-liveness signal.
/// On EOF it restores physical displays BEFORE releasing the virtual framebuffer.
@MainActor
public enum DisplayControlProcess {
    public static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--nocturne-display-worker") else { return false }
        signal(SIGPIPE, SIG_IGN)
        ProcessInfo.processInfo.processName = "Nocturne Display Recovery"
        NSApplication.shared.setActivationPolicy(.prohibited)
        let worker = DisplayWorker()
        worker.listen()
        withExtendedLifetime(worker) { NSApp.run() }
        return true
    }
}

@MainActor
private final class DisplayWorker {
    let driver = NativeStreamingDisplayDriver()
    private var shuttingDown = false
    func listen() {
        let reader = DisplayLineReader { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                guard let line else { await self.shutdown(); return }
                guard !self.shuttingDown, let command = try? JSONDecoder().decode(DisplayCommand.self, from: line) else { return }
                var reply = DisplayReply(id: command.id)
                do {
                    switch command.operation {
                    case "start": try await self.driver.start()
                    case "apply":
                        guard let size = command.size, size.isValid else { throw NocturneError.invalidFrame }
                        try await self.driver.apply(size, disablePhysicalDisplays: command.disable)
                    case "restore": try await self.restore()
                    default: throw NocturneError.invalidFrame
                    }
                } catch { reply.error = error.localizedDescription }
                guard !self.shuttingDown, let data = try? JSONEncoder().encode(reply) else { return }
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
        }
        FileHandle.standardInput.readabilityHandler = { handle in reader.receive(handle.availableData) }
    }
    private func restore() async throws {
        var failure: Error = NocturneError.timeout
        for _ in 0..<30 {
            do { try driver.restore(); return } catch { failure = error }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw failure
    }
    private func shutdown() async {
        guard !shuttingDown else { return }; shuttingDown = true
        FileHandle.standardInput.readabilityHandler = nil
        // Continue recovery if a monitor takes time to wake. Never kill the last
        // virtual framebuffer while a physical display still needs restoration.
        while true {
            do { try driver.stop(); exit(0) }
            catch { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
    }
}

private final class DisplayLineReader: @unchecked Sendable {
    private var buffer = Data()
    private var ended = false
    private let receiveLine: (Data?) -> Void
    init(_ receive: @escaping (Data?) -> Void) { receiveLine = receive }
    func receive(_ data: Data) {
        guard !ended else { return }
        guard !data.isEmpty, buffer.count + data.count <= 65_536 else { ended = true; receiveLine(nil); return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end); receiveLine(line)
        }
    }
}

/// Reply callbacks run on the pipe's queue, so Stop/restore can wait for the
/// worker without depending on the app's main run loop to deliver the reply.
private final class DisplayProcessChannel: @unchecked Sendable {
    let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var pending: [String: (Result<Void, Error>) -> Void] = [:]
    private var closed = false
    init() throws {
        guard let executable = Bundle.main.executableURL else { throw NocturneError.disconnected }
        process.executableURL = executable; process.arguments = ["--nocturne-display-worker"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let reader = DisplayLineReader { [weak self] line in
            guard let self else { return }
            guard let line, let reply = try? JSONDecoder().decode(DisplayReply.self, from: line) else { self.fail(); return }
            self.lock.lock(); let callback = self.pending.removeValue(forKey: reply.id); self.lock.unlock()
            callback?(reply.error.map { .failure(NocturneError.remote($0)) } ?? .success(()))
        }
        output.fileHandleForReading.readabilityHandler = { handle in reader.receive(handle.availableData) }
        process.terminationHandler = { [weak self] _ in self?.fail() }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        // Closing the unused pipe ends makes EOF reliable when either process dies.
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
    }
    func send(_ command: DisplayCommand, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        guard !closed else { lock.unlock(); completion(.failure(NocturneError.disconnected)); return }
        pending[command.id] = completion; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let callback = self.pending.removeValue(forKey: command.id); self.lock.unlock()
            callback?(.failure(NocturneError.timeout))
        }
        do { try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(command) + Data([10])) }
        catch {
            lock.lock(); let callback = pending.removeValue(forKey: command.id); lock.unlock(); callback?(.failure(error))
        }
    }
    func stop() {
        try? input.fileHandleForWriting.close() // EOF requests restore, then exit.
        fail()
    }
    private func fail() {
        output.fileHandleForReading.readabilityHandler = nil
        lock.lock(); closed = true; let callbacks = pending.values; pending.removeAll(); lock.unlock()
        callbacks.forEach { $0(.failure(NocturneError.disconnected)) }
    }
    deinit { try? input.fileHandleForWriting.close(); output.fileHandleForReading.readabilityHandler = nil }
}

@MainActor
final class ProcessStreamingDisplayDriver: StreamingDisplayDriver {
    private var channel: DisplayProcessChannel?
    func start() async throws {
        if channel == nil { channel = try DisplayProcessChannel() }
        try await request(.init(operation: "start"))
    }
    func apply(_ size: StreamDisplaySize, disablePhysicalDisplays: Bool) async throws {
        guard channel != nil else { throw NocturneError.disconnected }
        try await request(.init(operation: "apply", size: size, disable: disablePhysicalDisplays))
    }
    private func request(_ command: DisplayCommand) async throws {
        guard let channel else { throw NocturneError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.send(command) { continuation.resume(with: $0) }
        }
    }
    func restore() throws {
        guard let channel else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let result = DisplaySynchronousResult()
        channel.send(.init(operation: "restore")) { value in result.value = value; semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 8) == .success else {
            channel.stop(); self.channel = nil
            throw NocturneError.remote("The display controller is recovering your Mac’s displays. Restart the server before streaming again.")
        }
        try result.value?.get()
    }
    func stop() throws { channel?.stop(); channel = nil }
}

private final class DisplaySynchronousResult: @unchecked Sendable {
    // Written before the semaphore signal, read only after the wait succeeds.
    var value: Result<Void, Error>?
}
