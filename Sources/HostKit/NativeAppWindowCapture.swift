import AppKit
import ScreenCaptureKit
import VideoToolbox
import NocturneKit

@MainActor
final class NativeAppWindowCapture: NSObject, AppWindowCapture, SCStreamOutput, SCStreamDelegate {
    private(set) var window: RemoteAppWindow
    private(set) var display = StreamDisplaySize(width: 1920, height: 1080, frameRate: 60)
    private let source: SCWindow
    private let accessibility: AppWindowAccessibility
    private let encoder: AppWindowVideoEncoder
    private let ended: (Error) -> Void
    private var stream: SCStream?
    private var stopped = false
    init(window: SCWindow, applicationID: String, send: @escaping AppWindowSend, ended: @escaping (Error) -> Void) throws {
        guard let owner = window.owningApplication else { throw NocturneError.invalidFrame }
        accessibility = try AppWindowAccessibility(pid: owner.processID, windowID: window.windowID)
        source = window; encoder = AppWindowVideoEncoder(send: send); self.ended = ended
        self.window = RemoteAppWindow(id: window.windowID, applicationID: applicationID,
            title: window.title ?? owner.applicationName, width: Int(window.frame.width), height: Int(window.frame.height))
        super.init()
    }
    private func configuration(_ viewport: AppWindowViewport) throws -> SCStreamConfiguration {
        let size = try accessibility.resize(viewport)
        guard !stopped else { throw NocturneError.disconnected }
        guard let pixels = viewport.pixels(width: size.width, height: size.height) else { throw NocturneError.invalidFrame }
        display = pixels
        window = RemoteAppWindow(id: window.id, applicationID: window.applicationID, title: window.title,
                                 width: Int(size.width), height: Int(size.height))
        let configuration = SCStreamConfiguration()
        configuration.width = pixels.width; configuration.height = pixels.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(pixels.frameRate))
        configuration.queueDepth = 3; configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true
        configuration.capturesAudio = false
        if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        try encoder.configure(pixels)
        return configuration
    }
    func start(_ viewport: AppWindowViewport) async throws {
        let configuration = try configuration(viewport)
        // A desktop-independent window filter never captures the desktop or an
        // overlapping application's windows, even when this window is occluded.
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: source), configuration: configuration, delegate: self)
        self.stream = stream
        do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: encoder.queue) }
        catch { throw NocturneError.remote("Could not attach app window capture: \(error.localizedDescription)") }
        do { try await stream.startCapture() }
        catch { throw NocturneError.remote("Could not start app window capture: \(error.localizedDescription)") }
        guard !stopped else { try? await stream.stopCapture(); throw NocturneError.disconnected }
    }
    func resize(_ viewport: AppWindowViewport) async throws {
        guard !stopped, let stream else { throw NocturneError.disconnected }
        let configuration = try configuration(viewport)
        try await stream.updateConfiguration(configuration)
        guard !stopped else { throw NocturneError.disconnected }
    }
    func input(_ input: AppWindowInput) async throws {
        guard !stopped else { throw NocturneError.disconnected }
        try await accessibility.input(input, isActive: { !self.stopped })
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        encoder.stop(); accessibility.release()
        if let stream { self.stream = nil; Task { try? await stream.stopCapture() } }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // The delegate runs on the encoder's serial queue.
        if type == .screen { encoder.encode(sampleBuffer) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.stop(); self.ended(error)
        }
    }
}

/// One encode/send in flight per window. Slow clients drop *unencoded* capture
/// frames, preserving H.264 references and keeping memory/latency bounded.
final class AppWindowVideoEncoder: @unchecked Sendable {
    let queue = DispatchQueue(label: "nocturne.app-video", qos: .userInteractive)
    private let send: AppWindowSend
    private let encoderSpecification: CFDictionary?
    private var session: VTCompressionSession?
    private var generation = UUID()
    private var pending = false
    private var forceKeyframe = true
    init(send: @escaping AppWindowSend, encoderSpecification: CFDictionary? = nil) {
        self.send = send; self.encoderSpecification = encoderSpecification
    }
    func configure(_ size: StreamDisplaySize) throws {
        try queue.sync {
            invalidate()
            let status = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: encoderSpecification, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
            guard status == noErr, let session else { throw NocturneError.remote("The Mac could not create an app video encoder.") }
            let properties: [CFString: Any] = [kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
                kVTCompressionPropertyKey_ExpectedFrameRate: size.frameRate,
                kVTCompressionPropertyKey_MaxKeyFrameInterval: size.frameRate * 2,
                kVTCompressionPropertyKey_AverageBitRate: min(30_000_000, max(2_000_000, size.width * size.height * size.frameRate / 8))]
            guard VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr,
                  VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
                invalidate(); throw NocturneError.remote("The Mac could not configure app video encoding.")
            }
        }
    }
    func encode(_ sample: CMSampleBuffer) {
        guard !pending, let session, CMSampleBufferIsValid(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sample) else { return }
        pending = true
        let epoch = generation
        let properties: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, encoded in
                guard let self else { return }
                self.queue.async {
                    guard self.generation == epoch else { return }
                    guard status == noErr, let encoded, let frame = self.frame(encoded) else {
                        self.pending = false; self.forceKeyframe = true; return
                    }
                    self.sendFrame(frame, offset: 0, id: UUID().uuidString, epoch: epoch)
                }
            }
        // A software encoder may buffer its first frame even in real-time mode.
        // Drain this single submission on the encoder queue before waiting for
        // send completion; no subsequent capture frame is needed to make progress.
        let completed = status == noErr ? VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) : status
        if completed != noErr { pending = false; forceKeyframe = true }
    }
    private func sendFrame(_ frame: AppWindowVideoFrame, offset: Int, id: String, epoch: UUID) {
        guard generation == epoch else { return }
        let end = min(frame.data.count, offset + AppStreaming.videoChunkSize)
        var packet = Packet(.appVideo); packet.transferID = id; packet.offset = Int64(offset); packet.size = Int64(frame.data.count)
        packet.video = .init(data: frame.data.subdata(in: offset..<end), parameterSets: frame.parameterSets, timestamp: frame.timestamp)
        send(packet) { [weak encoder = self] error in
            guard let encoder else { return }
            encoder.queue.async {
                guard encoder.generation == epoch else { return }
                if error != nil { encoder.pending = false; encoder.forceKeyframe = true }
                else if end == frame.data.count { encoder.pending = false }
                else { encoder.sendFrame(frame, offset: end, id: id, epoch: epoch) }
            }
        }
    }
    private func frame(_ sample: CMSampleBuffer) -> AppWindowVideoFrame? {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= AppStreaming.maximumVideoBytes else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard status == noErr else { return nil }
        var sets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr,
                  let pointer, size > 0, size <= 4096 else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        let result = AppWindowVideoFrame(data: data, parameterSets: sets, timestamp: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        return result.isValid ? result : nil
    }
    func stop() { queue.sync { invalidate() } }
    private func invalidate() {
        generation = UUID(); pending = false; forceKeyframe = true
        if let session { VTCompressionSessionInvalidate(session) }; session = nil
    }
}
