import SwiftUI
import NocturneKit

struct ClientRootView: View {
    @ObservedObject var model: ClientModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("nocturne.appearance") private var appearance = NocturneAppearance.system
    var body: some View {
        GeometryReader { geometry in
            if horizontalSizeClass == .regular && WorkspaceLayout.resolve(width: geometry.size.width) == .expanded {
                NavigationSplitView {
                    List(selection: Binding<ClientPage?>(get: { model.page }, set: { if let page = $0 { model.page = page } })) {
                        Section("Workspace") {
                            ForEach(ClientPage.allCases) { page in
                                NavigationLink(value: page) { Label(page.rawValue, systemImage: page.symbol) }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .navigationTitle("Nocturne")
                    .safeAreaInset(edge: .bottom, alignment: .leading) {
                        Label("Your Mac, anywhere at home", systemImage: "moon")
                            .font(.caption).foregroundStyle(.secondary).padding(20)
                    }
                    .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 290)
                } detail: { navigation(for: model.page) }
                .navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: $model.page) {
                    ForEach(ClientPage.allCases) { page in
                        navigation(for: page).tabItem { Label(page.rawValue, systemImage: page.symbol) }.tag(page)
                    }
                }
            }
        }
        .tint(MoonStyle.accent).preferredColorScheme(appearance.colorScheme)
        .sheet(isPresented: $model.showAdd) { AddComputerView(model: model) }
        .sheet(isPresented: $model.showLibrary) { AppLibraryView(model: model) }
        .alert("Connection needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .fullScreenCover(item: $model.session, onDismiss: { model.endStream() }) { session in StreamWorkspace(model: model, session: session) }
        .task { model.start() }
    }
    private func navigation(for page: ClientPage) -> some View {
        NavigationStack {
            Group {
                switch page {
                case .computers: ComputersView(model: model)
                case .terminal: TerminalWorkspace(connection: model.server, connect: { Task { await model.reconnectServer() } })
                case .files: FilesWorkspace(connection: model.server, connect: { model.showAdd = true })
                case .settings: ClientSettingsView(model: model)
                }
            }
            .background { NocturneBackdrop() }.navigationTitle(page.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if page == .computers {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Add computer", systemImage: "plus") { model.preferServer = false; model.showAdd = true }.accessibilityIdentifier("addComputer")
                    }
                }
            }
        }
    }
}

struct ComputersView: View {
    @ObservedObject var model: ClientModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 7) { MoonMark(size: 24); Text("NOCTURNE").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(MoonStyle.secondary) }
                        Text("Your desktop.\nA little closer.")
                            .font(.system(size: sizeClass == .regular ? 42 : 32, weight: .semibold, design: .rounded)).tracking(-1.2).lineSpacing(-2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Stream, create, and play.\nAll from the device in your hands.")
                            .font(.system(size: 14)).foregroundStyle(MoonStyle.secondary).lineSpacing(4)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    LunarArtwork().frame(width: sizeClass == .regular ? 240 : 110, height: sizeClass == .regular ? 230 : 170)
                }.padding(.vertical, 12)

                VStack(spacing: 15) {
                    SectionCaption(title: "Your computers", detail: model.hosts.isEmpty ? "Local network" : "\(model.hosts.count) discovered")
                    if model.hosts.isEmpty {
                        MoonPanel {
                            VStack(alignment: .leading, spacing: 22) {
                                HStack(alignment: .top, spacing: 16) {
                                    Image(systemName: "desktopcomputer").font(.system(size: 31, weight: .light)).foregroundStyle(MoonStyle.secondary).padding(.top, 3)
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text("Make yourself at home").font(.system(size: 17, weight: .semibold))
                                        Text("Start Nocturne Server on your Mac, then scan its pairing code. Nearby computers also appear here.")
                                            .font(.system(size: 13)).foregroundStyle(MoonStyle.secondary).lineSpacing(4)
                                    }
                                }
                                Button { model.preferServer = false; model.showAdd = true } label: { Label("Add a computer", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 285), spacing: 16)], spacing: 16) {
                            ForEach(model.hosts) { host in
                                Button { model.select(host) } label: { HostCard(host: host) }.buttonStyle(.plain).disabled(model.busy)
                                    .contextMenu { Button("Forget computer", role: .destructive) { model.forgetHost(host.id) } }
                            }
                        }
                    }
                    if model.busy { HStack(spacing: 10) { ProgressView(); Text("Connecting to your computer…").font(.footnote).foregroundStyle(MoonStyle.secondary) }.frame(maxWidth: .infinity).padding(8) }
                }

                WorkspaceCard(model: model, connection: model.server)

                VStack(spacing: 14) {
                    SectionCaption(title: "Bring your favorites")
                    MoonPanel {
                        VStack(spacing: 14) {
                            FeatureRow(icon: "keyboard", title: "A familiar feel", subtitle: "Bluetooth keyboards, mice, and trackpads work with your stream.")
                            Divider().overlay(.white.opacity(0.04))
                            FeatureRow(icon: "gamecontroller", title: "Ready when you are", subtitle: "Connect an Xbox, PlayStation, or MFi controller in iOS Settings.")
                        }
                    }
                }
                HStack(spacing: 7) {
                    Image(systemName: "network").font(.system(size: 11))
                    Text("Direct to your computer. No account needed.").font(.system(size: 11))
                }.foregroundStyle(MoonStyle.secondary.opacity(0.7)).frame(maxWidth: .infinity).padding(.bottom, 10)
            }.padding(.horizontal, sizeClass == .regular ? 36 : 22).padding(.top, 18).padding(.bottom, 24)
                .frame(maxWidth: 1_100).frame(maxWidth: .infinity)
        }.refreshable { model.start() }
    }
}

