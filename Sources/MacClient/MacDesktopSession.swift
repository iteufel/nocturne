import AppKit
import Combine
import NocturneKit

@MainActor
public final class MacDesktopSession: ObservableObject {
    public let serverID: String
    public let name: String
    public let connection: WorkspaceConnection
    public let surface = MacVideoView(frame: .zero)
    @Published public private(set) var ready = false
    @Published public private(set) var status = "Connecting to your Mac…"
    @Published public private(set) var error: String?
    @Published public private(set) var audioError: String?
    @Published public private(set) var displays: [RemoteDesktopDisplay] = []
    @Published public private(set) var selectedDisplayID: UInt32?
    @Published public private(set) var display: StreamDisplaySize?
    @Published public var muted = false { didSet { audio.muted = muted } }
    var onAuthenticated: ((PairingInvitation) throws -> Void)?
    private let invitation: PairingInvitation
    private let audio = DesktopAudioPlayback()
    private var active = false
    private var epoch = UUID()
    private var sessionID: String?
    private var desiredViewport: AppWindowViewport?
    private var appliedViewport: AppWindowViewport?
    private var configureTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var firstFrameDeadline: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputs: [AppWindowInput] = []
    private var assembler = AppWindowVideoAssembler()
    private var observer: AnyCancellable?

    init(invitation: PairingInvitation, identity: WorkspaceIdentity) {
        self.invitation = invitation; name = invitation.name
        serverID = WorkspaceIdentity.fingerprint(invitation.secret)
        // Native media travels over this authenticated workspace socket, including
        // through a remote tunnel. It never needs Moonlight's UDP port forwarding.
        connection = WorkspaceConnection(identity: identity, remoteStreaming: false)
        surface.onInput = { [weak self] in self?.sendInput($0) }
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
        connection.onDesktopPacket = { [weak self] in self?.receive($0) }
        configure()
    }
    public func stop() {
        active = false; epoch = UUID()
        configureTask?.cancel(); configureTask = nil; heartbeat?.cancel(); heartbeat = nil
        firstFrameDeadline?.cancel(); firstFrameDeadline = nil; inputTask?.cancel(); inputTask = nil
        inputs.removeAll(); sessionID = nil; appliedViewport = nil; ready = false; display = nil
        surface.reset(); audio.stop(); assembler.reset(); connection.onDesktopPacket = nil
        // Closing the authenticated socket releases capture and all held input
        // on the other Mac, independently of this Mac's own host services.
        connection.disconnect()
    }
    public func reconnect() { stop(); activate() }
    public func selectDisplay(_ id: UInt32) {
        guard selectedDisplayID != id, displays.contains(where: { $0.id == id }) else { return }
        selectedDisplayID = id; reconnect()
    }
    public func viewport(_ size: CGSize, scale: CGFloat) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let viewport = AppWindowViewport(width: Int(min(4096, max(240, size.width.rounded()))),
            height: Int(min(4096, max(160, size.height.rounded()))), scale: min(3, max(1, Double(scale))))
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
                        guard self.connection.capabilities.contains(DesktopStreaming.capability) else {
                            throw NocturneError.remote("Enable Screen sharing and install the latest Nocturne Server on the other Mac to connect Mac to Mac.")
                        }
                        guard let refreshed = self.connection.connectedInvitation else { throw NocturneError.disconnected }
                        try self.onAuthenticated?(refreshed)
                        let catalog = try await self.connection.request(Packet(.desktopList), timeout: 30)
                        try Task.checkCancellation()
                        guard self.epoch == generation else { return }
                        self.displays = catalog.displays ?? []
                        if let chosen = self.selectedDisplayID, !self.displays.contains(where: { $0.id == chosen }) {
                            self.selectedDisplayID = nil
                        }
                    }
                    try Task.checkCancellation()
                    guard self.epoch == generation else { return }
                    if self.appliedViewport == desired { return }
                    var request = Packet(self.sessionID == nil ? .desktopOpen : .desktopResize)
                    if self.sessionID == nil { self.sessionID = UUID().uuidString }
                    request.sessionID = self.sessionID; request.displayID = self.selectedDisplayID; request.viewport = desired
                    self.status = "Opening \(self.name)’s desktop…"
                    let response = try await self.connection.request(request, timeout: 30)
                    guard self.epoch == generation else { return }
                    guard response.sessionID == self.sessionID, let display = response.display, display.isValidAppWindow else {
                        throw NocturneError.invalidFrame
                    }
                    self.display = display; self.selectedDisplayID = response.displayID; self.appliedViewport = desired
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
                    guard let self, self.active, self.epoch == generation, let id = self.sessionID else { return }
                    var ping = Packet(.desktopHeartbeat); ping.sessionID = id
                    _ = try await self.connection.request(ping, timeout: 8)
                } catch {
                    guard !Task.isCancelled, let self, self.epoch == generation else { return }
                    self.fail(error); return
                }
            }
        }
    }
    private func receive(_ packet: Packet) {
        guard active, let id = sessionID, packet.sessionID == id else { return }
        if packet.operation == .desktopEnded { fail(NocturneError.remote(packet.error ?? "Desktop sharing ended.")); return }
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
                var packet = Packet(.desktopInput); packet.sessionID = id; packet.input = self.inputs.removeFirst()
                do { _ = try await self.connection.request(packet) }
                catch { if self.epoch == generation { self.fail(error) }; return }
            }
        }
    }
    private func fail(_ error: Error) { stop(); self.error = error.localizedDescription }
}
