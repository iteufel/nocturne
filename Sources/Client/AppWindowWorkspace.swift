import SwiftUI
import NocturneKit

struct AppWindowWorkspace: View {
    @ObservedObject var stream: AppWindowStreamModel
    @ObservedObject private var client = ClientModel.shared
    let close: () -> Void
    @Environment(\.displayScale) private var scale
    @Environment(\.scenePhase) private var scenePhase
    @State private var showControls = false
    @State private var keyboardAfterControls = false

    var body: some View {
        GeometryReader { geometry in
            let layout = StreamWorkspaceLayout(size: geometry.size, insets: geometry.safeAreaInsets,
                fillEntireScreen: client.preferences.fillEntireScreen, showTools: false)
            ZStack {
                Color.black
                AppWindowSurface(stream: stream, fillEntireScreen: client.preferences.fillEntireScreen)
                    .frame(width: layout.video.width, height: layout.video.height)
                    .clipped()
                    .position(x: layout.video.midX, y: layout.video.midY)
                    .accessibilityAction(named: Text(L("Open stream controls"))) { openControls() }
                    .accessibilityAction(named: Text(L("Show keyboard"))) { showKeyboard() }
                if let error = stream.error {
                    ContentUnavailableView {
                        Label(L("App window disconnected"), systemImage: "macwindow")
                    } description: { Text(error) }
                    actions: { Button(L("Reconnect window")) { stream.activate() }.buttonStyle(NocturneGlassButtonStyle()) }
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
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .background {
            StreamControlsGesture(enabled: !showControls, open: openControls, keyboard: showKeyboard)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showControls, onDismiss: {
            if keyboardAfterControls { keyboardAfterControls = false; showKeyboard() }
        }) {
            AppWindowControlsMenu(stream: stream, client: client, showKeyboard: {
                keyboardAfterControls = true; showControls = false
            }, close: close)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .tint(MoonStyle.accent).preferredColorScheme(.dark).persistentSystemOverlays(.hidden)
        .onAppear { stream.activate() }
        .onDisappear { stream.deactivate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { stream.activate() }
            else if phase == .background { stream.deactivate() }
        }
    }
    private func openControls() { stream.keyboardVisible = false; showControls = true }
    private func showKeyboard() { if stream.ready { stream.keyboardVisible = true } }
}

struct AppWindowControlsMenu: View {
    @ObservedObject var stream: AppWindowStreamModel
    @ObservedObject var client: ClientModel
    let showKeyboard: () -> Void
    let close: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(L("Show keyboard"), systemImage: "keyboard") { showKeyboard(); dismiss() }
                        .disabled(!stream.ready).accessibilityIdentifier("appWindowKeyboard")
                    Toggle(L("Fill entire screen"), isOn: Binding(get: { client.preferences.fillEntireScreen }, set: client.setFillEntireScreen))
                    Button(L("Reconnect window"), systemImage: "arrow.clockwise") { dismiss(); stream.deactivate(); stream.activate() }
                }
                Section {
                    Button(L("Close stream"), systemImage: "xmark", role: .destructive) { dismiss(); stream.deactivate(); close() }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stream.connection.name)
                        if let display = stream.display { Text(L("%@ × %@ · %@ fps", display.width.formatted(), display.height.formatted(), display.frameRate.formatted())) }
                        Text(L("Only this Mac window is shared"))
                    }
                }
            }
            .navigationTitle(L("App window controls")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .tint(MoonStyle.accent).preferredColorScheme(.dark)
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
