import SwiftUI
import NocturneKit

struct StreamWorkspace: View {
    @ObservedObject var model: ClientModel
    @ObservedObject var session: StreamSession
    @Environment(\.displayScale) private var displayScale
    @State private var showTools = false
    @State private var tool = 0
    var body: some View {
        GeometryReader { geometry in
            // Landscape phones need a side panel too; a fixed bottom panel
            // would cover almost all of their short video viewport.
            let wide = geometry.size.width >= 900 || (geometry.size.width >= 700 && geometry.size.width > geometry.size.height)
            let toolHeight = min(340, geometry.size.height / 2)
            let viewport = CGSize(width: wide && showTools ? geometry.size.width - 340 : geometry.size.width,
                height: !wide && showTools ? geometry.size.height - toolHeight : geometry.size.height)
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                Group {
                    if let controller = session.controller {
                        StreamSurface(controller: controller, engine: model.engine).id(ObjectIdentifier(controller))
                    } else {
                        VStack(spacing: 14) { ProgressView(); Text(session.status).font(.callout).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(width: viewport.width, height: viewport.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if showTools {
                    VStack(spacing: 0) {
                        HStack {
                            Picker("Tool", selection: $tool) { Text("Terminal").tag(0); Text("Files").tag(1) }.pickerStyle(.segmented)
                            Button("Hide tools", systemImage: "xmark") { showTools = false }.labelStyle(.iconOnly).buttonStyle(NocturneGlassButtonStyle())
                        }.padding(12)
                        if tool == 0 { TerminalWorkspace(connection: model.server, connect: {
                            if model.savedServerName != nil { Task { await model.reconnectServer() } }
                            else { model.endStream(); model.showAdd = true }
                        }) }
                        else { FilesWorkspace(connection: model.server, connect: { model.endStream(); model.showAdd = true }) }
                    }.frame(width: wide ? 340 : geometry.size.width, height: wide ? geometry.size.height : toolHeight)
                        .background { NocturneBackdrop() }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: wide ? .trailing : .bottom)
                }
                HStack(spacing: 8) {
                    Menu {
                        Text(session.app.name + " · " + session.host.name)
                        if let size = session.size { Text("\(size.width) × \(size.height) · \(size.frameRate) fps") }
                        Picker("Input mode", selection: Binding(get: { session.preferences.inputMode }, set: model.setInputMode)) {
                            ForEach(StreamInputMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                        }
                        Divider()
                        Button("Terminal", systemImage: "terminal") { tool = 0; showTools = true }
                        Button("Files", systemImage: "folder") { tool = 1; showTools = true }
                        Button(showTools ? "Hide tools" : "Show tools", systemImage: "sidebar.right") { showTools.toggle() }
                        Divider()
                        Button("Disconnect stream", systemImage: "xmark", role: .destructive) { model.endStream() }
                    } label: { Image(systemName: "moon.fill").font(.system(size: 17)).frame(width: 44, height: 44) }
                        .nocturneGlass(in: Circle(), interactive: true).accessibilityLabel("Stream controls")
                }.padding(.leading, geometry.safeAreaInsets.leading + 10).padding(.top, geometry.safeAreaInsets.top + 8)
            }.onChange(of: viewport, initial: true) { _, size in model.streamViewport(size, scale: displayScale, session: session) }
                .onChange(of: displayScale) { _, scale in model.streamViewport(viewport, scale: scale, session: session) }
        }.ignoresSafeArea().tint(MoonStyle.accent).preferredColorScheme(.dark).persistentSystemOverlays(.hidden)
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
