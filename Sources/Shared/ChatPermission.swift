import Foundation

public enum ChatPermissionAction: String, Codable { case allowOnce, denyOnce }

public struct ChatPermissionOption: Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let destructive: Bool
    public let action: ChatPermissionAction?
    public let scope: String?
    public init(id: String, title: String, destructive: Bool = false, action: ChatPermissionAction? = nil, scope: String? = nil) {
        self.id = id; self.title = title; self.destructive = destructive; self.action = action; self.scope = scope
    }
}

public struct ChatPermission: Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public let options: [ChatPermissionOption]
    public let expiresAt: Date?
    public let attentionKind: AgentAttention.Kind?
    public init(id: String, title: String, detail: String, options: [ChatPermissionOption], expiresAt: Date? = nil, attentionKind: AgentAttention.Kind? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.options = options; self.expiresAt = expiresAt; self.attentionKind = attentionKind
    }
}

