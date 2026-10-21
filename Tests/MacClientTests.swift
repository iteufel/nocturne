import XCTest
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import NocturneKit
@testable import NocturneMacClient
@testable import NocturneHostKit

@MainActor
private final class RecordingDesktopCapture: DesktopCapture {
    var display = StreamDisplaySize(width: 640, height: 480, frameRate: 60)
    var displayID: UInt32 = 7
    var inputs: [AppWindowInput] = []
    var resizes: [AppWindowViewport] = []
    var stops = 0
    let send: AppWindowSend
    init(send: @escaping AppWindowSend) { self.send = send }
    func resize(_ viewport: AppWindowViewport) { resizes.append(viewport) }
    func input(_ input: AppWindowInput) { inputs.append(input) }
    func stop() { stops += 1 }
}

@MainActor
private final class RecordingDesktopHost: DesktopHosting {
    var captures: [RecordingDesktopCapture] = []
    var delayed = false
    var fail = false
    var pending: CheckedContinuation<Void, Never>?
    func displays() -> [RemoteDesktopDisplay] {
        [.init(id: 7, name: "Main display", width: 1920, height: 1440, isMain: true),
         .init(id: 8, name: "Second display", width: 1920, height: 1080, isMain: false)]
    }
    func capture(displayID: UInt32?, viewport: AppWindowViewport, send: @escaping AppWindowSend,
                 ended: @escaping (Error) -> Void) async throws -> DesktopCapture {
        if fail { throw NocturneError.permissionDenied }
        let capture = RecordingDesktopCapture(send: send); capture.displayID = displayID ?? 7; captures.append(capture)
        if delayed { await withCheckedContinuation { pending = $0 } }
        return capture
    }
}

