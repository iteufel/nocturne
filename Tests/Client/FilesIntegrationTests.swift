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
        let observation = model.filesIntegration.$locationName.compactMap { $0 }.first().sink { name in
            XCTAssertEqual(name, invitation.name); registered.fulfill()
        }
        defer { observation.cancel(); model.server.disconnect() }
        await model.pairScannedServer(invitation.url.absoluteString)
        XCTAssertEqual(model.server.state, .connected, model.error ?? "Pairing failed")
        await fulfillment(of: [registered], timeout: 15)
        let saved = try XCTUnwrap(SecureStore.read(FilesProviderAccount.keychainAccount))
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
        XCTAssertEqual(domains.map(\.identifier.rawValue), [account.domainIdentifier])

        let stale = try account.invitation.replacingAddress(host: "192.0.2.123", port: 1)
        try SecureStore.write(JSONEncoder().encode(stale), account: "server")
        model.server.disconnect()
        await model.reconnectServer()
        XCTAssertEqual(model.server.state, .connected, model.error ?? "Reconnection failed")
        let refreshed = try JSONDecoder().decode(FilesProviderAccount.self,
            from: XCTUnwrap(SecureStore.read(FilesProviderAccount.keychainAccount)))
        XCTAssertEqual(refreshed.invitation.host, model.server.connectedInvitation?.host)
        XCTAssertEqual(refreshed.invitation.port, model.server.connectedInvitation?.port)
        XCTAssertNotEqual(refreshed.invitation.host, stale.host)
        XCTAssertEqual(refreshed.domainIdentifier, account.domainIdentifier)
        XCTAssertNil(refreshed.invitation.enrollmentToken)

        // The Settings refresh must also retry Files registration when already connected.
        try model.filesIntegration.forget()
        await model.reconnectServer()
        XCTAssertNotNil(try SecureStore.read(FilesProviderAccount.keychainAccount))
    }
}
