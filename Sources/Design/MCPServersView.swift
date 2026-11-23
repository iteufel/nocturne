import SwiftUI
import NocturneKit

struct MCPServersView: View {
    @StateObject private var model: MCPServersModel
    @State private var editing: MCPServerConfiguration?
    @State private var removing: MCPServerConfiguration?
    @Environment(\.dismiss) private var dismiss
    var didChange: () -> Void = {}
    init(model: MCPServersModel, didChange: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: model); self.didChange = didChange
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("Add remote MCP tools for agent chats. Servers connect from your Mac, so localhost refers to the Mac. Changes apply when you start or reopen a conversation."))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(L("HTTP MCP servers are supported. Add authentication with HTTP headers, such as Authorization: Bearer your-token. Credentials are saved in the Mac’s Keychain."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("MCP servers")) {
                    ForEach(model.servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name).font(.headline)
                                Text(server.enabled ? L("Enabled") : L("Disabled")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L("Edit…")) { editing = server }.buttonStyle(.borderless)
                            Button(L("Remove"), systemImage: "minus.circle", role: .destructive) { removing = server }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    }
                    if model.loaded, model.servers.isEmpty { Text(L("No custom MCP servers")).foregroundStyle(.secondary) }
                    Button(L("Add MCP server"), systemImage: "plus") { editing = MCPServerConfiguration() }
                        .disabled(!model.loaded || model.servers.count >= MCPServerConfiguration.maximumServers)
                        .accessibilityIdentifier("addMCPServer")
                }.disabled(model.busy)
                if let error = model.error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            }
            .navigationTitle(L("MCP servers"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Refresh"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.busy)
                }
            }
            .overlay { if model.busy { ProgressView() } }
            .task { await model.refresh() }
            .sheet(item: $editing) { server in
                MCPServerEditor(server: server, model: model) { didChange() }
            }
            .confirmationDialog(L("Remove MCP server?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                if let server = removing {
                    Button(L("Remove"), role: .destructive) { Task { await model.remove(server.id); if model.error == nil { didChange() }; removing = nil } }
                }
            }
        }
        #if os(macOS)
        .frame(width: 600, height: 540)
        #endif
    }
}

private struct MCPHeaderDraft: Identifiable {
    let id = UUID()
    var name = ""
    var value = ""
}

private struct MCPServerEditor: View {
    @State var server: MCPServerConfiguration
    @ObservedObject var model: MCPServersModel
    let didSave: () -> Void
    @State private var headers: [MCPHeaderDraft]
    @State private var validationError: String?
    @Environment(\.dismiss) private var dismiss
    init(server: MCPServerConfiguration, model: MCPServersModel, didSave: @escaping () -> Void) {
        self._server = State(initialValue: server); self.model = model; self.didSave = didSave
        self._headers = State(initialValue: server.headers.keys.sorted().map { MCPHeaderDraft(name: $0, value: server.headers[$0]!) })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Server name"), text: $server.name).accessibilityIdentifier("mcpServerName")
                    TextField(L("Server URL"), text: $server.url).accessibilityIdentifier("mcpServerURL")
                        #if os(iOS)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    Toggle(L("Enabled"), isOn: $server.enabled)
                }
                Section(L("HTTP headers")) {
                    ForEach($headers) { $header in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(L("Header name"), text: $header.name)
                                #if os(iOS)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                #endif
                            SecureField(L("Header value"), text: $header.value)
                            Button(L("Remove header"), role: .destructive) { headers.removeAll { $0.id == header.id } }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button(L("Add header"), systemImage: "plus") { headers.append(MCPHeaderDraft()) }.disabled(headers.count >= 16)
                }
                if let error = validationError ?? model.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }.disabled(model.busy)
            .navigationTitle(L("Custom MCP server"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) { save() }.disabled(model.busy).accessibilityIdentifier("saveMCPServer")
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
        #if os(macOS)
        .frame(width: 540, height: 520)
        #endif
    }
    private func save() {
        validationError = nil
        do {
            var value = server
            value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            value.url = value.url.trimmingCharacters(in: .whitespacesAndNewlines)
            var fields: [String: String] = [:], names = Set<String>()
            for header in headers {
                let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard names.insert(name.lowercased()).inserted else {
                    throw NocturneError.remote("Enter unique HTTP header names and single-line values, using at most 16 headers and 16 KB in total.")
                }
                fields[name] = header.value
            }
            value.headers = fields; try value.validate()
            Task { if await model.save(value) { didSave(); dismiss() } }
        } catch { validationError = NocturneLocalization.message(error.localizedDescription) }
    }
}
