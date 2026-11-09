import SwiftUI
import NocturneKit
import NocturneMacClient

struct MacAppsWindow: View {
    @ObservedObject var client: MacClientModel
    var body: some View {
        if let apps = client.apps { MacAppsWorkspace(apps: apps, client: client).id(apps.serverID) }
        else {
            ContentUnavailableView(L("Choose a Mac"), systemImage: "square.grid.2x2", description: Text(L("Choose Apps next to a paired host in Computers.")))
        }
    }
}

private struct MacAppsWorkspace: View {
    @ObservedObject var apps: MacAppsModel
    @ObservedObject var client: MacClientModel
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var choosing: RemoteApplication?
    private var filtered: [RemoteApplication] {
        apps.applications.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }
    private var filteredWindows: [RemoteAppWindow] {
        apps.windows.filter { window in
            search.isEmpty || window.title.localizedStandardContains(search) || filtered.contains(where: { $0.id == window.applicationID })
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Apps on %@", "\(apps.name)")).font(.title.weight(.semibold))
                    Text(L("Open an app or choose one of its windows. Resizable apps follow the viewer; fixed-size apps keep their shape."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if apps.loading { ProgressView(L("Loading apps…")).frame(maxWidth: .infinity) }
                if let error = apps.error ?? client.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !filteredWindows.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("Open windows")).font(.headline)
                        ForEach(filteredWindows) { window in
                            Button { open(window) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "macwindow").foregroundStyle(MoonStyle.accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(window.title).lineLimit(1).foregroundStyle(.primary)
                                        Text(apps.applications.first(where: { $0.id == window.applicationID })?.name ?? L("Mac app"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                                }.padding(12).background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityLabel(L("Open %@", "\(window.title)"))
                        }
                    }
                }
                if !filtered.isEmpty { Text(L("Applications")).font(.headline) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    ForEach(filtered) { app in
                        Button {
                            Task {
                                let windows = await apps.launch(app)
                                if windows.count == 1, let window = windows.first { open(window) }
                                else if windows.count > 1 { choosing = app }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                if let icon = apps.icons[app.id] {
                                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 42, height: 42)
                                } else { Image(systemName: "app.dashed").font(.title).frame(width: 42, height: 42).foregroundStyle(MoonStyle.accent) }
                                Text(app.name).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                Spacer(minLength: 0)
                                if apps.opening == app.id { ProgressView().controlSize(.small) }
                            }.padding(14).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                .background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).disabled(apps.opening != nil || apps.loading)
                            .accessibilityLabel(L("Open %@", "\(app.name)")).task(id: app.id) { await apps.icon(app) }
                    }
                }
                if !apps.loading, filtered.isEmpty, filteredWindows.isEmpty, apps.error == nil {
                    ContentUnavailableView(search.isEmpty ? L("No apps found") : L("No matching apps"), systemImage: "square.grid.2x2",
                        description: Text(search.isEmpty ? L("Refresh after installing an app on the host Mac.") : L("Try another app name.")))
                }
            }.padding(28)
        }
        .background { NocturneBackdrop() }
        .navigationTitle(apps.name)
        .searchable(text: $search, prompt: L("Find an app or window"))
        .toolbar {
            ToolbarItem {
                Button(L("Desktop"), systemImage: "display") {
                    if client.session == nil { client.connect(apps.serverID) }
                    openWindow(id: "remote-desktop")
                }.disabled(client.session != nil && client.session?.serverID != apps.serverID)
            }
            ToolbarItem {
                Button(L("Refresh apps"), systemImage: "arrow.clockwise") { Task { await apps.load() } }
                    .disabled(apps.loading).accessibilityIdentifier("refreshMacApps")
            }
        }
        .task { await apps.load() }
        .onDisappear { if client.apps === apps { client.closeApps() } }
        .sheet(item: $choosing) { app in
            VStack(alignment: .leading, spacing: 18) {
                Text(L("Choose a window in %@", "\(app.name)")).font(.headline)
                List(apps.windows.filter { $0.applicationID == app.id }) { window in
                    Button(window.title, systemImage: "macwindow") { choosing = nil; open(window) }.buttonStyle(.plain)
                }
                HStack { Spacer(); Button(L("Cancel")) { choosing = nil }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 480, height: 360)
        }
    }
    private func open(_ window: RemoteAppWindow) {
        if let id = client.openAppWindow(window, from: apps) { client.showAppWindow(id) }
    }
}
