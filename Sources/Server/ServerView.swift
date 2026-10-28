import SwiftUI
import CoreImage.CIFilterBuiltins
import NocturneKit
import NocturneHostKit
import NocturneMacClient

private struct ChatProviderSettingsView: View {
    @ObservedObject var model: ServerModel
    @State private var editing: ChatAgentConfiguration?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $model.chatsEnabled) {
                FeatureRow(icon: "bubble.left.and.bubble.right", title: L("Agent chats"),
                    subtitle: L("Let paired devices read and continue agent conversations. This switch applies immediately; agents can use files and tools on this Mac."))
            }.toggleStyle(.switch)
            Divider()
            Text(L("Chat providers")).font(.headline)
            ForEach(model.chatAgents) { agent in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name).font(.subheadline.weight(.medium))
                        Text(agent.transport == .codex ? "Codex App Server" : "Agent Client Protocol").font(.caption).foregroundStyle(MoonStyle.secondary)
                    }
                    Spacer()
                    Button(L("Edit…")) { editing = agent }.buttonStyle(NocturneGlassButtonStyle())
                    if !["codex", "claude"].contains(agent.id) {
                        Button(L("Remove"), systemImage: "minus.circle", role: .destructive) { model.removeChatAgent(agent.id) }.labelStyle(.iconOnly)
                    }
                }
            }
            Button(L("Add ACP provider…"), systemImage: "plus") {
                editing = ChatAgentConfiguration(name: "", executable: "")
            }.buttonStyle(NocturneGlassButtonStyle())
            Text(L("Install and sign in to each agent on this Mac. Codex uses your existing Codex history and login. Claude Code needs claude-agent-acp. Saving providers stops active replies; refresh Chats on your device afterward."))
                .font(.caption).foregroundStyle(MoonStyle.secondary)
            Divider()
            CodexVoiceSignInView(account: model.codexAccount,
                configuration: model.chatAgents.first { $0.transport == .codex }, directory: model.appliedSettings.sharedFolder)
        }
        .sheet(item: $editing) { agent in
            ChatAgentEditor(agent: agent) { try model.saveChatAgent($0) }
        }
    }
}

private struct CodexVoiceSignInView: View {
    @ObservedObject var account: CodexAccountController
    let configuration: ChatAgentConfiguration?
    let directory: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Codex live voice"), systemImage: "waveform").font(.headline)
            Text(L("Talk to Codex using your ChatGPT sign-in. Codex manages the connection and sign-in on this Mac."))
                .font(.caption).foregroundStyle(MoonStyle.secondary)
            Label(NocturneLocalization.message(account.status), systemImage: account.signedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .font(.caption)
            HStack {
                if account.awaitingLogin {
                    Button(L("Cancel sign-in")) { Task { await account.cancelLogin() } }
                } else {
                    if !account.signedIn {
                        Button(L("Sign in with ChatGPT")) {
                            Task { await account.login(configuration: configuration, directory: directory) { NSWorkspace.shared.open($0) } }
                        }
                    }
                    Button(L("Check sign-in")) { Task { await account.refresh(configuration: configuration, directory: directory) } }
                }
            }.disabled(account.busy)
            if let error = account.error { Text(NocturneLocalization.message(error)).font(.caption).foregroundStyle(.orange) }
        }
        .task { await account.refresh(configuration: configuration, directory: directory) }
        .onChange(of: configuration) { _, next in Task { await account.refresh(configuration: next, directory: directory) } }
        .onDisappear { account.close() }
    }
}

