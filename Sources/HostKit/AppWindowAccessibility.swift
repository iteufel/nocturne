import AppKit
import ApplicationServices
import Darwin
import NocturneKit

/// Resolve exact WindowServer IDs rather than matching mutable/nonunique titles.
/// Like virtual display control, the ID bridge is runtime checked and fails closed.
@MainActor
final class AppWindowAccessibility {
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowID: WindowIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDFunction.self)
    }()
    private let application: AXUIElement
    private let element: AXUIElement
    private let pid: pid_t
    private let id: CGWindowID
    private let originalSize: CGSize
    private let originalPosition: CGPoint
    private var appliedSize: CGSize?
    private var appliedPosition: CGPoint?
    private(set) var isResizable = true
    private var events = AppWindowEventState()
    init(pid: pid_t, windowID: CGWindowID) throws {
        guard AXIsProcessTrusted() else {
            throw NocturneError.remote("Allow Nocturne in Mac System Settings → Privacy & Security → Accessibility to control and resize app windows.")
        }
        guard let getWindowID = Self.windowID else { throw NocturneError.remote("App window control is unavailable on this version of macOS.") }
        application = AXUIElementCreateApplication(pid); self.pid = pid; id = windowID
        AXUIElementSetMessagingTimeout(application, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              let match = windows.first(where: { var id: CGWindowID = 0; return getWindowID($0, &id) == .success && id == windowID }) else {
            throw NocturneError.remote("This app does not expose a controllable window. Choose another window in Apps.")
        }
        element = match
        originalSize = try Self.size(match)
        originalPosition = try Self.position(match)
        _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    private static func size(_ element: AXUIElement) throws -> CGSize {
        var value: CFTypeRef?, result = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &result) else { throw NocturneError.remote("This Mac window has closed.") }
        return result
    }
    var frame: CGRect? {
        guard let point = try? Self.position(element), let size = try? Self.size(element) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private static func position(_ element: AXUIElement) throws -> CGPoint {
        var value: CFTypeRef?, point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) else {
            throw NocturneError.remote("This Mac window has closed.")
        }
        return point
    }
    func resize(_ viewport: AppWindowViewport) throws -> CGSize {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        if (status == .success && !settable.boolValue) || status == .attributeUnsupported || status == .notImplemented {
            isResizable = false; return try Self.size(element)
        }
        let sizing = try Self.resizeIfPossible(viewport, currentSize: { try Self.size(self.element) }) { try self.applySize($0) }
        let actual = sizing.size; isResizable = sizing.isResizable
        if isResizable { appliedSize = actual; appliedPosition = frame?.origin }
        return actual
    }
    struct ResizeUnavailable: Error {}
    static func resizeIfPossible(_ viewport: AppWindowViewport, currentSize: @escaping () throws -> CGSize,
                                 apply: (CGSize) throws -> CGSize) throws -> (size: CGSize, isResizable: Bool) {
        let before = try currentSize()
        var accepted = true
        let actual = try resizeToMatch(viewport, currentSize: { accepted = false; return try currentSize() }, apply: apply)
        let matchesRequest = abs(actual.width - CGFloat(viewport.width)) < 1 && abs(actual.height - CGFloat(viewport.height)) < 1
        // Some apps report a writable AX size but silently ignore the setter.
        // Treat an unchanged, mismatched window as fixed rather than stretching it.
        return (actual, accepted && (actual != before || matchesRequest))
    }
    static func resizeToMatch(_ viewport: AppWindowViewport, currentSize: (() throws -> CGSize)? = nil,
                              apply: (CGSize) throws -> CGSize) throws -> CGSize {
        do { return try resizeSupportedWindow(viewport, apply: apply) }
        catch is ResizeUnavailable {
            guard let currentSize else { throw ResizeUnavailable() }
            let actual = try currentSize()
            guard actual.width.isFinite, actual.height.isFinite, actual.width > 0, actual.height > 0 else { throw NocturneError.invalidFrame }
            return actual
        }
    }
    private static func resizeSupportedWindow(_ viewport: AppWindowViewport, apply: (CGSize) throws -> CGSize) throws -> CGSize {
        let requested = CGSize(width: viewport.width, height: viewport.height)
        let actual = try apply(requested)
        guard actual.width > 0, actual.height > 0 else { throw NocturneError.invalidFrame }
        let ratio = requested.width / requested.height
        guard abs(actual.width / actual.height - ratio) > 0.001 else { return actual }
        // Apps can impose a minimum width or height. Grow the other dimension
        // proportionally instead of encoding that clamped, mismatched shape.
        let factor = min(max(actual.width / requested.width, actual.height / requested.height),
                         4096 / max(requested.width, requested.height))
        let matching = CGSize(width: requested.width * factor, height: requested.height * factor)
        guard abs(matching.width - actual.width) > 1 || abs(matching.height - actual.height) > 1 else { return actual }
        return try apply(matching)
    }
    private func applySize(_ requested: CGSize) throws -> CGSize {
        if let current = frame, let primary = NSScreen.screens.first {
            // AX uses a top-left origin; NSScreen uses a bottom-left origin.
            let visibleFrames = NSScreen.screens.map { screen in
                let visible = screen.visibleFrame
                return CGRect(x: visible.minX, y: primary.frame.maxY - visible.maxY,
                              width: visible.width, height: visible.height)
            }
            let center = CGPoint(x: current.midX, y: current.midY)
            if let visible = visibleFrames.first(where: { $0.contains(center) }) ?? visibleFrames.max(by: {
                $0.intersection(current).width * $0.intersection(current).height < $1.intersection(current).width * $1.intersection(current).height
            }) {
                var position = Self.positionToFit(current.origin, size: requested, visibleFrame: visible)
                if position != current.origin, let value = AXValueCreate(.cgPoint, &position) {
                    guard AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success else {
                        guard AXIsProcessTrusted() else { throw NocturneError.permissionDenied }
                        throw ResizeUnavailable()
                    }
                    appliedPosition = position
                    // Position changes also complete asynchronously. Resizing
                    // against the old origin lets macOS clamp the tall window
                    // to the space below that origin, undoing the move.
                    if pid != getpid() { Thread.sleep(forTimeInterval: 0.25) }
                    for _ in 0..<15 {
                        if pid != getpid() { Thread.sleep(forTimeInterval: 0.02) }
                        let actual = try Self.position(element)
                        if abs(actual.x - position.x) < 1, abs(actual.y - position.y) < 1 { break }
                    }
                }
            }
        }
        var size = requested
        guard let value = AXValueCreate(.cgSize, &size) else { throw NocturneError.invalidFrame }
        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        guard result == .success else {
            guard AXIsProcessTrusted() else { throw NocturneError.permissionDenied }
            throw ResizeUnavailable()
        }
        // AX setters return before the target app has laid out its window.
        // Reading immediately can report the previous size and reverse the
        // aspect compensation. Read back stable geometry before configuring video.
        var actual = try Self.size(element), stableReads = 0
        for _ in 0..<15 {
            if pid != getpid() { Thread.sleep(forTimeInterval: 0.02) }
            let next = try Self.size(element)
            stableReads = next == actual ? stableReads + 1 : 0
            actual = next
            if stableReads >= 3 { break }
        }
        return actual
    }
    static func positionToFit(_ origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width)),
                y: min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height)))
    }
    private func focus() async throws {
        guard frame != nil else { throw NocturneError.remote("This Mac window has closed.") }
        guard let target = NSRunningApplication(processIdentifier: pid), let url = target.bundleURL else {
            throw NocturneError.remote("This Mac app has closed.")
        }
        if !target.isActive {
            // Background activate(options:) is advisory on modern macOS. Opening
            // the existing app supplies the cooperative activation context.
            if pid == getpid() {
                NSApp.activate()
            } else {
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            for _ in 0..<50 where !target.isActive { try await Task.sleep(nanoseconds: 20_000_000) }
            guard target.isActive else {
                throw NocturneError.remote("The shared Mac app could not become active. Try reconnecting its window.")
            }
            // Some apps handle reopen by restoring their usual window size.
            // Keep the active stream's fitted geometry after that activation.
            if let appliedSize, frame?.size != appliedSize {
                do {
                    self.appliedSize = try applySize(appliedSize); appliedPosition = frame?.origin
                } catch is ResizeUnavailable {
                    isResizable = false
                    _ = try Self.size(element)
                }
            }
        }
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, element)
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, element) else {
            throw NocturneError.remote("This Mac window could not receive focus. Select it on your Mac, then reconnect.")
        }
    }
    func input(_ input: AppWindowInput, isActive: () -> Bool = { true }) async throws {
        guard input.isValid else { throw NocturneError.invalidFrame }
        if input.kind != .move, input.kind != .up { try await focus() }
        guard isActive(), let frame else { throw NocturneError.disconnected }
        // Let WindowServer annotate native global-coordinate events. Direct
        // per-process posting bypasses hit testing and drops clicks in apps.
        for event in events.events(for: input, frame: frame, windowID: id) { event.post(tap: .cghidEventTap) }
    }
    func release() {
        for event in events.release(windowID: id) { event.post(tap: .cghidEventTap) }
        let unchangedSize = appliedSize == nil || (try? Self.size(element)) == appliedSize
        if let appliedSize, (try? Self.size(element)) == appliedSize {
            var original = originalSize
            if let value = AXValueCreate(.cgSize, &original) { _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
        }
        if unchangedSize, let appliedPosition, (try? Self.position(element)) == appliedPosition {
            var position = originalPosition
            if let value = AXValueCreate(.cgPoint, &position) { _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
        }
    }
}

/// Owns the CGEvent state independently of Accessibility focus and window resizing.
/// Each lease must release precisely its own buttons and keys on disconnect.
struct AppWindowEventState {
    private var buttons = Set<Int>()
    private var keys = Set<UInt16>()
    private var lastPointer = CGPoint.zero
    mutating func events(for input: AppWindowInput, frame: CGRect, windowID: CGWindowID?) -> [CGEvent] {
        let point = CGPoint(x: frame.minX + min(input.x * frame.width, max(0, frame.width - 1)),
                            y: frame.minY + min(input.y * frame.height, max(0, frame.height - 1)))
        let source = CGEventSource(stateID: .privateState)
        let event: CGEvent?
        switch input.kind {
        case .move, .down, .up:
            lastPointer = point
            if input.kind == .down { buttons.insert(input.button) }
            if input.kind == .up { buttons.remove(input.button) }
            let button = CGMouseButton(rawValue: UInt32(input.button)) ?? .left
            let type: CGEventType
            if input.kind == .move { type = buttons.contains(0) ? .leftMouseDragged : buttons.contains(1) ? .rightMouseDragged : buttons.contains(2) ? .otherMouseDragged : .mouseMoved }
            else if input.button == 0 { type = input.kind == .down ? .leftMouseDown : .leftMouseUp }
            else if input.button == 1 { type = input.kind == .down ? .rightMouseDown : .rightMouseUp }
            else { type = input.kind == .down ? .otherMouseDown : .otherMouseUp }
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            if let windowID {
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            }
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(input.clickCount ?? 1))
        case .scroll:
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(input.deltaY), wheel2: Int32(input.deltaX), wheel3: 0)
            event?.location = point
        case .keyDown, .keyUp:
            if input.kind == .keyDown { keys.insert(input.keyCode) } else { keys.remove(input.keyCode) }
            event = CGEvent(keyboardEventSource: source, virtualKey: input.keyCode, keyDown: input.kind == .keyDown)
        case .text:
            let text = Array(input.text.utf16)
            return [true, false].compactMap { down in
                guard let key = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return nil }
                text.withUnsafeBufferPointer { key.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                key.flags = CGEventFlags(rawValue: input.modifiers & 0x00ff0000)
                return key
            }
        }
        event?.flags = CGEventFlags(rawValue: input.modifiers & 0x00ff0000)
        return event.map { [$0] } ?? []
    }
    mutating func release(windowID: CGWindowID?) -> [CGEvent] {
        let source = CGEventSource(stateID: .privateState)
        var events: [CGEvent] = []
        for button in buttons.sorted() {
            let type: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            if let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPointer,
                                  mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .left) {
                if let windowID {
                    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
                    event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
                }
                event.flags = []; events.append(event)
            }
        }
        for code in keys.sorted() {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                // Modifier key-up events become flagsChanged. Reusing their down
                // flags would tell AppKit that the modifier is still pressed.
                event.flags = []; events.append(event)
            }
        }
        buttons.removeAll(); keys.removeAll()
        return events
    }
}
