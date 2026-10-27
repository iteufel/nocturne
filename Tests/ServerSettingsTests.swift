import XCTest
import ServiceManagement
import NocturneKit
@testable import NocturneHostKit
@testable import NocturneServerModel

final class ServerSettingsTests: XCTestCase {
    func testMigrationPreservesExistingSharingAndDisplayChoices() throws {
        let suite = "nocturne.settings.test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("42", forKey: "streamDisplay")
        defaults.set(true, forKey: "allowTerminal")
        defaults.set(true, forKey: "allowFiles")
        defaults.set(true, forKey: "allowChats")
        let settings = ServerSettings(defaults: defaults)
        XCTAssertTrue(settings.screenSharing)
        XCTAssertTrue(settings.terminal); XCTAssertTrue(settings.files)
        XCTAssertTrue(settings.chats)
        XCTAssertEqual(settings.display, "42"); XCTAssertFalse(settings.headlessDisplay)
        var draft = settings
        draft.screenSharing = false
        draft.headlessDisplay = true; draft.disablePhysicalDisplays = true
        draft.microphone = true; draft.remoteAccess = true
        draft.brokerURL = "  https://broker.example.com/  "
        draft.sharedFolder = URL(fileURLWithPath: "/tmp/a different shared folder")
        XCTAssertEqual(ServerSettings(defaults: defaults), settings, "Draft edits must not persist before Apply")
        let applied = try draft.validated()
        applied.save(defaults: defaults)
        XCTAssertEqual(ServerSettings(defaults: defaults), applied)
        XCTAssertEqual(applied.brokerURL, "https://broker.example.com")
        draft.brokerURL = "http://untrusted.example.com"
        XCTAssertThrowsError(try draft.validated(), "Apply must use the transport's HTTPS validation")
    }

    @MainActor
    func testOfflineDeviceRevocationPreservesOtherPairingsAndEngineState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = try TestDeviceIdentity(), second = try TestDeviceIdentity()
        let url = root.appendingPathComponent("state.json")
        let state: [String: Any] = ["root": ["uniqueid": "host-id", "named_devices": [
            ["uuid": "first", "name": "iPad", "cert": first.pem],
            ["uuid": "second", "name": "iPad", "cert": second.pem]
        ]], "other": "preserved"]
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let engine = EmbeddedStreamingEngine(directory: root)
        try engine.removeSavedDevice("first")
        XCTAssertEqual(try engine.savedDevices().map(\.id), ["second"])
        XCTAssertEqual(try engine.savedDevices().first?.fingerprint, second.id)
        try engine.resetSavedPairing()
        XCTAssertTrue(try engine.savedDevices().isEmpty)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((saved["root"] as? [String: Any])?["uniqueid"] as? String, "host-id")
        XCTAssertEqual(saved["other"] as? String, "preserved")
        XCTAssertFalse(engine.isRunning)
    }
}

