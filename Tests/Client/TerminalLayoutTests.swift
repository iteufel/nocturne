import XCTest
import SwiftUI
import SwiftTerm
import Network
import NocturneKit
@testable import Nocturne

@MainActor
final class TerminalLayoutTests: XCTestCase {
    func testTerminalUsesTheAvailableCanvasWithTheKeyboardOpen() async throws {
        let key = "nocturne.client.onboardingComplete"
        let onboarding = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(onboarding, forKey: key) }
        let peer = try TerminalLayoutPeer(); try await peer.start()
        let app = ClientModel(voicePermission: { false })
        defer { app.suspend(); peer.stop() }
        try await app.server.connect(peer.invitation)
        app.page = .terminal
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ClientRootView(model: app))
        window.rootViewController = host
        let keyboard = host.view.keyboardLayoutGuide
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // The real SwiftTerm view opens its keyboard on selection, just as it does in the app.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        host.view.layoutIfNeeded()
        func terminals(_ view: UIView) -> [SwiftTerm.TerminalView] {
            (view as? SwiftTerm.TerminalView).map { [$0] } ?? view.subviews.flatMap(terminals)
        }
        let terminal = try XCTUnwrap(terminals(host.view).first)
        try await Task.sleep(nanoseconds: 500_000_000)
        host.view.layoutIfNeeded()
        for _ in 0..<20 where peer.columns != terminal.terminalDimensions.cols || peer.rows != terminal.terminalDimensions.rows {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let frame = terminal.convert(terminal.bounds, to: window)
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        let keyboardTop = host.view.convert(keyboard.layoutFrame, to: window).minY
        let availableHeight = min(safe.maxY, keyboardTop) - safe.minY
        print("Terminal canvas: \(frame), safe: \(safe), keyboard top: \(keyboardTop), PTY: \(terminal.terminalDimensions.cols)x\(terminal.terminalDimensions.rows)")
        XCTAssertTrue(terminal.isFirstResponder)
        XCTAssertGreaterThan(frame.width, safe.width * 0.9, "A terminal must not lose a quarter of its width to workspace navigation")
        XCTAssertGreaterThan(frame.height, availableHeight - 120, "Keep terminal controls compact when the keyboard is open")
        XCTAssertLessThanOrEqual(frame.maxY, keyboardTop + 1, "The shell must stay above the software keyboard")
        XCTAssertEqual(peer.columns, terminal.terminalDimensions.cols, "The remote PTY must follow the actual terminal width")
        XCTAssertEqual(peer.rows, terminal.terminalDimensions.rows, "The remote PTY must follow keyboard-driven resizing")
        let columns = terminal.terminalDimensions.cols
        let history = app.server.terminals.first?.history
        if ProcessInfo.processInfo.environment["NOCTURNE_CAPTURE_TERMINAL"] == "1" {
            try await Task.sleep(nanoseconds: 45_000_000_000)
        }
        terminal.resignFirstResponder()
        try await Task.sleep(nanoseconds: 500_000_000)
        host.view.layoutIfNeeded()
        for _ in 0..<20 where peer.rows != terminal.terminalDimensions.rows {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(terminal.bounds.height, frame.height, "Dismissing the keyboard returns its space to the shell")
        XCTAssertEqual(terminal.terminalDimensions.cols, columns)
        XCTAssertEqual(peer.rows, terminal.terminalDimensions.rows)
        XCTAssertEqual(app.server.terminals.first?.history, history, "Resizing must preserve the restored shell output")
    }
}

/// Real terminal restoration and resizing over TLS, without requiring a paired Mac.
@MainActor
private final class TerminalLayoutPeer {
    private let secret: Data
    private let listener: NWListener
    private var channels: [SecureChannel] = []
    private let terminal = RemoteTerminal(id: "layout", name: "Terminal 1", columns: 80, rows: 24)
    private(set) var columns = 80, rows = 24
    var invitation: PairingInvitation {
        try! PairingInvitation(host: "127.0.0.1", port: listener.port!.rawValue, name: "Layout Mac", secret: secret)
    }
    init() throws {
        secret = try SecureStore.randomKey()
        listener = try NWListener(using: SecureTransport.parameters(secret: secret), on: .any)
    }
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.listener.stateUpdateHandler = nil; continuation.resume()
                    case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }
    private func accept(_ connection: NWConnection) {
        let channel = SecureChannel(connection: connection), challenge = Data(repeating: 7, count: 32)
        channels.append(channel)
        channel.onPacket = { [weak self, weak channel] packet in
            Task { @MainActor in
                guard let self, let channel else { return }
                var reply = packet.reply()
                do {
                    switch packet.operation {
                    case .hello: reply.version = WorkspaceProtocol.version; reply.data = challenge
                    case .authenticate:
                        _ = try WorkspaceIdentity.verify(certificate: XCTUnwrap(packet.certificate), signature: XCTUnwrap(packet.signature), challenge: channel.boundChallenge(challenge))
                        reply.name = "Layout Mac"; reply.capabilities = ["terminal"]
                    case .terminalList: reply.terminals = [self.terminal]
                    case .terminalAttach:
                        reply.terminal = self.terminal
                        let data = Data("$ printf 'Ready for input\\n'\r\nReady for input\r\n$ ".utf8)
                        reply.data = data; reply.offset = 0; reply.size = Int64(data.count)
                    case .terminalResize:
                        self.columns = try XCTUnwrap(packet.columns); self.rows = try XCTUnwrap(packet.rows)
                    case .terminalInput, .ping: break
                    default: reply.error = "Unexpected request"
                    }
                } catch { reply.error = error.localizedDescription }
                channel.send(reply)
            }
        }
        channel.start()
    }
    func stop() { listener.cancel(); channels.forEach { $0.cancel() }; channels = [] }
}
