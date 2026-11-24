import AppKit
import Network
import XCTest
import NocturneKit
@testable import NocturneHostKit

@MainActor
private final class UnlockFixture {
    var session: UnlockConsoleSession? = .init(userID: 501, sessionID: 7, locked: true, user: "Fixture User")
    var now = Date(timeIntervalSince1970: 1_000)
    var submissions: [String] = []
    var cleanups = 0
    var polls = 0
    var unlockAfter: Int? = 1
    var beforeSubmission: (() async -> Void)?
    var onPoll: (() -> Void)?
    var onSubmitted: (() -> Void)?
    var canSubmit: (() -> Bool)?
    func unlocked() { session = .init(userID: 501, sessionID: 7, locked: false, user: "Fixture User") }
    var environment: MacUnlockEnvironment {
        .init(session: { self.session }, submit: { password, _, canSubmit in
            self.canSubmit = canSubmit; defer { self.canSubmit = nil }
            await self.beforeSubmission?()
            guard canSubmit() else { throw NocturneError.disconnected }
            self.submissions.append(password); self.onSubmitted?()
            return { self.cleanups += 1 }
        }, now: { self.now }, pause: {
            self.polls += 1; self.onPoll?()
            if let after = self.unlockAfter, self.polls >= after { self.unlocked() }
            await Task.yield()
        })
    }
    func request(_ value: String = "zY öäüß @€[]{}") throws -> Packet {
        var packet = Packet(.macUnlock); packet.unlockPassword = try MacUnlockPassword(value); return packet
    }
}

