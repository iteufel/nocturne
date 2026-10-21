import AppKit
import AVFoundation
import NocturneKit

@MainActor
public final class MacVideoView: NSView {
    private let videoLayer = AVSampleBufferDisplayLayer()
    public var onInput: ((AppWindowInput) -> Void)?
    public var inputEnabled = false
    private var parameterSets: [Data] = []
    private var format: CMVideoFormatDescription?
    private var videoSize = CGSize.zero
    private var keys = Set<UInt16>()
    private var buttons = Set<Int>()
    private var lastPointer = CGPoint.zero
    private var observers: [NSObjectProtocol] = []
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { inputEnabled }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect; layer?.addSublayer(videoLayer)
        setAccessibilityLabel("Remote Mac desktop")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds; CATransaction.commit()
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        guard let window else { releaseInput(); return }
        window.acceptsMouseMovedEvents = true
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseInput() }
            })
        }
    }
    public override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
    public func releaseInput() {
        for code in keys.sorted() { var input = AppWindowInput(.keyUp); input.keyCode = code; onInput?(input) }
        for button in buttons.sorted() {
            var input = AppWindowInput(.up); input.button = button; input.x = lastPointer.x; input.y = lastPointer.y; onInput?(input)
        }
        keys.removeAll(); buttons.removeAll()
    }
    public func reset() {
        inputEnabled = false; keys.removeAll(); buttons.removeAll()
        format = nil; parameterSets = []; videoSize = .zero; videoLayer.flushAndRemoveImage()
    }
    public func enqueue(_ frame: AppWindowVideoFrame) throws {
        guard frame.isValid else { throw NocturneError.invalidFrame }
        if parameterSets != frame.parameterSets {
            var description: CMFormatDescription?
            let status = frame.parameterSets[0].withUnsafeBytes { first in
                frame.parameterSets[1].withUnsafeBytes { second in
                    let pointers = [first.baseAddress!.assumingMemoryBound(to: UInt8.self), second.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                        parameterSetPointers: pointers, parameterSetSizes: frame.parameterSets.map(\.count), nalUnitHeaderLength: 4,
                        formatDescriptionOut: &description)
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
        let status = frame.data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard status == noErr else { throw NocturneError.invalidFrame }
        var sample: CMSampleBuffer?, length = frame.data.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &length,
            sampleBufferOut: &sample) == noErr, let sample else { throw NocturneError.invalidFrame }
        if let attachment = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary])?.first {
            attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        videoLayer.enqueue(sample)
    }
    static func normalized(_ point: CGPoint, bounds: CGRect, videoSize: CGSize, clamp: Bool) -> CGPoint? {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func pointer(_ event: NSEvent, kind: AppWindowInput.Kind) {
        guard inputEnabled, (0...2).contains(event.buttonNumber),
              let point = Self.normalized(convert(event.locationInWindow, from: nil), bounds: bounds, videoSize: videoSize, clamp: !buttons.isEmpty) else { return }
        if kind == .down { window?.makeFirstResponder(self); buttons.insert(event.buttonNumber) }
        if kind == .up { buttons.remove(event.buttonNumber) }
        lastPointer = point
        var input = AppWindowInput(kind); input.x = point.x; input.y = point.y; input.button = event.buttonNumber
        input.clickCount = min(3, max(1, event.clickCount)); input.modifiers = UInt64(event.modifierFlags.rawValue)
        onInput?(input)
    }
    public override func mouseDown(with event: NSEvent) { pointer(event, kind: .down) }
    public override func mouseUp(with event: NSEvent) { pointer(event, kind: .up) }
    public override func rightMouseDown(with event: NSEvent) { pointer(event, kind: .down) }
    public override func rightMouseUp(with event: NSEvent) { pointer(event, kind: .up) }
    public override func otherMouseDown(with event: NSEvent) { pointer(event, kind: .down) }
    public override func otherMouseUp(with event: NSEvent) { pointer(event, kind: .up) }
    public override func mouseMoved(with event: NSEvent) { pointer(event, kind: .move) }
    public override func mouseDragged(with event: NSEvent) { pointer(event, kind: .move) }
    public override func rightMouseDragged(with event: NSEvent) { pointer(event, kind: .move) }
    public override func otherMouseDragged(with event: NSEvent) { pointer(event, kind: .move) }
    public override func scrollWheel(with event: NSEvent) {
        guard inputEnabled, let point = Self.normalized(convert(event.locationInWindow, from: nil), bounds: bounds, videoSize: videoSize, clamp: false) else { return }
        var input = AppWindowInput(.scroll); input.x = point.x; input.y = point.y
        let multiplier = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        input.deltaX = max(-4096, min(4096, event.scrollingDeltaX * multiplier))
        input.deltaY = max(-4096, min(4096, event.scrollingDeltaY * multiplier))
        input.modifiers = UInt64(event.modifierFlags.rawValue); onInput?(input)
    }
    private func key(_ event: NSEvent, down: Bool) {
        guard inputEnabled, event.keyCode <= 127 else { return }
        if down { keys.insert(event.keyCode) } else { keys.remove(event.keyCode) }
        var input = AppWindowInput(down ? .keyDown : .keyUp); input.keyCode = event.keyCode
        input.modifiers = UInt64(event.modifierFlags.rawValue); onInput?(input)
    }
    private func releaseShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains([.control, .option]) else { return false }
        releaseInput(); window?.makeFirstResponder(nil); return true
    }
    public override func keyDown(with event: NSEvent) { if !releaseShortcut(event) { key(event, down: true) } }
    public override func keyUp(with event: NSEvent) { if keys.contains(event.keyCode) { key(event, down: false) } }
    public override func flagsChanged(with event: NSEvent) {
        key(event, down: !keys.contains(event.keyCode))
    }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard inputEnabled, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
}
