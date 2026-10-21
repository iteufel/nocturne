import AppKit
import ScreenCaptureKit
import NocturneKit
import DisplayBridge

@MainActor
public final class NativeAppWindowHost: AppWindowHosting {
    private var catalog: [RemoteApplication] = []
    private var scanned: TimeInterval = -.infinity
    public init() {}
    public func applications() throws -> [RemoteApplication] {
        if ProcessInfo.processInfo.systemUptime - scanned < 15 { return catalog }
        let manager = FileManager.default
        var urls = Set<URL>()
        let roots = Set(manager.urls(for: .applicationDirectory, in: .allDomainsMask) +
            [URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
             manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")])
        for root in roots {
            guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries where url.pathExtension.lowercased() == "app" {
                urls.insert(url.resolvingSymlinksInPath())
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL { urls.insert(url.resolvingSymlinksInPath()) }
        }
        catalog = urls.compactMap { url in
            guard let bundle = Bundle(url: url), bundle.bundleIdentifier != Bundle.main.bundleIdentifier,
                  (bundle.infoDictionary?["LSBackgroundOnly"] as? Bool) != true,
                  (bundle.infoDictionary?["LSUIElement"] as? Bool) != true else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return RemoteApplication(id: url.path, name: name, bundleIdentifier: bundle.bundleIdentifier)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        scanned = ProcessInfo.processInfo.systemUptime
        return catalog
    }
    private func application(_ id: String) throws -> RemoteApplication {
        guard let app = try applications().first(where: { $0.id == id }) else {
            throw NocturneError.remote("This app is no longer installed. Refresh Apps on your device.")
        }
        return app
    }
    public func icon(applicationID: String) throws -> Data {
        let app = try application(applicationID)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw NocturneError.invalidFrame }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSWorkspace.shared.icon(forFile: app.id).draw(in: NSRect(x: 0, y: 0, width: 96, height: 96))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 131_072 else { throw NocturneError.invalidFrame }
        return data
    }
    public func windows(applicationID: String?) async throws -> [RemoteAppWindow] {
        guard !NDDisplayLayout.isScreenLocked() else {
            throw NocturneError.remote("This Mac is locked. Open its desktop to unlock it, then refresh Apps.")
        }
        let apps = try applications()
        if let applicationID { _ = try application(applicationID) }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ids = Set(apps.map(\.id))
        return content.windows.compactMap { window in
            guard window.windowLayer == 0, window.frame.width >= 100, window.frame.height >= 80,
                  let owner = window.owningApplication,
                  let app = NSRunningApplication(processIdentifier: owner.processID), let url = app.bundleURL else { return nil }
            let id = url.resolvingSymlinksInPath().path
            guard ids.contains(id), applicationID == nil || applicationID == id else { return nil }
            return RemoteAppWindow(id: window.windowID, applicationID: id,
                title: window.title.flatMap { $0.isEmpty ? nil : $0 } ?? owner.applicationName,
                width: Int(window.frame.width), height: Int(window.frame.height))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public func launch(applicationID: String) async throws -> [RemoteAppWindow] {
        guard !NDDisplayLayout.isScreenLocked() else {
            throw NocturneError.remote("This Mac is locked. Open its desktop to unlock it, then refresh Apps.")
        }
        let app = try application(applicationID)
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.id), configuration: configuration)
        for _ in 0..<40 {
            try Task.checkCancellation()
            let available = try await windows(applicationID: app.id)
            if !available.isEmpty { return available }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NocturneError.remote("\(app.name) has no open window. Open a window on your Mac, then refresh Apps.")
    }
    public func capture(applicationID: String, windowID: UInt32, viewport: AppWindowViewport,
                        send: @escaping AppWindowSend, ended: @escaping (Error) -> Void) async throws -> AppWindowCapture {
        guard !NDDisplayLayout.isScreenLocked() else {
            throw NocturneError.remote("This Mac is locked. Open its desktop to unlock it, then reconnect this window.")
        }
        _ = try application(applicationID)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }), window.windowLayer == 0,
              let owner = window.owningApplication,
              NSRunningApplication(processIdentifier: owner.processID)?.bundleURL?.resolvingSymlinksInPath().path == applicationID else {
            throw NocturneError.remote("This Mac window has closed. Choose another window in Apps.")
        }
        let capture = try NativeAppWindowCapture(window: window, applicationID: applicationID, send: send, ended: ended)
        do { try await capture.start(viewport); return capture }
        catch { capture.stop(); throw error }
    }
}
