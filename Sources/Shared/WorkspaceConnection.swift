import Foundation
import Combine
import Network
import CryptoKit

@MainActor
public final class WorkspaceConnection: ObservableObject {
    public enum State: Equatable { case disconnected, connecting, connected }
    @Published public private(set) var state: State = .disconnected
    @Published public private(set) var name = L("Your Mac")
    @Published public private(set) var capabilities: [String] = []
    @Published public private(set) var lastError: String?
    public var onAppPacket: ((Packet) -> Void)?
    public let chatEvents = PassthroughSubject<ChatEvent, Never>()
    public let chatVoiceEvents = PassthroughSubject<ChatVoiceEvent, Never>()
    public var onDesktopPacket: ((Packet) -> Void)?
    @Published public private(set) var terminals: [TerminalTab] = []
    @Published public private(set) var terminalID: String?
    /// Authenticated pairing with a refreshed LAN address; remote proxy addresses are never saved.
    public private(set) var connectedInvitation: PairingInvitation?
    public var streamingAddress: String? { remoteTunnel == nil ? connectedInvitation?.host : "127.0.0.1" }
    public var connectionRoute: String? {
        if let remoteTunnel { return remoteTunnel.route ?? L("Reconnecting") }
        return state == .connected ? L("Local network") : nil
    }
    private var remoteTunnel: RemoteTunnel?
    /// The hashed pairing key of the Mac at the far end of `remoteTunnel`.
    private var tunnelServer: Data?
    private weak var mediaParent: WorkspaceConnection?
    private var terminalServer: Data?
    public func selectTerminal(_ id: String) {
        if terminals.contains(where: { $0.id == id }) { terminalID = id }
    }
    public func forgetTerminals() { terminals = []; terminalID = nil; terminalServer = nil }
    private var channel: SecureChannel?
    private var ready: CheckedContinuation<Void, Error>?
    private var pending: [String: CheckedContinuation<Packet, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var generation = UUID()
    private let discovery = WorkspaceDiscovery()
    private let identity: WorkspaceIdentity
    private let remoteStreaming: Bool
    private let requiresIPv4: Bool
    public init(identity: WorkspaceIdentity, remoteStreaming: Bool = true, requiresIPv4: Bool = false) {
        self.identity = identity; self.remoteStreaming = remoteStreaming; self.requiresIPv4 = requiresIPv4
    }
    /// A separately authenticated socket keeps live media independent of file/terminal traffic.
    public func mediaConnection() -> WorkspaceConnection {
        let media = WorkspaceConnection(identity: identity, remoteStreaming: false); media.mediaParent = self; return media
    }
    public func connect(_ invitation: PairingInvitation, restoreTerminalSessions: Bool = true, rediscover: Bool = false) async throws {
        try Task.checkCancellation()
        disconnect(); lastError = nil; state = .connecting; name = invitation.name
        let server = Data(SHA256.hash(data: invitation.secret))
        if terminalServer != server { forgetTerminals(); terminalServer = server }
        let epoch = generation
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                // App windows can belong to a Mac other than the parent's; only that Mac's own tunnel reaches it.
                if let parent = mediaParent, parent.tunnelServer == server, let shared = parent.remoteTunnel {
                    remoteTunnel = shared; tunnelServer = server
                    try await establish(invitation, endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: shared.workspacePort)!), restoreTerminalSessions: restoreTerminalSessions, epoch: epoch)
                    return
                }
                var endpoints = [NWEndpoint.hostPort(host: NWEndpoint.Host(invitation.host), port: NWEndpoint.Port(rawValue: invitation.port)!)]
                if rediscover, let endpoint = await discovery.find(secret: invitation.secret) { endpoints.insert(endpoint, at: 0) }
                for (index, endpoint) in endpoints.enumerated() {
                    try Task.checkCancellation()
                    guard generation == epoch else { throw NocturneError.disconnected }
                    do {
                        try await establish(invitation, endpoint: endpoint, restoreTerminalSessions: restoreTerminalSessions, epoch: epoch)
                        return
                    } catch {
                        guard generation == epoch else { throw error }
                        closeTransport()
                        if index == endpoints.count - 1 && invitation.remoteAccess == nil { throw error }
                    }
                }
                if let access = invitation.remoteAccess {
                    let tunnel = try await RemoteTunnel.connect(access, streaming: remoteStreaming)
                    guard generation == epoch else { tunnel.stop(); throw NocturneError.disconnected }
                    remoteTunnel = tunnel; tunnelServer = server
                    try await establish(invitation, endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: tunnel.workspacePort)!), restoreTerminalSessions: restoreTerminalSessions, epoch: epoch)
                }
            } catch {
                if generation == epoch { lastError = NocturneLocalization.message(error.localizedDescription); disconnect() }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == epoch else { return }
                self.disconnect()
            }
        }
    }
    private func establish(_ invitation: PairingInvitation, endpoint: NWEndpoint, restoreTerminalSessions: Bool, epoch: UUID) async throws {
        state = .connecting
        let parameters = SecureTransport.parameters(secret: invitation.secret)
        // The bundled streaming engine listens on IPv4. Bonjour otherwise often
        // chooses a link-local IPv6 workspace address that cannot reach video.
        // Independent workspace/media connections retain their dual-stack support.
        if requiresIPv4, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let channel = SecureChannel(connection: connection); self.channel = channel
        channel.onReady = { [weak self, weak channel] in Task { @MainActor in
            guard let self, let channel, self.channel === channel, self.generation == epoch else { return }
            self.ready?.resume(); self.ready = nil
        } }
        channel.onPacket = { [weak self, weak channel] packet in Task { @MainActor in
            guard let self, let channel, self.channel === channel, self.generation == epoch else { return }; self.received(packet)
        } }
        channel.onClose = { [weak self, weak channel] error in Task { @MainActor in
            guard let self, let channel, self.channel === channel, self.generation == epoch else { return }
            self.lastError = NocturneLocalization.message(error.localizedDescription); self.closeTransport()
        } }
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            channel.start(timeout: invitation.remoteAccess != nil && remoteTunnel == nil ? 3 : 12)
        }
        guard generation == epoch else { throw NocturneError.disconnected }
        var hello = Packet(.hello); hello.version = WorkspaceProtocol.version
        let greeting = try await request(hello)
        guard greeting.version == WorkspaceProtocol.version, let challenge = greeting.data, challenge.count == 32 else {
            throw NocturneError.remote("Update Nocturne before connecting this device.")
        }
        var proof = Packet(.authenticate); proof.certificate = identity.certificate; proof.name = identity.name
        proof.signature = try identity.sign(WorkspaceIdentity.message(for: channel.boundChallenge(challenge))); proof.enrollmentToken = invitation.enrollmentToken
        let response = try await request(proof)
        guard generation == epoch else { throw NocturneError.disconnected }
        capabilities = response.capabilities ?? []; name = response.name ?? invitation.name
        if capabilities.contains("terminal"), restoreTerminalSessions { try await restoreTerminals() }
        else { terminals = []; terminalID = nil }
        guard generation == epoch else { throw NocturneError.disconnected }
        try Task.checkCancellation()
        guard self.channel === channel else { throw NocturneError.disconnected }
        if remoteTunnel != nil {
            // Persist the real LAN address and broker identity, never the temporary proxy port.
            connectedInvitation = invitation
        } else if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
            connectedInvitation = try invitation.replacingAddress(host: Self.reusableAddress(host), port: port.rawValue)
        } else { connectedInvitation = invitation }
        lastError = nil
        state = .connected
    }
    static func reusableAddress(_ host: NWEndpoint.Host) -> String {
        // NWEndpoint's description includes an interface suffix even for IPv4
        // (e.g. 192.168.0.123%en0), which HTTP/DNS cannot use.
        if case .ipv4(let ip) = host { return ip.rawValue.map(String.init).joined(separator: ".") }
        return "\(host)"
    }
    public func disconnect() {
        generation = UUID(); discovery.cancel(); closeTransport()
    }
    private func closeTransport() {
        channel?.cancel(); channel = nil; state = .disconnected; connectedInvitation = nil
        remoteTunnel = nil; tunnelServer = nil
        capabilities = []
        ready?.resume(throwing: NocturneError.disconnected); ready = nil
        let waiting = pending; pending.removeAll(); deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        waiting.values.forEach { $0.resume(throwing: NocturneError.disconnected) }
    }
    public func request(_ packet: Packet, timeout: TimeInterval? = nil) async throws -> Packet {
        guard let channel = channel else { throw NocturneError.disconnected }
        let timeout = timeout ?? (packet.operation == .displayPrepare ? StreamDisplayPreparation.requestTimeout : 15)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pending[packet.id] = continuation
                deadlines[packet.id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000)) } catch { return }
                    self?.failRequest(packet.id, error: NocturneError.timeout)
                }
                channel.send(packet) { [weak self] error in
                    if let error = error { Task { @MainActor in self?.failRequest(packet.id, error: error) } }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.failRequest(packet.id, error: CancellationError()) } }
    }
    public func restoreTerminals() async throws {
        let epoch = generation
        _ = try await request(Packet(.terminalList))
        for tab in terminals {
            guard generation == epoch else { throw NocturneError.disconnected }
            var attach = Packet(.terminalAttach); attach.sessionID = tab.id; attach.offset = tab.offset
            _ = try await request(attach)
        }
    }
    @discardableResult
    public func openTerminal(columns: Int = 80, rows: Int = 24) async throws -> String {
        var packet = Packet(.terminalOpen); packet.columns = columns; packet.rows = rows
        let response = try await request(packet)
        guard let id = response.terminal?.id else { throw NocturneError.invalidFrame }
        return id
    }
    public func terminalInput(_ data: Data, sessionID: String? = nil) async throws {
        guard state == .connected, let id = sessionID ?? terminalID else { throw NocturneError.disconnected }
        // Capture the tab and connection once: changing tabs/reconnecting during a paste
        // must never send its remaining bytes to another shell or a new connection.
        let epoch = generation
        for start in stride(from: 0, to: data.count, by: 1_024) {
            guard generation == epoch else { throw NocturneError.disconnected }
            var packet = Packet(.terminalInput); packet.sessionID = id; packet.data = data.subdata(in: start..<min(data.count, start + 1_024))
            _ = try await request(packet)
        }
    }
    public func resizeTerminal(columns: Int, rows: Int, sessionID: String? = nil) async throws {
        guard state == .connected, let id = sessionID ?? terminalID else { return }
        var packet = Packet(.terminalResize); packet.sessionID = id; packet.columns = columns; packet.rows = rows
        _ = try await request(packet)
    }
    public func closeTerminal(_ sessionID: String? = nil) async throws {
        guard let id = sessionID ?? terminalID else { return }
        var packet = Packet(.terminalClose); packet.sessionID = id
        _ = try await request(packet)
    }
    private func upsert(_ info: RemoteTerminal) -> TerminalTab {
        if let tab = terminals.first(where: { $0.id == info.id }) { tab.update(info); return tab }
        let tab = TerminalTab(info); terminals.append(tab)
        if terminalID == nil { terminalID = tab.id }
        return tab
    }
    private func removeTerminal(_ id: String) {
        let index = terminals.firstIndex(where: { $0.id == id }) ?? 0
        terminals.removeAll { $0.id == id }
        if terminalID == id { terminalID = terminals.isEmpty ? nil : terminals[min(index, terminals.count - 1)].id }
    }
    private func received(_ packet: Packet) {
        if packet.operation == .chatVoiceEvent {
            if let event = packet.chatVoiceEvent { chatVoiceEvents.send(event) }
            return
        }
        if packet.operation == .chatEvent {
            if let event = packet.chatEvent { chatEvents.send(event) }
            return
        }
        if [.desktopVideo, .desktopAudio, .desktopEnded].contains(packet.operation) {
            onDesktopPacket?(packet); return
        }
        if packet.operation == .appVideo || packet.operation == .appEnded {
            onAppPacket?(packet); return
        }
        let event = [.terminalOutput, .terminalExit, .terminalClosed].contains(packet.operation)
        guard event || pending[packet.id] != nil else { return }
        do {
            if let error = packet.error { throw NocturneError.remote(error) }
            switch packet.operation {
            case .terminalList:
                guard let infos = packet.terminals, infos.count <= WorkspaceProtocol.maximumTerminals,
                      Set(infos.map(\.id)).count == infos.count else { throw NocturneError.invalidFrame }
                let restored = infos.map { upsert($0) }
                terminals = restored
                if !restored.contains(where: { $0.id == terminalID }) { terminalID = restored.first?.id }
            case .terminalOpen:
                guard let info = packet.terminal else { throw NocturneError.invalidFrame }
                _ = upsert(info); terminalID = info.id
            case .terminalAttach:
                guard let info = packet.terminal, let data = packet.data, let start = packet.offset,
                      let end = packet.size, start >= 0, end >= start, end - start == Int64(data.count),
                      data.count <= WorkspaceProtocol.terminalHistoryLimit else { throw NocturneError.invalidFrame }
                try upsert(info).receive(data, at: start)
            case .terminalOutput:
                guard let id = packet.sessionID, let data = packet.data, let start = packet.offset else { throw NocturneError.invalidFrame }
                try terminals.first(where: { $0.id == id })?.receive(data, at: start)
            case .terminalExit:
                if let info = packet.terminal { terminals.first(where: { $0.id == info.id })?.update(info) }
            case .terminalClose, .terminalClosed:
                if let id = packet.sessionID { removeTerminal(id) }
            default: break
            }
            deadlines.removeValue(forKey: packet.id)?.cancel()
            pending.removeValue(forKey: packet.id)?.resume(returning: packet)
        } catch {
            failRequest(packet.id, error: error)
            if event { lastError = NocturneLocalization.message(error.localizedDescription); disconnect() }
        }
    }
    private func failRequest(_ id: String, error: Error) {
        deadlines.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: error)
    }
}

