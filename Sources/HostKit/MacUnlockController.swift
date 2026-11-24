import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import NocturneKit
import Security

struct UnlockConsoleSession: Equatable {
    let userID: UInt32
    let sessionID: Int
    let locked: Bool
    let user: String
}

/// The native seam includes submission and cleanup of one bound lock-screen field.
struct MacUnlockEnvironment {
    var session: () -> UnlockConsoleSession?
    var submit: (String, UnlockConsoleSession, @escaping () -> Bool) async throws -> (() -> Void)
    var now: () -> Date = Date.init
    var pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }
}

@MainActor
public final class MacUnlockController {
    private final class Attempt {
        let id: String
        let connection: UUID
        var cancelled = false
        init(id: String, connection: UUID) { self.id = id; self.connection = connection }
    }
    private let environment: MacUnlockEnvironment
    private var active: Attempt?
    private var nextAttempt = Date.distantPast
    public convenience init() { self.init(environment: NativeMacUnlock.environment()) }
    init(environment: MacUnlockEnvironment) { self.environment = environment }
    public func disconnected(_ connection: UUID) {
        if active?.connection == connection { active?.cancelled = true }
    }
    public func handle(_ packet: Packet, connection: UUID, isConnected: @escaping () -> Bool) async throws -> Packet {
        defer { packet.unlockPassword?.clear() }
        guard isConnected() else { throw NocturneError.disconnected }
        var reply = packet.reply()
        switch packet.operation {
        case .macLockStatus:
            reply.macLockStatus = status(); return reply
        case .macUnlockCancel:
            if active?.connection == connection, active?.id == packet.sessionID { active?.cancelled = true }
            return reply
        case .macUnlock:
            guard let password = packet.unlockPassword else { throw NocturneError.invalidFrame }
            guard let session = environment.session() else {
                throw NocturneError.remote("Sign in to this Mac locally before using remote unlock. FileVault startup cannot be unlocked by Nocturne.")
            }
            if !session.locked { reply.macLockStatus = status(); return reply }
            guard active == nil else { throw NocturneError.remote("Another unlock attempt is in progress.") }
            guard environment.now() >= nextAttempt else { throw NocturneError.remote("Wait 30 seconds before another unlock attempt.") }
            let attempt = Attempt(id: packet.id, connection: connection); active = attempt
            let deadline = environment.now().addingTimeInterval(12)
            // One deliberate submission, shared across all paired connections. Never auto-retry a password.
            nextAttempt = environment.now().addingTimeInterval(30)
            defer { if active === attempt { active = nil } }
            let canSubmit = { [self] in
                !attempt.cancelled && isConnected() && !Task.isCancelled && environment.now() < deadline && environment.session() == session
            }
            guard canSubmit() else { throw NocturneError.disconnected }
            var value = try password.withValue { $0 }
            defer { value = "" }
            let cleanup = try await environment.submit(value, session, canSubmit)
            value = ""
            password.clear()
            defer { cleanup() }
            // Submission is not proof of authentication: observe the actual console session.
            for _ in 0..<100 {
                guard !attempt.cancelled, isConnected(), !Task.isCancelled else { throw NocturneError.disconnected }
                guard let current = environment.session(), current.userID == session.userID, current.sessionID == session.sessionID else {
                    throw NocturneError.remote("The Mac’s signed-in user changed. Reconnect before unlocking it.")
                }
                if !current.locked { reply.macLockStatus = status(); return reply }
                if environment.now() >= deadline { break }
                try await environment.pause()
            }
            throw NocturneError.remote("The Mac stayed locked. Check your login password, or enter it directly on the streamed lock screen. Nocturne will not retry it automatically.")
        default: throw NocturneError.invalidFrame
        }
    }
    private func status() -> MacLockStatus {
        guard let session = environment.session() else { return .init(state: .unavailable, user: "") }
        return .init(state: session.locked ? .locked : .unlocked, user: session.user)
    }
}

