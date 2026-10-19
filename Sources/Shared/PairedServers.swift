import Foundation

/// A Mac this device has enrolled with. Its identity is the pairing key, never the name or address.
public struct PairedServer: Codable, Equatable, Identifiable {
    public var invitation: PairingInvitation
    /// The video host approved through this Mac's QR pairing, if streaming was linked.
    public var streamingHostID: String?
    public var id: String { WorkspaceIdentity.fingerprint(invitation.secret) }
    public var name: String { invitation.name }
    public init(invitation: PairingInvitation, streamingHostID: String? = nil) {
        self.invitation = invitation; self.streamingHostID = streamingHostID
    }
}

/// Every paired Mac, in pairing order, with one active Mac for the terminal, files, apps, and display control.
/// The list holds pairing keys, so it is saved only in Keychain.
public struct PairedServerList: Codable, Equatable {
    public static let keychainAccount = "paired-servers"
    /// The single-Mac pairing saved by earlier versions.
    public static let legacyKeychainAccount = "server"
    public private(set) var servers: [PairedServer] = []
    public private(set) var activeID: String?
    public var active: PairedServer? { activeID.flatMap { self[$0] } }
    public init() {}
    public init(legacy: PairingInvitation?, streamingHostID: String?) {
        if let legacy { pair(legacy); servers[0].streamingHostID = streamingHostID }
    }
    public subscript(id: String) -> PairedServer? { servers.first { $0.id == id } }
    public func server(linkedTo streamingHostID: String) -> PairedServer? {
        servers.first { $0.streamingHostID == streamingHostID }
    }
    /// Saves a newly scanned pairing, or refreshes a re-scanned Mac in place, and makes it active.
    public mutating func pair(_ invitation: PairingInvitation) {
        let server = PairedServer(invitation: invitation)
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index].invitation = invitation }
        else { servers.append(server) }
        activeID = server.id
    }
    /// Records a newly authenticated address. Unknown Macs are ignored.
    public mutating func update(_ invitation: PairingInvitation) {
        let id = WorkspaceIdentity.fingerprint(invitation.secret)
        if let index = servers.firstIndex(where: { $0.id == id }) { servers[index].invitation = invitation }
    }
    public mutating func activate(_ id: String) {
        if self[id] != nil { activeID = id }
    }
    /// Links a video host to one Mac. Older pairings linked to the same host are stale
    /// (the Mac reset its pairing key), so they are removed and returned for cleanup.
    @discardableResult
    public mutating func link(streamingHostID: String, to id: String) -> [PairedServer] {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return [] }
        servers[index].streamingHostID = streamingHostID
        let superseded = servers.filter { $0.id != id && $0.streamingHostID == streamingHostID }
        servers.removeAll { server in superseded.contains { $0.id == server.id } }
        return superseded
    }
    @discardableResult
    public mutating func remove(_ id: String) -> PairedServer? {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = servers.remove(at: index)
        if activeID == id { activeID = servers.first?.id }
        return removed
    }
    private enum CodingKeys: String, CodingKey { case servers, activeID }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        for server in try fields.decode([PairedServer].self, forKey: .servers) where self[server.id] == nil { servers.append(server) }
        let saved = try fields.decodeIfPresent(String.self, forKey: .activeID)
        activeID = saved.flatMap { self[$0]?.id } ?? servers.first?.id
    }
}
