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
    var displayID: UInt32 = 100
    @discardableResult func start() async throws -> UInt32 { displayID }
    @discardableResult func apply(_ size: StreamDisplaySize, disablePhysicalDisplays: Bool) async throws -> UInt32 {
        sizes.append(size); hidesDisplays = disablePhysicalDisplays
        if failApply { throw NocturneError.remote("Display configuration failed") }
        displayID += 1; return displayID
    }
    func restore() throws { restorations += 1; if failRestore { throw NocturneError.remote("Display restoration failed") } }
    func stop() throws { stops += 1 }
}

@MainActor
private final class FakeVirtualDisplay: StreamingVirtualDisplay {
    let displayID: UInt32
    var selected = false
    var onSelect: (() -> Void)?
    init(_ id: UInt32) { displayID = id }
    func selectRequestedMode() throws { selected = true; onSelect?() }
}

@MainActor
private final class FakeDisplayLayout: StreamingDisplayLayout {
    var primaryChanges: [UInt32] = []
    var disabled = false
    var restorations = 0
    var failRestore = false
    func makePrimary(_ display: UInt32, disableOthers: Bool) throws {
        primaryChanges.append(display); disabled = disableOthers
    }
    func restore() throws {
        restorations += 1
        if failRestore { throw NocturneError.remote("Physical display is still waking") }
    }
}

