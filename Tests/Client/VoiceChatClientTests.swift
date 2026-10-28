import XCTest
import UIKit
import SwiftUI
import Network
import NocturneKit
import NocturneVoice
@testable import Nocturne

@MainActor
final class VoiceChatClientTests: XCTestCase {
    private func connected(supervisor: Bool = false) async throws -> (VoiceWorkspacePeer, WorkspaceConnection, ChatWorkspaceModel) {
        let peer = try VoiceWorkspacePeer(); peer.supervisor = supervisor; try await peer.start()
        let engine = NocturneStreamingService()
        let client = WorkspaceConnection(identity: WorkspaceIdentity(certificate: engine.workspaceCertificate(), name: "Voice test") { engine.signWorkspaceChallenge($0) })
        do {
            try await client.connect(peer.invitation())
            let model = ChatWorkspaceModel(connection: client)
            await model.refresh(); await model.open(try XCTUnwrap(model.sessions.first))
            XCTAssertTrue(model.supportsVoice); return (peer, client, model)
        } catch { client.disconnect(); peer.stop(); throw error }
    }
    func testSupervisorVoiceAutostartRequiresOptInAndSelectedSupervisor() async throws {
        let (peer, client, model) = try await connected(supervisor: true); defer { client.disconnect(); peer.stop() }
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }, applicationState: { .active })
        defer { voice.stop() }
        voice.startSupervisorIfEnabled(false)
        XCTAssertFalse(voice.engaged); XCTAssertEqual(audio.starts, 0)
        voice.startSupervisorIfEnabled(true)
        try await waitUntil { voice.active }
        XCTAssertEqual(audio.starts, 1)
        voice.startSupervisorIfEnabled(true)
        XCTAssertEqual(audio.starts, 1, "Repeated updates cannot start a second call")
        voice.stop(); peer.supervisor = false
        await model.open(try XCTUnwrap(model.selected))
        voice.startSupervisorIfEnabled(true)
        XCTAssertFalse(voice.engaged); XCTAssertEqual(audio.starts, 1)
    }
    func testSupervisorVoiceAutostartDoesNotRequestMicrophoneUntilActive() async throws {
        let (peer, client, model) = try await connected(supervisor: true); defer { client.disconnect(); peer.stop() }
        let audio = FakeVoiceAudio()
        var state = UIApplication.State.inactive, permissionRequests = 0
        let voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: {
            permissionRequests += 1; return true
        }, applicationState: { state })
        defer { voice.stop() }
        for blockedState in [UIApplication.State.inactive, .background] {
            state = blockedState
            voice.startSupervisorIfEnabled(true)
            await Task.yield()
            XCTAssertFalse(voice.engaged); XCTAssertFalse(model.voiceEngaged)
            XCTAssertEqual(permissionRequests, 0); XCTAssertEqual(audio.starts, 0); XCTAssertEqual(peer.voiceStarts, 0)
        }
        state = .active
        voice.startSupervisorIfEnabled(true)
        try await waitUntil { voice.active }
        XCTAssertEqual(permissionRequests, 1); XCTAssertEqual(audio.starts, 1); XCTAssertEqual(peer.voiceStarts, 1)
    }
    func testFailedVoicePreparationNeverStartsMicrophoneAndKeepsWorkspaceConnected() async throws {
        let (peer, client, model) = try await connected(supervisor: true); defer { client.disconnect(); peer.stop() }
        peer.failVoicePreparation = true
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }, applicationState: { .active })
        defer { voice.stop() }
        voice.startSupervisorIfEnabled(true)
        try await waitUntil { voice.error != nil }
        XCTAssertEqual(audio.starts, 0); XCTAssertEqual(peer.voiceStarts, 0)
        XCTAssertFalse(voice.engaged); XCTAssertFalse(model.voiceEngaged); XCTAssertEqual(client.state, .connected)
    }
    func testVoiceContinuationKeepsOriginalAndRoutesCallAndRetryToNewThread() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        peer.continueVoice = true; model.draft = "Keep my draft"
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }); defer { voice.stop() }
        voice.start(); try await waitUntil { voice.active }
        XCTAssertEqual(model.selected?.id, "voice-continuation")
        XCTAssertTrue(model.sessions.contains { $0.id == "voice-chat" })
        XCTAssertEqual(model.draft, "Keep my draft"); XCTAssertNotNil(model.voiceContinuationNotice)
        XCTAssertEqual(peer.startedSessions, ["voice-continuation"]); XCTAssertEqual(audio.starts, 1)
        voice.end(); try await waitUntil { !voice.engaged }
        voice.start(); try await waitUntil { voice.active }
        XCTAssertEqual(peer.preflightSessions, ["voice-chat", "voice-continuation"])
        XCTAssertEqual(peer.startedSessions, ["voice-continuation", "voice-continuation"])
        XCTAssertEqual(model.sessions.filter { $0.id == "voice-continuation" }.count, 1)
    }
    func testPreflightFailureDoesNotRecordAndCanRetry() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        peer.failPreflight = true
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }); defer { voice.stop() }
        voice.start(); try await waitUntil { voice.error != nil }
        XCTAssertEqual(audio.starts, 0); XCTAssertEqual(peer.voiceStarts, 0)
        XCTAssertEqual(model.selected?.id, "voice-chat"); XCTAssertNil(model.voiceContinuationNotice)
        peer.failPreflight = false
        voice.start(); try await waitUntil { voice.active }
        XCTAssertNil(voice.error); XCTAssertEqual(audio.starts, 1)
    }
    func testCanceledPreflightCannotSwitchThreadsOrStartRecording() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        peer.continueVoice = true; peer.delayPreflight = true
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }); defer { voice.stop() }
        voice.start(); try await waitUntil { peer.pendingPreflight != nil }
        voice.stop(); peer.pendingPreflight?(); peer.pendingPreflight = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(voice.engaged); XCTAssertFalse(model.voiceEngaged)
        XCTAssertEqual(audio.starts, 0); XCTAssertEqual(peer.voiceStarts, 0)
        XCTAssertEqual(model.selected?.id, "voice-chat"); XCTAssertNil(model.voiceContinuationNotice)
    }
    func testOlderHostCanStillStartVoiceWithoutPreflight() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        peer.supportsPreflight = false
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }); defer { voice.stop() }
        voice.start(); try await waitUntil { voice.active }
        XCTAssertEqual(peer.preflightSessions, []); XCTAssertEqual(peer.startedSessions, ["voice-chat"])
    }
    func testPermissionDenialNeverStartsAudio() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { false })
        voice.start(); try await waitUntil { voice.error != nil && !voice.engaged }
        XCTAssertEqual(audio.starts, 0); XCTAssertFalse(model.voiceEngaged); XCTAssertEqual(peer.voiceStarts, 0)
        XCTAssertEqual(client.state, .connected)
    }
    func testCancellingPermissionRequestCannotStartAudioAfterApproval() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        let audio = FakeVoiceAudio()
        var pending: CheckedContinuation<Bool, Never>?, answered = false
        let voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: {
            let allowed = await withCheckedContinuation { pending = $0 }; answered = true; return allowed
        })
        voice.start(); try await waitUntil { pending != nil }
        voice.stop(); pending?.resume(returning: true); pending = nil
        try await waitUntil { answered }; await Task.yield()
        XCTAssertEqual(audio.starts, 0); XCTAssertFalse(voice.engaged); XCTAssertFalse(model.voiceEngaged)
    }
    func testWebRTCOfferAnswerAndMuteKeepExistingVoiceControls() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true })
        defer { voice.stop() }
        voice.start(); try await waitUntil { voice.active }
        XCTAssertEqual(peer.offers, [FakeVoiceAudio.sdp]); XCTAssertEqual(audio.answers, [FakeVoiceAudio.sdp])
        voice.toggleMuted(); XCTAssertTrue(voice.muted); XCTAssertTrue(audio.muted)
        voice.toggleMuted(); XCTAssertFalse(voice.muted); XCTAssertFalse(audio.muted)
        audio.emit(.speaking(true)); try await waitUntil { voice.speaking }
        peer.send(.speechStarted); try await waitUntil { !voice.speaking }
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: NavigationStack { ChatWorkspace(model: model, connection: client, voice: voice, connect: {}) })
            window.rootViewController = host; window.makeKeyAndVisible(); defer { window.isHidden = true }
            try await Task.sleep(nanoseconds: 150_000_000); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "Codex WebRTC voice controls"; attachment.lifetime = .keepAlways; add(attachment)
        }
        voice.end(); try await waitUntil { !voice.engaged }
        XCTAssertFalse(model.voiceEngaged); XCTAssertGreaterThan(audio.stops, 0)
        _ = try await client.request(Packet(.ping))
    }
    func testAppServerStartedIsNotEnoughUntilWebRTCMediaConnects() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        let audio = FakeVoiceAudio(); audio.autoConnect = false
        let voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }); defer { voice.stop() }
        voice.start(); try await waitUntil { !audio.answers.isEmpty }
        XCTAssertTrue(voice.starting); XCTAssertFalse(voice.active)
        audio.emit(.connected); try await waitUntil { voice.active }
    }
    func testBackgroundKeepsWebRTCAudioAliveUntilHangup() async throws {
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("audio") == true)
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }); defer { voice.stop() }
        voice.start(); try await waitUntil { voice.active }; let stops = audio.stops
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(voice.active); XCTAssertTrue(model.voiceEngaged); XCTAssertEqual(audio.stops, stops)
        audio.emit(.speaking(true)); try await waitUntil { voice.speaking }
        voice.resumeAudioAfterStream(); XCTAssertEqual(audio.reactivations, 1)
        try await waitUntil { peer.heartbeats > 0 }
        _ = try await client.request(Packet(.ping))
        voice.end(); try await waitUntil { !voice.engaged }
        XCTAssertFalse(model.voiceEngaged); XCTAssertGreaterThan(audio.stops, stops)
    }
    func testBackgroundCancelsPendingMicrophonePermission() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        let audio = FakeVoiceAudio(); var pending: CheckedContinuation<Bool, Never>?, answered = false
        let voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: {
            let allowed = await withCheckedContinuation { pending = $0 }; answered = true; return allowed
        }); defer { voice.stop() }
        voice.start(); try await waitUntil { pending != nil }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(voice.engaged); XCTAssertFalse(model.voiceEngaged)
        pending?.resume(returning: true); pending = nil
        try await waitUntil { answered }; await Task.yield()
        XCTAssertEqual(audio.starts, 0); XCTAssertEqual(peer.voiceStarts, 0)
    }
    func testDisconnectStopsMediaAndRejectsPreviousVoiceLease() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }); defer { voice.stop() }
        voice.start(); try await waitUntil { voice.active }; let previous = try XCTUnwrap(peer.lastLease)
        voice.stop(); XCTAssertFalse(voice.engaged); XCTAssertFalse(model.voiceEngaged)
        voice.start(); try await waitUntil { voice.active }
        peer.send(.failed, overridingLease: previous)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(voice.active); XCTAssertNil(voice.error)
        client.disconnect(); try await waitUntil { !voice.engaged }
        XCTAssertFalse(model.voiceEngaged)
    }
    func testMediaFailureClosesOnlyVoiceConnection() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }); defer { voice.stop() }
        voice.start(); try await waitUntil { voice.active }
        audio.emit(.failed("WebRTC lost audio")); try await waitUntil { !voice.engaged && voice.error != nil }
        XCTAssertEqual(voice.error, "WebRTC lost audio"); XCTAssertFalse(model.voiceEngaged)
        _ = try await client.request(Packet(.ping)); XCTAssertEqual(client.state, .connected)
    }
    func testMalformedAnswerStopsMediaBeforeBecomingActive() async throws {
        let (peer, client, model) = try await connected(); defer { client.disconnect(); peer.stop() }
        peer.answerSDP = "not SDP"
        let audio = FakeVoiceAudio(), voice = ClientVoiceChat(chat: model, audio: audio, requestPermission: { true }); defer { voice.stop() }
        voice.start(); try await waitUntil { !voice.engaged && voice.error != nil }
        XCTAssertFalse(voice.active); XCTAssertFalse(model.voiceEngaged)
        _ = try await client.request(Packet(.ping))
    }
    func testClientSuspensionKeepsWorkspaceDuringVoiceAndReleasesAfterHangup() async throws {
        let peer = try VoiceWorkspacePeer(); try await peer.start(); defer { peer.stop() }
        let audio = FakeVoiceAudio(), app = ClientModel(voiceAudio: audio, voicePermission: { true })
        defer { app.voice.stop(); app.server.disconnect() }
        try await app.server.connect(peer.invitation())
        await app.chats.refresh(); await app.chats.open(try XCTUnwrap(app.chats.sessions.first))
        app.voice.start(); try await waitUntil { app.voice.active }
        app.suspend()
        XCTAssertTrue(app.voice.active); XCTAssertEqual(app.server.state, .connected)
        app.voice.end(); try await waitUntil { !app.voice.engaged && app.server.state == .disconnected }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("Voice state did not arrive"); throw NocturneError.timeout
    }
}

