import Foundation

public enum ChatVoice {
    public static let capability = "codex-webrtc-voice-v1"
    public static let leaseTimeout: TimeInterval = 10
    public static let maximumSDPBytes = 131_072
    public static func validateSDP(_ sdp: String) throws {
        let lines = sdp.replacingOccurrences(of: "\r\n", with: "\n")
        guard sdp.utf8.count <= maximumSDPBytes, sdp.hasPrefix("v=0"),
              lines.contains("\nm=audio "), lines.contains("\na=fingerprint:") else { throw NocturneError.invalidFrame }
    }
    /// Keep diagnostics useful without returning raw response bodies, HTML or credentials.
    public static func failure(_ raw: String) -> String {
        var message = raw, code: String?
        if let data = raw.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = value["error"] as? [String: Any] {
            message = error["message"] as? String ?? "The backend rejected the call."
            code = error["code"] as? String
        }
        for pattern in [#"(?i)Bearer\s+[^\s\"<>]+"#, #"eyJ[A-Za-z0-9_.-]+"#, #"sk-[A-Za-z0-9_-]+"#] {
            message = message.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        if message.contains("<html") || message.contains("<!DOCTYPE") { message = "The voice backend returned an unexpected HTTP response." }
        let lower = message.lowercased()
        let category: String
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("authentication") || lower.contains("token expired") {
            category = "ChatGPT authentication failed"
        } else if lower.contains("403") || lower.contains("permission") || lower.contains("not entitled") || lower.contains("not allowed") || lower.contains("access denied") {
            category = "ChatGPT voice access denied"
        } else if lower.contains("invalid") || lower.contains("requires") || code?.hasPrefix("invalid_") == true {
            category = "Codex voice protocol error"
        } else { category = "Codex voice failed" }
        let safeCode = code.flatMap { $0.range(of: #"^[a-zA-Z0-9_.-]{1,100}$"#, options: .regularExpression) != nil ? $0 : nil }
        return "\(category)\(safeCode.map { " (\($0))" } ?? ""): \(String(message.prefix(1200)))"
    }
}

/// Only signaling travels over the paired workspace connection. Audio uses encrypted WebRTC media.
public struct ChatVoiceEvent: Codable, Equatable {
    public enum Kind: String, Codable { case started, answer, speechStarted, closed, failed }
    public let voiceID: String
    public let providerID: String
    public let sessionID: String
    public var kind: Kind
    public var sdp: String?
    public var detail: String?
    public init(voiceID: String, providerID: String, sessionID: String, kind: Kind, sdp: String? = nil, detail: String? = nil) {
        self.voiceID = voiceID; self.providerID = providerID; self.sessionID = sessionID
        self.kind = kind; self.sdp = sdp; self.detail = detail
    }
}
