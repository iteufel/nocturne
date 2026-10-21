import XCTest
import Security
import Network
import NocturneKit
@testable import NocturneHostKit

struct TestDeviceIdentity {
    let pem: String
    let certificate: Data
    let key: SecKey
    var id: String { WorkspaceIdentity.fingerprint(certificate) }
    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", root.appendingPathComponent("key.pem").path,
                             "-out", root.appendingPathComponent("cert.pem").path, "-days", "1", "-subj", "/CN=Nocturne test device"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NocturneError.invalidFrame }
        func der(_ pem: String) throws -> Data {
            try XCTUnwrap(Data(base64Encoded: pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()))
        }
        pem = try String(contentsOf: root.appendingPathComponent("cert.pem")); certificate = try der(pem)
        let conversion = Process(); conversion.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        conversion.arguments = ["rsa", "-in", root.appendingPathComponent("key.pem").path, "-outform", "DER", "-out", root.appendingPathComponent("key.der").path]
        conversion.standardOutput = FileHandle.nullDevice; conversion.standardError = FileHandle.nullDevice
        try conversion.run(); conversion.waitUntilExit()
        guard conversion.terminationStatus == 0 else { throw NocturneError.invalidFrame }
        let privateKey = try Data(contentsOf: root.appendingPathComponent("key.der"))
        key = try XCTUnwrap(SecKeyCreateWithData(privateKey as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil))
    }
    func sign(_ message: Data) throws -> Data {
        try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)) as Data
    }
    func identity(name: String = "iPad") -> WorkspaceIdentity { .init(certificate: certificate, name: name, sign: sign) }
}

final class DeviceIdentityTests: XCTestCase {
    func testCertificateProofRejectsReplayAndDifferentKey() throws {
        let first = try TestDeviceIdentity(), second = try TestDeviceIdentity()
        let challenge = try SecureStore.randomKey()
        let signature = try first.sign(WorkspaceIdentity.message(for: challenge))
        XCTAssertEqual(try WorkspaceIdentity.verify(certificate: first.certificate, signature: signature, challenge: challenge), first.id)
        XCTAssertThrowsError(try WorkspaceIdentity.verify(certificate: first.certificate, signature: signature, challenge: SecureStore.randomKey()))
        XCTAssertThrowsError(try WorkspaceIdentity.verify(certificate: second.certificate, signature: signature, challenge: challenge))
    }
    func testInvitationIsSingleUseAndInterruptedRemovalPersists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("devices.json")
        let store = try WorkspaceDeviceStore(url: url)
        let token = try store.createInvitation()
        _ = try store.authorize(id: "a", name: "iPad", token: token)
        XCTAssertThrowsError(try store.authorize(id: "b", name: "iPad", token: token))
        _ = try store.authorize(id: "b", name: "iPad", token: store.createInvitation())
        try store.remove("a")
        let reloaded = try WorkspaceDeviceStore(url: url)
        XCTAssertThrowsError(try reloaded.authorize(id: "a", name: "iPad", token: token))
        XCTAssertNoThrow(try reloaded.authorize(id: "b", name: "iPad", token: nil))
        try reloaded.finishRemoval("a")
        XCTAssertThrowsError(try reloaded.authorize(id: "a", name: "iPad", token: token))
        XCTAssertNoThrow(try reloaded.authorize(id: "a", name: "iPad", token: reloaded.createInvitation()))
        XCTAssertEqual(reloaded.devices.count, 2)
    }
    func testDeviceListMergesByCertificateAndKeepsDuplicateNamesSeparate() {
        let streams = [StreamDevice(id: "video-a", name: "iPad", fingerprint: "a", enabled: true),
                       StreamDevice(id: "video-b", name: "iPad", fingerprint: "b", enabled: true)]
        let workspaces = [WorkspaceDevice(id: "a", name: "iPad", lastSeen: Date())]
        let connections = [WorkspaceDeviceConnection(id: "a", name: "iPad", address: "192.0.2.1")]
        let devices = ServerDevice.list(streams: streams, workspaces: workspaces, connections: connections)
        XCTAssertEqual(devices.map(\.id), ["a", "b"])
        XCTAssertTrue(devices[0].connected); XCTAssertTrue(devices[0].workspace)
        XCTAssertEqual(devices[0].streamIDs, ["video-a"])
        XCTAssertFalse(devices[1].connected); XCTAssertFalse(devices[1].workspace)
    }
}

