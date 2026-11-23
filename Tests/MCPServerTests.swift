import XCTest
import NocturneKit
@testable import NocturneHostKit

@MainActor
final class MCPServerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Nocturne-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var server: MCPServerConfiguration {
        .init(id: "nocturne_test", name: "Custom tools", url: "http://localhost:43123/mcp", headers: ["Authorization": "Bearer fixture-secret"])
    }
    func testValidationRejectsInvalidURLsHeadersAndBounds() throws {
        XCTAssertNoThrow(try server.validate())
        for url in ["", "localhost:123/mcp", "file:///tmp/server", "https://user:password@example.com/mcp", "https://example.com/#fragment", "https://example.com/a\nb", "https://example.com:70000/mcp"] {
            var value = server; value.url = url; XCTAssertThrowsError(try value.validate(), url)
        }
        for headers in [["Authorization": "a\r\nInjected: b"], ["Bad Name": "x"], ["Authorization": "a", "authorization": "b"], ["": "x"], ["x": String(repeating: "a", count: 8193)]] {
            var value = server; value.headers = headers; XCTAssertThrowsError(try value.validate())
        }
        var invalid = server; invalid.id = "bad.id"; XCTAssertThrowsError(try invalid.validate())
        invalid = server; invalid.name = "  "; XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try MCPServerConfiguration.validate([server, server]))
        XCTAssertThrowsError(try MCPServerConfiguration.validate((0..<25).map { .init(id: "server_\($0)", name: "Server \($0)", url: "https://example.com/mcp") }))
    }
    func testStorePersistsEditsDisablesAndRemovalAndDoesNotPublishFailedWrites() throws {
        var data: Data?, failWrite = false
        let store = MCPServerStore(read: { data }, write: { if failWrite { throw NocturneError.permissionDenied }; data = $0 })
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try store.save(server), [server])
        var changed = server; changed.enabled = false; changed.headers["Authorization"] = "Bearer replacement"
        XCTAssertEqual(try store.save(changed), [changed])
        let reopened = MCPServerStore(read: { data }, write: { data = $0 })
        XCTAssertEqual(try reopened.load(), [changed])
        failWrite = true
        XCTAssertThrowsError(try store.remove(server.id)); XCTAssertEqual(store.servers, [changed])
        failWrite = false; XCTAssertTrue(try store.remove(server.id).isEmpty)
        XCTAssertTrue(try reopened.load().isEmpty)
        data = Data("invalid".utf8); XCTAssertThrowsError(try reopened.load())
    }
    func testCodexReceivesOverridesForNewAndResumedThreads() async throws {
        let agent = try makeAgent("codex", servers: [server]); defer { agent.close() }
        try await agent.initialize(); _ = try await agent.create()
        _ = try await agent.load("existing", cursor: nil, archived: false)
        try await agent.prompt("existing", text: "Hello")
        let calls = try recordedCalls()
        for method in ["thread/start", "thread/resume"] {
            let params = try XCTUnwrap(calls.first { $0["method"] as? String == method }?["params"] as? [String: Any])
            let config = try XCTUnwrap(params["config"] as? [String: Any])
            let value = try XCTUnwrap(config["mcp_servers.nocturne_test"] as? [String: Any])
            XCTAssertEqual(value["url"] as? String, server.url)
            XCTAssertEqual(value["http_headers"] as? [String: String], server.headers)
        }
    }
    func testACPReceivesHTTPServersOnCreateAndLoadAndRejectsUnsupportedTransport() async throws {
        let agent = try makeAgent("acp", servers: [server]); defer { agent.close() }
        try await agent.initialize(); let session = try await agent.create()
        _ = try await agent.load(session.id, cursor: nil, archived: false)
        for method in ["session/new", "session/load"] {
            let params = try XCTUnwrap(try recordedCalls().first { $0["method"] as? String == method }?["params"] as? [String: Any])
            let value = try XCTUnwrap((params["mcpServers"] as? [[String: Any]])?.first)
            XCTAssertEqual(value["type"] as? String, "http"); XCTAssertEqual(value["url"] as? String, server.url)
            XCTAssertEqual(value["headers"] as? [[String: String]], [["name": "Authorization", "value": "Bearer fixture-secret"]])
        }
        let unsupported = try makeAgent("unsupported", servers: [server]); defer { unsupported.close() }
        try await unsupported.initialize()
        do { _ = try await unsupported.create(); XCTFail("Unsupported HTTP transport accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("does not support HTTP MCP")) }
        var disabled = server; disabled.enabled = false
        let empty = try makeAgent("unsupported", servers: [disabled]); defer { empty.close() }
        try await empty.initialize(); _ = try await empty.create()
        let last = try XCTUnwrap(try recordedCalls().last { $0["method"] as? String == "session/new" }?["params"] as? [String: Any])
        XCTAssertEqual((last["mcpServers"] as? [Any])?.count, 0)
    }
    func testManagementOverAuthenticatedTLSAndPermissionRevocation() async throws {
        var data: Data?
        let store = MCPServerStore(read: { data }, write: { data = $0 })
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let host = try WorkspaceServer(folder: root, name: "MCP Mac", devices: devices, permissions: .init(chats: true), chatAgents: [], mcpServers: store)
        let identity = try TestDeviceIdentity(), key = try SecureStore.randomKey()
        let client = WorkspaceConnection(identity: identity.identity())
        defer { client.disconnect(); host.stop() }
        let ready = expectation(description: "Ready"); var signalled = false
        host.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; ready.fulfill() } }
        try host.start(secret: key, port: 0); await fulfillment(of: [ready], timeout: 5)
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: XCTUnwrap(host.listeningPort), name: "MCP Mac", secret: key, enrollmentToken: devices.createInvitation()))
        XCTAssertTrue(client.capabilities.contains(MCPServerConfiguration.capability))
        let model = MCPServersModel(connection: client); await model.refresh(); XCTAssertTrue(model.loaded)
        let saved = await model.save(server); XCTAssertTrue(saved); XCTAssertEqual(try store.load(), [server])
        var changed = server; changed.enabled = false
        let edited = await model.save(changed); XCTAssertTrue(edited); XCTAssertEqual(model.servers.count, 1)
        let second = MCPServersModel(connection: client); await second.refresh(); XCTAssertEqual(second.servers, [changed])
        var packet = Packet(.chatMCPSave); var bad = server; bad.headers = ["Authorization": "bad\nvalue"]; packet.mcpServer = bad
        do { _ = try await client.request(packet); XCTFail("Malformed server accepted") } catch { }
        XCTAssertEqual(try store.load(), [changed])
        await model.remove(server.id); XCTAssertTrue(model.servers.isEmpty)
        host.updatePermissions(.init(chats: false))
        do { _ = try await client.request(Packet(.chatMCPList)); XCTFail("Revoked chat access accepted") } catch { }
        let denied = await model.save(server); XCTAssertFalse(denied); XCTAssertNotNil(model.error); XCTAssertTrue(try store.load().isEmpty)
    }
    func testHostRefreshesProviderSnapshotAndRejectsChangesDuringReplies() async throws {
        var data: Data?
        let store = MCPServerStore(read: { data }, write: { data = $0 })
        try Self.fixture.write(to: root.appendingPathComponent("agent.py"), atomically: true, encoding: .utf8)
        let configuration = ChatAgentConfiguration(id: "fixture", name: "Fixture", transport: .codex,
            executable: "/usr/bin/python3", arguments: ["-u", root.appendingPathComponent("agent.py").path, "codex", root.path])
        let host = ChatHostSession(configurations: [configuration], directory: root, enabled: true, mcpServers: store)
        defer { host.close() }
        func request(_ packet: Packet) async -> Packet {
            await withCheckedContinuation { continuation in host.handle(packet) { continuation.resume(returning: $0) } }
        }
        var create = Packet(.chatNew); create.chatRequest = ChatRequest(providerID: "fixture")
        let initial = await request(create); XCTAssertNil(initial.error)
        var save = Packet(.chatMCPSave); save.mcpServer = server
        let saved = await request(save); XCTAssertNil(saved.error)
        let updated = await request(create); XCTAssertNil(updated.error)
        let calls = try recordedCalls().filter { $0["method"] as? String == "thread/start" }
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil((calls.first?["params"] as? [String: Any])?["config"])
        XCTAssertNotNil((calls.last?["params"] as? [String: Any])?["config"])
        var prompt = Packet(.chatPrompt); prompt.chatRequest = ChatRequest(providerID: "fixture", sessionID: "new"); prompt.chatRequest?.text = "Hello"
        let started = await request(prompt); XCTAssertNil(started.error)
        var remove = Packet(.chatMCPRemove); remove.sessionID = server.id
        let denied = await request(remove); XCTAssertNotNil(denied.error)
        XCTAssertEqual(try store.load(), [server])
    }
    func testDisconnectedClientDoesNotSendUnsupportedRequests() async throws {
        let connection = WorkspaceConnection(identity: try TestDeviceIdentity().identity()), model = MCPServersModel(connection: connection)
        await model.refresh(); XCTAssertFalse(model.loaded); XCTAssertNotNil(model.error)
    }
    private func makeAgent(_ mode: String, servers: [MCPServerConfiguration]) throws -> ChatAgentSession {
        let script = root.appendingPathComponent("agent.py")
        try Self.fixture.write(to: script, atomically: true, encoding: .utf8)
        return try ChatAgentSession(configuration: .init(name: "Fixture", transport: mode == "codex" ? .codex : .acp,
            executable: "/usr/bin/python3", arguments: ["-u", script.path, mode, root.path]), directory: root, mcpServers: servers)
    }
    private func recordedCalls() throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    private static let fixture = #"""
import sys, json, os
mode, root = sys.argv[1:]
for line in sys.stdin:
    request = json.loads(line)
    with open(os.path.join(root, 'calls.jsonl'), 'a') as out: out.write(json.dumps(request) + '\n')
    if 'id' not in request: continue
    method = request['method']
    result = {}
    if method == 'initialize': result = {'protocolVersion': 1, 'agentCapabilities': {'loadSession': True, 'sessionCapabilities': {'list': {}}, 'mcpCapabilities': {'http': mode == 'acp'}}}
    elif method in ['thread/start', 'thread/read', 'thread/resume']: result = {'thread': {'id': 'new' if method == 'thread/start' else 'existing', 'cwd': root, 'preview': 'Fixture', 'turns': []}}
    elif method == 'turn/start': result = {'turn': {'id': 'turn'}}
    elif method == 'session/new': result = {'sessionId': 'new'}
    elif method == 'session/list': result = {'sessions': [{'sessionId': 'existing', 'cwd': root, 'title': 'Fixture'}]}
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
"""#
}
