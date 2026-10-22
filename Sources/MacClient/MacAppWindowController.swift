import AppKit
import SwiftUI
import Combine
import NocturneKit

final class MacRemoteAppWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { close() }
}

/// The captured Mac window supplies its own title bar. Local chrome consists
/// only of a small handle above the video; it never forwards a drag to the host.
@MainActor
final class MacAppWindowController: NSWindowController, NSWindowDelegate {
    static let handleHeight: CGFloat = 14
    let stream: MacDesktopSession
    private var observation: AnyCancellable?
    private var onClose: (() -> Void)?
    private var fixedAspect: CGFloat?
    private var lastHostWindow: RemoteAppWindow?

    init(stream: MacDesktopSession, onClose: @escaping () -> Void) {
        self.stream = stream; self.onClose = onClose
        let window = MacRemoteAppWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 614),
            styleMask: [.borderless, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = stream.title
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = .init(width: 240, height: 160 + Self.handleHeight)
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        let menu = NSMenu()
        for (title, action) in [("Fit window to app", #selector(fitToApp)), ("Reconnect", #selector(reconnect)),
                                ("Toggle full screen", #selector(fullScreen)), ("Close stream", #selector(closeStream))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        window.contentView = NSHostingView(rootView: MacAppWindowContent(stream: stream, menu: menu))
        fitToApp(); window.center()
        observation = stream.$appWindow.sink { [weak self] window in self?.applyHostGeometry(window) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); stream.activate() }
    func windowWillClose(_ notification: Notification) {
        observation?.cancel(); observation = nil
        stream.stop()
        let callback = onClose; onClose = nil; callback?()
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let fixedAspect, fixedAspect > 0 else { return frameSize }
        return .init(width: frameSize.width, height: frameSize.width / fixedAspect + Self.handleHeight)
    }
    private func applyHostGeometry(_ host: RemoteAppWindow?) {
        guard let host, host != lastHostWindow, host.width > 0, host.height > 0, let window else { return }
        lastHostWindow = host
        fixedAspect = host.isResizable == false ? CGFloat(host.width) / CGFloat(host.height) : nil
        window.contentMinSize = host.isResizable == false ? .init(width: 100, height: 80 + Self.handleHeight)
            : .init(width: 240, height: 160 + Self.handleHeight)
        let actual = CGFloat(host.width) / CGFloat(host.height)
        let current = window.frame.width / max(1, window.frame.height - Self.handleHeight)
        guard abs(actual - current) > 0.002, !window.styleMask.contains(.fullScreen) else { return }
        let size = Self.fitting(video: .init(width: host.width, height: host.height), inside: window.frame.size, upscale: true)
        window.setContentSize(size)
    }
    static func fitting(video: CGSize, inside available: CGSize, upscale: Bool = false) -> CGSize {
        guard video.width.isFinite, video.height.isFinite, video.width > 0, video.height > 0 else { return .init(width: 800, height: 614) }
        let factor = max(0.01, min(upscale ? .greatestFiniteMagnitude : 1,
            available.width / video.width, max(1, available.height - handleHeight) / video.height))
        return .init(width: video.width * factor, height: video.height * factor + handleHeight)
    }
    @objc private func fitToApp() {
        guard let window else { return }
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? .init(width: 1200, height: 800)
        let host = stream.appWindow
        let source = CGSize(width: host?.width ?? 800, height: host?.height ?? 600)
        window.setContentSize(Self.fitting(video: source, inside: .init(width: max(240, available.width - 80), height: max(200, available.height - 80))))
    }
    @objc private func reconnect() { stream.reconnect() }
    @objc private func fullScreen() { window?.toggleFullScreen(nil) }
    @objc private func closeStream() { close() }
}

private struct MacAppWindowContent: View {
    @ObservedObject var stream: MacDesktopSession
    let menu: NSMenu
    @Environment(\.displayScale) private var scale
    var body: some View {
        VStack(spacing: 0) {
            MacAppHandle(menu: menu).frame(width: 64, height: MacAppWindowController.handleHeight)
                .frame(maxWidth: .infinity)
            GeometryReader { geometry in
                ZStack {
                    MacAppSurface(surface: stream.surface)
                    if let error = stream.error {
                        VStack(spacing: 12) {
                            Text(error).font(.callout).multilineTextAlignment(.center)
                            Button("Reconnect") { stream.reconnect() }
                        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                    } else if !stream.ready {
                        ProgressView(stream.status).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                    }
                }
                .onChange(of: geometry.size, initial: true) { _, size in stream.viewport(size, scale: scale) }
                .onChange(of: scale) { _, value in stream.viewport(geometry.size, scale: value) }
            }
        }.preferredColorScheme(.dark)
    }
}

private struct MacAppSurface: NSViewRepresentable {
    let surface: MacVideoView
    func makeNSView(context: Context) -> MacVideoView { surface }
    func updateNSView(_ view: MacVideoView, context: Context) {}
    static func dismantleNSView(_ view: MacVideoView, coordinator: ()) { view.releaseInput() }
}

private struct MacAppHandle: NSViewRepresentable {
    let menu: NSMenu
    func makeNSView(context: Context) -> MacAppHandleView { let view = MacAppHandleView(); view.menu = menu; return view }
    func updateNSView(_ view: MacAppHandleView, context: Context) { view.menu = menu }
}

private final class MacAppHandleView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Remote window handle")
        setAccessibilityHelp("Drag to move this window. Right-click for reconnect, full screen, and close controls.")
        toolTip = "Drag to move. Right-click for window controls."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: .init(x: (bounds.width - 32) / 2, y: (bounds.height - 4) / 2, width: 32, height: 4), xRadius: 2, yRadius: 2).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func accessibilityPerformPress() -> Bool {
        guard let menu else { return false }
        menu.popUp(positioning: nil, at: .init(x: 0, y: bounds.maxY), in: self); return true
    }
}
