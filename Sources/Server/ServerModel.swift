import AppKit
import SwiftUI
import NocturneKit
import NocturneHostKit
import SystemConfiguration
import ServiceManagement

struct ServerLoginItem {
    var status: () -> SMAppService.Status
    var setEnabled: (Bool) throws -> Void
    static let system = ServerLoginItem(status: { SMAppService.mainApp.status }, setEnabled: { enabled in
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    })
}

@MainActor
final class ServerModel: ObservableObject {
    private let defaults: UserDefaults
    private let loginItem: ServerLoginItem
    private let keyProvider: (String) throws -> Data
    private let engineExecutable: URL
    private let port: UInt16
    private let appWindows = AppWindowSessionManager(host: NativeAppWindowHost())
    private let desktop = DesktopSessionManager(host: NativeDesktopHost())
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var status = L("Stopped")
    @Published private(set) var connections = 0
    @Published private(set) var devices: [ServerDevice] = []
    @Published private(set) var devicesError: String?
    @Published private(set) var refreshingDevices = false
    @Published private(set) var removingDevice: String?
    @Published var error: String?
    @Published var showPairing = false
    @Published var showOnboarding = false
    @Published var invitation: PairingInvitation?
    @Published private(set) var resettingPairing = false
    var changingDevices: Bool { removingDevice != nil || resettingPairing }
    let codexAccount = CodexAccountController()
    @Published private(set) var chatAgents: [ChatAgentConfiguration]
    @Published var settings: ServerSettings
    @Published private(set) var appliedSettings: ServerSettings
    var chatsEnabled: Bool {
        get { settings.chats }
        set {
            settings.chats = newValue; appliedSettings.chats = newValue
            defaults.set(newValue, forKey: "allowChats")
            server?.updatePermissions(.init(terminal: appliedSettings.terminal, files: appliedSettings.files,
                microphone: appliedSettings.microphone, chats: newValue))
            if newValue { startEnabledServices() }
            else if !appliedSettings.hasEnabledServices { stop() }
        }
    }
    var hasSettingsChanges: Bool { settings != appliedSettings }
    @Published private(set) var loginApprovalRequired = false
    @Published private(set) var screenSharingStatus = L("Stopped")
    @Published private(set) var screenSharingError: String?
    @Published private(set) var microphoneInstalled = VirtualMicrophone.isInstalled
    @Published private(set) var installingMicrophone = false
    @Published private(set) var microphoneInstallationMessage: String?
    @Published private(set) var displayStatus = ""
    @Published private(set) var displayActive = false
    let displays: DisplaySessionManager
    let name = Host.current().localizedName ?? "My Mac"
    let engine: EmbeddedStreamingEngine
    var active: Bool { running || starting }
    private var server: WorkspaceServer?
    private var remoteTunnel: RemoteTunnel?
    private var deviceStore: WorkspaceDeviceStore?
    private var streamDevices: [StreamDevice] = []
    private var workspaceConnections: [WorkspaceDeviceConnection] = []
    private var pairingTasks: [String: Task<Void, Error>] = [:]
    private var deviceRevision = UUID()
    private var startTask: Task<Void, Never>?
    private var screenSharingTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var secret: Data?
    private var generation = UUID()
    private var pairWhenReady = false
    init(defaults: UserDefaults = .standard, supportDirectory: URL? = nil,
         engineExecutable: URL? = nil, port: UInt16 = WorkspaceProtocol.port,
         loginItem: ServerLoginItem = .system,
         keyProvider: @escaping (String) throws -> Data = { account in
             if let stored = try SecureStore.read(account) { return stored }
             let key = try SecureStore.randomKey(); try SecureStore.write(key, account: account); return key
         }) {
        self.defaults = defaults; self.loginItem = loginItem; self.keyProvider = keyProvider; self.port = port
        chatAgents = defaults.data(forKey: "chatAgents").flatMap { try? JSONDecoder().decode([ChatAgentConfiguration].self, from: $0) } ?? ChatAgentConfiguration.defaults
        self.engineExecutable = engineExecutable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/nocturne-stream-host")
        var saved = ServerSettings(defaults: defaults)
        let loginStatus = loginItem.status()
        saved.launchAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
        settings = saved; appliedSettings = saved
        loginApprovalRequired = loginStatus == .requiresApproval
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let engine = EmbeddedStreamingEngine(directory: support.appendingPathComponent("Nocturne/Engine", isDirectory: true))
        self.engine = engine
        displays = DisplaySessionManager { display in try await engine.selectDisplay(display) }
        do {
            deviceStore = try WorkspaceDeviceStore(url: support.appendingPathComponent("Nocturne/devices.json"))
            streamDevices = try engine.savedDevices(); publishDevices()
        } catch { devicesError = NocturneLocalization.message(error.localizedDescription) }
        engine.onUnexpectedExit = { [weak self] message in
            guard let self else { return }
            self.engine.stop()
            self.displays.stop()
            self.screenSharingStatus = L("Retrying…")
            self.screenSharingError = message
            self.maintainScreenSharing()
        }
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
            displayStatus = "\(size.width) × \(size.height) · \(displays.deviceName ?? L("Connected device"))"
        } else {
            displayStatus = appliedSettings.headlessDisplay ? L("Virtual monitor · Matches your device") : L("Physical monitor · Fixed desktop size")
        }
    }
    func start() {
        guard !active, appliedSettings.hasEnabledServices else { return }
        guard DisplaySessionManager.isSessionAvailable else { error = L("Sign in to this Mac before starting the server."); return }
        starting = true; status = L("Starting"); error = nil
        let epoch = UUID(); generation = epoch
        let configuration = appliedSettings
        startTask = Task { [self] in
            do {
                try Task.checkCancellation()
                guard generation == epoch else { return }
                guard let deviceStore else { throw NocturneError.remote(L("The saved device list could not be loaded. Restart Nocturne and try again.")) }
                let key = try keyProvider("server-key")
                guard key.count == 32 else { throw NocturneError.invalidInvitation }
                secret = key
                if configuration.remoteAccess {
                    // This private identity is never shared in a QR or derived from its shared key.
                    let endpointKey = try keyProvider("server-remote-key")
                    let tunnel = try await RemoteTunnel.host(brokerURL: configuration.brokerURL, endpointKey: endpointKey, port: port)
                    guard generation == epoch, !Task.isCancelled else { tunnel.stop(); return }
                    remoteTunnel = tunnel
                }
                // Chat grants can be revoked immediately while startup is pending.
                let permissions = HostPermissions(terminal: configuration.terminal, files: configuration.files,
                    microphone: configuration.microphone, chats: appliedSettings.chats)
                let host = try WorkspaceServer(folder: configuration.sharedFolder, name: name, devices: deviceStore, permissions: permissions, appWindows: configuration.screenSharing ? appWindows : nil, desktop: configuration.screenSharing ? desktop : nil, chatAgents: chatAgents)
                if let tunnel = remoteTunnel {
                    host.authorizeRemoteDevice = { [weak tunnel] port, device in
                        guard let tunnel else { throw NocturneError.disconnected }
                        try tunnel.authorize(sourcePort: port, deviceID: device)
                    }
                }
                if configuration.screenSharing && configuration.headlessDisplay {
                    host.displayCommand = { [weak self] packet, connection, name, completion in
                        Task { @MainActor in
                            guard let self, self.generation == epoch, self.running else { completion(packet.reply(error: NocturneError.disconnected.localizedDescription)); return }
                            guard self.engine.isReady else { completion(packet.reply(error: "Screen sharing is starting. Try again in a moment.")); return }
                            do { completion(try await self.displays.handle(packet, connection: connection, name: name)) }
                            catch { completion(packet.reply(error: error.localizedDescription)) }
                        }
                    }
                    host.displayDisconnected = { [weak self] connection in
                        Task { @MainActor in guard self?.generation == epoch else { return }; self?.displays.disconnected(connection) }
                    }
                }
                if configuration.screenSharing {
                    host.pairStream = { [weak self] pin, name, address, deviceID, completion in
                        Task { @MainActor in
                            guard let self, self.running, self.engine.isReady, self.generation == epoch, self.removingDevice != deviceID, !self.resettingPairing,
                                  self.pairingTasks[deviceID] == nil else { completion(NocturneError.disconnected); return }
                            let task = Task { try await self.engine.pairAuthorizedClient(pin: pin, name: name, address: address) }
                            self.pairingTasks[deviceID] = task
                            do { try await task.value; completion(nil) } catch { completion(error) }
                            guard self.generation == epoch else { return }
                            self.pairingTasks.removeValue(forKey: deviceID)
                            await self.refreshDevices()

                        }
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
                        self.running = true; self.starting = false; self.status = L("Ready")
                        self.maintainScreenSharing()
                        if self.pairWhenReady { self.pairWhenReady = false; self.pair() }
                    } else if status != "Stopped" {
                        self.stop(); self.error = status
                    }
                }
                try host.start(secret: key, port: port); server = host
                pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.generation == epoch else { return }
                        self.displays.expire()
                        self.maintainScreenSharing()
                        await self.refreshDevices()
                        do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                    }
                }
            } catch {
                guard generation == epoch else { return }
                stop(); if !(error is CancellationError) { self.error = NocturneLocalization.message(error.localizedDescription) }
            }
        }
    }
    func stop() {
        appWindows.stop()
        desktop.stop()
        generation = UUID(); startTask?.cancel(); startTask = nil; pollTask?.cancel(); pollTask = nil
        screenSharingTask?.cancel(); screenSharingTask = nil; screenSharingStatus = L("Stopped")
        screenSharingError = nil
        deviceRevision = UUID()
        pairingTasks.values.forEach { $0.cancel() }; pairingTasks.removeAll()
        remoteTunnel?.stop(); remoteTunnel = nil
        server?.onStatus = nil; server?.onDevices = nil; server?.stop(); server = nil; engine.stop()
        displays.stop()
        deviceStore?.cancelInvitation(); workspaceConnections = []; publishDevices()
        running = false; starting = false; status = L("Stopped"); connections = 0
        invitation = nil; showPairing = false; pairWhenReady = false
    }
    func pair() {
        guard appliedSettings.hasEnabledServices else {
            error = L("Enable a feature in Sharing and apply your changes before pairing a device.")
            return
        }
        guard running else { pairWhenReady = true; start(); return }
        do {
            guard let secret, let deviceStore else { return }
            let remote = try remoteTunnel.map { try RemoteAccess(brokerURL: appliedSettings.brokerURL, endpointID: $0.endpointID) }
            // Resolve on the client's network instead of asking users to choose an
            // interface or embedding an IP that becomes stale when networks change.
            guard let hostname = SCDynamicStoreCopyLocalHostName(nil) as String?, !hostname.isEmpty else {
                throw NocturneError.remote(L("Your Mac’s network name is unavailable. Check your network connection and try again."))
            }
            invitation = try PairingInvitation(host: hostname + ".local", port: port, name: name, secret: secret, enrollmentToken: deviceStore.createInvitation(), remoteAccess: remote); showPairing = true
        } catch { self.error = NocturneLocalization.message(error.localizedDescription) }
    }
    func resetPairing() {
        guard running, !changingDevices else { error = L("Start the server and wait for device changes to finish before resetting pairing."); return }
        resettingPairing = true
        Task {
            defer { resettingPairing = false }
            do {
                // Revoke both video certificates and workspace keys as one operation.
                deviceRevision = UUID()
                if engine.isRunning { try await engine.resetPairing() }
                else { try engine.resetSavedPairing() }
                try deviceStore?.reset(); streamDevices = []
                // Close every transport before changing either stored credential.
                stop()
                let key = try SecureStore.randomKey(); try SecureStore.write(key, account: "server-key")
                try SecureStore.write(SecureStore.randomKey(), account: "server-remote-key")
                secret = key; start()
            } catch { self.error = NocturneLocalization.message(error.localizedDescription) }
        }
    }
    func refreshDevices() async {
        guard !refreshingDevices, removingDevice == nil, !resettingPairing else { return }
        refreshingDevices = true; defer { refreshingDevices = false }
        let epoch = generation, revision = deviceRevision
        do {
            let result: [StreamDevice]
            if engine.isReady { result = try await engine.pairedDevices() }
            else { result = try engine.savedDevices() }
            guard generation == epoch, deviceRevision == revision else { return }
            streamDevices = result; devicesError = nil; publishDevices()
        } catch {
            guard generation == epoch, deviceRevision == revision else { return }
            devicesError = L("Couldn’t refresh devices. Showing the last saved list. ") + NocturneLocalization.message(error.localizedDescription)
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
                let current = try engine.isRunning ? await engine.pairedDevices() : engine.savedDevices()
                for stream in current where stream.fingerprint == device.id {
                    guard generation == epoch else { throw NocturneError.disconnected }
                    if engine.isRunning { try await engine.removeDevice(stream.id) }
                    else { try engine.removeSavedDevice(stream.id) }
                }
                guard generation == epoch else { throw NocturneError.disconnected }
                let remaining = current.filter { $0.fingerprint != device.id }
                try deviceStore.finishRemoval(device.id)
                streamDevices = remaining
                devicesError = nil; publishDevices()
            } catch {
                // Keep the row available for retry and never report a failed removal as successful.
                self.error = L("Couldn’t fully remove %@. ", "\(device.name)") + NocturneLocalization.message(error.localizedDescription)
                devicesError = L("Removal is incomplete. Try removing this device again.")
                publishDevices()
            }
        }
    }
    private func publishDevices() {
        devices = ServerDevice.list(streams: streamDevices, workspaces: deviceStore?.devices ?? [], connections: workspaceConnections)
        for (id, name) in deviceStore?.pendingRemovals ?? [:] where !devices.contains(where: { $0.id == id }) {
            devices.append(.pendingRemoval(id: id, name: name))
        }
        if removingDevice == nil, deviceStore?.pendingRemovals.isEmpty == false { devicesError = L("A device removal is incomplete. Select Remove to finish it.") }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = L("Only this folder will be available for file transfers.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.sharedFolder = url
    }
    func revealFolder() {
        do { try FileManager.default.createDirectory(at: settings.sharedFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(settings.sharedFolder) }
        catch { self.error = NocturneLocalization.message(error.localizedDescription) }
    }
    func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([engine.logURL]) }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane) { NSWorkspace.shared.open(url) }
    }
    func saveChatAgent(_ agent: ChatAgentConfiguration) throws {
        try agent.validate()
        var agents = chatAgents
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent } else { agents.append(agent) }
        guard agents.count <= 24 else { throw NocturneError.remote(L("Configure up to 24 chat providers.")) }
        try persistChatAgents(agents)
    }
    func removeChatAgent(_ id: String) {
        guard !["codex", "claude"].contains(id) else { return }
        do { try persistChatAgents(chatAgents.filter { $0.id != id }) } catch { self.error = NocturneLocalization.message(error.localizedDescription) }
    }
    private func persistChatAgents(_ agents: [ChatAgentConfiguration]) throws {
        let data = try JSONEncoder().encode(agents)
        defaults.set(data, forKey: "chatAgents"); chatAgents = agents
        server?.updateChatAgents(agents)
    }
    func startEnabledServices() { if appliedSettings.hasEnabledServices { start() } }
    func refreshLoginItem() {
        let status = loginItem.status()
        loginApprovalRequired = status == .requiresApproval
        let enabled = status == .enabled || loginApprovalRequired
        if settings.launchAtLogin == appliedSettings.launchAtLogin { settings.launchAtLogin = enabled }
        appliedSettings.launchAtLogin = enabled
    }
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    func discardSettings() { settings = appliedSettings }
    func applySettings() {
        guard hasSettingsChanges, !changingDevices else { return }
        do {
            let configuration = try settings.validated()
            if configuration.launchAtLogin != appliedSettings.launchAtLogin {
                try loginItem.setEnabled(configuration.launchAtLogin)
            }
            let restart = active
            configuration.save(defaults: defaults)
            appliedSettings = configuration; settings = configuration
            refreshLoginItem()
            if restart { stop() }
            updateDisplayStatus()
            startEnabledServices()
        } catch { self.error = NocturneLocalization.message(error.localizedDescription) }
    }
    private func maintainScreenSharing() {
        guard running, appliedSettings.screenSharing, screenSharingTask == nil, !engine.isRunning else { return }
        let epoch = generation, configuration = appliedSettings
        screenSharingTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == epoch { self.screenSharingTask = nil } }
            while self.generation == epoch, !Task.isCancelled {
                do {
                    self.screenSharingStatus = L("Starting…")
                    var captureDisplay = configuration.display.isEmpty ? String(CGMainDisplayID()) : configuration.display
                    if configuration.headlessDisplay {
                        self.displays.disablePhysicalDisplays = configuration.disablePhysicalDisplays
                        captureDisplay = String(try await self.displays.start())
                    }
                    try Task.checkCancellation()
                    guard self.generation == epoch else { return }
                    try await self.engine.start(executable: self.engineExecutable, name: self.name, display: captureDisplay)
                    try Task.checkCancellation()
                    guard self.generation == epoch else { return }
                    if configuration.headlessDisplay {
                        self.displays.restore()
                        if let failure = self.displays.lastError { throw NocturneError.remote(failure) }
                    }
                    self.screenSharingStatus = CGPreflightScreenCaptureAccess() ? L("Ready") : L("Allow screen capture")
                    self.screenSharingError = nil
                    await self.refreshDevices()
                    return
                } catch {
                    guard self.generation == epoch, !Task.isCancelled else { return }
                    self.engine.stop(); self.displays.stop()
                    self.screenSharingStatus = L("Retrying…")
                    self.screenSharingError = NocturneLocalization.message(error.localizedDescription)
                }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
    func installMicrophone() {
        guard !installingMicrophone else { return }
        installingMicrophone = true
        Task {
            defer { installingMicrophone = false }
            do {
                try await MicrophoneInstallation.install()
                microphoneInstalled = VirtualMicrophone.isInstalled
                microphoneInstallationMessage = L("Installed. Restart your Mac before using Nocturne Microphone.")
            } catch { self.error = NocturneLocalization.message(error.localizedDescription) }
        }
    }
}
