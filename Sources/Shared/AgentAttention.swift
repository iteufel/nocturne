import Foundation

/// A locator, never an authorization token. Only populate from an authenticated host event.
/// No provider text, arguments, host names, paths or credentials belong here.
public struct AgentAttention: Codable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Codable { case approval, question }
    public let id: String
    public let hostID: String
    public let providerID: String
    public let sessionID: String
    public let expiresAt: Date
    public let kind: Kind
    public init(id: String, hostID: String, providerID: String, sessionID: String, expiresAt: Date, kind: Kind) {
        self.id = id; self.hostID = hostID; self.providerID = providerID
        self.sessionID = sessionID; self.expiresAt = expiresAt; self.kind = kind
    }
    public func isCurrent(hostID: String, providerID: String, sessionID: String, now: Date) -> Bool {
        !id.isEmpty && !self.hostID.isEmpty && !self.providerID.isEmpty && !self.sessionID.isEmpty &&
        self.hostID == hostID && self.providerID == providerID && self.sessionID == sessionID && expiresAt > now
    }
    public static let category = "NOCTURNE_ATTENTION_REVIEW"
    public static let approvalCategory = "NOCTURNE_ATTENTION_DECISION"
    public static let title = "Nocturne needs your attention"
    public static let body = "Open Nocturne to review a pending agent request."

    /// APNs alert payload foundation. Relay must authenticate ownership and set expiration/topic headers.
    /// Review only: receiving or opening this payload must never decide a permission.
    public func pushPayload() throws -> Data {
        let locator = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        return try JSONSerialization.data(withJSONObject: [
            "aps": ["alert": ["title": Self.title, "body": Self.body],
                    "category": Self.category, "sound": "default"],
            "nocturneAttention": locator
        ], options: [.sortedKeys])
    }
}

/// One-shot local gate shared by notification and Live Activity actions.
/// Host authority still validates and consumes the actual provider request independently.
public struct AttentionDecisionGate {
    private var pending: Set<AgentAttention> = []
    private var consumed: Set<AgentAttention> = []
    public init() {}
    public mutating func synchronize(_ requests: Set<AgentAttention>) { pending = requests.subtracting(consumed) }
    public mutating func consume(_ request: AgentAttention, hostID: String, providerID: String, sessionID: String, now: Date) -> Bool {
        guard request.kind == .approval,
              request.isCurrent(hostID: hostID, providerID: providerID, sessionID: sessionID, now: now),
              pending.remove(request) != nil else { return false }
        consumed.insert(request)
        return true
    }
}
