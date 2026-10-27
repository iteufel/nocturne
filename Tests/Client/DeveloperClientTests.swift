import XCTest
import UIKit
import SwiftUI
import Network
import CryptoKit
import NocturneKit
@testable import Nocturne

@MainActor
final class DeveloperClientTests: XCTestCase {
    func testInboxKeepsForgeIdentitiesAndHelpersPreserveDraftsOverTLS() async throws {
        let peer = try DeveloperWorkspacePeer(); try await peer.start()
        let engine = NocturneStreamingService()
        let client = WorkspaceConnection(identity: WorkspaceIdentity(certificate: engine.workspaceCertificate(), name: "Chat test") { engine.signWorkspaceChallenge($0) })
        defer { client.disconnect(); peer.stop() }
        try await client.connect(peer.invitation())
        let chat = ChatWorkspaceModel(connection: client)
        await chat.refresh(); await chat.open(try XCTUnwrap(chat.sessions.first))
        let inbox = PullRequestInboxModel(chat: chat); await inbox.refresh()
        XCTAssertEqual(inbox.items.count, 2, "Matching PR numbers on GitHub and Azure must remain distinct")
        XCTAssertEqual(Set(inbox.items.map(\.id)).count, 2)
        XCTAssertTrue(inbox.errors.isEmpty)
        chat.draft = "An unsent request"
        await chat.sendHelper("Explain https://github.com/acme/app/pull/41")
        XCTAssertEqual(peer.lastPrompt, "Explain https://github.com/acme/app/pull/41")
        XCTAssertEqual(chat.draft, "An unsent request")
        try await waitUntil { !chat.responding }
        peer.holdPrompt = true
        let helper = Task { await chat.sendHelper("A delayed helper") }
        try await waitUntil { peer.lastPrompt == "A delayed helper" }
        chat.reset(); peer.finishPrompt(); await helper.value
        XCTAssertNil(chat.selected); XCTAssertEqual(chat.draft, "", "A late helper cannot restore a draft into another chat generation")
    }
    func testNativeChatCanvasScreenshot() async throws {
        let peer = try DeveloperWorkspacePeer(demonstration: true); try await peer.start()
        let app = ClientModel(voicePermission: { false }), client = app.server, chat = app.chats
        defer { app.suspend(); peer.stop() }
        let invitation = try peer.invitation(); try await client.connect(invitation)
        await chat.refresh(); await chat.open(try XCTUnwrap(chat.sessions.first))
        let scope = SHA256.hash(data: invitation.secret).map { String(format: "%02x", $0) }.joined() + ".codex"
        let preferences = ChatNavigationState(scope: scope)
        preferences.snooze("demo-snoozed", until: Date().addingTimeInterval(3600)); preferences.settle("demo-settled", true)
        defer { UserDefaults.standard.removeObject(forKey: "nocturne.chat.navigation." + scope) }
        app.page = .chats
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: ClientRootView(model: app))
        window.rootViewController = controller; window.makeKeyAndVisible(); defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 400_000_000); controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "T3-style native chat workspace"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(chat.messages.count, 3)
        if #available(iOS 27.1, *), window.traitCollection.verticalBarEdge != .unspecified {
            func navigationControllers(_ controller: UIViewController) -> [UINavigationController] {
                (controller as? UINavigationController).map { [$0] } ?? controller.children.flatMap(navigationControllers)
            }
            let navigation = try XCTUnwrap(navigationControllers(controller).first { $0.view.window === window })
            XCTAssertFalse(navigation.isNavigationBarHidden, "Duo chat actions must use the system's vertical bar at the hardware edge, not a second rail inside the content safe area")
            XCTAssertFalse(navigation.toolbarItems?.isEmpty ?? navigation.topViewController?.toolbarItems?.isEmpty ?? true, "Keep conversation and PR navigation in the system bar")
        }
    }
    func testInteractiveChatWorkspaceCapture() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_CAPTURE_CHAT"] == "1" else { throw XCTSkip("Opt-in native screenshot navigation") }
        let peer = try DeveloperWorkspacePeer(demonstration: true); try await peer.start()
        let app = ClientModel(voicePermission: { false }), client = app.server, chat = app.chats
        defer { app.suspend(); peer.stop() }
        let invitation = try peer.invitation(); try await client.connect(invitation)
        await chat.refresh(); await chat.open(try XCTUnwrap(chat.sessions.first))
        let scope = SHA256.hash(data: invitation.secret).map { String(format: "%02x", $0) }.joined() + ".codex"
        let preferences = ChatNavigationState(scope: scope)
        preferences.snooze("demo-snoozed", until: Date().addingTimeInterval(3600)); preferences.settle("demo-settled", true)
        defer { UserDefaults.standard.removeObject(forKey: "nocturne.chat.navigation." + scope) }
        app.page = .chats
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ClientRootView(model: app))
        window.makeKeyAndVisible(); defer { window.isHidden = true }
        if ProcessInfo.processInfo.environment["NOCTURNE_CAPTURE_LANDSCAPE"] == "1" {
            for _ in 0..<50 {
                if window.bounds.width > window.bounds.height { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertGreaterThan(window.bounds.width, window.bounds.height, "Capture the actual landscape scene")
        }
        let deadline = Date().addingTimeInterval(420)
        while app.page == .chats, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw NocturneError.timeout
    }
    func testModelsWorktreesChangesAndBothForgeEditsOverAuthenticatedTLS() async throws {
        let peer = try DeveloperWorkspacePeer(); try await peer.start()
        let engine = NocturneStreamingService()
        let client = WorkspaceConnection(identity: WorkspaceIdentity(certificate: engine.workspaceCertificate(), name: "Developer test") { engine.signWorkspaceChallenge($0) })
        defer { client.disconnect(); peer.stop() }
        try await client.connect(peer.invitation())
        let chat = ChatWorkspaceModel(connection: client)
        await chat.refresh(); await chat.open(try XCTUnwrap(chat.sessions.first))
        XCTAssertEqual(chat.options.first?.value, "model-fast")
        let option = try XCTUnwrap(chat.options.first); await chat.configure(option, value: "model-deep")
        XCTAssertEqual(chat.options.first?.value, "model-deep")
        let project = DeveloperWorkspaceModel(chat: chat); await project.refresh()
        XCTAssertEqual(project.snapshot?.branch, "feature/mobile")
        let file = try XCTUnwrap(project.snapshot?.changes.first)
        await project.loadDiff(file); XCTAssertTrue(project.content?.text.contains("+updated") == true)
        let loaded = await project.readFile(file.path), original = try XCTUnwrap(loaded)
        let saved = await project.saveFile(original, text: "edited from phone\n")
        XCTAssertEqual(saved?.text, "edited from phone\n"); XCTAssertEqual(peer.fileText, "edited from phone\n")
        let stale = await project.saveFile(original, text: "stale"); XCTAssertNil(stale); XCTAssertNotNil(project.error)
        for remote in ["origin", "azure"] {
            project.remote = remote; await project.refresh(); await project.loadPullRequests()
            XCTAssertEqual(project.snapshot?.forge?.kind, remote == "origin" ? .github : .azureDevOps)
            let request = try XCTUnwrap(project.pullRequests.first)
            await project.openPullRequest(request.number)
            XCTAssertEqual(project.prFiles.first?.path, file.path)
            let didSave = await project.savePullRequest(title: remote + " edited", body: "First line\n\n**Second line**")
            XCTAssertTrue(didSave); XCTAssertEqual(project.selectedPR?.body, "First line\n\n**Second line**")
            XCTAssertEqual(peer.lastEditRemote, remote)
        }
        await project.refresh()
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(rootView: VStack(spacing: 0) {
                ChatConfigurationBar(model: chat)
                DeveloperProjectPane(model: project, tab: .changes)
            })
            window.rootViewController = controller; window.makeKeyAndVisible(); defer { window.isHidden = true }
            try await Task.sleep(nanoseconds: 200_000_000); controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "Native model and changes workspace"; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await waitUntil { !project.busy }
        let created = await project.createWorktree(branch: "feature/new", base: "main"), worktree = try XCTUnwrap(created, project.error ?? "Worktree action did not return a checkout")
        await project.openWorktree(worktree)
        XCTAssertEqual(chat.selected?.directory, worktree.path)
        XCTAssertEqual(peer.lastOpenedWorktree, worktree.path)
        XCTAssertNil(project.snapshot); XCTAssertTrue(project.pullRequests.isEmpty)
        client.disconnect(); XCTAssertNil(chat.selected)
    }
}

