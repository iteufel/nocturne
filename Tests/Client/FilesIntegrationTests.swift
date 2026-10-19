import XCTest
import Combine
import FileProvider
import NocturneKit
@testable import Nocturne

@MainActor
final class FilesIntegrationTests: XCTestCase {
    func testExportedFilesIdentityMatchesTheStreamingDevice() throws {
        let engine = NocturneStreamingService()
        let invitation = try PairingInvitation(host: "mac.local", name: "Mac", secret: SecureStore.randomKey(), enrollmentToken: SecureStore.randomKey())
        let account = try FilesProviderAccount(invitation: invitation, certificate: engine.workspaceCertificate(),
            privateKey: XCTUnwrap(engine.workspacePrivateKey()), deviceName: "Test iPad")
        XCTAssertNil(account.invitation.enrollmentToken)
        let challenge = try SecureStore.randomKey()
        let signature = try account.identity().sign(WorkspaceIdentity.message(for: challenge))
        XCTAssertEqual(try WorkspaceIdentity.verify(certificate: account.certificate, signature: signature, challenge: challenge),
            WorkspaceIdentity.fingerprint(engine.workspaceCertificate()))
    }

    /// Opt-in smoke with a running WorkspaceServer. Keeps the location available for checking Apple Files.
    func testRegisterAppleFilesFromLivePairing() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOCTURNE_FILES_TEST_INVITATION"] else {
            throw XCTSkip("Set NOCTURNE_FILES_TEST_INVITATION to a local host's private invitation JSON for the Apple Files smoke test.")
        }
        let invitation = try JSONDecoder().decode(PairingInvitation.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let model = ClientModel()
        let registered = expectation(description: "Paired Mac registered as an Apple Files location")
        let observation = model.filesIntegration.$locationNames.first { $0.contains(invitation.name) }.sink { _ in registered.fulfill() }
        defer { observation.cancel(); model.server.disconnect() }
        await model.pairScannedServer(invitation.url.absoluteString)
        XCTAssertEqual(model.server.state, .connected, model.error ?? "Pairing failed")
        await fulfillment(of: [registered], timeout: 15)
        let accountName = FilesProviderAccount.keychainAccount(domainIdentifier: FilesProviderAccount.domainIdentifier(secret: invitation.secret))
        let saved = try XCTUnwrap(SecureStore.read(accountName))
        let account = try JSONDecoder().decode(FilesProviderAccount.self, from: saved)
        XCTAssertNil(account.invitation.enrollmentToken)
        XCTAssertEqual(account.invitation.host, model.server.connectedInvitation?.host)
        XCTAssertEqual(account.invitation.port, model.server.connectedInvitation?.port)
        XCTAssertEqual(account.certificate, model.engine.workspaceCertificate())
        let domains: [NSFileProviderDomain] = try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: domains) }
            }
        }
        XCTAssertTrue(domains.map(\.identifier.rawValue).contains(account.domainIdentifier))

        let stale = try account.invitation.replacingAddress(host: "192.0.2.123", port: 1)
        var list = model.pairedServers; list.update(stale)
        try SecureStore.write(JSONEncoder().encode(list), account: PairedServerList.keychainAccount)
        model.server.disconnect()
        let restarted = ClientModel()
        defer { restarted.server.disconnect() }
        XCTAssertEqual(restarted.pairedServers.active?.invitation.host, stale.host)
        await restarted.reconnectServer()
        XCTAssertEqual(restarted.server.state, .connected, restarted.error ?? "Reconnection failed")
        XCTAssertEqual(restarted.pairedServers.active?.invitation.host, restarted.server.connectedInvitation?.host)
        let refreshed = try JSONDecoder().decode(FilesProviderAccount.self, from: XCTUnwrap(SecureStore.read(accountName)))
        XCTAssertEqual(refreshed.invitation.host, restarted.server.connectedInvitation?.host)
        XCTAssertEqual(refreshed.invitation.port, restarted.server.connectedInvitation?.port)
        XCTAssertNotEqual(refreshed.invitation.host, stale.host)
        XCTAssertEqual(refreshed.domainIdentifier, account.domainIdentifier)
        XCTAssertNil(refreshed.invitation.enrollmentToken)

        // The Settings refresh must also retry Files registration when already connected.
        try restarted.filesIntegration.forget(stale)
        XCTAssertNil(try SecureStore.read(accountName))
        await restarted.reconnectServer()
        XCTAssertNotNil(try SecureStore.read(accountName))
    }

    /// Opt-in smoke with two running WorkspaceServers, e.g. `NOCTURNE_MULTI_MAC_INVITATIONS=/tmp/a.json:/tmp/b.json`.
    func testPairTwoLiveMacsAndSwitchBetweenThem() async throws {
        guard let paths = ProcessInfo.processInfo.environment["NOCTURNE_MULTI_MAC_INVITATIONS"]?.split(separator: ":"), paths.count == 2 else {
            throw XCTSkip("Set NOCTURNE_MULTI_MAC_INVITATIONS to two private invitation JSON files from different hosts.")
        }
        let invitations = try paths.map { try JSONDecoder().decode(PairingInvitation.self, from: Data(contentsOf: URL(fileURLWithPath: String($0)))) }
        let (first, second) = (invitations[0], invitations[1])
        let firstID = WorkspaceIdentity.fingerprint(first.secret), secondID = WorkspaceIdentity.fingerprint(second.secret)
        let model = ClientModel()
        defer { model.server.disconnect() }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<150 where !condition() { try await Task.sleep(nanoseconds: 100_000_000) }
            XCTAssertTrue(condition())
        }

        await model.pairScannedServer(first.url.absoluteString)
        XCTAssertEqual(model.server.state, .connected, model.error ?? "First pairing failed")
        let shell = try await model.server.openTerminal()
        await model.pairScannedServer(second.url.absoluteString)
        XCTAssertEqual(model.server.state, .connected, model.error ?? "Second pairing failed")
        XCTAssertEqual(model.server.name, second.name)
        XCTAssertEqual(model.pairedServers.servers.map(\.id), [firstID, secondID])
        XCTAssertEqual(model.pairedServers.activeID, secondID)
        XCTAssertFalse(model.server.terminals.contains { $0.id == shell }, "Another Mac's shells must not appear")
        try await waitUntil { Set(model.filesIntegration.locationNames) == [first.name, second.name] }

        // The window socket for the inactive Mac authenticates with that Mac, not the active one.
        let window = model.server.mediaConnection(); defer { window.disconnect() }
        try await window.connect(model.appWindowInvitation(serverID: firstID), restoreTerminalSessions: false)
        XCTAssertEqual(window.name, first.name)
        window.disconnect()

        model.activateServer(firstID)
        try await waitUntil { model.server.state == .connected && model.server.name == first.name }
        XCTAssertEqual(model.server.terminals.map(\.id), [shell], "Switching back restores the first Mac's shell")
        XCTAssertEqual(ClientModel().pairedServers, model.pairedServers, "Paired Macs persist across launches")

        model.forgetServer(secondID)
        XCTAssertEqual(model.pairedServers.servers.map(\.id), [firstID])
        XCTAssertEqual(model.server.state, .connected, "Forgetting another Mac keeps the current connection")
        try await waitUntil { model.filesIntegration.locationNames == [first.name] }
        XCTAssertNil(try SecureStore.read(FilesProviderAccount.keychainAccount(domainIdentifier: FilesProviderAccount.domainIdentifier(secret: second.secret))))
        model.forgetServer()
        XCTAssertTrue(model.pairedServers.servers.isEmpty)
        XCTAssertEqual(model.server.state, .disconnected)
        try await waitUntil { model.filesIntegration.locationNames.isEmpty }
    }

    func testSingleMacPairingMigratesToThePairedMacList() throws {
        let previous = (list: try SecureStore.read(PairedServerList.keychainAccount), legacy: try SecureStore.read(PairedServerList.legacyKeychainAccount),
                        hostID: UserDefaults.standard.string(forKey: "serverHostID"))
        func restore(_ data: Data?, account: String) {
            if let data { try? SecureStore.write(data, account: account) } else { try? SecureStore.delete(account) }
        }
        defer {
            restore(previous.list, account: PairedServerList.keychainAccount)
            restore(previous.legacy, account: PairedServerList.legacyKeychainAccount)
            UserDefaults.standard.set(previous.hostID, forKey: "serverHostID")
        }
        let legacy = try PairingInvitation(host: "192.0.2.10", name: "Studio Mac", secret: SecureStore.randomKey())
        try SecureStore.delete(PairedServerList.keychainAccount)
        try SecureStore.write(JSONEncoder().encode(legacy), account: PairedServerList.legacyKeychainAccount)
        UserDefaults.standard.set("studio-video", forKey: "serverHostID")
        UserDefaults.standard.set("Studio Mac", forKey: "serverName")

        let model = ClientModel()
        XCTAssertEqual(model.pairedServers.servers.map(\.invitation), [legacy])
        XCTAssertEqual(model.pairedServers.active?.streamingHostID, "studio-video")
        XCTAssertEqual(model.savedServerName, "Studio Mac")
        XCTAssertEqual(try model.appWindowInvitation(serverID: WorkspaceIdentity.fingerprint(legacy.secret)), legacy)
        XCTAssertThrowsError(try model.appWindowInvitation(serverID: "another-mac"))
        XCTAssertNil(try SecureStore.read(PairedServerList.legacyKeychainAccount))
        XCTAssertNil(UserDefaults.standard.string(forKey: "serverHostID"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "serverName"))
        XCTAssertEqual(ClientModel().pairedServers, model.pairedServers, "Migration must run once and persist")
    }
}