@MainActor
public final class FileTransferModel: ObservableObject {
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var activeName: String?
    @Published public private(set) var status = L("Ready to transfer")
    @Published public private(set) var bytesTransferred: Int64 = 0
    private var task: Task<URL?, Error>?
    public init() {}
    public func cancel() { task?.cancel() }
    public func upload(_ url: URL, to folder: String, using connection: WorkspaceConnection) async throws {
        guard activeName == nil else { throw NocturneError.remote("Wait for the current transfer to finish.") }
        activeName = url.lastPathComponent; progress = 0; bytesTransferred = 0; status = L("Sending")
        defer { activeName = nil; task = nil }
        let work = Task<URL?, Error> {
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resource.isRegularFile == true, let size = resource.fileSize else { throw NocturneError.invalidPath }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var begin = Packet(.uploadBegin); begin.path = folder.isEmpty ? url.lastPathComponent : folder + "/" + url.lastPathComponent; begin.size = Int64(size)
            let response = try await connection.request(begin)
            guard let id = response.transferID else { throw NocturneError.invalidFrame }
            do {
                var offset: Int64 = 0
                while offset < size {
                    try Task.checkCancellation()
                    guard let data = try handle.read(upToCount: WorkspaceProtocol.chunkSize), !data.isEmpty else { throw NocturneError.invalidTransfer }
                    var chunk = Packet(.uploadChunk); chunk.transferID = id; chunk.offset = offset; chunk.data = data
                    _ = try await connection.request(chunk); offset += Int64(data.count)
                    bytesTransferred = offset; progress = size == 0 ? 1 : Double(offset) / Double(size)
                }
                try Task.checkCancellation()
                var commit = Packet(.uploadCommit); commit.transferID = id; _ = try await connection.request(commit)
                progress = 1; status = L("Sent %@", "\(url.lastPathComponent)"); return nil
            } catch {
                var cancel = Packet(.uploadCancel); cancel.transferID = id
                // A fresh task can send cleanup even when this transfer was cancelled.
                Task { _ = try? await connection.request(cancel) }; throw error
            }
        }
        task = work
        do { _ = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } }
        catch { status = error is CancellationError ? L("Transfer cancelled") : NocturneLocalization.message(error.localizedDescription); throw error }
    }
    public func download(_ file: RemoteFile, using connection: WorkspaceConnection, temporaryDirectory: URL? = nil) async throws -> URL {
        guard activeName == nil, !file.isDirectory else { throw NocturneError.invalidTransfer }
        activeName = file.name; progress = 0; bytesTransferred = 0; status = L("Receiving")
        defer { activeName = nil; task = nil }
        let work = Task<URL?, Error> {
            let directory = (temporaryDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent("Nocturne-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Treat names from a remote server as untrusted, even after authentication.
            guard !file.name.isEmpty, file.name == URL(fileURLWithPath: file.name).lastPathComponent, !file.name.contains("/"), file.name != ".." else { throw NocturneError.invalidPath }
            let url = directory.appendingPathComponent(file.name)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            do {
                var offset: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    var packet = Packet(.read); packet.path = file.path; packet.offset = offset
                    let response = try await connection.request(packet)
                    guard let data = response.data, data.count <= WorkspaceProtocol.chunkSize, response.size == file.size,
                          offset + Int64(data.count) <= file.size, !data.isEmpty || response.eof == true else { throw NocturneError.invalidTransfer }
                    try handle.write(contentsOf: data); offset += Int64(data.count)
                    bytesTransferred = offset; progress = file.size == 0 ? 1 : Double(offset) / Double(file.size)
                    if response.eof == true { guard offset == file.size else { throw NocturneError.invalidTransfer }; break }
                }
                try handle.synchronize(); status = L("Received %@", "\(file.name)"); return url
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
        task = work
        do { return try await withTaskCancellationHandler { try await work.value! } onCancel: { work.cancel() } }
        catch { status = error is CancellationError ? L("Transfer cancelled") : NocturneLocalization.message(error.localizedDescription); throw error }
    }
}
