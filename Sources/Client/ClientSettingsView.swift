import SwiftUI
import NocturneKit

struct ClientSettingsView: View {
    @ObservedObject var model: ClientModel
    var showOnboarding: () -> Void = {}
    @AppStorage("nocturne.appearance") private var appearance = NocturneAppearance.system
    var body: some View {
        Form {
            Section {
                NavigationLink { PairedHostsView(model: model) } label: {
                    HStack {
                        Label("Paired hosts", systemImage: "desktopcomputer")
                        Spacer()
                        Text("\(model.pairedServers.servers.count)").foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("pairedHostsSettings")
            }.listRowBackground(MoonStyle.surface)
            Section("Appearance") {
                Picker("Style", selection: $appearance) {
                    ForEach(NocturneAppearance.allCases) { style in Text(style.title).tag(style) }
                }
            }.listRowBackground(MoonStyle.surface)
            Section {
                Toggle("Fill entire screen", isOn: Binding(get: { model.preferences.fillEntireScreen }, set: model.setFillEntireScreen))
                    .accessibilityIdentifier("streamFillEntireScreen")
            } header: { Text("Stream display") } footer: {
                Text("Off fits the stream inside the safe area, keeping content clear of the camera and rounded corners. On fills the screen, cropping edges when needed to preserve proportions. Swipe inward from the right edge while streaming to open Controls.")
            }.listRowBackground(MoonStyle.surface)
            Section("Picture & sound") {
                Picker("Resolution", selection: $model.preferences.resolution) { ForEach(["Match device", "720p", "1080p", "1440p", "4K"], id: \.self) { Text($0) } }
                if model.preferences.resolution == "Match device" {
                    Text("Matches your computer’s desktop to your display and follows rotation and window resizing. Enable Headless virtual monitor in Nocturne Server’s display settings and pair using its QR code. Video briefly reconnects when the size changes.")
                        .font(.caption).foregroundStyle(MoonStyle.secondary)
                }
                Picker("Frame rate", selection: $model.preferences.frameRate) { Text("30 fps").tag(30); Text("60 fps").tag(60); Text("120 fps").tag(120) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Bitrate"); Spacer(); Text("\(model.preferences.bitrate) Mbps").monospacedDigit().foregroundStyle(MoonStyle.secondary) }
                    Slider(value: Binding(get: { Double(model.preferences.bitrate) }, set: { model.preferences.bitrate = Int($0) }), in: 5...150, step: 5)
                }
                Toggle("HDR when supported", isOn: $model.preferences.hdr)
                Toggle("Smooth frame pacing", isOn: $model.preferences.framePacing)
            }.listRowBackground(MoonStyle.surface)
            Section {
                Picker("Input mode", selection: Binding(get: { model.preferences.inputMode }, set: model.setInputMode)) {
                    ForEach(StreamInputMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                }.accessibilityIdentifier("streamInputMode")
                Text(model.preferences.inputMode.explanation).font(.caption).foregroundStyle(MoonStyle.secondary)
                Toggle("Onscreen game controls", isOn: $model.preferences.touchControls)
                Toggle("Multiple controllers", isOn: $model.preferences.multiController)
                Toggle("Stream statistics", isOn: $model.preferences.statistics)
            } header: { Text("Controls") } footer: { Text("You can also change input mode from the stream controls menu. A three-finger tap opens the keyboard. Mouse and trackpad accessories work in either mode.") }
                .listRowBackground(MoonStyle.surface)
            Section("Connected accessories") {
                inputStatus("Keyboard", symbol: "keyboard", connected: model.keyboardConnected)
                inputStatus("Mouse or trackpad", symbol: "computermouse", connected: model.mouseConnected)
                if model.controllers.isEmpty { inputStatus("Game controller", symbol: "gamecontroller", connected: false) }
                ForEach(Array(model.controllers.enumerated()), id: \.offset) { _, name in inputStatus(name, symbol: "gamecontroller.fill", connected: true) }
                Text("Pair Bluetooth accessories in iOS Settings. Nocturne forwards their input to your computer. Gamepad emulation requires a compatible host driver.")
                    .font(.caption).foregroundStyle(MoonStyle.secondary)
            }.listRowBackground(MoonStyle.surface)
            Section("Microphone") {
                Label("Voice chat on your computer", systemImage: "mic")
                Text("Enable Client microphone in Nocturne Server → Sharing and install the microphone input. In Discord or your game, select your host’s virtual microphone. Open Controls → Microphone in your stream to unmute.")
                    .font(.caption).foregroundStyle(MoonStyle.secondary)
                Text("Each stream starts muted. Backgrounding, disconnecting, resizing the stream, or changing audio devices mutes it again. Headphones are recommended; Bluetooth microphone use can reduce playback quality.")
                    .font(.caption).foregroundStyle(MoonStyle.secondary)
            }.listRowBackground(MoonStyle.surface)
            FilesIntegrationSettings(integration: model.filesIntegration, paired: model.savedServerName != nil) {
                Task { await model.reconnectServer() }
            }
            Section {
                Button("Welcome to Nocturne", systemImage: "sparkles", action: showOnboarding)
                    .accessibilityIdentifier("replayOnboarding")
                FeatureRow(icon: "rectangle.expand.vertical", title: "Room to move", subtitle: "Layouts follow your window on iPhone, iPad, and iPhone Duo. Expand for a sidebar; resize or fold back into a compact workspace.")
                Link("Moonlight open-source project", destination: URL(string: "https://github.com/moonlight-stream/moonlight-ios")!)
                Text("Nocturne 1.0 · GPL-3.0\nBuilt on Moonlight and SwiftTerm. An independent project, not affiliated with Apple or the Moonlight team.")
                    .font(.caption2).foregroundStyle(MoonStyle.secondary)
            }.listRowBackground(MoonStyle.surface)
        }.scrollContentBackground(.hidden)
    }
    private func inputStatus(_ name: String, symbol: String, connected: Bool) -> some View {
        HStack { Label(name, systemImage: symbol); Spacer(); Text(connected ? "Connected" : "Not connected").font(.caption).foregroundStyle(connected ? MoonStyle.mint : MoonStyle.secondary) }
    }
}