/// Uses standard Accessibility / Quartz input, never authentication-database edits
/// or global password keystrokes. macOS performs the normal login authentication.
@MainActor
private enum NativeMacUnlock {
    static func session() -> UnlockConsoleSession? {
        guard let values = CGSessionCopyCurrentDictionary() as? [String: Any],
              values[kCGSessionOnConsoleKey as String] as? Bool == true,
              values[kCGSessionLoginDoneKey as String] as? Bool == true,
              let uid = values[kCGSessionUserIDKey as String] as? NSNumber, uid.uint32Value == getuid() else { return nil }
        var sessionID: SecuritySessionId = 0
        var attributes = SessionAttributeBits()
        guard SessionGetInfo(callerSecuritySession, &sessionID, &attributes) == errSecSuccess else { return nil }
        return .init(userID: uid.uint32Value, sessionID: Int(sessionID),
            locked: values["CGSSessionScreenIsLocked"] as? Bool ?? false, user: NSFullUserName())
    }
    static func environment() -> MacUnlockEnvironment {
        .init(session: session, submit: submit)
    }
    static func submit(_ password: String, session: UnlockConsoleSession, canSubmit: @escaping () -> Bool) async throws -> (() -> Void) {
        guard AXIsProcessTrusted() else {
            throw NocturneError.remote("Allow Nocturne in Accessibility on the host Mac before using remote unlock.")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first(where: {
            $0.executableURL?.path == "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
        }) else { throw unavailable() }
        let pid = app.processIdentifier, application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var activity: IOPMAssertionID = 0
        let woke = IOPMAssertionDeclareUserActivity("Nocturne remote unlock" as CFString, kIOPMUserActiveLocal, &activity) == kIOReturnSuccess
        defer { if woke { IOPMAssertionRelease(activity) } }
        // Waking may first reveal a clock. A non-secret Return is confined to loginwindow.
        guard canSubmit() else { throw NocturneError.disconnected }
        if secureField(application, pid: pid) == nil { try key(36, pid: pid) }
        var field: AXUIElement?
        for _ in 0..<20 {
            guard canSubmit() else { throw NocturneError.disconnected }
            if let focused = secureField(application, pid: pid) { field = focused; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let field, canSubmit() else { throw unavailable() }
        let stillFocused = { canSubmit() && !app.isTerminated && secureField(application, pid: pid).map { CFEqual($0, field) } == true }
        let cleanup = {
            // Stale AX references fail closed; never look up a replacement app/field for cleanup.
            guard Self.session() == session else { return }
            if AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString) != .success,
               secureField(application, pid: pid).map({ CFEqual($0, field) }) == true {
                try? key(0, pid: pid, flags: .maskCommand); try? key(51, pid: pid)
            }
        }
        do {
            guard stillFocused() else { throw unavailable() }
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
                guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, password as CFString) == .success else { throw unavailable() }
            } else {
                // Some macOS releases expose a secure field without a writable AXValue.
                // Unicode text bypasses keyboard-layout translation. Even during a local
                // unlock, postToPid cannot route the password into a newly focused app.
                try key(0, pid: pid, flags: .maskCommand)
                guard stillFocused() else { throw unavailable() }
                try key(51, pid: pid)
                let units = Array(password.utf16)
                var start = 0
                while start < units.count {
                    guard stillFocused() else { throw unavailable() }
                    var end = min(start + 20, units.count)
                    if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
                    let chunk = Array(units[start..<end])
                    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw unavailable() }
                    chunk.withUnsafeBufferPointer {
                        down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
                        up.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
                    }
                    down.flags = []; up.flags = []; down.postToPid(pid); up.postToPid(pid)
                    start = end
                    // Permit disconnect/cancel packets to invalidate the attempt between chunks.
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            guard stillFocused() else { throw unavailable() }
            try key(36, pid: pid)
            return cleanup
        } catch { cleanup(); throw error }
    }
    private static func secureField(_ application: AXUIElement, pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let field = unsafeBitCast(value, to: AXUIElement.self)
        var owner: pid_t = 0
        guard AXUIElementGetPid(field, &owner) == .success, owner == pid else { return nil }
        var role: CFTypeRef?, subrole: CFTypeRef?, enabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &role) == .success,
              role as? String == kAXTextFieldRole,
              AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole) == .success,
              subrole as? String == kAXSecureTextFieldSubrole,
              AXUIElementCopyAttributeValue(field, kAXEnabledAttribute as CFString, &enabled) == .success,
              enabled as? Bool == true else { return nil }
        return field
    }
    private static func key(_ code: CGKeyCode, pid: pid_t, flags: CGEventFlags = []) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw unavailable() }
        down.flags = flags; up.flags = flags; down.postToPid(pid); up.postToPid(pid)
    }
    private static func unavailable() -> NocturneError {
        .remote("macOS did not expose its password field for remote unlock. Enter your password directly on the streamed lock screen instead.")
    }
}
