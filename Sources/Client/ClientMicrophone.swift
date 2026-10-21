import AVFoundation
import Combine
import NocturneKit

private enum MicrophoneCaptureEvent {
    case pcm(Data)
    case failed(String)
}

/// Owned by one audio tap. Resampling/framing stays off the main actor; the bounded
/// stream drops old capture events if UI work or a slow network falls behind.
private final class MicrophoneEncoder {
    private let converter: MicrophonePCMConverter
    private let continuation: AsyncStream<MicrophoneCaptureEvent>.Continuation
    private var failed = false
    init(input: AVAudioFormat, continuation: AsyncStream<MicrophoneCaptureEvent>.Continuation) throws {
        converter = try MicrophonePCMConverter(input: input); self.continuation = continuation
    }
    func encode(_ buffer: AVAudioPCMBuffer) {
        guard !failed else { return }
        do { try converter.convert(buffer) { continuation.yield(.pcm($0)) } }
        catch {
            failed = true; continuation.yield(.failed(error.localizedDescription))
        }
    }
}

@MainActor
final class ClientMicrophone: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var starting = false
    @Published private(set) var inputName = "Microphone"
    @Published private(set) var error: String?
    private var generation = UUID()
    private var connection: WorkspaceConnection?
    private var lease: String?
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var changedAudioSession = false
    private var inFlight = 0
    private var sequence: Int64 = 0
    private var startTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var captureWatchdog: Task<Void, Never>?
    private var lastCapture: TimeInterval = 0
    private var continuation: AsyncStream<MicrophoneCaptureEvent>.Continuation?
    private var connectionObserver: AnyCancellable?
    private var observers: [NSObjectProtocol] = []

    func start(invitation: PairingInvitation, connection: WorkspaceConnection) {
        guard !active, !starting else { return }
        stop(); error = nil; starting = true
        let epoch = generation
        self.connection = connection
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let allowed = await AVAudioApplication.requestRecordPermission()
                guard self.generation == epoch, !Task.isCancelled else { return }
                guard allowed else { throw NocturneError.remote("Allow microphone access in iOS Settings → Nocturne to use voice chat.") }
                try await connection.connect(invitation, restoreTerminalSessions: false)
                guard self.generation == epoch, !Task.isCancelled else { connection.disconnect(); return }
                guard connection.capabilities.contains(MicrophoneFormat.capability) else {
                    throw NocturneError.remote("Enable Client microphone in Nocturne → Sharing, then reconnect.")
                }
                let reply = try await connection.request(Packet(.microphoneStart), timeout: 5)
                guard self.generation == epoch, !Task.isCancelled else { connection.disconnect(); return }
                guard let lease = reply.sessionID else { throw NocturneError.invalidFrame }
                self.lease = lease
                try self.beginCapture(epoch: epoch)
                self.active = true; self.starting = false
                self.connectionObserver = connection.$state.sink { [weak self] state in
                    guard state == .disconnected else { return }
                    Task { @MainActor in
                        guard let self, self.generation == epoch else { return }
                        self.fail("Microphone disconnected. Unmute to reconnect.", epoch: epoch)
                    }
                }
            } catch {
                guard self.generation == epoch else { return }
                self.fail(error.localizedDescription, epoch: epoch)
            }
        }
    }
    private func beginCapture(epoch: UUID) throws {
        let session = AVAudioSession.sharedInstance()
        changedAudioSession = true
        // Playback remains active for the game. HFP selects the headset microphone
        // when a Bluetooth headset is attached; wired/USB inputs use the current route.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setPreferredSampleRate(Double(MicrophoneFormat.sampleRate))
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        let engine = AVAudioEngine(); self.engine = engine
        try engine.inputNode.setVoiceProcessingEnabled(true)
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else { throw NocturneError.remote("Connect a microphone to this device and try again.") }
        inputName = session.currentRoute.inputs.first?.portName ?? "Microphone"
        // Some input routes deliver a 100 ms tap despite the requested buffer size.
        let events = AsyncStream<MicrophoneCaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(MicrophoneFormat.maximumInFlight))
        continuation = events.continuation
        let encoder = try MicrophoneEncoder(input: input, continuation: events.continuation)
        engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(input.sampleRate * 0.02), format: input) { buffer, _ in encoder.encode(buffer) }
        tapInstalled = true
        engine.prepare(); try engine.start()
        lastCapture = ProcessInfo.processInfo.systemUptime
        captureTask = Task { [weak self] in
            for await event in events.stream {
                guard let self, self.generation == epoch, !Task.isCancelled else { return }
                switch event {
                case .pcm(let bytes): self.send(bytes, epoch: epoch)
                case .failed(let message): self.fail(message, epoch: epoch); return
                }
            }
        }
        captureWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, self.generation == epoch else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastCapture >= MicrophoneFormat.timeout {
                    self.fail("Microphone capture stopped. Unmute to try again.", epoch: epoch); return
                }
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.fail("Microphone interrupted. Unmute when you’re ready.", epoch: epoch) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
            guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  [AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue].contains(reason) else { return }
            Task { @MainActor in self?.fail("Audio device changed. Unmute to use the new microphone.", epoch: epoch) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fail("Audio restarted. Unmute to reconnect your microphone.", epoch: epoch) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
            Task { @MainActor in
                guard let self, let engine, self.generation == epoch, !engine.isRunning else { return }
                self.fail("Audio configuration changed. Unmute to reconnect your microphone.", epoch: epoch)
            }
        })
    }
    private func send(_ pcm: Data, epoch: UUID) {
        guard active, let connection, let lease else { return }
        lastCapture = ProcessInfo.processInfo.systemUptime
        sequence += 1
        // Receiver acknowledgements bound the entire transport backlog, not just
        // NWConnection's local send buffer. Drop new frames while the window is full.
        guard inFlight < MicrophoneFormat.maximumInFlight else { return }
        inFlight += 1
        var packet = Packet(.microphoneAudio); packet.sessionID = lease; packet.offset = sequence; packet.data = pcm
        Task { [weak self] in
            do { _ = try await connection.request(packet, timeout: 1) }
            catch { self?.fail(error.localizedDescription, epoch: epoch) }
            guard let self, self.generation == epoch else { return }
            self.inFlight -= 1
        }
    }
    func stop() {
        generation = UUID(); startTask?.cancel(); startTask = nil
        active = false; starting = false
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }; tapInstalled = false
        engine = nil; continuation?.finish(); continuation = nil; captureTask?.cancel(); captureTask = nil
        captureWatchdog?.cancel(); captureWatchdog = nil
        connectionObserver = nil
        // Closing the dedicated socket releases the host lease and flushes all
        // buffered speech without a stop packet waiting behind unacknowledged audio.
        connection?.disconnect(); connection = nil; lease = nil; inFlight = 0; sequence = 0
        if changedAudioSession {
            changedAudioSession = false
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
    }
    private func fail(_ message: String, epoch: UUID) {
        guard generation == epoch else { return }
        stop(); error = message
    }
}
