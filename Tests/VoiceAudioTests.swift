import XCTest
import NocturneKit

final class VoiceAudioTests: XCTestCase {
    func testSDPRejectsMissingAudioFingerprintAndOversizedSignaling() throws {
        for sdp in ["", "v=0\nm=video 9 RTP/AVP 96", "v=0\nm=audio 9 RTP/AVP 111", "v=0\nm=audio 9 RTP/AVP 111\na=fingerprint:" + String(repeating: "x", count: ChatVoice.maximumSDPBytes)] {
            XCTAssertThrowsError(try ChatVoice.validateSDP(sdp))
        }
        XCTAssertNoThrow(try ChatVoice.validateSDP("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=fingerprint:sha-256 fixture\r\n"))
    }
    func testBackendErrorsDistinguishAuthenticationPermissionAndProtocolWithoutSecrets() {
        XCTAssertTrue(ChatVoice.failure("HTTP 401 unauthorized").contains("authentication failed"))
        XCTAssertTrue(ChatVoice.failure("HTTP 403 permission denied").contains("access denied"))
        let raw = #"{"error":{"message":"AVAS requires OpenAI-Alpha: quicksilver=v2.","code":"invalid_quicksilver_alpha_header"}}"#
        XCTAssertTrue(ChatVoice.failure(raw).contains("protocol error (invalid_quicksilver_alpha_header)"))
        let sanitized = ChatVoice.failure("401 Bearer eyJfixture.value.signature sk-fixture-token")
        XCTAssertFalse(sanitized.contains("eyJfixture")); XCTAssertFalse(sanitized.contains("sk-fixture"))
        XCTAssertLessThan(ChatVoice.failure(String(repeating: "x", count: 10000)).count, 1300)
    }
}
