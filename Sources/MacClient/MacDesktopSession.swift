import AppKit
import Combine
import NocturneKit

@MainActor
public final class MacDesktopSession: ObservableObject {
    public let serverID: String
    public let name: String
    public let route: AppWindowRoute?
    public var title: String { route?.title ?? name }
    public let connection: WorkspaceConnection
    public let surface = MacVideoView(frame: .zero)
    @Published public private(set) var ready = false
    @Published public private(set) var status = "Connecting to your Mac…"
    @Published public private(set) var error: String?
    @Published public private(set) var audioError: String?
    @Published public private(set) var displays: [RemoteDesktopDisplay] = []
    @Published public private(set) var selectedDisplayID: UInt32?
    @Published public private(set) var display: StreamDisplaySize?
    @Published public private(set) var screenLocked = false
    @Published public private(set) var matchesWindow = true
    @Published public private(set) var appWindow: RemoteAppWindow?
    @Published public var muted = false { didSet { audio.muted = muted } }
    var onAuthenticated: ((PairingInvitation) throws -> Void)?
    private let invitation: PairingInvitation
    private let audio = DesktopAudioPlayback()
    private var active = false
    private var epoch = UUID()
    private var sessionID: String?
    private var displayLeaseID: String?
    private var desiredViewport: AppWindowViewport?
    private var appliedViewport: AppWindowViewport?
    private var configureTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var firstFrameDeadline: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputs: [AppWindowInput] = []
    private var assembler = AppWindowVideoAssembler()
    private var observer: AnyCancellable?

