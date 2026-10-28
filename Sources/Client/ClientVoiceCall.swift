import AVFoundation
import CallKit

/// CallKit owns activation; the voice session owns media and server signaling.
@MainActor
protocol VoiceSystemCall: AnyObject {
    var available: Bool { get }
    var onEnd: (() -> Void)? { get set }
    var onMute: ((Bool) -> Bool)? { get set }
    var onAudioActivation: ((Bool) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start() async throws
    func connected()
    func requestEnd()
    func requestMute(_ muted: Bool)
    func finish(failed: Bool)
}

@MainActor
final class ClientVoiceCall: NSObject, VoiceSystemCall, @preconcurrency CXProviderDelegate {
    var onEnd: (() -> Void)?
    var onMute: ((Bool) -> Bool)?
    var onAudioActivation: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    private let provider: CXProvider
    private let controller = CXCallController()
    private var audioActive = false
    var available: Bool { callID == nil && !audioActive && !controller.callObserver.calls.contains { !$0.hasEnded } }
    private var callID: UUID?
    private var pendingStart: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportsVideo = false
        // There is no standalone Recents redial route to a paired Mac/session.
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func start() async throws {
        guard available else { throw CancellationError() }
        let id = UUID(); callID = id
        try await withCheckedThrowingContinuation { continuation in
            pendingStart = continuation
            let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Nocturne Agent"))
            controller.request(CXTransaction(action: action)) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.callID == id, let error else { return }
                    self.finish(failed: true)
                    self.onFailure?(error.localizedDescription)
                }
            }
        }
    }
    func connected() {
        guard let callID else { return }
        provider.reportOutgoingCall(with: callID, connectedAt: Date())
    }
    func requestEnd() {
        guard let callID else { onEnd?(); return }
        request(CXEndCallAction(call: callID))
    }
    func requestMute(_ muted: Bool) {
        guard let callID else { return }
        request(CXSetMutedCallAction(call: callID, muted: muted))
    }
    private func request(_ action: CXCallAction) {
        let id = action.callUUID
        controller.request(CXTransaction(action: action)) { [weak self] error in
            Task { @MainActor in
                guard let self, self.callID == id, let error else { return }
                // End the actual session as well if the system can no longer control it.
                self.onFailure?(error.localizedDescription)
            }
        }
    }
    func finish(failed: Bool) {
        let id = callID; callID = nil
        pendingStart?.resume(throwing: CancellationError()); pendingStart = nil
        if let id { provider.reportCall(with: id, endedAt: Date(), reason: failed ? .failed : .remoteEnded) }
    }
    func providerDidReset(_ provider: CXProvider) {
        finish(failed: true)
        if audioActive { audioActive = false; onAudioActivation?(false) }
        onFailure?("The system call service reset. Start voice chat again.")
    }
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard callID == action.callUUID, let pendingStart else { action.fail(); return }
        self.pendingStart = nil
        let update = CXCallUpdate()
        update.localizedCallerName = "Nocturne Agent"
        update.remoteHandle = action.handle
        update.supportsHolding = false; update.supportsGrouping = false
        update.supportsUngrouping = false; update.supportsDTMF = false
        provider.reportCall(with: action.callUUID, updated: update)
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        // Audio was configured before requesting this action. The system activates it next.
        action.fulfill(); pendingStart.resume()
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard callID == action.callUUID else { action.fail(); return }
        callID = nil
        pendingStart?.resume(throwing: CancellationError()); pendingStart = nil
        onEnd?(); action.fulfill()
    }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard callID == action.callUUID, onMute?(action.isMuted) == true else { action.fail(); return }
        action.fulfill()
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let action = action as? CXCallAction, action.callUUID == callID else { return }
        onFailure?("The system call action timed out. Start voice chat again.")
    }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioActive = true
        onAudioActivation?(true)
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioActive = false
        onAudioActivation?(false)
    }
}
