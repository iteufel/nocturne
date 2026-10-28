import Foundation
import NocturneKit

/// One agent process per authenticated connection; disconnect and access revocation tear it down.
@MainActor
public final class ChatHostSession {
    private let supervisor: ChatSupervisorService
    private let ownsSupervisor: Bool
    private let supervisorListener = UUID()
    private var supervisorSelection: String?
    private var configurations: [ChatAgentConfiguration]
    private let directory: URL
    private var enabled: Bool
    private var closed = false
    private var generation = UUID()
    private var agent: ChatAgentSession?
    private var loading = false
    private var activeSession: String?
    private var promptTask: Task<Void, Never>?
    private var cancelTask: Task<Void, Never>?
    private var sendEvent: ((Packet) -> Void)?
    private var voiceID: String?
    private var voiceSession: String?
    private var voiceLastSeen: TimeInterval = 0
    private var voiceWatchdog: Task<Void, Never>?
    private var repositoryTask: Task<RepositoryResponse, Error>?
    private var repositoryBusy = false

    public nonisolated init(configurations: [ChatAgentConfiguration], directory: URL, enabled: Bool, supervisor: ChatSupervisorService? = nil) {
        self.configurations = configurations; self.directory = directory; self.enabled = enabled
        self.ownsSupervisor = supervisor == nil
        self.supervisor = supervisor ?? ChatSupervisorService(configurations: configurations, directory: directory)
    }
    public nonisolated func setEnabled(_ value: Bool) {
        DispatchQueue.main.async {
            if !value { self.supervisor.reset(); self.endActive("Chat access was turned off on your Mac.") }
            self.enabled = value; if !value { self.reset() }
        }
    }
    public nonisolated func configure(_ values: [ChatAgentConfiguration]) {
        DispatchQueue.main.async { self.endActive("The provider settings changed on your Mac. Refresh to reconnect."); self.configurations = values; if self.ownsSupervisor { self.supervisor.reset(configurations: values) }; self.reset() }
    }
    public nonisolated func close() {
        DispatchQueue.main.async { self.closed = true; self.reset(); if self.ownsSupervisor { self.supervisor.reset() }; self.sendEvent = nil }
    }
    private func reset() {
        supervisor.unsubscribe(supervisorListener); supervisorSelection = nil
        repositoryTask?.cancel(); repositoryTask = nil; repositoryBusy = false
        generation = UUID(); promptTask?.cancel(); promptTask = nil
        cancelTask?.cancel(); cancelTask = nil
        agent?.close(); agent = nil; activeSession = nil; loading = false
        clearVoice()
    }
    private func endActive(_ message: String) {
        if let session = activeSession, let agent { event(ChatEvent(providerID: agent.configuration.id, sessionID: session, kind: .failed, detail: message)) }
        if let lease = voiceID, let session = voiceSession, let agent {
            voiceEvent(ChatVoiceEvent(voiceID: lease, providerID: agent.configuration.id, sessionID: session, kind: .failed, detail: message))
        }
    }
    public nonisolated func handle(_ packet: Packet, send: @escaping (Packet) -> Void) {
        DispatchQueue.main.async {
            Task { @MainActor in
                let epoch = self.generation
                do {
                    let reply = try await self.perform(packet, send: send)
                    guard !self.closed else { return }
                    guard self.enabled, self.generation == epoch || packet.operation == .chatVoiceStop else {
                        send(packet.reply(error: NocturneError.permissionDenied.localizedDescription)); return
                    }
                    send(reply)
                } catch {
                    guard !self.closed else { return }
                    send(packet.reply(error: error.localizedDescription))
                }
            }
        }
    }
    private func perform(_ packet: Packet, send: @escaping (Packet) -> Void) async throws -> Packet {
        guard enabled, !closed else { throw NocturneError.permissionDenied }
        var reply = packet.reply()
        if packet.operation == .chatProviders {
            reply.chatProviders = configurations.map(\.descriptor); return reply
        }
        guard let request = packet.chatRequest, request.providerID.utf8.count <= 128,
              request.sessionID == nil || (request.sessionID!.utf8.count <= 512 && !request.sessionID!.isEmpty),
              request.cursor == nil || request.cursor!.utf8.count <= 4_096 else { throw NocturneError.invalidFrame }
        if packet.operation == .chatRepository {
            guard let repositoryRequest = packet.repositoryRequest, let session = request.sessionID, !repositoryBusy else { throw NocturneError.remote("Wait for the project action to finish.") }
            let writes: Set<RepositoryRequest.Action> = [.saveFile, .stage, .unstage, .createWorktree, .editPullRequest, .commit, .push, .createPullRequest]
            guard !writes.contains(repositoryRequest.action) || (activeSession == nil && voiceID == nil && !loading) else {
                throw NocturneError.remote("Finish the agent reply or voice call before changing the project.")
            }
            guard !loading else { throw NocturneError.remote("Wait for the provider to finish loading.") }
            let epoch = generation
            guard let provider = agent, provider.configuration.id == request.providerID, !provider.isClosed else { throw NocturneError.remote("Open the conversation before using project tools.") }
            repositoryBusy = true
            defer { if generation == epoch { repositoryBusy = false; repositoryTask = nil } }
            let directory = try await provider.workingDirectory(for: session)
            guard generation == epoch, enabled, !closed else { throw NocturneError.permissionDenied }
            let task = Task { @MainActor in
                let service = try await RepositoryService.open(directory)
                return try await self.repositoryAction(repositoryRequest, service: service)
            }
            repositoryTask = task
            reply.repositoryResponse = try await task.value
            guard enabled, !closed, generation == epoch else { throw NocturneError.permissionDenied }
            guard try JSONEncoder().encode(reply).count < WorkspaceProtocol.maximumFrame - 4096 else { throw NocturneError.remote("The project response is too large. Choose a smaller file or comparison.") }
            return reply
        }
        if [.chatVoiceHeartbeat, .chatVoiceStop].contains(packet.operation) {
            guard let agent, agent.configuration.id == request.providerID, let lease = request.voiceID,
                  lease == voiceID, request.sessionID == voiceSession else { throw NocturneError.invalidFrame }
            voiceLastSeen = ProcessInfo.processInfo.systemUptime
            switch packet.operation {
            case .chatVoiceStop:
                do { try await agent.stopVoice(lease: lease) }
                catch { reset(); throw error }
                reset()
                return reply
            default: break
            }
            return reply
        }
        if packet.operation == .chatPermission, let session = request.sessionID,
           supervisor.isSupervisor(session, provider: request.providerID), let id = request.permissionID, let option = request.optionID,
           try supervisor.approve(id, option: option, supervisor: session) {
            return reply
        }
        if packet.operation == .chatCancel || packet.operation == .chatPermission {
            guard let agent, agent.configuration.id == request.providerID, let id = request.sessionID,
                  id == activeSession || id == voiceSession else { throw NocturneError.invalidFrame }
            if packet.operation == .chatCancel {
                try await agent.cancel(id)
                if activeSession == id {
                    let epoch = generation
                    cancelTask?.cancel()
                    cancelTask = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                        guard let self, self.generation == epoch, self.activeSession == id else { return }
                        self.event(ChatEvent(providerID: request.providerID, sessionID: id, kind: .completed, detail: "Stopped"))
                        self.reset()
                    }
                }
            }
            else {
                guard let permission = request.permissionID, let option = request.optionID else { throw NocturneError.invalidFrame }
                try agent.approve(permission, option: option)
            }
            return reply
        }
        guard !loading else { throw NocturneError.remote("Wait for the provider to finish loading.") }
        guard activeSession == nil else { throw NocturneError.remote("Stop the current reply before switching conversations or providers.") }
        guard voiceID == nil else { throw NocturneError.remote("End voice chat before switching conversations or providers.") }
        loading = true; let epoch = generation
        defer { if generation == epoch { loading = false } }
        sendEvent = send
        if packet.operation == .chatVoicePrepare {
            guard let id = request.sessionID, configurations.contains(where: { $0.id == request.providerID && $0.transport == .codex }) else { throw NocturneError.invalidFrame }
            if let agent {
                guard agent.configuration.id == request.providerID else { throw NocturneError.invalidFrame }
                try await agent.releaseForVoice(id)
                if self.agent === agent { self.agent = nil }
            }
            return reply
        }
        if packet.operation == .chatVoiceStart {
            guard request.sessionID != nil, !request.archived, let sdp = request.voiceSDP else { throw NocturneError.remote("Open a recent Codex conversation to start live voice chat.") }
            try ChatVoice.validateSDP(sdp)
        }
        let provider = try await provider(request.providerID, forVoice: [.chatVoiceOpen, .chatVoiceStart].contains(packet.operation))
        guard generation == epoch, enabled, !closed else { throw NocturneError.permissionDenied }
        supervisorSelection = request.sessionID.flatMap { supervisor.isSupervisor($0, provider: request.providerID) ? $0 : nil }
        supervisor.subscribe(supervisorListener) { [weak self] event in
            guard let self, self.enabled, !self.closed, self.supervisorSelection == event.sessionID else { return }
            self.event(event)
        }
        switch packet.operation {
        case .chatVoiceOpen:
            guard let session = request.sessionID, !request.archived else { throw NocturneError.invalidFrame }
            do { reply.chatSession = supervisor.decorate(try await provider.prepareVoiceSession(session, allowContinuation: true), provider: request.providerID) }
            catch { provider.close(); if agent === provider { agent = nil }; throw error }
        case .chatSupervisor:
            reply.chatHistory = try await supervisor.open(using: provider)
            supervisorSelection = reply.chatHistory?.session.id
            if let id = supervisorSelection {
                reply.chatPermissions = supervisor.permissions(for: id)
            }
        case .chatList:
            let page = try await provider.list(cursor: request.cursor, archived: request.archived)
            reply.chatPage = ChatSessionPage(sessions: page.sessions.map { supervisor.decorate($0, provider: request.providerID) }, nextCursor: page.nextCursor, notice: page.notice)
        case .chatLoad:
            guard let id = request.sessionID else { throw NocturneError.invalidFrame }
            let page = try await provider.load(id, cursor: request.cursor, archived: request.archived)
            reply.chatHistory = ChatHistoryPage(session: supervisor.decorate(page.session, provider: request.providerID), messages: page.messages, nextCursor: page.nextCursor, canPrompt: page.canPrompt)
            if supervisorSelection != nil { reply.chatPermissions = supervisor.permissions(for: id) }
        case .chatNew:
            var directory: URL?
            if let path = request.worktreePath {
                guard let source = request.sessionID else { throw NocturneError.invalidFrame }
                let repository = try await RepositoryService.open(provider.workingDirectory(for: source))
                let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                guard try await repository.worktrees().contains(where: { $0.path == canonical.path && !$0.prunable }) else { throw NocturneError.invalidPath }
                directory = canonical
            } else if let source = request.sessionID {
                directory = try await provider.workingDirectory(for: source)
            }
            reply.chatSession = try await provider.create(in: directory)
        case .chatOptions:
            guard let id = request.sessionID else { throw NocturneError.invalidFrame }
            reply.chatOptions = try await provider.options(for: id)
        case .chatConfigure:
            guard let session = request.sessionID, let id = request.configID, let value = request.configValue,
                  id.utf8.count <= 512, value.utf8.count <= 512 else { throw NocturneError.invalidFrame }
            reply.chatOptions = try await provider.configure(session, id: id, value: value)
        case .chatVoiceStart:
            guard provider.configuration.transport == .codex, let session = request.sessionID, let sdp = request.voiceSDP, !request.archived else {
                throw NocturneError.remote("Open a recent Codex conversation to start live voice chat.")
            }
            let lease = UUID().uuidString
            voiceID = lease; voiceSession = session
            do { try await provider.startVoice(session, lease: lease, sdp: sdp) }
            catch { clearVoice(); provider.close(); agent = nil; throw error }
            guard voiceID == lease else { throw NocturneError.remote("Voice chat ended while connecting.") }
            voiceLastSeen = ProcessInfo.processInfo.systemUptime
            voiceWatchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self, self.voiceID == lease else { return }
                    self.expireVoice(now: ProcessInfo.processInfo.systemUptime)
                }
            }
            reply.chatVoiceEvent = ChatVoiceEvent(voiceID: lease, providerID: request.providerID, sessionID: session, kind: .started)
        case .chatPrompt:
            guard let id = request.sessionID, let text = request.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= ChatProtocol.maximumPromptBytes else { throw NocturneError.invalidFrame }
            activeSession = id
            promptTask = Task { [weak self] in
                do { try await provider.prompt(id, text: text) }
                catch {
                    guard let self, self.generation == epoch, self.activeSession == id else { return }
                    self.event(ChatEvent(providerID: request.providerID, sessionID: id, kind: .failed, detail: error.localizedDescription))
                }
            }
        default: throw NocturneError.invalidFrame
        }
        return reply
    }
    private func repositoryAction(_ request: RepositoryRequest, service: RepositoryService) async throws -> RepositoryResponse {
        var result = RepositoryResponse()
        switch request.action {
        case .status: result.snapshot = try await service.snapshot(scope: request.scope, requestedBase: request.base, remoteName: request.remote)
        case .diff: result.content = try await service.diff(request)
        case .readFile:
            guard let path = request.path else { throw NocturneError.invalidPath }
            result.content = try SharedFolder(url: service.root).editableText(path)
        case .saveFile:
            guard let path = request.path, let text = request.text, let revision = request.revision else { throw NocturneError.invalidFrame }
            result.content = try SharedFolder(url: service.root).replaceText(path, text: text, revision: revision)
        case .stage, .unstage:
            guard let path = request.path else { throw NocturneError.invalidPath }
            try await service.stage(path, undo: request.action == .unstage)
            result.snapshot = try await service.snapshot(scope: request.scope, requestedBase: request.base, remoteName: request.remote)
        case .createWorktree:
            guard let branch = request.branch, let base = request.base else { throw NocturneError.invalidFrame }
            result.worktree = try await service.createWorktree(branch: branch, base: base)
        case .commit:
            guard let text = request.text else { throw NocturneError.invalidFrame }
            try await service.commit(message: text, revision: request.revision)
            result.snapshot = try await service.snapshot(remoteName: request.remote)
        case .push:
            guard let remote = request.remote, let branch = request.branch else { throw NocturneError.invalidFrame }
            try await service.push(remote: remote, branch: branch, head: request.revision)
            result.snapshot = try await service.snapshot(remoteName: remote)
        default:
            let snapshot = try await service.snapshot(remoteName: request.remote)
            guard let forge = snapshot.forge else { throw NocturneError.remote("Choose a GitHub or Azure DevOps remote for this repository.") }
            var headOwner: String?
            if forge.kind == .github, [.pullRequests, .createPullRequest].contains(request.action), !request.allBranches {
                let origin = try await service.git(["remote", "get-url", "origin"], accepts: [0, 2, 128])
                if let source = ForgeService.parseRemote(origin.text), source.kind == .github, source.host == forge.host { headOwner = source.organization }
            }
            let provider = ForgeService(repository: forge, directory: service.root, headOwner: headOwner)
            switch request.action {
            case .pullRequests:
                let list = try await provider.list(branch: request.allBranches ? nil : snapshot.branch, page: request.page, includeClosed: request.includeClosed)
                result.pullRequests = list.0; result.hasMore = list.1
            case .pullRequest:
                guard let id = request.number else { throw NocturneError.invalidFrame }; result.pullRequest = try await provider.detail(id)
            case .pullRequestActivity:
                guard let id = request.number else { throw NocturneError.invalidFrame }; result.activity = try await provider.activity(id)
            case .createPullRequest:
                guard let title = request.title, let base = request.base, let branch = request.branch,
                      snapshot.branch == branch, snapshot.branches.contains(base), branch != "Detached HEAD" else { throw NocturneError.invalidFrame }
                let prefix = (request.remote ?? "origin") + "/"
                let target = base.hasPrefix(prefix) ? String(base.dropFirst(prefix.count)) : base
                result.pullRequest = try await provider.create(title: title, body: request.text ?? "", source: branch, target: target)
            case .editPullRequest:
                guard let id = request.number, let title = request.title, let body = request.text else { throw NocturneError.invalidFrame }
                result.pullRequest = try await provider.edit(id, title: title, body: body, expectedRevision: request.revision)
            case .pullRequestFiles:
                guard let id = request.number else { throw NocturneError.invalidFrame }
                let files = try await provider.files(id, page: request.page); result.changes = files.0; result.hasMore = files.1
            case .pullRequestDiff:
                guard let id = request.number, let path = request.path else { throw NocturneError.invalidFrame }
                result.content = try await provider.diff(id, path: path, previousPath: request.previousPath, changeType: request.changeType)
            default: throw NocturneError.invalidFrame
            }
        }
        return result
    }
    private func provider(_ id: String, forVoice: Bool = false) async throws -> ChatAgentSession {
        if let agent, agent.isVoiceProvider != forVoice { agent.close(); self.agent = nil }
        if let agent, agent.configuration.id == id, !agent.isClosed { return agent }
        guard let configuration = configurations.first(where: { $0.id == id }) else { throw NocturneError.remote("This provider is no longer configured on your Mac. Refresh the provider list.") }
        guard !forVoice || configuration.transport == .codex else { throw NocturneError.remote("Live voice is currently available for Codex.") }
        agent?.close(); agent = nil
        let epoch = generation
        let next = try ChatAgentSession(configuration: configuration, directory: configuration.workingDirectory(fallback: directory),
            chatGPTOnly: forVoice)
        next.supervisorSession = { [weak supervisor] id in supervisor?.isSupervisor(id, provider: configuration.id) == true }
        next.supervisorTool = { [weak supervisor] id, arguments in
            guard let supervisor else { throw NocturneError.disconnected }
            return try await supervisor.call(arguments, supervisorProvider: configuration.id, supervisorID: id)
        }
        next.emit = { [weak self] event in
            guard let self, self.generation == epoch else { return }; self.event(event)
        }
        next.emitVoice = { [weak self] event in
            guard let self, self.generation == epoch else { return }; self.voiceEvent(event)
        }
        agent = next
        do { try await next.initialize() }
        catch { next.close(); if agent === next { agent = nil }; throw error }
        guard generation == epoch, enabled, !closed else { next.close(); throw NocturneError.permissionDenied }
        return next
    }
    private func event(_ event: ChatEvent) {
        guard enabled, !closed else { return }
        if event.kind == .completed || event.kind == .failed { activeSession = nil; promptTask = nil; cancelTask?.cancel(); cancelTask = nil }
        if let message = event.message {
            // Full completed messages replace the partial text, then append the remaining bounded parts.
            for (index, part) in message.parts.enumerated() {
                var bounded = event; bounded.message = ChatMessage(id: message.id, role: message.role, text: part.text)
                if event.kind == .message, index > 0 { bounded.kind = .delta }
                var packet = Packet(.chatEvent); packet.chatEvent = bounded; sendEvent?(packet)
            }
        } else { var packet = Packet(.chatEvent); packet.chatEvent = event; sendEvent?(packet) }
        if event.kind == .completed || event.kind == .failed, supervisor.isSupervisor(event.sessionID, provider: event.providerID) {
            for permission in supervisor.permissions(for: event.sessionID) {
                var packet = Packet(.chatEvent); packet.chatEvent = ChatEvent(providerID: event.providerID, sessionID: event.sessionID, kind: .permission, permission: permission); sendEvent?(packet)
            }
        }
    }
    private func clearVoice() {
        voiceID = nil; voiceSession = nil; voiceWatchdog?.cancel(); voiceWatchdog = nil
    }
    func expireVoice(now: TimeInterval) {
        guard let lease = voiceID, let session = voiceSession, let agent, now - voiceLastSeen > ChatVoice.leaseTimeout else { return }
        voiceEvent(ChatVoiceEvent(voiceID: lease, providerID: agent.configuration.id, sessionID: session,
            kind: .failed, detail: "Voice chat timed out. Reconnect to start talking again."))
        reset()
    }
    private func voiceEvent(_ event: ChatVoiceEvent) {
        guard enabled, !closed, event.voiceID == voiceID, event.sessionID == voiceSession else { return }
        var packet = Packet(.chatVoiceEvent); packet.chatVoiceEvent = event; sendEvent?(packet)
        if (event.kind == .closed || event.kind == .failed), !loading { clearVoice(); reset() }
    }
}
