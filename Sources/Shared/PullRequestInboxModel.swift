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
    public init(chat: ChatWorkspaceModel) { self.chat = chat }
    public func reset() { generation = UUID(); items = []; projects = []; errors = []; busy = false; hasMore = false }
    public func refresh() async {
        guard !busy, !chat.loading else { return }
        reset(); let epoch = generation; busy = true
        defer { if generation == epoch { busy = false } }
        var directories = Set<String>(), repositories = Set<String>()
        for session in chat.sessions where directories.insert(session.directory).inserted {
            guard directories.count <= 20, generation == epoch, !Task.isCancelled else { break }
            do {
                let snapshot = try await chat.projectRequest(RepositoryRequest(.status), session: session).snapshot
                let remotes = snapshot?.remotes ?? []
                for remote in remotes.prefix(4) {
                    var status = RepositoryRequest(.status); status.remote = remote
                    guard let forge = try await chat.projectRequest(status, session: session).snapshot?.forge,
                          repositories.insert(forge.webURL).inserted else { continue }
                    var input = RepositoryRequest(.pullRequests); input.remote = remote; input.allBranches = true; input.includeClosed = true
                    let response = try await chat.projectRequest(input, session: session)
                    guard generation == epoch, !Task.isCancelled else { return }
                    append(response, session: session, remote: remote, repository: forge)
                    if response.hasMore { projects.append((session, remote, forge, 2)) }
                }
            } catch is CancellationError { return }
            catch { if generation == epoch { errors.append(URL(fileURLWithPath: session.directory).lastPathComponent + ": " + error.localizedDescription) } }
        }
        hasMore = !projects.isEmpty
    }
    public func more() async {
        guard !busy, !projects.isEmpty else { return }
        busy = true; let epoch = generation
        defer { if generation == epoch { busy = false } }
        let pending = projects; projects = []
        for (session, remote, repository, page) in pending {
            do {
                var input = RepositoryRequest(.pullRequests); input.remote = remote; input.allBranches = true; input.includeClosed = true; input.page = page
                let response = try await chat.projectRequest(input, session: session)
                guard epoch == generation, !Task.isCancelled else { return }
                append(response, session: session, remote: remote, repository: repository)
                if response.hasMore { projects.append((session, remote, repository, page + 1)) }
            } catch { if epoch == generation { errors.append(repository.name + ": " + error.localizedDescription); projects.append((session, remote, repository, page)) } }
        }
        hasMore = !projects.isEmpty
    }
    private func append(_ response: RepositoryResponse, session: ChatSessionInfo, remote: String, repository: ForgeRepository) {
        var existing = Set(items.map(\.id))
        items += (response.pullRequests ?? []).filter { existing.insert($0.url).inserted }.map { Item(session: session, remote: remote, repository: repository, request: $0) }
        items.sort { ($0.request.updatedAt ?? "") > ($1.request.updatedAt ?? "") }
    }
}
