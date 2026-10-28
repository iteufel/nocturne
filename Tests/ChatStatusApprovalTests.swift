import XCTest
import NocturneKit
@testable import NocturneHostKit

@MainActor
final class ChatStatusApprovalTests: XCTestCase {
    private var root: URL!
    private var agent: ChatAgentSession!
    private var events: [ChatEvent] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-chat-policy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.fixture.write(to: root.appendingPathComponent("agent.py"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws {
        agent?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    private func start(acp: Bool = false) async throws -> ChatSessionInfo {
        agent = try ChatAgentSession(configuration: .init(id: acp ? "claude" : "codex", name: "Fixture", transport: acp ? .acp : .codex,
            executable: "/usr/bin/python3", arguments: ["-u", root.appendingPathComponent("agent.py").path, root.path, acp ? "acp" : "codex"]), directory: root)
        try await agent.initialize()
        let session = try await agent.create()
        agent.emit = { [weak self] in self?.events.append($0) }
        return session
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fixture timed out"); throw NocturneError.timeout
    }
    private func response() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("response.json"))) as? [String: Any])
    }
    func testCodexRestrictedChoicesAndExactPersistentPayload() throws {
        let method = "item/commandExecution/requestApproval"
        let restricted = ChatAgentSession.codexApprovalOptions(method: method, params: ["availableDecisions": ["decline"], "proposedExecpolicyAmendment": ["swift", "test"]])
        XCTAssertEqual(restricted.options.map(\.id), ["decline"])
        let empty = ChatAgentSession.codexApprovalOptions(method: method, params: ["availableDecisions": []])
        XCTAssertTrue(empty.options.isEmpty)
        XCTAssertTrue(ChatAgentSession.codexApprovalOptions(method: method, params: ["availableDecisions": "malformed"]).options.isEmpty)
        let amendment: [String: Any] = ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["swift", "test"]]]
        let offered = ChatAgentSession.codexApprovalOptions(method: method, params: ["availableDecisions": ["acceptForSession", amendment], "proposedExecpolicyAmendment": ["swift", "test"]])
        XCTAssertEqual(offered.options.map(\.id), ["acceptForSession", "execpolicy"])
        XCTAssertTrue(offered.options.last?.scope?.contains("other chats") == true)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: offered.decisions["execpolicy"]!, options: [.sortedKeys]), try JSONSerialization.data(withJSONObject: amendment, options: [.sortedKeys]))
        let mismatch = ChatAgentSession.codexApprovalOptions(method: method, params: ["availableDecisions": [amendment], "proposedExecpolicyAmendment": ["sh"]])
        XCTAssertTrue(mismatch.options.isEmpty)
        let files = ChatAgentSession.codexApprovalOptions(method: "item/fileChange/requestApproval", params: [:])
        XCTAssertEqual(files.options.map(\.id), ["accept", "acceptForSession", "decline", "cancel"])
        XCTAssertNil(files.decisions["execpolicy"])
    }
    func testSessionApprovalRequiresUserChoiceAndCannotBeReplayed() async throws {
        let session = try await start()
        try await agent.prompt(session.id, text: "approval")
        try await wait { self.events.contains { $0.permission != nil } }
        let permission = try XCTUnwrap(events.compactMap(\.permission).first)
        XCTAssertEqual(permission.options.map(\.id), ["accept", "acceptForSession", "decline"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("response.json").path))
        XCTAssertThrowsError(try agent.approve(permission.id, option: "execpolicy"))
        try agent.approve(permission.id, option: "acceptForSession")
        XCTAssertThrowsError(try agent.approve(permission.id, option: "acceptForSession"))
        try await wait { self.events.contains { $0.kind == .completed } }
        XCTAssertEqual(try response()["decision"] as? String, "acceptForSession")
        XCTAssertTrue(events.contains { $0.kind == .permissionResolved && $0.detail == permission.id })
    }
    func testPermissionProfileScopeAndDenialNeverGrantExtraAccess() async throws {
        let session = try await start()
        for choice in ["acceptForSession", "decline"] {
            events = []
            try await agent.prompt(session.id, text: "permissions")
            try await wait { self.events.contains { $0.permission != nil } }
            let permission = try XCTUnwrap(events.compactMap(\.permission).first)
            XCTAssertFalse(permission.options.contains { $0.id == "cancel" })
            try agent.approve(permission.id, option: choice)
            try await wait { self.events.contains { $0.kind == .completed } }
            let result = try response()
            XCTAssertEqual(result["scope"] as? String, choice == "acceptForSession" ? "session" : "turn")
            let granted = try XCTUnwrap(result["permissions"] as? [String: Any])
            XCTAssertEqual(granted.isEmpty, choice == "decline")
        }
    }
    func testPersistentApprovalSendsOnlyProviderProposedRule() async throws {
        let session = try await start()
        try await agent.prompt(session.id, text: "persistent")
        try await wait { self.events.contains { $0.permission != nil } }
        let permission = try XCTUnwrap(events.compactMap(\.permission).first)
        try agent.approve(permission.id, option: "execpolicy")
        try await wait { self.events.contains { $0.kind == .completed } }
        let decision = try XCTUnwrap(try response()["decision"] as? [String: Any])
        let amendment = try XCTUnwrap(decision["acceptWithExecpolicyAmendment"] as? [String: Any])
        XCTAssertEqual(amendment["execpolicy_amendment"] as? [String], ["swift", "test"])
    }
    func testProviderResolutionClearsPendingWithoutSendingDecision() async throws {
        let session = try await start()
        try await agent.prompt(session.id, text: "resolved")
        try await wait { self.events.contains { $0.kind == .permissionResolved } }
        let permission = try XCTUnwrap(events.compactMap(\.permission).first)
        XCTAssertThrowsError(try agent.approve(permission.id, option: "accept"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("response.json").path))
        try await agent.cancel(session.id)
    }
    func testPolicyIsExplicitChatLocalReversibleAndDoesNotGrantAccess() async throws {
        let first = try await start(), second = try await agent.create()
        var options = try await agent.options(for: first.id)
        XCTAssertEqual(options.first { $0.id == "nocturne.approvalPolicy" }?.value, "on-request")
        options = try await agent.configure(first.id, id: "nocturne.approvalPolicy", value: "never")
        XCTAssertEqual(options.first { $0.id == "nocturne.approvalPolicy" }?.value, "never")
        do { _ = try await agent.configure(first.id, id: "nocturne.approvalPolicy", value: "bypass"); XCTFail("Unknown policy accepted") } catch {}
        try await agent.prompt(first.id, text: "policy")
        try await wait { self.events.contains { $0.kind == .completed } }
        XCTAssertEqual(try response()["approvalPolicy"] as? String, "never")
        XCTAssertNil(try response()["sandboxPolicy"])
        events = []
        try await agent.prompt(second.id, text: "policy")
        try await wait { self.events.contains { $0.kind == .completed } }
        XCTAssertNil(try response()["approvalPolicy"], "Another chat keeps its existing default")
        _ = try await agent.configure(first.id, id: "nocturne.approvalPolicy", value: "on-request")
        events = []
        try await agent.prompt(first.id, text: "policy")
        try await wait { self.events.contains { $0.kind == .completed } }
        XCTAssertEqual(try response()["approvalPolicy"] as? String, "on-request")
    }
    func testManagedPoliciesCannotBeSelectedEvenByForgedClientRequest() async throws {
        try #"["on-request"]"#.write(to: root.appendingPathComponent("requirements.json"), atomically: true, encoding: .utf8)
        let session = try await start()
        let options = try await agent.options(for: session.id)
        XCTAssertEqual(options.first { $0.id == "nocturne.approvalPolicy" }?.choices.map(\.value), ["on-request"])
        do { _ = try await agent.configure(session.id, id: "nocturne.approvalPolicy", value: "never"); XCTFail("Managed restriction ignored") } catch {}
        try await agent.prompt(session.id, text: "policy")
        try await wait { self.events.contains { $0.kind == .completed } }
        XCTAssertNil(try response()["approvalPolicy"])
    }
    func testCodexActivityTracksProviderPhasesAndFailureEndsTurn() async throws {
        let session = try await start()
        try await agent.prompt(session.id, text: "failed")
        try await wait { self.events.contains { $0.kind == .failed } }
        XCTAssertEqual(events.compactMap(\.activity).map(\.phase), [.working, .thinking, .tool, .working])
        XCTAssertFalse(agent.isResponding)
        XCTAssertEqual(events.last?.detail, "Fixture failure")
        XCTAssertFalse(events.compactMap(\.activity).contains { $0.detail.contains("%") })
    }
    func testACPUsesOnlyAdvertisedModesAndDurableChoices() async throws {
        let session = try await start(acp: true)
        let options = try await agent.options(for: session.id)
        XCTAssertEqual(options.first?.value, "default")
        XCTAssertEqual(options.first?.choices.map(\.value), ["default", "auto"])
        let configured = try await agent.configure(session.id, id: "nocturne.acpMode", value: "auto")
        XCTAssertEqual(configured.first?.value, "auto")
        let task = Task { try await agent.prompt(session.id, text: "approval") }
        try await wait { self.events.contains { $0.permission != nil } }
        let permission = try XCTUnwrap(events.compactMap(\.permission).first)
        XCTAssertEqual(permission.options.map(\.id), ["once", "remember", "reject"])
        XCTAssertTrue(permission.options[1].scope?.contains("Provider remembers") == true)
        XCTAssertTrue(events.contains { $0.activity?.phase == .tool })
        try agent.approve(permission.id, option: "remember")
        try await task.value
        XCTAssertEqual((try response()["outcome"] as? [String: Any])?["optionId"] as? String, "remember")
    }
    func testNewOptionalMetadataDecodesOldWirePayloads() throws {
        let option = try JSONDecoder().decode(ChatPermissionOption.self, from: Data(#"{"id":"a","title":"Allow","destructive":false}"#.utf8))
        XCTAssertNil(option.scope)
        let event = try JSONDecoder().decode(ChatEvent.self, from: Data(#"{"providerID":"codex","sessionID":"s","kind":"configured"}"#.utf8))
        XCTAssertNil(event.activity)
        XCTAssertFalse(ChatActivity(.waiting, "Waiting for approval").isActive)
        XCTAssertFalse(ChatActivity(.failed, "Failed").isActive)
        XCTAssertTrue(ChatActivity(.tool, "Reading file").isActive)
    }
    private static let fixture = #"""
import json, os, sys
root, transport = sys.argv[1:]
count = 0
sid = None
pending = None
def send(v): print(json.dumps(v), flush=True)
def reply(i, v): send({'jsonrpc':'2.0','id':i,'result':v})
def event(m,p): send({'jsonrpc':'2.0','method':m,'params':p})
def save(v):
    with open(os.path.join(root,'response.json'),'w') as f: json.dump(v,f)
for line in sys.stdin:
    q=json.loads(line); m=q.get('method'); p=q.get('params',{}); i=q.get('id')
    if m=='initialize': reply(i, {'protocolVersion':1,'agentCapabilities':{}} if transport=='acp' else {})
    elif m=='initialized': pass
    elif m in ('thread/start','session/new'):
        count+=1; sid='chat-'+str(count)
        assert 'approvalPolicy' not in p or p['approvalPolicy']=='on-request'
        assert 'sandbox' not in p or p['sandbox']=='workspace-write'
        reply(i, {'thread':{'id':sid,'cwd':root}} if transport=='codex' else {'sessionId':sid,'modes':{'currentModeId':'default','availableModes':[{'id':'default','name':'Manual'},{'id':'auto','name':'Auto','description':'Provider auto mode'}]}})
    elif m=='configRequirements/read':
        path=os.path.join(root,'requirements.json')
        reply(i, {'requirements':{'allowedApprovalPolicies':json.load(open(path))}} if os.path.exists(path) else {'requirements':None})
    elif m=='model/list': reply(i, {'data':[{'model':'fixture','displayName':'Fixture','isDefault':True}]})
    elif m=='thread/read': reply(i, {'thread':{'id':p['threadId'],'cwd':root,'model':'fixture'}})
    elif m=='session/set_mode':
        assert p['modeId'] in ['default','auto']; reply(i,{})
    elif m=='turn/start':
        sid=p['threadId']; text=p['input'][0]['text']
        reply(i,{'turn':{'id':'turn','status':'inProgress'}})
        event('turn/started',{'threadId':sid,'turn':{'id':'turn'}})
        if text=='policy':
            save(p); event('turn/completed',{'threadId':sid,'turn':{'status':'completed'}})
        elif text in ['permissions','persistent']:
            params={'threadId':sid,'turnId':'turn','itemId':'cmd'}
            if text=='permissions':
                params['permissions']={'network':{'enabled':True}}
            else:
                params['proposedExecpolicyAmendment']=['swift','test']
            send({'jsonrpc':'2.0','id':'approval','method':'item/permissions/requestApproval' if text=='permissions' else 'item/commandExecution/requestApproval','params':params})
        elif text=='failed':
            for item in [{'type':'reasoning'},{'type':'commandExecution','command':'echo test'}]: event('item/started',{'threadId':sid,'item':item})
            event('item/completed',{'threadId':sid,'item':{'id':'cmd','type':'commandExecution','status':'failed'}})
            event('turn/completed',{'threadId':sid,'turn':{'status':'failed','error':{'message':'Fixture failure'}}})
        else:
            send({'jsonrpc':'2.0','id':'approval','method':'item/commandExecution/requestApproval','params':{'threadId':sid,'turnId':'turn','itemId':'cmd','command':'pwd','availableDecisions':['accept','acceptForSession','decline']}})
            if text=='resolved': event('serverRequest/resolved',{'threadId':sid,'requestId':'approval'})
    elif m=='turn/interrupt':
        reply(i,{}); event('turn/completed',{'threadId':sid,'turn':{'status':'interrupted'}})
    elif m=='session/prompt':
        sid=p['sessionId']; pending=i
        event('session/update',{'sessionId':sid,'update':{'sessionUpdate':'tool_call','toolCallId':'tool','title':'Read file','status':'in_progress'}})
        send({'jsonrpc':'2.0','id':'approval','method':'session/request_permission','params':{'sessionId':sid,'toolCall':{'title':'Read file'},'options':[{'optionId':'once','name':'Allow once','kind':'allow_once'},{'optionId':'remember','name':'Remember','kind':'allow_always'},{'optionId':'reject','name':'Deny','kind':'reject_once'}]}})
    elif m is None and i=='approval':
        save(q['result'])
        if transport=='acp': reply(pending,{'stopReason':'end_turn'})
        else: event('turn/completed',{'threadId':sid,'turn':{'status':'completed'}})
    else:
        if i is not None: send({'jsonrpc':'2.0','id':i,'error':{'code':-32601,'message':'Unsupported '+str(m)}})
"""#
}