@MainActor
final class MacUnlockTests: XCTestCase {
    func testNativeStatusRecognizesCurrentConsoleWithoutEnteringCredentials() async throws {
        let values = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let reply = try await MacUnlockController().handle(Packet(.macLockStatus), connection: UUID(), isConnected: { true })
        let available = values[kCGSessionOnConsoleKey as String] as? Bool == true &&
            values[kCGSessionLoginDoneKey as String] as? Bool == true &&
            (values[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid()
        if available {
            XCTAssertEqual(reply.macLockStatus?.state, values["CGSSessionScreenIsLocked"] as? Bool == true ? .locked : .unlocked)
        } else { XCTAssertEqual(reply.macLockStatus?.state, .unavailable) }
    }
    func testPasswordRoundTripPreservesLayoutCharactersAndSpacesButRedactsDiagnostics() throws {
        let value = "  unlock-secret-marker zY öäüß @€[]{} 👩‍💻  "
        var packet = Packet(.macUnlock); packet.unlockPassword = try MacUnlockPassword(value)
        let encoded = try FrameCodec.encode(packet)
        let decoded = try JSONDecoder().decode(Packet.self, from: encoded.dropFirst(4))
        XCTAssertEqual(try decoded.unlockPassword?.withValue { $0 }, value)
        XCTAssertFalse(String(describing: packet).contains(value))
        XCTAssertFalse(String(reflecting: packet).contains(value))
        XCTAssertFalse(String(reflecting: decoded.unlockPassword!).contains(value))
        for diagnostic in [String(describing: packet), String(reflecting: packet), String(reflecting: decoded.unlockPassword!)] {
            XCTAssertFalse(diagnostic.contains("unlock-secret-marker"))
        }
        XCTAssertNil(packet.reply().unlockPassword)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(packet.reply(error: "Denied")), as: UTF8.self).contains(value))
        decoded.unlockPassword?.clear()
        XCTAssertThrowsError(try JSONEncoder().encode(decoded))
        XCTAssertThrowsError(try MacUnlockPassword(""))
        XCTAssertThrowsError(try MacUnlockPassword("secret\n"))
        XCTAssertThrowsError(try MacUnlockPassword("secret\0"))
        XCTAssertThrowsError(try MacUnlockPassword(String(repeating: "ü", count: 2_049)))
        _ = try MacUnlockPassword(String(repeating: "ü", count: 2_048))
    }
    func testUnlockSubmitsExactlyOnceAndWaitsForActualSessionTransition() async throws {
        let fixture = UnlockFixture(); fixture.unlockAfter = 3
        let controller = MacUnlockController(environment: fixture.environment)
        let packet = try fixture.request()
        let result = try await controller.handle(packet, connection: UUID(), isConnected: { true })
        XCTAssertEqual(result.macLockStatus?.state, .unlocked)
        XCTAssertNil(result.unlockPassword)
        XCTAssertEqual(fixture.submissions, ["zY öäüß @€[]{}"])
        XCTAssertEqual(fixture.polls, 3); XCTAssertEqual(fixture.cleanups, 1)
        XCTAssertThrowsError(try packet.unlockPassword?.withValue { $0 })
    }
    func testAlreadyUnlockedOrUnavailableNeverSubmitsPassword() async throws {
        let fixture = UnlockFixture(); fixture.unlocked()
        let controller = MacUnlockController(environment: fixture.environment)
        let reply = try await controller.handle(fixture.request(), connection: UUID(), isConnected: { true })
        XCTAssertEqual(reply.macLockStatus?.state, .unlocked)
        fixture.session = nil
        let status = try await controller.handle(Packet(.macLockStatus), connection: UUID(), isConnected: { true })
        XCTAssertEqual(status.macLockStatus?.state, .unavailable)
        do { _ = try await controller.handle(fixture.request(), connection: UUID(), isConnected: { true }); XCTFail("Logged-out session unlocked") } catch {}
        XCTAssertTrue(fixture.submissions.isEmpty)
    }
    func testFailedUnlockIsBoundedAndRateLimitSurvivesConnectionChange() async throws {
        let fixture = UnlockFixture(); fixture.unlockAfter = nil
        let controller = MacUnlockController(environment: fixture.environment)
        do { _ = try await controller.handle(fixture.request(), connection: UUID(), isConnected: { true }); XCTFail("Submission was mistaken for unlock") }
        catch { XCTAssertTrue(error.localizedDescription.contains("stayed locked")) }
        XCTAssertEqual(fixture.polls, 100); XCTAssertEqual(fixture.submissions.count, 1); XCTAssertEqual(fixture.cleanups, 1)
        do { _ = try await controller.handle(fixture.request(), connection: UUID(), isConnected: { true }); XCTFail("Reconnect bypassed cooldown") } catch {}
        XCTAssertEqual(fixture.submissions.count, 1)
        fixture.now.addTimeInterval(31); fixture.unlockAfter = 101
        _ = try await controller.handle(fixture.request(), connection: UUID(), isConnected: { true })
        XCTAssertEqual(fixture.submissions.count, 2)
    }
    func testDisconnectOrLocalUnlockWhilePreparingNeverTypesIntoDesktop() async throws {
        for locallyUnlocked in [false, true] {
            let fixture = UnlockFixture(), connection = UUID()
            var connected = true
            fixture.beforeSubmission = { if locallyUnlocked { fixture.unlocked() } else { connected = false } }
            let controller = MacUnlockController(environment: fixture.environment)
            do { _ = try await controller.handle(fixture.request(), connection: connection, isConnected: { connected }); XCTFail("Stale attempt submitted") } catch {}
            XCTAssertTrue(fixture.submissions.isEmpty)
        }
    }
    func testCancelIsOwnedByRequestAndConnectionAndPreventsDelayedSubmission() async throws {
        let fixture = UnlockFixture(), owner = UUID(), other = UUID()
        let controller = MacUnlockController(environment: fixture.environment), packet = try fixture.request()
        fixture.beforeSubmission = {
            var cancel = Packet(.macUnlockCancel); cancel.sessionID = packet.id
            _ = try? await controller.handle(cancel, connection: other, isConnected: { true })
            _ = try? await controller.handle(cancel, connection: owner, isConnected: { true })
        }
        do { _ = try await controller.handle(packet, connection: owner, isConnected: { true }); XCTFail("Cancelled attempt submitted") } catch {}
        XCTAssertTrue(fixture.submissions.isEmpty)
        XCTAssertThrowsError(try packet.unlockPassword?.withValue { $0 })
    }
    func testOtherConnectionCannotCancelAndConcurrentAttemptCannotSubmit() async throws {
        let fixture = UnlockFixture(), owner = UUID(), other = UUID()
        let controller = MacUnlockController(environment: fixture.environment), packet = try fixture.request()
        fixture.beforeSubmission = {
            var cancel = Packet(.macUnlockCancel); cancel.sessionID = packet.id
            _ = try? await controller.handle(cancel, connection: other, isConnected: { true })
            do { _ = try await controller.handle(fixture.request("other"), connection: other, isConnected: { true }); XCTFail("Concurrent password submitted") } catch {}
        }
        _ = try await controller.handle(packet, connection: owner, isConnected: { true })
        XCTAssertEqual(fixture.submissions.count, 1)
    }
    func testDisconnectAndUserSwitchDuringConfirmationFailAndCleanUp() async throws {
        for switchedUser in [false, true] {
            let fixture = UnlockFixture(), connection = UUID()
            let controller = MacUnlockController(environment: fixture.environment)
            fixture.unlockAfter = nil
            fixture.onPoll = {
                if switchedUser { fixture.session = .init(userID: 502, sessionID: 9, locked: false, user: "Other") }
                else { controller.disconnected(connection) }
            }
            do { _ = try await controller.handle(fixture.request(), connection: connection, isConnected: { true }); XCTFail("Wrong session confirmed") } catch {}
            XCTAssertEqual(fixture.cleanups, 1)
        }
    }
}

