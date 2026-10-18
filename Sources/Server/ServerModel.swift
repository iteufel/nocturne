import AppKit
import SwiftUI
import NocturneKit
import NocturneHostKit
import Darwin

@MainActor
final class ServerModel: ObservableObject {
    private let appWindows = AppWindowSessionManager(host: NativeAppWindowHost())
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var connections = 0
    @Published private(set) var devices: [ServerDevice] = []
    @Published private(set) var devicesError: String?
    @Published private(set) var refreshingDevices = false
    @Published private(set) var removingDevice: String?
    @Published var error: String?
    @Published var showPairing = false
    @Published var invitation: PairingInvitation?
    @Published private(set) var resettingPairing = false
    var changingDevices: Bool { removingDevice != nil || resettingPairing }
    @Published var terminalEnabled = UserDefaults.standard.bool(forKey: "allowTerminal") { didSet { updatePermissions() } }
    @Published var filesEnabled = UserDefaults.standard.bool(forKey: "allowFiles") { didSet { updatePermissions() } }
    @Published var microphoneEnabled = UserDefaults.standard.bool(forKey: "allowMicrophone") { didSet { updatePermissions() } }
    @Published private(set) var microphoneInstalled = VirtualMicrophone.isInstalled
    @Published private(set) var installingMicrophone = false
    @Published private(set) var microphoneInstallationMessage: String?
    @Published var address: String
    @Published var sharedFolder: URL
    @Published var display: String {
        didSet { UserDefaults.standard.set(display, forKey: "streamDisplay"); updateDisplayStatus() }
    }
    @Published var headlessDisplayEnabled: Bool {
        didSet { UserDefaults.standard.set(headlessDisplayEnabled, forKey: "headlessDisplayEnabled"); updateDisplayStatus() }
    }
    @Published var disablePhysicalDisplays: Bool {
        didSet { UserDefaults.standard.set(disablePhysicalDisplays, forKey: "disablePhysicalDisplays") }
    }
    @Published private(set) var displayStatus = ""
    @Published private(set) var displayActive = false
    let displays: DisplaySessionManager
    let addresses: [String]
    let name = Host.current().localizedName ?? "My Mac"
    let engine: EmbeddedStreamingEngine
    var active: Bool { running || starting }
    private var server: WorkspaceServer?
    private var remoteTunnel: RemoteTunnel?
    @Published var remoteAccessEnabled = UserDefaults.standard.bool(forKey: "remoteAccessEnabled") {
        didSet { UserDefaults.standard.set(remoteAccessEnabled, forKey: "remoteAccessEnabled") }
    }
    @Published var brokerURL = UserDefaults.standard.string(forKey: "remoteBrokerURL") ?? "" {
        didSet { UserDefaults.standard.set(brokerURL, forKey: "remoteBrokerURL") }
    }
    private var deviceStore: WorkspaceDeviceStore?
    private var streamDevices: [StreamDevice] = []
    private var workspaceConnections: [WorkspaceDeviceConnection] = []
    private var pairingTasks: [String: Task<Void, Error>] = [:]
    private var deviceRevision = UUID()
    private var startTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var secret: Data?
    private var generation = UUID()
    private var pairWhenReady = false
    init() {
        let displaySettings = DisplaySettings()
        display = displaySettings.physicalDisplay
        headlessDisplayEnabled = displaySettings.headlessEnabled
        disablePhysicalDisplays = displaySettings.disablePhysicalDisplays
        addresses = Self.localAddresses(); address = addresses.first ?? "127.0.0.1"
        let savedFolder = UserDefaults.standard.string(forKey: "sharedFolder")
        sharedFolder = savedFolder.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Nocturne Shared", isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let engine = EmbeddedStreamingEngine(directory: support.appendingPathComponent("Nocturne/Engine", isDirectory: true))
        self.engine = engine
        displays = DisplaySessionManager { display in try await engine.selectDisplay(display) }
        do {
            deviceStore = try WorkspaceDeviceStore(url: support.appendingPathComponent("Nocturne/devices.json"))
            streamDevices = try engine.savedDevices(); publishDevices()
        } catch { devicesError = error.localizedDescription }
        engine.onUnexpectedExit = { [weak self] message in self?.stop(); self?.error = message }
        displays.onChange = { [weak self] in
            guard let self else { return }
            self.displayActive = self.displays.isActive
            self.updateDisplayStatus()
            if let error = self.displays.lastError { self.error = error }
        }
        updateDisplayStatus()
    }
    private func updateDisplayStatus() {
        if let size = displays.size {
            displayStatus = "\(size.width) × \(size.height) · \(displays.deviceName ?? "Connected device")"
        } else {
            displayStatus = headlessDisplayEnabled ? "Virtual monitor · Matches your device" : "Physical monitor · Fixed desktop size"
        }
    }
    func start() {
        guard !active else { return }
        guard DisplaySessionManager.isSessionAvailable else { error = "Unlock this Mac before starting the server."; return }
        starting = true; status = "Starting"; error = nil
        let epoch = UUID(); generation = epoch
        startTask = Task { [self] in
            do {
                guard let deviceStore else { throw NocturneError.remote("The saved device list could not be loaded. Restart Nocturne Server and try again.") }
                let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/nocturne-stream-host")
                let key: Data
                if let stored = try SecureStore.read("server-key") { key = stored }
                else { key = try SecureStore.randomKey(); try SecureStore.write(key, account: "server-key") }
                guard key.count == 32 else { throw NocturneError.invalidInvitation }
                secret = key
                var captureDisplay = display.isEmpty ? String(CGMainDisplayID()) : display
                if headlessDisplayEnabled {
                    displays.disablePhysicalDisplays = disablePhysicalDisplays
                    captureDisplay = String(try await displays.start())
                }
                try Task.checkCancellation()
                guard generation == epoch else { return }
                try await engine.start(executable: executable, name: name, display: captureDisplay)
                try Task.checkCancellation()
                guard generation == epoch else { return }
                let savedDevices = try await engine.pairedDevices()
                guard generation == epoch, !Task.isCancelled else { return }
                streamDevices = savedDevices; publishDevices()
                if remoteAccessEnabled {
                    // This private identity is never shared in a QR or derived from its shared key.
                    let endpointKey: Data
                    if let stored = try SecureStore.read("server-remote-key") { endpointKey = stored }
                    else { endpointKey = try SecureStore.randomKey(); try SecureStore.write(endpointKey, account: "server-remote-key") }
                    let tunnel = try await RemoteTunnel.host(brokerURL: brokerURL, endpointKey: endpointKey)
                    guard generation == epoch, !Task.isCancelled else { tunnel.stop(); return }
                    remoteTunnel = tunnel
                }
                let host = try WorkspaceServer(folder: sharedFolder, name: name, devices: deviceStore, permissions: .init(terminal: terminalEnabled, files: filesEnabled, microphone: microphoneEnabled), appWindows: appWindows)
                if let tunnel = remoteTunnel {
                    host.authorizeRemoteDevice = { [weak tunnel] port, device in
                        guard let tunnel else { throw NocturneError.disconnected }
                        try tunnel.authorize(sourcePort: port, deviceID: device)
                    }
                }
                if headlessDisplayEnabled {
                    host.displayCommand = { [weak self] packet, connection, name, completion in
                        Task { @MainActor in
                            guard let self, self.generation == epoch, self.running else { completion(packet.reply(error: NocturneError.disconnected.localizedDescription)); return }
                            do { completion(try await self.displays.handle(packet, connection: connection, name: name)) }
                            catch { completion(packet.reply(error: error.localizedDescription)) }
                        }
                    }
                    host.displayDisconnected = { [weak self] connection in
                        Task { @MainActor in guard self?.generation == epoch else { return }; self?.displays.disconnected(connection) }
                    }
                }
                host.pairStream = { [weak self] pin, name, address, deviceID, completion in
                    Task { @MainActor in
                        guard let self, self.running, self.generation == epoch, self.removingDevice != deviceID, !self.resettingPairing,
                              self.pairingTasks[deviceID] == nil else { completion(NocturneError.disconnected); return }
                        let task = Task { try await self.engine.pairAuthorizedClient(pin: pin, name: name, address: address) }
                        self.pairingTasks[deviceID] = task
                        do { try await task.value; completion(nil) } catch { completion(error) }
                        guard self.generation == epoch else { return }
                        self.pairingTasks.removeValue(forKey: deviceID)
                        await self.refreshDevices()

                    }
                }
                host.onDevices = { [weak self] connections in
                    guard let self, self.generation == epoch else { return }
                    self.workspaceConnections = connections; self.publishDevices()
                }
                host.onStatus = { [weak self] status, count in
                    guard let self, self.generation == epoch else { return }
                    self.connections = count
                    if status == "Ready" || status == "Connected" {
                        self.running = true; self.starting = false; self.status = CGPreflightScreenCaptureAccess() ? "Ready" : "Allow screen capture"
                        if self.pairWhenReady { self.pairWhenReady = false; self.pair() }
                    } else if status != "Stopped" {
                        self.stop(); self.error = status
                    }
                }
                try host.start(secret: key); server = host
                pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.generation == epoch else { return }
                        self.displays.expire()
                        await self.refreshDevices()
                        do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                    }
                }
            } catch {
                guard generation == epoch else { return }
                stop(); if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func stop() {
        appWindows.stop()
        generation = UUID(); startTask?.cancel(); startTask = nil; pollTask?.cancel(); pollTask = nil
        deviceRevision = UUID()
        pairingTasks.values.forEach { $0.cancel() }; pairingTasks.removeAll()
        remoteTunnel?.stop(); remoteTunnel = nil
        server?.onStatus = nil; server?.onDevices = nil; server?.stop(); server = nil; engine.stop()
        displays.stop()
        deviceStore?.cancelInvitation(); workspaceConnections = []; publishDevices()
        running = false; starting = false; status = "Stopped"; connections = 0
        invitation = nil; showPairing = false; pairWhenReady = false
    }
    func pair() {
        guard running else { pairWhenReady = true; start(); return }
        do {
            guard let secret, let deviceStore else { return }
            let remote = try remoteTunnel.map { try RemoteAccess(brokerURL: brokerURL, endpointID: $0.endpointID) }
            invitation = try PairingInvitation(host: address, name: name, secret: secret, enrollmentToken: deviceStore.createInvitation(), remoteAccess: remote); showPairing = true
        } catch { self.error = error.localizedDescription }
    }
    func resetPairing() {
        guard running, !changingDevices else { error = "Start the server and wait for device changes to finish before resetting pairing."; return }
        resettingPairing = true
        Task {
            defer { resettingPairing = false }
            do {
                // Revoke both video certificates and workspace keys as one operation.
                deviceRevision = UUID()
                try await engine.resetPairing()
                try deviceStore?.reset(); streamDevices = []
                // Close every transport before changing either stored credential.
                stop()
                let key = try SecureStore.randomKey(); try SecureStore.write(key, account: "server-key")
                try SecureStore.write(SecureStore.randomKey(), account: "server-remote-key")
                secret = key; start()
            } catch { self.error = error.localizedDescription }
        }
    }
    func refreshDevices() async {
        guard !refreshingDevices, removingDevice == nil, !resettingPairing else { return }
        refreshingDevices = true; defer { refreshingDevices = false }
        let epoch = generation, revision = deviceRevision
        do {
            let result: [StreamDevice]
            if running { result = try await engine.pairedDevices() }
            else { result = try engine.savedDevices() }
            guard generation == epoch, deviceRevision == revision else { return }
            streamDevices = result; devicesError = nil; publishDevices()
        } catch {
            guard generation == epoch, deviceRevision == revision else { return }
            devicesError = "Couldn’t refresh devices. Showing the last saved list. " + error.localizedDescription
        }
    }
    func removeDevice(_ device: ServerDevice) {
        guard running, !changingDevices, let deviceStore else { return }
        removingDevice = device.id; deviceRevision = UUID()
        invitation = nil; showPairing = false
        let epoch = generation
        Task {
            defer { removingDevice = nil }
            do {
                // Revoke workspace access before awaiting network calls. Other identities stay online.
                do { try deviceStore.remove(device.id, name: device.name) }
                catch { server?.disconnectDevice(device.id); remoteTunnel?.revoke(deviceID: device.id); throw error }
                server?.disconnectDevice(device.id)
                remoteTunnel?.revoke(deviceID: device.id)
                workspaceConnections.removeAll { $0.id == device.id }; publishDevices()
                // Let any in-flight PIN approval settle, then revoke every certificate for this exact identity.
                if let pending = pairingTasks[device.id] { _ = try? await pending.value }
                guard generation == epoch else { throw NocturneError.disconnected }
                let current = try await engine.pairedDevices()
                for stream in current where stream.fingerprint == device.id {
                    guard generation == epoch else { throw NocturneError.disconnected }
                    try await engine.removeDevice(stream.id)
                }
                guard generation == epoch else { throw NocturneError.disconnected }
                let remaining = current.filter { $0.fingerprint != device.id }
                try deviceStore.finishRemoval(device.id)
                streamDevices = remaining
                devicesError = nil; publishDevices()
            } catch {
                // Keep the row available for retry and never report a failed removal as successful.
                self.error = "Couldn’t fully remove \(device.name). " + error.localizedDescription
                devicesError = "Removal is incomplete. Try removing this device again."
                publishDevices()
            }
        }
    }
    private func publishDevices() {
        devices = ServerDevice.list(streams: streamDevices, workspaces: deviceStore?.devices ?? [], connections: workspaceConnections)
        for (id, name) in deviceStore?.pendingRemovals ?? [:] where !devices.contains(where: { $0.id == id }) {
            devices.append(.pendingRemoval(id: id, name: name))
        }
        if removingDevice == nil, deviceStore?.pendingRemovals.isEmpty == false { devicesError = "A device removal is incomplete. Select Remove to finish it." }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Only this folder will be available for file transfers."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let restart = active; stop(); sharedFolder = url
        UserDefaults.standard.set(url.path, forKey: "sharedFolder"); if restart { start() }
    }
    func revealFolder() {
        do { try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(sharedFolder) }
        catch { self.error = error.localizedDescription }
    }
    func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([engine.logURL]) }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane) { NSWorkspace.shared.open(url) }
    }
    private func updatePermissions() {
        UserDefaults.standard.set(terminalEnabled, forKey: "allowTerminal"); UserDefaults.standard.set(filesEnabled, forKey: "allowFiles")
        UserDefaults.standard.set(microphoneEnabled, forKey: "allowMicrophone")
        server?.updatePermissions(.init(terminal: terminalEnabled, files: filesEnabled, microphone: microphoneEnabled))
    }
    func installMicrophone() {
        guard !installingMicrophone else { return }
        installingMicrophone = true
        Task {
            defer { installingMicrophone = false }
            do {
                try await MicrophoneInstallation.install()
                microphoneInstalled = VirtualMicrophone.isInstalled
                microphoneInstallationMessage = "Installed. Restart your Mac before using Nocturne Microphone."
            } catch { self.error = error.localizedDescription }
        }
    }
    private static func localAddresses() -> [String] {
        var result: [String] = []; var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return result }; defer { freeifaddrs(first) }
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 { result.append(String(cString: buffer)) }
        }
        return Array(Set(result)).sorted()
    }
}
