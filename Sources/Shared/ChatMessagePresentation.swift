import Foundation

/// Recognize only provider-generated envelopes; ordinary user prose remains untouched.
public enum ChatMessagePresentation {
    public static func summary(_ message: ChatMessage) -> String? {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<realtime_delegation>"), let start = text.range(of: "<input>"),
           let end = text.range(of: "</input>", range: start.upperBound..<text.endIndex) {
            return L("Voice request · ") + String(text[start.upperBound..<end.lowerBound].prefix(240))
        }
        if text.hasPrefix("The following is the Codex agent history added since your last approval assessment.") {
            return L("Agent activity sent for approval review")
        }
        if text.contains(">>> APPROVAL REQUEST END"), text.contains("APPROVAL REQUEST") { return L("Approval request details") }
        if message.role == .assistant, text.hasPrefix("{"),
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let outcome = object["outcome"] as? String, object["risk_level"] is String, object["user_authorization"] is String {
            return outcome == "allow" ? L("Action approved") : outcome == "deny" ? L("Action declined") : L("Approval review · ") + outcome
        }
        return nil
    }
}
