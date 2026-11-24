import Combine
import Foundation

/// Optional protocol-v4 extension; never send these operations to an older host.
public enum MacUnlock {
    public static let capability = "mac-unlock-v1"
    public static let maximumPasswordBytes = 4_096
}

public struct MacLockStatus: Codable, Equatable {
    public enum State: String, Codable { case locked, unlocked, unavailable }
    public let state: State
    public let user: String
    public init(state: State, user: String) { self.state = state; self.user = user }
}

/// One request's credential. Diagnostic descriptions and reflection are redacted.
/// Clearing drops references; Swift/JSON/TLS buffers cannot promise secure erasure.
public final class MacUnlockPassword: Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var value: String?
    private let lock = NSLock()
    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= MacUnlock.maximumPasswordBytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x2028 || $0.value == 0x2029 }) else {
            throw NocturneError.remote("Enter your Mac login password without line breaks.")
        }
        self.value = value
    }
    public func withValue<T>(_ body: (String) throws -> T) throws -> T {
        lock.lock(); let snapshot = value; lock.unlock()
        guard let value = snapshot else { throw NocturneError.invalidFrame }
        return try body(value)
    }
    public func clear() { lock.lock(); value = nil; lock.unlock() }
    public var description: String { "<Mac unlock password: redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public convenience init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        try withValue { value in var container = encoder.singleValueContainer(); try container.encode(value) }
    }
}

/// The prompt belongs to one authenticated connection, including across host switches.
@MainActor
public final class MacUnlockModel: ObservableObject {
    @Published public var password = ""
    @Published public private(set) var isPresented = false
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var status: MacLockStatus?
    @Published public private(set) var error: String?
    public let connection: WorkspaceConnection
    private var target: UUID?
    private var pendingID: String?
    private var attempt: Task<Void, Never>?
    private var observer: AnyCancellable?
    private var observedLock = false
    private var stateID = UUID()
    public var supported: Bool { connection.state == .connected && connection.capabilities.contains(MacUnlock.capability) }
    public init(connection: WorkspaceConnection) {
        self.connection = connection
        observer = connection.$state.sink { [weak self] state in
            if state != .connected { Task { @MainActor [weak self] in
                guard let self, self.connection.state != .connected else { return }; self.reset()
            } }
        }
    }
    public func refresh() async {
        guard supported else { reset(); return }
        guard !isSubmitting else { return }
        let epoch = connection.generation, revision = stateID
        do {
            let reply = try await connection.request(Packet(.macLockStatus), timeout: 5)
            guard !isSubmitting, stateID == revision, connection.state == .connected, connection.generation == epoch,
                  let status = reply.macLockStatus else { return }
            self.status = status
            if status.state == .locked {
                if !observedLock { observedLock = true; present() }
            } else {
                observedLock = false
                if isPresented { dismiss() }
            }
        } catch { /* A status poll never retries a password or interrupts the stream. */ }
    }
    public func present() {
        guard !isSubmitting, supported, status?.state == .locked else { return }
        stateID = UUID(); password = ""; error = nil; target = connection.generation; isPresented = true
    }
    public func submit() {
        guard !isSubmitting else { return }
        guard isPresented, let target, supported, connection.generation == target else { reset(); return }
        let credential: MacUnlockPassword
        do { credential = try MacUnlockPassword(password) }
        catch { self.password = ""; self.error = NocturneLocalization.message(error.localizedDescription); return }
        password = ""
        stateID = UUID()
        var packet = Packet(.macUnlock); packet.unlockPassword = credential
        let id = packet.id; pendingID = id; isSubmitting = true; error = nil
        attempt = Task { [weak self] in
            defer { credential.clear() }
            guard let self else { return }
            do {
                let reply = try await self.connection.request(packet, timeout: 18)
                guard !Task.isCancelled, self.pendingID == id, self.connection.generation == target else { return }
                guard reply.macLockStatus?.state == .unlocked else { throw NocturneError.invalidFrame }
                self.status = reply.macLockStatus; self.observedLock = false; self.finish()
            } catch {
                guard !Task.isCancelled, self.pendingID == id, self.connection.generation == target else { return }
                var cancel = Packet(.macUnlockCancel); cancel.sessionID = id
                _ = try? await self.connection.request(cancel, timeout: 3)
                guard !Task.isCancelled, self.pendingID == id, self.connection.generation == target else { return }
                self.isSubmitting = false; self.pendingID = nil; self.attempt = nil
                self.error = NocturneLocalization.message(error.localizedDescription)
            }
        }
    }
    public func dismiss() {
        password = ""
        if let id = pendingID, connection.state == .connected, connection.generation == target {
            var cancel = Packet(.macUnlockCancel); cancel.sessionID = id
            let epoch = connection.generation
            Task {
                guard connection.state == .connected, connection.generation == epoch else { return }
                _ = try? await connection.request(cancel, timeout: 3)
            }
        }
        attempt?.cancel(); finish()
    }
    private func finish() {
        stateID = UUID(); password = ""; pendingID = nil; target = nil; attempt = nil; isSubmitting = false; isPresented = false
    }
    private func reset() { dismiss(); status = nil; observedLock = false; error = nil }
}
