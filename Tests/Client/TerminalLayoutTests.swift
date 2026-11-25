import XCTest
import SwiftUI
import SwiftTerm
import Network
import NocturneKit
@testable import Nocturne

@MainActor
final class TerminalLayoutTests: XCTestCase {
    func testTerminalUsesTheAvailableCanvasWithTheKeyboardOpen() async throws {
        try await verifyTerminal(alternateKeyboard: false)
    }
    func testAlternateKeyboardStillHasReachableControls() async throws {
        try await verifyTerminal(alternateKeyboard: true)
    }
    private func verifyTerminal(alternateKeyboard: Bool) async throws {
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
        if alternateKeyboard {
            func buttons(_ view: UIView) -> [UIButton] {
                (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons)
            }
            let accessory = try XCTUnwrap(terminal.inputAccessoryView)
            let toggle = try XCTUnwrap(buttons(accessory).first { button in
                button.allTargets.contains { target in
                    button.actions(forTarget: target.base, forControlEvent: .touchDown)?.contains("toggleInputKeyboard:") == true
                }
            })
            toggle.sendActions(for: .touchDown)
            XCTAssertNotNil(terminal.inputView, "Exercise SwiftTerm's actual alternate keyboard, not a synthetic dismissal")
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        // Wait for keyboard animation and the debounced PTY resize, rather than sampling a transition frame.
        for _ in 0..<60 {
            host.view.layoutIfNeeded()
            let canvas = terminal.convert(terminal.bounds, to: window)
            let safe = window.bounds.inset(by: window.safeAreaInsets)
            let keyboardTop = host.view.convert(keyboard.layoutFrame, to: window).minY
            if abs(canvas.minY - safe.minY) < 1,
               abs(canvas.maxY - keyboardTop) < 1,
               peer.columns == terminal.terminalDimensions.cols, peer.rows == terminal.terminalDimensions.rows { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let frame = terminal.convert(terminal.bounds, to: window)
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        let keyboardTop = host.view.convert(keyboard.layoutFrame, to: window).minY
        let availableHeight = min(safe.maxY, keyboardTop) - safe.minY
        print("Terminal canvas: \(frame), safe: \(safe), keyboard top: \(keyboardTop), PTY: \(terminal.terminalDimensions.cols)x\(terminal.terminalDimensions.rows)")
        XCTAssertTrue(terminal.isFirstResponder)
        XCTAssertEqual(frame.width, safe.width, accuracy: 1, "The shell must fill the canvas without horizontal padding")
        XCTAssertEqual(frame.minY, safe.minY, accuracy: 1, "No header or tab bar may reserve space above the shell")
        XCTAssertEqual(frame.height, availableHeight, accuracy: 1, "Only the terminal should occupy the area above the keyboard")
        XCTAssertLessThanOrEqual(frame.maxY, keyboardTop + 1, "The shell must stay above the software keyboard")
        XCTAssertEqual(peer.columns, terminal.terminalDimensions.cols, "The remote PTY must follow the actual terminal width")
        XCTAssertEqual(peer.rows, terminal.terminalDimensions.rows, "The remote PTY must follow keyboard-driven resizing")
        let columns = terminal.terminalDimensions.cols
        let history = app.server.terminals.first?.history
        if ProcessInfo.processInfo.environment["NOCTURNE_CAPTURE_TERMINAL"] == "1" {
            // Leave the live fixture available for manually testing navigation away from Terminal.
            for _ in 0..<2 { try await Task.sleep(nanoseconds: 45_000_000_000) }
            return
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
        // The user must be able to leave Terminal without a successful keyboard-dismiss gesture.
        terminal.becomeFirstResponder()
        try await Task.sleep(nanoseconds: 500_000_000)
        host.view.layoutIfNeeded()
        func controlsButton(_ view: UIView) -> UIButton? {
            if let button = view as? UIButton, button.accessibilityIdentifier == "terminalControls" { return button }
            return view.subviews.lazy.compactMap(controlsButton).first
        }
        let controls = try XCTUnwrap(controlsButton(host.view), "Terminal controls must remain reachable with the keyboard open")
        let controlsFrame = controls.convert(controls.bounds, to: window)
        XCTAssertGreaterThanOrEqual(controlsFrame.width, 44)
        XCTAssertLessThanOrEqual(controlsFrame.maxY, host.view.convert(keyboard.layoutFrame, to: window).minY)
        let target = window.hitTest(CGPoint(x: controlsFrame.midX, y: controlsFrame.midY), with: nil)
        XCTAssertTrue(target === controls || target?.isDescendant(of: controls) == true, "Controls must be tappable above the keyboard")
        controls.sendActions(for: .touchUpInside)
        for _ in 0..<40 where terminal.isFirstResponder || host.presentedViewController == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(terminal.isFirstResponder, "Opening controls must end terminal editing without a keyboard gesture")
        XCTAssertNotNil(host.presentedViewController, "The controls sheet must expose session and exit actions")
        host.dismiss(animated: false)
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
