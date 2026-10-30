import AVFoundation
import UIKit
import Combine
import NocturneKit
import NocturneVoice

@MainActor
final class ClientVoiceChat: ObservableObject {
    @Published private(set) var starting = false
    @Published private(set) var active = false
    @Published private(set) var ending = false
    @Published private(set) var muted = false
    @Published private(set) var speaking = false
    @Published private(set) var error: String?
    var engaged: Bool { starting || active || ending }
    var beforeStart: (() async -> Void)?
    private let chat: ChatWorkspaceModel
    private let calls: VoiceSystemCall
    private var systemAudioActive = false
    private let audio: VoiceAudioDevice
    private let requestPermission: () async -> Bool
    private let applicationState: @MainActor () -> UIApplication.State
    private var connection: WorkspaceConnection?
    private var voiceID: String?, sessionID: String?, providerID: String?
    private var generation = UUID()
    private var acknowledged = false, peerConnected = false, answering = false
    private var startTask: Task<Void, Never>?, mediaTask: Task<Void, Never>?, heartbeat: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?, connectionDeadline: Task<Void, Never>?, endTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = [], globalObservers: Set<AnyCancellable> = []

    init(chat: ChatWorkspaceModel, audio: VoiceAudioDevice? = nil, calls: VoiceSystemCall? = nil, requestPermission: @escaping () async -> Bool = { await AVAudioApplication.requestRecordPermission() }, applicationState: @escaping @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState }) {
        self.chat = chat; self.audio = audio ?? ClientVoiceAudio(); self.requestPermission = requestPermission
        self.applicationState = applicationState
        self.calls = calls ?? ClientVoiceCall()
        self.calls.onEnd = { [weak self] in self?.endSession() }
        self.calls.onMute = { [weak self] value in
            guard let self, self.engaged, !self.ending else { return false }
            self.muted = value; self.audio.setMuted(value); return true
        }
        self.calls.onAudioActivation = { [weak self] activated in
            guard let self else { return }
            self.audio.systemAudioActivation(activated)
            self.systemAudioActive = activated
            if activated { self.activateIfReady() }
            else if self.starting || self.active { self.fail(L("Voice chat was interrupted by the system audio session. Start it again when you are ready."), epoch: self.generation) }
        }
        self.calls.onFailure = { [weak self] message in
            guard let self, self.engaged else { return }
            self.fail(message, epoch: self.generation)
        }
        chat.$voiceEngaged.dropFirst().sink { [weak self] engaged in
            if !engaged, self?.engaged == true { self?.stop() }
        }.store(in: &globalObservers)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            // Continue established calls, but never finish starting a new recording in the background.
            if self?.active != true { self?.stop() }
        }.store(in: &globalObservers)
    }
    func startSupervisorIfEnabled(_ enabled: Bool) {
        guard enabled, chat.selected?.isSupervisor == true, applicationState() == .active else { return }
        start()
    }
    func start() {
        guard !engaged, chat.supportsVoice, !chat.loading, !chat.responding,
              let session = chat.selected, let invitation = chat.connection.connectedInvitation else { return }
        guard calls.available else { error = L("Finish the current system call before starting voice chat."); return }
        stop(); error = nil
        let epoch = generation, connection = chat.connection.mediaConnection()
        self.connection = connection; sessionID = session.id; providerID = chat.providerID
        do { try chat.attachVoice(connection) } catch { self.error = NocturneLocalization.message(error.localizedDescription); self.connection = nil; return }
        starting = true
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let allowed = await self.requestPermission()
                guard self.generation == epoch, !Task.isCancelled else { return }
                guard allowed else { throw NocturneError.remote(L("Allow microphone access in iOS Settings → Nocturne to start voice chat.")) }
                await self.beforeStart?()
                guard self.generation == epoch, !Task.isCancelled else { return }
                try await self.chat.prepareVoice()
                guard self.generation == epoch, !Task.isCancelled else { return }
                try await connection.connect(invitation, restoreTerminalSessions: false)
                guard self.generation == epoch, !Task.isCancelled else { return }
                guard connection.capabilities.contains(ChatVoice.capability) else { throw NocturneError.remote(L("Update Nocturne Server on your Mac and enable Agent chats, then reconnect.")) }
                let voiceSession = try await self.chat.openVoice(on: connection, from: session.id)
                guard self.generation == epoch, !Task.isCancelled else { return }
                self.sessionID = voiceSession.id
                connection.chatVoiceEvents.sink { [weak self] event in self?.receive(event, epoch: epoch) }.store(in: &self.observers)
                connection.$state.dropFirst().sink { [weak self] state in
                    if state == .disconnected { self?.fail(L("Voice chat disconnected. Start it again to reconnect."), epoch: epoch) }
                }.store(in: &self.observers)
                chat.connection.$state.dropFirst().sink { [weak self] state in
                    if state != .connected { self?.stop() }
                }.store(in: &self.observers)
                let offer = try await self.audio.start()
                guard self.generation == epoch, !Task.isCancelled else { return }
                try ChatVoice.validateSDP(offer.sdp)
                try await self.calls.start()
                guard self.generation == epoch, !Task.isCancelled else { return }
                self.mediaTask = Task { [weak self] in
                    for await event in offer.events {
                        guard let self, self.generation == epoch, !Task.isCancelled else { return }
                        switch event {
                        case .connected: self.peerConnected = true; self.activateIfReady()
                        case .speaking(let value): self.speaking = value
                        case .failed(let message): self.fail(message, epoch: epoch); return
                        }
                    }
                }
                var packet = Packet(.chatVoiceStart); packet.chatRequest = ChatRequest(providerID: chat.providerID, sessionID: voiceSession.id)
                packet.chatRequest?.voiceSDP = offer.sdp
                let reply = try await connection.request(packet, timeout: 75)
                guard self.generation == epoch, !Task.isCancelled else { return }
                guard let started = reply.chatVoiceEvent, started.kind == .started,
                      started.providerID == self.providerID, started.sessionID == self.sessionID,
                      self.voiceID == started.voiceID else { throw NocturneError.invalidFrame }
                self.acknowledged = true; self.activateIfReady()
                self.connectionDeadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    guard let self, self.generation == epoch, !self.active else { return }
                    self.fail(L("WebRTC could not establish audio. Check your network and start voice chat again."), epoch: epoch)
                }
                self.heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                        guard let self, self.generation == epoch, let lease = self.voiceID else { return }
                        var pulse = Packet(.chatVoiceHeartbeat); pulse.chatRequest = self.request(lease)
                        do { _ = try await connection.request(pulse, timeout: 3) }
                        catch { self.fail(NocturneLocalization.message(error.localizedDescription), epoch: epoch); return }
                    }
                }
            } catch {
                if !self.ending { self.fail(NocturneLocalization.message(error.localizedDescription), epoch: epoch) }
            }
        }
    }
    func toggleMuted() { guard active, !ending else { return }; calls.requestMute(!muted) }
    func resumeAudioAfterStream() {
        guard active else { return }
        do { try audio.reactivate() } catch { fail(NocturneLocalization.message(error.localizedDescription), epoch: generation) }
    }
    func end() { guard engaged else { return }; calls.requestEnd() }
    private func endSession() {
        guard engaged, !ending else { return }
        guard let connection, let lease = voiceID else { stop(); return }
        let epoch = generation
        active = false; starting = false; ending = true; speaking = false
        startTask?.cancel(); startTask = nil
        audio.stop(); mediaTask?.cancel(); mediaTask = nil; heartbeat?.cancel(); heartbeat = nil
        answerTask?.cancel(); answerTask = nil; connectionDeadline?.cancel(); connectionDeadline = nil
        endTask = Task { [weak self] in
            guard let self else { return }
            var packet = Packet(.chatVoiceStop); packet.chatRequest = self.request(lease)
            _ = try? await connection.request(packet, timeout: 3)
            if self.generation == epoch { self.stop() }
        }
    }
    func stop(failed: Bool = false) {
        generation = UUID()
        startTask?.cancel(); mediaTask?.cancel(); heartbeat?.cancel(); answerTask?.cancel(); connectionDeadline?.cancel(); endTask?.cancel()
        startTask = nil; mediaTask = nil; heartbeat = nil; answerTask = nil; connectionDeadline = nil; endTask = nil
        active = false; starting = false; ending = false; muted = false; speaking = false
        audio.stop(); calls.finish(failed: failed); systemAudioActive = false; observers = []
        let previous = connection; connection = nil
        if let previous { chat.detachVoice(previous); previous.disconnect() }
        voiceID = nil; sessionID = nil; providerID = nil; acknowledged = false; peerConnected = false; answering = false
    }
    func dismissError() { error = nil }
    private func activateIfReady() {
        guard starting, acknowledged, peerConnected, systemAudioActive else { return }
        starting = false; active = true; calls.connected(); connectionDeadline?.cancel(); connectionDeadline = nil
    }
    private func request(_ lease: String) -> ChatRequest {
        var request = ChatRequest(providerID: providerID ?? "codex", sessionID: sessionID); request.voiceID = lease; return request
    }
    private func receive(_ event: ChatVoiceEvent, epoch: UUID) {
        guard generation == epoch, event.providerID == providerID, event.sessionID == sessionID else { return }
        if voiceID == nil, starting, event.kind == .started || event.kind == .answer { voiceID = event.voiceID }
        guard event.voiceID == voiceID else { return }
        switch event.kind {
        case .started: break
        case .answer:
            guard starting, !answering, let sdp = event.sdp else { fail(L("Codex sent an unexpected WebRTC answer."), epoch: epoch); return }
            answering = true
            answerTask = Task { [weak self] in
                do { try await self?.audio.answer(sdp) }
                catch { self?.fail(NocturneLocalization.message(error.localizedDescription), epoch: epoch) }
            }
        case .speechStarted: speaking = false
        case .closed:
            if ending { stop() }
            else { stop(); error = NocturneLocalization.message(event.detail ?? L("Codex ended voice chat. Start it again to reconnect.")) }
        case .failed: fail(event.detail ?? L("Codex voice ended unexpectedly."), epoch: epoch)
        }
    }
    private func fail(_ message: String, epoch: UUID) {
        guard generation == epoch else { return }; stop(failed: true); error = NocturneLocalization.message(message)
    }
}
