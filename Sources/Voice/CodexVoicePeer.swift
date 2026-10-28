import Foundation
import WebRTC
import NocturneKit
#if os(iOS)
import AVFAudio
#endif

public enum VoicePeerEvent: Equatable {
    case connected, speaking(Bool), failed(String)
}

/// Owns native WebRTC media only. Codex owns authentication, call creation and the sideband.
@MainActor
public final class CodexVoicePeer: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()
    private var peer: RTCPeerConnection?
    private var microphone: RTCAudioTrack?
    private var channel: RTCDataChannel?
    private var continuation: AsyncStream<VoicePeerEvent>.Continuation?
    private var generation = UUID()
    private var disconnectDeadline: Task<Void, Never>?

    public override init() { super.init() }
#if os(iOS)
    private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions, Bool, Bool)?
    private var activatedAudio = false
    private var systemManagedAudio = false
    private var systemAudioActive = false
    private var answered = false
    private var previousRTCConfiguration: RTCAudioSessionConfiguration?
#endif

    public func offer(systemManagedAudio: Bool = false) async throws -> (sdp: String, events: AsyncStream<VoicePeerEvent>) {
        stop()
#if os(iOS)
        self.systemManagedAudio = systemManagedAudio
        try configureAudio()
#endif
        let epoch = generation
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        // App Server 0.164.0 accepts a single SDP offer, without a trickle-ICE method.
        configuration.continualGatheringPolicy = .gatherOnce
        guard let peer = Self.factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            stop()
            throw NocturneError.remote("Could not create the WebRTC voice connection.")
        }
        self.peer = peer
        let events = AsyncStream<VoicePeerEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation = events.continuation
        let source = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil,
            optionalConstraints: ["googEchoCancellation": "true", "googNoiseSuppression": "true"]))
        let microphone = Self.factory.audioTrack(with: source, trackId: "nocturne-microphone")
        self.microphone = microphone
        peer.add(microphone, streamIds: ["nocturne-voice"])
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) else {
            stop(); throw NocturneError.remote("Could not create the WebRTC events channel.")
        }
        self.channel = channel; channel.delegate = self
        do {
            let description: RTCSessionDescription = try await withCheckedThrowingContinuation { resume in
                peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)) { sdp, error in
                    if let error { resume.resume(throwing: error) }
                    else if let sdp { resume.resume(returning: sdp) }
                    else { resume.resume(throwing: NocturneError.invalidFrame) }
                }
            }
            try check(epoch)
            try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
                peer.setLocalDescription(description) { error in
                    if let error { resume.resume(throwing: error) } else { resume.resume() }
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while peer.iceGatheringState != .complete {
                try check(epoch)
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw NocturneError.remote("WebRTC could not gather network candidates. Check your connection and try again.")
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try check(epoch)
            guard let sdp = peer.localDescription?.sdp else { throw NocturneError.invalidFrame }
            try ChatVoice.validateSDP(sdp)
            return (sdp, events.stream)
        } catch { if generation == epoch { stop() }; throw error }
    }
    public func answer(_ sdp: String) async throws {
        try ChatVoice.validateSDP(sdp)
        guard let peer, peer.signalingState == .haveLocalOffer else { throw NocturneError.invalidFrame }
        let epoch = generation
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                if let error { resume.resume(throwing: error) } else { resume.resume() }
            }
        }
        try check(epoch)
#if os(iOS)
        answered = true
        RTCAudioSession.sharedInstance().isAudioEnabled = !systemManagedAudio || systemAudioActive
#endif
        // WebRTC's audio device plays the received audio track through its duplex audio session.
        peer.receivers.compactMap { $0.track as? RTCAudioTrack }.forEach { $0.isEnabled = true }
    }
    public func setMuted(_ muted: Bool) { microphone?.isEnabled = !muted }
    public func stop() {
        generation = UUID()
        disconnectDeadline?.cancel(); disconnectDeadline = nil
        microphone?.isEnabled = false; microphone = nil
        channel?.delegate = nil; channel?.close(); channel = nil
        peer?.delegate = nil; peer?.close(); peer = nil
        continuation?.finish(); continuation = nil
#if os(iOS)
        restoreAudio()
#endif
    }
    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
    }
    private func receive(_ data: Data) {
        guard data.count <= 262_144, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = value["type"] as? String else { return }
        switch type {
        case "output_audio_buffer.started": continuation?.yield(.speaking(true))
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared": continuation?.yield(.speaking(false))
        // Transcripts, tool calls and errors come from Codex's thread-scoped sideband.
        default: break
        }
    }
