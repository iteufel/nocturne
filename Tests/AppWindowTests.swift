import XCTest
import AppKit
import ScreenCaptureKit
import VideoToolbox
import Network
import NocturneKit
@testable import NocturneHostKit

@MainActor
private final class RecordingAppCapture: AppWindowCapture {
    var window: RemoteAppWindow
    var display = StreamDisplaySize(width: 1600, height: 1200, frameRate: 60)
    var resizes: [AppWindowViewport] = []
    var inputs: [AppWindowInput] = []
    var stops = 0
    let send: AppWindowSend
    init(windowID: UInt32, send: @escaping AppWindowSend) {
        window = .init(id: windowID, applicationID: "app", title: "Window \(windowID)", width: 800, height: 600); self.send = send
    }
    func resize(_ viewport: AppWindowViewport) {
        resizes.append(viewport)
        window = .init(id: window.id, applicationID: "app", title: window.title, width: viewport.width, height: viewport.height)
        display = viewport.pixels(width: Double(viewport.width), height: Double(viewport.height))!
    }
    func input(_ input: AppWindowInput) { inputs.append(input) }
    func stop() { stops += 1 }
}

@MainActor
private final class RecordingAppHost: AppWindowHosting {
    var captures: [RecordingAppCapture] = []
    var pauseCapture: CheckedContinuation<Void, Never>?
    var delayCapture = false
    var failCapture = false
    func applications() -> [RemoteApplication] { (0..<130).map { .init(id: "app\($0)", name: "App \($0)") } }
    func icon(applicationID: String) -> Data { Data([1, 2, 3]) }
    func windows(applicationID: String?) -> [RemoteAppWindow] { (1...8).map { .init(id: UInt32($0), applicationID: "app", title: "Window \($0)", width: 800, height: 600) } }
    func launch(applicationID: String) -> [RemoteAppWindow] { windows(applicationID: applicationID) }
    func capture(applicationID: String, windowID: UInt32, viewport: AppWindowViewport, send: @escaping AppWindowSend, ended: @escaping (Error) -> Void) async throws -> AppWindowCapture {
        if failCapture { throw NocturneError.permissionDenied }
        let capture = RecordingAppCapture(windowID: windowID, send: send); captures.append(capture)
        if delayCapture { await withCheckedContinuation { pauseCapture = $0 } }
        return capture
    }
}

@MainActor
final class AppWindowTests: XCTestCase {
    private var nativeClicks = 0
    @objc private func nativeClick(_ sender: NSButton) { nativeClicks += 1 }

