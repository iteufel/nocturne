import SwiftUI
import NocturneKit

struct ClientRootView: View {
    @ObservedObject var model: ClientModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("nocturne.appearance") private var appearance = NocturneAppearance.system
    @AppStorage("nocturne.client.onboardingComplete") private var onboardingComplete = false
    @State private var replayOnboarding = false
    private var needsOnboarding: Bool {
        replayOnboarding || (!onboardingComplete && model.savedServerName == nil && !model.hosts.contains(where: \.paired))
    }
    var body: some View {
        Group {
            if needsOnboarding {
                ClientOnboardingView { pair in
                    onboardingComplete = true
                    replayOnboarding = false
                    if pair { model.showAdd = true }
                }
            } else { workspace }
        }
        .tint(MoonStyle.accent).preferredColorScheme(appearance.colorScheme)
        .sheet(isPresented: $model.showAdd) { AddComputerView(model: model) }
        .sheet(isPresented: $model.showLibrary) { AppLibraryView(model: model) }
        .alert(L("Connection needs attention"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("OK")) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .background { StreamPresentation(model: model).allowsHitTesting(false) }
        .task(id: needsOnboarding) {
            if !needsOnboarding { onboardingComplete = true; model.start() }
        }
    }
    private var workspace: some View {
        GeometryReader { geometry in
            if model.page == .chats {
                navigation(for: .chats)
            } else if horizontalSizeClass == .regular && WorkspaceLayout.resolve(width: geometry.size.width) == .expanded {
                NavigationSplitView {
                    List(selection: Binding<ClientPage?>(get: { model.page }, set: { if let page = $0 { model.page = page } })) {
                        Section(L("Workspace")) {
                            ForEach(ClientPage.allCases) { page in
                                NavigationLink(value: page) { Label(L(page.rawValue), systemImage: page.symbol) }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .navigationTitle("Nocturne")
                    .safeAreaInset(edge: .bottom, alignment: .leading) {
                        Label(L("Your Mac, anywhere at home"), systemImage: "moon")
                            .font(.caption).foregroundStyle(.secondary).padding(20)
                    }
                    .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 290)
                } detail: { navigation(for: model.page) }
                .navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: $model.page) {
                    ForEach(ClientPage.allCases) { page in
                        navigation(for: page).tabItem { Label(L(page.rawValue), systemImage: page.symbol) }.tag(page)
                    }
                }
            }
        }
    }
    private func navigation(for page: ClientPage) -> some View {
        NavigationStack {
            Group {
                switch page {
                case .computers: ComputersView(model: model)
                case .hostApps: HostAppsWorkspace(client: model, model: model.hostApps, connection: model.server)
                case .chats: ChatWorkspace(model: model.chats, connection: model.server, voice: model.voice, connect: { Task { await model.reconnectServer() } }, exit: { model.page = .computers })
                case .terminal: TerminalWorkspace(connection: model.server, connect: { Task { await model.reconnectServer() } })
                case .files: FilesWorkspace(connection: model.server, connect: { Task { await model.reconnectServer() } })
                case .settings: ClientSettingsView(model: model, showOnboarding: { replayOnboarding = true })
                }
            }
            .background { NocturneBackdrop() }.navigationTitle(L(page.rawValue))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if page == .computers {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("Add host"), systemImage: "plus") { model.showAdd = true }.disabled(model.busy || model.session != nil).accessibilityIdentifier("addComputer")
                    }
                } else if [.hostApps, .terminal, .files].contains(page), model.pairedServers.servers.count > 1 {
                    ToolbarItem(placement: .topBarLeading) { PairedHostMenu(model: model) }
                }
            }
        }
    }
}

