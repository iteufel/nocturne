import AppKit
import WebKit
import NocturneKit

/// Read on the main actor, updated synchronously on the authenticated channel queue.
/// Revocation invalidates already queued/in-flight commands as well as future commands.
final class BrowserAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var closed = false
    private var revision = UUID()
    func update(enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if self.enabled != enabled { self.enabled = enabled; revision = UUID() }
    }
    func close() { lock.lock(); defer { lock.unlock() }; closed = true; revision = UUID() }
    var token: UUID? { lock.lock(); defer { lock.unlock() }; return enabled && !closed ? revision : nil }
}

@MainActor
final class RemoteBrowserHost {
    private static var active = 0
    private var session: BrowserPage?
    private var sessionID: String?
    private var authorizationRevision: UUID?
    private let leaseSeconds: TimeInterval
    private let now: @MainActor @Sendable () -> Date
    nonisolated init(leaseSeconds: TimeInterval = BrowserProtocol.leaseSeconds, now: @escaping @MainActor @Sendable () -> Date = { Date() }) {
        self.leaseSeconds = leaseSeconds; self.now = now
    }

    func reset() { session?.close(); session = nil; sessionID = nil; authorizationRevision = nil }
    func refreshAuthorization(_ authorization: BrowserAuthorization) {
        if authorization.token == nil || authorization.token != authorizationRevision { reset() }
    }
    func handle(_ packet: Packet, authorization: BrowserAuthorization) async throws -> Packet {
        guard let revision = authorization.token else { reset(); throw NocturneError.permissionDenied }
        if authorizationRevision != revision { reset(); authorizationRevision = revision }
        if session?.closed == true { reset(); authorizationRevision = revision }
        guard let command = packet.browserCommand else { throw NocturneError.invalidFrame }
        var reply = packet.reply()
        guard let id = packet.sessionID, UUID(uuidString: id) != nil else { throw NocturneError.invalidFrame }
        if command.action != .open {
            guard sessionID == id else { throw NocturneError.remote("Browser session ended.") }
        }
        if command.action == .close { reset(); return reply }
        if command.action == .open {
            guard session == nil else { throw NocturneError.remote("A browser is already open on this connection.") }
            guard Self.active < 4 else { throw NocturneError.remote("Close another browser session on this Mac first.") }
            let page = BrowserPage(leaseSeconds: leaseSeconds, now: now)
            Self.active += 1
            page.onClose = { Self.active -= 1 }
            session = page; sessionID = id
        }
        guard let session, !session.closed else { reset(); throw NocturneError.remote("Browser session ended. Close and reopen the browser.") }
        reply.browserFrame = try await session.perform(command)
        guard authorization.token == revision, self.session === session, !session.closed else {
            if self.session === session { reset() }
            throw NocturneError.disconnected
        }
        return reply
    }
}