@MainActor
private final class FakeVoiceAudio: VoiceAudioDevice {
    static let sdp = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=fingerprint:sha-256 fixture\r\n"
    var starts = 0, stops = 0, reactivations = 0
    var muted = false, autoConnect = true
    var answers: [String] = []
    private var continuation: AsyncStream<VoicePeerEvent>.Continuation?
    func start() async throws -> VoiceAudioOffer {
        starts += 1
        let stream = AsyncStream<VoicePeerEvent>.makeStream(bufferingPolicy: .bufferingNewest(32)); continuation = stream.continuation
        return VoiceAudioOffer(sdp: Self.sdp, events: stream.stream)
    }
    func answer(_ sdp: String) async throws {
        try ChatVoice.validateSDP(sdp); answers.append(sdp)
        if autoConnect { emit(.connected) }
    }
    func setMuted(_ value: Bool) { muted = value }
    func reactivate() throws { reactivations += 1 }
    func emit(_ event: VoicePeerEvent) { continuation?.yield(event) }
    func stop() { stops += 1; continuation?.finish(); continuation = nil }
}

/// A real TLS peer with deterministic voice replies. It never contacts an AI service.
@MainActor
private final class VoiceWorkspacePeer {
    let key: Data
    let listener: NWListener
    var voiceStarts = 0, heartbeats = 0
    var offers: [String] = []
    var answerSDP = FakeVoiceAudio.sdp
    var lastLease: String?
    private var channels: [UUID: SecureChannel] = [:]
    private var leases: [UUID: String] = [:]
    private var leaseSessions: [UUID: String] = [:]
    var supervisor = false
    var failVoicePreparation = false
    var supportsPreflight = true, continueVoice = false, failPreflight = false, delayPreflight = false
    var preflightSessions: [String] = [], startedSessions: [String] = []
    var pendingPreflight: (() -> Void)?
    private var info: ChatSessionInfo { ChatSessionInfo(id: "voice-chat", title: "Work through the next change", directory: "/Projects/Nocturne", isSupervisor: supervisor) }
    private var continuation: ChatSessionInfo { ChatSessionInfo(id: "voice-continuation", title: "Voice · Work through the next change", directory: info.directory) }
    init() throws { key = try SecureStore.randomKey(); listener = try NWListener(using: SecureTransport.parameters(secret: key), on: .any) }
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false
            listener.stateUpdateHandler = { state in
                guard !completed else { return }
                if case .ready = state { completed = true; continuation.resume() }
                else if case .failed(let error) = state { completed = true; continuation.resume(throwing: error) }
            }
            listener.start(queue: .main)
        }
    }
    func invitation() throws -> PairingInvitation {
        try PairingInvitation(host: "127.0.0.1", port: XCTUnwrap(listener.port).rawValue, name: "Voice fixture", secret: key)
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID(), channel = SecureChannel(connection: connection, queue: .main), nonce = Data(repeating: 42, count: 32)
        channels[id] = channel
        channel.onPacket = { [weak self, weak channel] packet in
            guard let self, let channel else { return }
            var reply = packet.reply()
            do {
                switch packet.operation {
                case .hello: reply.version = WorkspaceProtocol.version; reply.data = nonce
                case .authenticate:
                    _ = try WorkspaceIdentity.verify(certificate: XCTUnwrap(packet.certificate), signature: XCTUnwrap(packet.signature), challenge: channel.boundChallenge(nonce))
                    reply.name = "Voice fixture"; reply.capabilities = [ChatProtocol.capability, ChatVoice.capability, ChatSupervisor.capability]
                    if self.supportsPreflight { reply.capabilities?.append(ChatVoice.preparationCapability) }
                case .chatProviders: reply.chatProviders = [ChatProvider(id: "codex", name: "Codex", available: true, detail: "Fixture", supportsVoice: true)]
                case .chatList: reply.chatPage = ChatSessionPage(sessions: [self.info])
                case .chatLoad: reply.chatHistory = ChatHistoryPage(session: self.info, messages: [])
                case .chatVoicePrepare: if self.failVoicePreparation { throw NocturneError.remote("Provider could not release the thread") }
                case .chatVoiceOpen:
                    let source = try XCTUnwrap(packet.chatRequest?.sessionID); self.preflightSessions.append(source)
                    if self.failPreflight { throw NocturneError.remote("Sign in with ChatGPT to start voice") }
                    reply.chatSession = self.continueVoice ? self.continuation : self.info
                    if self.delayPreflight {
                        let deferred = reply; self.pendingPreflight = { channel.send(deferred) }; return
                    }
                case .chatVoiceStart:
                    let offer = try XCTUnwrap(packet.chatRequest?.voiceSDP); try ChatVoice.validateSDP(offer); self.offers.append(offer)
                    let lease = UUID().uuidString; self.leases[id] = lease; self.lastLease = lease; self.voiceStarts += 1
                    let session = try XCTUnwrap(packet.chatRequest?.sessionID); self.leaseSessions[id] = session; self.startedSessions.append(session)
                    let event = ChatVoiceEvent(voiceID: lease, providerID: "codex", sessionID: session, kind: .started)
                    var started = Packet(.chatVoiceEvent); started.chatVoiceEvent = event; channel.send(started)
                    self.send(.answer, connection: id)
                    reply.chatVoiceEvent = event
                case .chatVoiceStop:
                    self.send(.closed, connection: id); self.leases.removeValue(forKey: id)
                case .chatVoiceHeartbeat: self.heartbeats += 1
                case .ping: break
                default: throw NocturneError.invalidFrame
                }
            } catch { reply.error = error.localizedDescription }
            channel.send(reply)
        }
        channel.onClose = { [weak self] _ in self?.channels.removeValue(forKey: id); self?.leases.removeValue(forKey: id); self?.leaseSessions.removeValue(forKey: id) }
        channel.start()
    }
    func send(_ kind: ChatVoiceEvent.Kind, overridingLease: String? = nil, connection: UUID? = nil) {
        for (id, lease) in leases where connection == nil || connection == id {
            var event = ChatVoiceEvent(voiceID: overridingLease ?? lease, providerID: "codex", sessionID: leaseSessions[id] ?? info.id, kind: kind)
            if kind == .answer { event.sdp = answerSDP }
            var packet = Packet(.chatVoiceEvent); packet.chatVoiceEvent = event; channels[id]?.send(packet)
        }
    }
    func stop() { listener.cancel(); Array(channels.values).forEach { $0.cancel() }; channels = [:]; leases = [:] }
}
