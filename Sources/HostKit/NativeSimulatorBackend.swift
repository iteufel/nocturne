import Foundation
import NocturneKit
import SimulatorBridge

/// One serial worker owns every native connection. XPC waits never block the UI
/// or a Swift concurrency executor. No shared input connection is borrowed.
public final class NativeSimulatorBackend: SimulatorBackend, @unchecked Sendable {
    public let supportsInput = true
    private struct Control {
        let device: String
        let bridge: NCSimulatorBridge
        var edge = 0
    }
    private let queue = DispatchQueue(label: "app.nocturne.simulator.native", qos: .userInitiated)
    private var controls: [String: Control] = [:]
    private let discovery = SimctlSimulatorBackend()
    public init() {}
    public func devices() async throws -> [RemoteSimulator] { try await discovery.devices() }
    public func open(device: String, session: String) async throws {
        let result = try await DeveloperCommand.run("/usr/bin/xcode-select", ["-p"], FileManager.default.temporaryDirectory, nil)
        guard result.code == 0, !result.truncated else { throw NocturneError.remote("Select a full Xcode installation on your Mac.") }
        let directory = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        try await perform {
            guard self.controls[session] == nil else { throw NocturneError.invalidFrame }
            let bridge = try NCSimulatorBridge(device: device, developerDirectory: directory)
            do { _ = try Self.geometry(bridge) }
            catch { bridge.close(); throw error }
            self.controls[session] = Control(device: device, bridge: bridge)
        }
    }
    public func frame(device: String, session: String) async throws -> SimulatorFrame {
        try await perform {
            let control = try self.control(device: device, session: session)
            let before = try Self.geometry(control.bridge)
            let data = try control.bridge.framebufferPNG(forDisplay: before.id, rotation: UInt(before.rotation))
            let after = try Self.geometry(control.bridge)
            guard before == after else { control.bridge.cancelTouch(); throw Self.displayChanged }
            let image = try SimctlSimulatorBackend.encodeFrame(data)
            let frame = SimulatorFrame(pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight, jpeg: image.jpeg, geometry: before)
            guard frame.isValid else { control.bridge.cancelTouch(); throw Self.displayChanged }
            return frame
        }
    }
    public func input(_ touch: SimulatorTouch, device: String, session: String, geometry: SimulatorDisplayGeometry) async throws {
        try await perform {
            var control = try self.control(device: device, session: session)
            if touch.phase == .cancel { control.bridge.cancelTouch(); return }
            guard try Self.geometry(control.bridge) == geometry, let point = geometry.nativePoint(x: touch.x, y: touch.y) else {
                control.bridge.cancelTouch(); throw Self.displayChanged
            }
            if touch.phase == .down { control.edge = geometry.nativeEdge(x: touch.x, y: touch.y) }
            let phase: UInt = touch.phase == .down ? 0 : (touch.phase == .move ? 1 : 2)
            try control.bridge.sendTouchPhase(phase, x: point.x, y: point.y, target: UInt(geometry.target), edge: UInt(control.edge))
            self.controls[session] = control
        }
    }
    public func cancelInput(session: String) async {
        _ = try? await perform { self.controls[session]?.bridge.cancelTouch() }
    }
    public func close(session: String) async {
        _ = try? await perform { self.controls.removeValue(forKey: session)?.bridge.close() }
    }
    private func control(device: String, session: String) throws -> Control {
        guard let control = controls[session], control.device == device else { throw NocturneError.disconnected }
        return control
    }
    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { completion in
            queue.async { completion.resume(with: Result(catching: operation)) }
        }
    }
    private static func geometry(_ bridge: NCSimulatorBridge) throws -> SimulatorDisplayGeometry {
        try geometry(displays: bridge.displayInfo(), touchscreens: bridge.touchscreens())
    }
    static let displayChanged = NocturneError.remote("The simulator display changed. Wait for its next frame before touching it.")
    /// Decode actual display and HID identities together; no device-name tables,
    /// default-display alias or window geometry can substitute for these records.
    static func geometry(displays: [AnyHashable: Any], touchscreens: [AnyHashable: Any]) throws -> SimulatorDisplayGeometry {
        guard displays["current"] as? Bool == true,
              let records = displays["displays"] as? [[String: Any]], records.count <= 32,
              let services = touchscreens["connectedServices"] as? [[String: Any]], services.count <= 256 else { throw NocturneError.invalidFrame }
        let integrated = records.filter { ($0["type"] as? [String: Any])?["integrated"] != nil }
        // Older runtimes without activity metadata are usable only when they have
        // exactly one integrated display, and still provide its explicit identity.
        let legacy = integrated.allSatisfy { $0["active"] == nil && ($0["backlightState"] == nil || $0["backlightState"] as? String == "unknown") }
        let active = legacy ? integrated : integrated.filter { $0["active"] as? Bool == true || ($0["active"] == nil && ["activeOn", "activeDimmed"].contains($0["backlightState"] as? String ?? "")) }
        let transitioning = integrated.contains { $0["active"] as? Bool == false && ["activeOn", "activeDimmed"].contains($0["backlightState"] as? String ?? "") }
        guard !transitioning, active.count == 1, let record = active.first,
              let id = record["uniqueId"] as? String, UUID(uuidString: id) != nil,
              let bounds = record["bounds"] as? [[Double]], bounds.count == 2, bounds.allSatisfy({ $0.count == 2 }),
              bounds.flatMap({ $0 }).allSatisfy(\.isFinite),
              let scale = record["pointScale"] as? Double,
              let orientation = record["currentOrientation"] as? String,
              let rotation = ["rot0", "rot90", "rot180", "rot270"].firstIndex(of: orientation),
              let width = Int(exactly: bounds[1][0]), let height = Int(exactly: bounds[1][1]) else { throw displayChanged }
        let matches = services.filter { ($0["PrimaryUsagePage"] as? Int) == 13 && ($0["PrimaryUsage"] as? Int) == 4 && ($0["displayUUID"] as? String) == id }
        guard matches.count == 1, let service = matches.first?["_ServiceID"] as? Int,
              (0x101...0x1ff).contains(service),
              services.filter({ ($0["_ServiceID"] as? Int) == service }).count == 1 else { throw displayChanged }
        let geometry = SimulatorDisplayGeometry(id: id, width: width, height: height, scale: scale, rotation: rotation, target: service & 0xff)
        guard geometry.isValid else { throw NocturneError.invalidFrame }
        return geometry
    }
}
