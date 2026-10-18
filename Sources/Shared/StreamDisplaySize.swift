import Foundation

/// Pixel dimensions negotiated by both the video connection and the Mac desktop.
public struct StreamDisplaySize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public init(width: Int, height: Int, frameRate: Int) {
        self.width = width; self.height = height; self.frameRate = frameRate
    }
    public var isValid: Bool {
        (320...4096).contains(width) && (320...4096).contains(height) &&
        width % 2 == 0 && height % 2 == 0 && [30, 60, 120].contains(frameRate)
    }
    /// Use the current scene, not UIScreen.main's portrait bounds. Round to even
    /// pixels for the encoder and retain aspect ratio when limiting large displays.
    public static func matching(width: Double, height: Double, scale: Double, frameRate: Int) -> Self? {
        guard width.isFinite, height.isFinite, scale.isFinite, width > 0, height > 0, scale > 0 else { return nil }
        let w = width * scale, h = height * scale
        guard w.isFinite, h.isFinite else { return nil }
        let factor = min(1, 4096 / max(w, h))
        let result = Self(width: Int((w * factor / 2).rounded()) * 2,
            height: Int((h * factor / 2).rounded()) * 2, frameRate: frameRate)
        return result.isValid ? result : nil
    }
}
