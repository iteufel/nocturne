import UIKit
import AVFoundation
import NocturneKit

/// Every native scene owns a display layer and input responder. Nothing uses
/// Moonlight's global decoder, mouse callbacks, or global stream connection.
@MainActor
final class AppWindowVideoView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    var onInput: ((AppWindowInput) -> Void)?
    private var parameterSets: [Data] = []
    private var format: CMVideoFormatDescription?
    private var videoSize = CGSize.zero
    private var previousScroll = CGPoint.zero
    private struct PointerPress {
        var point: CGPoint
        let origin: CGPoint
        let button: Int
        let clickCount: Int
        let modifiers: UIKeyModifierFlags
        var sentDown: Bool
    }
    private var pointerDown: PointerPress?
    private let hiddenKeyboard = UIView(frame: .zero)
    var keyboardVisible = false {
        didSet { if oldValue != keyboardVisible { becomeFirstResponder(); reloadInputViews() } }
    }
    override var inputView: UIView? { keyboardVisible ? nil : hiddenKeyboard }
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; isMultipleTouchEnabled = true
        videoLayer.videoGravity = .resizeAspect
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))); addGestureRecognizer(hover)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all; scroll.delegate = self; addGestureRecognizer(scroll)
        let rightClick = UILongPressGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        rightClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        rightClick.minimumPressDuration = 0.6; rightClick.allowableMovement = 8; addGestureRecognizer(rightClick)
        accessibilityLabel = "Mac app window"; accessibilityTraits = .allowsDirectInteraction
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func enqueue(_ frame: AppWindowVideoFrame) throws {
        guard frame.isValid else { throw NocturneError.invalidFrame }
        if parameterSets != frame.parameterSets {
            var description: CMFormatDescription?
            let status = frame.parameterSets[0].withUnsafeBytes { first in
                frame.parameterSets[1].withUnsafeBytes { second in
                    let pointers = [first.baseAddress!.assumingMemoryBound(to: UInt8.self), second.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                    let sizes = frame.parameterSets.map(\.count)
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                        parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                }
            }
            guard status == noErr, let description else { throw NocturneError.invalidFrame }
            videoLayer.flushAndRemoveImage(); format = description; parameterSets = frame.parameterSets
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            videoSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        }
        guard let format else { throw NocturneError.invalidFrame }
        if videoLayer.status == .failed { throw videoLayer.error ?? NocturneError.invalidFrame }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.data.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: frame.data.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw NocturneError.invalidFrame }
        let copy = frame.data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard copy == noErr else { throw NocturneError.invalidFrame }
        var sample: CMSampleBuffer?, length = frame.data.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &length, sampleBufferOut: &sample) == noErr,
              let sample else { throw NocturneError.invalidFrame }
        if let attachment = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary])?.first {
            attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        videoLayer.enqueue(sample)
    }
    func reset() {
        pointerDown = nil; format = nil; parameterSets = []; videoSize = .zero
        videoLayer.flushAndRemoveImage(); resignFirstResponder()
    }
    private func normalized(_ point: CGPoint) -> CGPoint? {
        guard videoSize.width > 0, videoSize.height > 0 else { return nil }
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }
    private func pointer(_ kind: AppWindowInput.Kind, _ point: CGPoint, button: Int = 0, clickCount: Int = 1, modifiers: UIKeyModifierFlags = []) {
        var input = AppWindowInput(kind); input.x = point.x; input.y = point.y; input.button = button
        input.clickCount = clickCount; input.modifiers = Self.macModifiers(modifiers); onInput?(input)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard event?.allTouches?.count == 1, let touch = touches.first, let point = normalized(touch.location(in: self)) else { releasePointer(); return }
        becomeFirstResponder()
        let button = event?.buttonMask.contains(.secondary) == true ? 1 : 0
        releasePointer()
        let modifiers = event?.modifierFlags ?? []
        let count = min(3, max(1, touch.tapCount)), immediate = touch.type == .indirectPointer
        pointerDown = PointerPress(point: point, origin: touch.location(in: self), button: button,
                                   clickCount: count, modifiers: modifiers, sentDown: immediate)
        // Direct touch may still become a long press or a two-finger scroll.
        // Mouse buttons already identify the intended click and remain immediate.
        if immediate { pointer(.down, point, button: button, clickCount: count, modifiers: modifiers) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard event?.allTouches?.count == 1, let touch = touches.first, let point = normalized(touch.location(in: self)), var down = pointerDown else { return }
        if !down.sentDown {
            let location = touch.location(in: self)
            guard hypot(location.x - down.origin.x, location.y - down.origin.y) > 8 else { return }
            pointer(.down, down.point, button: down.button, clickCount: down.clickCount, modifiers: down.modifiers)
            down.sentDown = true
        }
        down.point = point; pointerDown = down
        pointer(.move, point, button: down.button, clickCount: down.clickCount, modifiers: event?.modifierFlags ?? [])
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let point = touches.first.flatMap { normalized($0.location(in: self)) }
        releasePointer(completeTap: point != nil, point: point, modifiers: event?.modifierFlags)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { releasePointer(modifiers: event?.modifierFlags) }
    private func releasePointer(completeTap: Bool = false, point: CGPoint? = nil, modifiers: UIKeyModifierFlags? = nil) {
        guard let down = pointerDown else { return }; pointerDown = nil
        if !down.sentDown {
            guard completeTap else { return }
            pointer(.down, down.point, button: down.button, clickCount: down.clickCount, modifiers: down.modifiers)
        }
        pointer(.up, point ?? down.point, button: down.button, clickCount: down.clickCount, modifiers: modifiers ?? down.modifiers)
    }
    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        if let point = normalized(gesture.location(in: self)) {
            pointer(.move, point, button: pointerDown?.button ?? 0, modifiers: gesture.modifierFlags)
        }
    }
    @objc private func scroll(_ gesture: UIPanGestureRecognizer) {
        guard let point = normalized(gesture.location(in: self)) else { return }
        let translation = gesture.translation(in: self)
        if gesture.state == .began { releasePointer(); previousScroll = translation }
        var input = AppWindowInput(.scroll); input.x = point.x; input.y = point.y
        input.modifiers = Self.macModifiers(gesture.modifierFlags)
        input.deltaX = min(4096, max(-4096, translation.x - previousScroll.x))
        input.deltaY = min(4096, max(-4096, translation.y - previousScroll.y))
        previousScroll = translation; onInput?(input)
    }
    @objc private func rightClick(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let point = normalized(gesture.location(in: self)) else { return }
        releasePointer()
        pointer(.down, point, button: 1, modifiers: gesture.modifierFlags)
        pointer(.up, point, button: 1, modifiers: gesture.modifierFlags)
    }
    func insertText(_ text: String) { var input = AppWindowInput(.text); input.text = text; onInput?(input) }
    func deleteBackward() { key(51, down: true); key(51, down: false) }
    private func key(_ code: UInt16, down: Bool, modifiers: UIKeyModifierFlags = []) {
        var input = AppWindowInput(down ? .keyDown : .keyUp); input.keyCode = code
        input.modifiers = Self.macModifiers(modifiers)
        onInput?(input)
    }
    private static func macModifiers(_ modifiers: UIKeyModifierFlags) -> UInt64 {
        var flags: UInt64 = 0
        if modifiers.contains(.shift) { flags |= 1 << 17 }
        if modifiers.contains(.control) { flags |= 1 << 18 }
        if modifiers.contains(.alternate) { flags |= 1 << 19 }
        if modifiers.contains(.command) { flags |= 1 << 20 }
        if modifiers.contains(.alphaShift) { flags |= 1 << 16 }
        return flags
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let input = press.key, let code = Self.macKeyCodes[input.keyCode.rawValue] else { continue }
            key(code, down: true, modifiers: input.modifierFlags)
        }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let input = press.key, let code = Self.macKeyCodes[input.keyCode.rawValue] else { continue }
            key(code, down: false, modifiers: input.modifierFlags)
        }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { pressesEnded(presses, with: event) }
    // USB HID usages → macOS virtual key codes. Layout-sensitive text still uses
    // insertText; hardware shortcuts retain Command/Control/Option semantics.
    static let macKeyCodes: [Int: UInt16] = [4:0,5:11,6:8,7:2,8:14,9:3,10:5,11:4,12:34,13:38,14:40,15:37,
        16:46,17:45,18:31,19:35,20:12,21:15,22:1,23:17,24:32,25:9,26:13,27:7,28:16,29:6,
        30:18,31:19,32:20,33:21,34:23,35:22,36:26,37:28,38:25,39:29,40:36,41:53,42:51,43:48,44:49,
        45:27,46:24,47:33,48:30,49:42,50:10,51:41,52:39,53:50,54:43,55:47,56:44,57:57,
        58:122,59:120,60:99,61:118,62:96,63:97,64:98,65:100,66:101,67:109,68:103,69:111,
        73:114,74:115,75:116,76:117,77:119,78:121,79:124,80:123,81:125,82:126,
        224:59,225:56,226:58,227:55,228:62,229:60,230:61,231:54]
}
