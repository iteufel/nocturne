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
    private var appliedSize: CGSize?
    private var events = AppWindowEventState()
    init(pid: pid_t, windowID: CGWindowID) throws {
        guard AXIsProcessTrusted() else {
            throw NocturneError.remote("Allow Nocturne Server in Mac System Settings → Privacy & Security → Accessibility to control and resize app windows.")
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
        var value: CFTypeRef?, point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point), let size = try? Self.size(element) else { return nil }
        return CGRect(origin: point, size: size)
    }
    func resize(_ viewport: AppWindowViewport) throws -> CGSize {
        var size = CGSize(width: viewport.width, height: viewport.height)
        guard let value = AXValueCreate(.cgSize, &size) else { throw NocturneError.invalidFrame }
        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        guard result == .success else {
            throw NocturneError.remote("This Mac window cannot be resized. Choose a resizable window in Apps.")
        }
        let actual = try Self.size(element); appliedSize = actual
        return actual
    }
    private func focus() throws {
        guard frame != nil else { throw NocturneError.remote("This Mac window has closed.") }
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, element)
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, element) else {
            throw NocturneError.remote("This Mac window could not receive focus. Select it on your Mac, then reconnect.")
        }
    }
    func input(_ input: AppWindowInput) throws {
        guard input.isValid, let frame else { throw NocturneError.invalidFrame }
        if input.kind != .move, input.kind != .up { try focus() }
        for event in events.events(for: input, frame: frame, windowID: id) { event.postToPid(pid) }
    }
    func release() {
        for event in events.release(windowID: id) { event.postToPid(pid) }
        if let appliedSize, let current = try? Self.size(element), current == appliedSize {
            var original = originalSize
            if let value = AXValueCreate(.cgSize, &original) { _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
        }
    }
}

/// Owns the CGEvent state independently of Accessibility focus and window resizing.
/// Each lease must release precisely its own buttons and keys on disconnect.
struct AppWindowEventState {
    private var buttons = Set<Int>()
    private var keys = Set<UInt16>()
    private var lastPointer = CGPoint.zero
    mutating func events(for input: AppWindowInput, frame: CGRect, windowID: CGWindowID) -> [CGEvent] {
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
            if input.kind == .move { type = buttons.contains(0) ? .leftMouseDragged : buttons.contains(1) ? .rightMouseDragged : .mouseMoved }
            else if input.button == 0 { type = input.kind == .down ? .leftMouseDown : .leftMouseUp }
            else if input.button == 1 { type = input.kind == .down ? .rightMouseDown : .rightMouseUp }
            else { type = input.kind == .down ? .otherMouseDown : .otherMouseUp }
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
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
    mutating func release(windowID: CGWindowID) -> [CGEvent] {
        let source = CGEventSource(stateID: .privateState)
        var events: [CGEvent] = []
        for button in buttons.sorted() {
            let type: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            if let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPointer,
                                  mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .left) {
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
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
