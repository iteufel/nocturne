import XCTest
import AppKit
import Network
import NocturneKit
@testable import NocturneHostKit

@MainActor
final class BrowserConnectionTests: XCTestCase {
    private func request(_ action: BrowserCommand.Action, id: String, value: String? = nil) -> Packet {
        var packet = Packet(.browserCommand); packet.sessionID = id; packet.browserCommand = .init(action, value: value); return packet
    }
    private func start(_ server: WorkspaceServer, secret: Data) async throws -> UInt16 {
        let ready = expectation(description: "Browser pairing server ready")
        var signalled = false
        server.onStatus = { state, _ in if state == "Ready", !signalled { signalled = true; ready.fulfill() } }
        try server.start(secret: secret, port: 0)
        await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(server.listeningPort)
    }
    func testBrowserOverRealPairingTLSWithRevocationDisconnectAndHostSwitch() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-browser-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureStore.randomKey(), store = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Browser fixture Mac", devices: store, permissions: .init(browser: true))
        let identity = try TestDeviceIdentity(), client = WorkspaceConnection(identity: identity.identity())
        defer { client.disconnect(); server.stop() }
        let port = try await start(server, secret: key)
        let invitation = try PairingInvitation(host: "127.0.0.1", port: port, name: "Fixture", secret: key, enrollmentToken: store.createInvitation())
        try await client.connect(invitation)
        XCTAssertTrue(client.capabilities.contains(BrowserProtocol.capability))
        let fixture = try BrowserFixture(); try await fixture.start(); defer { fixture.stop() }
        let id = UUID().uuidString
        _ = try await client.request(request(.open, id: id))
        _ = try await client.request(request(.navigate, id: id, value: fixture.url("/redirect")))
        var rendered = false
        for _ in 0..<100 {
            let packet = try await client.request(request(.frame, id: id))
            if packet.browserFrame?.title.hasPrefix("ready:asset:socket-ok:") == true, packet.browserFrame?.jpeg != nil { rendered = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(rendered, "Actual TLS framing must deliver the Mac-rendered page")
        server.updatePermissions(.init())
        do { _ = try await client.request(request(.frame, id: id)); XCTFail("Revoked permission accepted") } catch {}
        server.updatePermissions(.init(browser: true))
        do { _ = try await client.request(request(.frame, id: id)); XCTFail("Revoked browser session survived") } catch {}
        let reopened = UUID().uuidString
        _ = try await client.request(request(.open, id: reopened))
        client.disconnect()
        try await client.connect(invitation)
        do { _ = try await client.request(request(.frame, id: reopened)); XCTFail("Disconnected session survived on new socket") } catch {}
        // A different paired Mac cannot use the old socket's session ID, even with the same device identity.
        let secondStore = try WorkspaceDeviceStore(url: root.appendingPathComponent("second/devices.json"))
        let secondKey = try SecureStore.randomKey()
        let second = try WorkspaceServer(folder: root.appendingPathComponent("second/shared"), name: "Second fixture Mac", devices: secondStore, permissions: .init(browser: true))
        defer { second.stop() }
        let secondPort = try await start(second, secret: secondKey)
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: secondPort, name: "Second fixture", secret: secondKey, enrollmentToken: secondStore.createInvitation()))
        do { _ = try await client.request(request(.frame, id: reopened)); XCTFail("Host switch leaked session") } catch {}
        _ = try await client.request(request(.open, id: UUID().uuidString))
    }
    func testTransportKeyAloneCannotUseBrowserAndFeatureDefaultsOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-browser-auth-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureStore.randomKey(), store = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Fixture", devices: store)
        defer { server.stop() }
        let port = try await start(server, secret: key)
        let denied = expectation(description: "PSK-only browser request rejected")
        let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: SecureTransport.parameters(secret: key)))
        defer { channel.cancel() }
        let packet = request(.open, id: UUID().uuidString)
        channel.onReady = { channel.send(packet) }
        channel.onPacket = { reply in XCTAssertNotNil(reply.error); XCTAssertNil(reply.browserFrame); denied.fulfill() }
        channel.start()
        await fulfillment(of: [denied], timeout: 5)
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity()); defer { client.disconnect() }
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Fixture", secret: key, enrollmentToken: store.createInvitation()))
        XCTAssertFalse(client.capabilities.contains(BrowserProtocol.capability))
        do { _ = try await client.request(request(.open, id: UUID().uuidString)); XCTFail("Default-disabled browser opened") } catch {}
    }
}
