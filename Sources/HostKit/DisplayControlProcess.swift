import AppKit
import Foundation
import NocturneKit
import Darwin

struct DisplayCommand: Codable {
    var id = UUID().uuidString
    let operation: String
    var size: StreamDisplaySize?
    var disable = false
}
private struct DisplayReply: Codable {
    let id: String
    var error: String?
    var displayID: UInt32?
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
                    case "start": reply.displayID = try await self.driver.start()
                    case "apply":
                        guard let size = command.size, size.isValid else { throw NocturneError.invalidFrame }
                        reply.displayID = try await self.driver.apply(size, disablePhysicalDisplays: command.disable)
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

protocol DisplayControlChannel: AnyObject {
    var isRunning: Bool { get }
    func send(_ command: DisplayCommand, timeout: TimeInterval, completion: @escaping (Result<UInt32?, Error>) -> Void)
    func stop()
}

/// Replies and deadlines are delivered on the pipe/background queues. No display
/// command may block the server's main actor while WindowServer is responding.
final class DisplayProcessChannel: DisplayControlChannel, @unchecked Sendable {
    let process = Process()
    var isRunning: Bool { process.isRunning }
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var pending: [String: (Result<UInt32?, Error>) -> Void] = [:]
    private var closed = false
    init(executable: URL? = Bundle.main.executableURL, arguments: [String] = ["--nocturne-display-worker"]) throws {
        guard let executable else { throw NocturneError.disconnected }
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let reader = DisplayLineReader { [weak self] line in
            guard let self else { return }
            guard let line, let reply = try? JSONDecoder().decode(DisplayReply.self, from: line) else { self.fail(); return }
            self.lock.lock(); let callback = self.pending.removeValue(forKey: reply.id); self.lock.unlock()
            callback?(reply.error.map { .failure(NocturneError.remote($0)) } ?? .success(reply.displayID))
        }
        output.fileHandleForReading.readabilityHandler = { handle in reader.receive(handle.availableData) }
        process.terminationHandler = { [weak self] _ in self?.fail() }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        // Closing the unused pipe ends makes EOF reliable when either process dies.
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
    }
    func send(_ command: DisplayCommand, timeout: TimeInterval, completion: @escaping (Result<UInt32?, Error>) -> Void) {
        lock.lock()
        guard !closed else { lock.unlock(); completion(.failure(NocturneError.disconnected)); return }
        pending[command.id] = completion; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let callback = self.pending.removeValue(forKey: command.id); self.lock.unlock()
            callback?(.failure(NocturneError.timeout))
        }
        do { try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(command) + Data([10])) }
        catch {
            fail()
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
    private var channel: DisplayControlChannel?
    private var recoveringChannels: [DisplayControlChannel] = []
    private var restoration: Task<Void, Never>?
    private var restorationID: UUID?
    private var revision = UUID()
    private let makeChannel: () throws -> DisplayControlChannel
    private let restoreTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    init(makeChannel: @escaping () throws -> DisplayControlChannel = { try DisplayProcessChannel() },
         restoreTimeout: TimeInterval = 8, requestTimeout: TimeInterval = 12) {
        self.makeChannel = makeChannel; self.restoreTimeout = restoreTimeout; self.requestTimeout = requestTimeout
    }
    @discardableResult func start() async throws -> UInt32 {
        return try await requestDisplay(.init(operation: "start"))
    }
    @discardableResult func apply(_ size: StreamDisplaySize, disablePhysicalDisplays: Bool) async throws -> UInt32 {
        return try await requestDisplay(.init(operation: "apply", size: size, disable: disablePhysicalDisplays))
    }
    private func requestDisplay(_ command: DisplayCommand) async throws -> UInt32 {
        let epoch = revision
        await restoration?.value
        // Only transport failures warrant a fresh worker. Native configuration
        // errors still propagate; each request can replace its worker only once.
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard revision == epoch else { throw NocturneError.disconnected }
            if channel == nil { channel = try makeChannel() }
            guard let channel else { throw NocturneError.disconnected }
            recoveringChannels.removeAll { !$0.isRunning }
            var request = command
            // A detached worker still owns its original layout. Let it restore
            // physical monitors without a new worker disabling them underneath it.
            if !recoveringChannels.isEmpty { request.disable = false }
            do {
                let display = try await send(request, to: channel, timeout: requestTimeout)
                try Task.checkCancellation()
                guard revision == epoch else { throw NocturneError.disconnected }
                guard let display, display != 0 else { throw NocturneError.invalidFrame }
                return display
            } catch {
                guard revision == epoch else { throw NocturneError.disconnected }
                guard let failure = error as? NocturneError,
                      failure == .disconnected || failure == .timeout || failure == .invalidFrame else { throw error }
                retire(channel)
                if attempt == 1 { throw error }
            }
        }
        throw NocturneError.disconnected
    }
    func restore() throws {
        revision = UUID()
        guard restoration == nil else { return }
        guard let channel else { return }
        let id = UUID(); restorationID = id
        restoration = Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.send(.init(operation: "restore"), to: channel, timeout: self.restoreTimeout) }
            catch {
                // EOF leaves physical-display recovery with the old worker. The
                // next stream creates a new capture target without a server restart.
                if self.channel === channel { self.retire(channel) }
            }
            if self.restorationID == id { self.restoration = nil; self.restorationID = nil }
        }
    }
    func stop() throws {
        revision = UUID()
        restoration?.cancel(); restoration = nil; restorationID = nil
        if let channel { retire(channel) }
    }
    private func retire(_ channel: DisplayControlChannel) {
        if self.channel === channel { self.channel = nil }
        channel.stop() // Request restoration on EOF; never kill the recovery worker.
        recoveringChannels.removeAll { !$0.isRunning }
        if channel.isRunning { recoveringChannels.append(channel) }
    }
    private func send(_ command: DisplayCommand, to channel: DisplayControlChannel, timeout: TimeInterval) async throws -> UInt32? {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            channel.send(command, timeout: timeout) { continuation.resume(with: $0) }
        }
    }
}
