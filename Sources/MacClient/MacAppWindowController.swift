import AppKit
import SwiftUI
import Combine
import NocturneKit

final class MacRemoteAppWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { close() }
}

/// The native title bar moves the viewer and native window edges resize it.
/// Both remain outside the captured app's input surface.
@MainActor
final class MacAppWindowController: NSWindowController, NSWindowDelegate {
    static let borderWidth: CGFloat = 6
    let stream: MacDesktopSession
    private var observation: AnyCancellable?
    private var onClose: (() -> Void)?
    private var fixedAspect: CGFloat?
    private var lastHostWindow: RemoteAppWindow?

    init(stream: MacDesktopSession, onClose: @escaping () -> Void) {
        self.stream = stream; self.onClose = onClose
        let window = MacRemoteAppWindow(contentRect: .init(origin: .zero, size: Self.contentSize(for: .init(width: 800, height: 600))),
            styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = stream.title
        window.isMovable = true; window.titleVisibility = .visible
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true; window.backgroundColor = .windowBackgroundColor; window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.contentSize(for: .init(width: 240, height: 160))
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        let menu = NSMenu()
        for (title, action) in [(L("Fit window to app"), #selector(fitToApp)), (L("Reconnect"), #selector(reconnect)),
                                (L("Toggle full screen"), #selector(fullScreen)), (L("Close stream"), #selector(closeStream))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        window.contentView = MacAppWindowContentView(stream: stream, menu: menu)
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
        let content = sender.contentRect(forFrameRect: .init(origin: .zero, size: frameSize)).size
        var video = Self.videoSize(in: content)
        let previous = Self.videoSize(in: sender.contentView?.bounds.size ?? content)
        if abs(video.width - previous.width) >= abs(video.height - previous.height) * fixedAspect {
            video.height = video.width / fixedAspect
        } else { video.width = video.height * fixedAspect }
        return sender.frameRect(forContentRect: .init(origin: .zero, size: Self.contentSize(for: video))).size
    }
    func windowDidResize(_ notification: Notification) { window?.contentView?.layoutSubtreeIfNeeded() }
    func windowDidChangeBackingProperties(_ notification: Notification) {
        (window?.contentView as? MacAppWindowContentView)?.updateViewport()
    }
    private func applyHostGeometry(_ host: RemoteAppWindow?) {
        guard let host, host != lastHostWindow, host.width > 0, host.height > 0, let window else { return }
        lastHostWindow = host
        fixedAspect = host.isResizable == false ? CGFloat(host.width) / CGFloat(host.height) : nil
        window.contentMinSize = Self.contentSize(for: host.isResizable == false ? .init(width: 100, height: 80)
            : .init(width: 240, height: 160))
        // A reply describes a previous request. Applying its geometry to a
        // resizable viewer would overwrite a newer drag and send that stale size
        // back to the host. Only fixed-size apps constrain the local aspect.
        guard fixedAspect != nil, !window.inLiveResize else { return }
        let actual = CGFloat(host.width) / CGFloat(host.height)
        let content = window.contentView?.bounds.size ?? .zero
        let video = Self.videoSize(in: content)
        let current = video.width / max(1, video.height)
        guard abs(actual - current) > 0.002, !window.styleMask.contains(.fullScreen) else { return }
        let size = Self.fitting(video: .init(width: host.width, height: host.height), inside: content, upscale: true)
        window.setContentSize(size)
    }
    static func videoSize(in content: CGSize) -> CGSize {
        .init(width: max(0, content.width - 2 * borderWidth), height: max(0, content.height - 2 * borderWidth))
    }
    static func contentSize(for video: CGSize) -> CGSize {
        .init(width: video.width + 2 * borderWidth, height: video.height + 2 * borderWidth)
    }
    static func fitting(video: CGSize, inside available: CGSize, upscale: Bool = false) -> CGSize {
        guard video.width.isFinite, video.height.isFinite, video.width > 0, video.height > 0 else { return contentSize(for: .init(width: 800, height: 600)) }
        let usable = videoSize(in: available)
        let factor = max(0.01, min(upscale ? .greatestFiniteMagnitude : 1,
            usable.width / video.width, max(1, usable.height) / video.height))
        return contentSize(for: .init(width: video.width * factor, height: video.height * factor))
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

/// AppKit owns the chrome and viewport layout so live window resizing does not
/// depend on a SwiftUI geometry update arriving before a network reply.
final class MacAppWindowContentView: NSView {
    private let stream: MacDesktopSession
    private let video: NSHostingView<MacAppVideoContent>
    override var isFlipped: Bool { true }
    init(stream: MacDesktopSession, menu: NSMenu) {
        self.stream = stream; video = NSHostingView(rootView: MacAppVideoContent(stream: stream))
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor; layer?.borderWidth = 1
        self.menu = menu
        addSubview(video)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let border = MacAppWindowController.borderWidth
        let size = MacAppWindowController.videoSize(in: bounds.size)
        video.frame = .init(origin: .init(x: border, y: border), size: size)
        updateViewport()
    }
    func updateViewport() {
        stream.viewport(MacAppWindowController.videoSize(in: bounds.size), scale: window?.backingScaleFactor ?? 1)
    }
}

private struct MacAppVideoContent: View {
    @ObservedObject var stream: MacDesktopSession
    var body: some View {
        ZStack {
            MacAppSurface(surface: stream.surface)
            if let error = stream.error {
                VStack(spacing: 12) {
                    Text(error).font(.callout).multilineTextAlignment(.center)
                    Button(L("Reconnect")) { stream.reconnect() }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            } else if !stream.ready {
                ProgressView(stream.status).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
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
