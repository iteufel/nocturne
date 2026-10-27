import Foundation
import Combine

@MainActor
public final class DeveloperWorkspaceModel: ObservableObject {
    public let chat: ChatWorkspaceModel
    @Published public private(set) var snapshot: RepositorySnapshot?
    @Published public private(set) var busy = false
    @Published public var error: String?
    @Published public var scope: GitDiffScope = .working
    @Published public var base = ""
    @Published public var remote = ""
    @Published public var allBranches = false
    @Published public var includeClosed = false
    @Published public private(set) var pullRequests: [PullRequestInfo] = []
    @Published public private(set) var selectedPR: PullRequestInfo?
    @Published public private(set) var prFiles: [GitChange] = []
    @Published public private(set) var hasMorePRs = false
    @Published public private(set) var hasMoreFiles = false
    @Published public private(set) var content: RepositoryText?
    @Published public private(set) var activity: [PullRequestActivity] = []
    private var prPage = 1, filePage = 1
    private var context = ""
    private var pendingRefresh = false, pendingPullRequests = false
    private var observers = Set<AnyCancellable>()
    public init(chat: ChatWorkspaceModel) {
        self.chat = chat
        chat.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        chat.$selected.sink { [weak self] selected in
            guard let self else { return }
            let context = self.chat.providerID + ":" + (selected?.id ?? "")
            if self.context != context {
                self.context = context; self.snapshot = nil; self.pullRequests = []; self.selectedPR = nil; self.prFiles = []
                self.content = nil; self.base = ""; self.remote = ""; self.scope = .working; self.error = nil; self.busy = false
                self.activity = []
                self.hasMorePRs = false; self.hasMoreFiles = false
                self.pendingRefresh = false; self.pendingPullRequests = false
            }
        }.store(in: &observers)
    }
    private func request(_ input: RepositoryRequest) async throws -> RepositoryResponse {
        guard !busy else { throw NocturneError.remote("Wait for the project action to finish.") }
        var input = input; input.remote = remote.isEmpty ? nil : remote
        let epoch = context; busy = true; error = nil
        defer {
            if context == epoch {
                busy = false
                let refresh = pendingRefresh, requests = pendingPullRequests
                pendingRefresh = false; pendingPullRequests = false
                if refresh || requests {
                    Task { @MainActor [weak self] in
                        guard let self, self.context == epoch else { return }
                        if refresh { await self.refresh() }
                        if requests { await self.loadPullRequests() }
                    }
                }
            }
        }
        let response = try await chat.projectRequest(input)
        guard context == epoch else { throw CancellationError() }
        return response
    }
    public func refresh() async {
        guard !busy else { pendingRefresh = true; return }
        var input = RepositoryRequest(.status); input.scope = scope == .agent ? .working : scope; input.base = base.isEmpty ? nil : base
        do {
            let response = try await request(input); snapshot = response.snapshot
            if base.isEmpty { base = snapshot?.base ?? "" }
            if remote.isEmpty { remote = snapshot?.remotes.contains("origin") == true ? "origin" : snapshot?.remotes.first ?? "" }
        } catch { record(error) }
    }
    public func stage(_ file: GitChange, undo: Bool) async {
        var input = RepositoryRequest(undo ? .unstage : .stage); input.path = file.path; input.scope = scope; input.base = base.isEmpty ? nil : base
        do { snapshot = try await request(input).snapshot } catch { record(error) }
    }
    public func createWorktree(branch: String, base: String) async -> GitWorktree? {
        var input = RepositoryRequest(.createWorktree); input.branch = branch; input.base = base
        do { return try await request(input).worktree } catch { record(error); return nil }
    }
    public func openWorktree(_ worktree: GitWorktree) async { await chat.newConversation(worktree: worktree.path) }
    public func loadPullRequests(more: Bool = false) async {
        guard !busy else { if !more { pendingPullRequests = true }; return }
        if !more { prPage = 1; pullRequests = [] }
        var input = RepositoryRequest(.pullRequests); input.allBranches = allBranches; input.includeClosed = includeClosed; input.page = prPage
        do {
            let response = try await request(input), existing = Set(pullRequests.map(\.number))
            pullRequests += (response.pullRequests ?? []).filter { !existing.contains($0.number) }
            hasMorePRs = response.hasMore; prPage += 1
        } catch { record(error) }
    }
    public func openPullRequest(_ number: Int) async {
        var input = RepositoryRequest(.pullRequest); input.number = number
        do {
            selectedPR = try await request(input).pullRequest
            activity = []; prFiles = []; filePage = 1; await loadPullRequestFiles()
        } catch { record(error) }
    }
    public func loadActivity() async {
        guard let selectedPR, chat.connection.capabilities.contains(DeveloperProtocol.actionsCapability) else { return }
        var input = RepositoryRequest(.pullRequestActivity); input.number = selectedPR.number
        do { activity = try await request(input).activity ?? [] } catch { record(error) }
    }
    public func commit(_ message: String, revision: String?) async -> Bool {
        var input = RepositoryRequest(.commit); input.text = message; input.revision = revision
        do { snapshot = try await request(input).snapshot; return true } catch { record(error); return false }
    }
    public func previewCommit() async -> RepositorySnapshot? {
        var input = RepositoryRequest(.status); input.scope = .staged
        do { return try await request(input).snapshot } catch { record(error); return nil }
    }
    public func push() async -> Bool {
        guard let snapshot else { return false }
        var input = RepositoryRequest(.push); input.branch = snapshot.branch; input.revision = snapshot.head
        do { self.snapshot = try await request(input).snapshot; return true } catch { record(error); return false }
    }
    public func createPullRequest(title: String, body: String, base: String) async -> Bool {
        guard let snapshot else { return false }
        var input = RepositoryRequest(.createPullRequest); input.title = title; input.text = body; input.base = base; input.branch = snapshot.branch
        do {
            selectedPR = try await request(input).pullRequest
            if let selectedPR { await openPullRequest(selectedPR.number); return true }
            return false
        } catch { record(error); return false }
    }
    public func loadPullRequestFiles() async {
        guard let selectedPR else { return }
        var input = RepositoryRequest(.pullRequestFiles); input.number = selectedPR.number; input.page = filePage
        do {
            let response = try await request(input), existing = Set(prFiles.map(\.path))
            prFiles += (response.changes ?? []).filter { !existing.contains($0.path) }; hasMoreFiles = response.hasMore; filePage += 1
        } catch { record(error) }
    }
    public func savePullRequest(title: String, body: String) async -> Bool {
        guard let selectedPR else { return false }
        var input = RepositoryRequest(.editPullRequest); input.number = selectedPR.number; input.title = title; input.text = body; input.revision = selectedPR.revision
        do {
            let response = try await request(input); self.selectedPR = response.pullRequest
            if let updated = response.pullRequest, let index = pullRequests.firstIndex(where: { $0.number == updated.number }) { pullRequests[index] = updated }
            return response.pullRequest != nil
        } catch { record(error); return false }
    }
    public func loadDiff(_ file: GitChange, pullRequest: Int? = nil) async {
        content = nil
        var input = RepositoryRequest(pullRequest == nil ? .diff : .pullRequestDiff)
        input.path = file.path; input.previousPath = file.previousPath; input.number = pullRequest; input.scope = scope; input.base = base.isEmpty ? nil : base
        input.changeType = file.indexStatus
        do { content = try await request(input).content } catch { record(error) }
    }
    public func readFile(_ path: String) async -> RepositoryText? {
        var input = RepositoryRequest(.readFile); input.path = path
        do { return try await request(input).content } catch { record(error); return nil }
    }
    public func saveFile(_ original: RepositoryText, text: String) async -> RepositoryText? {
        var input = RepositoryRequest(.saveFile); input.path = original.path; input.text = text; input.revision = original.revision
        do { return try await request(input).content } catch { record(error); return nil }
    }
    public func closePullRequest() { selectedPR = nil; prFiles = []; content = nil; activity = [] }
    private func record(_ error: Error) { if !(error is CancellationError) { self.error = error.localizedDescription } }
}
