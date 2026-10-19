import XCTest
import UIKit
import AVFoundation
import VideoToolbox
import NocturneKit
@testable import Nocturne

@MainActor
final class AppWindowClientTests: XCTestCase {
    func testWindowFillCoversPhoneAndMapsTouchesThroughTheCrop() async throws {
        let view = AppWindowVideoView(frame: CGRect(x: 0, y: 0, width: 430, height: 819))
        try view.enqueue(await encodedFrame(width: 740, height: 786))
        defer { view.reset() }
        view.fillEntireScreen = true
        XCTAssertEqual((view.layer as? AVSampleBufferDisplayLayer)?.videoGravity, .resizeAspectFill)
        XCTAssertTrue(view.videoRect.insetBy(dx: -0.001, dy: -0.001).contains(view.bounds))
        var sent: [AppWindowInput] = []; view.onInput = { sent.append($0) }
        let touch = AppWindowTestTouch(), event = AppWindowTestEvent()
        touch.point = CGPoint(x: 20, y: 400); event.inputTouches = [touch]
        view.touchesBegan([touch], with: event); view.touchesEnded([touch], with: event)
        XCTAssertEqual(sent.map(\.kind), [.down, .up])
        let expectedX = (touch.point.x - view.videoRect.minX) / view.videoRect.width
        XCTAssertEqual(try XCTUnwrap(sent.first).x, expectedX, accuracy: 0.001)
        XCTAssertGreaterThan(expectedX, 0.1, "The left screen edge corresponds to the cropped window, not its left edge")
        view.fillEntireScreen = false
        XCTAssertEqual((view.layer as? AVSampleBufferDisplayLayer)?.videoGravity, .resizeAspect)
        XCTAssertTrue(view.bounds.contains(view.videoRect))
    }
    func testLongPressAndTwoFingerScrollDoNotSendAnInitialLeftClick() async throws {
        let view = AppWindowVideoView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        try view.enqueue(await encodedFrame(width: 640, height: 480))
        defer { view.reset() }
        var sent: [AppWindowInput] = []; view.onInput = { sent.append($0) }
        let touch = AppWindowTestTouch(), event = AppWindowTestEvent()
        event.inputTouches = [touch]
        view.touchesBegan([touch], with: event)
        XCTAssertTrue(sent.isEmpty, "A touch must not click before long-press recognition")
        view.touchesCancelled([touch], with: event)
        let hold = AppWindowTestLongPress()
        _ = view.perform(NSSelectorFromString("rightClick:"), with: hold)
        XCTAssertEqual(sent.map(\.kind), [.down, .up])
        XCTAssertEqual(sent.map(\.button), [1, 1])
        XCTAssertTrue(sent.allSatisfy { $0.modifiers == 1 << 19 })

        sent.removeAll()
        view.touchesBegan([touch], with: event)
        let second = AppWindowTestTouch(); event.inputTouches = [touch, second]
        view.touchesBegan([second], with: event)
        view.touchesCancelled([touch, second], with: event)
        let scroll = AppWindowTestPan()
        _ = view.perform(NSSelectorFromString("scroll:"), with: scroll)
        scroll.inputState = .changed; scroll.inputTranslation = CGPoint(x: 0, y: 30)
        _ = view.perform(NSSelectorFromString("scroll:"), with: scroll)
        XCTAssertEqual(sent.map(\.kind), [.scroll, .scroll])
        XCTAssertEqual(sent.last?.deltaY, 30)
        XCTAssertTrue(sent.allSatisfy { $0.modifiers == 1 << 17 })
    }
    func testTouchTapCountsAndModifiersReachTheTransport() async throws {
        let view = AppWindowVideoView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        try view.enqueue(await encodedFrame(width: 640, height: 480))
        defer { view.reset() }
        var sent: [AppWindowInput] = []; view.onInput = { sent.append($0) }
        let touch = AppWindowTestTouch(), event = AppWindowTestEvent()
        event.inputTouches = [touch]; event.inputModifiers = [.command, .shift]
        for count in 1...3 {
            touch.inputTapCount = count
            view.touchesBegan([touch], with: event)
            view.touchesEnded([touch], with: event)
        }
        XCTAssertEqual(sent.map(\.kind), [.down, .up, .down, .up, .down, .up])
        XCTAssertEqual(sent.map(\.clickCount), [1, 1, 2, 2, 3, 3])
        XCTAssertTrue(sent.allSatisfy { $0.modifiers == (1 << 20 | 1 << 17) && $0.isValid })
    }
    func testTouchDragStartsAtItsOriginalPositionAndCancellationReleasesIt() async throws {
        let view = AppWindowVideoView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        try view.enqueue(await encodedFrame(width: 640, height: 480))
        defer { view.reset() }
        var sent: [AppWindowInput] = []; view.onInput = { sent.append($0) }
        let touch = AppWindowTestTouch(), event = AppWindowTestEvent()
        event.inputTouches = [touch]; event.inputModifiers = [.alternate]
        view.touchesBegan([touch], with: event)
        touch.point.x += 4; view.touchesMoved([touch], with: event)
        XCTAssertTrue(sent.isEmpty)
        touch.point.x += 16; view.touchesMoved([touch], with: event)
        event.inputModifiers = []
        view.touchesCancelled([touch], with: event)
        XCTAssertEqual(sent.map(\.kind), [.down, .move, .up])
        XCTAssertEqual(sent[0].x, 100.0 / 640)
        XCTAssertEqual(sent[1].x, 120.0 / 640)
        XCTAssertEqual(sent.map(\.modifiers), [1 << 19, 1 << 19, 0])
        view.touchesEnded([touch], with: event)
        XCTAssertEqual(sent.count, 3)
    }
    func testHardwareMouseClicksRemainImmediateAndForwardModifiers() async throws {
        let view = AppWindowVideoView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        try view.enqueue(await encodedFrame(width: 640, height: 480))
        defer { view.reset() }
        var sent: [AppWindowInput] = []; view.onInput = { sent.append($0) }
        let touch = AppWindowTestTouch(), event = AppWindowTestEvent()
        touch.inputType = .indirectPointer; touch.inputTapCount = 2
        event.inputTouches = [touch]; event.inputModifiers = [.command]; event.inputButtons = [.secondary]
        view.touchesBegan([touch], with: event)
        XCTAssertEqual(sent.map(\.kind), [.down])
        view.touchesEnded([touch], with: event)
        XCTAssertEqual(sent.map(\.kind), [.down, .up])
        XCTAssertEqual(sent.map(\.button), [1, 1])
        XCTAssertEqual(sent.map(\.clickCount), [2, 2])
        XCTAssertTrue(sent.allSatisfy { $0.modifiers == 1 << 20 })
    }
    func testSceneRestorationRoutesContainNoPairingSecrets() throws {
        let route = AppWindowRoute(serverID: "host-fingerprint", applicationID: "/Applications/Notes.app", windowID: 42, title: "Notes")
        let activity = AppWindowScenes.activity(route)
        XCTAssertEqual(activity.targetContentIdentifier, route.contentIdentifier)
        XCTAssertEqual(AppWindowScenes.route(activity), route)
        let payload = try XCTUnwrap(activity.userInfo?["route"] as? Data)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["serverID", "applicationID", "windowID", "title"])
        XCTAssertNotEqual(route.id, AppWindowRoute(serverID: "another-host", applicationID: route.applicationID, windowID: 42, title: "Notes").id)
        XCTAssertNil(AppWindowScenes.route(NSUserActivity(activityType: "unrelated")))
    }
    func testAppWindowsHaveIndependentNativeScenesAndCloseSeparately() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad, UIApplication.shared.supportsMultipleScenes else { throw XCTSkip("Native app windows require iPad") }
        let prefix = UUID().uuidString
        let first = AppWindowRoute(serverID: prefix, applicationID: "scene-test", windowID: 1, title: "First app window")
        let second = AppWindowRoute(serverID: prefix, applicationID: "scene-test", windowID: 2, title: "Second app window")
        var openingError: Error?
        func scenes() -> [UIWindowScene] {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter {
                ($0.delegate as? DarkSceneDelegate)?.appStream?.route.serverID == prefix
            }
        }
        defer {
            for scene in scenes() { AppWindowScenes.close(scene.session) }
        }
        AppWindowScenes.open(first) { openingError = $0 }
        for _ in 0..<100 where scenes().count < 1 && openingError == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        if let openingError { throw openingError }
        XCTAssertEqual(scenes().count, 1)
        AppWindowScenes.open(second) { openingError = $0 }
        for _ in 0..<100 where scenes().count < 2 && openingError == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        if let openingError { throw openingError }
        let firstScene = try XCTUnwrap(scenes().first { ($0.delegate as? DarkSceneDelegate)?.appStream?.route == first })
        let secondScene = try XCTUnwrap(scenes().first { ($0.delegate as? DarkSceneDelegate)?.appStream?.route == second })
        let a = try XCTUnwrap((firstScene.delegate as? DarkSceneDelegate)?.appStream)
        let b = try XCTUnwrap((secondScene.delegate as? DarkSceneDelegate)?.appStream)
        XCTAssertFalse(a.connection === b.connection); XCTAssertFalse(a.surface === b.surface)
        XCTAssertNotEqual(firstScene.session.persistentIdentifier, secondScene.session.persistentIdentifier)
        AppWindowScenes.open(first) { openingError = $0 }
        for _ in 0..<100 where firstScene.activationState != .foregroundActive && openingError == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        if let openingError { throw openingError }
        XCTAssertEqual(scenes().count, 2, "Reopening a target should activate its existing window")
        var closeError: Error?
        AppWindowScenes.close(firstScene.session) { closeError = $0 }
        for _ in 0..<100 where UIApplication.shared.openSessions.contains(firstScene.session) && closeError == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        if let closeError { throw closeError }
        XCTAssertFalse(UIApplication.shared.openSessions.contains(firstScene.session), "Closed session remained open (scene state \(firstScene.activationState.rawValue))")
        XCTAssertTrue(UIApplication.shared.openSessions.contains(secondScene.session))
    }
    func testActualH264FramesDecodeAndResizeOnIndependentVideoLayers() async throws {
        let first = AppWindowVideoView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let second = AppWindowVideoView(frame: first.frame)
        let root = UIViewController(), window = UIWindow(frame: first.frame)
        root.view.addSubview(first); root.view.addSubview(second)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { first.reset(); second.reset(); window.isHidden = true; window.rootViewController = nil }
        try first.enqueue(await encodedFrame(width: 640, height: 480))
        try second.enqueue(await encodedFrame(width: 480, height: 640))
        let layerA = try XCTUnwrap(first.layer as? AVSampleBufferDisplayLayer)
        let layerB = try XCTUnwrap(second.layer as? AVSampleBufferDisplayLayer)
        for _ in 0..<100 where layerA.status == .unknown || layerB.status == .unknown { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(layerA.status, .rendering, layerA.error?.localizedDescription ?? "First H.264 layer")
        XCTAssertEqual(layerB.status, .rendering, layerB.error?.localizedDescription ?? "Second H.264 layer")
        try first.enqueue(await encodedFrame(width: 800, height: 600))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(layerA.status, .rendering); XCTAssertEqual(layerB.status, .rendering)
        first.reset(); XCTAssertEqual(layerB.status, .rendering)
    }
    private func encodedFrame(width: Int, height: Int) async throws -> AppWindowVideoFrame {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw NocturneError.invalidFrame }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw NocturneError.invalidFrame }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let pointer = CVPixelBufferGetBaseAddress(buffer) { memset(pointer, 180, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let sample: CMSampleBuffer = try await withCheckedThrowingContinuation { continuation in
            let result = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: .zero, duration: .invalid,
                frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, infoFlagsOut: nil) { status, _, sample in
                    if status == noErr, let sample { continuation.resume(returning: sample) }
                    else { continuation.resume(throwing: NocturneError.invalidFrame) }
                }
            if result != noErr { continuation.resume(throwing: NocturneError.invalidFrame) }
            else { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
        }
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample)), block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let length = data.count
        _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        var sets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
            XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil), noErr)
            sets.append(Data(bytes: try XCTUnwrap(pointer), count: size))
        }
        return AppWindowVideoFrame(data: data, parameterSets: sets, timestamp: 0)
    }
}

