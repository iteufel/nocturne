import SwiftUI
import GameController
import Combine
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
    @Published var videoReady = false
    var desiredSize: StreamDisplaySize?
    var reconfigure: Task<Void, Never>?
    var heartbeat: Task<Void, Never>?
    var hasDisplayLease = false
    init(host: StreamingHost, app: StreamingApp, preferences: StreamPreferences) {
        self.host = host; self.app = app; self.preferences = preferences
    }
}
enum ClientPage: String, CaseIterable, Identifiable {
    case computers = "Computers", hostApps = "Apps", terminal = "Terminal", files = "Files", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .computers: return "desktopcomputer"; case .hostApps: return "square.grid.2x2"; case .terminal: return "terminal"; case .files: return "folder"; case .settings: return "slider.horizontal.3" }
    }
}

@MainActor
final class ClientModel: ObservableObject {
    static let shared = ClientModel()
    let engine: NocturneStreamingService
    let server: WorkspaceConnection
    let hostApps: HostAppsModel
    let microphone = ClientMicrophone()
    let filesIntegration = FilesIntegration()
    @Published var hosts: [StreamingHost] = []
    @Published var apps: [StreamingApp] = []
    @Published var selectedHost: StreamingHost?
    @Published var page = ClientPage.computers
    @Published var busy = false
    @Published var error: String?
    @Published var showAdd = false
    @Published var showLibrary = false
    @Published var session: StreamSession?
    @Published var controllers: [String] = []
    @Published var keyboardConnected = false
    @Published var mouseConnected = false
    @Published private(set) var pairedServers = PairedServerList()
    var savedServerName: String? { pairedServers.active?.name }
    @Published var preferences: StreamPreferences {
        didSet { if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "streamPreferences") } }
    }
    private var reconnectTask: Task<Void, Error>?
    private var networkTask: Task<Void, Never>?
    private var pendingStreamAddress: String?
    private struct HostSetup {
        let serverID: String
        var openLibrary: Bool
        var startDesktop: Bool
    }
    private var hostSetup: HostSetup?
    private var openingHost: Task<Void, Never>?
    private var openingRequest = UUID()
    private var setupDeadline: Task<Void, Never>?
    @Published private(set) var hostErrors: [String: String] = [:]
    private var linkedHostID: String? { pairedServers.active?.streamingHostID }
    /// Saving is refused until Keychain has been read, so a locked Keychain cannot erase other pairings.
    private var pairedServersLoaded = false
    private var pendingStream: Task<Void, Never>?
    private var closingStream: Task<Void, Never>?
    private var serverPairingGeneration = UUID()
    private var inputObservers: [NSObjectProtocol] = []
    private var workspaceObserver: AnyCancellable?
    init(engine: NocturneStreamingService = NocturneStreamingService()) {
        self.engine = engine
        let streamingEngine = engine
        server = WorkspaceConnection(identity: WorkspaceIdentity(certificate: streamingEngine.workspaceCertificate(),
            name: UIDevice.current.name) { streamingEngine.signWorkspaceChallenge($0) }, requiresIPv4: true)
        hostApps = HostAppsModel(connection: server)
        preferences = UserDefaults.standard.data(forKey: "streamPreferences").flatMap { try? JSONDecoder().decode(StreamPreferences.self, from: $0) } ?? .init()
        loadPairedServers()
        engine.hostsChanged = { [weak self] hosts in self?.hosts = hosts.map(StreamingHost.init) }
        engine.appsChanged = { [weak self] hostID, apps in
            guard let self, self.selectedHost?.id == hostID,
                  let host = self.hosts.first(where: { $0.id == hostID }), host.paired else { return }
            self.apps = apps.map(StreamingApp.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.selectedHost = host
            let destination = self.hostSetup
            self.finishHostSetup()
            if destination?.startDesktop == true, let desktop = self.apps.first(where: { $0.name.lowercased() == "desktop" }) {
                self.stream(desktop)
            } else if destination?.openLibrary != false { self.showLibrary = true }
        }
        engine.addressDiscovered = { [weak self] hostID, address in
            guard let self, self.pendingStreamAddress == address, let active = self.pairedServers.active,
                  self.hostSetup?.serverID == active.id, self.server.state == .connected else { return }
            self.pendingStreamAddress = nil
            var list = self.pairedServers
            let superseded = list.link(streamingHostID: hostID, to: active.id)
            do { try self.savePairedServers(list) } catch { self.failHostSetup(error.localizedDescription); return }
            for stale in superseded {
                AppWindowScenes.disconnect(serverID: stale.id)
                do { try self.filesIntegration.forget(stale.invitation) } catch { self.error = error.localizedDescription }
            }
            guard let host = self.hosts.first(where: { $0.id == hostID }) else {
                self.failHostSetup("The host could not be found. Try connecting again."); return
            }
            self.selectedHost = host
            self.engine.selectHost(hostID)
        }
        engine.canPairHost = { [weak self] hostID in
            guard let self else { return false }
            return self.server.state == .connected && self.server.capabilities.contains("streaming") && hostID == self.linkedHostID
        }
        engine.pairingRequired = { [weak self] in
            guard let self else { return }
            if self.hostSetup != nil {
                self.failHostSetup("Screen sharing could not finish connecting. Check that Nocturne Server is running, then try again.")
            } else { self.busy = false; self.showAdd = true }
        }
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
        engine.streamStarted = { [weak self] controller in
            guard let self, let current = self.session, current.controller === controller else { return }
            current.videoReady = true
        }
        engine.streamFailed = { [weak self] controller, message in
            guard let self, self.session?.controller === controller else { return }
            self.failHostSetup(message); self.endStream()
        }
        engine.failed = { [weak self] message in self?.failHostSetup(message) }
        for notification in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCKeyboardDidConnect, .GCKeyboardDidDisconnect, .GCMouseDidConnect, .GCMouseDidDisconnect] {
            inputObservers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshInputs() }
            })
        }
        refreshInputs()
        workspaceObserver = server.$state.sink { [weak self] state in
            guard state != .connected else { return }
            Task { @MainActor in
                guard let self, self.server.state != .connected else { return }
                self.microphone.stop(); self.hostApps.reset()
                if self.hostSetup != nil {
                    self.failHostSetup("The host connection was lost before screen sharing was ready. Try connecting again.")
                }
                if let id = self.linkedHostID { self.engine.clearTemporaryAddress(id) }
            }
        }
    }
    func start() {
        if !pairedServersLoaded { loadPairedServers() }
        if pairedServersLoaded { filesIntegration.refresh(pairedServers.servers.map(\.invitation)) }
        if session == nil { engine.start() }; refreshInputs()
        guard networkTask == nil else { return }
        networkTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.maintainConnection()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
    private func maintainConnection() async {
        guard pairedServers.active != nil, !showAdd else { return }
        if server.state == .disconnected { await reconnectServer(reportError: false) }
        else if server.state == .connected {
            let generation = serverPairingGeneration
            do { _ = try await server.request(Packet(.ping), timeout: 5) }
            catch {
                guard !Task.isCancelled, serverPairingGeneration == generation else { return }
                server.disconnect()
            }
        }
    }
    private func cancelReconnect() {
        serverPairingGeneration = UUID()
        reconnectTask?.cancel(); reconnectTask = nil
        openingRequest = UUID(); openingHost?.cancel(); openingHost = nil
        engine.cancelPairing(); finishHostSetup()
    }
    func suspend() {
        networkTask?.cancel(); networkTask = nil; cancelReconnect()
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
    func setFillEntireScreen(_ fill: Bool) {
        preferences.fillEntireScreen = fill
        session?.preferences.fillEntireScreen = fill
        if let controller = session?.controller { engine.setFillEntireScreen(fill, controller: controller) }
    }
    func select(_ host: StreamingHost) {
        guard !busy, session == nil, pendingStream == nil else { return }
        if let owner = pairedServers.server(linkedTo: host.id) {
            openHost(owner.id)
        } else if let active = pairedServers.active, active.streamingHostID == nil,
                  Self.sameHostAddress(host.address, active.invitation.host) {
            // Older/interrupted pairings may not have saved the video UUID yet.
            // Resolve through the authenticated workspace before granting approval.
            openHost(active.id)
        } else {
            selectedHost = host; busy = true; apps = []; engine.selectHost(host.id)
        }
    }
    static func sameHostAddress(_ first: String, _ second: String) -> Bool {
        func hostname(_ address: String) -> String? {
            URLComponents(string: "http://\(address)")?.host?.lowercased()
        }
        guard let first = hostname(first), let second = hostname(second) else { return false }
        return first == second
    }
    func streamingHost(for paired: PairedServer) -> StreamingHost? {
        hosts.first { $0.id == paired.streamingHostID }
    }
    var nearbyHosts: [StreamingHost] {
        hosts.filter { host in
            !pairedServers.servers.contains { paired in
                paired.streamingHostID == host.id || (paired.streamingHostID == nil && Self.sameHostAddress(host.address, paired.invitation.host))
            }
        }
    }
    func hostStatus(_ paired: PairedServer) -> String {
        if paired.id == pairedServers.activeID {
            if busy || server.state == .connecting { return "Connecting…" }
            if hostErrors[paired.id] != nil { return "Screen sharing needs attention" }
        }
        if let host = streamingHost(for: paired), host.paired {
            return host.online ? "Screen sharing ready" : "Offline"
        }
        return "Screen sharing needs setup"
    }
    /// Opens a saved host using its existing credentials, including unfinished video setup.
    func openHost(_ id: String, desktop: Bool = false) {
        guard !busy, session == nil, pendingStream == nil, pairedServers[id] != nil else { return }
        guard selectServer(id) else { return }
        busy = true; error = nil; hostErrors[id] = nil
        showLibrary = false; apps = []
        let request = UUID(); openingRequest = request
        openingHost = Task { [weak self] in
            guard let self else { return }
            defer { if self.openingRequest == request { self.openingHost = nil } }
            await self.reconnectServer(reportError: true, prepareVideo: false)
            guard !Task.isCancelled, self.pairedServers.activeID == id else { return }
            guard self.server.state == .connected else { self.busy = false; return }
            self.prepareScreenSharing(openLibrary: true, desktop: desktop)
        }
    }
    /// Changes the workspace first; video approval is requested only after authentication.
    private func selectServer(_ id: String) -> Bool {
        guard pairedServers[id] != nil else { return false }
        guard id != pairedServers.activeID else { return true }
        let previous = linkedHostID
        var list = pairedServers; list.activate(id)
        do { try savePairedServers(list) } catch { self.error = error.localizedDescription; return false }
        cancelReconnect()
        if let previous { engine.clearTemporaryAddress(previous) }
        selectedHost = nil; apps = []; showLibrary = false
        microphone.stop(); hostApps.reset(); server.disconnect(); server.forgetTerminals()
        return true
    }
    func activateServer(_ id: String) {
        guard session == nil, !busy, pendingStream == nil, selectServer(id) else { return }
        Task { await reconnectServer(reportError: true) }
    }
    func reconnectHost(_ id: String) {
        guard session == nil, !busy, pendingStream == nil, selectServer(id) else { return }
        cancelReconnect(); server.disconnect()
        Task { await reconnectServer() }
    }
    private func prepareScreenSharing(openLibrary: Bool, desktop: Bool = false) {
        guard let active = pairedServers.active, server.state == .connected else { return }
        guard server.capabilities.contains("streaming") else {
            busy = false
            if openLibrary { failHostSetup("Screen sharing is unavailable on this host. Start the streaming server and reconnect.", serverID: active.id) }
            return
        }
        if hostSetup?.serverID == active.id {
            if openLibrary { hostSetup?.openLibrary = true; hostSetup?.startDesktop = desktop }
            return
        }
        if !openLibrary, streamingHost(for: active)?.paired == true, hostErrors[active.id] == nil { busy = false; return }
        hostErrors[active.id] = nil
        hostSetup = HostSetup(serverID: active.id, openLibrary: openLibrary, startDesktop: desktop)
        busy = true
        setupDeadline?.cancel()
        setupDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            self?.failHostSetup("Screen sharing did not respond. Check Nocturne Server on your host, then try again.")
        }
        let address = server.streamingAddress ?? active.invitation.host
        pendingStreamAddress = address
        engine.addAddress(address)
    }
    func cancelHostConnection() { cancelReconnect() }
    private func finishHostSetup() {
        setupDeadline?.cancel(); setupDeadline = nil
        pendingStreamAddress = nil; hostSetup = nil; busy = false
    }
    private func failHostSetup(_ message: String, serverID: String? = nil) {
        let videoHost = session?.host.id ?? (busy ? selectedHost?.id : nil)
        let owner = videoHost.flatMap { pairedServers.server(linkedTo: $0)?.id }
        if let id = serverID ?? hostSetup?.serverID ?? owner { hostErrors[id] = message }
        error = message
        engine.cancelPairing(); finishHostSetup()
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
                    microphone.stop(); current.videoReady = false
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
                    "absolute":p.absolutePointer, "statistics":p.statistics, "multi":p.multiController, "fill":p.fillEntireScreen]
                guard let controller = engine.streamHost(current.host.id, app: current.app.id, settings: values, onExit: { [weak self, weak current] in
                    guard let self, let current, self.session === current else { return }; self.endStream()
                }) else { throw NocturneError.remote("Pair with this computer again before starting a stream.") }
                current.size = requested; current.controller = controller
                if current.desiredSize == requested { return }
            }
        } catch {
            guard session === current else { return }
            if !(error is CancellationError) { failHostSetup(error.localizedDescription) }
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
        microphone.stop()
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
    var canUseMicrophone: Bool {
        session?.host.id == linkedHostID && session?.videoReady == true && server.state == .connected
            && server.capabilities.contains(MicrophoneFormat.capability)
    }
    func toggleMicrophone() {
        if microphone.active || microphone.starting { microphone.stop(); return }
        guard canUseMicrophone else { return }
        do {
            guard let invitation = server.connectedInvitation else { throw NocturneError.disconnected }
            microphone.start(invitation: invitation, connection: server.mediaConnection())
        } catch { self.error = error.localizedDescription }
    }
    func pairScannedServer(_ text: String) async {
        cancelReconnect()
        let generation = serverPairingGeneration
        engine.cancelPairing()
        do {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw NocturneError.invalidInvitation }
            let invitation = try PairingInvitation(url: url)
            if let previous = linkedHostID { engine.clearTemporaryAddress(previous) }
            try await server.connect(invitation, rediscover: true)
            guard serverPairingGeneration == generation else { return }
            let connected = server.connectedInvitation ?? invitation
            var list = pairedServers; list.pair(connected)
            try savePairedServers(list)
            updateFilesLocation(connected)
            showAdd = false
            prepareScreenSharing(openLibrary: true)
        } catch {
            if serverPairingGeneration == generation { failHostSetup(error.localizedDescription) }
        }
    }
    func reconnectServer(reportError: Bool = true, prepareVideo: Bool = true) async {
        var generation = serverPairingGeneration
        do {
            if let reconnectTask {
                try await reconnectTask.value
                if prepareVideo { prepareScreenSharing(openLibrary: false) }
                return
            }
            guard server.state == .disconnected else {
                if let connected = server.connectedInvitation { updateFilesLocation(connected) }
                if prepareVideo { prepareScreenSharing(openLibrary: false) }
                return
            }
            generation = UUID(); serverPairingGeneration = generation
            let attempt = generation
            let task = Task { @MainActor in
                guard let saved = self.pairedServers.active else { if reportError { self.showAdd = true }; return }
                var invitation = saved.invitation
                if let host = self.hosts.first(where: { $0.id == saved.streamingHostID && $0.online && $0.paired }), !host.address.isEmpty, host.address != "127.0.0.1" {
                    invitation = try invitation.replacingAddress(host: host.address)
                }
                try await self.server.connect(invitation, rediscover: true)
                try Task.checkCancellation()
                guard self.serverPairingGeneration == attempt, self.pairedServers.activeID == saved.id,
                      let connected = self.server.connectedInvitation else { return }
                if let id = saved.streamingHostID { self.engine.updateHostAddress(id, address: self.server.streamingAddress ?? connected.host) }
                var list = self.pairedServers; list.update(connected)
                try self.savePairedServers(list)
                self.updateFilesLocation(connected)
            }
            reconnectTask = task
            defer { if serverPairingGeneration == generation { reconnectTask = nil } }
            try await task.value
            guard serverPairingGeneration == generation else { return }
            if prepareVideo { prepareScreenSharing(openLibrary: false) }
        } catch {
            if reportError, serverPairingGeneration == generation, !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    /// Forgets one paired Mac (the active one by default), with its video approval, Files location, and app windows.
    func forgetServer(_ id: String? = nil) {
        guard let target = if let id { pairedServers[id] } else { pairedServers.active } else { return }
        let wasActive = target.id == pairedServers.activeID
        if wasActive { cancelReconnect() }
        if let hostID = target.streamingHostID, !removeStreamingHost(hostID) { return }
        do {
            try filesIntegration.forget(target.invitation)
            AppWindowScenes.disconnect(serverID: target.id)
            hostErrors[target.id] = nil
            var list = pairedServers; list.remove(target.id)
            try savePairedServers(list)
            guard wasActive else { return }
            server.disconnect(); server.forgetTerminals(); hostApps.reset(); pendingStreamAddress = nil
            if list.active != nil { Task { await reconnectServer(reportError: false) } }
        } catch { self.error = error.localizedDescription }
    }
    private func loadPairedServers() {
        do {
            if let data = try SecureStore.read(PairedServerList.keychainAccount) {
                pairedServers = (try? JSONDecoder().decode(PairedServerList.self, from: data)) ?? PairedServerList()
            } else {
                let legacy = try SecureStore.read(PairedServerList.legacyKeychainAccount).flatMap {
                    try? JSONDecoder().decode(PairingInvitation.self, from: $0)
                }
                let list = PairedServerList(legacy: legacy, streamingHostID: UserDefaults.standard.string(forKey: "serverHostID"))
                try SecureStore.write(JSONEncoder().encode(list), account: PairedServerList.keychainAccount)
                try SecureStore.delete(PairedServerList.legacyKeychainAccount)
                UserDefaults.standard.removeObject(forKey: "serverHostID"); UserDefaults.standard.removeObject(forKey: "serverName")
                pairedServers = list
            }
            pairedServersLoaded = true
        } catch { self.error = error.localizedDescription }
    }
    private func savePairedServers(_ list: PairedServerList) throws {
        guard pairedServersLoaded else {
            throw NocturneError.remote("Your paired hosts could not be read from Keychain. Unlock this device, then reopen Nocturne.")
        }
        try SecureStore.write(JSONEncoder().encode(list), account: PairedServerList.keychainAccount)
        pairedServers = list
    }
    private func updateFilesLocation(_ invitation: PairingInvitation) {
        filesIntegration.configure(invitation: invitation, certificate: engine.workspaceCertificate(),
            privateKey: engine.workspacePrivateKey(), deviceName: UIDevice.current.name,
            enabled: server.capabilities.contains("files"))
    }
    /// App windows reconnect to their own Mac, which need not be the active one.
    func appWindowInvitation(serverID: String? = nil) throws -> PairingInvitation {
        if let serverID {
            guard let paired = pairedServers[serverID] else {
                throw NocturneError.remote("This window belongs to a Mac that is no longer paired. Pair it again to open its apps.")
            }
            return paired.invitation
        }
        guard let active = pairedServers.active else { throw NocturneError.remote("Pair your Mac in Nocturne before opening an app window.") }
        return active.invitation
    }
    func makeAppWindowStream(_ route: AppWindowRoute) -> AppWindowStreamModel {
        AppWindowStreamModel(route: route, connection: server.mediaConnection()) { [weak self] in
            guard let self else { throw NocturneError.disconnected }
            return try self.appWindowInvitation(serverID: route.serverID)
        }
    }
    func forgetHost(_ hostID: String) {
        if let owner = pairedServers.server(linkedTo: hostID) { forgetServer(owner.id) }
        else { _ = removeStreamingHost(hostID) }
    }
    private func removeStreamingHost(_ hostID: String) -> Bool {
        if session?.host.id == hostID || selectedHost?.id == hostID {
            endStream(); showLibrary = false; apps = []; selectedHost = nil; busy = false
        }
        return engine.forgetHost(hostID)
    }
}
