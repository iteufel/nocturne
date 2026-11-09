import XCTest
import NocturneKit
@testable import NocturneHostKit

final class SimulatorInputTests: XCTestCase {
    private let device = "F523F299-606A-4E4D-B6AF-BC5D18D20A2D"
    private func packet(_ operation: NocturneKit.Operation, session: String? = nil, touch: SimulatorTouch? = nil) -> Packet {
        var value = Packet(operation); value.sessionID = session; value.simulatorID = device; value.simulatorTouch = touch; return value
    }
    private func touch(_ phase: SimulatorTouch.Phase, sequence: Int, id: String, revision: String) -> SimulatorTouch {
        .init(gestureID: id, frameRevision: revision, sequence: sequence, phase: phase, x: 0.25, y: 0.75)
    }
    private func prepared(_ backend: TouchFixture, clock: TouchClock = TouchClock()) async throws -> (SimulatorSessionManager, UUID, String, String) {
        let manager = SimulatorSessionManager(backend: backend, now: { clock.date }), owner = UUID()
        let opened = try await manager.handle(packet(.simulatorOpen), connection: owner)
        let session = try XCTUnwrap(opened.sessionID)
        let frame = try await manager.handle(packet(.simulatorFrame, session: session), connection: owner)
        return (manager, owner, session, try XCTUnwrap(frame.simulatorFrame?.revision))
    }
    @MainActor
    func testAuthenticatedServerRevokesSimulatorControlAndClosesItsLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceDeviceStore(url: root.appendingPathComponent("devices.json"))
        let backend = TouchFixture(), manager = SimulatorSessionManager(backend: backend)
        let server = try WorkspaceServer(folder: root.appendingPathComponent("shared"), name: "Simulator Mac", devices: store, simulators: manager)
        defer { server.stop() }
        let ready = expectation(description: "Simulator listener ready"); var signalled = false
        server.onStatus = { status, _ in if status == "Ready", !signalled { signalled = true; ready.fulfill() } }
        let secret = try SecureStore.randomKey(), identity = try TestDeviceIdentity()
        try server.start(secret: secret, port: 0); await fulfillment(of: [ready], timeout: 5)
        let invitation = try PairingInvitation(host: "127.0.0.1", port: XCTUnwrap(server.listeningPort), name: "Simulator Mac", secret: secret, enrollmentToken: store.createInvitation())
        let client = WorkspaceConnection(identity: identity.identity()), other = WorkspaceConnection(identity: identity.identity())
        defer { client.disconnect(); other.disconnect() }
        try await client.connect(invitation); try await other.connect(invitation)
        XCTAssertTrue(client.capabilities.contains(SimulatorStreaming.inputCapability))
        let opened = try await client.request(packet(.simulatorOpen)), session = try XCTUnwrap(opened.sessionID)
        let frame = try await client.request(packet(.simulatorFrame, session: session))
        let down = packet(.simulatorInput, session: session, touch: touch(.down, sequence: 0, id: UUID().uuidString, revision: try XCTUnwrap(frame.simulatorFrame?.revision)))
        do { _ = try await other.request(down); XCTFail("A second socket reused another connection's control lease") } catch {}
        _ = try await client.request(down)
        try store.remove(identity.id); server.disconnectDevice(identity.id); try store.finishRemoval(identity.id)
        for _ in 0..<500 {
            if await backend.closed.contains(session) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let closed = await backend.closed; XCTAssertTrue(closed.contains(session))
        do { _ = try await client.request(down); XCTFail("Revoked simulator input was accepted") } catch {}
        let received = await backend.received; XCTAssertEqual(received.map(\.phase), [.down])
    }
    func testTouchSequenceIsDeliveredAndForeignSocketCannotInject() async throws {
        let backend = TouchFixture(), (manager, owner, session, revision) = try await prepared(backend), id = UUID().uuidString
        let down = packet(.simulatorInput, session: session, touch: touch(.down, sequence: 0, id: id, revision: revision))
        do { _ = try await manager.handle(down, connection: UUID()); XCTFail("Foreign input accepted") }
        catch { XCTAssertEqual(error as? NocturneError, .permissionDenied) }
        _ = try await manager.handle(down, connection: owner)
        _ = try await manager.handle(packet(.simulatorInput, session: session, touch: touch(.move, sequence: 1, id: id, revision: revision)), connection: owner)
        _ = try await manager.handle(packet(.simulatorInput, session: session, touch: touch(.up, sequence: 2, id: id, revision: revision)), connection: owner)
        let received = await backend.received
        XCTAssertEqual(received.map(\.phase), [.down, .move, .up])
        await manager.disconnected(owner)
        let closed = await backend.closed; XCTAssertEqual(closed, [session])
    }
    func testStaleOrUnseenFramesCannotStartTouch() async throws {
        let backend = TouchFixture(), clock = TouchClock(), (manager, owner, session, revision) = try await prepared(backend, clock: clock)
        for frame in ["unseen", revision] {
            if frame == revision { clock.advance(3) }
            do { _ = try await manager.handle(packet(.simulatorInput, session: session, touch: touch(.down, sequence: 0, id: UUID().uuidString, revision: frame)), connection: owner); XCTFail("Stale frame accepted") } catch {}
        }
        let received = await backend.received; XCTAssertTrue(received.isEmpty)
    }
    func testReplayAndOutOfOrderEventsReleaseContact() async throws {
        let backend = TouchFixture(), (manager, owner, session, revision) = try await prepared(backend), id = UUID().uuidString
        _ = try await manager.handle(packet(.simulatorInput, session: session, touch: touch(.down, sequence: 0, id: id, revision: revision)), connection: owner)
        do { _ = try await manager.handle(packet(.simulatorInput, session: session, touch: touch(.move, sequence: 2, id: id, revision: revision)), connection: owner); XCTFail("Skipped sequence accepted") } catch {}
        let cancelled = await backend.cancelled; XCTAssertEqual(cancelled, [session])
        do { _ = try await manager.handle(packet(.simulatorInput, session: session, touch: touch(.up, sequence: 1, id: id, revision: revision)), connection: owner); XCTFail("Released gesture restored") } catch {}
        let received = await backend.received; XCTAssertEqual(received.count, 1)
    }
    func testDisplayChangeReleasesTouchAndRejectsOldFrame() async throws {
        let backend = TouchFixture(), clock = TouchClock(), (manager, owner, session, revision) = try await prepared(backend, clock: clock), id = UUID().uuidString
        _ = try await manager.handle(packet(.simulatorInput, session: session, touch: touch(.down, sequence: 0, id: id, revision: revision)), connection: owner)
        await backend.rotate(); clock.advance(0.5)
        let newFrame = try await manager.handle(packet(.simulatorFrame, session: session), connection: owner)
        XCTAssertEqual(newFrame.simulatorFrame?.geometry?.rotation, 1)
        let cancelled = await backend.cancelled; XCTAssertEqual(cancelled, [session])
        do { _ = try await manager.handle(packet(.simulatorInput, session: session, touch: touch(.down, sequence: 0, id: UUID().uuidString, revision: revision)), connection: owner); XCTFail("Old display accepted") } catch {}
    }
    func testAbandonedTouchExpiresWhilePreviewLeaseSurvives() async throws {
        let backend = TouchFixture(), clock = TouchClock(), (manager, owner, session, revision) = try await prepared(backend, clock: clock)
        _ = try await manager.handle(packet(.simulatorInput, session: session, touch: touch(.down, sequence: 0, id: UUID().uuidString, revision: revision)), connection: owner)
        clock.advance(2.1); await manager.expire()
        let cancelled = await backend.cancelled; XCTAssertEqual(cancelled, [session])
        _ = try await manager.handle(packet(.simulatorFrame, session: session), connection: owner)
        let closed = await backend.closed; XCTAssertTrue(closed.isEmpty)
    }
    func testOnlyOneConnectionCanControlTheSameSimulator() async throws {
        let backend = TouchFixture(), (manager, owner, session, _) = try await prepared(backend)
        do { _ = try await manager.handle(packet(.simulatorOpen), connection: UUID()); XCTFail("Shared input ownership") } catch {}
        _ = try await manager.handle(packet(.simulatorClose, session: session), connection: owner)
        _ = try await manager.handle(packet(.simulatorOpen), connection: UUID())
        await manager.stop()
    }
    func testDisconnectDuringOpeningClosesLateNativeConnection() async throws {
        let backend = TouchFixture(delayOpen: true), manager = SimulatorSessionManager(backend: backend), owner = UUID()
        let opening = Task { try await manager.handle(packet(.simulatorOpen), connection: owner) }
        for _ in 0..<100 {
            if await backend.opened.count == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await manager.disconnected(owner)
        do { _ = try await opening.value; XCTFail("Late input connection survived") } catch {}
        let closed = await backend.closed, opened = await backend.opened
        XCTAssertFalse(opened.isEmpty); XCTAssertTrue(Set(opened).isSubset(of: Set(closed)))
    }
    func testNativeCoordinatesAndSystemGestureEdgesMatchEveryRotation() throws {
        for (rotation, x, y) in [(0, 0.2, 0.7), (1, 0.7, 0.8), (2, 0.8, 0.3), (3, 0.3, 0.2)] {
            let geometry = TouchFixture.geometry(rotation: rotation)
            let point = try XCTUnwrap(geometry.nativePoint(x: 0.2, y: 0.7))
            XCTAssertEqual(point.x, x, accuracy: 0.0001); XCTAssertEqual(point.y, y, accuracy: 0.0001)
            XCTAssertNil(geometry.nativePoint(x: .nan, y: 0)); XCTAssertNil(geometry.nativePoint(x: 1.1, y: 0))
            XCTAssertEqual(geometry.nativeEdge(x: 0.5, y: 0.99), [3, 4, 1, 2][rotation])
        }
    }
    func testGeometryUsesActiveDisplayAndMatchingDigitizerOnly() throws {
        let first = UUID().uuidString, second = UUID().uuidString
        func record(_ id: String, active: Bool, rotation: String = "rot90") -> [String: Any] {
            ["uniqueId":id, "active":active, "backlightState":active ? "activeOn" : "off", "type":["integrated":[:]], "bounds":[[0.0, 0.0], [1170.0, 2532.0]], "pointScale":3.0, "currentOrientation":rotation]
        }
        func service(_ id: String, target: Int) -> [String: Any] { ["PrimaryUsagePage":13, "PrimaryUsage":4, "displayUUID":id, "_ServiceID":0x100 + target] }
        let records = [record(first, active: false), record(second, active: true)]
        let services = [service(first, target: 1), service(second, target: 3)]
        let geometry = try NativeSimulatorBackend.geometry(displays: ["current":true, "displays":records], touchscreens: ["connectedServices":services])
        XCTAssertEqual(geometry.id, second); XCTAssertEqual(geometry.target, 3); XCTAssertEqual(geometry.rotation, 1)
        XCTAssertThrowsError(try NativeSimulatorBackend.geometry(displays: ["current":true, "displays":[record(first, active: true), record(second, active: true)]], touchscreens: ["connectedServices":services]))
        XCTAssertThrowsError(try NativeSimulatorBackend.geometry(displays: ["current":true, "displays":records], touchscreens: ["connectedServices":[service(first, target: 1)]]))
        XCTAssertThrowsError(try NativeSimulatorBackend.geometry(displays: ["current":true, "displays":records], touchscreens: ["connectedServices":services + [service(second, target: 4)]]))
        XCTAssertThrowsError(try NativeSimulatorBackend.geometry(displays: ["current":false, "displays":records], touchscreens: ["connectedServices":services]))
    }
}

private actor TouchFixture: SimulatorBackend {
    nonisolated let supportsInput = true
    let delayOpen: Bool
    var rotation = 0
    var received: [SimulatorTouch] = [], cancelled: [String] = [], closed: [String] = [], opened: [String] = []
    init(delayOpen: Bool = false) { self.delayOpen = delayOpen }
    func devices() async throws -> [RemoteSimulator] { [.init(id: "F523F299-606A-4E4D-B6AF-BC5D18D20A2D", name: "Phone", runtime: "iOS", state: "Booted")] }
    func open(device: String, session: String) async throws {
        opened.append(session)
        if delayOpen { try await Task.sleep(nanoseconds: 60_000_000_000) }
    }
    func frame(device: String, session: String) async throws -> SimulatorFrame {
        let geometry = Self.geometry(rotation: rotation)
        return .init(pixelWidth: geometry.displayWidth, pixelHeight: geometry.displayHeight, jpeg: Data([1]), geometry: geometry)
    }
    func input(_ touch: SimulatorTouch, device: String, session: String, geometry: SimulatorDisplayGeometry) async throws { received.append(touch) }
    func cancelInput(session: String) async { cancelled.append(session) }
    func close(session: String) async { closed.append(session) }
    func rotate() { rotation = 1 }
    nonisolated static func geometry(rotation: Int) -> SimulatorDisplayGeometry {
        .init(id: "FAA2D3C2-2384-4533-92CF-580691758F28", width: 1170, height: 2532, scale: 3, rotation: rotation, target: 1)
    }
}
private final class TouchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}
