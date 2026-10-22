import SwiftUI
import NocturneKit

struct AppWindowWorkspace: View {
    @ObservedObject var stream: AppWindowStreamModel
    @ObservedObject private var client = ClientModel.shared
    let close: () -> Void
    @Environment(\.displayScale) private var scale
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let insets = geometry.safeAreaInsets
                // Keep Close/Keyboard controls above the video while using the
                // camera-side and home-indicator areas when Fill is enabled.
                let layout = StreamWorkspaceLayout(size: geometry.size,
                    insets: EdgeInsets(top: 0, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing),
                    fillEntireScreen: client.preferences.fillEntireScreen, showTools: false)
                ZStack {
                    Color.black
                    AppWindowSurface(stream: stream, fillEntireScreen: client.preferences.fillEntireScreen)
                        .frame(width: layout.video.width, height: layout.video.height)
                        .clipped()
                        .position(x: layout.video.midX, y: layout.video.midY)
                    if let error = stream.error {
                        ContentUnavailableView {
                            Label("App window disconnected", systemImage: "macwindow")
                        } description: { Text(error) }
                        actions: { Button("Reconnect window") { stream.activate() }.buttonStyle(NocturneGlassButtonStyle()) }
                        .background(.black)
                    } else if !stream.ready {
                        VStack(spacing: 14) { ProgressView(); Text(stream.status).font(.callout).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onChange(of: layout.video.size, initial: true) { _, size in
                    stream.viewport(size, scale: scale, frameRate: client.preferences.frameRate)
                }
                .onChange(of: scale) { _, scale in stream.viewport(layout.video.size, scale: scale, frameRate: client.preferences.frameRate) }
            }.navigationTitle(stream.route.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close stream", systemImage: "xmark") { stream.deactivate(); close() }.labelStyle(.iconOnly)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Keyboard", systemImage: "keyboard") { stream.keyboardVisible.toggle() }.labelStyle(.iconOnly).disabled(!stream.ready)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Text(stream.connection.name)
                            if let display = stream.display { Text("\(display.width) × \(display.height) · \(display.frameRate) fps") }
                            Text("Only this app window is shared")
                            Toggle("Fill entire screen", isOn: Binding(get: { client.preferences.fillEntireScreen }, set: client.setFillEntireScreen))
                            Button("Reconnect window", systemImage: "arrow.clockwise") { stream.deactivate(); stream.activate() }
                            Button("Close stream", systemImage: "xmark", role: .destructive) { stream.deactivate(); close() }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("App window controls")
                    }
                }
        }.tint(MoonStyle.accent).preferredColorScheme(.dark)
            .onAppear { stream.activate() }
            .onDisappear { stream.deactivate() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { stream.activate() }
                else if phase == .background { stream.deactivate() }
            }
    }
}

private struct AppWindowSurface: UIViewRepresentable {
    @ObservedObject var stream: AppWindowStreamModel
    let fillEntireScreen: Bool
    func makeUIView(context: Context) -> AppWindowVideoView { stream.surface }
    func updateUIView(_ view: AppWindowVideoView, context: Context) {
        view.keyboardVisible = stream.keyboardVisible
        view.fillEntireScreen = fillEntireScreen
    }
}

struct AppWindowPhoneScene: View {
    @StateObject var stream: AppWindowStreamModel
    let close: () -> Void
    init(route: AppWindowRoute, client: ClientModel, close: @escaping () -> Void) {
        _stream = StateObject(wrappedValue: client.makeAppWindowStream(route)); self.close = close
    }
    var body: some View { AppWindowWorkspace(stream: stream, close: close) }
}
