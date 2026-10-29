import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NocturneKit
@testable import NocturneHostKit

final class SimulatorTests: XCTestCase {
    private let device = "F523F299-606A-4E4D-B6AF-BC5D18D20A2D"
    private func booted() -> RemoteSimulator { .init(id: device, name: "Fixture phone", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0", state: "Booted") }
    private func opening(_ device: String) -> Packet { var packet = Packet(.simulatorOpen); packet.simulatorID = device; return packet }
    private func request(_ operation: NocturneKit.Operation, _ lease: String?) -> Packet { var packet = Packet(operation); packet.sessionID = lease; return packet }

    func testSimulatorPreviewRequiresExplicitSavedOptIn() throws {
        let suite = "nocturne.simulator-fixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "allowScreenSharing")
        var settings = ServerSettings(defaults: defaults)
        XCTAssertFalse(settings.simulators); XCTAssertFalse(settings.hasEnabledServices)
        settings.simulators = true
        XCTAssertTrue(settings.hasEnabledServices)
        XCTAssertFalse(ServerSettings(defaults: defaults).simulators)
        settings.save(defaults: defaults)
        XCTAssertTrue(ServerSettings(defaults: defaults).simulators)
        XCTAssertFalse(ServerSettings(defaults: defaults).screenSharing)
    }
    func testDeviceListingFiltersUnavailableAndNonIOSWithoutInventingSizes() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
            {"udid":"\(device)","name":"Phone","state":"Booted","isAvailable":true},
            {"udid":"not-a-uuid","name":"Bad","state":"Booted","isAvailable":true},
            {"udid":"\(UUID().uuidString)","name":"Missing runtime","state":"Shutdown","isAvailable":false}],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
            {"udid":"\(UUID().uuidString)","name":"Watch","state":"Booted","isAvailable":true}]}}
        """
        let list = try SimctlSimulatorBackend.decodeDevices(Data(json.utf8))
        XCTAssertEqual(list.map(\.id), [device]); XCTAssertTrue(list[0].isBooted)
        XCTAssertThrowsError(try SimctlSimulatorBackend.decodeDevices(Data("{}".utf8)))
    }
    func testFrameCodecRoundTripAndPacketBudget() throws {
        var packet = Packet(.simulatorFrame)
        packet.simulatorFrame = .init(pixelWidth: 1170, pixelHeight: 2532, jpeg: Data(repeating: 1, count: SimulatorStreaming.maximumImageBytes))
        let encoded = try FrameCodec.encode(packet)
        XCTAssertLessThan(encoded.count, WorkspaceProtocol.maximumFrame)
        let decoded = try JSONDecoder().decode(Packet.self, from: encoded.dropFirst(4))
        XCTAssertEqual(decoded.simulatorFrame?.pixelWidth, 1170)
        XCTAssertTrue(try XCTUnwrap(decoded.simulatorFrame).isValid)
        XCTAssertFalse(SimulatorFrame(pixelWidth: 0, pixelHeight: 1, jpeg: Data([1])).isValid)
        XCTAssertFalse(SimulatorFrame(pixelWidth: 1, pixelHeight: 1, jpeg: Data()).isValid)
        XCTAssertFalse(SimulatorFrame(pixelWidth: 1, pixelHeight: 1, jpeg: Data(count: SimulatorStreaming.maximumImageBytes + 1)).isValid)
    }
    func testDirectFramebufferEncodingPreservesNativeSizeAndPortraitLandscape() throws {
        for (width, height) in [(1170, 2532), (2532, 1170), (400, 600)] {
            let frame = try SimctlSimulatorBackend.encodeFrame(Self.png(width: width, height: height))
            XCTAssertEqual(frame.pixelWidth, width); XCTAssertEqual(frame.pixelHeight, height)
            XCTAssertTrue(frame.isValid)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertLessThanOrEqual(max(image.width, image.height), 1280)
            XCTAssertEqual(Double(image.width) / Double(image.height), Double(width) / Double(height), accuracy: 0.002)
        }
        XCTAssertThrowsError(try SimctlSimulatorBackend.encodeFrame(Data([0, 1, 2])))
    }
    func testBackendUsesOnlyLiteralListAndSelectedScreenshotAndCleansFiles() async throws {
        let log = CommandLog(), json = try JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-18-0": [["udid":device, "name":"Fixture", "state":"Booted", "isAvailable":true]]]])
        let png = try Self.png(width: 400, height: 600)
        let backend = SimctlSimulatorBackend(run: { executable, args, directory, input in
            log.append(executable, args, directory)
            XCTAssertEqual(executable, "/usr/bin/xcrun"); XCTAssertNil(input)
            if args == ["simctl", "list", "devices", "available", "--json"] { return .init(data: json, error: "", code: 0, truncated: false) }
            XCTAssertEqual(Array(args.prefix(5)), ["simctl", "io", "F523F299-606A-4E4D-B6AF-BC5D18D20A2D", "screenshot", "--type=png"])
            try png.write(to: URL(fileURLWithPath: args[5]))
            return .init(data: Data(), error: "", code: 0, truncated: false)
        })
        _ = try await backend.devices(); _ = try await backend.frame(device: device)
        XCTAssertEqual(log.calls.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.calls[1].2.path))
        do { _ = try await backend.frame(device: "booted; erase all"); XCTFail("Unvalidated device accepted") } catch {}
        XCTAssertEqual(log.calls.count, 2)
    }
    func testBackendFailureDoesNotLeakCommandDiagnostics() async throws {
        let backend = SimctlSimulatorBackend(run: { _, _, _, _ in .init(data: Data(), error: "private-path secret", code: 1, truncated: false) })
        do { _ = try await backend.devices(); XCTFail() }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret")); XCTAssertTrue(error.localizedDescription.contains("Xcode")) }
    }
    func testLeaseOwnershipStopAndDisconnect() async throws {
        let manager = SimulatorSessionManager(backend: FixtureSimulator(devices: [booted()]))
        let owner = UUID(), other = UUID()
        let open = try await manager.handle(opening(device), connection: owner)
        XCTAssertNotNil(open.sessionID)
        do { _ = try await manager.handle(request(.simulatorFrame, open.sessionID), connection: other); XCTFail("Foreign frame access") } catch { XCTAssertEqual(error as? NocturneError, .permissionDenied) }
        do { _ = try await manager.handle(request(.simulatorClose, open.sessionID), connection: other); XCTFail("Foreign close") } catch { XCTAssertEqual(error as? NocturneError, .permissionDenied) }
        let frame = try await manager.handle(request(.simulatorFrame, open.sessionID), connection: owner)
        XCTAssertEqual(frame.simulatorID, device)
        await manager.disconnected(owner)
        do { _ = try await manager.handle(request(.simulatorFrame, open.sessionID), connection: owner); XCTFail("Disconnected lease survived") } catch {}
        let fresh = try await manager.handle(opening(device), connection: owner)
        _ = try await manager.handle(request(.simulatorClose, fresh.sessionID), connection: owner)
        _ = try await manager.handle(request(.simulatorClose, fresh.sessionID), connection: owner)
    }
    func testShutdownDeviceAndStaleOpenDoNotCreateLease() async throws {
        let backend = FixtureSimulator(devices: [.init(id: device, name: "Off", runtime: "iOS", state: "Shutdown")])
        let manager = SimulatorSessionManager(backend: backend)
        do { _ = try await manager.handle(opening(device), connection: UUID()); XCTFail("Booted shutdown simulator") } catch {}
        let captures = await backend.captures; XCTAssertEqual(captures, 0)
        do { _ = try await manager.handle(opening(device), connection: UUID(), isConnected: { false }); XCTFail("Disconnected open") } catch { XCTAssertEqual(error as? NocturneError, .disconnected) }
    }
    func testLeaseExpiryHostLimitAndStop() async throws {
        let clock = FixtureClock(), manager = SimulatorSessionManager(backend: FixtureSimulator(devices: [booted()]), now: { clock.date })
        let first = UUID(), second = UUID()
        let a = try await manager.handle(opening(device), connection: first)
        _ = try await manager.handle(opening(device), connection: second)
        do { _ = try await manager.handle(opening(device), connection: UUID()); XCTFail("Unlimited sessions") } catch {}
        clock.advance(21); await manager.expire()
        do { _ = try await manager.handle(request(.simulatorFrame, a.sessionID), connection: first); XCTFail("Expired lease") } catch {}
        let fresh = try await manager.handle(opening(device), connection: first)
        await manager.stop()
        do { _ = try await manager.handle(request(.simulatorFrame, fresh.sessionID), connection: first); XCTFail("Stopped lease") } catch {}
    }
    func testOneCaptureInFlightAndDisconnectCancelsIt() async throws {
        let backend = FixtureSimulator(devices: [booted()], delayed: true), owner = UUID()
        let manager = SimulatorSessionManager(backend: backend)
        let open = try await manager.handle(opening(device), connection: owner)
        let packet = request(.simulatorFrame, open.sessionID)
        let pending = Task { try await manager.handle(packet, connection: owner) }
        for _ in 0..<100 {
            if await backend.captures == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        do { _ = try await manager.handle(packet, connection: owner); XCTFail("Concurrent capture") } catch {}
        await manager.disconnected(owner)
        do { _ = try await pending.value; XCTFail("Capture survived disconnect") } catch {}
        let cancelled = await backend.cancelled; XCTAssertTrue(cancelled)
    }
    func testHostThrottlesFastFrameRequests() async throws {
        let clock = FixtureClock(), owner = UUID()
        let manager = SimulatorSessionManager(backend: FixtureSimulator(devices: [booted()]), now: { clock.date })
        let open = try await manager.handle(opening(device), connection: owner)
        _ = try await manager.handle(request(.simulatorFrame, open.sessionID), connection: owner)
        do { _ = try await manager.handle(request(.simulatorFrame, open.sessionID), connection: owner); XCTFail("Unthrottled frames") }
        catch { XCTAssertTrue(error.localizedDescription.contains("two frames")) }
        clock.advance(0.5)
        _ = try await manager.handle(request(.simulatorFrame, open.sessionID), connection: owner)
    }
    func testDisconnectCancelsDiscoveryAndAllowsNewOwner() async throws {
        let backend = FixtureSimulator(devices: [booted()], delayedDiscovery: true), owner = UUID()
        let manager = SimulatorSessionManager(backend: backend)
        let pending = Task { try await manager.handle(Packet(.simulatorList), connection: owner) }
        for _ in 0..<100 {
            if await backend.discoveries == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        do { _ = try await manager.handle(Packet(.simulatorList), connection: UUID()); XCTFail("Concurrent discovery") } catch {}
        await manager.disconnected(owner)
        do { _ = try await pending.value; XCTFail("Discovery survived disconnect") } catch {}
        let cancelled = await backend.cancelled; XCTAssertTrue(cancelled)
        _ = try await manager.handle(Packet(.simulatorList), connection: UUID())
    }
    func testInputFailsExplicitlyAndDoesNotAdvertiseTouchSupport() async throws {
        XCTAssertEqual(SimulatorStreaming.capability, "simulator-preview-v1")
        let manager = SimulatorSessionManager(backend: FixtureSimulator(devices: [booted()]))
        do { _ = try await manager.handle(Packet(.simulatorInput), connection: UUID()); XCTFail("Invented input support") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
    }
    func testRetinaAndLetterboxGeometryAndAllOrientations() throws {
        let portrait = SimulatorInputGeometry(width: 1170, height: 2532, scale: 3, rotation: .up)
        let center = try XCTUnwrap(portrait.point(x: 500, y: 500, viewWidth: 1000, viewHeight: 1000))
        XCTAssertEqual(center.x, 195, accuracy: 0.001); XCTAssertEqual(center.y, 422, accuracy: 0.001)
        XCTAssertNil(portrait.point(x: 0, y: 500, viewWidth: 1000, viewHeight: 1000))
        XCTAssertNil(portrait.point(x: .nan, y: 0, viewWidth: 1000, viewHeight: 1000))
        for (rotation, expectedX, expectedY) in [(SimulatorInputGeometry.Rotation.up, 97.5, 211.0), (.right, 97.5, 633), (.down, 292.5, 633), (.left, 292.5, 211)] {
            let geometry = SimulatorInputGeometry(width: 1170, height: 2532, scale: 3, rotation: rotation)
            let sideways = rotation == .left || rotation == .right
            let w = sideways ? 844.0 : 390.0, h = sideways ? 390.0 : 844.0
            let point = try XCTUnwrap(geometry.point(x: w / 4, y: h / 4, viewWidth: w, viewHeight: h))
            XCTAssertEqual(point.x, expectedX, accuracy: 0.001); XCTAssertEqual(point.y, expectedY, accuracy: 0.001)
        }
    }
    private static func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.25, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage()), output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

private actor FixtureSimulator: SimulatorBackend {
    let list: [RemoteSimulator]
    let delayed: Bool
    let delayedDiscovery: Bool
    private(set) var discoveries = 0
    private(set) var captures = 0
    private(set) var cancelled = false
    init(devices: [RemoteSimulator], delayed: Bool = false, delayedDiscovery: Bool = false) {
        list = devices; self.delayed = delayed; self.delayedDiscovery = delayedDiscovery
    }
    func devices() async throws -> [RemoteSimulator] {
        discoveries += 1
        if delayedDiscovery && discoveries == 1 {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { cancelled = true; throw error }
        }
        return list
    }
    func frame(device: String) async throws -> SimulatorFrame {
        captures += 1
        if delayed {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { cancelled = true; throw error }
        }
        return .init(pixelWidth: 1170, pixelHeight: 2532, jpeg: Data([1, 2, 3]))
    }
}
private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}
private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, [String], URL)] = []
    var calls: [(String, [String], URL)] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ executable: String, _ args: [String], _ directory: URL) { lock.lock(); values.append((executable, args, directory)); lock.unlock() }
}
