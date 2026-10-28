import XCTest
import NocturneKit

@MainActor
final class ChatNavigationTests: XCTestCase {
    func testSnoozeWakeAndSettledStatePersistAndStayIsolatedPerMacAndProvider() throws {
        let suite = "Nocturne-navigation-" + UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = ChatNavigationState(scope: "mac-a.codex", defaults: preferences)
        let now = Date(timeIntervalSince1970: 1000)
        state.snooze("thread", until: now.addingTimeInterval(60))
        XCTAssertEqual(state.group("thread", active: nil, now: now), .snoozed)
        XCTAssertEqual(state.group("thread", active: "thread", now: now), .working)
        XCTAssertEqual(state.group("thread", active: nil, now: now.addingTimeInterval(61)), .recent)
        state.settle("thread", true)
        state.rename("thread", title: "Review voice")
        state.saveDraft("Keep this unsent text", for: "thread")
        let restored = ChatNavigationState(scope: "mac-a.codex", defaults: preferences)
        XCTAssertEqual(restored.group("thread", active: nil), .settled)
        XCTAssertEqual(restored.entry("thread").draft, "Keep this unsent text")
        XCTAssertEqual(restored.title(ChatSessionInfo(id: "thread", title: "Original", directory: "/project")), "Review voice")
        XCTAssertNil(ChatNavigationState(scope: "mac-b.codex", defaults: preferences).entry("thread").draft)
        XCTAssertNil(ChatNavigationState(scope: "mac-a.claude", defaults: preferences).entry("thread").draft)
        restored.settle("thread", false)
        XCTAssertEqual(restored.group("thread", active: nil), .recent)
    }
    func testSupervisorVoicePreferenceIsOptInAndScoped() throws {
        let suite = "Nocturne-voice-preference-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ChatNavigationState(scope: "mac-a.codex", defaults: defaults)
        XCTAssertFalse(state.supervisorStartsVoice)
        state.supervisorStartsVoice = true
        XCTAssertTrue(ChatNavigationState(scope: "mac-a.codex", defaults: defaults).supervisorStartsVoice)
        XCTAssertFalse(ChatNavigationState(scope: "mac-b.codex", defaults: defaults).supervisorStartsVoice)
    }
    func testProviderEnvelopesCollapseWithoutChangingOrdinaryMessages() {
        let voice = ChatMessage(id: "voice", role: .user, text: "<realtime_delegation>\n<input>Fix the chat</input>\n<transcript_delta>user: hello</transcript_delta>\n</realtime_delegation>")
        XCTAssertEqual(ChatMessagePresentation.summary(voice), "Voice request · Fix the chat")
        XCTAssertEqual(ChatMessagePresentation.summary(.init(id: "review", role: .assistant, text: #"{"risk_level":"low","user_authorization":"high","outcome":"allow","rationale":"Read only"}"#)), "Action approved")
        XCTAssertNil(ChatMessagePresentation.summary(.init(id: "normal", role: .user, text: "Explain <realtime_delegation> to me")))
        XCTAssertNil(ChatMessagePresentation.summary(.init(id: "json", role: .assistant, text: #"{"outcome":"allow"}"#)))
        XCTAssertNil(ChatMessagePresentation.summary(.init(id: "partial", role: .user, text: "<realtime_delegation><input>Incomplete")))
    }
    func testOnlyExactNativeSlashCommandsAreIntercepted() {
        XCTAssertEqual(ChatSlashCommand.parse(" /changes\n"), .changes)
        XCTAssertEqual(ChatSlashCommand.parse("/pr"), .pr)
        for text in ["/review my changes", "/unknown", "/new extra", "Explain /changes", "/"] { XCTAssertNil(ChatSlashCommand.parse(text)) }
    }
    func testAgentPRContextContainsActualReferencesAndStaysWithinPromptBudget() {
        let request = PullRequestInfo(number: 7, title: "Voice changes", body: String(repeating: "大", count: 30_000), author: "Developer", state: "open", draft: false, source: "feature/voice", target: "main", url: "https://github.com/example/app/pull/7")
        let prompt = PullRequestAgentPrompt.make(request, files: [.init(path: "Voice.swift", indexStatus: "M", worktreeStatus: " ")], activity: [], task: .guide)
        XCTAssertTrue(prompt.contains(request.url)); XCTAssertTrue(prompt.contains("Source: feature/voice"))
        XCTAssertLessThan(prompt.utf8.count, ChatProtocol.maximumPromptBytes)
        XCTAssertLessThan(prompt.utf8.count, ChatProtocol.messagePartBytes, "Native helper context must fit one message part")
        XCTAssertEqual(PullRequestAgentPrompt.summary(prompt), "Write a review guide for PR #7")
        XCTAssertNil(PullRequestAgentPrompt.summary("Explain this pull request please"))
        let small = PullRequestInfo(number: 8, title: "Fix", body: "Description", author: "Developer", state: "active", draft: false, source: "feature/fix", target: "main", url: "https://dev.azure.com/org/project/_git/repo/pullrequest/8")
        let feedback = PullRequestAgentPrompt.make(small, files: [.init(path: "Sources/Voice.swift", indexStatus: "M", worktreeStatus: " ")], activity: [.init(id: "1", author: "Reviewer", text: "Fix cancellation")], task: .feedback)
        XCTAssertTrue(feedback.contains("Sources/Voice.swift")); XCTAssertTrue(feedback.contains("Reviewer: Fix cancellation")); XCTAssertTrue(feedback.contains("Do not post comments, push or merge"))
    }
}
