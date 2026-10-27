import Foundation
import Combine

@MainActor
public final class ChatWorkspaceModel: ObservableObject {
    public let connection: WorkspaceConnection
    @Published public private(set) var providers: [ChatProvider] = []
    @Published public private(set) var providerID = "codex"
    @Published public private(set) var sessions: [ChatSessionInfo] = []
    @Published public private(set) var selected: ChatSessionInfo?
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var permissions: [ChatPermission] = []
    @Published public private(set) var loading = false
    @Published public private(set) var responding = false
    @Published public private(set) var respondingSince: Date?
    @Published public private(set) var canPrompt = false
    @Published public private(set) var hasMoreSessions = false
    @Published public private(set) var hasOlderMessages = false
    @Published public private(set) var archived = false
    @Published public private(set) var voiceEngaged = false
    @Published public private(set) var notice: String?
    @Published public var error: String?
    @Published public var draft = ""
    @Published public private(set) var options: [ChatConfigOption] = []
    @Published public private(set) var configuring = false
    @Published public private(set) var optionsError: String?
    @Published public private(set) var latestTurnDiff: RepositoryText?
    public var provider: ChatProvider? { providers.first { $0.id == providerID } }
    public var supportsVoice: Bool {
        provider?.supportsVoice == true && connection.capabilities.contains(ChatVoice.capability) && selected != nil && canPrompt && !archived && !configuring
    }
    private weak var voiceConnection: WorkspaceConnection?
    private var voiceObserver: AnyCancellable?
    private var sessionCursor: String?
    private var historyCursor: String?
    private var generation = UUID()
    private var pendingUserID: String?
    private var observers: Set<AnyCancellable> = []

