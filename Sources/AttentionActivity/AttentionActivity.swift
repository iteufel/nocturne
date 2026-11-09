import ActivityKit
import AppIntents
import Foundation
import NocturneKit

struct AttentionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var expiresAt: Date
        var canAllow: Bool
        var canDeny: Bool
    }
    // Opaque locator only. Never add command text or conversation contents.
    let request: AgentAttention
}

struct AttentionDecisionIntent: LiveActivityIntent {
    static var title = LocalizedStringResource("Decide pending Nocturne request", table: "AppIntents")
    static var isDiscoverable: Bool = false
    // Bring authentication UI into the app; perform still executes the exact button decision.
    static var openAppWhenRun: Bool = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: LocalizedStringResource("Request", table: "AppIntents")) var requestID: String
    @Parameter(title: LocalizedStringResource("Host", table: "AppIntents")) var hostID: String
    @Parameter(title: LocalizedStringResource("Provider", table: "AppIntents")) var providerID: String
    @Parameter(title: LocalizedStringResource("Session", table: "AppIntents")) var sessionID: String
    @Parameter(title: LocalizedStringResource("Allow once", table: "AppIntents")) var allow: Bool
    init() {}
    init(_ request: AgentAttention, allow: Bool) {
        requestID = request.id; hostID = request.hostID; providerID = request.providerID
        sessionID = request.sessionID; self.allow = allow
    }
    @MainActor func perform() async throws -> some IntentResult {
        #if !NOCTURNE_ATTENTION_WIDGET
        try await AgentAttentionCenter.shared.decide(id: requestID, host: hostID, provider: providerID, session: sessionID, allow: allow)
        #else
        // LiveActivityIntent executes in the app process; never authorize from the extension.
        throw AttentionIntentError.unavailable
        #endif
        return .result()
    }
}

enum AttentionIntentError: Error { case unavailable }
