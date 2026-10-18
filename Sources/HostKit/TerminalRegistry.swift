import Foundation
import NocturneKit

/// Owned by the server, not a socket. Every operation runs on the host's serial queue.
final class TerminalRegistry {
    private final class Entry {
        let owner: String
        let number: Int
        let shell: TerminalSession
        var info: RemoteTerminal
        var history = Data()
        var offset: Int64 = 0
        var subscribers: [UUID: (Packet) -> Void] = [:]
        init(owner: String, number: Int, shell: TerminalSession, columns: Int, rows: Int) {
            self.owner = owner; self.number = number; self.shell = shell
            info = RemoteTerminal(id: shell.id, name: "Terminal \(number)", columns: columns, rows: rows)
        }
    }
    private var entries: [String: Entry] = [:]
    private var nextNumber: [String: Int] = [:]

    func list(owner: String) -> [RemoteTerminal] {
        entries.values.filter { $0.owner == owner }.sorted { $0.number < $1.number }.map(\.info)
    }

    func open(owner: String, connection: UUID, columns: Int, rows: Int, queue: DispatchQueue,
              send: @escaping (Packet) -> Void) throws -> RemoteTerminal {
        guard list(owner: owner).count < WorkspaceProtocol.maximumTerminals else {
            throw NocturneError.remote("You can have up to eight terminal tabs. Close a tab before opening another.")
        }
        let columns = min(max(columns, 20), 500), rows = min(max(rows, 5), 200)
        var id: String?
        let shell = try TerminalSession(columns: columns, rows: rows, queue: queue) { [weak self] data in
            guard let id else { return }; self?.received(data, id: id)
        } exited: { [weak self] in
            guard let id, let entry = self?.entries[id] else { return }
            entry.info.running = false
            var event = Packet(.terminalExit); event.sessionID = id; event.terminal = entry.info
            entry.subscribers.values.forEach { $0(event) }
        }
        id = shell.id
        let number = (nextNumber[owner] ?? 0) + 1; nextNumber[owner] = number
        let entry = Entry(owner: owner, number: number, shell: shell, columns: columns, rows: rows)
        entry.subscribers[connection] = send; entries[shell.id] = entry
        return entry.info
    }

    func attach(_ packet: Packet, owner: String, connection: UUID, send: @escaping (Packet) -> Void) throws -> Packet {
        let entry = try owned(packet.sessionID, by: owner)
        let first = entry.offset - Int64(entry.history.count)
        let requested = packet.offset ?? 0
        let start = requested >= first && requested <= entry.offset ? requested : first
        var reply = packet.reply(); reply.terminal = entry.info; reply.sessionID = entry.info.id
        reply.offset = start; reply.size = entry.offset
        reply.data = Data(entry.history.suffix(Int(entry.offset - start)))
        // Subscription and snapshot are atomic with respect to PTY reads. The reply is
        // sent before the next output event, so replay has neither a gap nor duplicates.
        entry.subscribers[connection] = send
        return reply
    }

    func input(_ packet: Packet, owner: String) throws {
        try owned(packet.sessionID, by: owner).shell.input(packet.data ?? Data())
    }
    func resize(_ packet: Packet, owner: String) throws {
        let entry = try owned(packet.sessionID, by: owner)
        entry.info.columns = min(max(packet.columns ?? 80, 20), 500)
        entry.info.rows = min(max(packet.rows ?? 24, 5), 200)
        entry.shell.resize(columns: entry.info.columns, rows: entry.info.rows)
    }
    func close(_ id: String?, owner: String) throws {
        let entry = try owned(id, by: owner)
        entries.removeValue(forKey: entry.info.id); entry.shell.close()
        var event = Packet(.terminalClosed); event.sessionID = entry.info.id
        entry.subscribers.values.forEach { $0(event) }
    }
    func detach(_ connection: UUID) {
        entries.values.forEach { $0.subscribers.removeValue(forKey: connection) }
    }
    func closeAll(owner: String? = nil) {
        for entry in Array(entries.values) where owner == nil || entry.owner == owner {
            try? close(entry.info.id, owner: entry.owner)
        }
        if let owner { nextNumber.removeValue(forKey: owner) } else { nextNumber.removeAll() }
    }
    private func owned(_ id: String?, by owner: String) throws -> Entry {
        guard let id, let entry = entries[id], entry.owner == owner else {
            throw NocturneError.remote("This terminal session is no longer available.")
        }
        return entry
    }
    private func received(_ data: Data, id: String) {
        guard let entry = entries[id] else { return }
        var event = Packet(.terminalOutput); event.sessionID = id; event.offset = entry.offset; event.data = data
        entry.offset += Int64(data.count); entry.history.append(data)
        if entry.history.count > WorkspaceProtocol.terminalHistoryLimit {
            entry.history.removeFirst(entry.history.count - WorkspaceProtocol.terminalHistoryLimit)
        }
        entry.subscribers.values.forEach { $0(event) }
    }
}
