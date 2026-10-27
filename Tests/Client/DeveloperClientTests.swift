import XCTest
import UIKit
import SwiftUI
import Network
import NocturneKit
@testable import Nocturne

@MainActor
final class DeveloperClientTests: XCTestCase {
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
        let created = await project.createWorktree(branch: "feature/new", base: "main"), worktree = try XCTUnwrap(created)
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
    private var revision = "file-v1"
    var fileText = "updated\n"
    var lastEditRemote: String?, lastOpenedWorktree: String?
    private var prTitle = "Review mobile workspace", prBody = "Description"
    private var info = ChatSessionInfo(id: "developer-chat", title: "Build the mobile workflow", directory: "/Projects/App")
    private let change = GitChange(path: "Sources/App.swift", indexStatus: " ", worktreeStatus: "M")
    init() throws { key = try SecureStore.randomKey(); listener = try NWListener(using: SecureTransport.parameters(secret: key), on: .any) }
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
    private var options: [ChatConfigOption] { [ChatConfigOption(id: "model", name: "Model", category: "model", value: model, choices: [.init("model-fast", name: "Fast"), .init("model-deep", name: "Deep")])] }
    private func pr(_ remote: String) -> PullRequestInfo {
        PullRequestInfo(number: 41, title: prTitle, body: prBody, author: "Developer", state: "open", draft: false, source: "feature/mobile", target: "main", url: remote == "azure" ? "https://dev.azure.com/acme/project/_git/app/pullrequest/41" : "https://github.com/acme/app/pull/41", reviewers: ["Reviewer"], checks: ["Build · success"])
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
                    authenticated = true; reply.capabilities = [ChatProtocol.capability, DeveloperProtocol.capability]
                case .chatProviders: reply.chatProviders = [.init(id: "codex", name: "Codex", available: true, detail: "Fixture")]
                case .chatList: reply.chatPage = .init(sessions: [self.info])
                case .chatLoad: reply.chatHistory = .init(session: self.info, messages: [])
                case .chatOptions: reply.chatOptions = self.options
                case .chatConfigure:
                    self.model = try XCTUnwrap(packet.chatRequest?.configValue); reply.chatOptions = self.options
                case .chatNew:
                    let path = try XCTUnwrap(packet.chatRequest?.worktreePath); self.lastOpenedWorktree = path
                    self.info = .init(id: "worktree-chat", title: "New worktree", directory: path); reply.chatSession = self.info
                case .chatRepository:
                    let request = try XCTUnwrap(packet.repositoryRequest), remote = request.remote ?? "origin"
                    var response = RepositoryResponse()
                    switch request.action {
                    case .status, .stage, .unstage: response.snapshot = self.snapshot(remote)
                    case .diff, .pullRequestDiff: response.content = .init(path: self.change.path, text: "@@ -1 +1 @@\n-original\n+updated\n")
                    case .readFile: response.content = .init(path: self.change.path, text: self.fileText, revision: self.revision)
                    case .saveFile:
                        guard request.revision == self.revision else { throw NocturneError.remote("The file changed. Reload before saving.") }
                        self.fileText = try XCTUnwrap(request.text); self.revision = "file-v2"
                        response.content = .init(path: self.change.path, text: self.fileText, revision: self.revision)
                    case .pullRequests: response.pullRequests = [self.pr(remote)]
                    case .pullRequest: response.pullRequest = self.pr(remote)
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
        }
        channel.onClose = { [weak self] _ in self?.channels.removeValue(forKey: id) }; channel.start()
    }
    func stop() { listener.cancel(); Array(channels.values).forEach { $0.cancel() }; channels = [:] }
}