    public init(connection: WorkspaceConnection) {
        self.connection = connection
        connection.chatEvents.sink { [weak self] in self?.receive($0) }.store(in: &observers)
        connection.$state.dropFirst().sink { [weak self] state in
            if state != .connected { self?.reset() }
        }.store(in: &observers)
    }
    public func reset() {
        generation = UUID(); providers = []; providerID = "codex"; sessions = []; clearConversation()
        sessionCursor = nil; hasMoreSessions = false; loading = false; archived = false; notice = nil; error = nil
    }
    private func clearConversation() {
        voiceObserver = nil; voiceConnection = nil; voiceEngaged = false
        selected = nil; messages = []; permissions = []; draft = ""; responding = false; respondingSince = nil
        canPrompt = false; historyCursor = nil; hasOlderMessages = false; pendingUserID = nil
        options = []; configuring = false; optionsError = nil; latestTurnDiff = nil
    }
    public func leaveConversation() { if !responding, !loading, !voiceEngaged, !configuring { generation = UUID(); clearConversation(); error = nil } }
    public func attachVoice(_ connection: WorkspaceConnection) throws {
        guard available, supportsVoice, !voiceEngaged, !loading, !responding else { throw NocturneError.remote("Open a recent Codex conversation and finish its reply before starting voice chat.") }
        voiceConnection = connection; voiceEngaged = true
        voiceObserver = connection.chatEvents.sink { [weak self] in self?.receive($0) }
    }
    public func detachVoice(_ connection: WorkspaceConnection) {
        guard voiceConnection === connection else { return }
        voiceObserver = nil; voiceConnection = nil; voiceEngaged = false; permissions = []; responding = false; respondingSince = nil
    }
    private var available: Bool { connection.state == .connected && connection.capabilities.contains(ChatProtocol.capability) }
    public func refresh() async {
        guard available, !loading, !responding, !voiceEngaged, !configuring else { return }
        let epoch = generation; loading = true; error = nil
        defer { if generation == epoch { loading = false } }
        do {
            let response = try await connection.request(Packet(.chatProviders), timeout: 30)
            guard generation == epoch else { return }
            guard let choices = response.chatProviders, choices.count <= 24, Set(choices.map(\.id)).count == choices.count else { throw NocturneError.invalidFrame }
            providers = choices
            if !choices.contains(where: { $0.id == providerID }) { providerID = choices.first?.id ?? "codex"; clearConversation() }
            sessionCursor = nil; sessions = []; hasMoreSessions = false
            if provider?.available == true { try await fetchSessions(epoch: epoch) }
        } catch { if generation == epoch { self.error = error.localizedDescription } }
    }
    public func chooseProvider(_ id: String) async {
        guard id != providerID, providers.contains(where: { $0.id == id }), !responding, !loading, !voiceEngaged, !configuring else { return }
        generation = UUID(); providerID = id; sessions = []; sessionCursor = nil; hasMoreSessions = false
        archived = false; notice = nil; error = nil; clearConversation()
        await moreSessions()
    }
    public func showArchived(_ value: Bool) async {
        guard !responding, !loading, !voiceEngaged, !configuring, archived != value else { return }
        generation = UUID(); archived = value; sessions = []; sessionCursor = nil; hasMoreSessions = false
        notice = nil; error = nil; clearConversation(); await moreSessions()
    }
    public func moreSessions() async {
        guard available, provider?.available == true, !loading, !responding, !voiceEngaged, !configuring else { return }
        loading = true; error = nil; let epoch = generation
        defer { if generation == epoch { loading = false } }
        do { try await fetchSessions(epoch: epoch) } catch { if generation == epoch { self.error = error.localizedDescription } }
    }
    private func fetchSessions(epoch: UUID) async throws {
        var packet = Packet(.chatList), request = ChatRequest(providerID: providerID)
        request.cursor = sessionCursor; request.archived = archived; packet.chatRequest = request
        let response = try await connection.request(packet, timeout: 100)
        guard generation == epoch else { return }
        guard let page = response.chatPage, page.sessions.count <= ChatProtocol.pageSize,
              page.nextCursor == nil || page.nextCursor != sessionCursor else { throw NocturneError.invalidFrame }
        let existing = Set(sessions.map(\.id)); sessions.append(contentsOf: page.sessions.filter { !existing.contains($0.id) })
        sessionCursor = page.nextCursor; hasMoreSessions = page.nextCursor != nil; notice = page.notice
    }
    public func open(_ session: ChatSessionInfo, older: Bool = false) async {
        guard available, !loading, !responding, !voiceEngaged, !configuring else { return }
        if !older { generation = UUID(); clearConversation(); selected = session }
        let epoch = generation; loading = true; error = nil
        defer { if generation == epoch { loading = false } }
        do {
            var packet = Packet(.chatLoad), request = ChatRequest(providerID: providerID, sessionID: session.id)
            request.cursor = older ? historyCursor : nil; request.archived = archived; packet.chatRequest = request
            let response = try await connection.request(packet, timeout: 100)
            guard generation == epoch else { return }
            guard let page = response.chatHistory, page.session.id == session.id, page.messages.count <= ChatProtocol.pageSize,
                  page.nextCursor == nil || page.nextCursor != request.cursor else { throw NocturneError.invalidFrame }
            selected = page.session
            let existing = Set(messages.map(\.id)); messages.insert(contentsOf: page.messages.filter { !existing.contains($0.id) }, at: 0)
            historyCursor = page.nextCursor; hasOlderMessages = page.nextCursor != nil; canPrompt = page.canPrompt
            if !older { await refreshOptions() }
        } catch { if generation == epoch { self.error = error.localizedDescription } }
    }
    public func newConversation(worktree: String? = nil, inheritProject: Bool = false) async {
        guard available, provider?.available == true, !loading, !responding, !voiceEngaged, !configuring else { return }
        generation = UUID(); let epoch = generation; loading = true; error = nil
        defer { if generation == epoch { loading = false } }
        do {
            var packet = Packet(.chatNew); packet.chatRequest = ChatRequest(providerID: providerID, sessionID: worktree != nil || inheritProject ? selected?.id : nil)
            packet.chatRequest?.worktreePath = worktree
            let response = try await connection.request(packet, timeout: 100)
            guard generation == epoch else { return }
            guard let session = response.chatSession else { throw NocturneError.invalidFrame }
            clearConversation(); selected = session; canPrompt = true; archived = false
            sessions.insert(session, at: 0)
            await refreshOptions()
        } catch { if generation == epoch { self.error = error.localizedDescription } }
    }
    public func refreshOptions() async {
        guard connection.capabilities.contains(DeveloperProtocol.capability), let selected, !configuring else { return }
        let epoch = generation
        do {
            var packet = Packet(.chatOptions); packet.chatRequest = ChatRequest(providerID: providerID, sessionID: selected.id)
            let response = try await connection.request(packet, timeout: 60)
            guard generation == epoch else { return }
            options = response.chatOptions ?? []; optionsError = nil
        } catch { if generation == epoch { optionsError = error.localizedDescription } }
    }
    public func configure(_ option: ChatConfigOption, value: String) async {
        guard let selected, !loading, !responding, !voiceEngaged, !configuring,
              option.choices.contains(where: { $0.value == value }) else { return }
        configuring = true; let epoch = generation; optionsError = nil
        defer { if generation == epoch { configuring = false } }
        do {
            var packet = Packet(.chatConfigure); packet.chatRequest = ChatRequest(providerID: providerID, sessionID: selected.id)
            packet.chatRequest?.configID = option.id; packet.chatRequest?.configValue = value
            let response = try await connection.request(packet, timeout: 60)
            guard generation == epoch, let options = response.chatOptions else { return }; self.options = options
        } catch { if generation == epoch { optionsError = error.localizedDescription } }
    }
    public func projectRequest(_ request: RepositoryRequest, session: ChatSessionInfo? = nil) async throws -> RepositoryResponse {
        let target = session ?? selected
        let crossThreadReads: Set<RepositoryRequest.Action> = [.status, .pullRequests]
        guard available, connection.capabilities.contains(DeveloperProtocol.capability), let target,
              session == nil || (crossThreadReads.contains(request.action) && sessions.contains(where: { $0.id == target.id })) else { throw NocturneError.remote("Open a conversation and update Nocturne Server to use project tools.") }
        let epoch = generation
        var packet = Packet(.chatRepository); packet.chatRequest = ChatRequest(providerID: providerID, sessionID: target.id); packet.repositoryRequest = request
        let reply = try await connection.request(packet, timeout: 180)
        guard epoch == generation else { throw CancellationError() }
        guard let response = reply.repositoryResponse else { throw NocturneError.invalidFrame }
        return response
    }
    public func send() async {
        guard available, let session = selected, canPrompt, !responding, !loading, !voiceEngaged, !configuring else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.utf8.count <= ChatProtocol.maximumPromptBytes else { error = "This message is too long. Send less than 64 KB of text."; return }
        let epoch = generation; responding = true; respondingSince = Date(); error = nil; permissions = []; draft = ""; latestTurnDiff = nil
        let id = UUID().uuidString; pendingUserID = id
        messages.append(ChatMessage(id: id, role: .user, text: text))
        do {
            var packet = Packet(.chatPrompt), request = ChatRequest(providerID: providerID, sessionID: session.id)
            request.text = text; packet.chatRequest = request
            _ = try await connection.request(packet, timeout: 100)
        } catch {
            guard generation == epoch else { return }
            responding = false; respondingSince = nil; permissions = []; self.error = error.localizedDescription
            // Preserve the unsent text for retry when the request itself was rejected.
            draft = text; messages.removeAll { $0.id == id }; pendingUserID = nil
        }
    }
    public func sendHelper(_ prompt: String) async {
        guard available, selected != nil, canPrompt, !responding, !loading, !voiceEngaged, !configuring else { return }
        let previous = draft, epoch = generation
        draft = prompt; await send()
        if generation == epoch { draft = previous }
    }
    public func stop() async {
        guard let session = selected, responding else { return }
        let epoch = generation
        do {
            var packet = Packet(.chatCancel); packet.chatRequest = ChatRequest(providerID: providerID, sessionID: session.id)
            _ = try await connection.request(packet, timeout: 30)
        } catch { if generation == epoch { self.error = error.localizedDescription } }
    }
    public func decide(_ permission: ChatPermission, option: ChatPermissionOption) async {
        guard let session = selected, permissions.contains(where: { $0.id == permission.id }) else { return }
        let epoch = generation
        do {
            var packet = Packet(.chatPermission), request = ChatRequest(providerID: providerID, sessionID: session.id)
            request.permissionID = permission.id; request.optionID = option.id; packet.chatRequest = request
            _ = try await (voiceConnection ?? connection).request(packet, timeout: 30)
            guard generation == epoch else { return }; permissions.removeAll { $0.id == permission.id }
        } catch { if generation == epoch { self.error = error.localizedDescription } }
    }
    private func receive(_ event: ChatEvent) {
        guard available, event.providerID == providerID, event.sessionID == selected?.id else { return }
        switch event.kind {
        case .configured: options = event.options ?? options
        case .diffUpdated: latestTurnDiff = event.diff
        case .message, .delta:
            guard let message = event.message else { return }
            if message.role == .user, let pendingUserID {
                messages.removeAll { $0.id == pendingUserID }; self.pendingUserID = nil
            }
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                if event.kind == .delta { messages[index].text += message.text } else { messages[index] = message }
            } else { messages.append(message) }
        case .permission:
            if let permission = event.permission, !permissions.contains(where: { $0.id == permission.id }) { permissions.append(permission) }
        case .permissionResolved: permissions.removeAll { $0.id == event.detail }
        case .completed: responding = false; respondingSince = nil; permissions = []; notice = event.detail; pendingUserID = nil
        case .failed: responding = false; respondingSince = nil; permissions = []; error = event.detail; pendingUserID = nil
        }
    }
}
