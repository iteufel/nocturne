import XCTest
import AppKit
import CoreGraphics
import DisplayBridge
import NocturneKit
@testable import NocturneHostKit

@MainActor
private final class RecordingDisplayDriver: StreamingDisplayDriver {
    var sizes: [StreamDisplaySize] = []
    var hidesDisplays = false
    var restorations = 0
    var stops = 0
    var failApply = false
    var failRestore = false
    func start() async throws {}
    func apply(_ size: StreamDisplaySize, disablePhysicalDisplays: Bool) async throws {
        sizes.append(size); hidesDisplays = disablePhysicalDisplays
        if failApply { throw NocturneError.remote("Display configuration failed") }
    }
    func restore() throws { restorations += 1; if failRestore { throw NocturneError.remote("Display restoration failed") } }
    func stop() throws { stops += 1 }
}

@MainActor
final class DisplayTests: XCTestCase {
    private func assertFailure(_ action: () async throws -> Packet, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await action(); XCTFail("Unexpectedly accepted display control", file: file, line: line) } catch {}
    }
    private let portrait = StreamDisplaySize(width: 1320, height: 2868, frameRate: 60)
    private let landscape = StreamDisplaySize(width: 2868, height: 1320, frameRate: 60)
    private func request(_ operation: NocturneKit.Operation = .displayPrepare, id: String, size: StreamDisplaySize? = nil) -> Packet {
        var packet = Packet(operation); packet.sessionID = id; packet.display = size; return packet
    }
    func testDevicePixelsFollowOrientationAndWindowSize() throws {
        XCTAssertEqual(StreamDisplaySize.matching(width: 440, height: 956, scale: 3, frameRate: 60), portrait)
        XCTAssertEqual(StreamDisplaySize.matching(width: 956, height: 440, scale: 3, frameRate: 60), landscape)
        XCTAssertEqual(StreamDisplaySize.matching(width: 1032, height: 1376, scale: 2, frameRate: 120), .init(width: 2064, height: 2752, frameRate: 120))
        XCTAssertEqual(StreamDisplaySize.matching(width: 800, height: 1000, scale: 2, frameRate: 60), .init(width: 1600, height: 2000, frameRate: 60))
        XCTAssertEqual(StreamDisplaySize.matching(width: 3840, height: 2160, scale: 2, frameRate: 60), .init(width: 4096, height: 2304, frameRate: 60))
        XCTAssertNil(StreamDisplaySize.matching(width: .nan, height: 900, scale: 2, frameRate: 60))
        XCTAssertNil(StreamDisplaySize.matching(width: 0, height: 900, scale: 2, frameRate: 60))
        XCTAssertNil(StreamDisplaySize.matching(width: 300, height: 900, scale: .infinity, frameRate: 60))
        XCTAssertFalse(StreamDisplaySize(width: Int.max, height: 1080, frameRate: 60).isValid)
        XCTAssertFalse(StreamDisplaySize(width: 1919, height: 1080, frameRate: 60).isValid)
        XCTAssertFalse(StreamDisplaySize(width: 1920, height: 1080, frameRate: 1000).isValid)
    }
    func testLeaseRejectsAnotherConnectionAndStaleMessages() async throws {
        let driver = RecordingDisplayDriver(), connection = UUID(), other = UUID(), id = UUID().uuidString
        let manager = DisplaySessionManager(driver: driver, timeout: 20); manager.disablePhysicalDisplays = true
        let first = try await manager.handle(request(id: id, size: portrait), connection: connection, name: "iPhone")
        XCTAssertEqual(first.display, portrait); XCTAssertTrue(driver.hidesDisplays)
        for operation in [NocturneKit.Operation.displayPrepare, .displayHeartbeat, .displayRelease] {
            await assertFailure { try await manager.handle(request(operation, id: id, size: landscape), connection: other, name: "iPad") }
        }
        await assertFailure { try await manager.handle(request(id: UUID().uuidString, size: landscape), connection: connection, name: "iPhone") }
        XCTAssertEqual(driver.sizes, [portrait]); XCTAssertEqual(driver.restorations, 0)
        _ = try await manager.handle(request(id: id, size: landscape), connection: connection, name: "iPhone")
        XCTAssertEqual(driver.sizes, [portrait, landscape])
        manager.disconnected(other); XCTAssertTrue(manager.isActive)
        manager.disconnected(connection); XCTAssertFalse(manager.isActive); XCTAssertEqual(driver.restorations, 1)
        await assertFailure { try await manager.handle(request(.displayHeartbeat, id: id), connection: connection, name: "iPhone") }
        await assertFailure { try await manager.handle(request(id: UUID().uuidString, size: .init(width: -1, height: 900, frameRate: 60)), connection: other, name: "iPad") }
        XCTAssertEqual(driver.sizes.count, 2)
    }
    func testHeartbeatExpiryAndFailedConfigurationRestoreDisplays() async throws {
        let driver = RecordingDisplayDriver(), connection = UUID(), id = UUID().uuidString, start = Date()
        let manager = DisplaySessionManager(driver: driver, timeout: 20)
        _ = try await manager.handle(request(id: id, size: portrait), connection: connection, name: "iPhone", now: start)
        _ = try await manager.handle(request(.displayHeartbeat, id: id), connection: connection, name: "iPhone", now: start.addingTimeInterval(10))
        manager.expire(now: start.addingTimeInterval(25)); XCTAssertTrue(manager.isActive)
        manager.expire(now: start.addingTimeInterval(30)); XCTAssertFalse(manager.isActive); XCTAssertEqual(driver.restorations, 1)
        driver.failApply = true
        await assertFailure { try await manager.handle(request(id: id, size: portrait), connection: connection, name: "iPhone") }
        XCTAssertFalse(manager.isActive); XCTAssertEqual(driver.restorations, 2)
        driver.failRestore = true; manager.restore(); XCTAssertNotNil(manager.lastError)
        driver.failRestore = false; manager.stop(); XCTAssertNil(manager.lastError); XCTAssertEqual(driver.stops, 1)
    }
    func testNativeVirtualDisplaysMatchRequestedPixelDimensions() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_DISPLAYS"] == "1" else { throw XCTSkip("Opt in to real WindowServer display changes") }
        guard NDDisplayLayout.isSessionAvailable() else { throw XCTSkip("Unlock the Mac before running native display tests") }
        _ = NSApplication.shared
        var previous: NDVirtualDisplay?
        defer { previous = nil }
        for size in [portrait, landscape, .init(width: 2064, height: 2752, frameRate: 60)] {
            let display = try NDVirtualDisplay(width: UInt(size.width), height: UInt(size.height), refreshRate: UInt(size.frameRate))
            let id = display.displayID
            var selected = false
            for _ in 0..<40 {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                if (try? display.selectRequestedMode()) != nil { selected = true; break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(selected, "Requested mode did not become available")
            let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(id))
            XCTAssertEqual(mode.pixelWidth, size.width)
            XCTAssertEqual(mode.pixelHeight, size.height)
            XCTAssertEqual(mode.width, size.width / 2)
            XCTAssertNotEqual(previous?.displayID, id)
            previous = display
        }
    }
    func testAuthenticatedTransportReleasesDisplayOnDisconnectAndRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Nocturne-display-" + UUID().uuidString)
        let store = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Mac", devices: store)
        let driver = RecordingDisplayDriver()
        let connectedManager = DisplaySessionManager(driver: driver, timeout: 20)
        server.displayCommand = { packet, connection, name, completion in
            Task { @MainActor in
                do { completion(try await connectedManager.handle(packet, connection: connection, name: name)) }
                catch { completion(packet.reply(error: error.localizedDescription)) }
            }
        }
        server.displayDisconnected = { connection in Task { @MainActor in connectedManager.disconnected(connection) } }
        let key = try SecureStore.randomKey(), port = UInt16.random(in: 52_000..<60_000)
        let ready = expectation(description: "Display listener ready"); var signalled = false
        server.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; ready.fulfill() } }
        let identity = try TestDeviceIdentity(), first = WorkspaceConnection(identity: try TestDeviceIdentity().identity())
        let second = WorkspaceConnection(identity: identity.identity())
        defer { first.disconnect(); second.disconnect(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try server.start(secret: key, port: port); await fulfillment(of: [ready], timeout: 5)
        func enroll(_ client: WorkspaceConnection) async throws {
            try await client.connect(PairingInvitation(host: "127.0.0.1", port: port, name: "Mac", secret: key, enrollmentToken: store.createInvitation()))
        }
        try await enroll(first); try await enroll(second)
        XCTAssertTrue(first.capabilities.contains("display"))
        let lease = UUID().uuidString
        _ = try await first.request(request(id: lease, size: portrait))
        do { _ = try await second.request(request(id: lease, size: landscape)); XCTFail("Another device took the display") } catch {}
        XCTAssertEqual(driver.sizes, [portrait])
        first.disconnect()
        for _ in 0..<100 { if !connectedManager.isActive { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(connectedManager.isActive); XCTAssertEqual(driver.restorations, 1)
        _ = try await second.request(request(id: UUID().uuidString, size: landscape))
        server.disconnectDevice(WorkspaceIdentity.fingerprint(identity.certificate))
        for _ in 0..<100 { if !connectedManager.isActive { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(connectedManager.isActive); XCTAssertEqual(driver.restorations, 2)
    }
    func testNativeDisplayLeaseDisablesAndRestoresOriginalScreens() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_DISPLAY_SWITCH"] == "1" else { throw XCTSkip("Opt in to switching physical displays") }
        guard NDDisplayLayout.isSessionAvailable() else { throw XCTSkip("Unlock the Mac before running native display tests") }
        _ = NSApplication.shared
        var ids = [CGDirectDisplayID](repeating: 0, count: 64), count: UInt32 = 0
        XCTAssertEqual(CGGetActiveDisplayList(64, &ids, &count), .success)
        let original = Array(ids.prefix(Int(count))), main = CGMainDisplayID()
        let before = original.map { CGDisplayBounds($0) }
        let manager = DisplaySessionManager(driver: NativeStreamingDisplayDriver(), timeout: 20); manager.disablePhysicalDisplays = true
        let events = Task { @MainActor in
            while !Task.isCancelled {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.03), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { events.cancel() }
        defer { manager.stop() }
        let connection = UUID(), id = UUID().uuidString
        for size in [portrait, landscape, .init(width: 2064, height: 2752, frameRate: 60)] {
            _ = try await manager.handle(request(id: id, size: size), connection: connection, name: "Display verification")
            let active = CGMainDisplayID(), mode = try XCTUnwrap(CGDisplayCopyDisplayMode(active))
            XCTAssertEqual(mode.pixelWidth, size.width); XCTAssertEqual(mode.pixelHeight, size.height)
            XCTAssertFalse(NDDisplayLayout.hasActiveDisplayOtherThan(active))
            for display in original { XCTAssertEqual(CGDisplayIsActive(display), 0) }
        }
        _ = try await manager.handle(request(.displayRelease, id: id), connection: connection, name: "Display verification")
        for _ in 0..<30 {
            if manager.lastError == nil { break }
            try await Task.sleep(nanoseconds: 100_000_000); manager.restore()
        }
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(CGMainDisplayID(), main)
        for (index, display) in original.enumerated() {
            XCTAssertNotEqual(CGDisplayIsActive(display), 0)
            XCTAssertEqual(CGDisplayBounds(display), before[index])
        }
    }
    func testNativeRestorationIgnoresReplacedStartupDisplay() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_DISPLAY_SWITCH"] == "1" else { throw XCTSkip("Opt in to switching physical displays") }
        guard NDDisplayLayout.isSessionAvailable() else { throw XCTSkip("Unlock the Mac before running native display tests") }
        _ = NSApplication.shared
        let originalMain = CGMainDisplayID()
        let events = Task { @MainActor in
            while !Task.isCancelled {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.03), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { events.cancel() }
        var bootstrap: NDVirtualDisplay? = try NDVirtualDisplay(width: 1920, height: 1080, refreshRate: 60)
        let bootstrapID = try XCTUnwrap(bootstrap?.displayID)
        let layout = NDDisplayLayout(excludingDisplay: bootstrapID)
        let replacement = try NDVirtualDisplay(width: 1320, height: 2868, refreshRate: 60)
        // Keep the replacement alive through restoration, including a failing assertion.
        defer { try? layout.restore(); withExtendedLifetime(replacement) {} }
        for _ in 0..<40 {
            if (try? replacement.selectRequestedMode()) != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try layout.makePrimary(replacement.displayID, disableOthers: true)
        bootstrap = nil // The startup framebuffer no longer exists.
        var failure: Error?
        for _ in 0..<30 {
            do { try layout.restore(); failure = nil; break } catch { failure = error }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(failure)
        XCTAssertEqual(CGMainDisplayID(), originalMain)
        XCTAssertEqual(CGDisplayIsOnline(bootstrapID), 0)
    }
}