#if os(iOS)
    private func configureAudio() throws {
        let rtc = RTCAudioSession.sharedInstance(), session = AVAudioSession.sharedInstance()
        previousAudio = (session.category, session.mode, session.categoryOptions, rtc.useManualAudio, rtc.isAudioEnabled)
        if systemManagedAudio {
            previousRTCConfiguration = RTCAudioSessionConfiguration.webRTC()
            let configuration = RTCAudioSessionConfiguration()
            configuration.category = AVAudioSession.Category.playAndRecord.rawValue
            configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
            configuration.categoryOptions = [.allowBluetoothHFP]
            RTCAudioSessionConfiguration.setWebRTC(configuration)
        }
        rtc.lockForConfiguration()
        do {
            rtc.useManualAudio = true; rtc.isAudioEnabled = false
            try rtc.setCategory(.playAndRecord, with: systemManagedAudio ? [.allowBluetoothHFP] : [.allowBluetoothHFP, .defaultToSpeaker])
            try rtc.setMode(.voiceChat)
            if !systemManagedAudio { try rtc.setActive(true); activatedAudio = true }
            rtc.unlockForConfiguration()
        } catch { rtc.unlockForConfiguration(); restoreAudio(); throw error }
    }
    /// SDL may deactivate the shared session when a desktop stream closes in the background.
    public func reactivateAudio() throws {
        guard peer != nil else { return }
        // CallKit alone may activate/deactivate a managed session. SDL must not steal ownership.
        if systemManagedAudio { return }
        guard activatedAudio else { return }
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration(); defer { rtc.unlockForConfiguration() }
        try rtc.setCategory(.playAndRecord, with: [.allowBluetoothHFP, .defaultToSpeaker])
        try rtc.setMode(.voiceChat)
        // Balance our activation before reasserting it, since SDL can change the shared OS session.
        try rtc.setActive(false); activatedAudio = false
        try rtc.setActive(true); activatedAudio = true
    }
    /// Forward CallKit activation to WebRTC's external audio-session ownership API.
    public func systemAudioActivation(_ active: Bool) {
        let rtc = RTCAudioSession.sharedInstance()
        systemAudioActive = active
        if active {
            rtc.audioSessionDidActivate(AVAudioSession.sharedInstance())
            rtc.isAudioEnabled = systemManagedAudio && answered && peer != nil
        } else {
            rtc.isAudioEnabled = false
            rtc.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
            if peer == nil { restoreAudio() }
        }
    }
    private func restoreAudio() {
        answered = false
        // Do not restore categories or manual-audio state while CallKit still owns active I/O.
        if systemManagedAudio && systemAudioActive {
            RTCAudioSession.sharedInstance().isAudioEnabled = false
            return
        }
        guard let previousAudio else { return }; self.previousAudio = nil
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration(); defer { rtc.unlockForConfiguration() }
        rtc.isAudioEnabled = false
        if activatedAudio { try? rtc.setActive(false); activatedAudio = false }
        if !systemManagedAudio {
            try? rtc.setCategory(previousAudio.0, with: previousAudio.2)
            try? rtc.setMode(previousAudio.1)
        }
        if let previousRTCConfiguration {
            RTCAudioSessionConfiguration.setWebRTC(previousRTCConfiguration)
            self.previousRTCConfiguration = nil
        }
        rtc.useManualAudio = previousAudio.3; rtc.isAudioEnabled = previousAudio.4
    }
#endif
}

extension CodexVoicePeer: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            switch newState {
            case .connected: self.continuation?.yield(.connected)
            case .failed, .closed: self.continuation?.yield(.failed("The WebRTC voice connection ended. Start voice chat again."))
            default: break // ICE disconnection can recover; the client also has a connection deadline.
            }
        }
    }
    nonisolated public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor [weak self] in
            guard let self, self.channel === dataChannel else { return }; self.receive(data)
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            self.disconnectDeadline?.cancel(); self.disconnectDeadline = nil
            if newState == .disconnected {
                self.disconnectDeadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    guard let self, self.peer === peerConnection, peerConnection.iceConnectionState == .disconnected else { return }
                    self.continuation?.yield(.failed("WebRTC lost its audio connection. Start voice chat again."))
                }
            }
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
}
