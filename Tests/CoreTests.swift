import XCTest
import Foundation
import NocturneKit
import NocturneHostKit

final class CoreTests: XCTestCase {
    func testTouchAndTrackpadModesPreserveExistingSavedPreferences() throws {
        let saved = Data(#"{"resolution":"1440p","frameRate":120,"bitrate":35,"hdr":true,"framePacing":false,"touchControls":true,"absolutePointer":true,"statistics":true,"multiController":false}"#.utf8)
        var preferences = try JSONDecoder().decode(StreamPreferences.self, from: saved)
        XCTAssertEqual(preferences.inputMode, .touch)
        preferences.inputMode = .trackpad
        let restored = try JSONDecoder().decode(StreamPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.inputMode, .trackpad)
        XCTAssertEqual(restored.bitrate, 35)
        XCTAssertEqual(restored.resolution, "1440p")
        XCTAssertTrue(restored.hdr)
        preferences.inputMode = .touch
        XCTAssertEqual(preferences, try JSONDecoder().decode(StreamPreferences.self, from: saved))
        XCTAssertEqual(StreamPreferences().inputMode, .trackpad)
    }
    func testInvitationRoundTripAndValidation() throws {
        let invitation = try PairingInvitation(host: "fe80::abcd%en0", name: "Studio Mac", secret: Data(repeating: 0x42, count: 32))
        XCTAssertEqual(try PairingInvitation(url: invitation.url), invitation)
        let enrollment = try PairingInvitation(host: "mac.local", name: "Mac", secret: Data(repeating: 0x42, count: 32), enrollmentToken: Data(repeating: 0x24, count: 32))
        XCTAssertEqual(try PairingInvitation(url: enrollment.url), enrollment)
        XCTAssertEqual(try JSONDecoder().decode(PairingInvitation.self, from: JSONEncoder().encode(enrollment)), enrollment)
        XCTAssertThrowsError(try PairingInvitation(host: "mac.local", name: "Mac", secret: Data(repeating: 0x42, count: 32), enrollmentToken: Data([1])))
        XCTAssertThrowsError(try PairingInvitation(url: URL(string: "nocturne://pair?key=123")!))
        XCTAssertThrowsError(try PairingInvitation(host: "bad/host", name: "Mac", secret: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try PairingInvitation(host: "mac.local", name: "Mac", secret: Data(repeating: 0, count: 4)))
    }
    func testFramingRejectsUnboundedPayloads() throws {
        var packet = Packet(.uploadChunk); packet.data = Data(repeating: 1, count: 10)
        let encoded = try FrameCodec.encode(packet)
        XCTAssertEqual(try FrameCodec.length(encoded.prefix(4)), encoded.count - 4)
        XCTAssertEqual(try JSONDecoder().decode(Packet.self, from: encoded.dropFirst(4)).data, packet.data)
        XCTAssertThrowsError(try FrameCodec.length(Data([255, 255, 255, 255])))
        XCTAssertThrowsError(try FrameCodec.length(Data([0, 0, 0, 0])))
        packet.data = Data(repeating: 1, count: WorkspaceProtocol.maximumFrame)
        XCTAssertThrowsError(try FrameCodec.encode(packet))
    }
    func testAdaptiveLayoutUsesAvailableWidth() {
        XCTAssertEqual(WorkspaceLayout.resolve(width: 393), .compact)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 699), .compact)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 700), .expanded)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 1024), .expanded)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 375), .compact)
    }
    func testSharedFolderRejectsTraversalSymlinksAndOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try SharedFolder(url: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try folder.list("../"))
        XCTAssertThrowsError(try folder.list("/tmp"))
        XCTAssertThrowsError(try folder.list("escape"))
        XCTAssertThrowsError(try folder.beginUpload(path: "escape/escaped.txt", size: 0))
        let transfer = try folder.beginUpload(path: "hello.txt", size: 5)
        XCTAssertThrowsError(try transfer.append(Data("hello".utf8), offset: 1))
        try transfer.append(Data("hello".utf8), offset: 0); try transfer.finish()
        XCTAssertEqual(try folder.read("hello.txt", offset: 0).data, Data("hello".utf8))
        XCTAssertThrowsError(try folder.beginUpload(path: "hello.txt", size: 0))
        XCTAssertEqual(try folder.list("").map(\.name), ["hello.txt"])
    }
    func testIncompleteAndCancelledUploadsStayInvisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try SharedFolder(url: root)
        var transfer: IncomingTransfer? = try folder.beginUpload(path: "incomplete", size: 99)
        try transfer!.append(Data("part".utf8), offset: 0)
        XCTAssertThrowsError(try transfer!.finish())
        XCTAssertTrue(try folder.list("").isEmpty)
        transfer = nil
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testFileCreatedDuringUploadIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try SharedFolder(url: root)
        let transfer = try folder.beginUpload(path: "race", size: 3)
        try transfer.append(Data("new".utf8), offset: 0)
        try Data("original".utf8).write(to: root.appendingPathComponent("race"))
        XCTAssertThrowsError(try transfer.finish())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("race")), Data("original".utf8))
    }
}

