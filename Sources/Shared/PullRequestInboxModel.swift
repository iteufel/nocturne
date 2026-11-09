import Foundation
import Combine

@MainActor
public final class PullRequestInboxModel: ObservableObject {
    public struct Item: Identifiable, Equatable {
        public var id: String { request.url }
        public let session: ChatSessionInfo
        public let remote: String
        public let repository: ForgeRepository
        public let request: PullRequestInfo
    }
    @Published public private(set) var items: [Item] = []
    @Published public private(set) var busy = false
    @Published public private(set) var errors: [String] = []
    @Published public private(set) var hasMore = false
    private let chat: ChatWorkspaceModel
    private var projects: [(ChatSessionInfo, String, ForgeRepository, Int)] = []
    private var generation = UUID()
    private var readerConnection: WorkspaceConnection?
    private var connectionObserver: AnyCancellable?
    public init(chat: ChatWorkspaceModel) {
        self.chat = chat
        connectionObserver = chat.connection.$state.dropFirst().sink { [weak self] state in
            if state != .connected { self?.reset() }
        }
    }
    public func reset() { readerConnection?.disconnect(); readerConnection = nil; generation = UUID(); items = []; projects = []; errors = []; busy = false; hasMore = false }
    public func refresh() async {
        guard !busy, !chat.loading else { return }
        reset(); let epoch = generation; busy = true
        defer { if generation == epoch { busy = false; readerConnection?.disconnect(); readerConnection = nil } }
        let reader: ChatWorkspaceModel
        do { reader = try await makeReader(epoch: epoch) }
        catch { if generation == epoch { errors = [NocturneLocalization.message(error.localizedDescription)] }; return }
        var directories = Set<String>(), repositories = Set<String>(), scanned = 0
        for session in reader.sessions where session.isSupervisor != true && directories.insert(session.directory).inserted {
            guard scanned < 20, generation == epoch, !Task.isCancelled else { break }
            scanned += 1
            do {
                let snapshot = try await reader.projectRequest(RepositoryRequest(.status), session: session).snapshot
                directories.formUnion(snapshot?.worktrees.map(\.path) ?? [])
                let remotes = snapshot?.remotes ?? []
                for remote in remotes.prefix(4) {
                    var status = RepositoryRequest(.status); status.remote = remote
                    guard let forge = try await reader.projectRequest(status, session: session).snapshot?.forge,
                          repositories.insert(forge.webURL).inserted else { continue }
                    var input = RepositoryRequest(.pullRequests); input.remote = remote; input.allBranches = true; input.includeClosed = true
                    let response = try await reader.projectRequest(input, session: session)
                    guard generation == epoch, !Task.isCancelled else { return }
                    append(response, session: session, remote: remote, repository: forge)
                    if response.hasMore { projects.append((session, remote, forge, 2)) }
                }
            } catch is CancellationError { return }
            catch { if generation == epoch { errors.append(URL(fileURLWithPath: session.directory).lastPathComponent + ": " + NocturneLocalization.message(error.localizedDescription)) } }
        }
        hasMore = !projects.isEmpty
    }
    public func more() async {
        guard !busy, !projects.isEmpty else { return }
        busy = true; let epoch = generation
        defer { if generation == epoch { busy = false; readerConnection?.disconnect(); readerConnection = nil } }
        let reader: ChatWorkspaceModel
        do { reader = try await makeReader(epoch: epoch) }
        catch { if generation == epoch { errors = [NocturneLocalization.message(error.localizedDescription)] }; return }
        let pending = projects; projects = []
        for (session, remote, repository, page) in pending {
            do {
                var input = RepositoryRequest(.pullRequests); input.remote = remote; input.allBranches = true; input.includeClosed = true; input.page = page
                let response = try await reader.projectRequest(input, session: session)
                guard epoch == generation, !Task.isCancelled else { return }
                append(response, session: session, remote: remote, repository: repository)
                if response.hasMore { projects.append((session, remote, repository, page + 1)) }
            } catch { if epoch == generation { errors.append(repository.name + ": " + NocturneLocalization.message(error.localizedDescription)); projects.append((session, remote, repository, page)) } }
        }
        hasMore = !projects.isEmpty
    }
    private func makeReader(epoch: UUID) async throws -> ChatWorkspaceModel {
        guard let invitation = chat.connection.connectedInvitation else { throw NocturneError.disconnected }
        let providerID = chat.providerID, connection = chat.connection.mediaConnection()
        readerConnection = connection
        try await connection.connect(invitation, restoreTerminalSessions: false)
        guard generation == epoch else { connection.disconnect(); throw CancellationError() }
        let reader = ChatWorkspaceModel(connection: connection)
        await reader.refresh()
        if reader.providerID != providerID { await reader.chooseProvider(providerID) }
        // Match the loaded source sessions without changing the conversation's own pagination cursor.
        let required = Set(chat.sessions.map(\.id)).union(projects.map { $0.0.id })
        for _ in 0..<50 {
            if required.isSubset(of: Set(reader.sessions.map(\.id))) || !reader.hasMoreSessions { break }
            guard generation == epoch, !Task.isCancelled else { throw CancellationError() }
            await reader.moreSessions()
            if reader.error != nil { break }
        }
        if let error = reader.error { throw NocturneError.remote(error) }
        guard generation == epoch else { throw CancellationError() }
        return reader
    }
    private func append(_ response: RepositoryResponse, session: ChatSessionInfo, remote: String, repository: ForgeRepository) {
        var existing = Set(items.map(\.id))
        items += (response.pullRequests ?? []).filter { existing.insert($0.url).inserted }.map { Item(session: session, remote: remote, repository: repository, request: $0) }
        items.sort { ($0.request.updatedAt ?? "") > ($1.request.updatedAt ?? "") }
    }
}
