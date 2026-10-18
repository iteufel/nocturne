import SwiftUI

@main
struct NocturneServerApp: App {
    @NSApplicationDelegateAdaptor(NocturneServerDelegate.self) private var delegate
    @AppStorage("nocturne.appearance") private var appearance = NocturneAppearance.system
    var body: some Scene {
        WindowGroup("Nocturne Server", id: "main") {
            ServerView(model: delegate.model).tint(MoonStyle.accent).preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 780, minHeight: 620)
        }.defaultSize(width: 1_040, height: 760).windowToolbarStyle(.unified)
        Settings {
            ServerSettingsView().tint(MoonStyle.accent).preferredColorScheme(appearance.colorScheme)
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
        Button(model.active ? "Stop server" : "Start server") { model.active ? model.stop() : model.start() }
        Button("Pair a device") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); model.pair() }
        Divider()
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Nocturne Server") { model.stop(); NSApp.terminate(nil) }
    }
}

struct ServerSettingsView: View {
    @AppStorage("nocturne.appearance") private var appearance = NocturneAppearance.system
    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(NocturneAppearance.allCases) { style in Text(style.title).tag(style) }
                }.pickerStyle(.segmented)
            } header: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            } footer: {
                Text("System follows your Mac’s Light or Dark appearance.")
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .background { NocturneBackdrop() }.frame(width: 480, height: 200)
    }
}
