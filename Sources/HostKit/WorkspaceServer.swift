import Foundation
import Network
import NocturneKit

public struct HostPermissions {
    public var terminal: Bool
    public var files: Bool
    public var microphone: Bool
    public var chats: Bool
    public init(terminal: Bool = false, files: Bool = false, microphone: Bool = false, chats: Bool = false) {
        self.terminal = terminal; self.files = files; self.microphone = microphone; self.chats = chats
    }
}

public struct WorkspaceDeviceConnection: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let address: String
}

public final class WorkspaceServer {
    public var pairStream: ((String, String, String, String, @escaping (Error?) -> Void) -> Void)?
    public var displayCommand: ((Packet, UUID, String, @escaping (Packet) -> Void) -> Void)?
    public var displayDisconnected: ((UUID) -> Void)?
    public var onDevices: (([WorkspaceDeviceConnection]) -> Void)?
    public var onStatus: ((String, Int) -> Void)?
    public var authorizeRemoteDevice: ((UInt16, String) throws -> Void)?
    public let folder: SharedFolder
    private let queue = DispatchQueue(label: "nocturne.host", qos: .userInitiated)
    private var listener: NWListener?
    /// Available after readiness, including when port zero requests an OS-assigned port.
    public var listeningPort: UInt16? { queue.sync { listener?.port?.rawValue } }
    private var listenerCancelled: DispatchSemaphore?
    private var sessions: [UUID: HostSession] = [:]
    private let terminals = TerminalRegistry()
    private let microphone: MicrophoneSession
    private let appWindows: AppWindowSessionManager?
    private let desktop: DesktopSessionManager?
    private let simulators: SimulatorSessionManager?
    private var microphoneTimer: DispatchSourceTimer?
    private var permissions: HostPermissions
    private var chatAgents: [ChatAgentConfiguration]
    private let supervisor: ChatSupervisorService
    private let name: String
    private let devices: WorkspaceDeviceStore
    public init(folder: URL, name: String, devices: WorkspaceDeviceStore, permissions: HostPermissions = .init(), microphoneOutput: MicrophoneOutput = VirtualMicrophone(), appWindows: AppWindowSessionManager? = nil, desktop: DesktopSessionManager? = nil, simulators: SimulatorSessionManager? = nil, chatAgents: [ChatAgentConfiguration] = ChatAgentConfiguration.defaults) throws {
        self.folder = try SharedFolder(url: folder); self.name = name; self.devices = devices; self.permissions = permissions
        self.appWindows = appWindows
        self.desktop = desktop
        self.simulators = simulators
        self.chatAgents = chatAgents
        self.supervisor = ChatSupervisorService(configurations: chatAgents, directory: folder)
        microphone = MicrophoneSession(output: microphoneOutput)
    }
    public func start(secret: Data, port: UInt16 = WorkspaceProtocol.port) throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: SecureTransport.parameters(secret: secret), on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        let cancelled = DispatchSemaphore(value: 0); listenerCancelled = cancelled
        let discoveryID = WorkspaceDiscovery.identifier(for: secret)
        listener.service = NWListener.Service(name: "Nocturne-" + discoveryID.prefix(32), type: WorkspaceProtocol.service,
            txtRecord: NWTXTRecord(["id": discoveryID]))
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self, self.listener != nil, self.sessions.count < 32 else { connection.cancel(); return }
            let id = UUID()
            let channel = SecureChannel(connection: connection, queue: self.queue)
            let session = HostSession(channel: channel, terminals: self.terminals, microphone: self.microphone, appWindows: self.appWindows, desktop: self.desktop, simulators: self.simulators, folder: self.folder, name: self.name, devices: self.devices, permissions: self.permissions, chatAgents: self.chatAgents, supervisor: self.supervisor, pairStream: self.pairStream, displayCommand: self.displayCommand, displayDisconnected: self.displayDisconnected)
            self.sessions[id] = session
            session.authorizeRemoteDevice = self.authorizeRemoteDevice
            session.onClose = { [weak self] in self?.sessions.removeValue(forKey: id); self?.publish("Ready") }
            session.onAuthenticated = { [weak self] in self?.publish("Connected") }
            channel.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.publish("Ready")
            case .failed(let error): self?.publish(error.localizedDescription)
            case .cancelled: cancelled.signal(); self?.publish("Stopped")
            default: break
            }
        }
        listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.microphone.expire()
            if let simulators = self?.simulators { Task { await simulators.expire() } }
            if let apps = self?.appWindows { Task { @MainActor in apps.expire() } }
            if let desktop = self?.desktop { Task { @MainActor in desktop.expire() } }
        }
        microphoneTimer = timer; timer.resume()
    }
    public func updatePermissions(_ permissions: HostPermissions) {
        queue.async {
            self.permissions = permissions
            if !permissions.chats { self.supervisor.reset() }
            if !permissions.terminal { self.terminals.closeAll() }
            if !permissions.microphone { self.microphone.stop() }
            self.sessions.values.forEach { $0.updatePermissions(permissions) }
        }
    }
    public func updateChatAgents(_ agents: [ChatAgentConfiguration]) {
        queue.async { self.supervisor.reset(configurations: agents); self.chatAgents = agents; self.sessions.values.forEach { $0.configureChats(agents) } }
    }
    public func stop() {
        supervisor.reset()
        var cancelled: DispatchSemaphore?
        queue.sync {
            cancelled = listenerCancelled; listenerCancelled = nil
            listener?.cancel(); listener = nil
            microphoneTimer?.cancel(); microphoneTimer = nil
            let active = Array(sessions.values); sessions.removeAll()
            active.forEach { $0.close() }
            terminals.closeAll()
            microphone.stop()
        }
        // NWListener.cancel() is asynchronous. Wait for the listening socket to be
        // released before a server restart tries to bind the same port.
        _ = cancelled?.wait(timeout: .now() + 2)
    }
    public func disconnectDevice(_ id: String) {
        supervisor.reset()
        queue.sync { terminals.closeAll(owner: id); sessions.values.filter { $0.device?.id == id }.forEach { $0.close() }; publish("Ready") }
    }
    private func publish(_ status: String) {
        let connections = sessions.values.compactMap { $0.device }
        let unique = Array(Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status, unique.count); self?.onDevices?(unique) }
    }
}

