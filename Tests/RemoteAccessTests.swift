import XCTest
import Network
import Security
import NocturneKit
import NocturneHostKit

@MainActor
final class RemoteAccessTests: XCTestCase {
    func testQRAndSavedPairingPreserveRemoteIdentityAcrossAddressChanges() throws {
        let access = try RemoteAccess(brokerURL: "https://broker.example.com/", endpointID: String(repeating: "ab", count: 32))
        let original = try PairingInvitation(host: "192.168.1.20", name: "Remote Mac", secret: Data(repeating: 1, count: 32), enrollmentToken: Data(repeating: 2, count: 32), remoteAccess: access)
        XCTAssertEqual(try PairingInvitation(url: original.url), original)
        let moved = try original.replacingAddress(host: "192.168.2.40", port: 48556)
        let saved = try JSONDecoder().decode(PairingInvitation.self, from: JSONEncoder().encode(moved))
        XCTAssertEqual(saved.remoteAccess, access)
        XCTAssertEqual(saved.host, "192.168.2.40")
        XCTAssertEqual(saved.secret, original.secret)
        let legacy = try PairingInvitation(host: "10.0.0.2", name: "LAN Mac", secret: original.secret)
        XCTAssertNil(try JSONDecoder().decode(PairingInvitation.self, from: JSONEncoder().encode(legacy)).remoteAccess)
        XCTAssertEqual(try PairingInvitation(url: legacy.url), legacy)
    }

