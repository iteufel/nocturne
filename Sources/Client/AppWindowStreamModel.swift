import SwiftUI
import Combine
import NocturneKit

@MainActor
final class AppWindowStreamModel: ObservableObject {
    let route: AppWindowRoute
    let connection: WorkspaceConnection
    let surface = AppWindowVideoView()
    @Published private(set) var ready = false
    @Published private(set) var display: StreamDisplaySize?
    @Published private(set) var status = L("Opening your Mac window…")
    @Published private(set) var error: String?
    @Published var keyboardVisible = false
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
    private let invitation: () throws -> PairingInvitation
    init(route: AppWindowRoute, connection: WorkspaceConnection, invitation: @escaping () throws -> PairingInvitation) {
        self.route = route; self.connection = connection; self.invitation = invitation
        surface.onInput = { [weak self] in self?.sendInput($0) }
        observer = connection.$state.sink { [weak self] state in
            guard state == .disconnected else { return }
            Task { @MainActor in
                guard let self, self.active, self.sessionID != nil else { return }
                self.fail(NocturneError.disconnected)
            }
        }
    }
    func activate() {
        guard !active else { return }
        active = true; error = nil; status = L("Opening your Mac window…")
        connection.onAppPacket = { [weak self] packet in self?.receive(packet) }
        configure()
    }
    func deactivate() {
        active = false; epoch = UUID()
        configureTask?.cancel(); configureTask = nil; heartbeat?.cancel(); heartbeat = nil
        inputTask?.cancel(); inputTask = nil; inputs.removeAll()
        firstFrameDeadline?.cancel(); firstFrameDeadline = nil
        sessionID = nil; appliedViewport = nil; ready = false
        surface.reset(); assembler.reset(); connection.onAppPacket = nil
        // Closing this socket releases only its own host capture and held input.
        connection.disconnect()
    }
    func viewport(_ size: CGSize, scale: CGFloat, frameRate: Int) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let next = AppWindowViewport(width: Int(min(4096, max(240, size.width.rounded()))),
            height: Int(min(4096, max(160, size.height.rounded()))), scale: min(3, max(1, scale)), frameRate: min(frameRate, 60))
        guard next.isValid, next != desiredViewport else { return }
        desiredViewport = next; configure()
    }
    private func configure() {
        guard active, configureTask == nil, desiredViewport != nil else { return }
        let generation = epoch
        configureTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == generation { self.configureTask = nil } }
            do {
                while self.active, self.epoch == generation, let desired = self.desiredViewport {
                    try await Task.sleep(nanoseconds: 350_000_000)
                    try Task.checkCancellation()
                    if desired != self.desiredViewport { continue }
                    if self.connection.state != .connected {
                        try await self.connection.connect(self.invitation(), restoreTerminalSessions: false, rediscover: true)
                        guard self.connection.capabilities.contains(AppStreaming.capability) else {
                            throw NocturneError.remote(L("Update Nocturne on your Mac to stream app windows."))
                        }
                    }
                    try Task.checkCancellation()
                    guard self.epoch == generation else { return }
                    if self.appliedViewport == desired { return }
                    var request = Packet(self.sessionID == nil ? .appOpen : .appResize)
                    if self.sessionID == nil { self.sessionID = UUID().uuidString }
                    request.sessionID = self.sessionID; request.applicationID = self.route.applicationID
                    request.windowID = self.route.windowID; request.viewport = desired
                    let reply = try await self.connection.request(request, timeout: 30)
                    guard self.epoch == generation else { return }
                    guard reply.sessionID == self.sessionID, let window = reply.window, window.id == self.route.windowID,
                          let display = reply.display, display.isValidAppWindow else { throw NocturneError.invalidFrame }
                    self.display = display; self.appliedViewport = desired
                    self.status = L("Waiting for %@…", "\(self.route.title)")
                    if self.heartbeat == nil { self.startHeartbeat(generation) }
                    if !self.ready, self.firstFrameDeadline == nil {
                        self.firstFrameDeadline = Task { [weak self] in
                            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                            guard let self, self.epoch == generation, !self.ready else { return }
                            self.fail(NocturneError.remote(L("No video arrived from this Mac window. Check Screen Recording permission on your Mac, then reconnect.")))
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
                    var ping = Packet(.appHeartbeat); ping.sessionID = id
                    _ = try await self.connection.request(ping)
                } catch {
                    guard !Task.isCancelled, let self, self.epoch == generation else { return }
                    self.fail(error); return
                }
            }
        }
    }
    private func receive(_ packet: Packet) {
        guard active, let id = sessionID, packet.sessionID == id else { return }
        if packet.operation == .appEnded { fail(NocturneError.remote(packet.error ?? L("This Mac window has closed."))); return }
        do {
            guard let video = try assembler.receive(packet) else { return }
            try surface.enqueue(video); ready = true; firstFrameDeadline?.cancel(); firstFrameDeadline = nil
        }
        catch { fail(error) }
    }
    func sendInput(_ input: AppWindowInput) {
        guard ready, active, input.isValid else { return }
        if input.kind == .move, inputs.last?.kind == .move { inputs[inputs.count - 1] = input }
        else {
            guard inputs.count < 128 else { fail(NocturneError.remote(L("The app window connection is too slow. Reconnect to continue."))); return }
            inputs.append(input)
        }
        guard inputTask == nil else { return }
        let generation = epoch
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == generation { self.inputTask = nil } }
            while !self.inputs.isEmpty, self.epoch == generation, let id = self.sessionID {
                var packet = Packet(.appInput); packet.sessionID = id; packet.input = self.inputs.removeFirst()
                do { _ = try await self.connection.request(packet) }
                catch { if self.epoch == generation { self.fail(error) }; return }
            }
        }
    }
    private func fail(_ error: Error) { deactivate(); self.error = NocturneLocalization.message(error.localizedDescription) }
}
