import Foundation
import Network
import NocturneKit

public struct HostPermissions {
    public var terminal: Bool
    public var files: Bool
    public init(terminal: Bool = false, files: Bool = false) { self.terminal = terminal; self.files = files }
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
    public let folder: SharedFolder
    private let queue = DispatchQueue(label: "nocturne.host", qos: .userInitiated)
    private var listener: NWListener?
    private var listenerCancelled: DispatchSemaphore?
    private var sessions: [UUID: HostSession] = [:]
    private let terminals = TerminalRegistry()
    private var permissions: HostPermissions
    private let name: String
    private let devices: WorkspaceDeviceStore
    public init(folder: URL, name: String, devices: WorkspaceDeviceStore, permissions: HostPermissions = .init()) throws {
        self.folder = try SharedFolder(url: folder); self.name = name; self.devices = devices; self.permissions = permissions
    }
    public func start(secret: Data, port: UInt16 = WorkspaceProtocol.port) throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: SecureTransport.parameters(secret: secret), on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        let cancelled = DispatchSemaphore(value: 0); listenerCancelled = cancelled
        listener.service = NWListener.Service(name: name, type: WorkspaceProtocol.service)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self, self.listener != nil, self.sessions.count < 8 else { connection.cancel(); return }
            let id = UUID()
            let channel = SecureChannel(connection: connection, queue: self.queue)
            let session = HostSession(channel: channel, terminals: self.terminals, folder: self.folder, name: self.name, devices: self.devices, permissions: self.permissions, pairStream: self.pairStream, displayCommand: self.displayCommand, displayDisconnected: self.displayDisconnected)
            self.sessions[id] = session
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
    }
    public func updatePermissions(_ permissions: HostPermissions) {
        queue.async {
            self.permissions = permissions
            if !permissions.terminal { self.terminals.closeAll() }
            self.sessions.values.forEach { $0.updatePermissions(permissions) }
        }
    }
    public func stop() {
        var cancelled: DispatchSemaphore?
        queue.sync {
            cancelled = listenerCancelled; listenerCancelled = nil
            listener?.cancel(); listener = nil
            let active = Array(sessions.values); sessions.removeAll()
            active.forEach { $0.close() }
            terminals.closeAll()
        }
        // NWListener.cancel() is asynchronous. Wait for the listening socket to be
        // released before a server restart tries to bind the same port.
        _ = cancelled?.wait(timeout: .now() + 2)
    }
    public func disconnectDevice(_ id: String) {
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
    private(set) var device: WorkspaceDeviceConnection?
    private let channel: SecureChannel
    private let folder: SharedFolder
    private let name: String
    private var permissions: HostPermissions
    private var transfers: [String: IncomingTransfer] = [:]
    private let terminals: TerminalRegistry
    private let connectionID = UUID()
    private let devices: WorkspaceDeviceStore
    private var challenge: Data?
    private var closed = false
    private var pairing = false
    private let pairStream: ((String, String, String, String, @escaping (Error?) -> Void) -> Void)?
    private let displayCommand: ((Packet, UUID, String, @escaping (Packet) -> Void) -> Void)?
    private let displayDisconnected: ((UUID) -> Void)?
    init(channel: SecureChannel, terminals: TerminalRegistry, folder: SharedFolder, name: String, devices: WorkspaceDeviceStore, permissions: HostPermissions, pairStream: ((String, String, String, String, @escaping (Error?) -> Void) -> Void)?, displayCommand: ((Packet, UUID, String, @escaping (Packet) -> Void) -> Void)?, displayDisconnected: ((UUID) -> Void)?) {
        self.pairStream = pairStream; self.terminals = terminals
        self.displayCommand = displayCommand; self.displayDisconnected = displayDisconnected
        self.channel = channel; self.devices = devices; self.folder = folder; self.name = name; self.permissions = permissions
        channel.onPacket = { [weak self] packet in self?.handle(packet) }
        channel.onClose = { [weak self] _ in self?.closed = true; self?.device = nil; self?.cleanup(); self?.onClose?() }
    }
    func updatePermissions(_ new: HostPermissions) {
        permissions = new
        if !new.files { transfers.removeAll() }
    }
    func close() { closed = true; device = nil; cleanup(); channel.cancel() }
    private func cleanup() {
        transfers.removeAll(); terminals.detach(connectionID)
        displayDisconnected?(connectionID)
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
                      case .hostPort(let address, _) = channel.connection.endpoint else { throw NocturneError.invalidFrame }
                challenge = nil
                let id = try WorkspaceIdentity.verify(certificate: certificate, signature: signature, challenge: channel.boundChallenge(nonce))
                let authorized = try devices.authorize(id: id, name: deviceName, token: packet.enrollmentToken)
                device = WorkspaceDeviceConnection(id: id, name: authorized.name, address: "\(address)")
                result.version = WorkspaceProtocol.version; result.name = name
                onAuthenticated?()
                result.capabilities = [permissions.files ? "files" : nil, permissions.terminal ? "terminal" : nil, pairStream != nil ? "streaming" : nil, displayCommand != nil ? "display" : nil].compactMap { $0 }
            case .ping: break
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
            case .terminalOutput, .terminalExit, .terminalClosed: throw NocturneError.invalidFrame
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