@MainActor
private final class FakeDisplayEnvironment {
    var sizes: [StreamDisplaySize] = []
    var exclusions: [UInt32] = []
    var onConsole = true
    var loginDone = true
    var locked = false
    var onSelect: (() -> Void)?
    weak var lastDisplay: FakeVirtualDisplay?
    let layout = FakeDisplayLayout()
    var environment: StreamingDisplayEnvironment {
        .init(isSessionAvailable: {
            NDDisplayLayout.isSessionAvailable(forSession: [
                kCGSessionOnConsoleKey as String: self.onConsole,
                kCGSessionLoginDoneKey as String: self.loginDone,
                "CGSSessionScreenIsLocked": self.locked
            ])
        }, isScreenLocked: { self.locked }, create: {
            self.sizes.append($0)
            let display = FakeVirtualDisplay(UInt32(100 + self.sizes.count))
            display.onSelect = self.onSelect
            self.lastDisplay = display; return display
        }, captureLayout: { self.exclusions.append($0); return self.layout })
    }
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
    func testLockedConsoleSessionCanPrepareResizeAndReleaseDisplay() async throws {
        let environment = FakeDisplayEnvironment()
        environment.locked = true
        let driver = NativeStreamingDisplayDriver(environment: environment.environment)
        var captureTargets: [UInt32] = []
        let manager = DisplaySessionManager(driver: driver, timeout: 20) { captureTargets.append($0) }
        defer { manager.stop() }
        _ = try await manager.start()
        manager.restore()
        let connection = UUID(), id = UUID().uuidString
        let reply = try await manager.handle(request(id: id, size: portrait), connection: connection, name: "iPad")
        XCTAssertEqual(reply.display, portrait)
        XCTAssertEqual(captureTargets, [environment.lastDisplay?.displayID].compactMap { $0 })
        XCTAssertTrue(manager.isActive)
        environment.locked = false
        _ = try await manager.handle(request(.displayHeartbeat, id: id), connection: connection, name: "iPad")
        _ = try await manager.handle(request(id: id, size: landscape), connection: connection, name: "iPad")
        XCTAssertEqual(manager.size, landscape)
        environment.locked = true
        manager.disconnected(connection)
        XCTAssertFalse(manager.isActive)
        XCTAssertNil(environment.lastDisplay)
        XCTAssertTrue(environment.exclusions.isEmpty, "Lock-screen access must preserve the physical display layout")
    }
    func testDisplayAccessStillRequiresLoggedInConsoleSession() async throws {
        XCTAssertFalse(NDDisplayLayout.isSessionAvailable(forSession: nil))
        XCTAssertFalse(NDDisplayLayout.isSessionAvailable(forSession: [:]))
        for state in [(false, true), (true, false), (false, false)] {
            let environment = FakeDisplayEnvironment()
            environment.onConsole = state.0
            environment.loginDone = state.1
            environment.locked = true
            let driver = NativeStreamingDisplayDriver(environment: environment.environment)
            do {
                _ = try await driver.start()
                XCTFail("An inactive or logged-out session must not configure displays")
            } catch {}
            XCTAssertTrue(environment.sizes.isEmpty)
        }
    }
    func testLockedLoginDefersPhysicalLayoutChangesUntilUnlockedPreparation() async throws {
        let environment = FakeDisplayEnvironment()
        environment.locked = true
        let driver = NativeStreamingDisplayDriver(environment: environment.environment)
        let manager = DisplaySessionManager(driver: driver, timeout: 20)
        manager.disablePhysicalDisplays = true
        defer { manager.stop() }
        let connection = UUID(), id = UUID().uuidString
        _ = try await manager.handle(request(id: id, size: portrait), connection: connection, name: "iPad")
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(environment.exclusions.isEmpty)
        XCTAssertTrue(environment.layout.primaryChanges.isEmpty)
        let display = try XCTUnwrap(environment.lastDisplay?.displayID)
        environment.locked = false
        _ = try await manager.handle(request(id: id, size: portrait), connection: connection, name: "iPad")
        XCTAssertEqual(environment.exclusions, [display])
        XCTAssertEqual(environment.layout.primaryChanges, [display])
        manager.disconnected(connection)
        XCTAssertEqual(environment.layout.restorations, 1)
        XCTAssertNil(environment.lastDisplay)
    }
    func testLockDuringModePublicationSkipsPhysicalLayoutChange() async throws {
        let environment = FakeDisplayEnvironment()
        environment.onSelect = { [weak environment] in environment?.locked = true }
        let driver = NativeStreamingDisplayDriver(environment: environment.environment)
        defer { try? driver.stop() }
        let display = try await driver.apply(portrait, disablePhysicalDisplays: true)
        XCTAssertNotEqual(display, 0)
        XCTAssertTrue(environment.locked)
        XCTAssertTrue(environment.layout.primaryChanges.isEmpty)
    }
    func testMatchDeviceDoesNotSilentlySkipDesktopPreparation() throws {
        let id = UUID().uuidString
        // A fixed Mac display currently advertises streaming without display control.
        // Returning nil here would start device-sized video over an unchanged desktop.
        XCTAssertThrowsError(try StreamDisplayPreparation.request(size: portrait, sessionID: id,
            matchesDevice: true, workspaceLinked: true, capabilities: ["streaming"]))
        XCTAssertThrowsError(try StreamDisplayPreparation.request(size: portrait, sessionID: id,
            matchesDevice: true, workspaceLinked: false, capabilities: ["display"]))
        let prepared = try XCTUnwrap(StreamDisplayPreparation.request(size: portrait, sessionID: id,
            matchesDevice: true, workspaceLinked: true, capabilities: ["display"]))
        XCTAssertEqual(prepared.operation, .displayPrepare)
        XCTAssertEqual(prepared.display, portrait)
        XCTAssertEqual(prepared.sessionID, id)
        let fixed = try XCTUnwrap(StreamDisplayPreparation.request(size: landscape, sessionID: id,
            matchesDevice: false, workspaceLinked: true, capabilities: ["display"]))
        XCTAssertEqual(fixed.operation, .displayPrepare, "Fixed resolutions also need a live display lease")
        XCTAssertEqual(fixed.display, landscape)
        XCTAssertNil(try StreamDisplayPreparation.request(size: landscape, sessionID: id,
            matchesDevice: false, workspaceLinked: false, capabilities: []))
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
    func testVirtualMonitorStartsResizesAndReleasesWithoutChangingPhysicalLayout() async throws {
        let environment = FakeDisplayEnvironment()
        let driver = NativeStreamingDisplayDriver(environment: environment.environment)
        let initial = try await driver.start()
        XCTAssertNotEqual(initial, 0)
        XCTAssertEqual(environment.sizes, [.init(width: 1920, height: 1080, frameRate: 60)])
        weak var initialDisplay = environment.lastDisplay
        let first = try await driver.apply(portrait, disablePhysicalDisplays: false)
        XCTAssertNotEqual(first, initial); XCTAssertNil(initialDisplay)
        initialDisplay = nil
        let repeated = try await driver.apply(portrait, disablePhysicalDisplays: false)
        XCTAssertEqual(repeated, first); XCTAssertEqual(environment.sizes.count, 2)
        let rotated = try await driver.apply(landscape, disablePhysicalDisplays: false)
        XCTAssertNotEqual(rotated, first)
        XCTAssertEqual(environment.sizes.last, landscape)
        XCTAssertEqual(environment.lastDisplay?.selected, true)
        weak var current = environment.lastDisplay
        try driver.restore()
        XCTAssertNil(current, "Idle virtual monitors must disappear after disconnect")
        let restarted = try await driver.start()
        XCTAssertNotEqual(restarted, rotated)
        XCTAssertTrue(environment.exclusions.isEmpty)
        XCTAssertTrue(environment.layout.primaryChanges.isEmpty)
        XCTAssertEqual(environment.layout.restorations, 0)
        weak var restartedDisplay = environment.lastDisplay
        try driver.stop(); XCTAssertNil(restartedDisplay)
        current = nil
    }
    func testDisconnectDestroysTheLeasedVirtualMonitor() async throws {
        for reason in ["release", "socket", "heartbeat"] {
            let environment = FakeDisplayEnvironment()
            let driver = NativeStreamingDisplayDriver(environment: environment.environment)
            var captureTargets: [UInt32] = []
            let manager = DisplaySessionManager(driver: driver, timeout: 20) { captureTargets.append($0) }
            defer { manager.stop() }
            let connection = UUID(), id = UUID().uuidString
            _ = try await manager.start()
            weak var bootstrap = environment.lastDisplay
            manager.restore()
            XCTAssertNil(bootstrap, "The startup framebuffer must not remain on an idle server")
            _ = try await manager.handle(request(id: id, size: portrait), connection: connection, name: "iPad")
            let firstTarget = try XCTUnwrap(environment.lastDisplay?.displayID)
            XCTAssertEqual(captureTargets, [firstTarget])
            weak var monitor = environment.lastDisplay
            XCTAssertNotNil(monitor)
            switch reason {
            case "release":
                _ = try await manager.handle(request(.displayRelease, id: id), connection: connection, name: "iPad")
            case "socket": manager.disconnected(connection)
            default: manager.expire(now: Date().addingTimeInterval(21))
            }
            XCTAssertFalse(manager.isActive)
            XCTAssertNil(monitor, "Nocturne Display must disappear after \(reason), without stopping the server")
            let nextID = UUID().uuidString
            let reply = try await manager.handle(request(id: nextID, size: portrait), connection: connection, name: "iPad")
            let nextTarget = try XCTUnwrap(environment.lastDisplay?.displayID)
            XCTAssertNotEqual(nextTarget, firstTarget)
            XCTAssertEqual(captureTargets, [firstTarget, nextTarget], "Reconnect must select the new capture target before acknowledging")
            XCTAssertEqual(reply.display, portrait)
            weak var nextMonitor = environment.lastDisplay
            _ = try await manager.handle(request(.displayRelease, id: nextID), connection: connection, name: "iPad")
            XCTAssertNil(nextMonitor)
        }
    }
    func testPhysicalDisplayChangesRequireSeparateOptIn() async throws {
        let environment = FakeDisplayEnvironment()
        let driver = NativeStreamingDisplayDriver(environment: environment.environment)
        let initial = try await driver.start()
        let target = try await driver.apply(portrait, disablePhysicalDisplays: true)
        XCTAssertEqual(environment.exclusions, [initial])
        XCTAssertEqual(environment.layout.primaryChanges, [target]); XCTAssertTrue(environment.layout.disabled)
        try driver.restore(); XCTAssertEqual(environment.layout.restorations, 1)
        XCTAssertNil(environment.lastDisplay)
        try driver.stop()
    }
    func testPhysicalRecoveryMustSucceedBeforeRemovingVirtualMonitor() async throws {
        let environment = FakeDisplayEnvironment()
        let driver = NativeStreamingDisplayDriver(environment: environment.environment)
        _ = try await driver.apply(portrait, disablePhysicalDisplays: true)
        weak var monitor = environment.lastDisplay
        environment.layout.failRestore = true
        XCTAssertThrowsError(try driver.restore())
        XCTAssertNotNil(monitor, "Keep a framebuffer until the physical screens are restored")
        environment.layout.failRestore = false
        try driver.restore()
        XCTAssertNil(monitor)
    }
    func testPhysicalSelectionAndExplicitHeadlessPreferenceSurviveMigration() throws {
        let suite = "Nocturne-display-preferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(DisplaySettings(defaults: defaults).headlessEnabled)
        XCTAssertFalse(DisplaySettings(defaults: defaults).disablePhysicalDisplays)
        defaults.set("1", forKey: "streamDisplay")
        XCTAssertFalse(DisplaySettings(defaults: defaults).headlessEnabled)
        defaults.set(true, forKey: "headlessDisplayEnabled")
        XCTAssertTrue(DisplaySettings(defaults: defaults).headlessEnabled)
        XCTAssertEqual(DisplaySettings(defaults: defaults).physicalDisplay, "1")
        defaults.set(false, forKey: "headlessDisplayEnabled")
        defaults.set("", forKey: "streamDisplay")
        XCTAssertFalse(DisplaySettings(defaults: defaults).headlessEnabled)
    }
    func testDisplayAcknowledgementWaitsForExactCaptureTargetReadiness() async throws {
        let driver = RecordingDisplayDriver(), connection = UUID(), id = UUID().uuidString
        var targets: [UInt32] = []
        var finish: CheckedContinuation<Void, Error>?
        let preparing = expectation(description: "Preparing capture")
        let manager = DisplaySessionManager(driver: driver, timeout: 20) { target in
            targets.append(target); preparing.fulfill()
            try await withCheckedThrowingContinuation { finish = $0 }
        }
        let pending = Task { try await manager.handle(request(id: id, size: portrait), connection: connection, name: "iPhone") }
        await fulfillment(of: [preparing], timeout: 2)
        XCTAssertEqual(targets, [driver.displayID]); XCTAssertNil(manager.size)
        // Initial capture preparation may take longer than an ordinary heartbeat.
        manager.expire(now: Date().addingTimeInterval(21)); XCTAssertTrue(manager.isActive)
        finish?.resume()
        let reply = try await pending.value
        XCTAssertEqual(reply.display, portrait); XCTAssertEqual(manager.size, portrait)
        manager.expire(now: Date().addingTimeInterval(21)); XCTAssertFalse(manager.isActive)
    }
    func testDisconnectDuringCapturePreparationCannotAcknowledgeStaleDisplay() async throws {
        let driver = RecordingDisplayDriver(), connection = UUID(), id = UUID().uuidString
        var finish: CheckedContinuation<Void, Error>?
        let preparing = expectation(description: "Preparing capture")
        let manager = DisplaySessionManager(driver: driver, timeout: 20) { _ in
            preparing.fulfill(); try await withCheckedThrowingContinuation { finish = $0 }
        }
        let pending = Task { try await manager.handle(request(id: id, size: portrait), connection: connection, name: "iPhone") }
        await fulfillment(of: [preparing], timeout: 2)
        manager.disconnected(connection); finish?.resume()
        await assertFailure { try await pending.value }
        XCTAssertFalse(manager.isActive); XCTAssertNil(manager.size); XCTAssertEqual(driver.restorations, 1)
    }
    func testFailedCaptureSelectionReleasesLease() async throws {
        let driver = RecordingDisplayDriver()
        let manager = DisplaySessionManager(driver: driver, timeout: 20) { _ in throw NocturneError.timeout }
        await assertFailure { try await manager.handle(request(id: UUID().uuidString, size: portrait), connection: UUID(), name: "iPhone") }
        XCTAssertFalse(manager.isActive); XCTAssertNil(manager.size); XCTAssertEqual(driver.restorations, 1)
    }
    func testPreparationDeadlineCannotBeExtendedByHeartbeats() async throws {
        let driver = RecordingDisplayDriver(), connection = UUID(), id = UUID().uuidString, start = Date()
        var finish: CheckedContinuation<Void, Error>?
        let preparing = expectation(description: "Preparing capture")
        let manager = DisplaySessionManager(driver: driver, timeout: 20) { _ in
            preparing.fulfill(); try await withCheckedThrowingContinuation { finish = $0 }
        }
        let pending = Task { try await manager.handle(request(id: id, size: portrait), connection: connection, name: "iPhone", now: start) }
        await fulfillment(of: [preparing], timeout: 2)
        _ = try await manager.handle(request(.displayHeartbeat, id: id), connection: connection, name: "iPhone", now: start.addingTimeInterval(40))
        manager.expire(now: start.addingTimeInterval(51))
        XCTAssertFalse(manager.isActive); XCTAssertEqual(driver.restorations, 1)
        finish?.resume()
        await assertFailure { try await pending.value }
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
    func testNativeDisconnectRemovesDisplayAndReconnectCreatesFreshTarget() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_DISPLAYS"] == "1" else { throw XCTSkip("Opt in to real WindowServer display changes") }
        guard NDDisplayLayout.isSessionAvailable() else { throw XCTSkip("Unlock the Mac before running native display tests") }
        _ = NSApplication.shared
        var ids = [CGDirectDisplayID](repeating: 0, count: 64), count: UInt32 = 0
        XCTAssertEqual(CGGetActiveDisplayList(64, &ids, &count), .success)
        let original = Array(ids.prefix(Int(count))), main = CGMainDisplayID()
        let bounds = original.map { CGDisplayBounds($0) }
        let mirrors = original.map { CGDisplayMirrorsDisplay($0) }
        func onlineDisplays() -> [CGDirectDisplayID] {
            var online = [CGDirectDisplayID](repeating: 0, count: 64), count: UInt32 = 0
            XCTAssertEqual(CGGetOnlineDisplayList(64, &online, &count), .success)
            return Array(online.prefix(Int(count)))
        }
        let events = Task { @MainActor in
            while !Task.isCancelled {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.03), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { events.cancel() }
        var target: UInt32 = 0
        let manager = DisplaySessionManager(driver: NativeStreamingDisplayDriver(), timeout: 20) { target = $0 }
        defer { manager.stop() }
        var previous: UInt32 = 0
        for reason in ["release", "socket", "heartbeat"] {
            let connection = UUID(), id = UUID().uuidString
            do {
                _ = try await manager.handle(request(id: id, size: .init(width: 1920, height: 1080, frameRate: 60)), connection: connection, name: "Display verification")
            } catch {
                XCTFail("Native display preparation failed before \(reason): \(error)")
                return
            }
            XCTAssertNotEqual(target, 0); XCTAssertNotEqual(target, previous)
            XCTAssertTrue(onlineDisplays().contains(target))
            previous = target
            switch reason {
            case "release":
                _ = try await manager.handle(request(.displayRelease, id: id), connection: connection, name: "Display verification")
            case "socket": manager.disconnected(connection)
            default: manager.expire(now: Date().addingTimeInterval(21))
            }
            for _ in 0..<60 {
                if !onlineDisplays().contains(target) { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertFalse(onlineDisplays().contains(target), "WindowServer must remove the virtual monitor after \(reason)")
            XCTAssertEqual(CGMainDisplayID(), main)
            XCTAssertEqual(original.map { CGDisplayBounds($0) }, bounds)
            XCTAssertEqual(original.map { CGDisplayMirrorsDisplay($0) }, mirrors)
            for display in original { XCTAssertNotEqual(CGDisplayIsActive(display), 0) }
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
        guard NDDisplayLayout.isSessionAvailable(), !NDDisplayLayout.isScreenLocked() else { throw XCTSkip("Unlock the Mac before switching physical displays") }
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
        guard NDDisplayLayout.isSessionAvailable(), !NDDisplayLayout.isScreenLocked() else { throw XCTSkip("Unlock the Mac before switching physical displays") }
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