struct HostCard: View {
    let host: StreamingHost
    var body: some View {
        MoonPanel {
            VStack(alignment: .leading, spacing: 25) {
                HStack { Image(systemName: "desktopcomputer").font(.system(size: 32, weight: .light)).foregroundStyle(MoonStyle.accent); Spacer(); StatusPill(label: host.online ? "Online" : "Offline", active: host.online) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(host.name).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(MoonStyle.silver)
                    Text(host.address).font(.system(size: 11, design: .monospaced)).foregroundStyle(MoonStyle.secondary)
                }
                HStack { Text(host.paired ? "Open library" : "Pair computer"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(MoonStyle.accent)
            }
        }
    }
}

struct WorkspaceCard: View {
    @ObservedObject var model: ClientModel
    @ObservedObject var connection: WorkspaceConnection
    var body: some View {
        MoonPanel {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Label("Your workspace", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if connection.state == .connected { StatusPill(label: "Connected", active: true) }
                }
                Text(connection.state == .connected ? "\(connection.name) is connected. Your terminal and shared files are a tap away." : "Connect to Nocturne Server for streaming, your terminal, and shared files.")
                    .font(.system(size: 13)).foregroundStyle(MoonStyle.secondary).lineSpacing(4)
                NocturneGlassGroup { HStack(spacing: 12) {
                    if connection.state == .connected {
                        Button { model.page = .terminal } label: { Label("Terminal", systemImage: "terminal") }
                        Button { model.page = .files } label: { Label("Files", systemImage: "folder") }
                    } else if model.savedServerName != nil {
                        Button { Task { await model.reconnectServer() } } label: { Label(connection.state == .connecting ? "Connecting…" : "Reconnect to Mac", systemImage: "link") }
                            .disabled(connection.state == .connecting)
                    } else {
                        Button { model.preferServer = true; model.showAdd = true } label: { HStack { Text("Pair your Mac"); Image(systemName: "arrow.right") } }
                    }
                }.buttonStyle(NocturneGlassButtonStyle()).controlSize(.large).font(.system(size: 13, weight: .semibold)).tint(MoonStyle.accent) }
            }
        }
    }
}

struct AppLibraryView: View {
    @ObservedObject var model: ClientModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Pick up where\nyou left off.").font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1)
                    HStack { StatusPill(label: "Paired", active: true); Text("\(model.preferences.resolution) · \(model.preferences.frameRate) fps").font(.caption).foregroundStyle(MoonStyle.secondary) }
                    if model.apps.isEmpty { ContentUnavailableView("No apps yet", systemImage: "square.grid.2x2", description: Text("Restart Nocturne Server on your Mac, then reconnect to load your desktop.")) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 16) {
                        ForEach(model.apps) { app in
                            Button { model.stream(app) } label: {
                                VStack(alignment: .leading, spacing: 16) {
                                    ZStack { RoundedRectangle(cornerRadius: 15).fill(MoonStyle.accent.opacity(0.08)); Image(systemName: app.icon).font(.system(size: 36, weight: .light)).foregroundStyle(MoonStyle.accent) }.frame(height: 100)
                                    Text(app.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(MoonStyle.silver).lineLimit(2)
                                    HStack { Text("Start streaming"); Spacer(); Image(systemName: "play.fill") }.font(.system(size: 10, weight: .medium)).foregroundStyle(MoonStyle.secondary)
                                }.padding(15).background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(24)
            }.background { NocturneBackdrop() }.navigationTitle(model.selectedHost?.name ?? "Library").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.tint(MoonStyle.accent)
    }
}