@MainActor
private final class AppWindowTestTouch: UITouch {
    var point = CGPoint(x: 100, y: 100)
    var inputType: UITouch.TouchType = .direct
    var inputTapCount = 1
    override var type: UITouch.TouchType { inputType }
    override var tapCount: Int { inputTapCount }
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class AppWindowTestEvent: UIEvent {
    var inputTouches = Set<UITouch>()
    var inputModifiers: UIKeyModifierFlags = []
    var inputButtons: UIEvent.ButtonMask = []
    override var allTouches: Set<UITouch>? { inputTouches }
    override var modifierFlags: UIKeyModifierFlags { inputModifiers }
    override var buttonMask: UIEvent.ButtonMask { inputButtons }
}

@MainActor
private final class AppWindowTestLongPress: UILongPressGestureRecognizer {
    override var state: UIGestureRecognizer.State { get { .began } set {} }
    override var modifierFlags: UIKeyModifierFlags { [.alternate] }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 100, y: 100) }
}

@MainActor
private final class AppWindowTestPan: UIPanGestureRecognizer {
    var inputState: UIGestureRecognizer.State = .began
    var inputTranslation = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { inputState } set { inputState = newValue } }
    override var modifierFlags: UIKeyModifierFlags { [.shift] }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 100, y: 100) }
    override func translation(in view: UIView?) -> CGPoint { inputTranslation }
}
