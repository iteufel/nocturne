import SwiftUI
import NocturneKit

@MainActor
final class HostAppsModel: ObservableObject {
    let connection: WorkspaceConnection
    @Published private(set) var applications: [RemoteApplication] = []
    @Published private(set) var windows: [RemoteAppWindow] = []
    @Published private(set) var icons: [String: UIImage] = [:]
    @Published private(set) var loading = false
    @Published private(set) var opening: String?
    @Published var error: String?
    private var generation = UUID()
    init(connection: WorkspaceConnection) { self.connection = connection }
    func reset() { generation = UUID(); applications = []; windows = []; icons = [:]; loading = false; opening = nil }
    func load() async {
        guard !loading, connection.state == .connected, connection.capabilities.contains(AppStreaming.capability) else { return }
        let epoch = generation; loading = true; error = nil
        defer { if generation == epoch { loading = false } }
        do {
            var apps: [RemoteApplication] = [], offset: Int64 = 0
            while true {
                var packet = Packet(.appList); packet.offset = offset
                let reply = try await connection.request(packet, timeout: 30)
                guard epoch == generation else { return }
                guard let page = reply.applications, page.count <= 64,
                      let next = reply.offset, next == offset + Int64(page.count),
                      reply.eof != nil, next > offset || reply.eof == true else { throw NocturneError.invalidFrame }
                apps.append(contentsOf: page)
                guard apps.count <= 10_000 else { throw NocturneError.invalidFrame }
                if offset == 0 { windows = reply.windows ?? []; error = reply.windowsError }
                if reply.eof == true { break }; offset = next
            }
            guard Set(apps.map(\.id)).count == apps.count else { throw NocturneError.invalidFrame }
            applications = apps
        } catch { if generation == epoch { self.error = error.localizedDescription } }
    }
    func icon(_ app: RemoteApplication) async {
        guard icons[app.id] == nil, connection.state == .connected else { return }
        let epoch = generation
        var packet = Packet(.appIcon); packet.applicationID = app.id
        guard let reply = try? await connection.request(packet), epoch == generation,
              let data = reply.data, data.count <= 131_072, let image = UIImage(data: data) else { return }
        icons[app.id] = image
    }
    func launch(_ app: RemoteApplication) async -> [RemoteAppWindow] {
        guard opening == nil else { return [] }
        let epoch = generation; opening = app.id; error = nil
        defer { if generation == epoch { opening = nil } }
        do {
            var packet = Packet(.appLaunch); packet.applicationID = app.id
            let reply = try await connection.request(packet, timeout: 30)
            guard epoch == generation else { return [] }
            guard let available = reply.windows, !available.isEmpty,
                  available.allSatisfy({ $0.applicationID == app.id }) else { throw NocturneError.invalidFrame }
            windows.removeAll { $0.applicationID == app.id }; windows.append(contentsOf: available)
            return available
        } catch { if generation == epoch { self.error = error.localizedDescription }; return [] }
    }
}