@MainActor
final class ServerLifecycleTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let suite = "nocturne.lifecycle.test." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let model: ServerModel
        let port = UInt16.random(in: 52_000..<60_000)
        let key = Data(repeating: 0x42, count: 32)

        init(terminal: Bool = true, screenSharing: Bool = false, legacyAutoStart: Bool? = nil, executable: URL? = nil) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            if let legacyAutoStart { defaults.set(legacyAutoStart, forKey: "startServerAutomatically") }
            defaults.set(screenSharing, forKey: "allowScreenSharing")
            defaults.set(false, forKey: "headlessDisplayEnabled")
            defaults.set(terminal, forKey: "allowTerminal")
            defaults.set(root.appendingPathComponent("original").path, forKey: "sharedFolder")
            // Captured state keeps tests away from the real login-item registration.
            let login = LoginState()
            loginState = login
            model = ServerModel(defaults: defaults, supportDirectory: root,
                engineExecutable: executable ?? root.appendingPathComponent("missing-engine"), port: port,
                loginItem: ServerLoginItem(status: { login.status }, setEnabled: {
                    if let error = login.error { throw error }
                    login.changes.append($0); login.status = $0 ? .requiresApproval : .notRegistered
                }), keyProvider: { _ in Data(repeating: 0x42, count: 32) })
        }
        final class LoginState {
            var status: SMAppService.Status = .notRegistered
            var error: Error?
            var changes: [Bool] = []
        }
        let loginState: LoginState
        func cleanup() {
            model.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func invitation() throws -> PairingInvitation {
            model.pair()
            let code = try XCTUnwrap(model.invitation)
            return try PairingInvitation(host: "127.0.0.1", port: port, name: code.name,
                secret: code.secret, enrollmentToken: code.enrollmentToken)
        }
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard predicate() else { XCTFail("Timed out: " + description); throw NocturneError.timeout }
    }

    func testSavedSharingTogglesControlStartupAndIgnoreTheRemovedStartupPreference() async throws {
        let enabled = try Fixture(legacyAutoStart: false), disabled = try Fixture(terminal: false, legacyAutoStart: true)
        defer { enabled.cleanup(); disabled.cleanup() }
        enabled.model.startEnabledServices(); disabled.model.startEnabledServices()
        try await waitFor("automatic listener startup") { enabled.model.running }
        XCTAssertFalse(disabled.model.active)
        XCTAssertFalse(enabled.model.engine.isRunning)
        XCTAssertNil(enabled.model.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: enabled.model.engine.directory.path))
    }

    func testApplyingSharingTogglesStartsAndStopsTheServer() async throws {
        let fixture = try Fixture(terminal: false); defer { fixture.cleanup() }
        let model = fixture.model
        model.startEnabledServices()
        XCTAssertFalse(model.active)
        model.settings.files = true
        XCTAssertFalse(model.active, "Draft toggles must wait for Apply")
        model.applySettings()
        try await waitFor("file sharing startup") { model.running }
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity())
        defer { client.disconnect() }
        try await client.connect(fixture.invitation())
        XCTAssertTrue(client.capabilities.contains("files"))
        model.settings.files = false
        XCTAssertTrue(model.running, "Turning off a draft toggle must leave the applied service running")
        _ = try await client.request(Packet(.ping))
        model.applySettings()
        XCTAssertFalse(model.active)
        try await waitFor("all sharing stopped") { client.state == .disconnected }
        model.pair()
        XCTAssertFalse(model.active, "Pairing must not bypass disabled Sharing toggles")
        XCTAssertNotNil(model.error)
        model.settings.terminal = true
        model.applySettings()
        try await waitFor("terminal sharing startup") { model.running }
        XCTAssertNil(model.error); XCTAssertFalse(model.engine.isRunning)
    }

    func testChatOnlySharingStartsAndRevokesWithoutApplyingOtherDraftPermissions() async throws {
        let fixture = try Fixture(terminal: false); defer { fixture.cleanup() }
        let model = fixture.model
        model.settings.files = true
        model.chatsEnabled = true
        try await waitFor("chat-only listener") { model.running }
        XCTAssertTrue(model.appliedSettings.chats)
        XCTAssertFalse(model.appliedSettings.files, "Enabling chat must not apply unrelated sharing drafts")
        XCTAssertTrue(fixture.defaults.bool(forKey: "allowChats"))
        XCTAssertFalse(fixture.defaults.bool(forKey: "allowFiles"))
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity())
        defer { client.disconnect() }
        try await client.connect(fixture.invitation())
        XCTAssertTrue(client.capabilities.contains(ChatProtocol.capability))
        XCTAssertFalse(client.capabilities.contains("files"))
        XCTAssertFalse(client.capabilities.contains("streaming"))
        model.chatsEnabled = false
        XCTAssertFalse(model.active, "Revoking the last applied service stops the listener")
        XCTAssertFalse(fixture.defaults.bool(forKey: "allowChats"))
        try await waitFor("chat access revoked") { client.state == .disconnected }
    }

    func testChatRevocationDuringStartupDoesNotRestoreCapturedPermission() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.model.chatsEnabled = true
        fixture.model.chatsEnabled = false
        try await waitFor("terminal-only listener after chat revocation") { fixture.model.running }
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity())
        defer { client.disconnect() }
        try await client.connect(fixture.invitation())
        XCTAssertTrue(client.capabilities.contains("terminal"))
        XCTAssertFalse(client.capabilities.contains(ChatProtocol.capability), "A pending startup must use the current chat grant after revocation")
    }

    func testDraftEditsDoNotAffectLiveServicesAndApplyRestartsWithSavedSettings() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let model = fixture.model
        model.start()
        try await waitFor("listener startup") { model.running }
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity())
        defer { client.disconnect() }
        let invitation = try fixture.invitation()
        try await client.connect(invitation)
        XCTAssertTrue(client.capabilities.contains("terminal"))
        XCTAssertFalse(client.capabilities.contains("files")); XCTAssertFalse(client.capabilities.contains("streaming"))
        XCTAssertFalse(client.capabilities.contains(AppStreaming.capability))
        model.settings.terminal = false; model.settings.files = true
        model.settings.sharedFolder = fixture.root.appendingPathComponent("replacement")
        XCTAssertTrue(model.hasSettingsChanges)
        XCTAssertTrue(fixture.defaults.bool(forKey: "allowTerminal"))
        XCTAssertFalse(fixture.defaults.bool(forKey: "allowFiles"))
        try await client.openTerminal()
        XCTAssertNotNil(client.terminalID, "Editing the draft must leave current permissions and connections intact")
        model.applySettings()
        XCTAssertTrue(model.starting)
        try await waitFor("restarted listener") { model.running }
        XCTAssertFalse(model.hasSettingsChanges)
        XCTAssertFalse(fixture.defaults.bool(forKey: "allowTerminal"))
        XCTAssertTrue(fixture.defaults.bool(forKey: "allowFiles"))
        // Reconnect with the original pairing, without issuing a new QR code.
        try await client.connect(invitation)
        XCTAssertTrue(client.capabilities.contains("files")); XCTAssertFalse(client.capabilities.contains("terminal"))
        let listing = try await client.request(Packet(.list))
        XCTAssertEqual(listing.files?.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.appliedSettings.sharedFolder.path))
        do { try await client.openTerminal(); XCTFail("Revoked terminal access remained available") } catch {}
    }

    func testApplyUsesSavedSnapshotAndDiscardRestoresIt() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let model = fixture.model
        model.settings.files = true
        model.settings.screenSharing = true
        model.start()
        try await waitFor("listener startup") { model.running }
        XCTAssertFalse(model.engine.isRunning, "Start must use the applied snapshot, not uncommitted edits")
        XCTAssertFalse(model.appliedSettings.files)
        model.discardSettings()
        XCTAssertFalse(model.settings.files); XCTAssertFalse(model.settings.screenSharing)
        XCTAssertFalse(model.hasSettingsChanges)
    }

    func testApplyAndStopCancelAnInFlightStartupBeforeItCanBind() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let model = fixture.model
        model.start()
        XCTAssertTrue(model.starting)
        model.settings.files = true
        model.applySettings()
        try await waitFor("replacement startup") { model.running || model.error != nil }
        XCTAssertTrue(model.running); XCTAssertNil(model.error)
        XCTAssertTrue(model.appliedSettings.files)
        model.stop()
        model.start(); model.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.active); XCTAssertNil(model.error)
        model.start()
        try await waitFor("port released after cancelled startup") { model.running || model.error != nil }
        XCTAssertTrue(model.running); XCTAssertNil(model.error)
    }

    func testInvalidSettingsAndLoginFailureLeaveRunningServerUntouched() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let model = fixture.model
        model.start(); try await waitFor("listener startup") { model.running }
        model.settings.remoteAccess = true; model.settings.brokerURL = "not a URL"
        model.settings.launchAtLogin = true
        model.applySettings()
        XCTAssertTrue(model.running); XCTAssertTrue(model.hasSettingsChanges)
        XCTAssertFalse(model.appliedSettings.remoteAccess); XCTAssertTrue(fixture.loginState.changes.isEmpty)
        XCTAssertNotNil(model.error)
        model.discardSettings(); model.error = nil
        fixture.loginState.error = NocturneError.permissionDenied
        model.settings.launchAtLogin = true; model.settings.files = true
        model.applySettings()
        XCTAssertTrue(model.running); XCTAssertTrue(model.hasSettingsChanges)
        XCTAssertFalse(fixture.defaults.bool(forKey: "allowFiles"))
        XCTAssertNotNil(model.error)
    }

    func testLoginApprovalAndExternalChangesDoNotStartDisabledSharing() throws {
        let fixture = try Fixture(terminal: false); defer { fixture.cleanup() }
        let model = fixture.model
        model.settings.launchAtLogin = true
        model.applySettings()
        XCTAssertEqual(fixture.loginState.changes, [true])
        XCTAssertTrue(model.loginApprovalRequired); XCTAssertTrue(model.appliedSettings.launchAtLogin)
        XCTAssertFalse(model.hasSettingsChanges); XCTAssertFalse(model.active)
        fixture.loginState.status = .notRegistered
        model.refreshLoginItem()
        XCTAssertFalse(model.settings.launchAtLogin); XCTAssertFalse(model.appliedSettings.launchAtLogin)
        model.settings.files = true
        model.refreshLoginItem()
        XCTAssertTrue(model.settings.files, "Refreshing the OS state must preserve unrelated draft edits")
    }

    func testScreenSharingRestartsAfterFailureWithoutDisconnectingWorkspaceAndStopsRetryingOnStop() async throws {
        let scriptRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scriptRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scriptRoot) }
        let executable = scriptRoot.appendingPathComponent("failing-engine")
        try Data("#!/bin/sh\nprintf 'start\\n' >> starts\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let fixture = try Fixture(screenSharing: true, executable: executable); defer { fixture.cleanup() }
        let model = fixture.model
        model.startEnabledServices()
        try await waitFor("listener startup") { model.running }
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity())
        defer { client.disconnect() }
        try await client.connect(fixture.invitation())
        let counter = model.engine.directory.appendingPathComponent("starts")
        func starts() -> Int { (try? String(contentsOf: counter).split(separator: "\n").count) ?? 0 }
        try await waitFor("automatic streaming engine recovery", timeout: 12) { starts() >= 2 }
        XCTAssertTrue(model.running); XCTAssertEqual(client.state, .connected)
        _ = try await client.request(Packet(.ping))
        XCTAssertNotNil(model.screenSharingError)
        model.settings.screenSharing = false
        model.applySettings()
        try await waitFor("restart with screen sharing disabled") { model.running }
        let count = starts()
        try await Task.sleep(nanoseconds: 5_200_000_000)
        XCTAssertEqual(starts(), count, "Apply must cancel retries for a disabled feature")
        XCTAssertFalse(model.engine.isRunning); XCTAssertNil(model.screenSharingError)
        model.stop()
        XCTAssertFalse(model.active)
    }
}
