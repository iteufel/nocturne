import Foundation

public enum ChatProtocol {
    public static let capability = "chats-v1"
    public static let pageSize = 40
    public static let maximumPromptBytes = 65_536
    public static let messagePartBytes = 16_384
}

public struct ChatProvider: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let available: Bool
    public let detail: String
    public let supportsVoice: Bool?
    public init(id: String, name: String, available: Bool, detail: String, supportsVoice: Bool? = nil) {
        self.id = id; self.name = name; self.available = available; self.detail = detail; self.supportsVoice = supportsVoice
    }
}

public struct ChatSessionInfo: Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let directory: String
    public let updatedAt: Date?
    public let isSupervisor: Bool?
    public init(id: String, title: String, directory: String, updatedAt: Date? = nil, isSupervisor: Bool? = nil) {
        self.id = id; self.title = title; self.directory = directory; self.updatedAt = updatedAt; self.isSupervisor = isSupervisor
    }
}

public enum ChatRole: String, Codable { case user, assistant, tool, system }

public struct ChatMessage: Codable, Identifiable, Equatable {
    public let id: String
    public let role: ChatRole
    public var text: String
    public init(id: String, role: ChatRole, text: String) { self.id = id; self.role = role; self.text = text }

    /// Split long messages without dropping text or exceeding a workspace frame, even for emoji.
    public var parts: [ChatMessage] {
        guard text.utf8.count > ChatProtocol.messagePartBytes else { return [self] }
        var result: [ChatMessage] = [], start = text.unicodeScalars.startIndex, index = start, bytes = 0
        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index].value
            let size = scalar <= 0x7f ? 1 : scalar <= 0x7ff ? 2 : scalar <= 0xffff ? 3 : 4
            if bytes + size > ChatProtocol.messagePartBytes {
                result.append(ChatMessage(id: id + ":part:\(result.count)", role: role, text: String(text[start..<index])))
                start = index; bytes = 0
            }
            bytes += size; index = text.unicodeScalars.index(after: index)
        }
        if start < text.endIndex { result.append(ChatMessage(id: id + ":part:\(result.count)", role: role, text: String(text[start...]))) }
        return result
    }
}

public struct ChatSessionPage: Codable, Equatable {
    public let sessions: [ChatSessionInfo]
    public let nextCursor: String?
    public let notice: String?
    public init(sessions: [ChatSessionInfo], nextCursor: String? = nil, notice: String? = nil) {
        self.sessions = sessions; self.nextCursor = nextCursor; self.notice = notice
    }
}

public struct ChatHistoryPage: Codable, Equatable {
    public let session: ChatSessionInfo
    public let messages: [ChatMessage]
    public let nextCursor: String?
    public let canPrompt: Bool
    public init(session: ChatSessionInfo, messages: [ChatMessage], nextCursor: String? = nil, canPrompt: Bool = true) {
        self.session = session; self.messages = messages; self.nextCursor = nextCursor; self.canPrompt = canPrompt
    }
}

public struct ChatEvent: Codable, Equatable {
    public enum Kind: String, Codable { case message, delta, completed, permission, permissionResolved, failed, configured, diffUpdated }
    public let providerID: String
    public let sessionID: String
    public var kind: Kind
    public var message: ChatMessage?
    public var permission: ChatPermission?
    public var detail: String?
    public var options: [ChatConfigOption]?
    public var diff: RepositoryText?
    public init(providerID: String, sessionID: String, kind: Kind, message: ChatMessage? = nil,
                permission: ChatPermission? = nil, detail: String? = nil) {
        self.providerID = providerID; self.sessionID = sessionID; self.kind = kind
        self.message = message; self.permission = permission; self.detail = detail
    }
}

public struct ChatRequest: Codable {
    public var providerID: String
    public var sessionID: String?
    public var cursor: String?
    public var text: String?
    public var archived = false
    public var permissionID: String?
    public var optionID: String?
    public var voiceID: String?
    public var voiceSDP: String?
    public var worktreePath: String?
    public var configID: String?
    public var configValue: String?
    public init(providerID: String = "codex", sessionID: String? = nil) {
        self.providerID = providerID; self.sessionID = sessionID
    }
}
