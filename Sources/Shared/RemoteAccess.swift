import Foundation
import NocturneRemote

/// Public routing information. Workspace secrets and device proofs stay inside TLS.
public struct RemoteAccess: Codable, Equatable, Sendable {
    public let brokerURL: String
    public let endpointID: String
    public init(brokerURL: String, endpointID: String) throws {
        let broker = try Self.validateBroker(brokerURL)
        guard endpointID.count == 64, endpointID.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw NocturneError.invalidInvitation }
        self.brokerURL = broker; self.endpointID = endpointID.lowercased()
    }
    public static func validateBroker(_ value: String) throws -> String {
        guard let url = URLComponents(string: value), let host = url.host, !host.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port == nil || (1...65535).contains(url.port!) else {
            throw NocturneError.remote("Enter the broker’s HTTPS address, such as https://broker.example.com.")
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private enum CodingKeys: String, CodingKey { case brokerURL, endpointID }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(brokerURL: fields.decode(String.self, forKey: .brokerURL), endpointID: fields.decode(String.self, forKey: .endpointID))
    }
}

/// Owns native sockets; a media connection may retain the same tunnel as its workspace.
/// The lock serializes host-queue authorization/revocation with UI-driven shutdown.
public final class RemoteTunnel: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { stop() }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let handle { nocturne_remote_stop(handle); self.handle = nil }
    }
    public var endpointID: String {
        lock.lock(); defer { lock.unlock() }
        guard let handle, let text = nocturne_remote_id(handle) else { return "" }
        defer { nocturne_remote_string_free(text) }
        return String(cString: text)
    }
    public var workspacePort: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return handle.map { nocturne_remote_port($0) } ?? 0
    }
    public var route: String? {
        lock.lock(); defer { lock.unlock() }
        switch handle.map({ nocturne_remote_route($0) }) {
        case 1: return L("Peer to peer")
        case 2: return L("Encrypted relay")
        default: return nil
        }
    }
    public func authorize(sourcePort: UInt16, deviceID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw NocturneError.disconnected }
        guard nocturne_remote_authorize(handle, sourcePort, deviceID) >= 0 else { throw NocturneError.permissionDenied }
    }
    public func revoke(deviceID: String) {
        lock.lock(); defer { lock.unlock() }
        if let handle { nocturne_remote_revoke(handle, deviceID) }
    }
    public static func host(brokerURL: String, endpointKey: Data, port: UInt16 = WorkspaceProtocol.port) async throws -> RemoteTunnel {
        let broker = try RemoteAccess.validateBroker(brokerURL)
        guard endpointKey.count == 32 else { throw NocturneError.invalidInvitation }
        return try await create {
            var error: UnsafeMutablePointer<CChar>?
            let handle = endpointKey.withUnsafeBytes { bytes in nocturne_remote_host(broker, bytes.bindMemory(to: UInt8.self).baseAddress!, port, &error) }
            return try checked(handle, error)
        }
    }
    public static func connect(_ access: RemoteAccess, streaming: Bool = true) async throws -> RemoteTunnel {
        try await create {
            var error: UnsafeMutablePointer<CChar>?
            let handle = nocturne_remote_client(access.brokerURL, access.endpointID, streaming, &error)
            return try checked(handle, error)
        }
    }
    private static func checked(_ handle: OpaquePointer?, _ error: UnsafeMutablePointer<CChar>?) throws -> RemoteTunnel {
        defer { if let error { nocturne_remote_string_free(error) } }
        guard let handle else { throw NocturneError.remote(error.map { String(cString: $0) } ?? "Remote connection failed.") }
        return RemoteTunnel(handle)
    }
    private static func create(_ action: @escaping @Sendable () throws -> RemoteTunnel) async throws -> RemoteTunnel {
        try Task.checkCancellation()
        let tunnel = try await Task.detached(priority: .userInitiated, operation: action).value
        // A cancelled/superseded attempt must release the sockets it just created.
        do { try Task.checkCancellation(); return tunnel }
        catch { tunnel.stop(); throw error }
    }
}
