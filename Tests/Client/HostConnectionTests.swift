import XCTest
import Network
import SwiftUI
import NocturneKit
@testable import Nocturne

@MainActor
final class HostConnectionTests: XCTestCase {
    private var savedPairings: Data?

    override func setUpWithError() throws {
        savedPairings = try SecureStore.read(PairedServerList.keychainAccount)
    }
    override func tearDownWithError() throws {
        if let savedPairings { try SecureStore.write(savedPairings, account: PairedServerList.keychainAccount) }
        else { try SecureStore.delete(PairedServerList.keychainAccount) }
    }
    private func model(for invitation: PairingInvitation, linked: Bool, additionalInvitations: [PairingInvitation] = []) throws -> (ClientModel, TestStreamingService) {
        var list = PairedServerList(); list.pair(invitation)
        for other in additionalInvitations { list.pair(other) }
        list.activate(WorkspaceIdentity.fingerprint(invitation.secret))
        if linked { _ = list.link(streamingHostID: "test-video", to: list.activeID!) }
        try SecureStore.write(JSONEncoder().encode(list), account: PairedServerList.keychainAccount)
        let engine = TestStreamingService(), model = ClientModel(engine: engine)
        model.hosts = [engine.host]
        return (model, engine)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition())
    }
    func testPairingURLSchemeIsRegistered() {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        XCTAssertTrue(types?.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("nocturne") == true } == true)
    }
    func testOpenedPairingLinkWaitsForConfirmationAndPreservesTheCurrentHost() async throws {
        let workspace = try TestWorkspace(); try await workspace.start()
        let (model, engine) = try model(for: workspace.address, linked: true)
        defer { model.suspend(); workspace.stop() }
        await model.reconnectServer()
        try await waitUntil { engine.approved }
        let invitation = try PairingInvitation(host: "other.local", name: "Other Mac", secret: SecureStore.randomKey(), enrollmentToken: SecureStore.randomKey())
        XCTAssertTrue(model.receivePairingLink(invitation.url))
        XCTAssertTrue(model.showAdd)
        XCTAssertEqual(model.pairingLink, invitation.url.absoluteString)
        XCTAssertEqual(model.server.state, .connected)
        XCTAssertEqual(model.server.connectedInvitation?.secret, workspace.address.secret)
        XCTAssertEqual(model.pairedServers.servers.count, 1)
        XCTAssertEqual(model.pairedServers.active?.invitation.secret, workspace.address.secret)
    }
    func testInvalidPastedLinkDoesNotDisconnectTheCurrentHost() async throws {
        let workspace = try TestWorkspace(); try await workspace.start()
        let (model, engine) = try model(for: workspace.address, linked: true)
        defer { model.suspend(); workspace.stop() }
        await model.reconnectServer()
        try await waitUntil { engine.approved }
        await model.pairServer("invalid pairing link")
        XCTAssertEqual(model.error, NocturneError.invalidInvitation.localizedDescription)
        XCTAssertEqual(model.server.state, .connected)
        XCTAssertEqual(model.pairedServers.servers.count, 1)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.receivePairingLink(URL(string: "nocturne://pair?key=invalid")!))
        XCTAssertTrue(model.pairingLink.isEmpty)
        XCTAssertFalse(model.showAdd)
    }
    func testPairingLinkCannotInterruptADesktopStream() throws {
        let invitation = try PairingInvitation(host: "mac.local", name: "Mac", secret: SecureStore.randomKey())
        let (model, engine) = try model(for: invitation, linked: true)
        defer { model.suspend() }
        model.session = StreamSession(host: engine.host, app: StreamingApp(["id": "desktop", "name": "Desktop"]), preferences: model.preferences)
        XCTAssertFalse(model.receivePairingLink(invitation.url))
        XCTAssertFalse(model.showAdd)
        XCTAssertTrue(model.pairingLink.isEmpty)
        XCTAssertNotNil(model.session)
    }
    func testReconnectRepairsInterruptedVideoPairingWithoutAnotherQRScan() async throws {
        let workspace = try TestWorkspace(); try await workspace.start()
        let (model, engine) = try model(for: workspace.address, linked: false)
        defer { model.suspend(); workspace.stop() }
        await model.reconnectServer()
        XCTAssertEqual(model.server.state, .connected)
        try await waitUntil { engine.selections > 0 }
        XCTAssertEqual(engine.resolutions, 1, "A saved workspace without video approval must resume screen-sharing setup")
        XCTAssertEqual(model.pairedServers.active?.streamingHostID, engine.host.id)
        XCTAssertFalse(model.showAdd, "Saved credentials should repair streaming without rescanning")
    }
    func testSelectingSavedHostReconnectsBeforeRequestingVideoApproval() async throws {
        let workspace = try TestWorkspace(); try await workspace.start()
        let (model, engine) = try model(for: workspace.address, linked: true)
        defer { model.suspend(); workspace.stop() }
        model.select(engine.host)
        try await waitUntil { model.showLibrary || model.showAdd }
        XCTAssertFalse(model.showAdd, "Selecting a saved host must reconnect its workspace instead of asking to pair again")
        XCTAssertTrue(model.showLibrary)
        XCTAssertEqual(engine.unauthenticatedSelections, 0, "Video setup must wait for the selected workspace to authenticate")
    }
    func testWorkspaceConnectionDoesNotClaimThatUnfinishedScreenSharingIsReady() async throws {
        let workspace = try TestWorkspace(); try await workspace.start()
        let (model, engine) = try model(for: workspace.address, linked: false)
        defer { model.suspend(); workspace.stop() }
        engine.deferResolution = true
        await model.reconnectServer()
        XCTAssertEqual(model.server.state, .connected)
        XCTAssertEqual(model.hostStatus(try XCTUnwrap(model.pairedServers.active)), "Connecting…")
        engine.finishResolution()
        try await waitUntil { engine.approved }
        XCTAssertEqual(model.hostStatus(try XCTUnwrap(model.pairedServers.active)), "Screen sharing ready")
        XCTAssertFalse(model.showLibrary, "Background recovery must not interrupt the user with a sheet")
    }
    func testFailedVideoSetupCanRetryUsingTheAlreadyConnectedWorkspace() async throws {
        let workspace = try TestWorkspace(); try await workspace.start()
        let (model, engine) = try model(for: workspace.address, linked: false)
        defer { model.suspend(); workspace.stop() }
        engine.resolutionError = "Screen capture is unavailable"
        await model.reconnectServer()
        let paired = try XCTUnwrap(model.pairedServers.active)
        XCTAssertEqual(model.server.state, .connected)
        XCTAssertEqual(model.hostStatus(paired), "Screen sharing needs attention")
        XCTAssertEqual(model.hostErrors[paired.id], engine.resolutionError)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.showAdd)
        engine.resolutionError = nil
        model.openHost(paired.id)
        try await waitUntil { model.showLibrary }
        XCTAssertEqual(engine.resolutions, 2)
        XCTAssertEqual(model.pairedServers.servers.count, 1)
        XCTAssertNil(model.hostErrors[paired.id])
        XCTAssertTrue(engine.approved)
    }
    func testCancellingSetupIgnoresItsLateDiscoveryCallback() async throws {
        let workspace = try TestWorkspace(); try await workspace.start()
        let (model, engine) = try model(for: workspace.address, linked: false)
        defer { model.suspend(); workspace.stop() }
        engine.deferResolution = true
        await model.reconnectServer()
        XCTAssertTrue(model.busy)
        model.cancelHostConnection()
        engine.finishResolution()
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.pairedServers.active?.streamingHostID)
        XCTAssertEqual(engine.selections, 0)
        XCTAssertFalse(model.showLibrary)
    }
    func testSelectingAnotherSavedHostAuthenticatesThatHostBeforeVideoSetup() async throws {
        let first = try TestWorkspace(), second = try TestWorkspace()
        try await first.start(); try await second.start()
        let (model, engine) = try model(for: first.address, linked: false)
        defer { model.suspend(); first.stop(); second.stop() }
        await model.pairServer(" \n" + second.address.url.absoluteString + "\n")
        try await waitUntil { engine.approved }
        let secondID = try XCTUnwrap(model.pairedServers.activeID)
        model.showLibrary = false
        engine.hostID = "first-video"
        model.openHost(WorkspaceIdentity.fingerprint(first.address.secret))
        try await waitUntil { model.showLibrary }
        XCTAssertEqual(model.server.connectedInvitation?.secret, first.address.secret)
        XCTAssertNotEqual(model.pairedServers.activeID, secondID)
        XCTAssertEqual(model.pairedServers.servers.count, 2)
        XCTAssertEqual(engine.unauthenticatedSelections, 0)
    }
    func testDesktopActionStartsTheDesktopAfterCompletingSetup() async throws {
        let workspace = try TestWorkspace(); try await workspace.start()
        let (model, engine) = try model(for: workspace.address, linked: false)
        defer { model.suspend(); workspace.stop() }
        model.openHost(try XCTUnwrap(model.pairedServers.activeID), desktop: true)
        try await waitUntil { model.session != nil }
        XCTAssertEqual(model.session?.app.name, "Desktop")
        XCTAssertTrue(engine.approved)
        XCTAssertFalse(model.showLibrary)
    }

    func testReconnectActionRefreshesTheWorkspaceEvenWhenAlreadyConnected() async throws {
        let workspace = try TestWorkspace(); try await workspace.start()
        let (model, engine) = try model(for: workspace.address, linked: false)
        defer { model.suspend(); workspace.stop() }
        await model.reconnectServer()
        try await waitUntil { engine.approved }
        XCTAssertEqual(workspace.acceptedConnections, 1)
        model.reconnectHost(try XCTUnwrap(model.pairedServers.activeID))
        try await waitUntil { workspace.acceptedConnections == 2 && model.server.state == .connected }
        XCTAssertFalse(model.showAdd)
    }
    func testStreamStartupFailureMarksOnlyItsHostAsNeedingAttention() async throws {
        let workspace = try TestWorkspace(); try await workspace.start()
        let (model, engine) = try model(for: workspace.address, linked: true)
        defer { model.suspend(); workspace.stop() }
        let paired = try XCTUnwrap(model.pairedServers.active)
        model.session = StreamSession(host: engine.host, app: StreamingApp(["id": "desktop", "name": "Desktop"]), preferences: model.preferences)
        let controller = UIViewController(); model.session?.controller = controller
        engine.streamFailed?(controller, "Failed to initialize video capture/encoding")
        XCTAssertNil(model.session)
        XCTAssertEqual(model.hostErrors[paired.id], "Failed to initialize video capture/encoding")
        XCTAssertEqual(model.hostStatus(paired), "Screen sharing needs attention")
        XCTAssertFalse(model.showAdd)
    }
    func testHostManagementPresentation() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_HOST_UI_REVIEW"] == "1" else {
            throw XCTSkip("Opt-in rendered host-management review")
        }
        let workspace = try TestWorkspace(); try await workspace.start()
        let office = try PairingInvitation(host: "office.local", name: "Office PC", secret: SecureStore.randomKey())
        let (model, engine) = try model(for: workspace.address, linked: false, additionalInvitations: [office])
        defer { model.suspend(); workspace.stop() }
        await model.reconnectServer()
        try await waitUntil { engine.approved }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("HostReview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func capture<V: View>(_ name: String, _ view: V, style: UIUserInterfaceStyle = .light) async throws {
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(rootView: view.tint(MoonStyle.accent))
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 500_000_000)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await capture("computers", ClientRootView(model: model))
        model.page = .settings
        try await capture("settings", ClientRootView(model: model))
        try await capture("paired-hosts", NavigationStack { PairedHostsView(model: model) })
        try await capture("host-details", NavigationStack { PairedHostDetailView(model: model, hostID: model.pairedServers.activeID!) })
        try await capture("paired-hosts-dark", NavigationStack { PairedHostsView(model: model) }, style: .dark)
        engine.approved = false; engine.resolutionError = "Screen sharing could not start. Check Nocturne Server on your host, then try again."
        model.openHost(model.pairedServers.activeID!)
        try await waitUntil { model.hostErrors[model.pairedServers.activeID!] != nil }
        model.error = nil; model.page = .computers
        try await capture("screen-sharing-retry", ClientRootView(model: model))
    }

}

