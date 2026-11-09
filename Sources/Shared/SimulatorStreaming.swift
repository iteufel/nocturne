import Foundation

/// Simulator display frames travel on the existing authenticated workspace channel.
public enum SimulatorStreaming {
    public static let capability = "simulator-preview-v1"
    public static let inputCapability = "simulator-touch-v1"
    public static let maximumImageBytes = 524_288
    public static let maximumDevices = 256
    public static let leaseDuration: TimeInterval = 20
}

public struct RemoteSimulator: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let runtime: String
    public let state: String
    public var isBooted: Bool { state == "Booted" }
    public init(id: String, name: String, runtime: String, state: String) {
        self.id = id; self.name = name; self.runtime = runtime; self.state = state
    }
}

/// Dimensions come from the simulator framebuffer, never a hard-coded device table.
/// The JPEG is already in the simulator's current display orientation. Do not rotate
/// coordinates based on the viewing iPhone/iPad's physical orientation.
public struct SimulatorFrame: Codable, Sendable {
    public let revision: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let jpeg: Data
    public let geometry: SimulatorDisplayGeometry?
    public init(revision: String = UUID().uuidString, pixelWidth: Int, pixelHeight: Int, jpeg: Data, geometry: SimulatorDisplayGeometry? = nil) {
        self.revision = revision; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.jpeg = jpeg; self.geometry = geometry
    }
    public var isValid: Bool {
        !revision.isEmpty && revision.utf8.count <= 64 && (1...8192).contains(pixelWidth) &&
        (1...8192).contains(pixelHeight) && !jpeg.isEmpty && jpeg.count <= SimulatorStreaming.maximumImageBytes &&
        (geometry == nil || (geometry!.isValid && geometry!.displayWidth == pixelWidth && geometry!.displayHeight == pixelHeight))
    }
}

/// Aspect-fit conversion to native points. Scale and rotation must come from
/// display metadata: a screenshot alone cannot establish either. The DTUHID
/// backend uses normalized panel coordinates through SimulatorDisplayGeometry.
public struct SimulatorInputGeometry: Equatable, Sendable {
    public enum Rotation: Int, Sendable { case up = 0, right = 1, down = 2, left = 3 }
    public let width: Double
    public let height: Double
    public let scale: Double
    public let rotation: Rotation
    public init(width: Double, height: Double, scale: Double, rotation: Rotation) {
        self.width = width; self.height = height; self.scale = scale; self.rotation = rotation
    }
    /// Map an aspect-fit view location to the backend's native portrait points.
    /// Letterboxes are rejected; touch samples are never clamped into the device.
    public func point(x: Double, y: Double, viewWidth: Double, viewHeight: Double) -> (x: Double, y: Double)? {
        guard [width, height, scale, x, y, viewWidth, viewHeight].allSatisfy(\.isFinite),
              (1...8192).contains(width), (1...8192).contains(height), (1...4).contains(scale), viewWidth > 0, viewHeight > 0 else { return nil }
        let sideways = rotation == .right || rotation == .left
        let displayWidth = sideways ? height : width, displayHeight = sideways ? width : height
        let factor = min(viewWidth / displayWidth, viewHeight / displayHeight)
        let dx = (x - (viewWidth - displayWidth * factor) / 2) / factor
        let dy = (y - (viewHeight - displayHeight * factor) / 2) / factor
        guard dx >= 0, dx < displayWidth, dy >= 0, dy < displayHeight else { return nil }
        let px: Double, py: Double
        switch rotation {
        case .up: (px, py) = (dx, dy)
        case .right: (px, py) = (dy, height - dx)
        case .down: (px, py) = (width - dx, height - dy)
        case .left: (px, py) = (width - dy, dx)
        }
        return (min(width.nextDown, px) / scale, min(height.nextDown, py) / scale)
    }
}

/// A snapshot of the actual active panel. It binds a displayed frame to a precise
/// digitizer target and interface rotation; a device/window name cannot do that.
public struct SimulatorDisplayGeometry: Codable, Equatable, Sendable {
    public let id: String
    public let width: Int
    public let height: Int
    public let scale: Double
    public let rotation: Int
    public let target: Int
    public init(id: String, width: Int, height: Int, scale: Double, rotation: Int, target: Int) {
        self.id = id; self.width = width; self.height = height; self.scale = scale; self.rotation = rotation; self.target = target
    }
    public var displayWidth: Int { rotation % 2 == 0 ? width : height }
    public var displayHeight: Int { rotation % 2 == 0 ? height : width }
    public var isValid: Bool {
        UUID(uuidString: id) != nil && (1...8192).contains(width) && (1...8192).contains(height) &&
        width * height <= 33_554_432 && scale.isFinite && (1...4).contains(scale) && (0...3).contains(rotation) && (1...255).contains(target)
    }
    public func nativePoint(x: Double, y: Double) -> (x: Double, y: Double)? {
        guard isValid, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        switch rotation {
        case 0: return (x, y)
        case 1: return (y, 1 - x)
        case 2: return (1 - x, 1 - y)
        default: return (1 - y, x)
        }
    }
    /// The system-gesture edge is fixed at touch-down and rotated with the panel.
    public func nativeEdge(x: Double, y: Double) -> Int {
        let edge: Int
        if y >= 0.98 { edge = 2 }
        else if y <= 0.02 { edge = 0 }
        else if x <= 0.02 { edge = 3 }
        else if x >= 0.98 { edge = 1 }
        else { return 0 }
        return [1, 4, 3, 2][(edge - rotation + 4) % 4]
    }
}

public struct SimulatorTouch: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case down, move, up, cancel }
    public let gestureID: String
    public let frameRevision: String
    public let sequence: Int
    public let phase: Phase
    /// Normalized coordinates in the image as shown, excluding its letterbox.
    public let x: Double
    public let y: Double
    public init(gestureID: String, frameRevision: String, sequence: Int, phase: Phase, x: Double, y: Double) {
        self.gestureID = gestureID; self.frameRevision = frameRevision; self.sequence = sequence; self.phase = phase; self.x = x; self.y = y
    }
    public var isValid: Bool {
        UUID(uuidString: gestureID) != nil && !frameRevision.isEmpty && frameRevision.utf8.count <= 64 &&
        (0...1_000_000).contains(sequence) && x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }
}
