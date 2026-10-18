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
struct StreamSession: Identifiable {
    let id = UUID()
    let host: StreamingHost
    let app: StreamingApp
    let controller: UIViewController
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
    @Published var pin: String?
    @Published var error: String?
    @Published var showAdd = false
    @Published var preferServer = false
    @Published var showLibrary = false
    @Published var session: StreamSession?
    @Published var controllers: [String] = []
    @Published var keyboardConnected = false
    @Published var mouseConnected = false
    @Published var invitationText = ""
    @Published var savedServerName: String?
    @Published var preferences: StreamPreferences {
        didSet { if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "streamPreferences") } }
    }
    private var reconnecting = false
    private var pendingStreamAddress: String?
    private var linkedHostID = UserDefaults.standard.string(forKey: "serverHostID")
    private var pendingStream: Task<Void, Never>?
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
        engine.pairingPIN = { [weak self] pin in
            guard let self else { return }
            guard self.server.state == .connected, self.server.capabilities.contains("streaming"), self.selectedHost?.id == self.linkedHostID else { self.pin = pin; return }
            let hostID = self.selectedHost?.id
            Task {
                guard self.busy, self.selectedHost?.id == hostID else { return }
                do {
                    var packet = Packet(.pairStream); packet.data = Data(pin.utf8)
                    packet.name = String(UIDevice.current.name.prefix(32))
                    _ = try await self.server.request(packet)
                } catch { if self.busy, self.selectedHost?.id == hostID { self.pin = pin } }
            }
        }
        engine.pairingFinished = { [weak self] in self?.busy = false; self?.pin = nil }
        engine.failed = { [weak self] message in self?.error = message; self?.busy = false; self?.pin = nil }
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
        engine.pause()
        // The Mac retains the PTYs. Only the transport belongs to this scene.
        server.disconnect()
    }
    func refreshInputs() {
        controllers = GCController.controllers().map { $0.vendorName ?? "Game controller" }
        keyboardConnected = GCKeyboard.coalesced != nil; mouseConnected = !GCMouse.mice().isEmpty
    }
    func select(_ host: StreamingHost) {
        guard !busy, session == nil, pendingStream == nil else { return }
        selectedHost = host; busy = true; apps = []; engine.selectHost(host.id)
    }
    func add(address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(where: \.isWhitespace) else { error = "Enter a host name or IP address, such as studio.local or 192.168.1.20."; return }
        busy = true; engine.addAddress(trimmed); showAdd = false
    }
    func stream(_ app: StreamingApp) {
        guard session == nil, pendingStream == nil, let host = selectedHost else { return }
        let p = preferences
        let values: [String: Any] = ["width":p.dimensions.width, "height":p.dimensions.height, "fps":p.frameRate,
            "bitrate":p.bitrate, "hdr":p.hdr, "pacing":p.framePacing, "touch":p.touchControls,
            "absolute":p.absolutePointer, "statistics":p.statistics, "multi":p.multiController]
        showLibrary = false
        // Avoid presenting a second controller during the sheet's dismissal transition.
        // Check approval at launch, after the delay, so forgetting cannot race presentation.
        pendingStream = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            defer { self.pendingStream = nil }
            guard self.selectedHost?.id == host.id else { return }
            guard let controller = self.engine.streamHost(host.id, app: app.id, settings: values, onExit: { [weak self] in self?.endStream() }) else {
                self.error = "Pair with this computer again before starting a stream."; return
            }
            self.session = StreamSession(host: host, app: app, controller: controller)
        }
    }
    func endStream() {
        pendingStream?.cancel(); pendingStream = nil
        if let session { engine.stopController(session.controller) }
        session = nil; engine.start()
    }
    func receiveInvitation(_ url: URL) {
        guard url.scheme == "nocturne" else { return }
        invitationText = url.absoluteString; preferServer = true; showAdd = true
    }
    func pairServer(_ text: String) async {
        let generation = UUID(); serverPairingGeneration = generation
        do {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw NocturneError.invalidInvitation }
            let invitation = try PairingInvitation(url: url)
            try await server.connect(invitation)
            guard serverPairingGeneration == generation else { return }
            try SecureStore.write(JSONEncoder().encode(invitation), account: "server")
            savedServerName = invitation.name; UserDefaults.standard.set(invitation.name, forKey: "serverName")
            invitationText = ""; showAdd = false
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
            endStream(); showLibrary = false; apps = []; selectedHost = nil; pin = nil; busy = false
        }
        return engine.forgetHost(hostID)
    }
}
