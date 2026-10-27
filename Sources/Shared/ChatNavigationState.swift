import Foundation
import Combine

public enum ChatSlashCommand: String, CaseIterable, Identifiable {
    case new, changes, worktrees, terminal, files, pr
    public var id: String { rawValue }
    public static func parse(_ text: String) -> ChatSlashCommand? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/") else { return nil }
        return ChatSlashCommand(rawValue: String(value.dropFirst()))
    }
}

/// Presentation preferences are local to a paired Mac and provider. Agent history stays agent-owned.
@MainActor
public final class ChatNavigationState: ObservableObject {
    public enum Group: String, CaseIterable { case recent = "Threads", working = "Working", snoozed = "Snoozed", settled = "Settled" }
    public struct Entry: Codable, Equatable {
        public var title: String?
        public var snoozedUntil: Date?
        public var settled = false
        public var draft: String?
    }
    @Published private var entries: [String: Entry]
    private let defaults: UserDefaults
    private let key: String
    public init(scope: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults; key = "nocturne.chat.navigation." + scope
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
    public func entry(_ id: String) -> Entry { entries[id] ?? Entry() }
    public func title(_ session: ChatSessionInfo) -> String { entries[session.id]?.title ?? session.title }
    public func rename(_ id: String, title: String) {
        update(id) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(title.prefix(256)) }
    }
    public func snooze(_ id: String, until: Date?) { update(id) { $0.snoozedUntil = until; $0.settled = false } }
    public func settle(_ id: String, _ value: Bool) { update(id) { $0.settled = value; $0.snoozedUntil = nil } }
    public func saveDraft(_ text: String, for id: String) { update(id) { $0.draft = text.isEmpty ? nil : String(text.prefix(ChatProtocol.maximumPromptBytes)) } }
    public func group(_ id: String, active: String?, now: Date = Date()) -> Group {
        if id == active { return .working }
        let item = entry(id)
        if let until = item.snoozedUntil, until > now { return .snoozed }
        return item.settled ? .settled : .recent
    }
    private func update(_ id: String, _ action: (inout Entry) -> Void) {
        var item = entry(id); action(&item); entries[id] = item
        // Bound local metadata without removing the user's saved drafts.
        if entries.count > 2000 {
            for key in entries.keys.sorted().prefix(entries.count - 2000) where key != id && entries[key]?.draft == nil { entries.removeValue(forKey: key) }
        }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}
