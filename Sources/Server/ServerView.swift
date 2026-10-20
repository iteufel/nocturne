import SwiftUI
import CoreImage.CIFilterBuiltins
import NocturneKit
import NocturneHostKit

struct ServerView: View {
    @ObservedObject var model: ServerModel
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
            } else { workspace }
        }
        .sheet(isPresented: $model.showPairing) { if let invitation = model.invitation { ServerPairingView(invitation: invitation) } }
        .alert("Nocturne Server", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .task(id: needsOnboarding) { if !needsOnboarding { onboardingComplete = true } }
    }
    private var workspace: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section("This Mac") {
                    Label("Overview", systemImage: "square.grid.2x2").tag("Overview")
                    Label("Sharing", systemImage: "folder").tag("Sharing")
                    Label("Devices", systemImage: "ipad.and.iphone").tag("Devices")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Nocturne")
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    StatusPill(label: model.running ? "Server online" : "Server offline", active: model.running)
                    Text(model.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(20)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if selected == "Overview" || selected == nil { overview }
                    if selected == "Sharing" { sharing }
                    if selected == "Devices" { devices }
                }.padding(32).frame(maxWidth: 950).frame(maxWidth: .infinity)
            }
            .background { NocturneBackdrop() }
            .navigationTitle(selected ?? "Overview")
            .safeAreaInset(edge: .bottom) { if selected == "Sharing" { ServerApplySettingsView(model: model) } }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Pair a device", systemImage: "plus") { model.pair() }
                        .help("Pair an iPhone or iPad")
                }
            }
        }.navigationSplitViewStyle(.balanced).foregroundStyle(MoonStyle.silver)
            .confirmationDialog("Reset all device pairing?", isPresented: $reset, titleVisibility: .visible) {
                Button("Reset pairing", role: .destructive) { model.resetPairing() }
            } message: { Text("Every connected device will be disconnected. Old QR codes will stop working. Pair your devices again by scanning a new QR code.") }
            .confirmationDialog("Remove \(deviceToRemove?.name ?? "device")?", isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }), titleVisibility: .visible) {
                if let device = deviceToRemove {
                    Button("Remove device", role: .destructive) { model.removeDevice(device); deviceToRemove = nil }
                }
            } message: {
                Text("This device will be disconnected and lose access to streaming, terminal, and files. It must pair again to reconnect. Your other devices keep their access.")
            }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 8) { MoonMark(size: 24); Text("NOCTURNE SERVER").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(MoonStyle.secondary) }
                    Text("Your Mac.\nOn every screen.").font(.system(size: 38, weight: .semibold, design: .rounded)).tracking(-1.2)
                    Text("Your Mac’s power, with a little more freedom.").font(.system(size: 13)).foregroundStyle(MoonStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                LunarArtwork().frame(width: 170, height: 180)
            }
            MoonPanel {
                VStack(alignment: .leading, spacing: 19) {
                    HStack {
                        Label("Nocturne Server", systemImage: "network").font(.system(size: 16, weight: .semibold))
                        Spacer(); StatusPill(label: model.status, active: model.running)
                    }
                    Text("Stream your Mac, open a terminal, and move your files. One server, ready for every device.")
                        .font(.system(size: 13)).foregroundStyle(MoonStyle.secondary)
                    NocturneGlassGroup { HStack(spacing: 12) {
                        Button { selected = "Sharing" } label: { Label("Sharing settings", systemImage: "slider.horizontal.3") }.buttonStyle(PrimaryButtonStyle())
                        if model.running { Button("Pair a device", systemImage: "plus") { model.pair() }.buttonStyle(NocturneGlassButtonStyle()).controlSize(.large) }
                        Spacer()
                        if model.running { Text("\(model.connections) connected").font(.system(size: 11)).foregroundStyle(MoonStyle.secondary) }
                    } }
                }
            }
            HStack(spacing: 14) {
                capability("display", "Screen sharing", model.appliedSettings.screenSharing ? model.screenSharingStatus : "Off")
                capability("terminal", "Terminal", model.appliedSettings.terminal ? "Enabled" : "Off")
                capability("folder", "Files", model.appliedSettings.files ? "Enabled" : "Off")
            }
            MoonPanel {
                VStack(alignment: .leading, spacing: 15) {
                    FeatureRow(icon: "checkmark.shield", title: "Mac permissions", subtitle: "Screen and system audio recording power your stream. Accessibility lets you use a keyboard, mouse, or trackpad.")
                    NocturneGlassGroup {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { permissionButtons }
                            VStack(alignment: .leading, spacing: 10) { permissionButtons }
                        }.buttonStyle(NocturneGlassButtonStyle()).controlSize(.regular).font(.system(size: 11))
                    }
                }
            }
            HStack(spacing: 8) { Image(systemName: "lock.shield"); Text(model.settings.remoteAccess ? "Encrypted connections, wherever you are." : "Local connection. Your computer stays yours.") }.font(.system(size: 11)).foregroundStyle(MoonStyle.secondary)
        }
    }
    @ViewBuilder private var permissionButtons: some View {
        Button("Screen & audio", systemImage: "arrow.up.right") { model.openPrivacy("ScreenCapture") }
        Button("Input access", systemImage: "arrow.up.right") { model.openPrivacy("Accessibility") }
        Button("Server log", systemImage: "doc.text") { model.revealLog() }
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
            Text("Make room for your work.").font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-1).padding(.vertical, 12)
            MoonPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Screen sharing", systemImage: "display").font(.headline)
                        Spacer()
                        Text(model.appliedSettings.screenSharing ? model.screenSharingStatus : "Off").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.settings.headlessDisplay ? "Nocturne Display" : "Connected Mac display").font(.title3)
                    Text(model.displayStatus).font(.caption).foregroundStyle(MoonStyle.secondary)
                    if let message = model.screenSharingError {
                        Text(message + " Retrying automatically.").font(.caption).foregroundStyle(.orange)
                    }
                    SettingsLink { Label("Display settings…", systemImage: "slider.horizontal.3") }
                }
            }
            MoonPanel {
                VStack(spacing: 20) {
                    Toggle(isOn: $model.settings.screenSharing) { FeatureRow(icon: "display", title: "Screen sharing", subtitle: "Start and keep screen and app sharing ready while Nocturne is open. Files and terminal work independently when this is off.") }.toggleStyle(.switch)
                    Divider()
                    Toggle(isOn: $model.settings.terminal) { FeatureRow(icon: "terminal", title: "Terminal", subtitle: "Shells keep running when devices disconnect. Applying changes closes all terminal tabs, including background shells.") }.toggleStyle(.switch)
                    Divider()
                    Toggle(isOn: $model.settings.files) { FeatureRow(icon: "folder", title: "File sharing", subtitle: "Allow paired devices to read and upload files in the folder below. Existing files are never overwritten.") }.toggleStyle(.switch)
                }
            }
            MoonPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Shared folder", systemImage: "folder.badge.person.crop").font(.headline)
                    Text(model.settings.sharedFolder.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(MoonStyle.secondary).textSelection(.enabled)
                    NocturneGlassGroup { HStack(spacing: 12) { Button("Show in Finder", systemImage: "arrow.up.right") { model.revealFolder() }; Button("Choose folder…", systemImage: "folder") { model.chooseFolder() } }.buttonStyle(NocturneGlassButtonStyle()) }
                    Text("Choose a folder, then apply your changes to share it.").font(.caption2).foregroundStyle(MoonStyle.secondary)
                }
            }
            MoonPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $model.settings.microphone) {
                        FeatureRow(icon: "mic", title: "Client microphone", subtitle: "Let a paired iPhone or iPad send its microphone to voice chat on this Mac. Apply changes to update access.")
                    }.toggleStyle(.switch)
                    Text("In Discord or your game, choose Nocturne Microphone as the input device. Unmute with the microphone button while streaming; each new stream starts muted.")
                        .font(.caption).foregroundStyle(MoonStyle.secondary)
                    if model.microphoneInstalled {
                        Label("Nocturne Microphone is ready", systemImage: "checkmark.circle").font(.caption)
                    } else {
                        Text("Install the audio input once, then restart your Mac. macOS will ask for administrator approval.")
                            .font(.caption).foregroundStyle(MoonStyle.secondary)
                        Button(model.installingMicrophone ? "Installing…" : "Install microphone input…", systemImage: "arrow.down.circle") { model.installMicrophone() }
                            .buttonStyle(NocturneGlassButtonStyle()).disabled(model.installingMicrophone)
                    }
                    if let message = model.microphoneInstallationMessage { Text(message).font(.caption).foregroundStyle(MoonStyle.secondary) }
                }
            }
            Text("Apply changes to update sharing. Reconnect your devices after the server restarts.").font(.caption).foregroundStyle(MoonStyle.secondary)
            MoonPanel {
                FeatureRow(icon: "gamecontroller", title: "Controllers & Bluetooth input", subtitle: "Pair your accessories with your iPhone or iPad. Nocturne forwards keyboard, mouse, trackpad, and controller input. Mac gamepad emulation uses Virtual HID Broker when installed; keyboard and mouse require Accessibility permission.")
            }
        }
    }
    private var devices: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Better together.").font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-1).padding(.vertical, 12)
            MoonPanel {
                VStack(alignment: .leading, spacing: 20) {
                    FeatureRow(icon: "ipad.and.iphone", title: "\(model.connections) active connections", subtitle: "One pairing connects streaming, terminal, and shared files on iPhone, iPad, and iPhone Duo.")
                    Button { model.pair() } label: { Label("Pair a device", systemImage: "qrcode") }.buttonStyle(PrimaryButtonStyle())
                }
            }
            Text("Pair new devices by scanning this Mac’s QR code in Nocturne. No pairing code needs to be entered.").font(.caption).foregroundStyle(MoonStyle.secondary)
            pairedDevices
            MoonPanel {
                VStack(alignment: .leading, spacing: 15) {
                    Label("A fresh start", systemImage: "key").font(.headline)
                    Text("Remove all streaming certificates and rotate your workspace key. Existing connections close and old QR codes stop working.")
                        .font(.subheadline).foregroundStyle(MoonStyle.secondary).lineSpacing(4)
                    Button("Reset all pairing…", role: .destructive) { reset = true }.buttonStyle(.plain).foregroundStyle(.orange).disabled(!model.running || model.changingDevices)
                }
            }
        }
    }
    private var pairedDevices: some View {
        MoonPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Your devices", systemImage: "ipad.and.iphone").font(.headline)
                    Text("\(model.devices.count)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if model.refreshingDevices { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshDevices() } }
                        .labelStyle(.iconOnly).buttonStyle(NocturneGlassButtonStyle())
                        .disabled(model.refreshingDevices || model.removingDevice != nil)
                }
                if let message = model.devicesError {
                    Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if model.devices.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "ipad.and.iphone").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                        Text("No paired devices yet").font(.headline)
                        Text("Pair an iPhone or iPad to see it here.").foregroundStyle(.secondary)
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
                            StatusPill(label: device.connected ? "Connected" : !device.streamIDs.isEmpty && !device.streamingEnabled ? "Disabled" : "Paired", active: device.connected)
                            if model.removingDevice == device.id {
                                ProgressView().controlSize(.small).frame(width: 74).accessibilityLabel("Removing \(device.name)")
                            } else {
                                Button("Remove…", role: .destructive) { deviceToRemove = device }
                                    .buttonStyle(NocturneGlassButtonStyle())
                                    .accessibilityLabel("Remove \(device.name)")
                                    .disabled(!model.running || model.changingDevices)
                            }
                        }.padding(.vertical, 3)
                    }
                }
                Text(model.running ? "Paired devices stay here when they disconnect. Connected indicates an open terminal and files connection." : "Start the server to see current connections or remove a device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func deviceFeatures(_ device: ServerDevice) -> String {
        ([device.streamIDs.isEmpty ? nil : "Streaming", device.workspace ? "Terminal & files" : nil].compactMap { $0 }).joined(separator: " · ")
    }
}
struct ServerPairingView: View {
    let invitation: PairingInvitation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 20) {
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(NocturneGlassButtonStyle()).keyboardShortcut(.defaultAction) }
            Text("Meet your Mac.").font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-1)
            Text("In Nocturne, choose Add host and scan this code.\nStreaming, terminal, and files connect together.").font(.subheadline).foregroundStyle(MoonStyle.secondary).multilineTextAlignment(.center)
            if let image = qrImage {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 210, height: 210).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 18))
            }
            Text(invitation.name).font(.subheadline.weight(.medium)).foregroundStyle(MoonStyle.secondary)
            Text("This code pairs one device and expires after five minutes.\nKeep it private. Remove devices individually in Devices.").font(.caption2).foregroundStyle(MoonStyle.secondary).multilineTextAlignment(.center)
        }.padding(28).frame(width: 440).background { NocturneBackdrop() }.tint(MoonStyle.accent)
    }
    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(invitation.url.absoluteString.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