private final class HostSession {
    var onClose: (() -> Void)?
    var onAuthenticated: (() -> Void)?
    var authorizeRemoteDevice: ((UInt16, String) throws -> Void)?
    private(set) var device: WorkspaceDeviceConnection?
    private let channel: SecureChannel
    private let folder: SharedFolder
    private let name: String
    private var permissions: HostPermissions
    private var transfers: [String: IncomingTransfer] = [:]
    private let terminals: TerminalRegistry
    private let microphone: MicrophoneSession
    private let appWindows: AppWindowSessionManager?
    private let desktop: DesktopSessionManager?
    private let simulators: SimulatorSessionManager?
    private let connectionID = UUID()
    private let chats: ChatHostSession
    private let devices: WorkspaceDeviceStore
    private var challenge: Data?
    private var closed = false
    private var pairing = false
    private let appConnection = AppWindowConnectionState()
    private let pairStream: ((String, String, String, String, @escaping (Error?) -> Void) -> Void)?
    private let displayCommand: ((Packet, UUID, String, @escaping (Packet) -> Void) -> Void)?
    private let displayDisconnected: ((UUID) -> Void)?
    init(channel: SecureChannel, terminals: TerminalRegistry, microphone: MicrophoneSession, appWindows: AppWindowSessionManager?, desktop: DesktopSessionManager?, simulators: SimulatorSessionManager?, folder: SharedFolder, name: String, devices: WorkspaceDeviceStore, permissions: HostPermissions, chatAgents: [ChatAgentConfiguration], supervisor: ChatSupervisorService, pairStream: ((String, String, String, String, @escaping (Error?) -> Void) -> Void)?, displayCommand: ((Packet, UUID, String, @escaping (Packet) -> Void) -> Void)?, displayDisconnected: ((UUID) -> Void)?) {
        self.pairStream = pairStream; self.terminals = terminals
        self.microphone = microphone
        self.appWindows = appWindows
        self.desktop = desktop
        self.simulators = simulators
        chats = ChatHostSession(configurations: chatAgents, directory: folder.url, enabled: permissions.chats, supervisor: supervisor)
        self.displayCommand = displayCommand; self.displayDisconnected = displayDisconnected
        self.channel = channel; self.devices = devices; self.folder = folder; self.name = name; self.permissions = permissions
        channel.onPacket = { [weak self] packet in self?.handle(packet) }
        channel.onClose = { [weak self] _ in self?.closed = true; self?.device = nil; self?.cleanup(); self?.onClose?() }
    }
    func updatePermissions(_ new: HostPermissions) {
        permissions = new
        chats.setEnabled(new.chats)
        if !new.files { transfers.removeAll() }
    }
    func configureChats(_ agents: [ChatAgentConfiguration]) { chats.configure(agents) }
    func close() { closed = true; device = nil; cleanup(); channel.cancel() }
    private func cleanup() {
        chats.close()
        if let simulators { let id = connectionID; Task { await simulators.disconnected(id) } }
        appConnection.close()
        transfers.removeAll(); terminals.detach(connectionID)
        microphone.disconnected(connectionID)
        if let appWindows { let id = connectionID; Task { @MainActor in appWindows.disconnected(id) } }
        if let desktop {
            let id = connectionID, displayDisconnected = displayDisconnected
            Task { @MainActor in
                // Stop native capture before its display lease removes the framebuffer.
                desktop.disconnected(id); displayDisconnected?(id)
            }
        } else { displayDisconnected?(connectionID) }
    }
    private func handle(_ packet: Packet) {
        do {
            guard !closed else { return }
            guard [.hello, .authenticate].contains(packet.operation) || device != nil else { throw NocturneError.remote("Authenticate this device before using your Mac.") }
            var result = packet.reply()
            switch packet.operation {
            case .hello:
                guard packet.version == WorkspaceProtocol.version else { throw NocturneError.remote("Update both apps to the same protocol version.") }
                guard challenge == nil, device == nil else { throw NocturneError.invalidFrame }
                let nonce = try SecureStore.randomKey(); challenge = nonce
                result.version = WorkspaceProtocol.version; result.data = nonce
            case .authenticate:
                guard device == nil, let nonce = challenge, let certificate = packet.certificate,
                      let signature = packet.signature, let deviceName = packet.name,
                      case .hostPort(let address, let port) = channel.connection.endpoint else { throw NocturneError.invalidFrame }
                challenge = nil
                let id = try WorkspaceIdentity.verify(certificate: certificate, signature: signature, challenge: channel.boundChallenge(nonce))
                let authorized = try devices.authorize(id: id, name: deviceName, token: packet.enrollmentToken)
                // Only a loopback socket created by the tunnel can authorize its QUIC peer.
                if ["127.0.0.1", "::1", "::ffff:127.0.0.1"].contains("\(address)") {
                    try authorizeRemoteDevice?(port.rawValue, id)
                }
                device = WorkspaceDeviceConnection(id: id, name: authorized.name, address: "\(address)")
                result.version = WorkspaceProtocol.version; result.name = name
                onAuthenticated?()
                result.capabilities = [permissions.files ? "files" : nil, permissions.terminal ? "terminal" : nil, pairStream != nil ? "streaming" : nil, displayCommand != nil ? "display" : nil, permissions.microphone ? MicrophoneFormat.capability : nil].compactMap { $0 }
                if appWindows != nil { result.capabilities?.append(AppStreaming.capability) }
                if desktop != nil { result.capabilities?.append(DesktopStreaming.capability) }
                if simulators != nil { result.capabilities?.append(SimulatorStreaming.capability) }
                if permissions.chats {
                    result.capabilities?.append(ChatProtocol.capability)
                    result.capabilities?.append(ChatVoice.capability)
                    result.capabilities?.append(ChatVoice.preparationCapability)
                    result.capabilities?.append(ChatSupervisor.capability)
                    result.capabilities?.append(DeveloperProtocol.capability)
                    result.capabilities?.append(DeveloperProtocol.actionsCapability)
                }
            case .ping: break
            case .chatSupervisor, .chatProviders, .chatList, .chatLoad, .chatNew, .chatPrompt, .chatCancel, .chatPermission, .chatOptions, .chatConfigure, .chatRepository,
                 .chatVoicePrepare, .chatVoiceOpen, .chatVoiceStart, .chatVoiceHeartbeat, .chatVoiceStop:
                guard permissions.chats else { throw NocturneError.permissionDenied }
                chats.handle(packet) { [weak channel] in channel?.send($0) }
                return
            case .desktopList, .desktopOpen, .desktopResize, .desktopInput, .desktopHeartbeat, .desktopClose:
                guard let desktop, device != nil else { throw NocturneError.permissionDenied }
                let connection = connectionID, channel = channel, state = appConnection
                Task { @MainActor in
                    let reply: Packet
                    do {
                        reply = try await desktop.handle(packet, connection: connection, isConnected: { state.isOpen },
                            send: { packet, completion in channel.send(packet, completion: completion) })
                    } catch { reply = packet.reply(error: error.localizedDescription) }
                    if state.isOpen { channel.send(reply) }
                }
                return
            case .appList, .appIcon, .appLaunch, .appOpen, .appResize, .appInput, .appHeartbeat, .appClose:
                guard let appWindows, let device else { throw NocturneError.permissionDenied }
                let connection = connectionID, channel = channel, state = appConnection
                Task { @MainActor in
                    let reply: Packet
                    do {
                        reply = try await appWindows.handle(packet, connection: connection, device: device.id, isConnected: { state.isOpen },
                            send: { packet, completion in channel.send(packet, completion: completion) })
                    } catch { reply = packet.reply(error: error.localizedDescription) }
                    if state.isOpen { channel.send(reply) }
                }
                return
            case .simulatorList, .simulatorOpen, .simulatorFrame, .simulatorClose, .simulatorInput:
                guard let simulators, device != nil else { throw NocturneError.permissionDenied }
                let connection = connectionID, channel = channel, state = appConnection
                Task {
                    let reply: Packet
                    do { reply = try await simulators.handle(packet, connection: connection, isConnected: { state.isOpen }) }
                    catch { reply = packet.reply(error: error.localizedDescription) }
                    if state.isOpen { channel.send(reply) }
                }
                return
            case .microphoneStart, .microphoneAudio, .microphoneStop:
                guard permissions.microphone else { throw NocturneError.permissionDenied }
                result = try microphone.handle(packet, connection: connectionID)
            case .displayPrepare, .displayHeartbeat, .displayRelease:
                guard let displayCommand, let device else { throw NocturneError.permissionDenied }
                let connection = connectionID, disconnected = displayDisconnected
                displayCommand(packet, connection, device.name) { [weak self] reply in
                    guard let self else { disconnected?(connection); return }
                    self.channel.queue.async {
                        guard !self.closed else { disconnected?(connection); return }
                        self.channel.send(reply)
                    }
                }
                return
            case .pairStream:
                guard let pairStream, !pairing, let data = packet.data, data.count == 4,
                      let pin = String(data: data, encoding: .utf8), pin.utf8.allSatisfy({ (48...57).contains($0) }),
                      let device,
                      case .hostPort(let address, _) = channel.connection.endpoint else { throw NocturneError.invalidFrame }
                pairing = true
                pairStream(pin, device.name, "\(address)", device.id) { [weak self] error in
                    guard let self else { return }
                    self.channel.queue.async {
                        guard !self.closed else { return }
                        self.pairing = false
                        self.channel.send(packet.reply(error: error?.localizedDescription))
                    }
                }
                return
            case .list:
                guard permissions.files else { throw NocturneError.permissionDenied }
                result.files = try folder.list(packet.path ?? "")
            case .read:
                guard permissions.files else { throw NocturneError.permissionDenied }
                let chunk = try folder.read(packet.path ?? "", offset: packet.offset ?? 0)
                result.data = chunk.data; result.size = chunk.size; result.eof = chunk.eof
            case .uploadBegin:
                guard permissions.files else { throw NocturneError.permissionDenied }
                guard transfers.count < 2 else { throw NocturneError.remote("Finish the current transfers first.") }
                let transfer = try folder.beginUpload(path: packet.path ?? "", size: packet.size ?? -1)
                transfers[transfer.id] = transfer; result.transferID = transfer.id
            case .uploadChunk:
                guard permissions.files else { throw NocturneError.permissionDenied }
                guard let id = packet.transferID, let transfer = transfers[id], let data = packet.data else { throw NocturneError.invalidTransfer }
                try transfer.append(data, offset: packet.offset ?? -1); result.offset = transfer.received
            case .uploadCommit:
                guard permissions.files else { throw NocturneError.permissionDenied }
                guard let id = packet.transferID, let transfer = transfers[id] else { throw NocturneError.invalidTransfer }
                try transfer.finish(); transfers.removeValue(forKey: id)
            case .uploadCancel:
                if let id = packet.transferID { transfers.removeValue(forKey: id) }
            case .terminalList, .terminalAttach, .terminalOpen, .terminalInput, .terminalResize, .terminalClose:
                guard permissions.terminal, let device else { throw NocturneError.permissionDenied }
                switch packet.operation {
                case .terminalList: result.terminals = terminals.list(owner: device.id)
                case .terminalAttach:
                    result = try terminals.attach(packet, owner: device.id, connection: connectionID) { [weak channel] in channel?.send($0) }
                case .terminalOpen:
                    let info = try terminals.open(owner: device.id, connection: connectionID,
                        columns: packet.columns ?? 80, rows: packet.rows ?? 24, queue: channel.queue) { [weak channel] in channel?.send($0) }
                    result.terminal = info; result.sessionID = info.id
                case .terminalInput: try terminals.input(packet, owner: device.id)
                case .terminalResize: try terminals.resize(packet, owner: device.id)
                case .terminalClose:
                    try terminals.close(packet.sessionID, owner: device.id); result.sessionID = packet.sessionID
                default: break
                }
            case .terminalOutput, .terminalExit, .terminalClosed, .appVideo, .appEnded, .desktopVideo, .desktopAudio, .desktopEnded, .chatEvent, .chatVoiceEvent: throw NocturneError.invalidFrame
            }
            channel.send(result)
        } catch {
            if packet.operation == .authenticate || packet.operation == .hello {
                closed = true
                channel.send(packet.reply(error: error.localizedDescription)) { [weak self] _ in self?.channel.cancel() }
            } else { channel.send(packet.reply(error: error.localizedDescription)) }
        }
    }
}

private final class AppWindowConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func close() { lock.lock(); open = false; lock.unlock() }
}
