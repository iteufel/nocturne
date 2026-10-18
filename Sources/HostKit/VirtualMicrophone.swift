import Foundation
import CoreAudio
import MicrophoneBridge
import NocturneKit

/// Feeds the bundled HAL input device, never the Mac speakers or default output.
public final class VirtualMicrophone: MicrophoneOutput {
    private var device: AudioDeviceID = kAudioObjectUnknown
    public static var isInstalled: Bool { NocturneMicFindDevice() != kAudioObjectUnknown }
    public init() {}
    public func start() throws {
        let found = NocturneMicFindDevice()
        guard found != kAudioObjectUnknown else {
            throw NocturneError.remote("Install Nocturne Microphone in Nocturne Server → Sharing, then restart your Mac.")
        }
        guard NocturneMicSetControl(found, UInt32(NocturneMicStart)) == noErr else {
            throw NocturneError.remote("Nocturne Microphone is busy. Mute the other device and try again.")
        }
        device = found
    }
    public func write(_ pcm: Data) throws {
        let result = pcm.withUnsafeBytes { NocturneMicWrite(device, $0.baseAddress, UInt32($0.count)) }
        guard result == noErr else { throw NocturneError.remote("The Mac microphone input stopped responding. Mute and reconnect your microphone.") }
    }
    public func stop() {
        if device != kAudioObjectUnknown { _ = NocturneMicSetControl(device, UInt32(NocturneMicStop)) }
        device = kAudioObjectUnknown
    }
    deinit { stop() }
}