struct HostAppsWorkspace: View {
    @ObservedObject var client: ClientModel
    @ObservedObject var model: HostAppsModel
    @ObservedObject var connection: WorkspaceConnection
    @State private var search = ""
    @State private var choosing: RemoteApplication?
    @State private var phoneWindow: AppWindowRoute?
    private var filtered: [RemoteApplication] {
        model.applications.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }
    var body: some View {
        Group {
            if connection.state != .connected {
                ContentUnavailableView {
                    Label("Your Mac apps", systemImage: "square.grid.2x2")
                } description: { Text("Connect to Nocturne to browse and open your Mac’s apps.") }
                actions: {
                    Button(client.savedServerName == nil ? "Pair your Mac" : "Reconnect to Mac") {
                        if client.savedServerName == nil { client.showAdd = true }
                        else { Task { await client.reconnectServer() } }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(connection.state == .connecting)
                }
            } else if !connection.capabilities.contains(AppStreaming.capability) {
                ContentUnavailableView("Update your Mac server", systemImage: "macwindow", description: Text("Install the latest Nocturne, then reconnect to open individual app windows."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(connection.name, systemImage: "desktopcomputer").font(.subheadline.weight(.medium)).foregroundStyle(MoonStyle.secondary)
                            Text("Your apps. Their own space.").font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.8)
                            Text(UIApplication.shared.supportsMultipleScenes
                                 ? "Open a Mac app in its own iPad window. Resize it here and the window on your Mac follows."
                                 : "Open and control just an app’s window from your Mac.")
                                .font(.callout).foregroundStyle(MoonStyle.secondary).frame(maxWidth: 530, alignment: .leading)
                        }
                        if model.loading { ProgressView("Loading apps…").frame(maxWidth: .infinity).padding() }
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(MoonStyle.secondary)
                        }
                        if !model.loading, filtered.isEmpty {
                            ContentUnavailableView(search.isEmpty ? "No apps found" : "No matching apps", systemImage: "square.grid.2x2", description: Text(search.isEmpty ? "Install an app on your Mac, then refresh this list." : "Try another app name."))
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 220), spacing: 16)], alignment: .leading, spacing: 16) {
                            ForEach(filtered) { app in
                                Button { Task { await launch(app) } } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            if let icon = model.icons[app.id] { Image(uiImage: icon).resizable().scaledToFit().frame(width: 56, height: 56) }
                                            else { Image(systemName: "app.dashed").font(.system(size: 42, weight: .light)).foregroundStyle(MoonStyle.accent).frame(width: 56, height: 56) }
                                            Spacer(minLength: 0)
                                            if model.opening == app.id { ProgressView() }
                                            else { Image(systemName: "arrow.up.forward.app").foregroundStyle(MoonStyle.secondary) }
                                        }
                                        Text(app.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).frame(height: 38, alignment: .topLeading)
                                        let count = model.windows.filter { $0.applicationID == app.id }.count
                                        Text(count == 0 ? "Open app" : count == 1 ? "1 open window" : "\(count) open windows")
                                            .font(.caption).foregroundStyle(MoonStyle.secondary)
                                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                                }.buttonStyle(.plain).disabled(model.opening != nil)
                                    .accessibilityLabel("Open \(app.name)")
                                    .task(id: app.id) { await model.icon(app) }
                                    .contextMenu {
                                        ForEach(model.windows.filter { $0.applicationID == app.id }) { window in
                                            Button(window.title, systemImage: "macwindow") { open(window) }
                                        }
                                        Button("Open app", systemImage: "arrow.up.forward.app") { Task { await launch(app) } }
                                    }
                            }
                        }
                    }.padding(24).frame(maxWidth: 1150, alignment: .leading).frame(maxWidth: .infinity)
                }.refreshable { await model.load() }
                    .searchable(text: $search, prompt: "Find an app")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SimulatorWorkspace(connection: connection) } label: { Label("Simulator", systemImage: "iphone") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh apps", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.loading || connection.state != .connected).accessibilityIdentifier("refreshApps")
            }
        }
        .task(id: connection.state) { if connection.state == .connected { await model.load() } }
        .sheet(item: $choosing) { app in
            NavigationStack {
                List(model.windows.filter { $0.applicationID == app.id }) { window in
                    Button { choosing = nil; open(window) } label: {
                        Label { VStack(alignment: .leading, spacing: 4) {
                            Text(window.title).foregroundStyle(.primary)
                            Text("Open window · \(window.width) × \(window.height)").font(.caption).foregroundStyle(.secondary)
                        } } icon: { Image(systemName: "macwindow") }
                    }
                }.navigationTitle(app.name).navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .top) { Text("Choose a window to stream").font(.subheadline).foregroundStyle(.secondary).padding() }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = nil } } }
            }.presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $phoneWindow) { route in
            AppWindowPhoneScene(route: route, client: client) { phoneWindow = nil }
        }
    }
    private func launch(_ app: RemoteApplication) async {
        let windows = await model.launch(app)
        if windows.count == 1, let window = windows.first { open(window) }
        else if windows.count > 1 { choosing = app }
    }
    private func open(_ window: RemoteAppWindow) {
        do {
            let invitation = try client.appWindowInvitation()
            let route = AppWindowRoute(serverID: WorkspaceIdentity.fingerprint(invitation.secret), applicationID: window.applicationID,
                                       windowID: window.id, title: window.title)
            if UIApplication.shared.supportsMultipleScenes { AppWindowScenes.open(route) { model.error = $0.localizedDescription } }
            else { phoneWindow = route }
        } catch { model.error = error.localizedDescription }
    }
}