/// Real TLS and device-signature exchange, with only the video engine replaced.
@MainActor
private final class TestWorkspace {
    let invitation: PairingInvitation
    private let listener: NWListener
    private var channels: [SecureChannel] = []
    private(set) var acceptedConnections = 0
    init() throws {
        let secret = try SecureStore.randomKey()
        listener = try NWListener(using: SecureTransport.parameters(secret: secret), on: .any)
        invitation = try PairingInvitation(host: "127.0.0.1", port: 1, name: "Studio", secret: secret)
    }
    private(set) var port: UInt16 = 1
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 1
                    self?.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
                }
            }
            listener.start(queue: .main)
        }
    }
    var address: PairingInvitation { try! invitation.replacingAddress(host: "127.0.0.1", port: port) }
    private func accept(_ connection: NWConnection) {
        acceptedConnections += 1
        let channel = SecureChannel(connection: connection), challenge = Data(repeating: 7, count: 32)
        channels.append(channel)
        channel.onPacket = { [weak channel] packet in
            guard let channel else { return }
            var reply = packet.reply()
            do {
                switch packet.operation {
                case .hello: reply.version = WorkspaceProtocol.version; reply.data = challenge
                case .authenticate:
                    _ = try WorkspaceIdentity.verify(certificate: XCTUnwrap(packet.certificate), signature: XCTUnwrap(packet.signature), challenge: channel.boundChallenge(challenge))
                    reply.name = "Studio"; reply.capabilities = ["streaming"]
                case .pairStream, .ping: break
                default: reply.error = "Unexpected request"
                }
            } catch { reply.error = error.localizedDescription }
            channel.send(reply)
        }
        channel.start()
    }
    func stop() { listener.cancel(); channels.forEach { $0.cancel() }; channels = [] }
}

