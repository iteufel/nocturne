import XCTest
import SimulatorBridge
import ImageIO
import NocturneKit
@testable import NocturneHostKit

final class SimulatorNativeTests: XCTestCase {
    func testInstalledSimulatorTouchPhasesAndDisconnectRelease() async throws {
        guard let device = ProcessInfo.processInfo.environment["NOCTURNE_SIMULATOR_TEST_DEVICE"],
              ProcessInfo.processInfo.environment["NOCTURNE_SIMULATOR_TOUCH_FIXTURE"] == "1" else {
            throw XCTSkip("Open the dedicated Nocturne Touch Fixture on an owned simulator before opting in.")
        }
        let manager = SimulatorSessionManager(backend: NativeSimulatorBackend()), owner = UUID()
        var open = Packet(.simulatorOpen); open.simulatorID = device
        let opened = try await manager.handle(open, connection: owner)
        let session = try XCTUnwrap(opened.sessionID)
        func frame(_ session: String) async throws -> SimulatorFrame {
            var request = Packet(.simulatorFrame); request.sessionID = session
            let reply = try await manager.handle(request, connection: owner)
            return try XCTUnwrap(reply.simulatorFrame)
        }
        func send(_ phase: SimulatorTouch.Phase, _ sequence: Int, _ gesture: String, _ revision: String) async throws {
            var request = Packet(.simulatorInput); request.sessionID = session
            request.simulatorTouch = .init(gestureID: gesture, frameRevision: revision, sequence: sequence, phase: phase, x: sequence == 0 ? 0.25 : 0.6, y: 0.7)
            _ = try await manager.handle(request, connection: owner)
            try await Task.sleep(nanoseconds: 550_000_000)
        }
        do {
            let initial = try await frame(session), gesture = UUID().uuidString
            if ProcessInfo.processInfo.environment["NOCTURNE_SIMULATOR_EXPECT_LANDSCAPE"] == "1" {
                XCTAssertGreaterThan(initial.pixelWidth, initial.pixelHeight)
                XCTAssertTrue([1, 3].contains(initial.geometry?.rotation ?? -1))
            }
            let red = try color(initial)
            // Fail before sending anything if the dedicated fixture is not ready.
            guard red.0 > 0.8, red.1 < 0.2, red.2 < 0.2 else {
                throw NocturneError.remote("Relaunch the dedicated simulator touch fixture before this test.")
            }
            try await send(.down, 0, gesture, initial.revision)
            let downFrame = try await frame(session), green = try color(downFrame)
            XCTAssertLessThan(green.0, 0.2); XCTAssertGreaterThan(green.1, 0.8); XCTAssertLessThan(green.2, 0.2)
            try assertMarker(downFrame, x: 0.25, y: 0.7)
            try await send(.move, 1, gesture, initial.revision)
            let moveFrame = try await frame(session), blue = try color(moveFrame)
            XCTAssertLessThan(blue.0, 0.2); XCTAssertLessThan(blue.1, 0.2); XCTAssertGreaterThan(blue.2, 0.8)
            try assertMarker(moveFrame, x: 0.6, y: 0.7)
            try await send(.up, 2, gesture, initial.revision)
            let ended = try await frame(session), yellow = try color(ended)
            XCTAssertGreaterThan(yellow.0, 0.8); XCTAssertGreaterThan(yellow.1, 0.8); XCTAssertLessThan(yellow.2, 0.2)
            try await send(.down, 0, UUID().uuidString, ended.revision)
            let held = try color(try await frame(session)); XCTAssertGreaterThan(held.1, 0.8); XCTAssertLessThan(held.0, 0.2)
            await manager.disconnected(owner)
            let reopened = try await manager.handle(open, connection: owner)
            let released = try color(try await frame(try XCTUnwrap(reopened.sessionID)))
            XCTAssertGreaterThan(released.0, 0.8); XCTAssertGreaterThan(released.1, 0.8); XCTAssertLessThan(released.2, 0.2)
            await manager.stop()
        } catch { await manager.stop(); throw error }
    }
    private func assertMarker(_ frame: SimulatorFrame, x: Double, y: Double) throws {
        let white = try color(frame, x: x, y: y)
        XCTAssertGreaterThan(white.0, 0.8); XCTAssertGreaterThan(white.1, 0.8); XCTAssertGreaterThan(white.2, 0.8)
    }
    private func color(_ frame: SimulatorFrame, x: Double = 0.5, y: Double = 0.75) throws -> (Double, Double, Double) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: Double(image.width) * x, y: Double(image.height) * y, width: 2, height: 2)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }
    func testInstalledSimulatorDisplayMetadata() async throws {
        guard let device = ProcessInfo.processInfo.environment["NOCTURNE_SIMULATOR_TEST_DEVICE"] else {
            throw XCTSkip("Set NOCTURNE_SIMULATOR_TEST_DEVICE to an owned, already booted simulator.")
        }
        let selected = try await DeveloperCommand.run("/usr/bin/xcode-select", ["-p"], FileManager.default.temporaryDirectory, nil)
        let bridge = try NCSimulatorBridge(device: device, developerDirectory: selected.text.trimmingCharacters(in: .whitespacesAndNewlines))
        defer { bridge.close() }
        let display = try bridge.displayInfo()
        let touchscreens = try bridge.touchscreens()
        let geometry = try NativeSimulatorBackend.geometry(displays: display, touchscreens: touchscreens)
        let png = try bridge.framebufferPNG(forDisplay: geometry.id, rotation: UInt(geometry.rotation))
        let image = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, geometry.displayWidth)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, geometry.displayHeight)
    }
}
