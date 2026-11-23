import XCTest
import Darwin
import NocturneKit
@testable import NocturneHostKit

@MainActor
final class ChatOwnershipTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var agents: [ChatAgentSession] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Nocturne-ownership-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.fixture.write(to: root.appendingPathComponent("agent.py"), atomically: true, encoding: .utf8)
        suite = "Nocturne-ownership-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws {
        agents.forEach { $0.close() }; agents = []
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    private func configuration(_ mode: String = "codex", id: String = "codex") -> ChatAgentConfiguration {
        .init(id: id, name: "Fixture", transport: mode == "acp" ? .acp : .codex,
              executable: "/usr/bin/python3", arguments: ["-u", root.appendingPathComponent("agent.py").path, root.path, mode])
    }
    private func agent(_ mode: String = "codex", id: String = "codex") async throws -> ChatAgentSession {
        let agent = try ChatAgentSession(configuration: configuration(mode, id: id), directory: root, defaults: defaults)
        agents.append(agent); try await agent.initialize(); return agent
    }
    func testCodexFiltersByExactOriginAcrossPagesAndArchives() async throws {
        let agent = try await agent()
        // Merely reading another app's chat must not adopt it into Nocturne.
        _ = try await agent.load("foreign", cursor: nil, archived: false)
        let page = try await agent.list(cursor: nil, archived: false)
        XCTAssertEqual(page.sessions.map(\.id), ["owned"]); XCTAssertNil(page.nextCursor)
        let archived = try await agent.list(cursor: nil, archived: true)
        XCTAssertEqual(archived.sessions.map(\.id), ["archived-owned"])
    }
    func testCreatedChatsPersistWhenProviderHasNoOriginMetadataAndAreProviderScoped() async throws {
        for mode in ["legacy", "acp"] {
            let first = try await agent(mode)
            let initial = try await first.list(cursor: nil, archived: false)
            XCTAssertTrue(initial.sessions.isEmpty)
            let session = try await first.create(); first.close()
            let second = try await agent(mode)
            let page = try await second.list(cursor: nil, archived: false)
            XCTAssertEqual(page.sessions.map(\.id), [session.id])
            let otherProvider = try await agent(mode, id: "another-provider")
            let other = try await otherProvider.list(cursor: nil, archived: false)
            XCTAssertTrue(other.sessions.isEmpty)
        }
    }
    func testExternalPagesAreBoundedAndRetainAnOpaqueContinuation() async throws {
        let agent = try await agent("many-pages")
        let first = try await agent.list(cursor: nil, archived: false)
        XCTAssertTrue(first.sessions.isEmpty); XCTAssertNotNil(first.nextCursor)
        let second = try await agent.list(cursor: XCTUnwrap(first.nextCursor), archived: false)
        XCTAssertEqual(second.sessions.map(\.id), ["owned"]); XCTAssertNil(second.nextCursor)
        do { _ = try await agent.list(cursor: first.nextCursor, archived: false); XCTFail("Stale cursor accepted") }
        catch { XCTAssertEqual(error as? NocturneError, .invalidFrame) }
    }
    func testSupervisorResetReplacesPersistedIdentityHidesOldChatAndCancelsWorkers() async throws {
        let service = ChatSupervisorService(configurations: [configuration()], directory: root, defaults: defaults)
        defer { service.reset() }
        let agent = try await agent()
        agent.supervisorSession = { service.isSupervisor($0, provider: "codex") }
        let old = try await service.open(using: agent).session
        var events: [ChatEvent] = []
        service.subscribe(UUID()) { events.append($0) }
        _ = try await service.call(["action": "create", "text": "wait"], supervisorProvider: "codex", supervisorID: old.id)
        for _ in 0..<300 {
            if !service.permissions(for: old.id).isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(service.permissions(for: old.id).isEmpty)
        let workerPID = try XCTUnwrap(Int32(try String(contentsOf: root.appendingPathComponent("worker.pid"), encoding: .utf8)))
        let replacement = try await service.open(using: agent, reset: true)
        for _ in 0..<300 {
            if kill(workerPID, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(kill(workerPID, 0), 0, "Reset must stop the worker process")
        XCTAssertNotEqual(replacement.session.id, old.id)
        XCTAssertTrue(replacement.session.isSupervisor == true); XCTAssertTrue(replacement.messages.isEmpty)
        XCTAssertFalse(service.isSupervisor(old.id, provider: "codex"))
        XCTAssertTrue(service.permissions(for: old.id).isEmpty)
        XCTAssertTrue(events.contains { $0.sessionID == old.id && $0.detail == ChatSupervisor.resetNotice })
        let restored = ChatSupervisorService(configurations: [configuration()], directory: root, defaults: defaults)
        XCTAssertTrue(restored.isSupervisor(replacement.session.id, provider: "codex"))
        let reopened = try await service.open(using: agent)
        XCTAssertEqual(reopened.session.id, replacement.session.id)
        let reconnected = try await self.agent()
        let list = try await reconnected.list(cursor: nil, archived: false)
        XCTAssertFalse(list.sessions.contains { $0.id == old.id })
        XCTAssertTrue(list.sessions.contains { $0.id == replacement.session.id })
        let result = try await service.call(["action": "list"], supervisorProvider: "codex", supervisorID: replacement.session.id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertTrue((json["workers"] as? [Any])?.isEmpty == true)
        do {
            _ = try await service.call(["action": "list"], supervisorProvider: "codex", supervisorID: old.id)
            XCTFail("Retired supervisor retained tool access")
        } catch {}
    }
    func testFailedSupervisorResetKeepsPreviousIdentityAndHistory() async throws {
        let service = ChatSupervisorService(configurations: [configuration("fail-reset")], directory: root, defaults: defaults)
        defer { service.reset() }
        let agent = try await agent("fail-reset"), old = try await service.open(using: agent).session
        do { _ = try await service.open(using: agent, reset: true); XCTFail("Reset unexpectedly succeeded") } catch {}
        XCTAssertTrue(service.isSupervisor(old.id, provider: "codex"))
        let reopened = try await service.open(using: agent)
        XCTAssertEqual(reopened.session.id, old.id)
    }
    private static let fixture = #"""
import json, os, sys
root, mode = sys.argv[1:]
path = os.path.join(root, 'sessions-' + mode + '.json')
def records():
    return json.load(open(path)) if os.path.exists(path) else []
def thread(tid, origin=None):
    return {'id':tid,'cwd':root,'name':tid,'originator':origin,'source':'appServer'}
def reply(rid, result):
    print(json.dumps({'id':rid,'result':result}), flush=True)
for line in sys.stdin:
    q = json.loads(line)
    m, p, rid = q.get('method'), q.get('params',{}), q.get('id')
    if m == 'initialize':
        reply(rid, {'protocolVersion':1,'agentCapabilities':{'loadSession':True,'sessionCapabilities':{'list':{}}}})
    elif m == 'thread/list':
        assert not p.get('originators'), 'Local Codex rejects originator request filters'
        page = int(p.get('cursor','0'))
        foreign = [thread('foreign','codex_vscode'), thread('lookalike','nocturne-other'),thread('unknown')]
        if mode in ('legacy','fail-reset'):
            reply(rid, {'data':foreign + [thread(i) for i in records()]})
        elif mode == 'many-pages':
            reply(rid, {'data':[thread('owned','nocturne')] if page == 9 else foreign,'nextCursor':str(page+1) if page < 9 else None})
        elif page == 0:
            reply(rid, {'data':foreign,'nextCursor':'1'})
        else:
            reply(rid, {'data':[thread('archived-owned' if p['archived'] else 'owned','nocturne')] + [thread(i,'nocturne') for i in records()]})
    elif m in ('thread/start','session/new'):
        values = records()
        if mode == 'fail-reset' and values:
            print(json.dumps({'id':rid,'error':{'code':-32603,'message':'fixture create failed'}}), flush=True)
            continue
        tid = 'created-' + str(len(values)+1)
        values.append(tid)
        with open(path,'w') as f: json.dump(values,f)
        reply(rid, {'thread':thread(tid),'sessionId':tid})
    elif m == 'thread/read':
        t = thread(p['threadId']); t['turns'] = []
        reply(rid, {'thread':t})
    elif m == 'session/list':
        reply(rid, {'sessions':[{'sessionId':i,'cwd':root,'title':i} for i in ['foreign'] + records()]})
    elif m == 'turn/start':
        with open(os.path.join(root,'worker.pid'),'w') as f: f.write(str(os.getpid()))
        reply(rid, {'turn':{'id':'turn'}})
        print(json.dumps({'id':'approval','method':'item/commandExecution/requestApproval','params':{'threadId':p['threadId'],'command':'pwd','cwd':root}}), flush=True)
    elif m in ('thread/name/set','thread/resume'):
        reply(rid, {})
"""#
}
