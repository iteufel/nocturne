import XCTest
import FileProvider
import Security
import Network
import NocturneKit
import NocturneHostKit
@testable import NocturneFiles

final class FilesProviderPathTests: XCTestCase {
    func testIdentifiersAndUntrustedListingsCannotEscapeSharedFolder() throws {
        for path in ["", "Projects/Résumé #1.txt", "rootContainer", "a:b/資料.txt", ".hidden"] {
            XCTAssertEqual(try FileProviderItem.path(for: FileProviderItem.identifier(for: path)), path)
        }
        for path in ["/etc/passwd", "../secret", "a/../secret", "a//b", "a/./b", "a/", "a\0b", ".nocturne-upload-secret", String(repeating: "a", count: 4_097)] {
            XCTAssertThrowsError(try FileProviderItem.path(for: FileProviderItem.identifier(for: path)), path)
        }
        XCTAssertThrowsError(try FileProviderItem.path(for: .init("path:not-base64")))
        let malicious = RemoteFile(name: "secret", path: "Other/secret", isDirectory: false, size: 4, modified: Date())
        XCTAssertThrowsError(try SharedFilePath.validate([malicious], in: "Projects"))
        let mismatched = RemoteFile(name: "../secret", path: "Projects/secret", isDirectory: false, size: 4, modified: Date())
        XCTAssertThrowsError(try SharedFilePath.validate([mismatched], in: "Projects"))
    }
}