@MainActor
final class DeviceRevocationIntegrationTests: XCTestCase {
    func testVideoPairingRequiresInvitationEnrollmentAndAllowsRegisteredReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Mac", devices: store)
        let identity = try TestDeviceIdentity(), client = WorkspaceConnection(identity: identity.identity())
        defer { client.disconnect(); server.stop() }
        let secret = try SecureStore.randomKey(), port = UInt16.random(in: 52_000..<60_000)
        var approvals = 0
        server.pairStream = { challenge, name, address, id, completion in
            Task { @MainActor in
                XCTAssertEqual(challenge, "1234"); XCTAssertEqual(id, identity.id)
                approvals += 1; completion(nil)
            }
        }
        try await start(server, secret: secret, port: port, stage: "QR pairing server")
        let transportOnly = try PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: secret)
        do { try await client.connect(transportOnly); XCTFail("A transport key enrolled a device without QR authorization") } catch {}
        XCTAssertEqual(approvals, 0); XCTAssertTrue(store.devices.isEmpty)
        let invitation = try PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: secret, enrollmentToken: store.createInvitation())
        // A copied link carries exactly the QR invitation and consumes the same token.
        let copied = try PairingInvitation(pairingLink: invitation.url.absoluteString)
        try await client.connect(copied)
        var packet = Packet(.pairStream); packet.data = Data("1234".utf8)
        _ = try await client.request(packet)
        XCTAssertEqual(approvals, 1)
        client.disconnect()
        try await client.connect(transportOnly)
        _ = try await client.request(packet)
        XCTAssertEqual(approvals, 2)
        let unknown = WorkspaceConnection(identity: try TestDeviceIdentity().identity())
        defer { unknown.disconnect() }
        do { try await unknown.connect(invitation); XCTFail("A consumed QR code enrolled another device") } catch {}
        XCTAssertEqual(approvals, 2)
    }
    func testRemovingOneDeviceClosesItsSessionsAndPreservesOtherDeviceAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("devices.json")
        let store = try WorkspaceDeviceStore(url: storeURL)
        let first = try TestDeviceIdentity(), second = try TestDeviceIdentity()
        let secret = try SecureStore.randomKey(), port = UInt16.random(in: 52_000..<60_000)
        var server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Mac", devices: store, permissions: .init(terminal: true, files: true))
        defer { server.stop() }
        try await start(server, secret: secret, port: port, stage: "initial start")
        let a = WorkspaceConnection(identity: first.identity()), a2 = WorkspaceConnection(identity: first.identity()), b = WorkspaceConnection(identity: second.identity())
        defer { a.disconnect(); a2.disconnect(); b.disconnect() }
        let firstLink = try PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: secret, enrollmentToken: store.createInvitation())
        try await a.connect(firstLink); try await a2.connect(firstLink)
        let secondLink = try PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: secret, enrollmentToken: store.createInvitation())
        try await b.connect(secondLink)
        try await a.openTerminal(); try await b.openTerminal()
        var upload = Packet(.uploadBegin); upload.path = "partial.txt"; upload.size = 100
        _ = try await a.request(upload)
        let removed = expectation(description: "Only second identity remains connected")
        var signalled = false
        server.onDevices = { devices in
            if devices.map(\.id) == [second.id], !signalled { signalled = true; removed.fulfill() }
        }
        try store.remove(first.id); server.disconnectDevice(first.id); try store.finishRemoval(first.id)
        await fulfillment(of: [removed], timeout: 5)
        // The surviving device retains its original connection and PTY.
        XCTAssertEqual(b.state, .connected); XCTAssertNotNil(b.terminalID)
        _ = try await b.request(Packet(.ping)); try await b.terminalInput(Data("printf alive\\n\r".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("shared").path).isEmpty)
        do { _ = try await a.request(Packet(.ping)); XCTFail("Revoked connection still works") } catch {}
        do { _ = try await a2.request(Packet(.ping)); XCTFail("Second session of revoked identity still works") } catch {}
        do { try await a.connect(firstLink); XCTFail("Removed device reused the old pairing link") } catch {}
        // Even an entirely new identity cannot use a consumed link and the old shared PSK.
        let impostor = WorkspaceConnection(identity: try TestDeviceIdentity().identity()); defer { impostor.disconnect() }
        do { try await impostor.connect(firstLink); XCTFail("Consumed invitation enrolled a new identity") } catch {}
        server.stop(); b.disconnect()
        let reloaded = try WorkspaceDeviceStore(url: storeURL)
        server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Mac", devices: reloaded)
        try await start(server, secret: secret, port: port, stage: "restart")
        try await b.connect(secondLink)
        do { try await a.connect(firstLink); XCTFail("Revocation did not survive restart") } catch {}
        XCTAssertEqual(b.state, .connected)
        XCTAssertEqual(reloaded.devices.map(\.id), [second.id])
    }
    private func start(_ server: WorkspaceServer, secret: Data, port: UInt16, stage: String) async throws {
        let ready = expectation(description: "Listener ready: " + stage); var signalled = false; var latestStatus = "Starting"
        server.onStatus = { status, _ in
            latestStatus = status
            if status == "Ready", !signalled { signalled = true; ready.fulfill() }
        }
        try server.start(secret: secret, port: port); await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(latestStatus, "Ready", stage)
    }
}
