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
        .alert("Connection needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .background { StreamPresentation(model: model).allowsHitTesting(false) }
        .task(id: needsOnboarding) {
            if !needsOnboarding { onboardingComplete = true; model.start() }
        }
    }
    private var workspace: some View {
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
                        Label("Your computer, anywhere at home", systemImage: "moon")
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
    }
    private func navigation(for page: ClientPage) -> some View {
        NavigationStack {
            Group {
                switch page {
                case .computers: ComputersView(model: model)
                case .hostApps: HostAppsWorkspace(client: model, model: model.hostApps, connection: model.server)
                case .terminal: TerminalWorkspace(connection: model.server, connect: { Task { await model.reconnectServer() } })
                case .files: FilesWorkspace(connection: model.server, connect: { Task { await model.reconnectServer() } })
                case .settings: ClientSettingsView(model: model, showOnboarding: { replayOnboarding = true })
                }
            }
            .background { NocturneBackdrop() }.navigationTitle(page.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if page == .computers {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Add host", systemImage: "plus") { model.showAdd = true }.disabled(model.busy || model.session != nil).accessibilityIdentifier("addComputer")
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
                                .accessibilityLabel("Open \(paired.name) desktop")
                                .accessibilityHint(model.hostStatus(paired))
                            NavigationLink { PairedHostDetailView(model: model, hostID: paired.id) } label: {
                                Image(systemName: "info.circle").foregroundStyle(MoonStyle.accent)
                            }.fixedSize().accessibilityLabel("Manage \(paired.name)")
                        }
                    }
                } header: {
                    HStack {
                        Text("Paired hosts")
                        Spacer()
                        NavigationLink("Manage") { PairedHostsView(model: model) }
                    }
                } footer: { Text("Tap a host to open its desktop.") }
                    .listRowBackground(MoonStyle.surface)
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        MoonMark(size: 42)
                        Text("Your desktop, wherever you are.")
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text("Start Nocturne on your host, choose Pair a device, then scan its QR code.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Add host", systemImage: "qrcode.viewfinder") { model.showAdd = true }
                            .buttonStyle(PrimaryButtonStyle())
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
            }
            if model.busy {
                Section {
                    HStack(spacing: 12) { ProgressView(); Text("Preparing screen sharing…").font(.subheadline) }
                    Button("Cancel connection", role: .cancel) { model.cancelHostConnection() }
                }.listRowBackground(MoonStyle.surface)
            }
            if let active = model.pairedServers.active, let error = model.hostErrors[active.id] {
                Section("Screen sharing") {
                    Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary)
                    Button("Retry screen sharing") { model.openHost(active.id, desktop: true) }.disabled(model.busy)
                }.listRowBackground(MoonStyle.surface)
            }
            if !model.nearbyHosts.isEmpty {
                Section("Nearby hosts") {
                    ForEach(model.nearbyHosts) { host in
                        Button { model.select(host) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(MoonStyle.accent).frame(width: 36)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(host.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(host.paired ? "Open library" : "Scan QR code to pair").font(.caption).foregroundStyle(.secondary)
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
                    Label("Your workspace", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if connection.state == .connected {
                        TimelineView(.periodic(from: .now, by: 2)) { _ in
                            StatusPill(label: connection.connectionRoute ?? "Connected", active: true)
                        }
                    }
                }
                Text(connection.state == .connected ? "Apps, Terminal, and Files use \(connection.name). Open its desktop from Paired hosts above." : "Connect to your selected host to use Apps, Terminal, and Files.")
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
            Button("Apps") { model.page = .hostApps }.fixedSize()
            Button("Terminal") { model.page = .terminal }.fixedSize()
            Button("Files") { model.page = .files }.fixedSize()
        } else if let name = model.savedServerName {
            Button(connection.state == .connecting ? "Connecting…" : "Reconnect to \(name)") {
                Task { await model.reconnectServer() }
            }.disabled(connection.state == .connecting).fixedSize()
        } else {
            Button("Add host") { model.showAdd = true }.fixedSize()
        }
    }

}

/// Chooses the paired Mac that Apps, Terminal, and Files use, or pairs another one.
struct PairedHostMenu: View {
    @ObservedObject var model: ClientModel
    var body: some View {
        Menu {
            Picker("Paired hosts", selection: Binding(get: { model.pairedServers.activeID ?? "" }, set: { model.activateServer($0) })) {
                ForEach(model.pairedServers.servers) { paired in Text(paired.name).tag(paired.id) }
            }
            Divider()
            Button("Add host", systemImage: "plus") { model.showAdd = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                Text(model.savedServerName ?? "Choose a host").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .disabled(model.busy || model.session != nil)
        .accessibilityLabel("Current host: \(model.savedServerName ?? "none")")
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
                    Text("Pick up where\nyou left off.").font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1)
                    HStack { StatusPill(label: "Paired", active: true); Text("\(model.preferences.resolution) · \(model.preferences.frameRate) fps").font(.caption).foregroundStyle(MoonStyle.secondary) }
                    if model.apps.isEmpty { ContentUnavailableView("No apps yet", systemImage: "square.grid.2x2", description: Text("Restart Nocturne on your computer, then reconnect to load your desktop.")) }
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