struct ComputersView: View {
    @ObservedObject var model: ClientModel
    @ObservedObject private var connection: WorkspaceConnection
    init(model: ClientModel) { self.model = model; connection = model.server }
    var body: some View {
        List {
            if !model.pairedServers.servers.isEmpty {
                Section {
                    ForEach(model.pairedServers.servers) { paired in
                        HStack(spacing: 12) {
                            Button { model.openHost(paired.id, desktop: true) } label: {
                                PairedHostSummary(model: model, paired: paired).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.busy)
                                .accessibilityLabel(L("Open %@ desktop", "\(paired.name)"))
                                .accessibilityHint(model.hostStatus(paired))
                            NavigationLink { PairedHostDetailView(model: model, hostID: paired.id) } label: {
                                Image(systemName: "info.circle").foregroundStyle(MoonStyle.accent)
                            }.fixedSize().accessibilityLabel(L("Manage %@", "\(paired.name)"))
                        }
                    }
                } header: {
                    HStack {
                        Text(L("Paired hosts"))
                        Spacer()
                        NavigationLink(L("Manage")) { PairedHostsView(model: model) }
                    }
                } footer: { Text(L("Tap a host to open its desktop.")) }
                    .listRowBackground(MoonStyle.surface)
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        MoonMark(size: 42)
                        Text(L("Your desktop, wherever you are."))
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text(L("Start Nocturne on your host, choose Pair a device, then scan its QR code."))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(L("Add host"), systemImage: "qrcode.viewfinder") { model.showAdd = true }
                            .buttonStyle(PrimaryButtonStyle())
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
            }
            if model.busy {
                Section {
                    HStack(spacing: 12) { ProgressView(); Text(L("Preparing screen sharing…")).font(.subheadline) }
                    Button(L("Cancel connection"), role: .cancel) { model.cancelHostConnection() }
                }.listRowBackground(MoonStyle.surface)
            }
            if let active = model.pairedServers.active, let error = model.hostErrors[active.id] {
                Section(L("Screen sharing")) {
                    Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary)
                    Button(L("Retry screen sharing")) { model.openHost(active.id, desktop: true) }.disabled(model.busy)
                }.listRowBackground(MoonStyle.surface)
            }
            if !model.nearbyHosts.isEmpty {
                Section(L("Nearby hosts")) {
                    ForEach(model.nearbyHosts) { host in
                        Button { model.select(host) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(MoonStyle.accent).frame(width: 36)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(host.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(host.paired ? L("Open library") : L("Scan QR code to pair")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: host.paired ? "play.circle" : "qrcode").foregroundStyle(MoonStyle.accent)
                            }.padding(.vertical, 7)
                        }.disabled(model.busy)
                    }
                }.listRowBackground(MoonStyle.surface)
            }
            if model.pairedServers.active != nil {
                Section {
                    WorkspaceCard(model: model, connection: connection)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { model.start(); await model.reconnectServer(reportError: false) }
    }
}

struct WorkspaceCard: View {
    @ObservedObject var model: ClientModel
    @ObservedObject var connection: WorkspaceConnection
    var body: some View {
        MoonPanel {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Label(L("Your workspace"), systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if connection.state == .connected {
                        TimelineView(.periodic(from: .now, by: 2)) { _ in
                            StatusPill(label: connection.connectionRoute ?? L("Connected"), active: true)
                        }
                    }
                }
                Text(connection.state == .connected ? L("Apps, Terminal, and Files use %@. Open its desktop from Paired hosts above.", "\(connection.name)") : L("Connect to your selected host to use Apps, Terminal, and Files."))
                    .font(.system(size: 13)).foregroundStyle(MoonStyle.secondary).lineSpacing(4)
                if !model.pairedServers.servers.isEmpty {
                    PairedHostMenu(model: model).font(.system(size: 13, weight: .medium))
                }
                NocturneGlassGroup {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { workspaceActions }
                        VStack(alignment: .leading, spacing: 8) { workspaceActions }
                    }
                    .buttonStyle(NocturneGlassButtonStyle()).controlSize(.regular)
                    .font(.system(size: 13, weight: .semibold)).tint(MoonStyle.accent)
                }
            }
        }
    }
    @ViewBuilder private var workspaceActions: some View {
        if connection.state == .connected {
            Button(L("Apps")) { model.page = .hostApps }.fixedSize()
            Button(L("Terminal")) { model.page = .terminal }.fixedSize()
            Button(L("Files")) { model.page = .files }.fixedSize()
        } else if let name = model.savedServerName {
            Button(connection.state == .connecting ? L("Connecting…") : L("Reconnect to %@", "\(name)")) {
                Task { await model.reconnectServer() }
            }.disabled(connection.state == .connecting).fixedSize()
        } else {
            Button(L("Add host")) { model.showAdd = true }.fixedSize()
        }
    }

}

/// Chooses the paired Mac that Apps, Terminal, and Files use, or pairs another one.
struct PairedHostMenu: View {
    @ObservedObject var model: ClientModel
    var body: some View {
        Menu {
            Picker(L("Paired hosts"), selection: Binding(get: { model.pairedServers.activeID ?? "" }, set: { model.activateServer($0) })) {
                ForEach(model.pairedServers.servers) { paired in Text(paired.name).tag(paired.id) }
            }
            Divider()
            Button(L("Add host"), systemImage: "plus") { model.showAdd = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                Text(model.savedServerName ?? L("Choose a host")).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .disabled(model.busy || model.session != nil)
        .accessibilityLabel(L("Current host: %@", "\(model.savedServerName ?? "none")"))
        .accessibilityIdentifier("pairedHostMenu")
    }
}

struct AppLibraryView: View {
    @ObservedObject var model: ClientModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L("Pick up where\nyou left off.")).font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1)
                    HStack { StatusPill(label: L("Paired"), active: true); Text(L("%@ · %@ fps", "\(model.preferences.resolution)", model.preferences.frameRate.formatted())).font(.caption).foregroundStyle(MoonStyle.secondary) }
                    if model.apps.isEmpty { ContentUnavailableView(L("No apps yet"), systemImage: "square.grid.2x2", description: Text(L("Restart Nocturne on your Mac, then reconnect to load your desktop."))) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 16) {
                        ForEach(model.apps) { app in
                            Button { model.stream(app) } label: {
                                VStack(alignment: .leading, spacing: 16) {
                                    ZStack { RoundedRectangle(cornerRadius: 15).fill(MoonStyle.accent.opacity(0.08)); Image(systemName: app.icon).font(.system(size: 36, weight: .light)).foregroundStyle(MoonStyle.accent) }.frame(height: 100)
                                    Text(app.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(MoonStyle.silver).lineLimit(2)
                                    HStack { Text(L("Start streaming")); Spacer(); Image(systemName: "play.fill") }.font(.system(size: 10, weight: .medium)).foregroundStyle(MoonStyle.secondary)
                                }.padding(15).background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(24)
            }.background { NocturneBackdrop() }.navigationTitle(model.selectedHost?.name ?? L("Library")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Done")) { dismiss() } } }
        }.tint(MoonStyle.accent)
    }
}
