import SwiftUI
import NocturneKit
import NocturneMacClient

struct MacComputersView: View {
    @ObservedObject var client: MacClientModel
    @Environment(\.openWindow) private var openWindow
    @State private var forgetting: PairedServer?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Another Mac.\nRight here.")
                        .font(.system(size: 38, weight: .semibold, design: .rounded)).tracking(-1.2)
                    Text("Connect to a Mac running Nocturne. Open its desktop with sound, keyboard, and mouse, or give each app window its own space.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let stream = client.session {
                    MoonPanel {
                        HStack(spacing: 16) {
                            Image(systemName: "display.2").font(.title).foregroundStyle(MoonStyle.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stream.name).font(.headline)
                                Text("Desktop window open").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show desktop") { openWindow(id: "remote-desktop") }.buttonStyle(PrimaryButtonStyle())
                            Button("Disconnect") { client.disconnect() }
                        }
                    }
                }
                if client.pairedServers.servers.isEmpty {
                    ContentUnavailableView {
                        Label("Connect to your first Mac", systemImage: "desktopcomputer")
                    } description: {
                        Text("On the other Mac, open Pair a device and copy its pairing code. Then add it here.")
                    } actions: {
                        Button("Add host", systemImage: "plus") { client.showAddHost = true }
                            .buttonStyle(PrimaryButtonStyle()).disabled(client.session != nil)
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Paired hosts").font(.headline)
                        ForEach(client.pairedServers.servers) { paired in
                            MoonPanel {
                                HStack(spacing: 16) {
                                    Image(systemName: "desktopcomputer").font(.system(size: 28)).foregroundStyle(MoonStyle.accent).frame(width: 40)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(paired.name).font(.headline)
                                        Text(paired.invitation.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Connect") { client.connect(paired.id) }
                                        .buttonStyle(PrimaryButtonStyle()).disabled(client.session != nil)
                                        .accessibilityIdentifier("connectMac-\(paired.id)")
                                    Button("Apps", systemImage: "square.grid.2x2") {
                                        client.browseApps(paired.id); openWindow(id: "remote-apps")
                                    }.accessibilityIdentifier("macApps-\(paired.id)")
                                    Menu {
                                        Button("Forget host", role: .destructive) { forgetting = paired }
                                            .disabled(client.session?.serverID == paired.id)
                                    } label: { Image(systemName: "ellipsis.circle") }
                                        .menuStyle(.borderlessButton).fixedSize().help("Host actions")
                                }
                            }
                        }
                    }
                }
                Label("This Mac keeps sharing while you connect to another host.", systemImage: "arrow.left.arrow.right")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 950).frame(maxWidth: .infinity)
        }
        .background { NocturneBackdrop() }
        .navigationTitle("Computers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add host", systemImage: "plus") { client.showAddHost = true }.disabled(client.session != nil)
            }
        }
        .onAppear { client.load() }
        .confirmationDialog("Forget \(forgetting?.name ?? "host")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            if let paired = forgetting { Button("Forget host", role: .destructive) { client.forget(paired.id); forgetting = nil } }
        } message: { Text("Removes its saved pairing from this Mac. You can pair it again with a new code.") }
    }
}

struct MacAddHostView: View {
    @ObservedObject var client: MacClientModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Add a Mac", systemImage: "desktopcomputer").font(.title2.weight(.semibold))
            Text("On the other Mac, open Nocturne → Pair a device → Copy pairing code. Paste that code here within five minutes.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Pairing code", text: $code).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("macPairingCode")
                .onChange(of: code) { _, _ in client.error = nil }
            Button("Paste pairing code", systemImage: "doc.on.clipboard") {
                if let value = NSPasteboard.general.string(forType: .string) { code = value }
            }
            if let error = client.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { client.error = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add & connect") { _ = client.addHost(code) }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 500).background { NocturneBackdrop() }.tint(MoonStyle.accent)
    }
}
