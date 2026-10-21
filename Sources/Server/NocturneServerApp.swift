import SwiftUI
import NocturneHostKit
import NocturneMacClient

@main
enum NocturneServerMain {
    @MainActor static func main() {
        guard !DisplayControlProcess.runIfRequested() else { return }
        // The bundle defaults to an agent so its embedded streaming executable
        // never registers a second Dock icon. Only the main app owns the UI.
        NSApplication.shared.setActivationPolicy(.regular)
        NocturneServerApp.main()
    }
}

struct NocturneServerApp: App {
    @NSApplicationDelegateAdaptor(NocturneServerDelegate.self) private var delegate
    @AppStorage("nocturne.appearance") private var appearance = NocturneAppearance.system
    var body: some Scene {
        WindowGroup("Nocturne Server", id: "main") {
            ServerView(model: delegate.model, client: delegate.client).tint(MoonStyle.accent).preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 780, minHeight: 620)
        }.defaultSize(width: 1_040, height: 760).windowToolbarStyle(.unified)
        Window("Remote desktop", id: "remote-desktop") {
            MacDesktopWindow(client: delegate.client)
                .frame(minWidth: 640, minHeight: 400)
        }.defaultSize(width: 1_280, height: 800).windowToolbarStyle(.unified)
        Settings {
            ServerSettingsView(model: delegate.model).tint(MoonStyle.accent).preferredColorScheme(appearance.colorScheme)
        }
        MenuBarExtra("Nocturne Server", systemImage: "moon.fill") {
            ServerMenu(model: delegate.model, client: delegate.client)
        }
    }
}

@MainActor
final class NocturneServerDelegate: NSObject, NSApplicationDelegate {
    let model = ServerModel()
    let client = MacClientModel()
    func applicationDidFinishLaunching(_ notification: Notification) { model.startEnabledServices() }
    // The app owns the server even after its last window closes.
    func applicationWillTerminate(_ notification: Notification) { client.disconnect(); model.stop() }
}

private struct MacDesktopWindow: View {
    @ObservedObject var client: MacClientModel
    var body: some View {
        if let stream = client.session { MacDesktopWorkspace(stream: stream, client: client) }
        else { ContentUnavailableView("No Mac connected", systemImage: "desktopcomputer", description: Text("Choose a host in Computers to open its desktop.")) }
    }
}

struct ServerMenu: View {
    @ObservedObject var model: ServerModel
    @ObservedObject var client: MacClientModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.running ? "\(model.connections) connected devices" : "Sharing off")
        Button("Open Nocturne Server") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Connect to a Mac…") {
            client.showAddHost = true
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }.disabled(client.session != nil)
        if client.session != nil {
            Button("Show remote desktop") { openWindow(id: "remote-desktop"); NSApp.activate(ignoringOtherApps: true) }
            Button("Disconnect remote desktop") { client.disconnect() }
        }
        Button("Welcome to Nocturne…") {
            model.showOnboarding = true
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }
        Button("Pair a device") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); model.pair() }
        Button("Restore Mac displays") { model.displays.restore() }.disabled(!model.displayActive && model.displays.lastError == nil)
        Divider()
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Nocturne Server") { model.stop(); NSApp.terminate(nil) }
    }
}

struct ServerSettingsView: View {
    @ObservedObject var model: ServerModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("nocturne.appearance") private var appearance = NocturneAppearance.system
    var body: some View {
        Form {
            Section {
                Toggle("Open Nocturne at login", isOn: $model.settings.launchAtLogin)
                if model.loginApprovalRequired {
                    Text("Allow Nocturne in Login Items to finish enabling automatic startup.").foregroundStyle(.secondary)
                    Button("Open Login Items…") { model.openLoginItems() }
                }
            } header: {
                Label("Startup", systemImage: "power")
            } footer: {
                Text("Open Nocturne when you sign in. The toggles in Sharing control which services run. Closing the window keeps enabled services running in the menu bar.")
            }
            Section {
                Toggle("Connect over the internet", isOn: $model.settings.remoteAccess)
                if model.settings.remoteAccess {
                    TextField("Broker URL", text: $model.settings.brokerURL, prompt: Text("https://nocturne.alkal.de"))
                }
            } header: {
                Label("Remote access", systemImage: "network")
            } footer: {
                Text("Use the default Nocturne broker or enter your own to connect from other networks. Devices try peer to peer and use an encrypted relay when needed. After enabling this, scan a new pairing QR code on your device.")
            }
            Section {
                Toggle("Headless virtual monitor", isOn: $model.settings.headlessDisplay)
                    .disabled(!model.settings.screenSharing || (!model.settings.headlessDisplay && !DisplaySessionManager.isSupported))
                if model.settings.headlessDisplay {
                    LabeledContent("Resolution", value: "Matches the streaming device")
                } else {
                    Picker("Stream display", selection: $model.settings.display) {
                        Text("Main display").tag("")
                        ForEach(NSScreen.screens.filter { $0.localizedName != "Nocturne Display" }, id: \.self) { screen in
                            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                                Text(screen.localizedName).tag(number.stringValue)
                            }
                        }
                    }.disabled(!model.settings.screenSharing)
                }
                Toggle("Turn off connected Mac displays", isOn: $model.settings.disablePhysicalDisplays)
                    .disabled(!model.settings.screenSharing || !model.settings.headlessDisplay || !DisplaySessionManager.canDisableDisplays)
                if model.displayActive {
                    LabeledContent("Streaming", value: model.displayStatus)
                    Button("Restore Mac displays") { model.displays.restore() }
                }
            } header: {
                Label("Displays", systemImage: "display.2")
            } footer: {
                Text("The virtual monitor works with or without a physical screen and adapts to your device. Connected displays keep their layout unless you separately enable turning them off. Apply changes to restart a running server.")
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(NocturneAppearance.allCases) { style in Text(style.title).tag(style) }
                }.pickerStyle(.segmented)
            } header: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            } footer: {
                Text("System follows your Mac’s Light or Dark appearance.")
            }
            Section("Getting started") {
                Button("Welcome to Nocturne…") {
                    model.showOnboarding = true
                    openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { ServerApplySettingsView(model: model) }
            .background { NocturneBackdrop() }.frame(width: 560, height: 720)
            .onAppear { model.refreshLoginItem() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshLoginItem() } }
            .alert("Nocturne Server", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

struct ServerApplySettingsView: View {
    @ObservedObject var model: ServerModel
    private var actionTitle: String {
        if model.settings.hasEnabledServices { return model.active ? "Apply & restart" : "Apply & start" }
        return model.active ? "Apply & stop" : "Apply"
    }
    private var changesMessage: String {
        guard model.hasSettingsChanges else { return "All changes applied." }
        if model.active {
            return model.settings.hasEnabledServices
                ? "Applying restarts the server and disconnects current sessions."
                : "Applying stops sharing and disconnects current sessions."
        }
        return model.settings.hasEnabledServices ? "Applying starts the enabled sharing services." : "You have unapplied changes."
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(changesMessage)
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button("Discard") { model.discardSettings() }.disabled(!model.hasSettingsChanges)
            Button(actionTitle) { model.applySettings() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasSettingsChanges || model.changingDevices)
        }.padding(16).background(.bar)
    }
}