@MainActor
final class FilesProviderIntegrationTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let server: WorkspaceServer
        let devices: WorkspaceDeviceStore
        let account: FilesProviderAccount
        let provider: HostFileProvider
        let snapshotsURL: URL
        let application: WorkspaceConnection
        func close() { provider.invalidate(); application.disconnect(); server.stop(); try? FileManager.default.removeItem(at: root) }
    }
    private func fixture(enroll: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Nocturne-Files-Test-" + UUID().uuidString)
        let devices = try WorkspaceDeviceStore(url: root.appendingPathComponent("state/devices.json"))
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Files Test Mac", devices: devices,
            permissions: .init(terminal: true, files: true))
        let ready = expectation(description: "Files test host ready")
        var announced = false
        server.onStatus = { status, _ in if status == "Ready", !announced { announced = true; ready.fulfill() } }
        let secret = try SecureStore.randomKey(), port = UInt16.random(in: 52_000..<60_000)
        try server.start(secret: secret, port: port)
        await fulfillment(of: [ready], timeout: 5)
        let device = try TestDeviceIdentity()
        let invitation = try PairingInvitation(host: "127.0.0.1", port: port, name: "Files Test Mac", secret: secret, enrollmentToken: devices.createInvitation())
        let application = WorkspaceConnection(identity: device.identity())
        if enroll { try await application.connect(invitation, restoreTerminalSessions: false); application.disconnect() }
        let privateKey = try XCTUnwrap(SecKeyCopyExternalRepresentation(device.key, nil)) as Data
        let account = try FilesProviderAccount(invitation: invitation, certificate: device.certificate, privateKey: privateKey, deviceName: "Test iPad")
        let domain = NSFileProviderDomain(identifier: .init(account.domainIdentifier), displayName: invitation.name)
        let snapshotsURL = root.appendingPathComponent("provider/snapshots.json")
        let provider = HostFileProvider(domain: domain, snapshots: FileProviderSnapshots(url: snapshotsURL)) { account }
        return Fixture(root: root, server: server, devices: devices, account: account, provider: provider,
            snapshotsURL: snapshotsURL, application: application)
    }
    private func enumerate(_ provider: HostFileProvider, container: NSFileProviderItemIdentifier = .rootContainer) async throws -> [NSFileProviderItem] {
        let enumerator = try provider.enumerator(for: container, request: NSFileProviderRequest())
        defer { enumerator.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            enumerator.enumerateItems(for: EnumerationObserver { continuation.resume(with: $0) },
                startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        }
    }
    private func download(_ provider: HostFileProvider, path: String, cancel: Bool = false) async throws -> (URL, NSFileProviderItem) {
        try await withCheckedThrowingContinuation { continuation in
            let progress = provider.fetchContents(for: FileProviderItem.identifier(for: path), version: nil, request: NSFileProviderRequest()) { url, item, error in
                if let error { continuation.resume(throwing: error) }
                else if let url, let item { continuation.resume(returning: (url, item)) }
                else { continuation.resume(throwing: NocturneError.invalidFrame) }
            }
            if cancel { progress.cancel() }
        }
    }

    func testBrowsingAndChunkedDownloadsWorkWithContainingAppDisconnected() async throws {
        let test = try await fixture(); defer { test.close() }
        let shared = test.server.folder.url
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        let payload = Data((0..<450_000).map { UInt8($0 % 251) })
        try payload.write(to: shared.appendingPathComponent("Projects/Résumé #1.txt"))
        try Data().write(to: shared.appendingPathComponent("empty.txt"))
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("escape"), withDestinationURL: test.root)
        XCTAssertEqual(test.application.state, .disconnected)
        let root = try await enumerate(test.provider)
        XCTAssertEqual(root.map(\.filename), ["Projects", "empty.txt"])
        let folder = try XCTUnwrap(root.first)
        XCTAssertEqual(folder.capabilities?.contains(.allowsContentEnumerating), true)
        XCTAssertEqual(folder.capabilities?.contains(.allowsAddingSubItems), false)
        let children = try await enumerate(test.provider, container: folder.itemIdentifier)
        XCTAssertEqual(children.map(\.filename), ["Résumé #1.txt"])
        let result = try await download(test.provider, path: "Projects/Résumé #1.txt")
        defer { try? FileManager.default.removeItem(at: result.0.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: result.0), payload)
        XCTAssertEqual(result.1.capabilities?.contains(.allowsWriting), false)
        let empty = try await download(test.provider, path: "empty.txt")
        defer { try? FileManager.default.removeItem(at: empty.0.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: empty.0), Data())
        try await test.application.connect(test.account.invitation, restoreTerminalSessions: false)
        let terminals = try await test.application.request(Packet(.terminalList))
        XCTAssertEqual(terminals.terminals, [], "Files must not restore or open terminal sessions")
    }
    func testFilesRediscoversPairedHostWithStaleAddressWhileAppIsDisconnected() async throws {
        let test = try await fixture(); defer { test.close() }
        let payload = Data("Shared files follow the paired Mac to its new address.".utf8)
        try payload.write(to: test.server.folder.url.appendingPathComponent("moved.txt"))
        let invitation = try test.account.invitation.replacingAddress(host: "192.0.2.123", port: 1)
        let stale = try FilesProviderAccount(invitation: invitation, certificate: test.account.certificate,
            privateKey: test.account.privateKey, deviceName: test.account.deviceName)
        let provider = HostFileProvider(domain: test.provider.domain, snapshots: FileProviderSnapshots(url: test.snapshotsURL)) { stale }
        defer { provider.invalidate() }
        XCTAssertEqual(test.application.state, .disconnected)
        let items = try await enumerate(provider)
        XCTAssertEqual(items.map(\.filename), ["moved.txt"])
        let result = try await download(provider, path: "moved.txt")
        defer { try? FileManager.default.removeItem(at: result.0.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: result.0), payload)
        XCTAssertEqual(test.devices.devices.count, 1, "Address changes must preserve the existing enrollment")
    }
    func testFilesCannotEnrollAnUnpairedDeviceEvenWithAValidQRInvitation() async throws {
        let test = try await fixture(enroll: false); defer { test.close() }
        XCTAssertNil(test.account.invitation.enrollmentToken)
        do { _ = try await enumerate(test.provider); XCTFail("Files enrolled an unpaired identity") }
        catch { XCTAssertEqual((error as NSError).code, NSFileProviderError.notAuthenticated.rawValue) }
        XCTAssertTrue(test.devices.devices.isEmpty)
    }
    func testPermissionRevocationDomainMismatchAndMissingItemsFailClosed() async throws {
        let test = try await fixture(); defer { test.close() }
        let mismatch = HostFileProvider(domain: NSFileProviderDomain(identifier: .init("different-mac"), displayName: "Other Mac"),
            snapshots: FileProviderSnapshots(url: test.root.appendingPathComponent("other.json"))) { test.account }
        defer { mismatch.invalidate() }
        do { _ = try await enumerate(mismatch); XCTFail("A location used another host's credentials") }
        catch { XCTAssertEqual((error as NSError).code, NSFileProviderError.notAuthenticated.rawValue) }
        do { _ = try await download(test.provider, path: "missing.txt"); XCTFail("Missing file was returned") }
        catch { XCTAssertEqual((error as NSError).code, NSFileProviderError.noSuchItem.rawValue) }
        test.server.updatePermissions(.init(files: false))
        do { _ = try await enumerate(test.provider); XCTFail("Revoked sharing remained readable") }
        catch { XCTAssertEqual((error as NSError).code, NSFileReadNoPermissionError) }
    }
    func testChangeEnumerationRetainsAnchorsAcrossExtensionRestartAndRemovesDeletedItems() async throws {
        let test = try await fixture(); defer { test.close() }
        let shared = test.server.folder.url
        try Data("before".utf8).write(to: shared.appendingPathComponent("change.txt"))
        try Data("gone".utf8).write(to: shared.appendingPathComponent("delete.txt"))
        _ = try await enumerate(test.provider)
        let enumerator = try XCTUnwrap(test.provider.enumerator(for: .rootContainer, request: NSFileProviderRequest()) as? FileProviderEnumerator)
        defer { enumerator.invalidate() }
        let anchor: NSFileProviderSyncAnchor? = await withCheckedContinuation { continuation in
            enumerator.currentSyncAnchor { continuation.resume(returning: $0) }
        }
        try FileManager.default.removeItem(at: shared.appendingPathComponent("delete.txt"))
        try Data("after!".utf8).write(to: shared.appendingPathComponent("change.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: shared.appendingPathComponent("change.txt").path)
        try Data("new".utf8).write(to: shared.appendingPathComponent("new.txt"))
        let restarted = HostFileProvider(domain: test.provider.domain, snapshots: FileProviderSnapshots(url: test.snapshotsURL)) { test.account }
        defer { restarted.invalidate() }
        let changes = try XCTUnwrap(restarted.enumerator(for: .rootContainer, request: NSFileProviderRequest()) as? FileProviderEnumerator)
        defer { changes.invalidate() }
        let savedAnchor = try XCTUnwrap(anchor)
        let result: ChangeObserver.Result = try await withCheckedThrowingContinuation { continuation in
            changes.enumerateChanges(for: ChangeObserver { continuation.resume(with: $0) }, from: savedAnchor)
        }
        XCTAssertEqual(Set(result.updated.map(\.filename)), ["change.txt", "new.txt"])
        XCTAssertEqual(result.deleted, [FileProviderItem.identifier(for: "delete.txt")])
        XCTAssertNotEqual(result.anchor, anchor)
    }
    func testCancelledDownloadCompletesWithCancellation() async throws {
        let test = try await fixture(); defer { test.close() }
        try Data(repeating: 0x41, count: 450_000).write(to: test.server.folder.url.appendingPathComponent("cancel.bin"))
        do { _ = try await download(test.provider, path: "cancel.bin", cancel: true); XCTFail("A cancelled download succeeded") }
        catch { XCTAssertEqual((error as NSError).code, NSUserCancelledError) }
    }
    func testSingleDocumentEnumerationReturnsTheWatchedFile() async throws {
        let test = try await fixture(); defer { test.close() }
        try Data("watch this file".utf8).write(to: test.server.folder.url.appendingPathComponent("watch.txt"))
        let items = try await enumerate(test.provider, container: FileProviderItem.identifier(for: "watch.txt"))
        XCTAssertEqual(items.map(\.filename), ["watch.txt"])
        let workingSet = try await enumerate(test.provider, container: .workingSet)
        XCTAssertEqual(workingSet.map(\.filename), ["watch.txt"])
    }
    func testCancelledTLSHandshakeDoesNotWaitForTransportReadiness() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "Stalled TLS listener ready")
        let accepted = expectation(description: "TLS connection accepted")
        var stalled: NWConnection?
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { stalled = $0; accepted.fulfill() }
        listener.start(queue: .main)
        defer { listener.cancel(); stalled?.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let connection = WorkspaceConnection(identity: try TestDeviceIdentity().identity())
        defer { connection.disconnect() }
        let invitation = try PairingInvitation(host: "127.0.0.1", port: XCTUnwrap(listener.port).rawValue, name: "Stalled Mac", secret: SecureStore.randomKey())
        let work = Task { try await connection.connect(invitation, restoreTerminalSessions: false) }
        await fulfillment(of: [accepted], timeout: 5)
        work.cancel()
        let ended = expectation(description: "Cancelled handshake ended promptly")
        Task { do { try await work.value; XCTFail("Cancelled handshake succeeded") } catch {}; ended.fulfill() }
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(connection.state, .disconnected)
    }
}

