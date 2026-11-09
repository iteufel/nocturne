import XCTest
import NocturneKit
@testable import NocturneHostKit

@MainActor
final class AttentionHostTests: XCTestCase {
    private var root: URL!
    private var agent: ChatAgentSession!
    private var events: [ChatEvent] = []
    override func tearDownWithError() throws {
        agent?.close(); agent = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    private func start(_ mode: String, lifetime: TimeInterval = 300) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-attention-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("fixture.py")
        try Self.fixture.write(to: fixture, atomically: true, encoding: .utf8)
        agent = try ChatAgentSession(configuration: .init(id: "codex", name: "Fixture", transport: .codex,
            executable: "/usr/bin/python3", arguments: ["-u", fixture.path, root.path]), directory: root, approvalLifetime: lifetime)
        try await agent.initialize()
        let session = try await agent.create()
        agent.emit = { [weak self] in self?.events.append($0) }
        try await agent.prompt(session.id, text: mode)
        try await wait { self.events.contains { $0.permission != nil } }
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fixture event timed out"); throw NocturneError.timeout
    }
    private var responseFile: URL { root.appendingPathComponent("response.json") }
    private func response() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: responseFile)) as? [String: Any])
    }
    func testRealRPCNeedsExplicitExactSessionChoiceAndConsumesOnce() async throws {
        try await start("approval")
        let permission = try XCTUnwrap(events.compactMap(\.permission).first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseFile.path), "Displaying an event must not approve it")
        XCTAssertThrowsError(try agent.approve(permission.id, option: "accept", session: "another-session"))
        XCTAssertThrowsError(try agent.approve(permission.id, option: "invented", session: "thread"))
        XCTAssertEqual(permission.options.first?.action, .allowOnce)
        try agent.approve(permission.id, option: "decline", session: "thread")
        XCTAssertThrowsError(try agent.approve(permission.id, option: "accept", session: "thread"))
        try await wait { FileManager.default.fileExists(atPath: self.responseFile.path) }
        XCTAssertEqual(try response()["decision"] as? String, "decline")
    }
    func testProviderRestrictedDecisionsCannotBeExpandedByClient() async throws {
        try await start("restricted")
        let permission = try XCTUnwrap(events.compactMap(\.permission).first)
        XCTAssertEqual(permission.options.map(\.id), ["decline"])
        XCTAssertThrowsError(try agent.approve(permission.id, option: "accept", session: "thread"))
        try agent.approve(permission.id, option: "decline", session: "thread")
        try await wait { FileManager.default.fileExists(atPath: self.responseFile.path) }
        XCTAssertEqual(try response()["decision"] as? String, "decline")
    }
    func testQuestionExpiryNeverSelectsPartiallyAnsweredChoices() async throws {
        try await start("questions", lifetime: 0.15)
        try await wait { self.events.compactMap(\.permission).count == 2 }
        let questions = events.compactMap(\.permission)
        try agent.approve(questions[0].id, option: "0", session: "thread")
        try await wait { FileManager.default.fileExists(atPath: self.responseFile.path) }
        XCTAssertEqual(try response()["answers"] as? [String: String], [:])
        XCTAssertThrowsError(try agent.approve(questions[1].id, option: "0", session: "thread"))
    }
    func testExpiredRPCIsCancelledAndNeverGranted() async throws {
        try await start("approval", lifetime: 0.08)
        let permission = try XCTUnwrap(events.compactMap(\.permission).first)
        try await wait { self.events.contains { $0.kind == .permissionResolved } }
        XCTAssertThrowsError(try agent.approve(permission.id, option: "accept", session: "thread"))
        try await wait { FileManager.default.fileExists(atPath: self.responseFile.path) }
        XCTAssertEqual(try response()["decision"] as? String, "cancel")
    }
    func testProviderResolutionInvalidatesDisplayedRequest() async throws {
        try await start("resolved")
        let permission = try XCTUnwrap(events.compactMap(\.permission).first)
        try await wait { self.events.contains { $0.kind == .permissionResolved } }
        XCTAssertThrowsError(try agent.approve(permission.id, option: "accept", session: "thread"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseFile.path))
    }
    func testQuestionsReturnExactAnswersOnlyAfterAllExplicitSelections() async throws {
        try await start("questions")
        try await wait { self.events.compactMap(\.permission).count == 2 }
        let questions = events.compactMap(\.permission)
        XCTAssertTrue(questions.allSatisfy { $0.attentionKind == .question && $0.options.allSatisfy { $0.action == nil } })
        try agent.approve(questions[0].id, option: "0", session: "thread")
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseFile.path))
        try agent.approve(questions[1].id, option: "1", session: "thread")
        try await wait { FileManager.default.fileExists(atPath: self.responseFile.path) }
        let answers = try XCTUnwrap(try response()["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers, ["q1": ["answers": ["Accept"]], "q2": ["answers": ["Decline"]]])
    }
    private static let fixture = #"""
import json, sys, os
root = sys.argv[1]
def send(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    msg = json.loads(line)
    if 'method' not in msg:
        if msg.get('id') == 900 and 'result' in msg:
            path = os.path.join(root, 'response.json')
            with open(path + '.tmp', 'w') as f: json.dump(msg['result'], f)
            os.replace(path + '.tmp', path)
        continue
    method, ident = msg['method'], msg.get('id')
    if ident is None: continue
    result = {}
    if method == 'thread/start': result = {'thread': {'id': 'thread', 'cwd': root, 'preview': 'Fixture', 'updatedAt': 1}}
    if method == 'turn/start': result = {'turn': {'id': 'turn'}}
    send({'id': ident, 'result': result})
    if method == 'turn/start':
        mode = msg['params']['input'][0]['text']
        params = {'threadId': 'thread', 'turnId': 'turn', 'itemId': 'item'}
        request_method = 'item/commandExecution/requestApproval'
        if mode == 'restricted': params['availableDecisions'] = ['decline', 'cancel']
        if mode == 'questions':
            request_method = 'item/tool/requestUserInput'
            choices = [{'label': 'Accept', 'description': 'yes'}, {'label': 'Decline', 'description': 'no'}]
            params['questions'] = [{'id': q, 'header': 'Choice', 'question': 'Proceed?', 'options': choices} for q in ['q1', 'q2']]
        send({'id': 900, 'method': request_method, 'params': params})
        if mode == 'resolved': send({'method': 'serverRequest/resolved', 'params': {'threadId': 'thread', 'requestId': 900}})
"""#
}
