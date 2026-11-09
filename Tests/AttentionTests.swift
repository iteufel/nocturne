import XCTest
import NocturneKit
@testable import NocturneHostKit

final class AttentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func request(kind: AgentAttention.Kind = .approval, deadline: Date? = nil) -> AgentAttention {
        AgentAttention(id: "request-1", hostID: "host-key-fingerprint", providerID: "codex", sessionID: "thread-1",
            expiresAt: deadline ?? now.addingTimeInterval(30), kind: kind)
    }
    func testGateRequiresExactPendingHostProviderSessionAndDeadline() {
        let request = request(); var gate = AttentionDecisionGate()
        XCTAssertFalse(gate.consume(request, hostID: request.hostID, providerID: request.providerID, sessionID: request.sessionID, now: now))
        gate.synchronize([request])
        for fields in [("other-host", "codex", "thread-1"), (request.hostID, "claude", "thread-1"), (request.hostID, "codex", "other-thread")] {
            XCTAssertFalse(gate.consume(request, hostID: fields.0, providerID: fields.1, sessionID: fields.2, now: now))
        }
        XCTAssertFalse(gate.consume(request, hostID: request.hostID, providerID: request.providerID, sessionID: request.sessionID, now: request.expiresAt))
        XCTAssertTrue(gate.consume(request, hostID: request.hostID, providerID: request.providerID, sessionID: request.sessionID, now: now))
        gate.synchronize([request]) // A late publisher event cannot re-arm a consumed action.
        XCTAssertFalse(gate.consume(request, hostID: request.hostID, providerID: request.providerID, sessionID: request.sessionID, now: now))
    }
    func testCompletionDisconnectColdStartAndQuestionsCannotGrant() {
        var gate = AttentionDecisionGate(); let item = request()
        gate.synchronize([item]); gate.synchronize([])
        XCTAssertFalse(gate.consume(item, hostID: item.hostID, providerID: item.providerID, sessionID: item.sessionID, now: now))
        let question = request(kind: .question); gate.synchronize([question])
        XCTAssertFalse(gate.consume(question, hostID: question.hostID, providerID: question.providerID, sessionID: question.sessionID, now: now))
    }
    func testPayloadIsGenericAndReviewOnlyAndLocatorRoundTrips() throws {
        let item = request(), payload = try item.pushPayload()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let aps = try XCTUnwrap(object["aps"] as? [String: Any])
        XCTAssertEqual(aps["category"] as? String, AgentAttention.category)
        let alert = try XCTUnwrap(aps["alert"] as? [String: String])
        XCTAssertEqual(alert, ["title": AgentAttention.title, "body": AgentAttention.body])
        XCTAssertEqual(Set(object.keys), ["aps", "nocturneAttention"])
        let locator = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["nocturneAttention"]))
        XCTAssertEqual(try JSONDecoder().decode(AgentAttention.self, from: locator), item)
    }
    func testLegacyPermissionDecodesWithoutActionOrExpiry() throws {
        let data = Data(#"{"id":"old","title":"Approve","detail":"private","options":[{"id":"accept","title":"Allow","destructive":false}]}"#.utf8)
        let permission = try JSONDecoder().decode(ChatPermission.self, from: data)
        XCTAssertNil(permission.expiresAt); XCTAssertNil(permission.options.first?.action)
    }
    func testQuestionsKeepProviderAnswersAndRejectSecretOtherDuplicateAndUnboundedForms() throws {
        let choice: [String: Any] = ["label": "Accept", "description": "One exact provider answer"]
        let row: [String: Any] = ["id": "q1", "header": "Choice", "question": "Proceed?", "options": [choice]]
        let parsed = try XCTUnwrap(CodexAttentionQuestions.parse(["questions": [row]]).first)
        XCTAssertEqual(parsed.labels["0"], "Accept"); XCTAssertNil(parsed.options.first?.action)
        for field in ["isSecret", "isOther"] {
            var bad = row; bad[field] = true
            XCTAssertThrowsError(try CodexAttentionQuestions.parse(["questions": [bad]]))
        }
        XCTAssertThrowsError(try CodexAttentionQuestions.parse(["questions": [row, row]]))
        XCTAssertThrowsError(try CodexAttentionQuestions.parse(["questions": []]))
        var bad = row; bad["options"] = [choice, choice]
        XCTAssertThrowsError(try CodexAttentionQuestions.parse(["questions": [bad]]))
    }
}
