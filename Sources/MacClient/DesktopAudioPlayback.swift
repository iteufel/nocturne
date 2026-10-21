import AVFoundation
import NocturneKit

@MainActor
final class DesktopAudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(DesktopStreaming.audioSampleRate), channels: 2)!
    private var queuedFrames = 0
    private var epoch = UUID()
    var muted = false { didSet { player.volume = muted ? 0 : 1 } }
    init() {
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
    }
    func enqueue(_ frame: DesktopAudioFrame) throws {
        guard frame.isValid else { throw NocturneError.invalidFrame }
        guard queuedFrames + frame.frames <= DesktopStreaming.audioSampleRate / 5 else { return }
        if !engine.isRunning { try engine.start(); player.play() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.frames)),
              let channels = buffer.floatChannelData else { throw NocturneError.invalidFrame }
        buffer.frameLength = AVAudioFrameCount(frame.frames)
        frame.data.withUnsafeBytes { bytes in
            for index in 0..<frame.frames {
                for channel in 0..<2 {
                    let bits = bytes.loadUnaligned(fromByteOffset: (index * 2 + channel) * 4, as: UInt32.self)
                    let value = Float(bitPattern: UInt32(littleEndian: bits))
                    channels[channel][index] = value.isFinite ? min(1, max(-1, value)) : 0
                }
            }
        }
        queuedFrames += frame.frames
        let generation = epoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.epoch == generation else { return }
                self.queuedFrames = max(0, self.queuedFrames - frame.frames)
            }
        }
    }
    func stop() { epoch = UUID(); player.stop(); engine.stop(); queuedFrames = 0 }
}
