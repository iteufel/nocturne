import SwiftUI
import NocturneKit

struct ClientSettingsView: View {
    @ObservedObject var model: ClientModel
    var showOnboarding: () -> Void = {}
    @ObservedObject private var attention = AgentAttentionCenter.shared
    @AppStorage("nocturne.appearance") private var appearance = NocturneAppearance.system
    var body: some View {
        Form {
            Section {
                NavigationLink { PairedHostsView(model: model) } label: {
                    HStack {
                        Label(L("Paired hosts"), systemImage: "desktopcomputer")
                        Spacer()
                        Text("\(model.pairedServers.servers.count)").foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("pairedHostsSettings")
            }.listRowBackground(MoonStyle.surface)
            Section(L("Agent attention")) {
                Toggle(L("Notifications for pending requests"), isOn: Binding(get: { attention.notificationsEnabled },
                    set: { enabled in Task { await attention.setNotifications(enabled) } }))
                Toggle(L("Live Activities"), isOn: Binding(get: { attention.activitiesEnabled }, set: attention.setActivities))
                Text(attention.status).font(.caption).foregroundStyle(MoonStyle.secondary)
                Text(L("Connected requests can show local alerts. Remote delivery needs a configured push server. Decisions require device authentication; open Chats to inspect request details."))
                    .font(.caption).foregroundStyle(MoonStyle.secondary)
            }.listRowBackground(MoonStyle.surface)
            Section(L("Appearance")) {
                Picker(L("Style"), selection: $appearance) {
                    ForEach(NocturneAppearance.allCases) { style in Text(style.title).tag(style) }
                }
            }.listRowBackground(MoonStyle.surface)
            Section {
                Toggle(L("Fill entire screen"), isOn: Binding(get: { model.preferences.fillEntireScreen }, set: model.setFillEntireScreen))
                    .accessibilityIdentifier("streamFillEntireScreen")
            } header: { Text(L("Stream display")) } footer: {
                Text(L("Off fits the stream inside the safe area, keeping content clear of the camera and rounded corners. On fills the screen, cropping edges when needed to preserve proportions. Swipe inward from the left edge while streaming to open Controls, or from the right edge to show the keyboard."))
            }.listRowBackground(MoonStyle.surface)
            Section(L("Picture & sound")) {
                Picker(L("Resolution"), selection: $model.preferences.resolution) { ForEach(["Match device", "720p", "1080p", "1440p", "4K"], id: \.self) { Text($0 == "Match device" ? L("Match device") : $0).tag($0) } }
                if model.preferences.resolution == "Match device" {
                    Text(L("Matches the Mac desktop to your display and follows rotation and window resizing. Enable Headless virtual monitor in Nocturne’s display settings and pair using its QR code. Video briefly reconnects when the size changes."))
                        .font(.caption).foregroundStyle(MoonStyle.secondary)
                }
                Picker(L("Frame rate"), selection: $model.preferences.frameRate) { Text(L("30 fps")).tag(30); Text(L("60 fps")).tag(60); Text(L("120 fps")).tag(120) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(L("Bitrate")); Spacer(); Text(L("%@ Mbps", model.preferences.bitrate.formatted())).monospacedDigit().foregroundStyle(MoonStyle.secondary) }
                    Slider(value: Binding(get: { Double(model.preferences.bitrate) }, set: { model.preferences.bitrate = Int($0) }), in: 5...150, step: 5)
                }
                Toggle(L("HDR when supported"), isOn: $model.preferences.hdr)
                Toggle(L("Smooth frame pacing"), isOn: $model.preferences.framePacing)
            }.listRowBackground(MoonStyle.surface)
            Section {
                Picker(L("Input mode"), selection: Binding(get: { model.preferences.inputMode }, set: model.setInputMode)) {
                    ForEach(StreamInputMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                }.accessibilityIdentifier("streamInputMode")
                Text(model.preferences.inputMode.explanation).font(.caption).foregroundStyle(MoonStyle.secondary)
                Toggle(L("Onscreen game controls"), isOn: $model.preferences.touchControls)
                Toggle(L("Multiple controllers"), isOn: $model.preferences.multiController)
                Toggle(L("Stream statistics"), isOn: $model.preferences.statistics)
            } header: { Text(L("Controls")) } footer: { Text(L("You can also change input mode from the stream controls menu. A three-finger tap opens the keyboard. Mouse and trackpad accessories work in either mode.")) }
                .listRowBackground(MoonStyle.surface)
            Section(L("Connected accessories")) {
                inputStatus(L("Keyboard"), symbol: "keyboard", connected: model.keyboardConnected)
                inputStatus(L("Mouse or trackpad"), symbol: "computermouse", connected: model.mouseConnected)
                if model.controllers.isEmpty { inputStatus(L("Game controller"), symbol: "gamecontroller", connected: false) }
                ForEach(Array(model.controllers.enumerated()), id: \.offset) { _, name in inputStatus(name, symbol: "gamecontroller.fill", connected: true) }
                Text(L("Pair Bluetooth accessories in iOS Settings. Nocturne forwards their input to your computer. Mac gamepad emulation requires a compatible host driver."))
                    .font(.caption).foregroundStyle(MoonStyle.secondary)
            }.listRowBackground(MoonStyle.surface)
            Section(L("Microphone")) {
                Label(L("Voice chat on your Mac"), systemImage: "mic")
                Text(L("Enable Client microphone in Nocturne → Sharing and install the microphone input. In Discord or your game, select Nocturne Microphone. Open Controls → Microphone in your stream to unmute."))
                    .font(.caption).foregroundStyle(MoonStyle.secondary)
                Text(L("Each stream starts muted. Backgrounding, disconnecting, resizing the stream, or changing audio devices mutes it again. Headphones are recommended; Bluetooth microphone use can reduce playback quality."))
                    .font(.caption).foregroundStyle(MoonStyle.secondary)
            }.listRowBackground(MoonStyle.surface)
            FilesIntegrationSettings(integration: model.filesIntegration, paired: model.savedServerName != nil) {
                Task { await model.reconnectServer() }
            }
            Section {
                Button(L("Welcome to Nocturne"), systemImage: "sparkles", action: showOnboarding)
                    .accessibilityIdentifier("replayOnboarding")
                FeatureRow(icon: "rectangle.expand.vertical", title: L("Room to move"), subtitle: L("Layouts follow your window on iPhone, iPad, and iPhone Duo. Expand for a sidebar; resize or fold back into a compact workspace."))
                Link(L("Moonlight open-source project"), destination: URL(string: "https://github.com/moonlight-stream/moonlight-ios")!)
                Text(L("Nocturne 1.0 · GPL-3.0\nBuilt on Moonlight and SwiftTerm. An independent project, not affiliated with Apple or the Moonlight team."))
                    .font(.caption2).foregroundStyle(MoonStyle.secondary)
            }.listRowBackground(MoonStyle.surface)
        }.scrollContentBackground(.hidden)
    }
    private func inputStatus(_ name: String, symbol: String, connected: Bool) -> some View {
        HStack { Label(name, systemImage: symbol); Spacer(); Text(connected ? L("Connected") : L("Not connected")).font(.caption).foregroundStyle(connected ? MoonStyle.mint : MoonStyle.secondary) }
    }
}