    init(invitation: PairingInvitation, identity: WorkspaceIdentity, route: AppWindowRoute? = nil, initialWindow: RemoteAppWindow? = nil) {
        self.invitation = invitation; name = invitation.name; self.route = route
        serverID = WorkspaceIdentity.fingerprint(invitation.secret)
        appWindow = initialWindow
        // Native media travels over this authenticated workspace socket, including
        // through a remote tunnel. It never needs Moonlight's UDP port forwarding.
        connection = WorkspaceConnection(identity: identity, remoteStreaming: false)
        surface.onInput = { [weak self] in self?.sendInput($0) }
        surface.setAccessibilityLabel(route == nil ? "Remote Mac desktop" : "Remote Mac app window")
        observer = connection.$state.dropFirst().sink { [weak self] state in
            guard state == .disconnected else { return }
            Task { @MainActor in
                guard let self, self.active, self.sessionID != nil, self.connection.state == .disconnected else { return }
                self.fail(NocturneError.remote(self.connection.lastError ?? NocturneError.disconnected.localizedDescription))
            }
        }
    }
    public func activate() {
        guard !active else { return }
        active = true; error = nil; audioError = nil; status = "Connecting to \(name)…"
        if route == nil { connection.onDesktopPacket = { [weak self] in self?.receive($0) } }
        else { connection.onAppPacket = { [weak self] in self?.receive($0) } }
        configure()
    }
    public func stop() {
        active = false; epoch = UUID()
        configureTask?.cancel(); configureTask = nil; heartbeat?.cancel(); heartbeat = nil
        firstFrameDeadline?.cancel(); firstFrameDeadline = nil; inputTask?.cancel(); inputTask = nil
        inputs.removeAll(); sessionID = nil; displayLeaseID = nil; appliedViewport = nil; ready = false; display = nil; appWindow = nil; screenLocked = false
        surface.reset(); audio.stop(); assembler.reset(); connection.onDesktopPacket = nil; connection.onAppPacket = nil
        // Closing the authenticated socket releases capture and all held input
        // on the other Mac, independently of this Mac's own host services.
        connection.disconnect()
    }
    public func reconnect() { stop(); activate() }
    public func matchWindow(_ enabled: Bool) {
        guard route == nil, matchesWindow != enabled else { return }
        matchesWindow = enabled
        if active { reconnect() }
    }
    public func selectDisplay(_ id: UInt32) {
        guard route == nil, matchesWindow || selectedDisplayID != id, displays.contains(where: { $0.id == id }) else { return }
        matchesWindow = false; selectedDisplayID = id; reconnect()
    }
    public func viewport(_ size: CGSize, scale: CGFloat) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let factor = min(1, 4096 / max(size.width, size.height))
        let viewport = AppWindowViewport(width: Int(min(4096, max(240, (size.width * factor).rounded()))),
            height: Int(min(4096, max(160, (size.height * factor).rounded()))), scale: min(3, max(1, Double(scale))))
        guard viewport.isValid, viewport != desiredViewport else { return }
        desiredViewport = viewport; configure()
    }
    private func configure() {
        guard active, configureTask == nil, desiredViewport != nil else { return }
        let generation = epoch
        configureTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == generation { self.configureTask = nil } }
            do {
                while self.active, self.epoch == generation, let desired = self.desiredViewport {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    try Task.checkCancellation()
                    if desired != self.desiredViewport { continue }
                    if self.connection.state != .connected {
                        try await self.connection.connect(self.invitation, restoreTerminalSessions: false, rediscover: true)
                        try Task.checkCancellation()
                        guard self.epoch == generation else { return }
                        guard self.connection.capabilities.contains(self.route == nil ? DesktopStreaming.capability : AppStreaming.capability) else {
                            throw NocturneError.remote("Enable Screen sharing and install the latest Nocturne on the other Mac to share its desktop and app windows.")
                        }
                        guard let refreshed = self.connection.connectedInvitation else { throw NocturneError.disconnected }
                        try self.onAuthenticated?(refreshed)
                        if self.route == nil {
                            let catalog = try await self.connection.request(Packet(.desktopList), timeout: 30)
                            try Task.checkCancellation()
                            guard self.epoch == generation else { return }
                            self.displays = catalog.displays ?? []
                            if !self.displays.contains(where: { $0.id == self.selectedDisplayID }) {
                                self.selectedDisplayID = self.displays.first(where: \.isMain)?.id ?? self.displays.first?.id
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard self.epoch == generation else { return }
                    if self.appliedViewport == desired { return }
                    var captureDisplayID = self.selectedDisplayID
                    if self.route == nil, self.matchesWindow {
                        guard let size = StreamDisplaySize.matching(width: Double(desired.width), height: Double(desired.height),
                            scale: desired.scale, frameRate: desired.frameRate) else {
                            throw NocturneError.remote("Enlarge this window to match the host desktop to your screen.")
                        }
                        // Release capture before replacing its virtual framebuffer.
                        // Each video source gets a new ID so late frames are ignored.
                        if let oldID = self.sessionID {
                            self.surface.releaseInput(); self.inputs.removeAll()
                            await self.inputTask?.value
                            self.sessionID = nil; self.ready = false
                            self.surface.reset(); self.audio.stop(); self.assembler.reset()
                            self.firstFrameDeadline?.cancel(); self.firstFrameDeadline = nil
                            var close = Packet(.desktopClose); close.sessionID = oldID
                            _ = try await self.connection.request(close)
                        }
                        let leaseID = self.displayLeaseID ?? UUID().uuidString
                        guard let preparation = try StreamDisplayPreparation.request(size: size, sessionID: leaseID,
                            matchesDevice: true, workspaceLinked: true, capabilities: self.connection.capabilities) else {
                            throw NocturneError.invalidFrame
                        }
                        self.status = "Matching the host desktop to this window…"
                        let prepared = try await self.connection.request(preparation)
                        try Task.checkCancellation()
                        guard self.epoch == generation else { return }
                        guard prepared.sessionID == leaseID, prepared.display == size,
                              let id = prepared.displayID, id != 0 else {
                            throw NocturneError.remote("Update Nocturne on the host Mac to match its desktop to this window.")
                        }
                        self.displayLeaseID = leaseID; captureDisplayID = id
                        if self.heartbeat == nil { self.startHeartbeat(generation) }
                    }
                    var request = Packet(self.operation(self.sessionID == nil ? .desktopOpen : .desktopResize,
                                                       self.sessionID == nil ? .appOpen : .appResize))
                    if self.sessionID == nil { self.sessionID = UUID().uuidString }
                    request.sessionID = self.sessionID; request.displayID = captureDisplayID; request.viewport = desired
                    request.applicationID = self.route?.applicationID; request.windowID = self.route?.windowID
                    self.status = "Opening \(self.title)…"
                    let response = try await self.connection.request(request, timeout: 30)
                    guard self.epoch == generation else { return }
                    guard response.sessionID == self.sessionID, let display = response.display, display.isValidAppWindow else {
                        throw NocturneError.invalidFrame
                    }
                    if let route = self.route {
                        guard response.window?.id == route.windowID, response.window?.applicationID == route.applicationID else {
                            throw NocturneError.invalidFrame
                        }
                        self.appWindow = response.window
                    }
                    self.display = display; self.screenLocked = response.screenLocked ?? false; self.appliedViewport = desired
                    self.status = "Waiting for video…"
                    if self.heartbeat == nil { self.startHeartbeat(generation) }
                    if !self.ready, self.firstFrameDeadline == nil {
                        self.firstFrameDeadline = Task { [weak self] in
                            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                            guard let self, self.epoch == generation, !self.ready else { return }
                            self.fail(NocturneError.remote("No video arrived. Check Screen & System Audio Recording permission on the host Mac, then reconnect."))
                        }
                    }
                    if desired == self.desiredViewport { return }
                }
            } catch {
                guard self.epoch == generation, !(error is CancellationError) else { return }
                self.fail(error)
            }
        }
    }
    private func startHeartbeat(_ generation: UUID) {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self, self.active, self.epoch == generation else { return }
                    if let leaseID = self.displayLeaseID {
                        var ping = Packet(.displayHeartbeat); ping.sessionID = leaseID
                        _ = try await self.connection.request(ping, timeout: 8)
                    }
                    if let id = self.sessionID {
                        var ping = Packet(self.operation(.desktopHeartbeat, .appHeartbeat)); ping.sessionID = id
                        let reply: Packet
                        do { reply = try await self.connection.request(ping, timeout: 8) }
                        catch {
                            // A resize can close this source while its final
                            // heartbeat is in flight. The display lease is separate.
                            if self.sessionID != id { continue }
                            throw error
                        }
                        guard self.epoch == generation, self.sessionID == id else { continue }
                        if let display = reply.display, display.isValidAppWindow { self.display = display }
                        self.screenLocked = reply.screenLocked ?? false
                    }
                } catch {
                    guard !Task.isCancelled, let self, self.epoch == generation else { return }
                    self.fail(error); return
                }
            }
        }
    }
    private func receive(_ packet: Packet) {
        guard active, let id = sessionID, packet.sessionID == id else { return }
        if packet.operation == operation(.desktopEnded, .appEnded) { fail(NocturneError.remote(packet.error ?? "Sharing ended.")); return }
        if packet.operation == .desktopAudio {
            guard let frame = packet.audio, frame.isValid else { fail(NocturneError.invalidFrame); return }
            guard audioError == nil else { return }
            do { try audio.enqueue(frame) } catch { audio.stop(); audioError = error.localizedDescription }
            return
        }
        do {
            guard let frame = try assembler.receive(packet) else { return }
            try surface.enqueue(frame); ready = true; surface.inputEnabled = true
            firstFrameDeadline?.cancel(); firstFrameDeadline = nil
        } catch { fail(error) }
    }
    public func sendInput(_ input: AppWindowInput) {
        guard active, ready, input.isValid else { return }
        if input.kind == .move, inputs.last?.kind == .move { inputs[inputs.count - 1] = input }
        else {
            guard inputs.count < 128 else { fail(NocturneError.remote("The connection is too slow to receive input. Reconnect to continue.")); return }
            inputs.append(input)
        }
        guard inputTask == nil else { return }
        let generation = epoch
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == generation { self.inputTask = nil } }
            while !self.inputs.isEmpty, self.epoch == generation, let id = self.sessionID {
                var packet = Packet(self.operation(.desktopInput, .appInput)); packet.sessionID = id; packet.input = self.inputs.removeFirst()
                do { _ = try await self.connection.request(packet) }
                catch { if self.epoch == generation { self.fail(error) }; return }
            }
        }
    }
    private func operation(_ desktop: NocturneKit.Operation, _ app: NocturneKit.Operation) -> NocturneKit.Operation { route == nil ? desktop : app }
    private func fail(_ error: Error) { stop(); self.error = error.localizedDescription }
}
