import SwiftUI
import NocturneKit

/// Frames are relative to the safe area. Only the video may extend beyond it.
struct StreamWorkspaceLayout {
    let video: CGRect
    let tools: CGRect

    init(size: CGSize, insets: EdgeInsets, fillEntireScreen: Bool, showTools: Bool) {
        let wide = size.width >= 900 || (size.width >= 700 && size.width > size.height)
        let toolWidth = min(340, size.width / 2)
        let toolHeight = min(340, size.height / 2)
        let safeVideo = CGRect(x: 0, y: 0,
            width: max(0, size.width - (wide && showTools ? toolWidth : 0)),
            height: max(0, size.height - (!wide && showTools ? toolHeight : 0)))
        tools = wide
            ? CGRect(x: size.width - toolWidth, y: 0, width: toolWidth, height: size.height)
            : CGRect(x: 0, y: size.height - toolHeight, width: size.width, height: toolHeight)
        video = fillEntireScreen
            ? CGRect(x: -insets.leading, y: -insets.top,
                width: safeVideo.width + insets.leading + (wide && showTools ? 0 : insets.trailing),
                height: safeVideo.height + insets.top + (!wide && showTools ? 0 : insets.bottom))
            : safeVideo
    }
}

struct StreamWorkspace: View {
    @ObservedObject var model: ClientModel
    @ObservedObject var session: StreamSession
    @Environment(\.displayScale) private var displayScale
    @State private var showTools = false
    @State private var tool = 0
    @State private var showControls = false
    @State private var showControlsHint = true

    var body: some View {
        GeometryReader { geometry in
            let layout = StreamWorkspaceLayout(size: geometry.size, insets: geometry.safeAreaInsets,
                fillEntireScreen: session.preferences.fillEntireScreen, showTools: showTools)
            ZStack(alignment: .topLeading) {
                Group {
                    if let controller = session.controller {
                        StreamSurface(controller: controller, engine: model.engine).id(ObjectIdentifier(controller))
                    } else {
                        VStack(spacing: 14) { ProgressView(); Text(session.status).font(.callout).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: layout.video.width, height: layout.video.height)
                .clipped()
                .offset(x: layout.video.minX, y: layout.video.minY)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Stream")
                .accessibilityAction { openControls() }
                .accessibilityAction(named: Text("Open stream controls")) { openControls() }

                if showTools {
                    StreamToolsPanel(model: model, connection: model.server, showTools: $showTools, tool: $tool)
                        .frame(width: layout.tools.width, height: layout.tools.height)
                        .background { NocturneBackdrop() }
                        .clipped()
                        .offset(x: layout.tools.minX, y: layout.tools.minY)
                }

                if showControlsHint {
                    Label("Swipe from the right edge for controls", systemImage: "arrow.left")
                        .font(.footnote.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .onChange(of: layout.video.size, initial: true) { _, size in model.streamViewport(size, scale: displayScale, session: session) }
            .onChange(of: displayScale) { _, scale in model.streamViewport(layout.video.size, scale: scale, session: session) }
        }
        .background(Color.black.ignoresSafeArea())
        .background { StreamControlsGesture(enabled: !showControls) { openControls() }.allowsHitTesting(false) }
        .onReceive(model.microphone.$error.dropFirst()) { error in
            if error != nil { openControls() }
        }
        .sheet(isPresented: $showControls) {
            StreamControlsMenu(model: model, session: session, microphone: model.microphone,
                connection: model.server, showTools: $showTools, tool: $tool)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            showControlsHint = false
        }
        .tint(MoonStyle.accent).preferredColorScheme(.dark).persistentSystemOverlays(.hidden)
    }

    private func openControls() { showControlsHint = false; showControls = true }
}

private struct StreamToolsPanel: View {
    @ObservedObject var model: ClientModel
    @ObservedObject var connection: WorkspaceConnection
    @Binding var showTools: Bool
    @Binding var tool: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Tool", selection: $tool) { Text("Terminal").tag(0); Text("Files").tag(1) }.pickerStyle(.segmented)
                Button("Hide tools", systemImage: "xmark") { showTools = false }
                    .labelStyle(.iconOnly).buttonStyle(NocturneGlassButtonStyle())
            }.padding(12)
            GeometryReader { geometry in
                Group {
                    if connection.state != .connected && (tool == 1 || connection.terminals.isEmpty) {
                        ScrollView { content.frame(minHeight: geometry.size.height) }
                    } else { content }
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if tool == 0 {
            TerminalWorkspace(connection: connection, connect: {
                if model.savedServerName != nil { Task { await model.reconnectServer() } }
                else { model.endStream(); model.showAdd = true }
            })
        } else {
            FilesWorkspace(connection: connection, connect: { model.endStream(); model.showAdd = true })
        }
    }
}

struct StreamControlsMenu: View {
    @ObservedObject var model: ClientModel
    @ObservedObject var session: StreamSession
    @ObservedObject var microphone: ClientMicrophone
    @ObservedObject var connection: WorkspaceConnection
    @Binding var showTools: Bool
    @Binding var tool: Int
    @Environment(\.dismiss) private var dismiss
    @State private var showMicrophoneInfo = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { microphone.active || microphone.starting }, set: { _ in toggleMicrophone() })) {
                        Label(microphone.starting ? "Connecting microphone…" : "Microphone", systemImage: microphone.active ? "mic.fill" : "mic.slash")
                    }.accessibilityIdentifier("streamMicrophone")
                    if microphone.active { Text(microphone.inputName).font(.caption).foregroundStyle(.secondary) }
                    Button("Microphone setup", systemImage: "info.circle") { showMicrophoneInfo = true }
                } footer: { Text("Your microphone stays muted until you turn it on.") }

                Section {
                    Toggle("Fill entire screen", isOn: Binding(get: { session.preferences.fillEntireScreen }, set: model.setFillEntireScreen))
                        .accessibilityIdentifier("streamFillEntireScreen")
                    Picker("Input mode", selection: Binding(get: { session.preferences.inputMode }, set: model.setInputMode)) {
                        ForEach(StreamInputMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                    }
                } footer: {
                    Text("Off keeps the picture inside the safe area, clear of the camera and rounded corners. On fills the screen, cropping edges when needed to preserve proportions.")
                }

                Section {
                    Button("Terminal", systemImage: "terminal") { tool = 0; showTools = true; dismiss() }
                    Button("Files", systemImage: "folder") { tool = 1; showTools = true; dismiss() }
                    if showTools { Button("Hide tools", systemImage: "sidebar.right") { showTools = false; dismiss() } }
                }
                Section {
                    Button("Disconnect stream", systemImage: "xmark", role: .destructive) { dismiss(); model.endStream() }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.app.name + " · " + session.host.name)
                        if let size = session.size { Text("\(size.width) × \(size.height) · \(size.frameRate) fps") }
                    }
                }
            }
            .navigationTitle("Stream controls").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(MoonStyle.accent).preferredColorScheme(.dark)
        .alert("Client microphone", isPresented: $showMicrophoneInfo) {
            Button("Done", role: .cancel) {}
        } message: { Text(microphoneExplanation) }
        .onChange(of: microphone.error, initial: true) { _, error in if error != nil { showMicrophoneInfo = true } }
    }

    private func toggleMicrophone() {
        if microphone.active || microphone.starting || model.canUseMicrophone { model.toggleMicrophone() }
        else { showMicrophoneInfo = true }
    }

    private var microphoneExplanation: String {
        if let error = microphone.error { return error }
        if !session.videoReady { return "Your stream is still connecting. Unmute after it starts." }
        return "On your Mac, open Nocturne Server → Sharing, enable Client microphone, and install the microphone input. Pair using the server’s QR code and reconnect after enabling it.\n\nChoose Nocturne Microphone as the input in Discord or your game. Headphones help keep game audio out of voice chat."
    }
}

