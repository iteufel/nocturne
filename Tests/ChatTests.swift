import XCTest
import Combine
import Darwin
import NocturneKit
import NocturneVoice
@testable import NocturneHostKit

@MainActor
final class ChatTests: XCTestCase {
    private var root: URL!
    private var agents: [ChatAgentSession] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Nocturne-chats-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.fixture.write(to: root.appendingPathComponent("agent.py"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws {
        agents.forEach { $0.close() }; agents = []
        try? FileManager.default.removeItem(at: root)
    }
    private func configuration(_ mode: String = "codex", id: String = "codex") -> ChatAgentConfiguration {
        ChatAgentConfiguration(id: id, name: mode, transport: mode.hasPrefix("acp") ? .acp : .codex,
            executable: "/usr/bin/python3", arguments: ["-u", root.appendingPathComponent("agent.py").path, mode, root.path])
    }
    private func agent(_ mode: String = "codex") async throws -> ChatAgentSession {
        let agent = try ChatAgentSession(configuration: configuration(mode), directory: root, chatGPTOnly: mode.hasPrefix("voice")); agents.append(agent)
        try await agent.initialize(); return agent
    }
    func testSupervisorPersistsThreadAndRoutesRealDynamicToolsAndWorkerApprovals() async throws {
        let suite = "Nocturne-supervisor-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ChatSupervisorService(configurations: [configuration(), configuration("acp", id: "claude")], directory: root, defaults: defaults)
        defer { service.reset() }
        let agent = try await agent()
        agent.supervisorSession = { service.isSupervisor($0, provider: "codex") }
        agent.supervisorTool = { try await service.call($1, supervisorProvider: "codex", supervisorID: $0) }
        let page = try await service.open(using: agent)
        XCTAssertTrue(page.session.isSupervisor == true)
        let reopened = try await service.open(using: agent)
        XCTAssertEqual(reopened.session.id, page.session.id)
        let restored = ChatSupervisorService(configurations: [configuration()], directory: root, defaults: defaults)
        XCTAssertTrue(restored.isSupervisor(page.session.id, provider: "codex"))
        var events: [ChatEvent] = [], workerEvents: [ChatEvent] = []
        agent.emit = { events.append($0) }
        let listener = UUID(); service.subscribe(listener) { workerEvents.append($0) }
        defer { service.unsubscribe(listener) }
        try await agent.prompt(page.session.id, text: "list agents")
        try await waitUntil { events.contains { $0.kind == .completed } }
        XCTAssertTrue(events.contains { $0.message?.text.contains("claude") == true }, "The actual RPC dynamic tool response reaches the supervisor")
        let started = try await service.call(["action": "send", "sessionID": "legacy", "text": "run"], supervisorProvider: "codex", supervisorID: page.session.id)
        XCTAssertTrue(started.contains("Started"))
        try await waitUntil { !service.permissions(for: page.session.id).isEmpty }
        let permission = try XCTUnwrap(service.permissions(for: page.session.id).first)
        XCTAssertTrue(workerEvents.contains { $0.kind == .permission && $0.sessionID == page.session.id })
        XCTAssertFalse(try service.approve(permission.id, option: "accept", supervisor: "another-thread"))
        XCTAssertTrue(try service.approve(permission.id, option: "accept", supervisor: page.session.id))
        try await waitUntil { workerEvents.contains { $0.message?.text.contains("Completed") == true } }
        XCTAssertTrue(service.permissions(for: page.session.id).isEmpty)
        let list = try await service.call(["action": "list"], supervisorProvider: "codex", supervisorID: page.session.id)
        XCTAssertTrue(list.contains("Completed"))
        _ = try await service.call(["action": "send", "sessionID": "legacy", "text": "wait"], supervisorProvider: "codex", supervisorID: page.session.id)
        _ = try await service.call(["action": "stop", "sessionID": "legacy"], supervisorProvider: "codex", supervisorID: page.session.id)
        try await waitUntil { workerEvents.contains { $0.message?.text.contains("Stopped") == true } }
    }
    func testSupervisorCreatesProjectWorkersAndRejectsExternalActiveTargets() async throws {
        let suite = "Nocturne-supervisor-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ChatSupervisorService(configurations: [configuration()], directory: root, defaults: defaults)
        defer { service.reset() }
        let agent = try await agent(), page = try await service.open(using: agent)
        let created = try await service.call(["action": "create", "sourceSessionID": "legacy", "text": "wait"], supervisorProvider: "codex", supervisorID: page.session.id)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(created.utf8)) as? [String: String])
        XCTAssertEqual(result["directory"], root.path); XCTAssertEqual(result["sessionID"], "new")
        for arguments in [["action": "send", "sessionID": "external-active", "text": "run"], ["action": "stop", "sessionID": "external-active"], ["action": "send", "sessionID": page.session.id, "text": "run"]] {
            do { _ = try await service.call(arguments, supervisorProvider: "codex", supervisorID: page.session.id); XCTFail("Unsafe target accepted") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        let workerPID = try XCTUnwrap(Int32(try String(contentsOf: root.appendingPathComponent("agent.pid"))))
        service.reset()
        try await waitUntil { kill(workerPID, 0) != 0 }
    }
    func testSupervisorOpensOverAuthenticatedConnectionAndOlderPagesCannotSwitchThreads() async throws {
        let key = try SecureStore.randomKey(), identity = try TestDeviceIdentity()
        let store = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let server = try WorkspaceServer(folder: root, name: "Supervisor Mac", devices: store, permissions: .init(chats: true), chatAgents: [configuration("modern")])
        let client = WorkspaceConnection(identity: identity.identity()), model = ChatWorkspaceModel(connection: client)
        defer { client.disconnect(); server.stop() }
        let ready = expectation(description: "Ready"); var signalled = false
        server.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; ready.fulfill() } }
        try server.start(secret: key, port: 0); await fulfillment(of: [ready], timeout: 5)
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: XCTUnwrap(server.listeningPort), name: "Supervisor Mac", secret: key, enrollmentToken: store.createInvitation()))
        await model.refresh(); XCTAssertTrue(model.supportsSupervisor)
        await model.openSupervisor(); XCTAssertNil(model.error); XCTAssertTrue(model.selected?.isSupervisor == true)
        let id = try XCTUnwrap(model.selected?.id)
        await model.open(ChatSessionInfo(id: "other-thread", title: "Other", directory: root.path), older: true)
        XCTAssertEqual(model.selected?.id, id)
        try await model.prepareVoice()
        try await model.prepareVoice() // Retrying after a canceled voice start is harmless.
        model.draft = "list agents"; await model.send()
        try await waitUntil { !model.responding }
        XCTAssertTrue(model.messages.contains { $0.text.contains("providers") })
        await model.openSupervisor(); XCTAssertEqual(model.selected?.id, id)
    }
    func testNewCodexThreadCanOpenBeforeItsFirstTurnIsMaterialized() async throws {
        let agent = try await agent("unmaterialized")
        let session = try await agent.create(supervisor: true)
        let page = try await agent.load(session.id, cursor: nil, archived: false)
        XCTAssertEqual(page.session.id, session.id); XCTAssertTrue(page.messages.isEmpty); XCTAssertTrue(page.canPrompt)
    }
    func testCodexListsEverySourceAndModelProviderAndPagesArchivedHistory() async throws {
        let agent = try await agent()
        let first = try await agent.list(cursor: nil, archived: false)
        XCTAssertEqual(first.sessions.count, 40)
        let second = try await agent.list(cursor: XCTUnwrap(first.nextCursor), archived: false)
        XCTAssertEqual(second.sessions.count, 5)
        let third = try await agent.list(cursor: XCTUnwrap(second.nextCursor), archived: false)
        XCTAssertEqual(third.sessions.map(\.id), ["remote"]); XCTAssertNil(third.nextCursor)
        let archived = try await agent.list(cursor: nil, archived: true)
        XCTAssertEqual(archived.sessions.first?.title, "Archived")
        let history = try await agent.load("legacy", cursor: nil, archived: true)
        XCTAssertFalse(history.canPrompt)
        XCTAssertEqual(history.messages.first?.text, "Hello")
        XCTAssertEqual(history.messages.filter { $0.role == .assistant }.map(\.text).joined(), String(repeating: "🌙", count: 10_000))
        XCTAssertFalse(history.messages.contains { $0.text.contains("private reasoning") })
        XCTAssertLessThan(try JSONEncoder().encode(history).count, 200_000)
    }
    func testCodexPaginatedItemsStayInOrderAndRejectStaleCursors() async throws {
        let agent = try await agent("modern")
        let recent = try await agent.load("modern", cursor: nil, archived: false)
        XCTAssertEqual(recent.messages.map(\.text), ["second", "third"])
        let older = try await agent.load("modern", cursor: XCTUnwrap(recent.nextCursor), archived: false)
        XCTAssertEqual(older.messages.map(\.text), ["first"]); XCTAssertNil(older.nextCursor)
        do { _ = try await agent.load("modern", cursor: recent.nextCursor, archived: false); XCTFail("Stale cursor accepted") }
        catch { XCTAssertEqual(error as? NocturneError, .invalidFrame) }
    }
    func testCodexApprovalStreamingAndCompletion() async throws {
        let agent = try await agent()
        _ = try await agent.load("legacy", cursor: nil, archived: false)
        let permission = expectation(description: "Command approval"), completed = expectation(description: "Completed")
        var pending: ChatPermission?, text = "", diff: RepositoryText?
        agent.emit = { event in
            if event.kind == .permission { pending = event.permission; permission.fulfill() }
            if event.kind == .delta { text += event.message?.text ?? "" }
            if event.kind == .completed { completed.fulfill() }
            if event.kind == .diffUpdated { diff = event.diff }
        }
        try await agent.prompt("legacy", text: "run")
        await fulfillment(of: [permission], timeout: 5)
        let approval = try XCTUnwrap(pending)
        XCTAssertTrue(approval.detail.contains("pwd"))
        do { try agent.approve(approval.id, option: "invented", session: "legacy"); XCTFail("Invalid permission option accepted") } catch {}
        XCTAssertThrowsError(try agent.approve(approval.id, option: "accept", session: "wrong-session"))
        XCTAssertNotNil(approval.expiresAt)
        try agent.approve(approval.id, option: "accept", session: "legacy")
        XCTAssertThrowsError(try agent.approve(approval.id, option: "accept", session: "legacy"))
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(diff?.text.contains("+agent edit") == true)
        XCTAssertEqual(text, "Hello world")
    }
    func testACPReplaysChunksAndSupportsPermissionAndCancellation() async throws {
        let agent = try await agent("acp")
        let list = try await agent.list(cursor: nil, archived: false)
        let id = try XCTUnwrap(list.sessions.first?.id)
        let history = try await agent.load(id, cursor: nil, archived: false)
        XCTAssertEqual(history.messages.map(\.text), ["Hi", "Hello", "Read file · completed"])
        let approval = expectation(description: "ACP approval")
        var permission: ChatPermission?, text = ""
        agent.emit = { event in
            if event.kind == .permission { permission = event.permission; approval.fulfill() }
            if event.kind == .delta { text += event.message?.text ?? "" }
        }
        let reply = Task { try await agent.prompt(id, text: "run") }
        await fulfillment(of: [approval], timeout: 5)
        try agent.approve(XCTUnwrap(permission).id, option: "allow", session: id)
        try await reply.value
        XCTAssertEqual(text, "Reply done")
        let started = expectation(description: "Started"), stopped = expectation(description: "Stopped")
        agent.emit = { event in
            if event.kind == .delta { started.fulfill() }
            if event.kind == .completed { XCTAssertEqual(event.detail, "Stopped"); stopped.fulfill() }
        }
        let waiting = Task { try await agent.prompt(id, text: "wait") }
        await fulfillment(of: [started], timeout: 5)
        try await agent.cancel(id); try await waiting.value
        await fulfillment(of: [stopped], timeout: 5)
    }
    func testACPWithoutHistoryCapabilitiesDoesNotCallUnsupportedMethods() async throws {
        let agent = try await agent("acp-minimal")
        let first = try await agent.list(cursor: nil, archived: false)
        XCTAssertTrue(first.sessions.isEmpty); XCTAssertNotNil(first.notice)
        let created = try await agent.create()
        let sessions = try await agent.list(cursor: nil, archived: false)
        XCTAssertEqual(sessions.sessions.map(\.id), [created.id])
    }
    func testMalformedStdoutAndEarlyExitFailPendingRequests() async throws {
        for mode in ["bad", "exit"] {
            do { _ = try await agent(mode); XCTFail("Invalid process succeeded") } catch {}
        }
    }
    func testAuthenticatedChatFlowRevocationAndDisconnectResetTheClient() async throws {
        let key = try SecureStore.randomKey(), identity = try TestDeviceIdentity()
        let store = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let server = try WorkspaceServer(folder: root, name: "Chat Mac", devices: store, permissions: .init(chats: true), chatAgents: [configuration()])
        let client = WorkspaceConnection(identity: identity.identity()), model = ChatWorkspaceModel(connection: client)
        defer { client.disconnect(); server.stop() }
        let ready = expectation(description: "Listener ready")
        var signalled = false
        server.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; ready.fulfill() } }
        try server.start(secret: key, port: 0)
        await fulfillment(of: [ready], timeout: 5)
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: XCTUnwrap(server.listeningPort), name: "Chat Mac", secret: key, enrollmentToken: store.createInvitation()))
        XCTAssertTrue(client.capabilities.contains(ChatProtocol.capability)); XCTAssertFalse(client.capabilities.contains("terminal"))
        await model.refresh(); XCTAssertNil(model.error); XCTAssertEqual(model.sessions.count, 40)
        await model.open(try XCTUnwrap(model.sessions.first)); XCTAssertTrue(model.canPrompt)
        model.draft = "run"; await model.send()
        try await waitUntil { !model.permissions.isEmpty }
        let permission = try XCTUnwrap(model.permissions.first)
        XCTAssertEqual(model.activity(for: try XCTUnwrap(model.selected?.id))?.phase, .waiting)
        await model.decide(permission, option: try XCTUnwrap(permission.options.first))
        try await waitUntil { !model.responding }
        XCTAssertEqual(model.activity(for: try XCTUnwrap(model.selected?.id))?.phase, .completed)
        XCTAssertTrue(model.messages.contains { $0.text == "Hello world" })
        XCTAssertEqual(model.messages.filter { $0.role == .user && $0.text == "run" }.count, 1)
        model.draft = "wait"; await model.send(); try await waitUntil { model.responding }
        let pidText = try String(contentsOf: root.appendingPathComponent("agent.pid"), encoding: .utf8)
        let childPID = try XCTUnwrap(Int32(pidText))
        server.updatePermissions(.init())
        try await waitUntil { !model.responding && model.error != nil }
        try await waitUntil { kill(childPID, 0) != 0 }
        do { _ = try await client.request(Packet(.chatProviders)); XCTFail("Revoked chats remained accessible") }
        catch { XCTAssertEqual(error as? NocturneError, .remote(NocturneError.permissionDenied.localizedDescription)) }
        client.disconnect()
        XCTAssertTrue(model.messages.isEmpty); XCTAssertTrue(model.providers.isEmpty); XCTAssertTrue(model.activities.isEmpty); XCTAssertNil(model.selected)
    }
    func testChatAccessDefaultsOff() async throws {
        let session = ChatHostSession(configurations: [configuration()], directory: root, enabled: false)
        defer { session.close() }
        let denied = expectation(description: "Denied")
        session.handle(Packet(.chatProviders)) { packet in
            XCTAssertNotNil(packet.error); XCTAssertNil(packet.chatProviders); denied.fulfill()
        }
        await fulfillment(of: [denied], timeout: 5)
    }
    func testProviderSwitchingClearsHistoryAndKeepsConversationIDsSeparate() async throws {
        let key = try SecureStore.randomKey(), identity = try TestDeviceIdentity()
        let store = try WorkspaceDeviceStore(url: root.appendingPathComponent("switch-devices.json"))
        let server = try WorkspaceServer(folder: root, name: "Mac", devices: store, permissions: .init(chats: true),
            chatAgents: [configuration(), configuration("acp", id: "claude")])
        let client = WorkspaceConnection(identity: identity.identity()), model = ChatWorkspaceModel(connection: client)
        defer { client.disconnect(); server.stop() }
        let ready = expectation(description: "Switch listener ready"); var signalled = false
        server.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; ready.fulfill() } }
        try server.start(secret: key, port: 0); await fulfillment(of: [ready], timeout: 5)
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: XCTUnwrap(server.listeningPort), name: "Mac", secret: key, enrollmentToken: store.createInvitation()))
        await model.refresh(); await model.open(try XCTUnwrap(model.sessions.first))
        XCTAssertEqual(model.providerID, "codex"); XCTAssertFalse(model.messages.isEmpty)
        await model.chooseProvider("claude")
        XCTAssertNil(model.error); XCTAssertTrue(model.messages.isEmpty); XCTAssertNil(model.selected)
        XCTAssertEqual(model.sessions.map(\.id), ["acp-chat"])
        await model.open(try XCTUnwrap(model.sessions.first))
        XCTAssertEqual(model.messages.map(\.text), ["Hi", "Hello", "Read file · completed"])
        client.chatEvents.send(ChatEvent(providerID: "codex", sessionID: "acp-chat", kind: .delta,
            message: ChatMessage(id: "stale", role: .assistant, text: "Wrong provider")))
        XCTAssertFalse(model.messages.contains { $0.id == "stale" })
        await model.chooseProvider("codex")
        XCTAssertEqual(model.sessions.count, 40); XCTAssertTrue(model.messages.isEmpty); XCTAssertNil(model.error)
    }
    func testACPTemporaryConversationsKeepTheirOwnTranscripts() async throws {
        let agent = try await agent("acp-minimal")
        agent.emit = { event in
            if let permission = event.permission { try? agent.approve(permission.id, option: "allow", session: event.sessionID) }
        }
        let first = try await agent.create(); try await agent.prompt(first.id, text: "first chat")
        let second = try await agent.create(); try await agent.prompt(second.id, text: "second chat")
        XCTAssertNotEqual(first.id, second.id)
        let restored = try await agent.load(first.id, cursor: nil, archived: false)
        XCTAssertTrue(restored.messages.contains { $0.text == "first chat" })
        XCTAssertFalse(restored.messages.contains { $0.text == "second chat" })
        agent.emit = nil
    }
    func testMessagePartsPreserveUnicodeAndFitWorkspaceFrames() throws {
        let text = String(repeating: "👩🏽‍💻\n\"\\", count: 20_000)
        let message = ChatMessage(id: "long", role: .assistant, text: text)
        XCTAssertEqual(message.parts.map(\.text).joined(), text)
        for part in message.parts {
            var packet = Packet(.chatEvent); packet.chatEvent = ChatEvent(providerID: "codex", sessionID: "chat", kind: .message, message: part)
            XCTAssertLessThan(try FrameCodec.encode(packet).count, WorkspaceProtocol.maximumFrame)
        }
    }
    func testInstalledCodexHistoryReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_CODEX"] == "1" else { throw XCTSkip("Opt-in read-only check against the installed Codex.") }
        let agent = try ChatAgentSession(configuration: ChatAgentConfiguration.defaults[0], directory: root); agents.append(agent)
        try await agent.initialize()
        let page = try await agent.list(cursor: nil, archived: false)
        guard let first = page.sessions.first else { throw XCTSkip("No local Codex conversations are available.") }
        let history = try await agent.load(first.id, cursor: nil, archived: false)
        XCTAssertEqual(history.session.id, first.id)
        XCTAssertFalse(history.messages.isEmpty)
    }
    private static let offerSDP = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=fingerprint:sha-256 fixture\r\n"
    func testCodexWebRTCWaitsForAnswerAndKeepsTranscriptsAndApprovalsThreaded() async throws {
        let agent = try await agent("voice")
        var events: [ChatVoiceEvent] = [], texts: [String: String] = [:], pending: ChatPermission?
        let approval = expectation(description: "Spoken task approval"), completed = expectation(description: "Agent answer")
        agent.emitVoice = { events.append($0) }
        agent.emit = { event in
            if let permission = event.permission { pending = permission; approval.fulfill() }
            if event.kind == .completed { completed.fulfill() }
            if let message = event.message {
                if event.kind == .delta { texts[message.id, default: ""] += message.text } else { texts[message.id] = message.text }
            }
        }
        try await agent.startVoice("legacy", lease: "voice-lease", sdp: Self.offerSDP)
        XCTAssertEqual(events.first?.kind, .started)
        XCTAssertEqual(events.first { $0.kind == .answer }?.sdp, Self.offerSDP)
        await fulfillment(of: [approval], timeout: 5)
        try agent.approve(XCTUnwrap(pending).id, option: "accept", session: "legacy")
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(texts["voice:spoken-user"], "Run tests")
        XCTAssertEqual(texts.values.filter { $0 == "Run tests" }.count, 1)
        XCTAssertEqual(texts["voice:spoken-answer"], "Running the tests.")
        XCTAssertTrue(events.contains { $0.kind == .speechStarted })
        try await agent.stopVoice(lease: "voice-lease")
        XCTAssertEqual(events.last?.kind, .closed)
        XCTAssertFalse(events.contains { $0.kind == .failed })
    }
    func testVoiceCanContinueWhenAnotherClientOwnsTheThread() async throws {
        let agent = try await agent("voice-writer")
        let session = try await agent.prepareVoiceSession("legacy", allowContinuation: true)
        XCTAssertEqual(session.id, "voice-continuation"); XCTAssertEqual(session.title, "Voice · A conversation")
        XCTAssertEqual(session.directory, root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("voice-started").path))
        var events: [ChatVoiceEvent] = []
        agent.emitVoice = { events.append($0) }
        try await agent.startVoice(session.id, lease: "lease", sdp: Self.offerSDP)
        XCTAssertTrue(events.contains { $0.kind == .answer && $0.sessionID == session.id })
        XCTAssertTrue(events.allSatisfy { $0.sessionID == session.id })
        try await agent.stopVoice(lease: "lease")
        let forks = try String(contentsOf: root.appendingPathComponent("voice-forked"), encoding: .utf8)
        XCTAssertEqual(forks, "legacy\n", "Starting the prepared call must not fork a second time")
    }
    func testVoicePreflightNeverForksForOtherErrorsOrTheSupervisor() async throws {
        for mode in ["voice-resume-failure", "voice-writer"] {
            let agent = try await agent(mode)
            if mode == "voice-writer" { agent.supervisorSession = { $0 == "legacy" } }
            do { _ = try await agent.prepareVoiceSession("legacy", allowContinuation: true); XCTFail("Unexpected voice preparation") }
            catch { XCTAssertTrue(error.localizedDescription.contains(mode == "voice-writer" ? "supervisor is open" : "fixture resume failure")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("voice-forked").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("voice-started").path))
        }
    }
    func testHostKeepsPreparedVoiceWriterUntilCallStarts() async throws {
        let host = ChatHostSession(configurations: [configuration("voice-writer")], directory: root, enabled: true)
        defer { host.close() }
        func send(_ packet: Packet) async -> Packet {
            await withCheckedContinuation { continuation in
                host.handle(packet) { if $0.id == packet.id { continuation.resume(returning: $0) } }
            }
        }
        var open = Packet(.chatVoiceOpen); open.chatRequest = ChatRequest(providerID: "codex", sessionID: "legacy")
        let prepared = await send(open); XCTAssertNil(prepared.error)
        let session = try XCTUnwrap(prepared.chatSession)
        var start = Packet(.chatVoiceStart); start.chatRequest = ChatRequest(providerID: "codex", sessionID: session.id); start.chatRequest?.voiceSDP = Self.offerSDP
        let started = await send(start); XCTAssertNil(started.error)
        XCTAssertEqual(started.chatVoiceEvent?.sessionID, session.id)
        var stop = Packet(.chatVoiceStop); stop.chatRequest = start.chatRequest; stop.chatRequest?.voiceID = started.chatVoiceEvent?.voiceID
        let stopped = await send(stop); XCTAssertNil(stopped.error)
    }
    func testVoiceRejectsSignedOutAndAPIKeyAccountsBeforeCallCreation() async throws {
        for mode in ["voice-signed-out", "voice-platform-key", "voice-platform-provider"] {
            let agent = try await agent(mode)
            do { try await agent.startVoice("legacy", lease: "lease", sdp: Self.offerSDP); XCTFail("Non-ChatGPT login accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("ChatGPT")) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("voice-started").path))
    }
    func testAuthenticatedVoiceUsesDedicatedConnectionAndRevocationClosesIt() async throws {
        let key = try SecureStore.randomKey(), identity = try TestDeviceIdentity()
        let store = try WorkspaceDeviceStore(url: root.appendingPathComponent("voice-devices.json"))
        let server = try WorkspaceServer(folder: root, name: "Voice Mac", devices: store, permissions: .init(chats: true), chatAgents: [configuration("voice")])
        let client = WorkspaceConnection(identity: identity.identity()), model = ChatWorkspaceModel(connection: client)
        let voice = client.mediaConnection()
        var subscription: AnyCancellable?
        defer { subscription?.cancel(); model.detachVoice(voice); voice.disconnect(); client.disconnect(); server.stop() }
        let ready = expectation(description: "Voice listener"); var signalled = false
        server.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; ready.fulfill() } }
        try server.start(secret: key, port: 0); await fulfillment(of: [ready], timeout: 5)
        let invitation = try PairingInvitation(host: "127.0.0.1", port: XCTUnwrap(server.listeningPort), name: "Voice Mac", secret: key, enrollmentToken: store.createInvitation())
        try await client.connect(invitation)
        await model.refresh(); await model.open(try XCTUnwrap(model.sessions.first))
        XCTAssertTrue(model.supportsVoice)
        try model.attachVoice(voice)
        await model.newConversation(); XCTAssertEqual(model.selected?.id, "legacy")
        try await voice.connect(invitation, restoreTerminalSessions: false)
        var events: [ChatVoiceEvent] = []
        subscription = voice.chatVoiceEvents.sink { events.append($0) }
        var start = Packet(.chatVoiceStart); start.chatRequest = ChatRequest(providerID: "codex", sessionID: "legacy"); start.chatRequest?.voiceSDP = Self.offerSDP
        let response = try await voice.request(start)
        let lease = try XCTUnwrap(response.chatVoiceEvent?.voiceID)
        XCTAssertEqual(events.first { $0.kind == .answer }?.sdp, Self.offerSDP)
        var request = ChatRequest(providerID: "codex", sessionID: "legacy"); request.voiceID = lease
        try await waitUntil { !model.permissions.isEmpty }
        let permission = try XCTUnwrap(model.permissions.first)
        await model.decide(permission, option: try XCTUnwrap(permission.options.first))
        try await waitUntil { model.messages.contains { $0.text == "Running the tests." } }
        XCTAssertNil(model.error)
        var pulse = Packet(.chatVoiceHeartbeat); pulse.chatRequest = request
        _ = try await voice.request(pulse)
        pulse.chatRequest?.voiceID = "stale-voice"
        do { _ = try await voice.request(pulse); XCTFail("A stale lease controlled the call") } catch {}
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("agent.pid"), encoding: .utf8)))
        server.updatePermissions(.init())
        try await waitUntil { events.contains { $0.kind == .failed } && kill(pid, 0) != 0 }
        _ = try await client.request(Packet(.ping)); XCTAssertEqual(client.state, .connected)
    }
    func testInstalledCodexVoiceCatalogReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_CODEX_VOICE"] == "1" else { throw XCTSkip("Opt-in check of installed Codex voice protocol; no microphone or inference.") }
        let rpc = try AgentRPC(configuration: ChatAgentConfiguration.defaults[0], directory: root, chatGPTOnly: true); defer { rpc.close() }
        _ = try await rpc.call("initialize", ["clientInfo": ["name": "nocturne", "version": "1.0"], "capabilities": ["experimentalApi": true]])
        rpc.notify("initialized")
        let response = try await rpc.call("thread/realtime/listVoices")
        XCTAssertNotNil(response["voices"])
    }
    func testInstalledCodexWebRTCWithChatGPTSignIn() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_CODEX_WEBRTC"] == "1" else { throw XCTSkip("Opt-in real WebRTC SDP exchange with Codex-managed ChatGPT login. No microphone capture.") }
        let peer = CodexVoicePeer(); defer { peer.stop() }
        let offer = try await peer.offer()
        let agent = try ChatAgentSession(configuration: ChatAgentConfiguration.defaults[0], directory: root, chatGPTOnly: true); agents.append(agent)
        try await agent.initialize()
        let session = try await agent.create(ephemeral: true)
        var answer: String?
        agent.emitVoice = { event in if event.kind == .answer { answer = event.sdp } }
        let lease = UUID().uuidString
        try await agent.startVoice(session.id, lease: lease, sdp: offer.sdp)
        try ChatVoice.validateSDP(XCTUnwrap(answer))
        try await agent.stopVoice(lease: lease)
    }
    func testVoiceStopAcknowledgesCleanupAndHeartbeatExpiryTerminatesProvider() async throws {
        let host = ChatHostSession(configurations: [configuration("voice")], directory: root, enabled: true)
        defer { host.close() }
        var events: [ChatVoiceEvent] = []
        func send(_ packet: Packet) async -> Packet {
            await withCheckedContinuation { continuation in
                host.handle(packet) { response in
                    if let event = response.chatVoiceEvent, response.operation == .chatVoiceEvent { events.append(event) }
                    if response.id == packet.id { continuation.resume(returning: response) }
                }
            }
        }
        var start = Packet(.chatVoiceStart); start.chatRequest = ChatRequest(providerID: "codex", sessionID: "legacy"); start.chatRequest?.voiceSDP = Self.offerSDP
        let started = await send(start), lease = try XCTUnwrap(started.chatVoiceEvent?.voiceID)
        var stop = Packet(.chatVoiceStop); stop.chatRequest = start.chatRequest; stop.chatRequest?.voiceID = lease
        let stopped = await send(stop); XCTAssertNil(stopped.error); XCTAssertTrue(events.contains { $0.kind == .closed })
        let second = await send(start); XCTAssertNil(second.error)
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("agent.pid"), encoding: .utf8)))
        host.expireVoice(now: ProcessInfo.processInfo.systemUptime + ChatVoice.leaseTimeout + 1)
        try await waitUntil { events.contains { $0.kind == .failed } && kill(pid, 0) != 0 }
    }
    func testProviderCloseDrainsQueuedWritesWithoutUsingClosedHandles() async throws {
        for _ in 0..<20 {
            let rpc = try AgentRPC(configuration: configuration("voice"), directory: root, chatGPTOnly: true)
            _ = try await rpc.call("voice/testEnvironment")
            for _ in 0..<8 { rpc.notify("initialized") }
            rpc.close()
            try await rpc.waitUntilExit()
        }
    }
    func testProviderClosedStdinFailsRequestWithoutTerminatingHost() async throws {
        let childFlag = "NOCTURNE_TEST_AGENT_SIGPIPE_CHILD"
        if ProcessInfo.processInfo.environment[childFlag] == "1" {
            // Run with the default signal action, regardless of the test launcher's environment.
            // Only this isolated child may be terminated if the regression returns.
            let previous = signal(SIGPIPE, SIG_DFL)
            defer { signal(SIGPIPE, previous) }
            let rpc = try AgentRPC(configuration: configuration(), directory: root)
            defer { rpc.close() }
            _ = try await rpc.call("fixture/closeStdin")
            do {
                _ = try await rpc.call("initialize", timeout: 2)
                XCTFail("A provider with closed stdin accepted another request")
            } catch { XCTAssertEqual(error.localizedDescription, NocturneError.disconnected.localizedDescription) }
            XCTAssertTrue(rpc.closed)
            try await rpc.waitUntilExit()
            return
        }
        let child = Process(), log = root.appendingPathComponent("sigpipe-child.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); if child.isRunning { child.terminate() } }
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["-XCTest", "NocturneKitTests.ChatTests/testProviderClosedStdinFailsRequestWithoutTerminatingHost", Bundle(for: ChatTests.self).bundlePath]
        var environment = ProcessInfo.processInfo.environment; environment[childFlag] = "1"; child.environment = environment
        child.standardOutput = output; child.standardError = output
        try child.run()
        for _ in 0..<500 {
            if !child.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !child.isRunning else { XCTFail("Isolated broken-pipe regression timed out"); return }
        let diagnostics = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(child.terminationReason, .exit, diagnostics)
        XCTAssertEqual(child.terminationStatus, 0, diagnostics)
    }
    func testVoiceChildNeverReceivesPlatformKeyEnvironment() async throws {
        let previous = getenv("OPENAI_API_KEY").map { String(cString: $0) }
        setenv("OPENAI_API_KEY", "fixture-only", 1)
        defer { if let previous { setenv("OPENAI_API_KEY", previous, 1) } else { unsetenv("OPENAI_API_KEY") } }
        let rpc = try AgentRPC(configuration: configuration("voice"), directory: root, chatGPTOnly: true); defer { rpc.close() }
        let result = try await rpc.call("voice/testEnvironment")
        XCTAssertEqual(result["platformKeyPresent"] as? Bool, false)
        XCTAssertEqual(result["originatorOverridePresent"] as? Bool, false)
    }
    func testWebRTCAnswerCanPrecedeStartedNotification() async throws {
        let agent = try await agent("voice-answer-first")
        var events: [ChatVoiceEvent.Kind] = []
        agent.emitVoice = { events.append($0.kind) }
        try await agent.startVoice("legacy", lease: "lease", sdp: Self.offerSDP)
        XCTAssertEqual(Array(events.prefix(2)), [.answer, .started])
        try await agent.stopVoice(lease: "lease")
    }
    func testBackendProtocolRejectionKeepsSanitizedCauseAndNeverFallsBack() async throws {
        let agent = try await agent("voice-rejected")
        do { try await agent.startVoice("legacy", lease: "lease", sdp: Self.offerSDP); XCTFail("Backend rejection was ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains("invalid_quicksilver_alpha_header"), error.localizedDescription) }
    }
    func testCodexAccountControllerUsesManagedChatGPTLogin() async throws {
        let account = CodexAccountController(); defer { account.close() }
        await account.refresh(configuration: configuration("account-signed-out"), directory: root)
        XCTAssertFalse(account.signedIn)
        var opened: URL?
        await account.login(configuration: configuration("account-signed-out"), directory: root) { opened = $0 }
        XCTAssertEqual(opened?.host, "auth.openai.com")
        try await waitUntil { account.signedIn }
        XCTAssertFalse(account.awaitingLogin); XCTAssertNil(account.error)
    }
    func testCodexModelCatalogAndReasoningSettingsAreValidatedAndPersisted() async throws {
        let agent = try await agent()
        _ = try await agent.load("legacy", cursor: nil, archived: false)
        let initial = try await agent.options(for: "legacy")
        XCTAssertEqual(initial.first { $0.id == "model" }?.value, "fixture-fast")
        let changed = try await agent.configure("legacy", id: "model", value: "fixture-deep")
        XCTAssertEqual(changed.first { $0.id == "model" }?.value, "fixture-deep")
        XCTAssertEqual(changed.first { $0.id == "effort" }?.choices.map(\.value), ["medium", "high"])
        let effort = try await agent.configure("legacy", id: "effort", value: "high")
        XCTAssertEqual(effort.first { $0.id == "effort" }?.value, "high")
        do { _ = try await agent.configure("legacy", id: "effort", value: "invented"); XCTFail("Unadvertised effort accepted") } catch {}
    }
    func testACPAdvertisedModelOptionsFlattenGroupsAndUseSessionConfiguration() async throws {
        let agent = try await agent("acp")
        let page = try await agent.list(cursor: nil, archived: false)
        let session = try XCTUnwrap(page.sessions.first)
        _ = try await agent.load(session.id, cursor: nil, archived: false)
        let options = try await agent.options(for: session.id)
        XCTAssertEqual(options.first?.choices.map(\.value), ["fixture-fast", "fixture-deep"])
        let changed = try await agent.configure(session.id, id: "agent-model", value: "fixture-deep")
        XCTAssertEqual(changed.first?.value, "fixture-deep")
    }
    func testInstalledCodexVoiceContinuationWithCompetingWriterWithoutInference() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_CODEX_VOICE_PREFLIGHT"] == "1" else { throw XCTSkip("Opt-in installed Codex writer conflict and voice preparation; no inference or microphone.") }
        let configuration = ChatAgentConfiguration.defaults[0]
        let owner = try AgentRPC(configuration: configuration, directory: root)
        defer { owner.close() }
        _ = try await owner.call("initialize", ["clientInfo": ["name": "nocturne-test", "version": "1.0"], "capabilities": ["experimentalApi": true]])
        owner.notify("initialized")
        let started = try await owner.call("thread/start", ["cwd": root.path, "historyMode": "legacy"])
        let source = try XCTUnwrap((started["thread"] as? [String: Any])?["id"] as? String)
        _ = try await owner.call("thread/name/set", ["threadId": source, "name": "Nocturne voice writer fixture"])
        let voice = try ChatAgentSession(configuration: configuration, directory: root, chatGPTOnly: true); agents.append(voice)
        var continuation: String?
        do {
            try await voice.initialize()
            let prepared = try await voice.prepareVoiceSession(source, allowContinuation: true); continuation = prepared.id
            XCTAssertNotEqual(prepared.id, source)
            XCTAssertEqual(prepared.title, "Voice · Nocturne voice writer fixture")
            XCTAssertEqual(URL(fileURLWithPath: prepared.directory).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
            let again = try await voice.prepareVoiceSession(prepared.id)
            XCTAssertEqual(again.id, prepared.id)
            // The original client still owns and can operate its original thread.
            _ = try await owner.call("thread/name/set", ["threadId": source, "name": "Nocturne voice writer fixture still owned"])
            try await voice.releaseForVoice(prepared.id)
        } catch {
            voice.close()
            if let continuation { _ = try? await owner.call("thread/archive", ["threadId": continuation]) }
            _ = try? await owner.call("thread/archive", ["threadId": source])
            throw error
        }
        if let continuation { _ = try await owner.call("thread/archive", ["threadId": continuation]) }
        _ = try await owner.call("thread/archive", ["threadId": source])
    }
    func testInstalledCodexSupervisorToolsWithoutInference() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_CODEX_SUPERVISOR"] == "1" else { throw XCTSkip("Opt-in installed Codex supervisor registration and handoff; no inference or microphone.") }
        let configuration = ChatAgentConfiguration.defaults[0]
        let agent = try ChatAgentSession(configuration: configuration, directory: root); agents.append(agent)
        try await agent.initialize()
        let session = try await agent.create(supervisor: true)
        let page = try await agent.load(session.id, cursor: nil, archived: false)
        XCTAssertEqual(page.session.id, session.id); XCTAssertTrue(page.messages.isEmpty)
        try await agent.releaseForVoice(session.id)
        let rpc = try AgentRPC(configuration: configuration, directory: root, chatGPTOnly: true)
        defer { rpc.close() }
        _ = try await rpc.call("initialize", ["clientInfo": ["name": "nocturne", "version": "1.0"], "capabilities": ["experimentalApi": true]])
        rpc.notify("initialized")
        do {
            let resumed = try await rpc.call("thread/resume", ["threadId": session.id, "excludeTurns": true])
            XCTAssertEqual((resumed["thread"] as? [String: Any])?["id"] as? String, session.id)
        } catch {
            _ = try? await rpc.call("thread/archive", ["threadId": session.id]); throw error
        }
        _ = try await rpc.call("thread/archive", ["threadId": session.id])
    }
    func testInstalledCodexModelSelectionWithoutInference() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_CODEX_MODELS"] == "1" else { throw XCTSkip("Opt-in installed Codex model catalog and ephemeral thread settings; no inference.") }
        let agent = try ChatAgentSession(configuration: ChatAgentConfiguration.defaults[0], directory: root); agents.append(agent)
        try await agent.initialize()
        let thread = try await agent.create(ephemeral: true)
        let options = try await agent.options(for: thread.id)
        let model = try XCTUnwrap(options.first { $0.id == "model" })
        XCTAssertFalse(model.choices.isEmpty)
        let updated = try await agent.configure(thread.id, id: "model", value: model.value)
        XCTAssertEqual(updated.first { $0.id == "model" }?.value, model.value)
    }
    func testAuthenticatedProjectToolsKeepWorktreeAndConversationTogether() async throws {
        func git(_ arguments: [String]) async throws {
            let result = try await DeveloperCommand.run("git", arguments, root, nil)
            guard result.code == 0 else { throw NocturneError.remote(result.error) }
        }
        try await git(["init", "-b", "main"])
        try await git(["config", "user.name", "Nocturne test"]); try await git(["config", "user.email", "test@example.invalid"])
        try await git(["config", "commit.gpgsign", "false"]); try await git(["config", "core.hooksPath", "/dev/null"])
        try "original\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "notes.txt"]); try await git(["commit", "-m", "Fixture"])
        try "changed\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let repository = try await RepositoryService.open(root)
        let tree = try await repository.createWorktree(branch: "feature/new", base: "main", storage: root.appendingPathComponent("trees"))
        let identity = try TestDeviceIdentity(), store = try WorkspaceDeviceStore(url: root.appendingPathComponent("developer-devices.json"))
        let server = try WorkspaceServer(folder: root, name: "Developer Mac", devices: store, permissions: .init(chats: true), chatAgents: [configuration()])
        let client = WorkspaceConnection(identity: identity.identity()), chat = ChatWorkspaceModel(connection: client)
        defer { client.disconnect(); server.stop() }
        let ready = expectation(description: "Developer listener"); var signalled = false
        server.onStatus = { state, _ in if state == "Ready", !signalled { signalled = true; ready.fulfill() } }
        let secret = try SecureStore.randomKey(); try server.start(secret: secret, port: 0); await fulfillment(of: [ready], timeout: 5)
        let invitation = try PairingInvitation(host: "127.0.0.1", port: XCTUnwrap(server.listeningPort), name: "Developer Mac", secret: secret, enrollmentToken: store.createInvitation())
        try await client.connect(invitation); await chat.refresh(); await chat.open(try XCTUnwrap(chat.sessions.first))
        XCTAssertEqual(chat.options.first?.value, "fixture-fast")
        let project = DeveloperWorkspaceModel(chat: chat); await project.refresh()
        XCTAssertEqual(project.snapshot?.root, root.resolvingSymlinksInPath().path)
        let file = try XCTUnwrap(project.snapshot?.changes.first { $0.path == "notes.txt" })
        await project.loadDiff(file); XCTAssertTrue(project.content?.text.contains("+changed") == true)
        chat.draft = "wait"; await chat.send()
        await project.stage(file, undo: false); XCTAssertNotNil(project.error, "Git mutations must wait for the agent's active turn")
        await chat.stop(); try await waitUntil { !chat.responding }
        var invalid = Packet(.chatNew); invalid.chatRequest = ChatRequest(providerID: "codex", sessionID: "legacy"); invalid.chatRequest?.worktreePath = "/tmp/unlisted-worktree"
        do { _ = try await client.request(invalid); XCTFail("An unlisted worktree was accepted") } catch {}
        await project.openWorktree(tree)
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.selected?.directory, tree.path)
        await chat.newConversation(inheritProject: true)
        XCTAssertEqual(chat.selected?.directory, tree.path, "New threads must stay in the selected project checkout")
        XCTAssertNil(project.snapshot, "Old checkout state must be cleared when opening the worktree chat")
        await project.refresh(); XCTAssertEqual(project.snapshot?.branch, "feature/new")
        server.updatePermissions(.init())
        await project.refresh(); XCTAssertNotNil(project.error)
        _ = try await client.request(Packet(.ping)); XCTAssertEqual(client.state, .connected)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("Chat state did not arrive"); throw NocturneError.timeout
    }

    private static let fixture = #"""
import json, os, sys, base64, time
mode, cwd = sys.argv[1:]
with open(os.path.join(cwd,'agent.pid'), 'w') as f:
    f.write(str(os.getpid()))
pending = None
created = 0
logged_in = False
selected_model = 'fixture-fast'
selected_effort = 'medium'
thread_directories = {}
sid = 'acp-chat' if mode.startswith('acp') else 'legacy'
def send(value):
    print(json.dumps(value), flush=True)
def reply(rid, result):
    send({'jsonrpc':'2.0', 'id':rid, 'result':result})
def event(method, params):
    send({'jsonrpc':'2.0', 'method':method, 'params':params})
def thread(tid, title='A conversation'):
    return {'id':tid, 'name':title, 'cwd':thread_directories.get(tid,cwd), 'model':selected_model,'reasoningEffort':selected_effort,'updatedAt':1700000000, 'historyMode':'paginated' if mode == 'modern' else 'legacy'}
def config_options():
    return [{'id':'agent-model','name':'Agent model','category':'model','type':'select','currentValue':selected_model,'options':[{'group':'recommended','name':'Recommended','options':[{'value':'fixture-fast','name':'Fast'},{'value':'fixture-deep','name':'Deep'}]}]}]
def item(i, text, role='agentMessage'):
    return {'id':i, 'type':role, 'text':text} if role != 'userMessage' else {'id':i, 'type':role, 'content':[{'type':'text','text':text}]}
def update(kind, **kw):
    event('session/update', {'sessionId':sid, 'update':dict(sessionUpdate=kind, **kw)})
for line in sys.stdin:
    q = json.loads(line)
    method, p, rid = q.get('method'), q.get('params',{}), q.get('id')
    if method == 'initialize':
        if mode.startswith('voice'):
            assert not os.environ.get('OPENAI_API_KEY')
            assert not os.environ.get('CODEX_INTERNAL_ORIGINATOR_OVERRIDE')
            assert p['capabilities']['experimentalApi']
        if mode == 'bad':
            print('this is not JSON', flush=True)
            continue
        if mode == 'exit':
            sys.exit(0)
        if mode.startswith('acp'):
            assert p['protocolVersion'] == 1 and not p['clientCapabilities']['terminal']
            caps = {} if mode == 'acp-minimal' else {'loadSession':True, 'sessionCapabilities':{'list':{}}}
            reply(rid, {'protocolVersion':1,'agentCapabilities':caps})
        else:
            assert p['clientInfo']['name'] == 'nocturne'
            reply(rid,{})
    elif method == 'initialized':
        pass
    elif method == 'thread/list':
        assert p['modelProviders'] == [] and 'exec' in p['sourceKinds'] and 'unknown' in p['sourceKinds']
        if p.get('cursor'):
            reply(rid, {'data':[thread('remote')], 'nextCursor':None})
        else:
            reply(rid, {'data':[thread('legacy' if i == 0 else str(i), 'Archived' if p['archived'] else 'Chat '+str(i)) for i in range(45)], 'nextCursor':'remote-page'})
    elif method == 'thread/read':
        t = thread(p['threadId'])
        if p['threadId'] == 'external-active': t['status'] = {'type':'active','activeFlags':[]}
        if p.get('includeTurns') and mode == 'unmaterialized':
            send({'id':rid,'error':{'code':-32600,'message':'thread supervisor is not materialized yet; includeTurns is unavailable before first user message'}})
            continue
        if p.get('includeTurns'):
            t['turns'] = [{'id':'turn','items':[item('u','Hello','userMessage'), item('a','🌙'*10000), {'id':'secret','type':'reasoning','content':['private reasoning']}]}]
        reply(rid, {'thread':t})
    elif method == 'model/list':
        reply(rid, {'data':[{'id':m,'model':m,'displayName':m,'isDefault':i==0,'defaultReasoningEffort':'medium','supportedReasoningEfforts':[{'reasoningEffort':x,'description':x} for x in (['low','medium'] if i==0 else ['medium','high'])]} for i,m in enumerate(['fixture-fast','fixture-deep'])], 'nextCursor':None})
    elif method == 'thread/settings/update':
        assert p['threadId']=='legacy' or p['threadId']=='new'
        selected_model = p.get('model',selected_model); selected_effort = p.get('effort',selected_effort)
        reply(rid, {})
    elif method == 'thread/items/list':
        values = [item('one','first')] if p.get('cursor') else [item('three','third'),item('two','second')]
        reply(rid, {'data':[{'turnId':'t','item':i} for i in values], 'nextCursor':None if p.get('cursor') else 'older'})
    elif method in ('thread/resume','thread/start'):
        tid = p.get('threadId','new')
        if method == 'thread/resume' and mode == 'voice-writer' and tid == 'legacy':
            send({'jsonrpc':'2.0','id':rid,'error':{'code':-32600,'message':'thread legacy already has an active writer'}})
            continue
        if method == 'thread/resume' and mode == 'voice-resume-failure':
            send({'jsonrpc':'2.0','id':rid,'error':{'code':-32600,'message':'fixture resume failure'}})
            continue
        if method == 'thread/resume' and mode == 'voice-writer' and tid == 'voice-continuation':
            raise AssertionError('The prepared provider must be reused, not resumed in a second process')
        if method == 'thread/start':
            if p.get('dynamicTools'):
                assert p['dynamicTools'][0]['name'] == 'nocturne_agents' and p['dynamicTools'][0]['type'] == 'function'
                assert 'supervisor' in p['developerInstructions']
                tid = 'supervisor'
            thread_directories[tid] = p['cwd']
        reply(rid, {'thread':thread(tid)})
    elif method == 'thread/fork':
        assert mode == 'voice-writer' and p['threadId'] == 'legacy'
        assert p['deferGoalContinuation'] and p['excludeTurns'] and p['modelProvider'] == 'openai'
        assert p['sandbox'] == 'workspace-write' and p['approvalPolicy'] == 'on-request'
        with open(os.path.join(cwd,'voice-forked'),'a') as f: f.write(p['threadId']+'\n')
        reply(rid, {'thread':thread('voice-continuation')})
    elif method == 'thread/name/set':
        reply(rid, {})
    elif method == 'fixture/closeStdin':
        os.close(0)
        reply(rid, {})
        time.sleep(30) # Keep stdout open so only the failed write can close the RPC.
        break
    elif method == 'voice/testEnvironment':
        reply(rid, {'platformKeyPresent': any(os.environ.get(k) for k in ['OPENAI_API_KEY','CODEX_API_KEY','AZURE_OPENAI_API_KEY']), 'originatorOverridePresent': bool(os.environ.get('CODEX_INTERNAL_ORIGINATOR_OVERRIDE'))})
    elif method == 'account/read':
        account = None if mode == 'voice-signed-out' or (mode == 'account-signed-out' and not logged_in) else {'type':'apiKey'} if mode == 'voice-platform-key' else {'type':'chatgpt','email':None,'planType':'pro'}
        reply(rid, {'account':account,'requiresOpenaiAuth':True})
    elif method == 'config/read':
        reply(rid, {'config': {'model_providers': {'openai': {'env_key': 'FIXTURE_PLATFORM_KEY'}}} if mode == 'voice-platform-provider' else {}})
    elif method == 'account/login/start':
        assert p == {'type':'chatgpt'}
        reply(rid, {'type':'chatgpt','loginId':'fixture-login','authUrl':'https://auth.openai.com/nocturne-fixture'})
        logged_in = True
        event('account/login/completed', {'loginId':'fixture-login','success':True,'error':None})
    elif method == 'thread/realtime/start':
        assert p['outputModality'] == 'audio' and p['transport']['type'] == 'webrtc' and p['version'] == 'v3'
        assert p['transport']['sdp'].startswith('v=0')
        open(os.path.join(cwd,'voice-started'),'w').close()
        sid = p['threadId']; voice_id = p['realtimeSessionId']
        reply(rid,{})
        if mode == 'voice-rejected':
            event('thread/realtime/error', {'threadId':sid,'message':'{"error":{"message":"AVAS requires OpenAI-Alpha: quicksilver=v2.","code":"invalid_quicksilver_alpha_header"}}'})
            continue
        if mode == 'voice-answer-first':
            event('thread/realtime/sdp',{'threadId':sid,'sdp':p['transport']['sdp']})
        event('thread/realtime/started',{'threadId':sid,'realtimeSessionId':'provider-session','version':'v3'})
        if mode != 'voice-answer-first':
            event('thread/realtime/sdp',{'threadId':sid,'sdp':p['transport']['sdp']})
        event('thread/realtime/itemAdded',{'threadId':sid,'item':{'type':'input_audio_buffer.speech_started'}})
        u = {'id':'spoken-user','realtimeSessionId':voice_id,'type':'transcriptSegment','role':'user','text':''}
        event('thread/realtime/item/started',{'threadId':sid,'item':u})
        event('thread/realtime/item/transcript/delta',{'threadId':sid,'itemId':'spoken-user','delta':'Run tests'})
        event('thread/realtime/transcript/delta',{'threadId':sid,'role':'user','delta':'Run tests'})
        u['text'] = 'Run tests'
        event('thread/realtime/item/completed',{'threadId':sid,'item':u})
        send({'jsonrpc':'2.0','id':'voice-approval','method':'item/commandExecution/requestApproval','params':{'threadId':sid,'command':'swift test','cwd':cwd,'reason':'Run the requested checks'}})
    elif method == 'thread/realtime/stop':
        reply(rid,{})
        event('thread/realtime/closed',{'threadId':sid,'reason':'client_requested'})
    elif method is None and rid == 'voice-approval':
        assert q['result']['decision'] == 'accept'
        a = {'id':'spoken-answer','realtimeSessionId':voice_id,'type':'transcriptSegment','role':'assistant','text':''}
        event('thread/realtime/item/started',{'threadId':sid,'item':a})
        event('thread/realtime/item/transcript/delta',{'threadId':sid,'itemId':'spoken-answer','delta':'Running the tests.'})
        a['text'] = 'Running the tests.'
        event('thread/realtime/item/completed',{'threadId':sid,'item':a})
        event('turn/completed',{'threadId':sid,'turn':{'id':'spoken-work','status':'completed'}})
    elif method == 'turn/start':
        sid = p['threadId']
        reply(rid, {'turn':{'id':'active-turn','status':'inProgress'}})
        event('turn/started',{'threadId':sid,'turn':{'id':'active-turn'}})
        event('item/completed',{'threadId':sid,'item':item('sent',p['input'][0]['text'],'userMessage')})
        if sid == 'supervisor':
            send({'jsonrpc':'2.0','id':'supervisor-tool','method':'item/tool/call','params':{'threadId':sid,'turnId':'active-turn','callId':'manage-1','tool':'nocturne_agents','arguments':{'action':'list'}}})
        elif p['input'][0]['text'] != 'wait':
            event('turn/diff/updated',{'threadId':sid,'turnId':'active-turn','diff':'diff --git a/notes.txt b/notes.txt\n@@ -1 +1 @@\n-old\n+agent edit\n'})
            event('item/agentMessage/delta',{'threadId':sid,'itemId':'answer','delta':'Hello '})
            pending = rid
            send({'jsonrpc':'2.0','id':'approval','method':'item/commandExecution/requestApproval','params':{'threadId':sid,'command':'pwd','cwd':cwd,'reason':'Check project'}})
    elif method == 'turn/interrupt':
        reply(rid,{})
        event('turn/completed',{'threadId':sid,'turn':{'id':'active-turn','status':'interrupted'}})
    elif method == 'session/list':
        assert mode != 'acp-minimal'
        reply(rid, {'sessions':[{'sessionId':sid,'cwd':cwd,'title':'ACP conversation','updatedAt':'2026-10-27T10:00:00Z'}]})
    elif method == 'session/new':
        created += 1
        sid = 'temporary-' + str(created)
        reply(rid, {'sessionId':sid,'configOptions':config_options()})
    elif method == 'session/load':
        assert mode != 'acp-minimal'
        update('user_message_chunk', content={'type':'text','text':'Hi'})
        update('agent_message_chunk', content={'type':'text','text':'Hel'})
        update('agent_message_chunk', content={'type':'text','text':'lo'})
        update('tool_call', toolCallId='read', title='Read file', status='in_progress')
        update('tool_call_update', toolCallId='read', status='completed')
        reply(rid,{'configOptions':config_options()})
    elif method == 'session/set_config_option':
        assert p['configId']=='agent-model' and p['value'] in ['fixture-fast','fixture-deep']
        selected_model = p['value']; reply(rid, {'configOptions':config_options()})
    elif method == 'session/prompt':
        pending = rid
        update('agent_message_chunk', content={'type':'text','text':'Reply '})
        if p['prompt'][0]['text'] != 'wait':
            send({'jsonrpc':'2.0','id':'approval','method':'session/request_permission','params':{'sessionId':sid,'toolCall':{'title':'Read file','rawInput':{'path':'test.swift'}},'options':[{'optionId':'allow','name':'Allow once','kind':'allow_once'},{'optionId':'deny','name':'Deny','kind':'reject_once'}]}})
    elif method == 'session/cancel':
        reply(pending, {'stopReason':'cancelled'})
        pending = None
    elif method is None and rid == 'supervisor-tool':
        assert q['result']['success']
        event('item/completed', {'threadId':sid,'item':item('supervisor-answer',q['result']['contentItems'][0]['text'])})
        event('turn/completed',{'threadId':sid,'turn':{'id':'active-turn','status':'completed'}})
    elif method is None and rid == 'approval':
        if mode.startswith('acp'):
            assert q['result']['outcome']['outcome'] in ('selected','cancelled')
            update('agent_message_chunk', content={'type':'text','text':'done'})
            reply(pending, {'stopReason':'end_turn'})
        else:
            assert q['result']['decision'] in ('accept','cancel','decline')
            event('item/agentMessage/delta',{'threadId':sid,'itemId':'answer','delta':'world'})
            event('item/completed',{'threadId':sid,'item':item('answer','Hello world')})
            event('turn/completed',{'threadId':sid,'turn':{'id':'active-turn','status':'completed'}})
        pending = None
    else:
        if rid is not None:
            send({'jsonrpc':'2.0','id':rid,'error':{'code':-32601,'message':'Unexpected method '+str(method)}})
"""#
}
