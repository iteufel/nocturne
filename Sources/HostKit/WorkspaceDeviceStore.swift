import Foundation
import NocturneKit

public struct WorkspaceDevice: Codable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var lastSeen: Date
}

/// Public identity metadata only. Pairing invitations are single-use and expire in memory.
/// The old transport PSK cannot register or reconnect a removed identity by itself.
public final class WorkspaceDeviceStore {
    private struct Snapshot: Codable { var devices: [WorkspaceDevice]; var removing: [String: String] }
    private let url: URL
    private let lock = NSLock()
    private var records: [String: WorkspaceDevice]
    private var streaming: Set<String> = []
    private var blocked: [String: String] = [:]
    private var invitation: (token: Data, expires: Date)?

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
            records = Dictionary(saved.devices.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }); blocked = saved.removing
        } else { records = [:] }
    }
    public var devices: [WorkspaceDevice] {
        lock.lock(); defer { lock.unlock() }; return Array(records.values)
    }
    public var pendingRemovals: [String: String] {
        lock.lock(); defer { lock.unlock() }; return blocked
    }
    public func createInvitation() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let token = try SecureStore.randomKey()
        invitation = (token, Date().addingTimeInterval(300)); return token
    }
    public func cancelInvitation() {
        lock.lock(); defer { lock.unlock() }; invitation = nil
    }
    public func updateStreamingIdentities(_ fingerprints: Set<String>) {
        lock.lock(); defer { lock.unlock() }; streaming = fingerprints
    }
    public func authorize(id: String, name: String, token: Data?) throws -> WorkspaceDevice {
        lock.lock(); defer { lock.unlock() }
        guard blocked[id] == nil else { throw NocturneError.remote("This device is being removed.") }
        let enrolling = token != nil && token == invitation?.token && (invitation?.expires ?? .distantPast) > Date()
        guard records[id] != nil || streaming.contains(id) || enrolling else {
            throw NocturneError.remote("This device is no longer paired. Scan a new code in Nocturne Server → Devices.")
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf8.count <= 128,
              !cleanName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw NocturneError.invalidFrame }
        let device = WorkspaceDevice(id: id, name: cleanName, lastSeen: Date())
        var updated = records; updated[id] = device
        try save(updated, blocked: blocked); records = updated
        if enrolling { invitation = nil }
        return device
    }
    /// Block first and keep the block if persistence or engine revocation fails. Retrying is safe.
    public func remove(_ id: String, name: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        blocked[id] = name ?? records[id]?.name ?? "Device"; streaming.remove(id)
        invitation = nil
        try save(records, blocked: blocked)
        // An unconsumed link copied before removal must not authorize the device again.
        invitation = nil
    }
    public func finishRemoval(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var updated = records; updated.removeValue(forKey: id)
        var remaining = blocked; remaining.removeValue(forKey: id)
        try save(updated, blocked: remaining); records = updated; blocked = remaining
    }
    public func reset() throws {
        lock.lock(); defer { lock.unlock() }
        try save([:], blocked: [:]); records = [:]; streaming = []; blocked = [:]; invitation = nil
    }
    private func save(_ records: [String: WorkspaceDevice], blocked: [String: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Snapshot(devices: records.values.sorted { $0.id < $1.id }, removing: blocked)).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
