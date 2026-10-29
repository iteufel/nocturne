import ActivityKit
import Combine
import LocalAuthentication
import NocturneKit
import UIKit
import UserNotifications

/// Optional operator-owned registration boundary. No token is logged or persisted by the app.
/// Configure before calling registerForRemoteNotifications; the relay must authenticate device ownership.
@MainActor enum AttentionPushRegistration {
    static var receiveToken: ((Data) async throws -> Void)?
    static var registrationFailed: (() -> Void)?
}

@MainActor
final class AgentAttentionCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AgentAttentionCenter()
    @Published private(set) var status = "Remote push requires an operator-configured server."
    var notificationsEnabled: Bool { UserDefaults.standard.bool(forKey: "nocturne.attention.notifications") }
    var activitiesEnabled: Bool { UserDefaults.standard.bool(forKey: "nocturne.attention.activities") }
    private weak var model: ClientModel?
    private var observers = Set<AnyCancellable>()
    private var gate = AttentionDecisionGate()
    private var current: [AgentAttention: ChatPermission] = [:]
    private var announced = Set<AgentAttention>()
    private var rendering: Task<Void, Never>?
    private var expiry: Task<Void, Never>?

    func bind(_ model: ClientModel) {
        guard self.model == nil else { return }
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let review = UNNotificationAction(identifier: "review", title: "Review in Nocturne", options: [.foreground, .authenticationRequired])
        let allow = UNNotificationAction(identifier: "allow", title: "Allow once", options: [.foreground, .authenticationRequired])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.foreground, .authenticationRequired, .destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: AgentAttention.category, actions: [review], intentIdentifiers: []),
            UNNotificationCategory(identifier: AgentAttention.approvalCategory, actions: [deny, allow], intentIdentifiers: [])
        ])
        model.chats.$permissions.combineLatest(model.chats.$selected, model.chats.$providerID, model.server.$state)
            .sink { [weak self] _ in
                // @Published emits before the model mutates. Read the settled authenticated state.
                Task { @MainActor [weak self] in self?.refresh() }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &observers)
        if notificationsEnabled, AttentionPushRegistration.receiveToken != nil { UIApplication.shared.registerForRemoteNotifications() }
        refresh()
    }
    func setNotifications(_ enabled: Bool) async {
        if enabled {
            do {
                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else {
                    status = "Notifications are disabled in iOS Settings."; return
                }
            } catch { status = "Notification permission could not be requested."; return }
        }
        UserDefaults.standard.set(enabled, forKey: "nocturne.attention.notifications")
        if enabled, AttentionPushRegistration.receiveToken != nil { UIApplication.shared.registerForRemoteNotifications() }
        refresh(); objectWillChange.send()
    }
    func setActivities(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "nocturne.attention.activities")
        refresh(); objectWillChange.send()
    }
    func registered(_ token: Data) {
        guard let receive = AttentionPushRegistration.receiveToken else { return }
        Task {
            do { try await receive(token); status = "Device registered with the configured push server." }
            catch { status = "Push server registration failed. Try enabling notifications again." }
        }
    }
    func registrationFailed() {
        status = "APNs registration failed. Check signing and operator configuration."
        AttentionPushRegistration.registrationFailed?()
    }
    private func refresh() {
        var next: [AgentAttention: ChatPermission] = [:]
        if let model, model.server.state == .connected, let invitation = model.server.connectedInvitation,
           let session = model.chats.selected {
            let host = WorkspaceIdentity.fingerprint(invitation.secret)
            for permission in model.chats.permissions {
                // Legacy hosts have no authoritative expiry: keep their existing in-app review only.
                guard let deadline = permission.expiresAt, deadline > Date() else { continue }
                let request = AgentAttention(id: permission.id, hostID: host, providerID: model.chats.providerID,
                    sessionID: session.id, expiresAt: deadline, kind: permission.attentionKind ?? .approval)
                next[request] = permission
            }
        }
        current = next; gate.synchronize(Set(next.keys))
        expiry?.cancel()
        if let deadline = next.keys.map(\.expiresAt).min() {
            expiry = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)) }
                catch { return }
                self?.refresh()
            }
        }
        rendering?.cancel()
        let previous = rendering
        rendering = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            await self.render(next)
        }
    }
    private func render(_ snapshot: [AgentAttention: ChatPermission]) async {
        let center = UNUserNotificationCenter.current()
        let visible = notificationsEnabled ? Set(snapshot.keys) : []
        let removed = announced.subtracting(visible)
        center.removeDeliveredNotifications(withIdentifiers: removed.map(\.id))
        center.removePendingNotificationRequests(withIdentifiers: removed.map(\.id))
        announced.subtract(removed)
        for (request, permission) in snapshot where notificationsEnabled && !announced.contains(request) {
            guard !Task.isCancelled else { return }
            let content = UNMutableNotificationContent()
            content.title = AgentAttention.title; content.body = AgentAttention.body; content.sound = .default
            let actions = Set(permission.options.compactMap(\.action))
            content.categoryIdentifier = actions == [.allowOnce, .denyOnce] ? AgentAttention.approvalCategory : AgentAttention.category
            if let data = try? JSONEncoder().encode(request), let object = try? JSONSerialization.jsonObject(with: data) {
                content.userInfo = ["nocturneAttention": object]
            }
            // Only called after the person explicitly enables notifications. Never in tests.
            do { try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil)); announced.insert(request) }
            catch { status = "A local attention notification could not be displayed." }
        }
        for activity in Activity<AttentionAttributes>.activities {
            guard !Task.isCancelled else { return }
            if !activitiesEnabled || snapshot[activity.attributes.request] == nil {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        guard activitiesEnabled, ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        for (request, permission) in snapshot {
            guard !Task.isCancelled else { return }
            guard !Activity<AttentionAttributes>.activities.contains(where: { $0.attributes.request == request }) else { continue }
            let state = AttentionAttributes.ContentState(expiresAt: request.expiresAt,
                canAllow: permission.options.filter { $0.action == .allowOnce }.count == 1,
                canDeny: permission.options.filter { $0.action == .denyOnce }.count == 1)
            do {
                _ = try Activity.request(attributes: AttentionAttributes(request: request),
                    content: ActivityContent(state: state, staleDate: request.expiresAt), pushType: nil)
            } catch { status = "Live Activity could not start. Review the request in Nocturne." }
        }
    }
    func decide(id: String, host: String, provider: String, session: String, allow: Bool) async throws {
        // Explicit OS-delivered action plus local authentication; no background event calls this method.
        let auth = LAContext()
        guard try await auth.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: allow ? "Allow this pending Nocturne request once" : "Deny this pending Nocturne request") else {
            throw AttentionIntentError.unavailable
        }
        refresh()
        guard let model, model.server.state == .connected, let invitation = model.server.connectedInvitation,
              let selected = model.chats.selected,
              let request = current.keys.first(where: { $0.id == id && $0.hostID == host && $0.providerID == provider && $0.sessionID == session }),
              let permission = current[request] else { throw AttentionIntentError.unavailable }
        let choices = permission.options.filter { $0.action == (allow ? .allowOnce : .denyOnce) }
        guard choices.count == 1,
              gate.consume(request, hostID: WorkspaceIdentity.fingerprint(invitation.secret),
                providerID: model.chats.providerID, sessionID: selected.id, now: Date()) else { throw AttentionIntentError.unavailable }
        // Consume before suspension; an uncertain network result is never retried automatically.
        defer { refresh() }
        try await model.chats.decideAttention(request, permission: permission, option: choices[0])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            defer { completionHandler() }
            let info = response.notification.request.content.userInfo
            guard let object = info["nocturneAttention"], let data = try? JSONSerialization.data(withJSONObject: object),
                  let request = try? JSONDecoder().decode(AgentAttention.self, from: data) else { return }
            if response.actionIdentifier == "allow" || response.actionIdentifier == "deny" {
                do { try await self.decide(id: request.id, host: request.hostID, provider: request.providerID,
                    session: request.sessionID, allow: response.actionIdentifier == "allow") }
                catch { self.status = "Request unavailable or authentication cancelled. Review in Nocturne." }
            } else if response.actionIdentifier == "review" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                // Opening a notification only navigates. Payload data can never grant permission.
                self.model?.page = .chats
            }
        }
    }
}
