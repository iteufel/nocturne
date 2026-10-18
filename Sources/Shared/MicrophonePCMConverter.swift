import AVFoundation

/// One instance per hardware tap; accessed serially on the audio callback.
/// Keeps converter state between buffers, including non-48 kHz Bluetooth/USB inputs.
public final class MicrophonePCMConverter {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private var framer = MicrophoneFramer()
    public init(input: AVAudioFormat) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(MicrophoneFormat.sampleRate), channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: input, to: format) else { throw NocturneError.remote("This microphone’s audio format is unavailable.") }
        converter.downmix = true
        self.converter = converter
    }
    public func convert(_ buffer: AVAudioPCMBuffer, emit: (Data) -> Void) throws {
        guard buffer.format == converter.inputFormat, buffer.frameLength > 0 else { throw NocturneError.invalidFrame }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw NocturneError.invalidFrame }
        var consumed = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true; inputStatus.pointee = .haveData; return buffer
        }
        if let error { throw error }
        guard status != .error else { throw NocturneError.remote("Microphone conversion failed.") }
        guard let samples = output.int16ChannelData?[0], output.frameLength > 0 else { return }
        framer.append(Data(bytes: samples, count: Int(output.frameLength) * 2), emit: emit)
    }
}
