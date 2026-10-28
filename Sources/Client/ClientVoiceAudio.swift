import AVFoundation
import NocturneKit
import NocturneVoice

struct VoiceAudioOffer {
    let sdp: String
    let events: AsyncStream<VoicePeerEvent>
}

@MainActor
protocol VoiceAudioDevice: AnyObject {
    func start() async throws -> VoiceAudioOffer
    func answer(_ sdp: String) async throws
    func setMuted(_ value: Bool)
    func reactivate() throws
    func stop()
}

@MainActor
final class ClientVoiceAudio: VoiceAudioDevice {
    private let peer = CodexVoicePeer()
    private var continuation: AsyncStream<VoicePeerEvent>.Continuation?
    private var eventTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    func start() async throws -> VoiceAudioOffer {
        stop()
        let offer = try await peer.offer()
        let stream = AsyncStream<VoicePeerEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation = stream.continuation
        eventTask = Task { [weak self] in
            for await event in offer.events {
                guard !Task.isCancelled else { return }; self?.continuation?.yield(event)
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.continuation?.yield(.failed(L("Voice chat was interrupted by another audio session. Start it again when you are ready."))) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.continuation?.yield(.failed(L("The audio system restarted. Start voice chat again."))) }
        })
        return VoiceAudioOffer(sdp: offer.sdp, events: stream.stream)
    }
    func answer(_ sdp: String) async throws { try await peer.answer(sdp) }
    func setMuted(_ value: Bool) { peer.setMuted(value) }
    func reactivate() throws { try peer.reactivateAudio() }
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        eventTask?.cancel(); eventTask = nil
        peer.stop(); continuation?.finish(); continuation = nil
    }
}
