import XCTest
import Network
@testable import NocturneKit
import NocturneHostKit

@MainActor
final class DiscoveryTests: XCTestCase {
    func testScopedIPv4EndpointCanBeReusedByHTTPAndNetworkConnections() async throws {
        let monitor = NWPathMonitor(); defer { monitor.cancel() }
        let ready = expectation(description: "Network interfaces available")
        monitor.pathUpdateHandler = { _ in
            monitor.pathUpdateHandler = nil; ready.fulfill()
        }
        monitor.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        let interface = try XCTUnwrap(monitor.currentPath.availableInterfaces.first)
        let scoped = try XCTUnwrap(IPv4Address(Data([192, 168, 0, 123]), interface))
        let host = NWEndpoint.Host.ipv4(scoped)
        XCTAssertTrue(String(describing: host).contains("%"), "Exercise the scoped endpoint returned by Bonjour")
        let reusable = WorkspaceConnection.reusableAddress(host)
        XCTAssertEqual(URLComponents(string: "http://\(reusable):47989/serverinfo")?.host, "192.168.0.123")
        guard case .ipv4 = NWEndpoint.Host(reusable) else { return XCTFail("Saved IPv4 endpoint became a DNS hostname") }
    }

    func testPairedWorkspaceFindsNewAddressAndPortWithoutReenrollment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureStore.randomKey(), identity = try TestDeviceIdentity()
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let name = "Discovery Mac " + UUID().uuidString
        let host = try WorkspaceServer(folder: root.appendingPathComponent("files"), name: name, devices: devices, permissions: .init(terminal: true, files: true))
        let otherDevices = try WorkspaceDeviceStore(url: root.appendingPathComponent("other.json"))
        let other = try WorkspaceServer(folder: root.appendingPathComponent("other"), name: name, devices: otherDevices)
        defer { host.stop(); other.stop() }
        try await start(host, key: key, port: 0)
        let port = try XCTUnwrap(host.listeningPort)
        // Duplicate display names are deliberately ambiguous; only the key-derived ID matches.
        try await start(other, key: SecureStore.randomKey(), port: 0)
        let client = WorkspaceConnection(identity: identity.identity()); defer { client.disconnect() }
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: name, secret: key, enrollmentToken: devices.createInvitation()))
        let tab = try await client.openTerminal()
        client.disconnect()

        // Represents an existing Keychain record after changing networks. No fresh QR/token.
        let saved = try PairingInvitation(host: "192.0.2.123", port: port == 1 ? 2 : 1, name: "Old Mac name", secret: key)
        let restored = try JSONDecoder().decode(PairingInvitation.self, from: JSONEncoder().encode(saved))
        try await client.connect(restored, rediscover: true)
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(client.terminals.map(\.id), [tab])
        let current = try XCTUnwrap(client.connectedInvitation)
        XCTAssertNotEqual(current.host, saved.host)
        XCTAssertEqual(client.streamingAddress, current.host)
        XCTAssertEqual(current.port, port)
        XCTAssertEqual(current.secret, key)
        XCTAssertNil(current.enrollmentToken)
        XCTAssertEqual(devices.devices.count, 1)
        XCTAssertTrue(otherDevices.devices.isEmpty)
        var list = Packet(.list); list.path = ""
        _ = try await client.request(list)

        // The refreshed address must also work for the independent microphone socket.
        let media = client.mediaConnection(); defer { media.disconnect() }
        try await media.connect(current, restoreTerminalSessions: false)
        XCTAssertEqual(media.state, .connected)
    }

    func testCancellationStopsLookupWithoutDisconnectingTheNextAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureStore.randomKey(), identity = try TestDeviceIdentity()
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let host = try WorkspaceServer(folder: root.appendingPathComponent("files"), name: "Fallback Mac", devices: devices)
        defer { host.stop() }
        try await start(host, key: key, port: 0)
        let port = try XCTUnwrap(host.listeningPort)
        let client = WorkspaceConnection(identity: identity.identity()); defer { client.disconnect() }
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: key, enrollmentToken: devices.createInvitation()))
        XCTAssertEqual(client.connectedInvitation?.port, port)
        client.disconnect()
        let absent = try PairingInvitation(host: "127.0.0.1", port: port, name: "Missing", secret: SecureStore.randomKey())
        let task = Task { try await client.connect(absent, rediscover: true) }
        await Task.yield()
        task.cancel()
        // Start the replacement before the cancelled task and its queued callbacks drain.
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: key))
        do { try await task.value; XCTFail("Cancelled lookup connected") } catch {}
        let cancelledBeforeStart = Task { try await client.connect(absent, rediscover: true) }
        cancelledBeforeStart.cancel()
        do { try await cancelledBeforeStart.value; XCTFail("Cancelled attempt connected") } catch {}
        _ = try await client.request(Packet(.ping))
        XCTAssertEqual(client.state, .connected)
    }

    func testMissingBonjourIdentityFallsBackToSavedAddress() async throws {
        let key = try SecureStore.randomKey(), identity = try TestDeviceIdentity()
        // A minimal legacy workspace peer with real TLS and device proof, but no
        // Bonjour identity announcement. This exercises the saved-address fallback.
        let listener = try NWListener(using: SecureTransport.parameters(secret: key), on: .any)
        var channels: [SecureChannel] = []
        defer { listener.cancel(); channels.forEach { $0.cancel() } }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let channel = SecureChannel(connection: connection, queue: .main)
                channels.append(channel)
                let nonce = Data(repeating: 42, count: 32)
                channel.onPacket = { [weak channel] packet in
                    guard let channel else { return }
                    var reply = packet.reply(); reply.version = WorkspaceProtocol.version
                    if packet.operation == .hello { reply.data = nonce }
                    else if packet.operation == .authenticate {
                        do {
                            let certificate = try XCTUnwrap(packet.certificate), signature = try XCTUnwrap(packet.signature)
                            let device = try WorkspaceIdentity.verify(certificate: certificate, signature: signature,
                                challenge: channel.boundChallenge(nonce))
                            XCTAssertEqual(device, identity.id)
                            reply.name = "Legacy Mac"; reply.capabilities = []
                        } catch { reply.error = error.localizedDescription }
                    }
                    channel.send(reply)
                }
                channel.start()
            }
        }
        let ready = expectation(description: "Legacy peer ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port).rawValue
        let client = WorkspaceConnection(identity: identity.identity()); defer { client.disconnect() }
        try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: key), rediscover: true)
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(client.name, "Legacy Mac")
        XCTAssertEqual(client.connectedInvitation?.port, port)
    }

    func testDiscoveryMetadataCannotAuthorizeAnUnpairedDevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureStore.randomKey()
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let host = try WorkspaceServer(folder: root.appendingPathComponent("files"), name: "Private Mac", devices: devices)
        defer { host.stop() }
        try await start(host, key: key, port: 0)
        let port = try XCTUnwrap(host.listeningPort)
        let discovery = WorkspaceDiscovery()
        let endpoint = await discovery.find(secret: key)
        XCTAssertNotNil(endpoint)
        let client = WorkspaceConnection(identity: try TestDeviceIdentity().identity()); defer { client.disconnect() }
        do {
            try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: key), rediscover: true)
            XCTFail("Discovery enrolled a device without scanning a QR")
        } catch {}
        XCTAssertEqual(client.state, .disconnected)
        XCTAssertNil(client.connectedInvitation)
        XCTAssertTrue(devices.devices.isEmpty)
        XCTAssertNotEqual(WorkspaceDiscovery.identifier(for: key), key.base64EncodedString())
        XCTAssertNotEqual(WorkspaceDiscovery.identifier(for: key), WorkspaceDiscovery.identifier(for: try SecureStore.randomKey()))
    }

    private func start(_ host: WorkspaceServer, key: Data, port: UInt16) async throws {
        let ready = expectation(description: "Workspace listener ready")
        var signalled = false
        host.onStatus = { status, _ in
            if status == "Ready", !signalled { signalled = true; ready.fulfill() }
        }
        try host.start(secret: key, port: port)
        await fulfillment(of: [ready], timeout: 5)
    }
}