private struct ChatAgentEditor: View {
    @State var agent: ChatAgentConfiguration
    let save: (ChatAgentConfiguration) throws -> Void
    @State private var arguments = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(agent.name.isEmpty ? L("Add chat provider") : L("Edit %@", "\(agent.name)")).font(.title2.weight(.semibold))
            Form {
                TextField(L("Name"), text: $agent.name)
                TextField(L("Executable"), text: $agent.executable).autocorrectionDisabled()
                TextField(L("Working directory"), text: $agent.directory).autocorrectionDisabled()
                Text(L("Leave the directory empty to start new chats in your shared folder. Existing chats keep their project directory."))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent(L("Arguments")) {
                    TextEditor(text: $arguments).font(.system(.caption, design: .monospaced)).frame(height: 95)
                }
                Text(L("One argument per line. Enter an executable name or full path, without shell quotes. Custom providers must speak ACP v1 over stdio."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(NocturneLocalization.message(error)).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save")) {
                    agent.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    agent.executable = agent.executable.trimmingCharacters(in: .whitespacesAndNewlines)
                    agent.arguments = arguments.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    if agent.arguments.last == "" { agent.arguments.removeLast() }
                    do { try save(agent); dismiss() } catch { self.error = NocturneLocalization.message(error.localizedDescription) }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540).background { NocturneBackdrop() }
            .onAppear { arguments = agent.arguments.joined(separator: "\n") }
    }
}

struct ServerView: View {
    @ObservedObject var model: ServerModel
    @ObservedObject var client: MacClientModel
    @Environment(\.openWindow) private var openWindow
    @State private var reset = false
    @State private var deviceToRemove: ServerDevice?
    @State private var selected: String? = "Overview"
    @AppStorage("nocturne.server.onboardingComplete") private var onboardingComplete = false
    private var needsOnboarding: Bool {
        model.showOnboarding || (!onboardingComplete && model.devices.isEmpty)
    }
    var body: some View {
        Group {
            if needsOnboarding {
                ServerOnboardingView(model: model) { pair in
                    onboardingComplete = true
                    model.showOnboarding = false
                    if pair { model.pair() }
                }
                .safeAreaInset(edge: .bottom) {
                    Button(L("Connect to another Mac"), systemImage: "desktopcomputer") {
                        onboardingComplete = true; model.showOnboarding = false; selected = "Computers"
                    }.buttonStyle(NocturneGlassButtonStyle()).padding(.bottom, 16)
                }
            } else { workspace }
        }
        .sheet(isPresented: $model.showPairing) { if let invitation = model.invitation { ServerPairingView(invitation: invitation) } }
        .sheet(isPresented: $client.showAddHost) { MacAddHostView(client: client) }
        .alert("Nocturne", isPresented: Binding(get: { model.error != nil || (client.error != nil && !client.showAddHost) }, set: {
            if !$0 { model.error = nil; client.error = nil }
        })) {
            Button(L("OK")) { model.error = nil; client.error = nil }
        } message: { Text(NocturneLocalization.message(model.error ?? client.error ?? "")) }
        .task(id: needsOnboarding) { if !needsOnboarding { onboardingComplete = true } }
        .onChange(of: client.showAddHost, initial: true) { _, show in
            if show { onboardingComplete = true; model.showOnboarding = false; selected = "Computers" }
        }
        .onChange(of: client.session != nil) { _, connected in if connected { openWindow(id: "remote-desktop") } }
    }
    private var workspace: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section(L("This Mac")) {
                    Label(L("Overview"), systemImage: "square.grid.2x2").tag("Overview")
                    Label(L("Sharing"), systemImage: "folder").tag("Sharing")
                    Label(L("Devices"), systemImage: "ipad.and.iphone").tag("Devices")
                }
                Section(L("Connect")) {
                    Label(L("Computers"), systemImage: "desktopcomputer").tag("Computers")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Nocturne")
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    StatusPill(label: model.running ? L("Server online") : L("Server offline"), active: model.running)
                    Text(model.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(20)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            if selected == "Computers" { MacComputersView(client: client) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if selected == "Overview" || selected == nil { overview }
                        if selected == "Sharing" { sharing }
                        if selected == "Devices" { devices }
                    }.padding(32).frame(maxWidth: 950).frame(maxWidth: .infinity)
                }
                .background { NocturneBackdrop() }
                .navigationTitle(L(selected ?? "Overview"))
                .safeAreaInset(edge: .bottom) { if selected == "Sharing" { ServerApplySettingsView(model: model) } }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(L("Pair a device"), systemImage: "plus") { model.pair() }
                            .help(L("Pair an iPhone, iPad, or Mac"))
                    }
                }
            }
        }.navigationSplitViewStyle(.balanced).foregroundStyle(MoonStyle.silver)
            .confirmationDialog(L("Reset all device pairing?"), isPresented: $reset, titleVisibility: .visible) {
                Button(L("Reset pairing"), role: .destructive) { model.resetPairing() }
            } message: { Text(L("Every connected device will be disconnected. Old QR codes will stop working. Pair your devices again by scanning a new QR code.")) }
            .confirmationDialog(deviceToRemove.map { L("Remove %@?", $0.name) } ?? L("Remove this device?"), isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }), titleVisibility: .visible) {
                if let device = deviceToRemove {
                    Button(L("Remove device"), role: .destructive) { model.removeDevice(device); deviceToRemove = nil }
                }
            } message: {
                Text(L("This device will be disconnected and lose access to streaming, terminal, and files. It must pair again to reconnect. Your other devices keep their access."))
            }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 8) { MoonMark(size: 24); Text(L("NOCTURNE SERVER")).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(MoonStyle.secondary) }
                    Text(L("Your Mac.\nOn every screen.")).font(.system(size: 38, weight: .semibold, design: .rounded)).tracking(-1.2)
                    Text(L("Your Mac’s power, with a little more freedom.")).font(.system(size: 13)).foregroundStyle(MoonStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                LunarArtwork().frame(width: 170, height: 180)
            }
            MoonPanel {
                VStack(alignment: .leading, spacing: 19) {
                    HStack {
                        Label("Nocturne", systemImage: "network").font(.system(size: 16, weight: .semibold))
                        Spacer(); StatusPill(label: model.status, active: model.running)
                    }
                    Text(L("Stream your Mac, open a terminal, and move your files. One server, ready for every device."))
                        .font(.system(size: 13)).foregroundStyle(MoonStyle.secondary)
                    NocturneGlassGroup { HStack(spacing: 12) {
                        Button { selected = "Sharing" } label: { Label(L("Sharing settings"), systemImage: "slider.horizontal.3") }.buttonStyle(PrimaryButtonStyle())
                        if model.running { Button(L("Pair a device"), systemImage: "plus") { model.pair() }.buttonStyle(NocturneGlassButtonStyle()).controlSize(.large) }
                        Spacer()
                        if model.running { Text(LCount("%d connected", model.connections)).font(.system(size: 11)).foregroundStyle(MoonStyle.secondary) }
                    } }
                }
            }
            HStack(spacing: 14) {
                capability("display", L("Screen sharing"), model.appliedSettings.screenSharing ? model.screenSharingStatus : L("Off"))
                capability("terminal", L("Terminal"), model.appliedSettings.terminal ? L("Enabled") : L("Off"))
                capability("folder", L("Files"), model.appliedSettings.files ? L("Enabled") : L("Off"))
            }
            MoonPanel {
                VStack(alignment: .leading, spacing: 15) {
                    FeatureRow(icon: "checkmark.shield", title: L("Mac permissions"), subtitle: L("Screen and system audio recording power your stream. Accessibility lets you use a keyboard, mouse, or trackpad."))
                    NocturneGlassGroup {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { permissionButtons }
                            VStack(alignment: .leading, spacing: 10) { permissionButtons }
                        }.buttonStyle(NocturneGlassButtonStyle()).controlSize(.regular).font(.system(size: 11))
                    }
                }
            }
            HStack(spacing: 8) { Image(systemName: "lock.shield"); Text(model.settings.remoteAccess ? L("Encrypted connections, wherever you are.") : L("Local connection. Your computer stays yours.")) }.font(.system(size: 11)).foregroundStyle(MoonStyle.secondary)
        }
    }
    @ViewBuilder private var permissionButtons: some View {
        Button(L("Screen & audio"), systemImage: "arrow.up.right") { model.openPrivacy("ScreenCapture") }
        Button(L("Input access"), systemImage: "arrow.up.right") { model.openPrivacy(L("Accessibility")) }
        Button(L("Server log"), systemImage: "doc.text") { model.revealLog() }
    }
    private func capability(_ icon: String, _ title: String, _ detail: String) -> some View {
        MoonPanel {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 20, weight: .light)).foregroundStyle(MoonStyle.accent)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(MoonStyle.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var sharing: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L("Make room for your work.")).font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-1).padding(.vertical, 12)
            MoonPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(L("Screen sharing"), systemImage: "display").font(.headline)
                        Spacer()
                        Text(model.appliedSettings.screenSharing ? model.screenSharingStatus : L("Off")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.settings.headlessDisplay ? "Nocturne Display" : L("Connected Mac display")).font(.title3)
                    Text(model.displayStatus).font(.caption).foregroundStyle(MoonStyle.secondary)
                    if let message = model.screenSharingError {
                        Text(NocturneLocalization.message(message) + L(" Retrying automatically.")).font(.caption).foregroundStyle(.orange)
                    }
                    SettingsLink { Label(L("Display settings…"), systemImage: "slider.horizontal.3") }
                }
            }
            MoonPanel {
                VStack(spacing: 20) {
                    Toggle(isOn: $model.settings.screenSharing) { FeatureRow(icon: "display", title: L("Screen sharing"), subtitle: L("Start and keep screen and app sharing ready while Nocturne is open. Files and terminal work independently when this is off.")) }.toggleStyle(.switch)
                    Divider()
                    Toggle(isOn: $model.settings.terminal) { FeatureRow(icon: "terminal", title: L("Terminal"), subtitle: L("Shells keep running when devices disconnect. Applying changes closes all terminal tabs, including background shells.")) }.toggleStyle(.switch)
                    Divider()
                    Toggle(isOn: $model.settings.files) { FeatureRow(icon: "folder", title: L("File sharing"), subtitle: L("Allow paired devices to read and upload files in the folder below. Existing files are never overwritten.")) }.toggleStyle(.switch)
                }
            }
            MoonPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Label(L("Shared folder"), systemImage: "folder.badge.person.crop").font(.headline)
                    Text(model.settings.sharedFolder.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(MoonStyle.secondary).textSelection(.enabled)
                    NocturneGlassGroup { HStack(spacing: 12) { Button(L("Show in Finder"), systemImage: "arrow.up.right") { model.revealFolder() }; Button(L("Choose folder…"), systemImage: "folder") { model.chooseFolder() } }.buttonStyle(NocturneGlassButtonStyle()) }
                    Text(L("Choose a folder, then apply your changes to share it.")).font(.caption2).foregroundStyle(MoonStyle.secondary)
                }
            }
            MoonPanel { ChatProviderSettingsView(model: model) }
            MoonPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $model.settings.microphone) {
                        FeatureRow(icon: "mic", title: L("Client microphone"), subtitle: L("Let a paired iPhone or iPad send its microphone to voice chat on this Mac. Apply changes to update access."))
                    }.toggleStyle(.switch)
                    Text(L("In Discord or your game, choose Nocturne Microphone as the input device. Unmute with the microphone button while streaming; each new stream starts muted."))
                        .font(.caption).foregroundStyle(MoonStyle.secondary)
                    if model.microphoneInstalled {
                        Label(L("Nocturne Microphone is ready"), systemImage: "checkmark.circle").font(.caption)
                    } else {
                        Text(L("Install the audio input once, then restart your Mac. macOS will ask for administrator approval."))
                            .font(.caption).foregroundStyle(MoonStyle.secondary)
                        Button(model.installingMicrophone ? L("Installing…") : L("Install microphone input…"), systemImage: "arrow.down.circle") { model.installMicrophone() }
                            .buttonStyle(NocturneGlassButtonStyle()).disabled(model.installingMicrophone)
                    }
                    if let message = model.microphoneInstallationMessage { Text(message).font(.caption).foregroundStyle(MoonStyle.secondary) }
                }
            }
            Text(L("Apply changes to update sharing. Reconnect your devices after the server restarts.")).font(.caption).foregroundStyle(MoonStyle.secondary)
            MoonPanel {
                FeatureRow(icon: "gamecontroller", title: L("Controllers & Bluetooth input"), subtitle: L("Pair your accessories with your iPhone or iPad. Nocturne forwards keyboard, mouse, trackpad, and controller input. Mac gamepad emulation uses Virtual HID Broker when installed; keyboard and mouse require Accessibility permission."))
            }
        }
    }
    private var devices: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L("Better together.")).font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-1).padding(.vertical, 12)
            MoonPanel {
                VStack(alignment: .leading, spacing: 20) {
                    FeatureRow(icon: "ipad.and.iphone", title: LCount("%d active connections", model.connections), subtitle: L("One pairing connects streaming, terminal, and shared files on iPhone, iPad, and iPhone Duo."))
                    Button { model.pair() } label: { Label(L("Pair a device"), systemImage: "qrcode") }.buttonStyle(PrimaryButtonStyle())
                }
            }
            Text(L("Pair new devices by scanning this Mac’s QR code in Nocturne. No pairing code needs to be entered.")).font(.caption).foregroundStyle(MoonStyle.secondary)
            pairedDevices
            MoonPanel {
                VStack(alignment: .leading, spacing: 15) {
                    Label(L("A fresh start"), systemImage: "key").font(.headline)
                    Text(L("Remove all streaming certificates and rotate your workspace key. Existing connections close and old QR codes stop working."))
                        .font(.subheadline).foregroundStyle(MoonStyle.secondary).lineSpacing(4)
                    Button(L("Reset all pairing…"), role: .destructive) { reset = true }.buttonStyle(.plain).foregroundStyle(.orange).disabled(!model.running || model.changingDevices)
                }
            }
        }
    }
    private var pairedDevices: some View {
        MoonPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(L("Your devices"), systemImage: "ipad.and.iphone").font(.headline)
                    Text("\(model.devices.count)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if model.refreshingDevices { ProgressView().controlSize(.small) }
                    Button(L("Refresh"), systemImage: "arrow.clockwise") { Task { await model.refreshDevices() } }
                        .labelStyle(.iconOnly).buttonStyle(NocturneGlassButtonStyle())
                        .disabled(model.refreshingDevices || model.removingDevice != nil)
                }
                if let message = model.devicesError {
                    Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if model.devices.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "ipad.and.iphone").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                        Text(L("No paired devices yet")).font(.headline)
                        Text(L("Pair an iPhone or iPad to see it here.")).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 22)
                } else {
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider() }
                        HStack(spacing: 14) {
                            Image(systemName: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone")
                                .font(.system(size: 26, weight: .light)).foregroundStyle(MoonStyle.accent).frame(width: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(device.name).font(.headline).textSelection(.enabled)
                                Text(deviceFeatures(device)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            StatusPill(label: device.connected ? L("Connected") : !device.streamIDs.isEmpty && !device.streamingEnabled ? L("Disabled") : L("Paired"), active: device.connected)
                            if model.removingDevice == device.id {
                                ProgressView().controlSize(.small).frame(width: 74).accessibilityLabel(L("Removing %@", "\(device.name)"))
                            } else {
                                Button(L("Remove…"), role: .destructive) { deviceToRemove = device }
                                    .buttonStyle(NocturneGlassButtonStyle())
                                    .accessibilityLabel(L("Remove %@", "\(device.name)"))
                                    .disabled(!model.running || model.changingDevices)
                            }
                        }.padding(.vertical, 3)
                    }
                }
                Text(model.running ? L("Paired devices stay here when they disconnect. Connected indicates an open terminal and files connection.") : L("Start the server to see current connections or remove a device."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func deviceFeatures(_ device: ServerDevice) -> String {
        ([device.streamIDs.isEmpty ? nil : L("Streaming"), device.workspace ? L("Terminal & files") : nil].compactMap { $0 }).joined(separator: " · ")
    }
}
struct ServerPairingView: View {
    let invitation: PairingInvitation
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        VStack(spacing: 20) {
            HStack { Spacer(); Button(L("Done")) { dismiss() }.buttonStyle(NocturneGlassButtonStyle()).keyboardShortcut(.defaultAction) }
            Text(L("Meet your Mac.")).font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-1)
            Text(L("In Nocturne, choose Add host and scan this code.\nStreaming, terminal, and files connect together.")).font(.subheadline).foregroundStyle(MoonStyle.secondary).multilineTextAlignment(.center)
            if let image = qrImage {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 210, height: 210).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 18))
            }
            Text(invitation.name).font(.subheadline.weight(.medium)).foregroundStyle(MoonStyle.secondary)
            Button(copied ? L("Pairing code copied") : L("Copy pairing code"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(invitation.url.absoluteString, forType: .string)
                copied = true
            }.buttonStyle(NocturneGlassButtonStyle())
            Text(L("On another Mac, choose Computers → Add host and paste the code."))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(L("This code pairs one device and expires after five minutes.\nKeep it private. Remove devices individually in Devices.")).font(.caption2).foregroundStyle(MoonStyle.secondary).multilineTextAlignment(.center)
        }.padding(28).frame(width: 440).background { NocturneBackdrop() }.tint(MoonStyle.accent)
    }
    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(invitation.url.absoluteString.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
