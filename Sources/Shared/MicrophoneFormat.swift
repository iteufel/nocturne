import Foundation

/// Negotiated separately from video. Signed 16-bit little-endian, mono PCM in 20 ms frames.
public enum MicrophoneFormat {
    public static let capability = "microphone-pcm-v1"
    public static let sampleRate = 48_000
    public static let samplesPerFrame = 960
    public static let bytesPerFrame = samplesPerFrame * 2
    public static let maximumInFlight = 6
    public static let timeout: TimeInterval = 2
}

/// Hardware taps do not necessarily deliver exactly 20 ms of audio.
public struct MicrophoneFramer {
    private var pending = Data()
    public init() {}
    public mutating func append(_ pcm: Data, emit: (Data) -> Void) {
        pending.append(pcm)
        while pending.count >= MicrophoneFormat.bytesPerFrame {
            emit(Data(pending.prefix(MicrophoneFormat.bytesPerFrame)))
            pending.removeFirst(MicrophoneFormat.bytesPerFrame)
        }
    }
}