@MainActor
final class WorkspaceIntegrationTests: XCTestCase {
    func testTLSFileTransferTerminalAndPermissionRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureStore.randomKey()
        let port = UInt16.random(in: 52_000..<60_000)
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("state/devices.json"))
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Integration Mac", devices: devices, permissions: .init(terminal: true, files: true))
        defer { server.stop() }
        let listening = expectation(description: "Listener ready")
        var signalled = false
        server.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; listening.fulfill() } }
        try server.start(secret: key, port: port)
        await fulfillment(of: [listening], timeout: 5)
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity()); defer { client.disconnect() }
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: key, enrollmentToken: devices.createInvitation()))
        XCTAssertEqual(client.state, .connected); XCTAssertEqual(client.name, "Integration Mac")

        let payload = Data((0..<450_000).map { UInt8($0 % 251) })
        let source = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".bin")
        defer { try? FileManager.default.removeItem(at: source) }
        try payload.write(to: source)
        let transfer = FileTransferModel()
        try await transfer.upload(source, to: "", using: client)
        var list = Packet(.list); list.path = ""
        let listing = try await client.request(list)
        let file = try XCTUnwrap(listing.files?.first)
        let download = try await transfer.download(file, using: client)
        defer { try? FileManager.default.removeItem(at: download.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: download), payload)

        let terminalOutput = expectation(description: "Real PTY output")
        var output = Data(); var found = false
        try await client.openTerminal(columns: 100, rows: 30)
        let tab = try XCTUnwrap(client.terminals.first)
        let subscription = tab.output.sink { update in
            guard case .append(let data) = update else { return }
            output.append(data)
            if String(decoding: output, as: UTF8.self).contains("nocturne-" + "pty-ok"), !found { found = true; terminalOutput.fulfill() }
        }
        defer { subscription.cancel() }
        try await client.terminalInput(Data("printf 'nocturne-%s\\n' 'pty-ok'\r".utf8))
        await fulfillment(of: [terminalOutput], timeout: 10)
        try await client.resizeTerminal(columns: 120, rows: 40)
        try await client.closeTerminal()
        XCTAssertNil(client.terminalID)

        server.updatePermissions(.init())
        do { _ = try await client.request(list); XCTFail("Files must be denied after revocation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Enable this feature")) }
    }
    func testWrongPairingKeyIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Mac", devices: devices)
        defer { server.stop() }
        let port = UInt16.random(in: 52_000..<60_000)
        let ready = expectation(description: "Listener ready")
        var signalled = false
        server.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; ready.fulfill() } }
        try server.start(secret: Data(repeating: 1, count: 32), port: port)
        await fulfillment(of: [ready], timeout: 5)
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity()); defer { client.disconnect() }
        do {
            try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: Data(repeating: 2, count: 32)))
            XCTFail("A wrong PSK must never authenticate")
        } catch { XCTAssertEqual(client.state, .disconnected) }
    }
}

@MainActor
final class EmbeddedEngineIntegrationTests: XCTestCase {
    func testBundledEngineAuthenticatedLifecycle() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOCTURNE_ENGINE_EXECUTABLE"] else {
            throw XCTSkip("Set NOCTURNE_ENGINE_EXECUTABLE to run the real embedded engine check.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Nocturne-engine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try TestDeviceIdentity(), second = try TestDeviceIdentity()
        let firstID = UUID().uuidString, secondID = UUID().uuidString
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let state: [String: Any] = ["root": ["uniqueid": UUID().uuidString, "named_devices": [
            ["uuid": firstID, "name": "iPad", "cert": first.pem, "enabled": "true"],
            ["uuid": secondID, "name": "iPad", "cert": second.pem, "enabled": "true"]]]]
        try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent("state.json"))
        let engine = EmbeddedStreamingEngine(directory: root)
        defer { engine.stop() }
        try await engine.start(executable: URL(fileURLWithPath: path), name: "Nocturne integration")
        XCTAssertTrue(engine.isRunning)
        let paired = try await engine.pairedDevices()
        XCTAssertEqual(Set(paired.map(\.fingerprint)), [first.id, second.id])
        try await engine.removeDevice(firstID)
        let remaining = try await engine.pairedDevices()
        XCTAssertEqual(remaining.map(\.id), [secondID]); XCTAssertTrue(remaining[0].enabled)
        XCTAssertEqual(try engine.savedDevices().map(\.id), [secondID])
        let applicationList = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("apps.json"))) as? [String: Any])
        XCTAssertNotNil(applicationList["env"] as? [String: String])
        XCTAssertEqual((applicationList["apps"] as? [[String: String]])?.first?["name"], "Desktop")
        let log = try String(contentsOf: engine.logURL)
        XCTAssertFalse(log.contains("No such node"), "The engine must load its actual application library")
        let config = try String(contentsOf: root.appendingPathComponent("engine.conf"))
        XCTAssertTrue(config.contains("origin_web_ui_allowed = pc"))
        XCTAssertTrue(config.contains("system_tray = disabled"))
        XCTAssertFalse(config.contains("password"))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        engine.stop(); XCTAssertFalse(engine.isRunning)
        // Restart must load persisted certificates while rotating the local API credential.
        try await engine.start(executable: URL(fileURLWithPath: path), name: "Nocturne integration")
        XCTAssertTrue(engine.isRunning)
        let afterRestart = try await engine.pairedDevices()
        XCTAssertEqual(afterRestart.map(\.id), [secondID])
        try await engine.resetPairing()
        let cleared = try await engine.pairedDevices()
        XCTAssertTrue(cleared.isEmpty)
    }
}