@MainActor
final class MacClientTests: XCTestCase {
    private let viewport = AppWindowViewport(width: 800, height: 600, scale: 2)
    private let send: AppWindowSend = { _, completion in completion(nil) }
    private func open() -> Packet {
        var packet = Packet(.desktopOpen); packet.sessionID = UUID().uuidString; packet.viewport = viewport; return packet
    }
    private func waitFor(_ message: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard predicate() else { XCTFail("Timed out: " + message); throw NocturneError.timeout }
    }
    private func rejected(_ action: () async throws -> Packet, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await action(); XCTFail("Unauthorized desktop command succeeded", file: file, line: line) } catch {}
    }

    func testNativeIdentityAuthenticatesAndSurvivesReloadWithoutChangingKey() throws {
        var storage: [String: Data] = [:]
        var writes = 0
        let first = try MacClientIdentity.load(read: { storage[$0] }, write: { storage[$1] = $0; writes += 1 })
        let restored = try MacClientIdentity.load(read: { storage[$0] }, write: { _, _ in XCTFail("Must reuse the existing identity") })
        XCTAssertEqual(first.certificate, restored.certificate); XCTAssertEqual(writes, 1)
        let identity = try restored.workspace(name: "Mac")
        let challenge = try SecureStore.randomKey()
        let signature = try identity.sign(WorkspaceIdentity.message(for: challenge))
        XCTAssertEqual(try WorkspaceIdentity.verify(certificate: identity.certificate, signature: signature, challenge: challenge),
            WorkspaceIdentity.fingerprint(first.certificate))
        XCTAssertThrowsError(try WorkspaceIdentity.verify(certificate: identity.certificate, signature: signature, challenge: SecureStore.randomKey()))
        XCTAssertThrowsError(try MacClientIdentity.load(read: { _ in throw NocturneError.permissionDenied }, write: { _, _ in XCTFail("Locked Keychain must not replace identity") }))
        XCTAssertThrowsError(try MacClientIdentity.load(read: { _ in Data([1,2,3]) }, write: { _, _ in XCTFail("Corrupt identity must not be replaced") }))
    }

    func testLockedPairingsAndSelfPairingCannotOverwriteHostingCredentials() throws {
        let model = MacClientModel(read: { _ in throw NocturneError.permissionDenied }, write: { _, _ in XCTFail("Must not save after failed read") })
        model.load()
        let invitation = try PairingInvitation(host: "example.local", name: "Mac", secret: SecureStore.randomKey())
        XCTAssertFalse(model.addHost(invitation.url.absoluteString)); XCTAssertNil(model.session)
        let own = MacClientModel(read: { $0 == "server-key" ? invitation.secret : nil }, write: { _, _ in XCTFail("Must not touch local server credentials") })
        XCTAssertFalse(own.addHost("invalid")); XCTAssertTrue(own.error?.contains("pairing code is invalid") == true)
        XCTAssertFalse(own.addHost(invitation.url.absoluteString)); XCTAssertNil(own.session)
        XCTAssertTrue(own.error?.contains("own Mac") == true)
    }

    func testDesktopLeaseRejectsOtherConnectionsAndSessionsAndReleasesOnExpiry() async throws {
        var clock: TimeInterval = 0
        let host = RecordingDesktopHost(), manager = DesktopSessionManager(host: host, now: { clock })
        let owner = UUID(), other = UUID(), request = open()
        var events: [Packet] = []
        let reply = try await manager.handle(request, connection: owner, send: { events.append($0); $1(nil) })
        XCTAssertEqual(reply.displayID, 7)
        await rejected { try await manager.handle(open(), connection: other, send: send) }
        for operation in [Operation.desktopInput, .desktopResize, .desktopHeartbeat, .desktopClose] {
            var command = Packet(operation); command.sessionID = request.sessionID
            command.viewport = viewport; command.input = AppWindowInput(.keyDown)
            await rejected { try await manager.handle(command, connection: other, send: send) }
            command.sessionID = UUID().uuidString
            await rejected { try await manager.handle(command, connection: owner, send: send) }
        }
        var input = Packet(.desktopInput); input.sessionID = request.sessionID; input.input = AppWindowInput(.keyDown)
        _ = try await manager.handle(input, connection: owner, send: send)
        XCTAssertEqual(host.captures[0].inputs.count, 1)
        manager.disconnected(other); XCTAssertEqual(host.captures[0].stops, 0)
        clock = AppStreaming.heartbeatTimeout; manager.expire()
        XCTAssertEqual(host.captures[0].stops, 1); XCTAssertEqual(events.last?.operation, .desktopEnded)
        _ = try await manager.handle(open(), connection: other, send: send)
        manager.disconnected(owner); XCTAssertEqual(host.captures[1].stops, 0)
        manager.stop(); XCTAssertEqual(host.captures[1].stops, 1)
    }

    func testDisconnectDuringCaptureAndCaptureFailureDoNotLeaveAControlLease() async throws {
        let host = RecordingDesktopHost(), manager = DesktopSessionManager(host: host), owner = UUID()
        host.delayed = true
        let opening = Task { try await manager.handle(open(), connection: owner, send: send) }
        try await waitFor("pending capture") { host.pending != nil }
        manager.disconnected(owner); host.pending?.resume(); host.pending = nil
        do { _ = try await opening.value; XCTFail("Disconnected capture acquired a lease") } catch {}
        XCTAssertEqual(host.captures.first?.stops, 1)
        host.delayed = false; host.fail = true
        await rejected { try await manager.handle(open(), connection: owner, send: send) }
        host.fail = false
        _ = try await manager.handle(open(), connection: owner, send: send)
        manager.stop(); XCTAssertEqual(host.captures.last?.stops, 1)
    }

    func testDesktopGeometryAudioAndKeyboardRelease() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000), video = CGSize(width: 1920, height: 1080)
        XCTAssertNil(MacVideoView.normalized(CGPoint(x: 500, y: 20), bounds: bounds, videoSize: video, clamp: false))
        XCTAssertEqual(MacVideoView.normalized(CGPoint(x: 500, y: 500), bounds: bounds, videoSize: video, clamp: false), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(MacVideoView.normalized(CGPoint(x: -100, y: 1000), bounds: bounds, videoSize: video, clamp: true), CGPoint(x: 0, y: 1))
        XCTAssertTrue(DesktopAudioFrame(data: Data(count: 480 * 8), frames: 480).isValid)
        XCTAssertFalse(DesktopAudioFrame(data: Data(count: 480 * 8 - 1), frames: 480).isValid)
        XCTAssertFalse(DesktopAudioFrame(data: Data(count: 4801 * 8), frames: 4801).isValid)
        var state = AppWindowEventState(), down = AppWindowInput(.down)
        down.x = 0.5; down.y = 0.25; down.button = 2
        let frame = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        XCTAssertEqual(state.events(for: down, frame: frame, windowID: nil).first?.location, CGPoint(x: -960, y: 170))
        down.kind = .move
        XCTAssertEqual(state.events(for: down, frame: frame, windowID: nil).first?.type, .otherMouseDragged)
        XCTAssertEqual(state.release(windowID: nil).count, 1)
        let view = MacVideoView(frame: .zero)
        var inputs: [AppWindowInput] = []; view.onInput = { inputs.append($0) }; view.inputEnabled = true
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        view.keyDown(with: key); view.releaseInput(); view.releaseInput()
        XCTAssertEqual(inputs.map(\.kind), [.keyDown, .keyUp]); XCTAssertEqual(inputs.last?.modifiers, 0)
    }

    private func encodedFrame() async throws -> AppWindowVideoFrame {
        let received = expectation(description: "H.264 frame")
        var result: AppWindowVideoFrame?, assembler = AppWindowVideoAssembler()
        let encoder = AppWindowVideoEncoder(send: { packet, completion in
            do { if let frame = try assembler.receive(packet) { result = frame; received.fulfill() }; completion(nil) }
            catch { completion(error) }
        }, encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false] as CFDictionary)
        defer { encoder.stop() }
        try encoder.configure(.init(width: 640, height: 480, frameRate: 60))
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
        let buffer = try XCTUnwrap(image)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let captured = try XCTUnwrap(sample)
        // ScreenCaptureKit marks status on the per-sample attachment array.
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(captured, createIfNecessary: true) as? [NSMutableDictionary])
        attachments[0][SCStreamFrameInfo.status] = SCFrameStatus.complete.rawValue
        encoder.queue.sync { encoder.encode(captured) }
        await fulfillment(of: [received], timeout: 5)
        return try XCTUnwrap(result)
    }

    func testMacClientStreamsOverAuthenticatedWorkspaceAndDisconnectKeepsHostRunning() async throws {
        let frame = try await encodedFrame()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let deviceStore = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let remote = RecordingDesktopHost(), desktop = DesktopSessionManager(host: remote)
        let host = try WorkspaceServer(folder: root, name: "Other Mac", devices: deviceStore, desktop: desktop)
        var listening = false; host.onStatus = { status, _ in if status == "Ready" { listening = true } }
        let secret = try SecureStore.randomKey(), port = UInt16.random(in: 52_000..<59_000)
        try host.start(secret: secret, port: port); defer { host.stop(); desktop.stop() }
        try await waitFor("listener") { listening }
        let invitation = try PairingInvitation(host: "127.0.0.1", port: port, name: "Other Mac", secret: secret, enrollmentToken: deviceStore.createInvitation())
        let identity = try MacClientIdentity.generate().workspace(name: "Client Mac")
        var saved: [String: Data] = [:]
        let client = MacClientModel(read: { saved[$0] }, write: { saved[$1] = $0 }, makeIdentity: { identity })
        XCTAssertTrue(client.addHost(invitation.url.absoluteString)); XCTAssertNil(saved[MacClientModel.account], "Save only after authentication")
        let stream = try XCTUnwrap(client.session)
        stream.viewport(CGSize(width: 800, height: 600), scale: 2); stream.activate()
        try await waitFor("native desktop handshake", timeout: 10) { stream.display != nil || stream.error != nil }
        XCTAssertNil(stream.error); XCTAssertEqual(stream.selectedDisplayID, 7)
        XCTAssertEqual(client.pairedServers.servers.count, 1); XCTAssertNotNil(saved[MacClientModel.account]); XCTAssertNil(saved["server-key"])
        var packet = Packet(.desktopVideo); packet.video = frame
        try XCTUnwrap(remote.captures.first).send(packet) { _ in }
        try await waitFor("native video presentation") { stream.ready }
        stream.sendInput(AppWindowInput(.keyDown))
        try await waitFor("remote keyboard event") { remote.captures.first?.inputs.count == 1 }
        stream.viewport(CGSize(width: 1024, height: 768), scale: 1)
        try await waitFor("viewport resize") { remote.captures.first?.resizes.count == 1 }
        XCTAssertEqual(remote.captures.count, 1, "A viewer resize must reuse its capture lease")
        stream.selectDisplay(8)
        try await waitFor("display switch", timeout: 10) { (remote.captures.count == 2 && stream.display != nil) || stream.error != nil }
        XCTAssertNil(stream.error); XCTAssertEqual(stream.selectedDisplayID, 8)
        XCTAssertEqual(remote.captures.first?.stops, 1)
        let secondConnection = WorkspaceConnection(identity: identity, remoteStreaming: false)
        try await secondConnection.connect(invitation, restoreTerminalSessions: false)
        defer { secondConnection.disconnect() }
        client.disconnect()
        try await waitFor("capture release") { remote.captures.count == 2 && remote.captures[1].stops == 1 }
        XCTAssertFalse(stream.ready); XCTAssertNil(client.session)
        _ = try await secondConnection.request(Packet(.ping))
        XCTAssertEqual(secondConnection.state, .connected, "Closing an outgoing stream must leave host services and other connections running")
        client.connect(try XCTUnwrap(client.pairedServers.servers.first?.id))
        let reconnected = try XCTUnwrap(client.session)
        reconnected.viewport(CGSize(width: 800, height: 600), scale: 1); reconnected.activate()
        try await waitFor("saved host reconnect", timeout: 10) { reconnected.display != nil || reconnected.error != nil }
        XCTAssertNil(reconnected.error); XCTAssertEqual(remote.captures.count, 3)
        client.disconnect()
    }

    func testUnsupportedHostAndFailedPairingSaveCloseConnectionWithoutReplacingSavedHosts() async throws {
        for failSave in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
            let remote = RecordingDesktopHost(), desktop = DesktopSessionManager(host: remote)
            let host = try WorkspaceServer(folder: root, name: "Host", devices: store, desktop: failSave ? desktop : nil)
            var listening = false; host.onStatus = { status, _ in if status == "Ready" { listening = true } }
            let secret = try SecureStore.randomKey(), port = UInt16.random(in: 52_000..<59_000)
            try host.start(secret: secret, port: port); defer { host.stop(); desktop.stop() }
            try await waitFor("listener") { listening }
            let invitation = try PairingInvitation(host: "127.0.0.1", port: port, name: "Host", secret: secret, enrollmentToken: store.createInvitation())
            let identity = try MacClientIdentity.generate().workspace(name: "Mac")
            var existing = PairedServerList()
            existing.pair(try PairingInvitation(host: "other.local", name: "Saved Mac", secret: SecureStore.randomKey()))
            let encoded = try JSONEncoder().encode(existing)
            var writes = 0
            let client = MacClientModel(read: { $0 == MacClientModel.account ? encoded : nil }, write: { _, _ in
                writes += 1; throw NocturneError.remote("Pairing storage is locked.")
            }, makeIdentity: { identity })
            XCTAssertTrue(client.addHost(invitation.url.absoluteString))
            let stream = try XCTUnwrap(client.session)
            stream.viewport(CGSize(width: 800, height: 600), scale: 1); stream.activate()
            try await waitFor("actionable connection failure", timeout: 10) { stream.error != nil }
            XCTAssertEqual(client.pairedServers, existing)
            XCTAssertEqual(stream.connection.state, .disconnected); XCTAssertTrue(remote.captures.isEmpty)
            XCTAssertEqual(writes, failSave ? 1 : 0)
            XCTAssertTrue(stream.error?.contains(failSave ? "storage is locked" : "latest Nocturne Server") == true)
            client.disconnect()
        }
    }
}