/// Listen on the containing window without putting a hit-testing view over the stream.
/// Delaying edge touches keeps the reveal gesture out of the remote computer's input.
struct StreamControlsGesture: UIViewRepresentable {
    var enabled = true
    let open: () -> Void
    func makeUIView(context: Context) -> StreamControlsGestureView { StreamControlsGestureView(open: open) }
    func updateUIView(_ view: StreamControlsGestureView, context: Context) { view.open = open; view.gestureEnabled = enabled }
    static func dismantleUIView(_ view: StreamControlsGestureView, coordinator: ()) { view.detach() }
}

final class StreamControlsGestureView: UIView, UIGestureRecognizerDelegate {
    var open: () -> Void
    var gestureEnabled: Bool {
        get { edgeGesture.isEnabled }
        set { edgeGesture.isEnabled = newValue }
    }
    private weak var gestureWindow: UIWindow?
    private lazy var edgeGesture: UIPanGestureRecognizer = {
        // A scene-relative edge region also works in an iPad window.
        // Ignore all touches outside it so ordinary stream input is unaffected.
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(reveal(_:)))
        gesture.delegate = self
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        gesture.maximumNumberOfTouches = 1
        gesture.delaysTouchesBegan = true
        gesture.cancelsTouchesInView = true
        gesture.name = "Nocturne stream controls"
        return gesture
    }()
    init(open: @escaping () -> Void) { self.open = open; super.init(frame: .zero); isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        if let window { window.addGestureRecognizer(edgeGesture); gestureWindow = window }
    }
    func detach() { gestureWindow?.removeGestureRecognizer(edgeGesture); gestureWindow = nil }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = gestureRecognizer.view else { return false }
        return touch.location(in: view).x >= view.bounds.maxX - 24
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = edgeGesture.velocity(in: edgeGesture.view)
        return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
    }
    @objc private func reveal(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .ended, gesture.translation(in: gesture.view).x < -24 { open() }
    }
}

struct StreamSurface: UIViewControllerRepresentable {
    let controller: UIViewController
    let engine: NocturneStreamingService
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    func makeCoordinator() -> NocturneStreamingService { engine }
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: NocturneStreamingService) { coordinator.stopController(uiViewController) }
}
