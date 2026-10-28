import SwiftUI
import NocturneKit

/// A single roster for saved hosts; per-host actions live in the detail screen.
struct PairedHostsView: View {
    @ObservedObject var model: ClientModel
    @ObservedObject private var connection: WorkspaceConnection
    init(model: ClientModel) { self.model = model; connection = model.server }
    var body: some View {
        List {
            Section {
                if model.pairedServers.servers.isEmpty {
                    ContentUnavailableView(L("No paired hosts"), systemImage: "desktopcomputer",
                        description: Text(L("Add a host by scanning its Nocturne QR code.")))
                }
                ForEach(model.pairedServers.servers) { paired in
                    NavigationLink { PairedHostDetailView(model: model, hostID: paired.id) } label: {
                        PairedHostSummary(model: model, paired: paired)
                    }
                    .accessibilityIdentifier("pairedHost-\(paired.id)")
                }
                Button(L("Add host"), systemImage: "plus") { model.showAdd = true }
                    .disabled(model.busy || model.session != nil)
            } footer: {
                Text(L("Choose a host to open its desktop, switch your workspace, or manage its pairing."))
            }.listRowBackground(MoonStyle.surface)
        }
        .scrollContentBackground(.hidden).background { NocturneBackdrop() }
        .navigationTitle(L("Paired hosts")).navigationBarTitleDisplayMode(.inline)
    }
}

struct PairedHostSummary: View {
    @ObservedObject var model: ClientModel
    let paired: PairedServer
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer").font(.system(size: 25, weight: .regular))
                .foregroundStyle(MoonStyle.accent).frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(paired.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(model.hostStatus(paired)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if paired.id == model.pairedServers.activeID {
                Text(L("Selected")).font(.caption2.weight(.medium)).foregroundStyle(MoonStyle.accent)
            }
        }.padding(.vertical, 7)
    }
}

struct PairedHostDetailView: View {
    @ObservedObject var model: ClientModel
    @ObservedObject private var connection: WorkspaceConnection
    let hostID: String
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting = false
    init(model: ClientModel, hostID: String) { self.model = model; self.hostID = hostID; connection = model.server }
    private var paired: PairedServer? { model.pairedServers[hostID] }
    private var isActive: Bool { model.pairedServers.activeID == hostID }
    var body: some View {
        List {
            if let paired {
                Section {
                    PairedHostSummary(model: model, paired: paired)
                    LabeledContent(L("Workspace"), value: workspaceStatus)
                    LabeledContent(L("Screen sharing"), value: model.hostStatus(paired))
                }.listRowBackground(MoonStyle.surface)
                Section {
                    Button(L("Open desktop"), systemImage: "play.display") { model.openHost(hostID, desktop: true) }
                        .accessibilityIdentifier("openHostDesktop")
                    Button(L("Open library"), systemImage: "square.grid.2x2") { model.openHost(hostID) }
                    if !isActive {
                        Button(L("Use for Apps, Terminal & Files"), systemImage: "checkmark.circle") { model.activateServer(hostID) }
                    }
                    Button(L("Reconnect"), systemImage: "arrow.clockwise") { model.reconnectHost(hostID) }
                }.disabled(model.busy || model.session != nil).listRowBackground(MoonStyle.surface)
                if isActive && model.busy {
                    Section {
                        HStack(spacing: 12) { ProgressView(); Text(L("Connecting to %@…", "\(paired.name)")) }
                        Button(L("Cancel connection"), role: .cancel) { model.cancelHostConnection() }
                    }.listRowBackground(MoonStyle.surface)
                }
                if let error = model.hostErrors[hostID] {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary)
                        Button(L("Retry screen sharing")) { model.openHost(hostID, desktop: true) }.disabled(model.busy)
                    }.listRowBackground(MoonStyle.surface)
                }
                Section {
                    Button(L("Forget host"), systemImage: "trash", role: .destructive) { forgetting = true }
                } footer: { Text(L("Removes this host’s pairing and Files location from this device. Other hosts stay paired.")) }
                    .listRowBackground(MoonStyle.surface)
            }
        }
        .scrollContentBackground(.hidden).background { NocturneBackdrop() }
        .navigationTitle(paired?.name ?? L("Host")).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(paired.map { L("Forget %@?", $0.name) } ?? L("Forget this host?"), isPresented: $forgetting, titleVisibility: .visible) {
            Button(L("Forget host"), role: .destructive) {
                model.forgetServer(hostID)
                if model.pairedServers[hostID] == nil { dismiss() }
            }
        }
    }
    private var workspaceStatus: String {
        guard isActive else { return L("Not selected") }
        switch connection.state {
        case .connected: return L("Available")
        case .connecting: return L("Connecting…")
        case .disconnected: return L("Offline")
        }
    }
}