private final class TestStreamingService: NocturneStreamingService {
    var resolutions = 0, selections = 0, unauthenticatedSelections = 0
    var hostID = "test-video"
    var approved = false
    var deferResolution = false
    var resolutionError: String?
    private var pendingAddress: String?
    var host: StreamingHost { StreamingHost(["id": hostID, "name": "Studio", "address": "127.0.0.1", "online": true, "paired": approved]) }
    override func start() {}
    override func pause() {}
    override func cancelPairing() {}
    override func clearTemporaryAddress(_ hostID: String) {}
    override func updateHostAddress(_ hostID: String, address: String) {}
    override func addAddress(_ address: String) {
        resolutions += 1
        if let resolutionError { failed?(resolutionError); return }
        pendingAddress = address
        if !deferResolution { finishResolution() }
    }
    func finishResolution() {
        guard let address = pendingAddress else { return }
        pendingAddress = nil
        hostsChanged?([["id": host.id, "name": host.name, "address": address, "online": true, "paired": approved]])
        addressDiscovered?(host.id, address)
    }
    override func selectHost(_ hostID: String) {
        selections += 1
        guard canPairHost?(hostID) == true else {
            unauthenticatedSelections += 1; pairingRequired?(); return
        }
        authorizePairing?(hostID, "1234") { [weak self] authorized in
            guard let self else { return }
            guard authorized else { self.failed?("Approval failed"); return }
            self.approved = true
            self.hostsChanged?([["id": hostID, "name": "Studio", "address": "127.0.0.1", "online": true, "paired": true]])
            self.appsChanged?(hostID, [["id": "desktop", "name": "Desktop"]])
            self.pairingFinished?()
        }
    }
}
