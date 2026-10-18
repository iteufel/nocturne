import Foundation
import Combine

/// A tab survives transport reconnects. Each renderer subscribes independently, so
/// the main workspace and the stream's tools panel never steal each other's output.
@MainActor
public final class TerminalTab: ObservableObject, Identifiable {
    public enum Update { case append(Data), reset(Data) }
    public nonisolated let id: String
    @Published public private(set) var info: RemoteTerminal
    public private(set) var history = Data()
    public private(set) var offset: Int64 = 0
    public let output = PassthroughSubject<Update, Never>()
    init(_ info: RemoteTerminal) { self.id = info.id; self.info = info }
    func update(_ info: RemoteTerminal) { self.info = info }
    func receive(_ data: Data, at start: Int64) throws {
        guard start >= 0, start <= Int64.max - Int64(data.count) else { throw NocturneError.invalidFrame }
        if start > offset {
            // The device was away longer than the bounded server scrollback covers.
            history = data; offset = start + Int64(data.count)
            trimHistory(); output.send(.reset(history)); return
        }
        let overlap = min(Int64(data.count), offset - start)
        let fresh = Data(data.dropFirst(Int(overlap)))
        guard !fresh.isEmpty else { return }
        offset += Int64(fresh.count); history.append(fresh); trimHistory()
        output.send(.append(fresh))
    }
    private func trimHistory() {
        if history.count > WorkspaceProtocol.terminalHistoryLimit {
            history.removeFirst(history.count - WorkspaceProtocol.terminalHistoryLimit)
        }
    }
}