@MainActor
private final class UnlockDesktopHost: DesktopHosting {
    func displays() async throws -> [RemoteDesktopDisplay] { [] }
    func capture(displayID: UInt32?, viewport: AppWindowViewport, send: @escaping AppWindowSend,
                 ended: @escaping (Error) -> Void) async throws -> DesktopCapture { throw NocturneError.permissionDenied }
}

@MainActor
final class MacUnlockConnectionTests: XCTestCase {
    private func start(_ server: WorkspaceServer, secret: Data) async throws -> UInt16 {
        let ready = expectation(description: "Unlock fixture ready"); var signalled = false
        server.onStatus = { state, _ in if state == "Ready", !signalled { signalled = true; ready.fulfill() } }
        try server.start(secret: secret, port: 0); await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(server.listeningPort)
    }
    func testClearingAQueuedCredentialDoesNotCloseTheWorkspaceTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureStore.randomKey(), devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices"))
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Fixture Mac", devices: devices)
        let port = try await start(server, secret: key); defer { server.stop() }
        let ready = expectation(description: "Transport ready"), replies = expectation(description: "Both queued frames delivered")
        replies.expectedFulfillmentCount = 2
        let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: SecureTransport.parameters(secret: key)))
        defer { channel.onClose = nil; channel.cancel() }
        channel.onReady = { ready.fulfill() }
        channel.onPacket = { reply in
            // These deliberately unauthenticated requests are denied, but framing stays usable.
            XCTAssertNotNil(reply.error); XCTAssertNil(reply.unlockPassword); replies.fulfill()
        }
        channel.onClose = { _ in XCTFail("Clearing a queued credential closed the transport") }
        channel.start(); await fulfillment(of: [ready], timeout: 5)
        let blocked = expectation(description: "Queue deliberately backlogged"), resume = DispatchSemaphore(value: 0)
        channel.queue.async { blocked.fulfill(); resume.wait() }
        await fulfillment(of: [blocked], timeout: 5)
        let packet = try UnlockFixture().request()
        channel.send(packet)
        packet.unlockPassword?.clear()
        channel.send(Packet(.ping))
        resume.signal()
        await fulfillment(of: [replies], timeout: 5)
    }
    func testRealTLSRequiresDeviceAuthenticationAndScreenSharingForUnlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for screenSharing in [false, true] {
            let key = try SecureStore.randomKey(), fixture = UnlockFixture()
            let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent(UUID().uuidString))
            let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Fixture Mac", devices: devices,
                permissions: .init(terminal: true), desktop: screenSharing ? DesktopSessionManager(host: UnlockDesktopHost()) : nil)
            server.macUnlock = MacUnlockController(environment: fixture.environment)
            defer { server.stop() }
            let port = try await start(server, secret: key)
            let rejected = expectation(description: "PSK alone cannot unlock")
            let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: SecureTransport.parameters(secret: key)))
            defer { channel.cancel() }
            channel.onReady = { channel.send(try! fixture.request()) }
            channel.onPacket = { reply in XCTAssertNotNil(reply.error); XCTAssertNil(reply.unlockPassword); rejected.fulfill() }
            channel.start(); await fulfillment(of: [rejected], timeout: 5)
            let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity()); defer { client.disconnect() }
            try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Fixture", secret: key, enrollmentToken: devices.createInvitation()))
            XCTAssertEqual(client.capabilities.contains(MacUnlock.capability), screenSharing)
            if screenSharing {
                let result = try await client.request(fixture.request())
                XCTAssertEqual(result.macLockStatus?.state, .unlocked); XCTAssertNil(result.unlockPassword)
            } else {
                do { _ = try await client.request(fixture.request()); XCTFail("Terminal permission granted unlock") } catch {}
            }
            XCTAssertEqual(fixture.submissions.count, screenSharing ? 1 : 0)
        }
    }
    func testPromptClearsPasswordOnSubmitCancelDisconnectAndDoesNotReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureStore.randomKey(), fixture = UnlockFixture()
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices"))
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Fixture Mac", devices: devices,
            desktop: DesktopSessionManager(host: UnlockDesktopHost()))
        server.macUnlock = MacUnlockController(environment: fixture.environment)
        let port = try await start(server, secret: key); defer { server.stop() }
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity()); defer { client.disconnect() }
        let invitation = try PairingInvitation(host: "127.0.0.1", port: port, name: "Fixture", secret: key, enrollmentToken: devices.createInvitation())
        try await client.connect(invitation)
        let model = MacUnlockModel(connection: client)
        await model.refresh(); XCTAssertTrue(model.isPresented)
        model.password = "discard on cancel"; model.dismiss()
        XCTAssertTrue(model.password.isEmpty); XCTAssertFalse(model.isPresented)
        await model.refresh(); XCTAssertFalse(model.isPresented, "Cancel must not cause repeated prompts")
        model.present(); model.password = "  öäüß zY @€  "; model.submit(); model.submit()
        XCTAssertTrue(model.password.isEmpty)
        try await waitUntil { !model.isSubmitting }
        XCTAssertNil(model.error); XCTAssertFalse(model.isPresented)
        XCTAssertEqual(fixture.submissions, ["  öäüß zY @€  "])
        fixture.session = .init(userID: 501, sessionID: 7, locked: true, user: "Fixture User")
        await model.refresh(); model.password = "discard on disconnect"
        client.disconnect(); try await waitUntil { !model.isPresented && model.password.isEmpty }
        try await client.connect(invitation); await model.refresh()
        XCTAssertTrue(model.password.isEmpty); XCTAssertEqual(fixture.submissions.count, 1)
    }
    func testHostSwitchInvalidatesOpenPasswordPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity()); defer { client.disconnect() }
        let model = MacUnlockModel(connection: client)
        var servers: [WorkspaceServer] = [], fixtures: [UnlockFixture] = []
        defer { servers.forEach { $0.stop() } }
        for index in 0..<2 {
            let fixture = UnlockFixture(), key = try SecureStore.randomKey()
            let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices\(index)"))
            let server = try WorkspaceServer(folder: root.appendingPathComponent("shared\(index)"), name: "Mac \(index)", devices: devices,
                desktop: DesktopSessionManager(host: UnlockDesktopHost()))
            server.macUnlock = MacUnlockController(environment: fixture.environment)
            servers.append(server); fixtures.append(fixture)
            let port = try await start(server, secret: key)
            try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Mac \(index)", secret: key, enrollmentToken: devices.createInvitation()))
            if index == 0 { await model.refresh(); model.password = "belongs to first Mac" }
        }
        model.submit()
        XCTAssertTrue(model.password.isEmpty); XCTAssertFalse(model.isPresented)
        XCTAssertTrue(fixtures.allSatisfy { $0.submissions.isEmpty })
    }
    func testDismissingPromptCancelsTheInFlightServerOperationOverTLS() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureStore.randomKey(), fixture = UnlockFixture()
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices"))
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Fixture Mac", devices: devices,
            desktop: DesktopSessionManager(host: UnlockDesktopHost()))
        server.macUnlock = MacUnlockController(environment: fixture.environment)
        let port = try await start(server, secret: key); defer { server.stop() }
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity()); defer { client.disconnect() }
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Fixture", secret: key, enrollmentToken: devices.createInvitation()))
        var resume: CheckedContinuation<Void, Never>?
        fixture.beforeSubmission = { await withCheckedContinuation { resume = $0 } }
        let model = MacUnlockModel(connection: client)
        await model.refresh(); model.password = "cancel before native submission"; model.submit()
        try await waitUntil { resume != nil }
        model.dismiss()
        XCTAssertTrue(model.password.isEmpty); XCTAssertFalse(model.isPresented)
        try await waitUntil { fixture.canSubmit?() == false }
        resume?.resume(); resume = nil
        try await waitUntil { fixture.canSubmit == nil }
        XCTAssertTrue(fixture.submissions.isEmpty, "Cancellation must reach the server before its delayed native submission")
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("Unlock state did not settle")
    }
}
