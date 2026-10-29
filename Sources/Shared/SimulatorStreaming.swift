import Foundation

/// Simulator display frames travel on the existing authenticated workspace channel.
public enum SimulatorStreaming {
    public static let capability = "simulator-preview-v1"
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
    public init(revision: String = UUID().uuidString, pixelWidth: Int, pixelHeight: Int, jpeg: Data) {
        self.revision = revision; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.jpeg = jpeg
    }
    public var isValid: Bool {
        !revision.isEmpty && revision.utf8.count <= 64 && (1...8192).contains(pixelWidth) &&
        (1...8192).contains(pixelHeight) && !jpeg.isEmpty && jpeg.count <= SimulatorStreaming.maximumImageBytes
    }
}

/// Geometry for a future input backend. Scale and rotation must be supplied by
/// that backend: a screenshot alone cannot distinguish landscape-left/right or
/// reliably tell us a device's Retina scale. No input capability is advertised yet.
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