/// A private offscreen WebKit view, never a system-browser window or a proxy listener.
/// No credentials, cookies, profiles or history are imported from Safari.
@MainActor
private final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var view: WKWebView?
    private var webView: WKWebView { view! }
    private let window: NSWindow
    private var page = UUID().uuidString
    private var notice: String?
    private var lastActivity: Date
    private let now: @MainActor @Sendable () -> Date
    private var lease: Timer?
    private var commandInFlight = false
    private(set) var closed = false
    var onClose: (() -> Void)?

    init(leaseSeconds: TimeInterval, now: @escaping @MainActor @Sendable () -> Date) {
        self.now = now; lastActivity = now()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        let browser = WKWebView(frame: NSRect(x: 0, y: 0, width: BrowserProtocol.width, height: BrowserProtocol.height), configuration: config)
        view = browser
        window = NSWindow(contentRect: browser.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsLinkPreview = false
        window.isReleasedWhenClosed = false
        window.contentView = webView
        // Keep it out of the desktop and window sharing menus. Snapshotting needs a window backing store.
        window.setFrameOrigin(NSPoint(x: -32_000, y: -32_000))
        window.sharingType = .none
        window.orderBack(nil)
        lease = Timer.scheduledTimer(withTimeInterval: min(5, leaseSeconds / 2), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.now().timeIntervalSince(self.lastActivity) > leaseSeconds else { return }
                self.close()
            }
        }
    }
    func close() {
        guard !closed else { return }; closed = true
        lease?.invalidate(); lease = nil
        // stopLoading alone does not tear down an already-running document/WebSocket.
        // Destroy the browsing context as well, including on lease expiration without another request.
        if let view {
            view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
            view.loadHTMLString("", baseURL: nil)
        }
        window.contentView = nil; view = nil; window.close()
        let callback = onClose; onClose = nil; callback?()
    }
    func perform(_ command: BrowserCommand) async throws -> BrowserFrame {
        guard !closed else { throw NocturneError.disconnected }
        guard !commandInFlight else { throw NocturneError.remote("Wait for the current browser frame.") }
        commandInFlight = true; defer { commandInFlight = false }
        lastActivity = now()
        switch command.action {
        case .open, .frame: break
        case .navigate:
            let url = try BrowserProtocol.destination(command.value ?? "")
            page = UUID().uuidString; notice = nil
            webView.load(URLRequest(url: url))
        case .back, .forward, .reload:
            try current(command); page = UUID().uuidString; notice = nil
            if command.action == .back { webView.goBack() }
            else if command.action == .forward { webView.goForward() }
            else { webView.reload() }
        case .click:
            try current(command)
            guard let x = command.x, let y = command.y, x.isFinite, y.isFinite,
                  (0...1).contains(x), (0...1).contains(y) else { throw NocturneError.invalidFrame }
            let point = NSPoint(x: x * webView.bounds.width, y: (webView.isFlipped ? y : 1 - y) * webView.bounds.height)
            // Native WebKit hit testing also supports cross-origin frames, unlike DOM injection.
            let location = webView.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(event)
                }
            }
        case .text:
            try current(command)
            guard let text = command.value, text.utf8.count <= 8_192, !text.contains("\0") else { throw NocturneError.invalidFrame }
            // Delivered only to this view's responder chain; never system-wide input or pasteboard.
            window.firstResponder?.insertText(text)
        case .enter, .tab, .backspace:
            try current(command)
            let key: (UInt16, String) = command.action == .enter ? (36, "\r") : command.action == .tab ? (48, "\t") : (51, "\u{7f}")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key.1, charactersIgnoringModifiers: key.1, isARepeat: false, keyCode: key.0) {
                    window.sendEvent(event)
                }
            }
        case .scroll:
            try current(command)
            guard let y = command.y, y.isFinite, abs(y) <= 768 else { throw NocturneError.invalidFrame }
            // Fixed script in an isolated world, arguments cannot introduce script source.
            _ = try await webView.callAsyncJavaScript("window.scrollBy(0, amount)", arguments: ["amount": y], in: nil, contentWorld: .defaultClient)
        case .close: close()
        }
        guard !closed else { throw NocturneError.disconnected }
        if webView.url == nil {
            return BrowserFrame(page: page, url: "", title: "Browser on Mac", canGoBack: false, canGoForward: false, loading: webView.isLoading, notice: notice)
        }
        // At most one snapshot per session; no unbounded image queue behind a slow client.
        let snapshotPage = page
        let image = try await webView.takeSnapshot(configuration: nil)
        guard !closed else { throw NocturneError.disconnected }
        // Navigation may commit while capture is pending. Never pair old pixels with a new input revision.
        var jpeg: Data?
        if snapshotPage == page, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            for quality in [0.65, 0.35, 0.15] {
                if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= BrowserProtocol.maximumImageBytes {
                    jpeg = data; break
                }
            }
        }
        return BrowserFrame(page: snapshotPage, url: String((webView.url?.absoluteString ?? "").prefix(8_192)), title: String((webView.title ?? "Browser on Mac").prefix(512)),
            canGoBack: webView.canGoBack, canGoForward: webView.canGoForward, loading: webView.isLoading, notice: notice.map { String($0.prefix(2_048)) }, jpeg: jpeg)
    }
    private func current(_ command: BrowserCommand) throws {
        guard command.page == page, !webView.isLoading else { throw NocturneError.remote("The page changed. Wait for its next frame before interacting.") }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        let localDocument = navigationAction.targetFrame?.isMainFrame == false && ["about", "data", "blob"].contains(scheme)
        guard (try? BrowserProtocol.destination(url.absoluteString)) != nil || localDocument else {
            notice = "Only HTTP and HTTPS navigation is allowed. External apps and downloads are blocked."
            decisionHandler(.cancel); return
        }
        if navigationAction.shouldPerformDownload { notice = "Downloads are disabled."; decisionHandler(.cancel); return }
        if navigationAction.targetFrame == nil {
            // User-triggered target=_blank stays in this private session. Never NSWorkspace.open.
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated { webView.load(navigationAction.request) }
            else { notice = "Pop-up blocked." }
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true { page = UUID().uuidString }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType ||
            (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true {
            notice = "Downloads are disabled."; decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { page = UUID().uuidString }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { page = UUID().uuidString }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { notice = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { notice = error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { close() }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Retain normal certificate validation; never use the Mac's saved HTTP/client-certificate credentials.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { notice = "File uploads are disabled."; completionHandler(nil) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { notice = String(message.prefix(512)); completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { notice = "Page confirmation blocked."; completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { notice = "Page prompt blocked."; completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