    func testPointerEventsUseGlobalWindowCoordinatesForSystemRouting() throws {
        var state = AppWindowEventState()
        let frame = CGRect(x: 2830, y: 38, width: 740, height: 1402)
        for kind in [AppWindowInput.Kind.down, .move, .up, .scroll] {
            var input = AppWindowInput(kind); input.x = 0.25; input.y = 0.2
            input.deltaY = 37
            let event = try XCTUnwrap(state.events(for: input, frame: frame, windowID: 115).first)
            XCTAssertEqual(event.location.x, 3015, accuracy: 0.001)
            XCTAssertEqual(event.location.y, 318.4, accuracy: 0.001)
            if kind == .scroll {
                XCTAssertEqual(event.type, .scrollWheel)
                XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 37)
            }
        }
        var down = AppWindowInput(.down); down.x = 1; down.y = 1; down.button = 1
        let event = try XCTUnwrap(state.events(for: down, frame: frame, windowID: 115).first)
        XCTAssertEqual(event.type, .rightMouseDown)
        XCTAssertEqual(event.location, CGPoint(x: frame.maxX - 1, y: frame.maxY - 1))
        XCTAssertEqual(state.release(windowID: 115).first?.location, event.location)
    }
    private let viewport = AppWindowViewport(width: 800, height: 600, scale: 2)
    private let send: AppWindowSend = { _, completion in completion(nil) }
    func testSmallAndExtremeAppViewportsRetainTheirAspectRatio() throws {
        for (width, height, scale, expectedWidth, expectedHeight) in [
            (320, 236, 1.0, 320, 236), (240, 160, 1.0, 240, 160),
            (4096, 160, 2.0, 4096, 160), (240, 4096, 3.0, 240, 4096),
            (800, 600, 2.0, 1600, 1200)
        ] {
            let viewport = AppWindowViewport(width: width, height: height, scale: scale)
            XCTAssertTrue(viewport.isValid)
            let size = try XCTUnwrap(viewport.pixels(width: Double(width), height: Double(height)))
            XCTAssertEqual(size, .init(width: expectedWidth, height: expectedHeight, frameRate: 60))
            XCTAssertTrue(size.isValidAppWindow)
        }
        XCTAssertFalse(StreamDisplaySize(width: 320, height: 236, frameRate: 60).isValid, "Desktop limits stay unchanged")
        XCTAssertNil(viewport.pixels(width: .infinity, height: 200))
        XCTAssertNil(viewport.pixels(width: 200, height: 0))
    }
    func testSoftwareEncoderEmitsASingleFrameWithoutAnotherFrame() async throws {
        for size in [StreamDisplaySize(width: 1600, height: 1200, frameRate: 60), .init(width: 320, height: 236, frameRate: 60)] {
            let received = expectation(description: "Software encoder emits \(size.width) × \(size.height)")
            var assembler = AppWindowVideoAssembler()
            let encoder = AppWindowVideoEncoder(send: { packet, completion in
                do {
                    if let frame = try assembler.receive(packet) {
                        XCTAssertTrue(frame.isValid); received.fulfill()
                    }
                    completion(nil)
                } catch { XCTFail(error.localizedDescription); completion(error) }
            }, encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false] as CFDictionary)
            defer { encoder.stop() }
            try encoder.configure(size)
            var image: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
            let buffer = try XCTUnwrap(image)
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 128,
                    CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
            XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
            let captured = try XCTUnwrap(sample)
            let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(captured, createIfNecessary: true) as? [NSMutableDictionary])
            attachments[0][SCStreamFrameInfo.status] = SCFrameStatus.complete.rawValue
            let metadata = CMSampleBufferGetSampleAttachmentsArray(captured, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
            XCTAssertEqual(metadata?.first?[.status] as? Int, SCFrameStatus.complete.rawValue)
            encoder.queue.sync { encoder.encode(captured) }
            await fulfillment(of: [received], timeout: 5)
        }
    }
    func testMouseClicksAndScrollPreserveCountsAndModifiersThroughAppKit() throws {
        var state = AppWindowEventState()
        let rect = CGRect(x: 10, y: 20, width: 800, height: 600)
        for count in 1...3 {
            for kind in [AppWindowInput.Kind.down, .up] {
                var input = AppWindowInput(kind); input.x = 0.5; input.y = 0.5
                input.clickCount = count; input.modifiers = CGEventFlags([.maskCommand, .maskShift]).rawValue
                let roundTrip = try JSONDecoder().decode(AppWindowInput.self, from: JSONEncoder().encode(input))
                let event = try XCTUnwrap(state.events(for: roundTrip, frame: rect, windowID: 42).first)
                let native = try XCTUnwrap(NSEvent(cgEvent: event))
                XCTAssertEqual(native.clickCount, count)
                XCTAssertTrue(native.modifierFlags.contains([.command, .shift]))
                XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointer), 42)
            }
        }
        var scroll = AppWindowInput(.scroll); scroll.deltaY = 30; scroll.modifiers = CGEventFlags.maskAlternate.rawValue
        let event = try XCTUnwrap(state.events(for: scroll, frame: rect, windowID: 42).first)
        XCTAssertTrue(try XCTUnwrap(NSEvent(cgEvent: event)).modifierFlags.contains(.option))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(scroll)) as? [String: Any])
        legacy.removeValue(forKey: "clickCount")
        XCTAssertTrue(try JSONDecoder().decode(AppWindowInput.self, from: JSONSerialization.data(withJSONObject: legacy)).isValid)
        scroll.clickCount = 0; XCTAssertFalse(scroll.isValid)
        scroll.clickCount = 4; XCTAssertFalse(scroll.isValid)
    }
    func testDisconnectReleasesHeldKeysWithoutReassertingModifiers() throws {
        var state = AppWindowEventState()
        let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
        for code: UInt16 in [55, 56, 0] {
            var down = AppWindowInput(.keyDown); down.keyCode = code
            down.modifiers = CGEventFlags([.maskCommand, .maskShift]).rawValue
            _ = state.events(for: down, frame: rect, windowID: 42)
        }
        var mouse = AppWindowInput(.down); mouse.modifiers = CGEventFlags.maskCommand.rawValue
        _ = state.events(for: mouse, frame: rect, windowID: 42)
        let released = state.release(windowID: 42)
        XCTAssertEqual(released.count, 4)
        let native = try released.map { try XCTUnwrap(NSEvent(cgEvent: $0)) }
        XCTAssertEqual(native.filter { $0.type == .flagsChanged }.count, 2)
        XCTAssertTrue(native.allSatisfy { $0.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty })
        XCTAssertTrue(state.release(windowID: 42).isEmpty, "Repeated cleanup must not release a sibling's input")
    }
    private func open(_ window: UInt32, session: String = UUID().uuidString) -> Packet {
        var packet = Packet(.appOpen); packet.applicationID = "app"; packet.windowID = window
        packet.sessionID = session; packet.viewport = viewport; return packet
    }
    private func rejected(_ action: () async throws -> Packet, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await action(); XCTFail("Unauthorized app operation succeeded", file: file, line: line) } catch {}
    }
    func testWindowsResizeAndReceiveInputIndependentlyAndRejectCrossConnectionControl() async throws {
        let host = RecordingAppHost(), manager = AppWindowSessionManager(host: host)
        let a = UUID(), b = UUID(), first = open(1), second = open(2)
        let reply = try await manager.handle(first, connection: a, device: "iPad", send: send)
        _ = try await manager.handle(second, connection: b, device: "iPad", send: send)
        XCTAssertEqual(reply.window?.id, 1)
        var resize = Packet(.appResize); resize.sessionID = first.sessionID
        resize.viewport = .init(width: 600, height: 900, scale: 2)
        await rejected { try await manager.handle(resize, connection: b, device: "iPad", send: send) }
        _ = try await manager.handle(resize, connection: a, device: "iPad", send: send)
        XCTAssertEqual(host.captures[0].resizes, [resize.viewport!]); XCTAssertTrue(host.captures[1].resizes.isEmpty)
        var input = Packet(.appInput); input.sessionID = second.sessionID; input.input = AppWindowInput(.keyDown)
        await rejected { try await manager.handle(input, connection: a, device: "iPad", send: send) }
        _ = try await manager.handle(input, connection: b, device: "iPad", send: send)
        XCTAssertTrue(host.captures[0].inputs.isEmpty); XCTAssertEqual(host.captures[1].inputs.count, 1)
        await rejected { try await manager.handle(open(1), connection: UUID(), device: "other", send: send) }
        manager.disconnected(a)
        XCTAssertEqual(host.captures[0].stops, 1); XCTAssertEqual(host.captures[1].stops, 0)
        _ = try await manager.handle(open(1), connection: UUID(), device: "other", send: send)
        manager.stop(); XCTAssertTrue(host.captures.allSatisfy { $0.stops == 1 })
    }
    func testLimitsStaleMessagesExpiryAndFailedCaptureRelease() async throws {
        var clock: TimeInterval = 100
        let host = RecordingAppHost(), manager = AppWindowSessionManager(host: host, now: { clock })
        for id in 1...4 { _ = try await manager.handle(open(UInt32(id)), connection: UUID(), device: "iPad", send: send) }
        await rejected { try await manager.handle(open(5), connection: UUID(), device: "iPad", send: send) }
        let connection = UUID(), request = open(5)
        _ = try await manager.handle(request, connection: connection, device: "other", send: send)
        var close = Packet(.appClose); close.sessionID = UUID().uuidString
        _ = try await manager.handle(close, connection: connection, device: "other", send: send)
        XCTAssertEqual(host.captures[4].stops, 0)
        clock += 15
        var heartbeat = Packet(.appHeartbeat); heartbeat.sessionID = request.sessionID
        _ = try await manager.handle(heartbeat, connection: connection, device: "other", send: send)
        clock += 5; manager.expire()
        XCTAssertTrue(host.captures.prefix(4).allSatisfy { $0.stops == 1 }); XCTAssertEqual(host.captures[4].stops, 0)
        host.failCapture = true
        await rejected { try await manager.handle(open(6), connection: UUID(), device: "iPad", send: send) }
        host.failCapture = false
        _ = try await manager.handle(open(6), connection: UUID(), device: "iPad", send: send)
        clock += 20; manager.expire(); XCTAssertTrue(host.captures.allSatisfy { $0.stops == 1 })
    }
    func testDisconnectDuringCaptureAndQueuedRequestsCannotAcquireAWindow() async throws {
        let host = RecordingAppHost(), manager = AppWindowSessionManager(host: host), connection = UUID()
        host.delayCapture = true
        let request = open(1)
        let starting = Task { try await manager.handle(request, connection: connection, device: "iPad", send: send) }
        while host.pauseCapture == nil { await Task.yield() }
        manager.disconnected(connection)
        host.pauseCapture?.resume(); host.pauseCapture = nil
        await rejected { try await starting.value }
        XCTAssertEqual(host.captures.first?.stops, 1)
        await rejected { try await manager.handle(open(2), connection: UUID(), device: "iPad", isConnected: { false }, send: send) }
        XCTAssertEqual(host.captures.count, 1)
    }
    func testCatalogPagingAndUntrustedViewportVideoInputValidation() async throws {
        let manager = AppWindowSessionManager(host: RecordingAppHost()), connection = UUID()
        var packet = Packet(.appList), apps: [RemoteApplication] = []
        repeat {
            let reply = try await manager.handle(packet, connection: connection, device: "iPad", send: send)
            XCTAssertLessThanOrEqual(reply.applications!.count, 64)
            _ = try FrameCodec.encode(reply)
            apps += reply.applications!; packet.offset = reply.offset
            if reply.eof == true { break }
        } while true
        XCTAssertEqual(apps.count, 130)
        var invalid = open(1); invalid.viewport = .init(width: Int.max, height: 600, scale: .nan)
        await rejected { try await manager.handle(invalid, connection: connection, device: "iPad", send: send) }
        XCTAssertEqual(viewport.pixels(width: 800, height: 600), .init(width: 1600, height: 1200, frameRate: 60))
        XCTAssertFalse(AppWindowViewport(width: 800, height: 600, scale: .infinity).isValid)
        var input = AppWindowInput(.scroll); input.deltaY = .infinity; XCTAssertFalse(input.isValid)
        input = AppWindowInput(.text); input.text = String(repeating: "a", count: 1025); XCTAssertFalse(input.isValid)
        let frame = AppWindowVideoFrame(data: Data(repeating: 7, count: AppStreaming.maximumVideoBytes), parameterSets: [Data([1]), Data([2])], timestamp: 1)
        XCTAssertTrue(frame.isValid)
        var assembler = AppWindowVideoAssembler(), assembled: AppWindowVideoFrame?
        for offset in stride(from: 0, to: frame.data.count, by: AppStreaming.videoChunkSize) {
            var packet = Packet(.appVideo); packet.offset = Int64(offset); packet.size = Int64(frame.data.count); packet.transferID = "frame"
            packet.video = .init(data: frame.data.subdata(in: offset..<min(frame.data.count, offset + AppStreaming.videoChunkSize)), parameterSets: frame.parameterSets, timestamp: frame.timestamp)
            _ = try FrameCodec.encode(packet)
            assembled = try assembler.receive(packet)
        }
        XCTAssertEqual(assembled?.data, frame.data)
        var invalidFragment = Packet(.appVideo); invalidFragment.offset = 1; invalidFragment.size = Int64(frame.data.count); invalidFragment.transferID = "frame"
        invalidFragment.video = .init(data: Data([1]), parameterSets: frame.parameterSets, timestamp: 1)
        XCTAssertThrowsError(try assembler.receive(invalidFragment))
    }
    func testNativeWindowCaptureAndResize() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_APP_WINDOWS"] == "1" else { throw XCTSkip("Opt in to capturing/resizing a test Mac window") }
        guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else { throw XCTSkip("Native app capture requires Screen Recording and Accessibility for the test process") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular); NSApp.finishLaunching()
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Nocturne capture test"; window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        let field = NSTextField(frame: CGRect(x: 30, y: 40, width: 400, height: 30))
        window.contentView?.addSubview(field); window.makeFirstResponder(field)
        let button = NSButton(title: "Test remote click", target: self, action: #selector(nativeClick(_:)))
        button.frame = CGRect(x: 30, y: 120, width: 180, height: 30)
        window.contentView?.addSubview(button); nativeClicks = 0
        let other = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 700, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        other.title = "Another Nocturne window"; other.isReleasedWhenClosed = false; other.orderFront(nil)
        defer { window.close(); other.close() }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let source = try XCTUnwrap(content.windows.first { $0.windowID == UInt32(window.windowNumber) })
        let otherSource = try XCTUnwrap(content.windows.first { $0.windowID == UInt32(other.windowNumber) })
        var frame: XCTestExpectation?
        var gotFrame = false
        let capture = try NativeAppWindowCapture(window: source, applicationID: "test", send: { packet, completion in
            if packet.video?.isValid == true, !gotFrame { gotFrame = true; frame?.fulfill() }; completion(nil)
        }, ended: { XCTFail($0.localizedDescription) })
        let second = try NativeAppWindowCapture(window: otherSource, applicationID: "test", send: { _, completion in completion(nil) }, ended: { XCTFail($0.localizedDescription) })
        defer { capture.stop(); second.stop() }
        let waiting = expectation(description: "Real window H.264 frame"); frame = waiting
        do { try await capture.start(viewport) }
        catch { waiting.fulfill(); await fulfillment(of: [waiting], timeout: 1); XCTFail("Starting native window capture: \(error)"); return }
        await fulfillment(of: [waiting], timeout: 8)
        do { try await second.start(.init(width: 700, height: 500, scale: 2)) }
        catch { throw NocturneError.remote("Starting second test capture: \(error)") }
        try await capture.resize(.init(width: 640, height: 480, scale: 2))
        XCTAssertEqual(capture.window.width, 640); XCTAssertEqual(capture.window.height, 480)
        XCTAssertEqual(capture.display, .init(width: 1280, height: 960, frameRate: 60))
        XCTAssertEqual(second.window.width, 700); XCTAssertEqual(second.window.height, 500)
        var text = AppWindowInput(.text); text.text = "Nocturne"
        do { try await capture.input(text) }
        catch { throw NocturneError.remote("Typing into native test window: \(error)") }
        for _ in 0..<100 where field.currentEditor()?.string.contains("Nocturne") != true {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(field.currentEditor()?.string.contains("Nocturne") == true)
        let accessibility = try AppWindowAccessibility(pid: getpid(), windowID: UInt32(window.windowNumber))
        let bounds = try XCTUnwrap(accessibility.frame)
        let screenPoint = window.convertPoint(toScreen: CGPoint(x: button.frame.midX, y: button.frame.midY))
        let top = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        var click = AppWindowInput(.down)
        click.x = (screenPoint.x - bounds.minX) / bounds.width
        click.y = (top - screenPoint.y - bounds.minY) / bounds.height
        do { try await capture.input(click); click.kind = .up; try await capture.input(click) }
        catch { throw NocturneError.remote("Clicking native test control: \(error)") }
        for _ in 0..<100 where nativeClicks == 0 {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(nativeClicks, 1, "Remote down/up must activate the native control, not merely acknowledge input")
        if let screen = NSScreen.screens.first, screen.visibleFrame.height >= 1100 {
            window.contentMinSize = CGSize(width: 740, height: 200)
            try await capture.resize(.init(width: 430, height: 600, scale: 2))
            let fitted = try XCTUnwrap(accessibility.frame)
            XCTAssertEqual(fitted.width / fitted.height, 430.0 / 600.0, accuracy: 0.002,
                "Await both AX position and size before reporting a fitted portrait window")
            XCTAssertEqual(capture.window.width, Int(fitted.width))
            XCTAssertEqual(capture.window.height, Int(fitted.height))
        }
        capture.stop()
        try await second.input(AppWindowInput(.move))
    }
    func testMinimumWindowWidthKeepsPortraitPhoneProportions() async throws {
        let viewport = AppWindowViewport(width: 430, height: 785, scale: 3)
        var requests: [CGSize] = []
        let size = try AppWindowAccessibility.resizeToMatch(viewport) { requested in
            requests.append(requested)
            return CGSize(width: max(740, requested.width), height: requested.height)
        }
        XCTAssertEqual(requests.count, 2, "Compensate when the app clamps the requested window width")
        XCTAssertGreaterThanOrEqual(size.width, 740)
        XCTAssertEqual(size.width / size.height, 430.0 / 785.0, accuracy: 0.001,
            "App minimum widths must not turn a portrait stream into a letterboxed square")
    }
    func testFixedSizeWindowCanStreamWhenTheAppRejectsResizing() throws {
        let original = CGSize(width: 620, height: 440)
        do {
            let size = try AppWindowAccessibility.resizeToMatch(.init(width: 1200, height: 700, scale: 2),
                currentSize: { original }) { _ in throw AppWindowAccessibility.ResizeUnavailable() }
            XCTAssertEqual(size, original, "Stream the fixed-size app at its actual aspect ratio")
        } catch { XCTFail("Opening a non-resizable app must not fail: \(error)") }
    }
    func testResizeFallbackReadsCurrentGeometryAndPreservesPermissionErrors() throws {
        var current = CGSize(width: 400, height: 300), calls = 0
        let result = try AppWindowAccessibility.resizeToMatch(.init(width: 430, height: 785, scale: 2), currentSize: { current }) { proposed in
            calls += 1
            if calls == 2 { throw AppWindowAccessibility.ResizeUnavailable() }
            current = .init(width: 740, height: proposed.height); return current
        }
        XCTAssertEqual(calls, 2); XCTAssertEqual(result, current, "Read the actual window after a partial resize")
        XCTAssertThrowsError(try AppWindowAccessibility.resizeToMatch(.init(width: 800, height: 600, scale: 1),
            currentSize: { current }) { _ in throw NocturneError.permissionDenied }) { error in
                XCTAssertEqual(error as? NocturneError, .permissionDenied)
            }
        let legacy = Data(#"{"id":1,"applicationID":"app","title":"Window","width":620,"height":440}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RemoteAppWindow.self, from: legacy).isResizable)
    }
    func testAppThatSilentlyIgnoresWritableSizeIsReportedAsFixed() throws {
        let size = CGSize(width: 620, height: 440)
        let fixed = try AppWindowAccessibility.resizeIfPossible(.init(width: 1200, height: 700, scale: 2),
            currentSize: { size }, apply: { _ in size })
        XCTAssertEqual(fixed.size, size); XCTAssertFalse(fixed.isResizable)
        var current = size
        let resizing = try AppWindowAccessibility.resizeIfPossible(.init(width: 800, height: 600, scale: 2),
            currentSize: { current }, apply: { current = $0; return current })
        XCTAssertEqual(resizing.size, .init(width: 800, height: 600)); XCTAssertTrue(resizing.isResizable)
    }
    func testTallPhoneWindowMovesUpBeforeMacOSClampsItsHeight() {
        let visible = CGRect(x: 0, y: 38, width: 5120, height: 1402)
        let position = AppWindowAccessibility.positionToFit(CGPoint(x: 2830, y: 549),
            size: CGSize(width: 740, height: 1409), visibleFrame: visible)
        XCTAssertEqual(position, CGPoint(x: 2830, y: 38))
        XCTAssertEqual(AppWindowAccessibility.positionToFit(CGPoint(x: 100, y: 100),
            size: CGSize(width: 800, height: 600), visibleFrame: visible), CGPoint(x: 100, y: 100))
    }
    func testNativeCatalogAndIcons() throws {
        let host = NativeAppWindowHost(), apps = try host.applications()
        XCTAssertFalse(apps.isEmpty); XCTAssertEqual(Set(apps.map(\.id)).count, apps.count)
        let app = try XCTUnwrap(apps.first)
        let icon = try host.icon(applicationID: app.id)
        XCTAssertNotNil(NSImage(data: icon)); XCTAssertLessThanOrEqual(icon.count, 131_072)
        XCTAssertThrowsError(try host.icon(applicationID: "/tmp/arbitrary.app"))
    }
}

@MainActor
final class AppWindowIntegrationTests: XCTestCase {
    func testAuthenticatedIndependentSocketsEventsAndDeviceRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let host = RecordingAppHost(), windows = AppWindowSessionManager(host: host)
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Mac", devices: store, appWindows: windows)
        defer { server.stop(); windows.stop() }
        let secret = try SecureStore.randomKey(), port = UInt16.random(in: 52_000..<60_000)
        let listening = expectation(description: "Listening"); var started = false
        server.onStatus = { status, _ in if status == "Ready", !started { started = true; listening.fulfill() } }
        try server.start(secret: secret, port: port); await fulfillment(of: [listening], timeout: 5)
        let rejected = expectation(description: "Unauthenticated app access rejected")
        let raw = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: SecureTransport.parameters(secret: secret)))
        raw.onReady = { raw.send(Packet(.appLaunch)) }
        raw.onPacket = { packet in XCTAssertNotNil(packet.error); rejected.fulfill() }
        raw.start(); await fulfillment(of: [rejected], timeout: 5); raw.cancel()
        let first = try TestDeviceIdentity(), second = try TestDeviceIdentity()
        let a = WorkspaceConnection(identity: first.identity()), b = a.mediaConnection(), c = WorkspaceConnection(identity: second.identity())
        defer { a.disconnect(); b.disconnect(); c.disconnect() }
        let link = try PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: secret, enrollmentToken: store.createInvitation())
        try await a.connect(link)
        // A restored app scene must find the paired Mac independently of the
        // library scene, including when its saved address and port are stale.
        let stale = try link.replacingAddress(host: "192.0.2.123", port: 1)
        try await b.connect(stale, restoreTerminalSessions: false, rediscover: true)
        XCTAssertEqual(b.connectedInvitation?.port, port)
        XCTAssertEqual(b.connectedInvitation?.secret, link.secret)
        XCTAssertTrue(b.terminals.isEmpty)
        try await c.connect(PairingInvitation(host: link.host, port: port, name: "Mac", secret: secret, enrollmentToken: store.createInvitation()))
        XCTAssertTrue(a.capabilities.contains(AppStreaming.capability))
        let idA = UUID().uuidString, idB = UUID().uuidString, idC = UUID().uuidString
        for (client, id, window) in [(a, idA, UInt32(1)), (b, idB, UInt32(2)), (c, idC, UInt32(3))] {
            var open = Packet(.appOpen); open.applicationID = "app"; open.sessionID = id; open.windowID = window
            open.viewport = .init(width: 800, height: 600, scale: 2)
            let reply = try await client.request(open); XCTAssertEqual(reply.window?.id, window)
        }
        let video = expectation(description: "Video event reaches its own socket")
        b.onAppPacket = { packet in XCTAssertEqual(packet.sessionID, idB); XCTAssertEqual(packet.video?.data, Data([7])); video.fulfill() }
        a.onAppPacket = { _ in XCTFail("Video crossed to another window") }
        var frame = Packet(.appVideo); frame.video = .init(data: Data([7]), parameterSets: [Data([1]), Data([2])], timestamp: 1)
        host.captures[1].send(frame) { _ in }
        await fulfillment(of: [video], timeout: 5)
        var input = Packet(.appInput); input.sessionID = idA; input.input = AppWindowInput(.down)
        do { _ = try await b.request(input); XCTFail("A sibling socket controlled another window") } catch {}
        a.disconnect()
        for _ in 0..<100 where host.captures[0].stops == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(host.captures[0].stops, 1); XCTAssertEqual(host.captures[1].stops, 0)
        try store.remove(first.id); server.disconnectDevice(first.id)
        for _ in 0..<100 where host.captures[1].stops == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(host.captures[1].stops, 1); XCTAssertEqual(host.captures[2].stops, 0)
        var heartbeat = Packet(.appHeartbeat); heartbeat.sessionID = idC; _ = try await c.request(heartbeat)
    }
}
