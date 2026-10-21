import SwiftUI
import NocturneMacClient

struct MacDesktopWorkspace: View {
    @ObservedObject var stream: MacDesktopSession
    @ObservedObject var client: MacClientModel
    @Environment(\.displayScale) private var scale
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                MacDesktopSurface(stream: stream)
                if let error = stream.error {
                    ContentUnavailableView {
                        Label("Desktop disconnected", systemImage: "display.trianglebadge.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button("Reconnect") { stream.reconnect() }.buttonStyle(.borderedProminent)
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
        .navigationTitle(stream.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Disconnect", systemImage: "xmark") {
                    client.disconnect(); dismissWindow(id: "remote-desktop")
                }.help("Disconnect from this Mac")
            }
            ToolbarItem {
                if let display = stream.display {
                    Text("\(display.width) × \(display.height)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ToolbarItem {
                Menu {
                    ForEach(stream.displays) { display in
                        Button {
                            stream.selectDisplay(display.id)
                        } label: {
                            if display.id == stream.selectedDisplayID { Label(display.name, systemImage: "checkmark") }
                            else { Text(display.name) }
                        }
                    }
                } label: { Label("Displays", systemImage: "display.2") }.disabled(stream.displays.isEmpty)
            }
            ToolbarItem {
                Button(stream.muted ? "Unmute audio" : "Mute audio", systemImage: stream.muted ? "speaker.slash" : "speaker.wave.2") { stream.muted.toggle() }
                    .help(stream.audioError ?? (stream.muted ? "Unmute host audio" : "Mute host audio"))
            }
            ToolbarItem {
                Menu {
                    Text(stream.connection.connectionRoute ?? "Connecting")
                    Text("Click the desktop to control it. Press ⌃⌥Esc to release the keyboard.")
                    if let error = stream.audioError { Text("Audio unavailable: \(error)") }
                    Divider()
                    Button("Toggle full screen", systemImage: "arrow.up.left.and.arrow.down.right") { stream.surface.window?.toggleFullScreen(nil) }
                    Button("Reconnect", systemImage: "arrow.clockwise") { stream.reconnect() }
                } label: { Label("Desktop controls", systemImage: "ellipsis.circle") }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { stream.activate() }
        .onDisappear { if client.session === stream { client.disconnect() } }
    }
}

private struct MacDesktopSurface: NSViewRepresentable {
    let stream: MacDesktopSession
    func makeNSView(context: Context) -> MacVideoView { stream.surface }
    func updateNSView(_ nsView: MacVideoView, context: Context) {}
    static func dismantleNSView(_ nsView: MacVideoView, coordinator: ()) { nsView.releaseInput() }
}
