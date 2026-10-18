import SwiftUI
import GameController
import NocturneKit

struct StreamingHost: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let online: Bool
    let paired: Bool
    init(_ item: [AnyHashable: Any]) {
        id = item["id"] as? String ?? ""; name = item["name"] as? String ?? "Computer"
        address = item["address"] as? String ?? ""; online = item["online"] as? Bool ?? false; paired = item["paired"] as? Bool ?? false
    }
}
struct StreamingApp: Identifiable {
    let id: String
    let name: String
    let hdr: Bool
    init(_ item: [AnyHashable: Any]) {
        id = item["id"] as? String ?? ""; name = item["name"] as? String ?? "App"; hdr = item["hdr"] as? Bool ?? false
    }
    var icon: String { name.lowercased().contains("desktop") ? "macwindow" : "gamecontroller" }
}
@MainActor
final class StreamSession: ObservableObject, Identifiable {
    let id = UUID()
    let host: StreamingHost
    let app: StreamingApp
    @Published var preferences: StreamPreferences
    @Published var controller: UIViewController?
    @Published var status = "Preparing your display…"
    @Published var size: StreamDisplaySize?
    var desiredSize: StreamDisplaySize?
    var reconfigure: Task<Void, Never>?
    var heartbeat: Task<Void, Never>?
    var hasDisplayLease = false
    init(host: StreamingHost, app: StreamingApp, preferences: StreamPreferences) {
        self.host = host; self.app = app; self.preferences = preferences
    }
}
enum ClientPage: String, CaseIterable, Identifiable {
    case computers = "Computers", terminal = "Terminal", files = "Files", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .computers: return "desktopcomputer"; case .terminal: return "terminal"; case .files: return "folder"; case .settings: return "slider.horizontal.3" }
    }
}