    func testInvalidBrokerAndTamperedPairingFailClosed() throws {
        let id = String(repeating: "ab", count: 32)
        for url in ["http://example.com", "https://user:secret@example.com", "https://example.com/path", "https://example.com/?token=secret", "https://example.com/#fragment", "https://example.com:0", "file:///tmp/relay"] {
            XCTAssertThrowsError(try RemoteAccess(brokerURL: url, endpointID: id), url)
        }
        XCTAssertThrowsError(try RemoteAccess(brokerURL: "https://example.com", endpointID: "not-a-key"))
        let invitation = try PairingInvitation(host: "10.0.0.2", name: "Mac", secret: Data(repeating: 1, count: 32))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(invitation)) as? [String: Any])
        fields["port"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(PairingInvitation.self, from: JSONSerialization.data(withJSONObject: fields)))
        XCTAssertThrowsError(try PairingInvitation(url: XCTUnwrap(URL(string: invitation.url.absoluteString + "&host=attacker"))))
    }

    func testRemoteTLSWorkspaceMediaReconnectAndRevocation() async throws {
        let (broker, brokerURL) = try await startBroker()
        defer { if broker.isRunning { broker.terminate(); broker.waitUntilExit() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureStore.randomKey(), identity = try TestDeviceIdentity()
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let host = try WorkspaceServer(folder: root.appendingPathComponent("files"), name: "Online Mac", devices: devices, permissions: .init(terminal: true, files: true))
        let port = UInt16.random(in: 52_000..<58_000)
        let tunnel = try await RemoteTunnel.host(brokerURL: brokerURL, endpointKey: SecureStore.randomKey(), port: port)
        defer { host.stop(); tunnel.stop() }
        host.authorizeRemoteDevice = { try tunnel.authorize(sourcePort: $0, deviceID: $1) }
        let ready = expectation(description: "Workspace ready")
        var signalled = false
        host.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; ready.fulfill() } }
        try host.start(secret: key, port: port)
        await fulfillment(of: [ready], timeout: 5)
        let access = try RemoteAccess(brokerURL: brokerURL, endpointID: tunnel.endpointID)
        // A stale LAN port forces the real Rust/Swift fallback without binding game ports.
        let invitation = try PairingInvitation(host: "127.0.0.1", port: port + 1, name: "Online Mac", secret: key, enrollmentToken: devices.createInvitation(), remoteAccess: access)
        let client = WorkspaceConnection(identity: identity.identity(), remoteStreaming: false)
        defer { client.disconnect() }
        try await client.connect(invitation)
        XCTAssertEqual(client.state, .connected)
        XCTAssertNotEqual(client.connectionRoute, "Local network")
        XCTAssertEqual(client.connectedInvitation, invitation)
        let tab = try await client.openTerminal()
        var list = Packet(.list); list.path = ""
        _ = try await client.request(list)
        let media = client.mediaConnection(); defer { media.disconnect() }
        try await media.connect(invitation, restoreTerminalSessions: false)
        XCTAssertEqual(media.state, .connected)
        media.disconnect()
        // An app window from another paired Mac must not ride this Mac's tunnel.
        let officeDevices = try WorkspaceDeviceStore(url: root.appendingPathComponent("office-devices.json"))
        let office = try WorkspaceServer(folder: root.appendingPathComponent("office"), name: "Office Mac", devices: officeDevices, permissions: .init(terminal: false, files: true))
        defer { office.stop() }
        let officeReady = expectation(description: "Second Mac ready")
        var officeSignalled = false
        office.onStatus = { status, _ in if status == "Ready", !officeSignalled { officeSignalled = true; officeReady.fulfill() } }
        let officeKey = try SecureStore.randomKey(), officePort = port + 2
        try office.start(secret: officeKey, port: officePort)
        await fulfillment(of: [officeReady], timeout: 5)
        let officeWindow = client.mediaConnection(); defer { officeWindow.disconnect() }
        try await officeWindow.connect(PairingInvitation(host: "127.0.0.1", port: officePort, name: "Office Mac", secret: officeKey,
            enrollmentToken: officeDevices.createInvitation()), restoreTerminalSessions: false)
        XCTAssertEqual(officeWindow.name, "Office Mac")
        XCTAssertEqual(officeWindow.connectionRoute, "Local network")
        officeWindow.disconnect(); office.stop()
        // Files keeps the public remote route, strips enrollment, and opens its own
        // workspace-only tunnel while the containing app is connected or suspended.
        let account = try FilesProviderAccount(invitation: invitation, certificate: identity.certificate,
            privateKey: XCTUnwrap(SecKeyCopyExternalRepresentation(identity.key, nil)) as Data, deviceName: "Files iPad")
        let saved = try JSONDecoder().decode(FilesProviderAccount.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(saved.invitation.remoteAccess, access)
        XCTAssertEqual(saved.invitation.host, invitation.host)
        XCTAssertEqual(saved.invitation.port, invitation.port)
        XCTAssertNil(saved.invitation.enrollmentToken)
        let files = WorkspaceConnection(identity: try saved.identity(), remoteStreaming: false)
        defer { files.disconnect() }
        try await files.connect(saved.invitation, restoreTerminalSessions: false)
        XCTAssertNotEqual(files.connectionRoute, "Local network")
        XCTAssertEqual(client.state, .connected)
        client.disconnect()
        let payload = Data((0..<150_000).map { UInt8($0 % 251) })
        try payload.write(to: host.folder.url.appendingPathComponent("remote.txt"))
        let listing = try await files.request(list)
        let file = try XCTUnwrap(listing.files?.first { $0.name == "remote.txt" })
        let download = try await FileTransferModel().download(file, using: files)
        defer { try? FileManager.default.removeItem(at: download.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: download), payload)
        XCTAssertTrue(files.terminals.isEmpty)
        files.disconnect()
        // The consumed invitation token cannot enroll anyone else, but this device can reconnect.
        try await client.connect(invitation)
        XCTAssertEqual(client.terminals.map(\.id), [tab])
        let unauthorized = WorkspaceConnection(identity: try TestDeviceIdentity().identity(), remoteStreaming: false)
        defer { unauthorized.disconnect() }
        do { try await unauthorized.connect(invitation); XCTFail("Consumed invitation enrolled another remote device") } catch {}
        try devices.remove(identity.id, name: "Device")
        host.disconnectDevice(identity.id); tunnel.revoke(deviceID: identity.id)
        do { _ = try await client.request(Packet(.ping)); XCTFail("Revoked device kept access") } catch {}
        client.disconnect()
        do { try await client.connect(invitation); XCTFail("Revoked remote device reconnected") } catch {}
    }

    private func startBroker() async throws -> (Process, String) {
        guard let executable = ProcessInfo.processInfo.environment["NOCTURNE_BROKER_EXECUTABLE"] else {
            throw XCTSkip("Set NOCTURNE_BROKER_EXECUTABLE to run the Rust/Swift integration test.")
        }
        let port = UInt16.random(in: 40_000..<49_000)
        let url = "http://127.0.0.1:\(port)"
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["--dev"]
        var environment = ProcessInfo.processInfo.environment
        environment["NOCTURNE_BROKER_HTTP"] = "127.0.0.1:\(port)"; environment["NOCTURNE_BROKER_METRICS"] = "127.0.0.1:0"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<50 {
            var request = URLRequest(url: URL(string: url + "/ping")!); request.timeoutInterval = 0.2
            if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return (process, url) }
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        throw NocturneError.remote("Test broker did not start")
    }
}