private final class EnumerationObserver: NSObject, NSFileProviderEnumerationObserver {
    private var items: [NSFileProviderItem] = []
    private let completion: (Swift.Result<[NSFileProviderItem], Error>) -> Void
    init(completion: @escaping (Swift.Result<[NSFileProviderItem], Error>) -> Void) { self.completion = completion }
    func didEnumerate(_ updatedItems: [NSFileProviderItem]) { items += updatedItems }
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) { completion(.success(items)) }
    func finishEnumeratingWithError(_ error: Error) { completion(.failure(error)) }
}

private final class ChangeObserver: NSObject, NSFileProviderChangeObserver {
    struct Result {
        let updated: [NSFileProviderItem]
        let deleted: [NSFileProviderItemIdentifier]
        let anchor: NSFileProviderSyncAnchor
    }
    private var updated: [NSFileProviderItem] = []
    private var deleted: [NSFileProviderItemIdentifier] = []
    private let completion: (Swift.Result<Result, Error>) -> Void
    init(completion: @escaping (Swift.Result<Result, Error>) -> Void) { self.completion = completion }
    func didUpdate(_ updatedItems: [NSFileProviderItem]) { updated += updatedItems }
    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) { deleted += deletedItemIdentifiers }
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) { completion(.success(Result(updated: updated, deleted: deleted, anchor: anchor))) }
    func finishEnumeratingWithError(_ error: Error) { completion(.failure(error)) }
}