@MainActor
final class ClientModel: ObservableObject {
    static let shared = ClientModel()
    let engine = NocturneStreamingService()
    let server: WorkspaceConnection
    @Published var hosts: [StreamingHost] = []
    @Published var apps: [StreamingApp] = []
    @Published var selectedHost: StreamingHost?
    @Published var page = ClientPage.computers
    @Published var busy = false
    @Published var error: String?
    @Published var showAdd = false
    @Published var preferServer = false
    @Published var showLibrary = false
    @Published var session: StreamSession?
    @Published var controllers: [String] = []
    @Published var keyboardConnected = false
    @Published var mouseConnected = false
    @Published var savedServerName: String?
    @Published var preferences: StreamPreferences {
        didSet { if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "streamPreferences") } }
    }
    private var reconnecting = false
    private var pendingStreamAddress: String?
    private var linkedHostID = UserDefaults.standard.string(forKey: "serverHostID")
    private var pendingStream: Task<Void, Never>?
    private var closingStream: Task<Void, Never>?
    private var serverPairingGeneration = UUID()
    private var inputObservers: [NSObjectProtocol] = []
    init() {
        let streamingEngine = engine
        server = WorkspaceConnection(identity: WorkspaceIdentity(certificate: streamingEngine.workspaceCertificate(),
            name: UIDevice.current.name) { streamingEngine.signWorkspaceChallenge($0) })
        preferences = UserDefaults.standard.data(forKey: "streamPreferences").flatMap { try? JSONDecoder().decode(StreamPreferences.self, from: $0) } ?? .init()
        savedServerName = UserDefaults.standard.string(forKey: "serverName")
        engine.hostsChanged = { [weak self] hosts in self?.hosts = hosts.map(StreamingHost.init) }
        engine.appsChanged = { [weak self] hostID, apps in
            guard let self, self.selectedHost?.id == hostID,
                  let host = self.hosts.first(where: { $0.id == hostID }), host.paired else { return }
            self.apps = apps.map(StreamingApp.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.selectedHost = host; self.showLibrary = true
        }
        engine.addressDiscovered = { [weak self] hostID, address in
            guard let self, self.pendingStreamAddress == address else { return }
            self.pendingStreamAddress = nil; self.linkedHostID = hostID
            UserDefaults.standard.set(hostID, forKey: "serverHostID")
            if let host = self.hosts.first(where: { $0.id == hostID }) { self.busy = false; self.select(host) }
        }
        engine.canPairHost = { [weak self] hostID in
            guard let self else { return false }
            return self.server.state == .connected && self.server.capabilities.contains("streaming") && hostID == self.linkedHostID
        }
        engine.pairingRequired = { [weak self] in self?.busy = false; self?.showAdd = true }
        engine.authorizePairing = { [weak self] hostID, challenge, completion in
            guard let self else { completion(false); return }
            let generation = self.serverPairingGeneration
            Task {
                guard self.busy, self.selectedHost?.id == hostID, self.linkedHostID == hostID,
                      self.server.state == .connected, self.server.capabilities.contains("streaming") else { completion(false); return }
                do {
                    var packet = Packet(.pairStream); packet.data = Data(challenge.utf8)
                    _ = try await self.server.request(packet)
                    completion(self.serverPairingGeneration == generation && self.server.state == .connected && self.linkedHostID == hostID)
                } catch { completion(false) }
            }
        }
        engine.pairingFinished = { [weak self] in self?.busy = false }
        engine.failed = { [weak self] message in self?.error = message; self?.busy = false }
        for notification in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCKeyboardDidConnect, .GCKeyboardDidDisconnect, .GCMouseDidConnect, .GCMouseDidDisconnect] {
            inputObservers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshInputs() }
            })
        }
        refreshInputs()
    }
    func start() {
        if session == nil { engine.start() }; refreshInputs()
        if savedServerName != nil, server.state == .disconnected, !reconnecting {
            reconnecting = true
            Task { defer { reconnecting = false }; await reconnectServer(reportError: false) }
        }
    }
    func suspend() {
        endStream()
        engine.cancelPairing(); busy = false
        engine.pause()
        // The Mac retains the PTYs. Only the transport belongs to this scene.
        server.disconnect()
    }
    func refreshInputs() {
        controllers = GCController.controllers().map { $0.vendorName ?? "Game controller" }
        keyboardConnected = GCKeyboard.coalesced != nil; mouseConnected = !GCMouse.mice().isEmpty
    }
    func setInputMode(_ mode: StreamInputMode) {
        preferences.inputMode = mode
        guard let current = session else { return }
        current.preferences.inputMode = mode
        if let controller = current.controller {
            engine.setTouchMode(mode == .touch, controller: controller)
        }
    }
    func select(_ host: StreamingHost) {
        guard !busy, session == nil, pendingStream == nil else { return }
        selectedHost = host; busy = true; apps = []; engine.selectHost(host.id)
    }
    func stream(_ app: StreamingApp) {
        guard session == nil, pendingStream == nil, let host = selectedHost else { return }
        let p = preferences
        showLibrary = false
        // Avoid presenting a second controller during the sheet's dismissal transition.
        // Check approval at launch, after the delay, so forgetting cannot race presentation.
        pendingStream = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            defer { self.pendingStream = nil }
            guard self.selectedHost?.id == host.id else { return }
            self.session = StreamSession(host: host, app: app, preferences: p)
        }
    }
    func streamViewport(_ size: CGSize, scale: CGFloat, session current: StreamSession) {
        guard session === current else { return }
        let p = current.preferences
        let fps = min(p.frameRate, UIScreen.main.maximumFramesPerSecond >= 120 ? 120 : 60)
        let requested = p.resolution == "Match device"
            ? StreamDisplaySize.matching(width: size.width, height: size.height, scale: scale, frameRate: fps)
            : StreamDisplaySize(width: p.dimensions.width, height: p.dimensions.height, frameRate: fps)
        guard let requested, requested.isValid, requested != current.desiredSize else { return }
        current.desiredSize = requested
        if current.reconfigure == nil {
            current.reconfigure = Task { [weak self] in await self?.configureStream(current) }
        }
    }
    private func configureStream(_ current: StreamSession) async {
        defer { current.reconfigure = nil }
        do {
            guard session === current, !Task.isCancelled else { return }
            await closingStream?.value
            while session === current, let requested = current.desiredSize {
                // Coalesce rotation, Split View, Stage Manager, and tool-panel layout events.
                try await Task.sleep(nanoseconds: 600_000_000)
                guard session === current else { return }
                if requested != current.desiredSize { continue }
                if current.size == requested, current.controller != nil { return }
                current.status = current.size == nil ? "Preparing your display…" : "Matching your display…"
                if let old = current.controller {
                    current.controller = nil
                    await stopVideo(old)
                }
                try Task.checkCancellation()
                guard session === current else { return }
                if current.host.id == linkedHostID {
                    if server.state != .connected { await reconnectServer(reportError: false) }
                    guard server.state == .connected else { throw NocturneError.disconnected }
                }
                if let packet = try StreamDisplayPreparation.request(size: requested, sessionID: current.id.uuidString,
                    matchesDevice: current.preferences.resolution == "Match device",
                    workspaceLinked: current.host.id == linkedHostID, capabilities: server.capabilities) {
                    current.hasDisplayLease = true
                    let reply = try await server.request(packet)
                    guard reply.display == requested, reply.sessionID == current.id.uuidString else { throw NocturneError.invalidFrame }
                    if current.heartbeat == nil { startDisplayHeartbeat(current) }
                }
                try Task.checkCancellation()
                guard session === current else { return }
                let p = current.preferences
                let values: [String: Any] = ["width":requested.width, "height":requested.height, "fps":requested.frameRate,
                    "bitrate":p.bitrate, "hdr":p.hdr, "pacing":p.framePacing, "touch":p.touchControls,
                    "absolute":p.absolutePointer, "statistics":p.statistics, "multi":p.multiController]
                guard let controller = engine.streamHost(current.host.id, app: current.app.id, settings: values, onExit: { [weak self, weak current] in
                    guard let self, let current, self.session === current else { return }; self.endStream()
                }) else { throw NocturneError.remote("Pair with this computer again before starting a stream.") }
                current.size = requested; current.controller = controller
                if current.desiredSize == requested { return }
            }
        } catch {
            guard session === current else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
            endStream()
        }
    }
    private func startDisplayHeartbeat(_ current: StreamSession) {
        current.heartbeat = Task { [weak self, weak current] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self, let current, self.session === current else { return }
                    var ping = Packet(.displayHeartbeat); ping.sessionID = current.id.uuidString
                    _ = try await self.server.request(ping)
                } catch {
                    guard !Task.isCancelled, let self, let current, self.session === current else { return }
                    self.error = "The display connection was lost. Reconnect to start a new stream."
                    self.endStream(); return
                }
            }
        }
    }
    private func stopVideo(_ controller: UIViewController) async {
        await withCheckedContinuation { continuation in engine.stopController(controller, completion: { continuation.resume() }) }
    }
    func endStream() {
        pendingStream?.cancel(); pendingStream = nil
        guard let current = session else { return }
        session = nil; current.reconfigure?.cancel(); current.heartbeat?.cancel(); current.heartbeat = nil
        if let controller = current.controller { engine.stopController(controller) }
        closingStream = Task { [weak self] in
            guard let self else { return }
            await current.reconfigure?.value
            if let controller = current.controller { await self.stopVideo(controller); current.controller = nil }
            if current.hasDisplayLease, self.server.state == .connected {
                var release = Packet(.displayRelease); release.sessionID = current.id.uuidString
                _ = try? await self.server.request(release)
            }
            if UIApplication.shared.applicationState == .active, self.session == nil { self.engine.start() }
        }
    }
    func pairScannedServer(_ text: String) async {
        let generation = UUID(); serverPairingGeneration = generation
        engine.cancelPairing()
        do {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw NocturneError.invalidInvitation }
            let invitation = try PairingInvitation(url: url)
            try await server.connect(invitation)
            guard serverPairingGeneration == generation else { return }
            try SecureStore.write(JSONEncoder().encode(invitation), account: "server")
            savedServerName = invitation.name; UserDefaults.standard.set(invitation.name, forKey: "serverName")
            showAdd = false
            if server.capabilities.contains("streaming") {
                pendingStreamAddress = invitation.host; busy = true
                try await Task.sleep(nanoseconds: 350_000_000)
                guard serverPairingGeneration == generation else { return }
                engine.addAddress(invitation.host)
            }
        } catch { if serverPairingGeneration == generation { self.error = error.localizedDescription } }
    }
    func reconnectServer(reportError: Bool = true) async {
        do {
            guard let data = try SecureStore.read("server") else { showAdd = true; return }
            try await server.connect(JSONDecoder().decode(PairingInvitation.self, from: data))
        } catch { if reportError { self.error = error.localizedDescription } }
    }
    func forgetServer() {
        serverPairingGeneration = UUID()
        if let linkedHostID, !removeStreamingHost(linkedHostID) { return }
        do {
            try SecureStore.delete("server"); server.disconnect(); server.forgetTerminals(); savedServerName = nil
            UserDefaults.standard.removeObject(forKey: "serverName"); UserDefaults.standard.removeObject(forKey: "serverHostID"); linkedHostID = nil; pendingStreamAddress = nil
        } catch { self.error = error.localizedDescription }
    }
    func forgetHost(_ hostID: String) {
        if hostID == linkedHostID { forgetServer() }
        else { _ = removeStreamingHost(hostID) }
    }
    private func removeStreamingHost(_ hostID: String) -> Bool {
        if session?.host.id == hostID || selectedHost?.id == hostID {
            endStream(); showLibrary = false; apps = []; selectedHost = nil; busy = false
        }
        return engine.forgetHost(hostID)
    }
}
