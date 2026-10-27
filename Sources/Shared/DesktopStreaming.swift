import Foundation

/// Optional protocol-v4 extension. Older hosts keep working with iOS clients;
/// Mac clients check this capability before sending desktop operations.
public enum DesktopStreaming {
    public static let capability = "desktop-stream-v1"
    public static let audioSampleRate = 48_000
    public static let audioChannels = 2
    public static let maximumAudioFrames = 4_800
}

public struct RemoteDesktopDisplay: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int
    public let isMain: Bool
    public init(id: UInt32, name: String, width: Int, height: Int, isMain: Bool) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.isMain = isMain
    }
}

/// Interleaved little-endian Float32 stereo at 48 kHz. Each packet is bounded to
/// 100 ms; the receiver also caps its playback queue so stale sound cannot build up.
public struct DesktopAudioFrame: Codable, Sendable {
    public let data: Data
    public let frames: Int
    public init(data: Data, frames: Int) { self.data = data; self.frames = frames }
    public var isValid: Bool {
        (1...DesktopStreaming.maximumAudioFrames).contains(frames) &&
        data.count == frames * DesktopStreaming.audioChannels * MemoryLayout<Float>.size
    }
}
