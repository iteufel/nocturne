import SwiftUI
import NocturneHostKit

@main
enum NocturneServerMain {
    @MainActor static func main() {
        if !DisplayControlProcess.runIfRequested() { NocturneServerApp.main() }
    }
}

struct NocturneServerApp: App {
    @NSApplicationDelegateAdaptor(NocturneServerDelegate.self) private var delegate
    @AppStorage("nocturne.appearance") private var appearance = NocturneAppearance.system
    var body: some Scene {
        WindowGroup("Nocturne Server", id: "main") {
            ServerView(model: delegate.model).tint(MoonStyle.accent).preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 780, minHeight: 620)
        }.defaultSize(width: 1_040, height: 760).windowToolbarStyle(.unified)
        Settings {
            ServerSettingsView(model: delegate.model).tint(MoonStyle.accent).preferredColorScheme(appearance.colorScheme)
        }
        MenuBarExtra("Nocturne Server", systemImage: "moon.fill") {
            ServerMenu(model: delegate.model)
        }
    }
}

@MainActor
final class NocturneServerDelegate: NSObject, NSApplicationDelegate {
    let model = ServerModel()
    // The app owns the server even after its last window closes.
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

struct ServerMenu: View {
    @ObservedObject var model: ServerModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.running ? "\(model.connections) connected devices" : "Server stopped")
        Button("Open Nocturne Server") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Welcome to Nocturne…") {
            model.showOnboarding = true
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }
        Button(model.active ? "Stop server" : "Start server") { model.active ? model.stop() : model.start() }
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
    @AppStorage("nocturne.appearance") private var appearance = NocturneAppearance.system
    var body: some View {
        Form {
            Section {
                Toggle("Connect over the internet", isOn: $model.remoteAccessEnabled).disabled(model.active)
                if model.remoteAccessEnabled {
                    TextField("Broker URL", text: $model.brokerURL, prompt: Text("https://nocturne.alkal.de"))
                        .disabled(model.active)
                }
            } header: {
                Label("Remote access", systemImage: "network")
            } footer: {
                Text("Use the default Nocturne broker or enter your own to connect from other networks. Devices try peer to peer and use an encrypted relay when needed. After enabling this, scan a new pairing QR code on your device. Stop the server to change these settings.")
            }
            Section {
                Toggle("Headless virtual monitor", isOn: $model.headlessDisplayEnabled)
                    .disabled(model.active || (!model.headlessDisplayEnabled && !DisplaySessionManager.isSupported))
                if model.headlessDisplayEnabled {
                    LabeledContent("Resolution", value: "Matches the streaming device")
                } else {
                    Picker("Stream display", selection: $model.display) {
                        Text("Main display").tag("")
                        ForEach(NSScreen.screens.filter { $0.localizedName != "Nocturne Display" }, id: \.self) { screen in
                            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                                Text(screen.localizedName).tag(number.stringValue)
                            }
                        }
                    }.disabled(model.active)
                }
                Toggle("Turn off connected Mac displays", isOn: $model.disablePhysicalDisplays)
                    .disabled(model.active || !model.headlessDisplayEnabled || !DisplaySessionManager.canDisableDisplays)
                if model.displayActive {
                    LabeledContent("Streaming", value: model.displayStatus)
                    Button("Restore Mac displays") { model.displays.restore() }
                }
            } header: {
                Label("Displays", systemImage: "display.2")
            } footer: {
                Text("The virtual monitor works with or without a physical screen and adapts to your device. Connected displays keep their layout unless you separately enable turning them off. Stop the server to change these settings.")
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
            .background { NocturneBackdrop() }.frame(width: 540, height: 620)
    }
}
