import NocturneKit
import SwiftUI
import NocturneMacClient

struct MacDesktopWorkspace: View {
    @ObservedObject var stream: MacDesktopSession
    @ObservedObject var client: MacClientModel
    @Environment(\.displayScale) private var scale
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                MacDesktopSurface(stream: stream)
                if let error = stream.error {
                    ContentUnavailableView {
                        Label(stream.route == nil ? L("Desktop disconnected") : L("App window disconnected"), systemImage: "display.trianglebadge.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button(L("Reconnect")) { stream.reconnect() }.buttonStyle(.borderedProminent)
                    }.background(.black)
                } else if !stream.ready {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(stream.status).font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                }
            }
            .onChange(of: geometry.size, initial: true) { _, size in stream.viewport(size, scale: scale) }
            .onChange(of: scale) { _, scale in stream.viewport(geometry.size, scale: scale) }
        }
        .navigationTitle(stream.title)
        .navigationSubtitle(stream.route == nil ? (stream.screenLocked ? L("Lock screen · Enter your Mac password to unlock") : "") : stream.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(L("Disconnect"), systemImage: "xmark") {
                    if let route = stream.route { client.disconnectApp(route.id); dismiss() }
                    else { client.disconnect(); dismissWindow(id: "remote-desktop") }
                }.help(L("Disconnect from this Mac"))
            }
            ToolbarItem {
                if let display = stream.display {
                    Text("\(display.width) × \(display.height)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ToolbarItem {
                if stream.route == nil {
                    Button(L("Apps"), systemImage: "square.grid.2x2") {
                        client.browseApps(stream.serverID); openWindow(id: "remote-apps")
                    }.disabled(stream.connection.state != .connected)
                }
            }
            ToolbarItem {
                if stream.route == nil {
                    Menu {
                        Button {
                            stream.matchWindow(true)
                        } label: {
                            if stream.matchesWindow { Label(L("Match window"), systemImage: "checkmark") }
                            else { Text(L("Match window")) }
                        }
                        Divider()
                        ForEach(stream.displays) { display in
                            Button {
                                stream.selectDisplay(display.id)
                            } label: {
                                if !stream.matchesWindow, display.id == stream.selectedDisplayID { Label(display.name, systemImage: "checkmark") }
                                else { Text(display.name) }
                            }
                        }
                    } label: { Label(L("Displays"), systemImage: "display.2") }.disabled(stream.displays.isEmpty)
                }
            }
            ToolbarItem {
                if stream.route == nil {
                    Button(stream.muted ? L("Unmute audio") : L("Mute audio"), systemImage: stream.muted ? "speaker.slash" : "speaker.wave.2") { stream.muted.toggle() }
                        .help(stream.audioError ?? (stream.muted ? L("Unmute host audio") : L("Mute host audio")))
                }
            }
            ToolbarItem {
                Menu {
                    Text(stream.connection.connectionRoute ?? L("Connecting"))
                    Text(L("Click the desktop to control it. Press ⌃⌥Esc to release the keyboard."))
                    if let error = stream.audioError { Text(L("Audio unavailable: %@", "\(error)")) }
                    Divider()
                    Button(L("Toggle full screen"), systemImage: "arrow.up.left.and.arrow.down.right") { stream.surface.window?.toggleFullScreen(nil) }
                    Button(L("Reconnect"), systemImage: "arrow.clockwise") { stream.reconnect() }
                } label: { Label(L("Desktop controls"), systemImage: "ellipsis.circle") }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { stream.activate() }
        .onDisappear {
            if let route = stream.route, client.appSessions[route.id] === stream { client.disconnectApp(route.id) }
            else if client.session === stream { client.disconnect() }
        }
    }
}

private struct MacDesktopSurface: NSViewRepresentable {
    let stream: MacDesktopSession
    func makeNSView(context: Context) -> MacVideoView { stream.surface }
    func updateNSView(_ nsView: MacVideoView, context: Context) {}
    static func dismantleNSView(_ nsView: MacVideoView, coordinator: ()) { nsView.releaseInput() }
}