@MainActor
private final class DeveloperWorkspacePeer {
    private let key: Data
    private let listener: NWListener
    private var channels: [UUID: SecureChannel] = [:]
    private var model = "model-fast"
    private var effort = "medium"
    private let demonstration: Bool
    private var revision = "file-v1"
    var fileText = "updated\n"
    var lastEditRemote: String?, lastOpenedWorktree: String?
    var lastPrompt: String?
    var holdPrompt = false
    private var promptReply: Packet?
    private weak var promptChannel: SecureChannel?
    private var prTitle = "Review mobile workspace", prBody = "Description"
    private var info = ChatSessionInfo(id: "developer-chat", title: "Build the mobile workflow", directory: "/Projects/App")
    private let change = GitChange(path: "Sources/App.swift", indexStatus: " ", worktreeStatus: "M")
    init(demonstration: Bool = false) throws { self.demonstration = demonstration; key = try SecureStore.randomKey(); listener = try NWListener(using: SecureTransport.parameters(secret: key), on: .any) }
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            listener.stateUpdateHandler = { state in
                guard !finished else { return }
                if case .ready = state { finished = true; continuation.resume() }
                if case .failed(let error) = state { finished = true; continuation.resume(throwing: error) }
            }; listener.start(queue: .main)
        }
    }
    func invitation() throws -> PairingInvitation { try PairingInvitation(host: "127.0.0.1", port: XCTUnwrap(listener.port).rawValue, name: "Developer Mac", secret: key) }
    private var options: [ChatConfigOption] { [ChatConfigOption(id: "model", name: "Model", category: "model", value: model, choices: [.init("model-fast", name: "Codex Fast"), .init("model-deep", name: "Codex Deep")]), ChatConfigOption(id: "effort", name: "Reasoning", category: "thought_level", value: effort, choices: [.init("low", name: "Low"), .init("medium", name: "Medium"), .init("high", name: "High")])] }
    private func pr(_ remote: String) -> PullRequestInfo {
        var value = PullRequestInfo(number: 41, title: demonstration ? "Add worktrees and native PR review" : prTitle, body: demonstration ? "Add an adaptive chat workspace with project-bound threads, file diffs and GitHub/Azure DevOps review.\n\n**Validation**\n- Authenticated workspace tests\n- Native iPhone and iPad layouts\n- Stale file and index protection" : prBody, author: "Developer", state: "open", draft: false, source: "feature/mobile", target: "main", url: remote == "azure" ? "https://dev.azure.com/acme/project/_git/app/pullrequest/41" : "https://github.com/acme/app/pull/41", updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2400)), reviewers: ["Reviewer · Approved"], checks: ["Build · success", "Client tests · success"])
        value.mergeable = true; value.labels = ["enhancement"]; value.additions = 247; value.deletions = 36; value.fileCount = 4
        return value
    }
    private func snapshot(_ remote: String) -> RepositorySnapshot {
        let forge = ForgeRepository(kind: remote == "azure" ? .azureDevOps : .github, host: remote == "azure" ? "dev.azure.com" : "github.com", organization: "acme", project: remote == "azure" ? "project" : nil, name: "app", webURL: remote == "azure" ? "https://dev.azure.com/acme/project/_git/app" : "https://github.com/acme/app")
        var result = RepositorySnapshot(root: info.directory, branch: "feature/mobile", head: "abcdef", base: "main", branches: ["main", "feature/mobile"], worktrees: [.init(path: info.directory, branch: "feature/mobile")], changes: [change], forge: forge)
        result.remotes = ["origin", "azure"]; return result
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID(), channel = SecureChannel(connection: connection, queue: .main), nonce = Data(repeating: 71, count: 32)
        channels[id] = channel; var authenticated = false
        channel.onPacket = { [weak self, weak channel] packet in
            guard let self, let channel else { return }; var reply = packet.reply()
            do {
                guard authenticated || [.hello, .authenticate].contains(packet.operation) else { throw NocturneError.permissionDenied }
                switch packet.operation {
                case .hello: reply.version = WorkspaceProtocol.version; reply.data = nonce
                case .authenticate:
                    _ = try WorkspaceIdentity.verify(certificate: XCTUnwrap(packet.certificate), signature: XCTUnwrap(packet.signature), challenge: channel.boundChallenge(nonce))
                    authenticated = true; reply.capabilities = [ChatProtocol.capability, DeveloperProtocol.capability, DeveloperProtocol.actionsCapability]
                case .chatProviders: reply.chatProviders = [.init(id: "codex", name: "Codex", available: true, detail: "Fixture")]
                case .chatList:
                    reply.chatPage = .init(sessions: [self.info] + (self.demonstration ? [.init(id: "demo-review", title: "Review Codex voice", directory: "/Projects/Nocturne", updatedAt: Date().addingTimeInterval(-3600)), .init(id: "demo-snoozed", title: "Polish the diff viewer", directory: "/Projects/Nocturne", updatedAt: Date().addingTimeInterval(-21600)), .init(id: "demo-settled", title: "Keep background audio connected", directory: "/Projects/Nocturne", updatedAt: Date().addingTimeInterval(-86400))] : []))
                case .chatLoad:
                    if self.demonstration { self.info = .init(id: packet.chatRequest?.sessionID ?? self.info.id, title: "Build the native chat workspace", directory: "/Projects/Nocturne", updatedAt: Date()) }
                    reply.chatHistory = .init(session: self.info, messages: self.demonstration ? self.demonstrationMessages : [])
                case .chatOptions: reply.chatOptions = self.options
                case .chatConfigure:
                    if packet.chatRequest?.configID == "effort" { self.effort = try XCTUnwrap(packet.chatRequest?.configValue) }
                    else { self.model = try XCTUnwrap(packet.chatRequest?.configValue) }; reply.chatOptions = self.options
                case .chatPrompt:
                    self.lastPrompt = packet.chatRequest?.text
                    if self.holdPrompt { self.promptReply = reply; self.promptChannel = channel; return }
                case .chatNew:
                    let path = packet.chatRequest?.worktreePath ?? self.info.directory; self.lastOpenedWorktree = path
                    self.info = .init(id: "worktree-chat", title: "New conversation", directory: path); reply.chatSession = self.info
                case .chatRepository:
                    let request = try XCTUnwrap(packet.repositoryRequest), remote = request.remote ?? "origin"
                    var response = RepositoryResponse()
                    switch request.action {
                    case .status, .stage, .unstage, .commit, .push: response.snapshot = self.snapshot(remote)
                    case .diff, .pullRequestDiff: response.content = .init(path: self.change.path, text: "@@ -1 +1 @@\n-original\n+updated\n")
                    case .readFile: response.content = .init(path: self.change.path, text: self.fileText, revision: self.revision)
                    case .saveFile:
                        guard request.revision == self.revision else { throw NocturneError.remote("The file changed. Reload before saving.") }
                        self.fileText = try XCTUnwrap(request.text); self.revision = "file-v2"
                        response.content = .init(path: self.change.path, text: self.fileText, revision: self.revision)
                    case .pullRequests: response.pullRequests = [self.pr(remote)]
                    case .pullRequest: response.pullRequest = self.pr(remote)
                    case .createPullRequest: response.pullRequest = self.pr(remote)
                    case .pullRequestActivity: response.activity = [.init(id: "review-1", author: "Reviewer", text: "Looks good. Please keep cancellation and background audio covered by the client tests.", createdAt: "2026-10-27T19:00:00Z", path: "Sources/Client/ChatWorkspace.swift")]
                    case .pullRequestFiles: response.changes = [self.change]
                    case .editPullRequest:
                        guard request.revision == self.pr(remote).revision else { throw NocturneError.remote("Refresh the PR") }
                        self.prTitle = try XCTUnwrap(request.title); self.prBody = try XCTUnwrap(request.text); self.lastEditRemote = remote
                        response.pullRequest = self.pr(remote)
                    case .createWorktree: response.worktree = .init(path: "/Projects/Worktrees/new", branch: request.branch ?? "")
                    }
                    reply.repositoryResponse = response
                case .ping: break
                default: throw NocturneError.invalidFrame
                }
            } catch { reply.error = error.localizedDescription }
            channel.send(reply)
            if packet.operation == .chatPrompt { self.sendCompletion(channel) }
        }
        channel.onClose = { [weak self] _ in self?.channels.removeValue(forKey: id) }; channel.start()
    }
    func stop() { listener.cancel(); Array(channels.values).forEach { $0.cancel() }; channels = [:] }
    func finishPrompt() { if let channel = promptChannel, let reply = promptReply { channel.send(reply); sendCompletion(channel) }; promptReply = nil; promptChannel = nil }
    private func sendCompletion(_ channel: SecureChannel) {
        var event = Packet(.chatEvent)
        event.chatEvent = .init(providerID: "codex", sessionID: info.id, kind: .message, message: .init(id: UUID().uuidString, role: .assistant, text: "## Review guide\n\nStart with the workspace layout, then check the thread binding and cancellation.\n\n```swift\nChatWorkspace(model: chat, connection: connection, voice: voice, connect: {})\n```\n\nVerify iPhone and iPad layouts and confirm unrelated staged files stay untouched."))
        channel.send(event); event.chatEvent = .init(providerID: "codex", sessionID: info.id, kind: .completed); channel.send(event)
    }
    private var demonstrationMessages: [ChatMessage] { [
        .init(id: "demo-user", role: .user, text: "Make the chat workspace work well on iPad, with worktrees and pull request review."),
        .init(id: "demo-response", role: .assistant, text: "The workspace now has a thread sidebar, a focused conversation canvas and a composer that stays within reach. Model and reasoning choices come from your connected agent."),
        .init(id: "demo-tool-1", role: .tool, text: "git diff --stat\nSources/Client/ChatWorkspace.swift | 48 +++++++++\nSources/Client/ChatSidebar.swift | 62 +++++++++++++"),
        .init(id: "demo-tool-2", role: .tool, text: "swift test --filter ChatNavigationTests\n3 tests passed, 0 failures"),
        .init(id: "demo-result", role: .assistant, text: "**Ready to review**\n\nOpen **Git → Review changes** for the latest agent diff or staged files. The pull request workspace has Overview, Guide and Activity tabs.\n\n```swift\nlet project = DeveloperWorkspaceModel(chat: chat)\nawait project.refresh()\n```\n\nYour Codex voice connection remains attached to the selected thread.")
    ] }
}
