import SwiftUI
import NocturneKit

/// A remote image surface. Deliberately imports no WebKit and never loads a webpage URL.
@MainActor
final class BrowserWorkspaceModel: ObservableObject {
    @Published private(set) var frame: BrowserFrame?
    @Published private(set) var image: UIImage?
    @Published private(set) var busy = false
    @Published var error: String?
    private let isConnected: () -> Bool
    private let request: (Packet, TimeInterval?) async throws -> Packet
    private let sessionID = UUID().uuidString
    private var stopped = false
    private var opened = false
    init(connection: WorkspaceConnection) {
        isConnected = { connection.state == .connected }
        request = { try await connection.request($0, timeout: $1) }
    }
    init(isConnected: @escaping () -> Bool, request: @escaping (Packet, TimeInterval?) async throws -> Packet) {
        self.isConnected = isConnected; self.request = request
    }
    func run() async {
        await send(.init(.open))
        while !Task.isCancelled, !stopped, opened, isConnected() {
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break }
            if !busy { await send(.init(.frame)) }
        }
        await stop()
    }
    func send(_ command: BrowserCommand) async {
        guard !stopped, !busy, isConnected() else { return }
        busy = true; defer { busy = false }
        var command = command
        if command.page == nil { command.page = frame?.page }
        var packet = Packet(.browserCommand); packet.sessionID = sessionID; packet.browserCommand = command
        do {
            let reply = try await request(packet, nil)
            if command.action == .open { opened = true }
            guard !stopped, !Task.isCancelled else { return }
            guard let next = reply.browserFrame else { throw NocturneError.invalidFrame }
            if let jpeg = next.jpeg {
                guard jpeg.count <= BrowserProtocol.maximumImageBytes, let decoded = UIImage(data: jpeg),
                      decoded.size.width <= 4096, decoded.size.height <= 4096 else { throw NocturneError.invalidFrame }
                image = decoded; frame = next
            } else if frame == nil { frame = next }
            error = nil
        } catch {
            guard !stopped, !Task.isCancelled else { return }
            image = nil; frame = nil
            self.error = error.localizedDescription
        }
    }
    func stop() async {
        guard !stopped else { return }; stopped = true; image = nil; frame = nil
        // Even if open was cancelled before its reply, close this specific session, never a later one.
        var packet = Packet(.browserCommand); packet.sessionID = sessionID; packet.browserCommand = .init(.close)
        // SwiftUI cancels .task when hidden. An unstructured cleanup task must still send close.
        await Task { @MainActor [request] in
            _ = try? await request(packet, 3)
        }.value
    }
}

@MainActor
struct BrowserWorkspace: View {
    @ObservedObject var connection: WorkspaceConnection
    @StateObject private var browser: BrowserWorkspaceModel
    @State private var address = "http://localhost:3000"
    @State private var input = ""
    let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    init(connection: WorkspaceConnection, close: @escaping () -> Void) {
        self.connection = connection; self.close = close
        _browser = StateObject(wrappedValue: BrowserWorkspaceModel(connection: connection))
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Browser on " + connection.name, systemImage: "globe").font(.headline).lineLimit(1)
                Spacer()
                Button("Close", systemImage: "xmark", action: close).labelStyle(.iconOnly)
            }
            Text("Runs on your Mac. localhost and LAN addresses use your Mac’s network.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("http://localhost:3000", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder).onSubmit(navigate)
                    .accessibilityIdentifier("browserAddress")
                Button("Go", action: navigate).disabled(browser.busy)
            }
            HStack {
                Button("Back", systemImage: "chevron.left") { send(.init(.back)) }.disabled(browser.frame?.canGoBack != true)
                Button("Forward", systemImage: "chevron.right") { send(.init(.forward)) }.disabled(browser.frame?.canGoForward != true)
                Button("Reload", systemImage: "arrow.clockwise") { send(.init(.reload)) }
                Spacer()
                Button("Scroll up", systemImage: "arrow.up") { send(.init(.scroll, y: -500)) }
                Button("Scroll down", systemImage: "arrow.down") { send(.init(.scroll, y: 500)) }
            }.labelStyle(.iconOnly).disabled(browser.busy || browser.frame == nil)
            if let frame = browser.frame, !frame.url.isEmpty {
                Text(frame.url).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).accessibilityIdentifier("browserCurrentURL")
            }
            GeometryReader { geometry in
                if let image = browser.image {
                    let width = min(geometry.size.width, geometry.size.height * 4 / 3)
                    let height = width * 3 / 4
                    Image(uiImage: image).resizable().frame(width: width, height: height)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            send(.init(.click, x: location.x / width, y: location.y / height))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Remote Mac web page. Tap to interact; use text and scroll controls below.")
                } else { ContentUnavailableView("Private browser on your Mac", systemImage: "globe", description: Text("Enter an address and choose Go.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.background(Color.black.opacity(0.05)).clipped()
            if browser.frame?.loading == true { ProgressView().controlSize(.small) }
            if let notice = browser.frame?.notice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            if let error = browser.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
            HStack {
                SecureField("Text for focused field", text: $input).textFieldStyle(.roundedBorder).onSubmit(sendText)
                Button("Type", action: sendText).disabled(input.isEmpty)
                Button("Enter") { send(.init(.enter)) }
                Menu {
                    Button("Tab") { send(.init(.tab)) }
                    Button("Backspace") { send(.init(.backspace)) }
                } label: { Image(systemName: "keyboard") }
            }.disabled(browser.busy || browser.frame == nil)
            Text("Private session · no downloads, uploads, camera or microphone · closes when hidden").font(.caption2).foregroundStyle(.secondary)
        }.padding(12).background(.background)
            .task { await browser.run() }
            .onChange(of: connection.state) { _, state in if state != .connected { close() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { close() } }
            .accessibilityIdentifier("hostBrowserWorkspace")
    }
    private func send(_ command: BrowserCommand) { Task { await browser.send(command) } }
    private func sendText() { let text = input; input = ""; send(.init(.text, value: text)) }
    private func navigate() {
        do { _ = try BrowserProtocol.destination(address); send(.init(.navigate, value: address)) }
        catch { browser.error = error.localizedDescription }
    }
}
