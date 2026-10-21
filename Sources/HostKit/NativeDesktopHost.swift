import AppKit
import ScreenCaptureKit
import AVFoundation
import NocturneKit

@MainActor
public final class NativeDesktopHost: DesktopHosting {
    public init() {}
    public func displays() async throws -> [RemoteDesktopDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.map { display in
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
            return RemoteDesktopDisplay(id: display.displayID, name: screen?.localizedName ?? "Display",
                width: display.width, height: display.height, isMain: display.displayID == CGMainDisplayID())
        }.sorted { $0.isMain && !$1.isMain }
    }
    public func capture(displayID: UInt32?, viewport: AppWindowViewport,
                        send: @escaping AppWindowSend, ended: @escaping (Error) -> Void) async throws -> DesktopCapture {
        guard CGPreflightScreenCaptureAccess() else {
            throw NocturneError.remote("Allow Nocturne Server in Screen & System Audio Recording on the host Mac, then reopen the app.")
        }
        guard AXIsProcessTrusted() else {
            throw NocturneError.remote("Allow Nocturne Server in Accessibility on the host Mac to control its desktop.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == (displayID ?? CGMainDisplayID()) }) else {
            throw NocturneError.remote("This display is no longer connected. Refresh the host’s displays and try again.")
        }
        let capture = NativeDesktopCapture(source: display, send: send, ended: ended)
        do { try await capture.start(viewport); return capture }
        catch { capture.stop(); throw error }
    }
}

@MainActor
private final class NativeDesktopCapture: NSObject, DesktopCapture, SCStreamOutput, SCStreamDelegate {
    let displayID: UInt32
    private(set) var display = StreamDisplaySize(width: 1920, height: 1080, frameRate: 60)
    private let source: SCDisplay
    private let encoder: AppWindowVideoEncoder
    private let audio: DesktopAudioSender
    private let ended: (Error) -> Void
    private var stream: SCStream?
    private var stopped = false
    private var events = AppWindowEventState()
    init(source: SCDisplay, send: @escaping AppWindowSend, ended: @escaping (Error) -> Void) {
        self.source = source; displayID = source.displayID; self.ended = ended
        encoder = AppWindowVideoEncoder(send: { packet, completion in
            var packet = packet; packet.operation = .desktopVideo; send(packet, completion)
        })
        audio = DesktopAudioSender(send: send)
        super.init()
    }
    private func configuration(_ viewport: AppWindowViewport) throws -> SCStreamConfiguration {
        guard !stopped, viewport.isValid, source.width > 0, source.height > 0,
              let bounds = viewport.pixels(width: Double(viewport.width), height: Double(viewport.height)) else { throw NocturneError.invalidFrame }
        // Fit the source aspect ratio inside the requested pixel budget. Resizing
        // a viewer never changes the host's physical display resolution or layout.
        let factor = min(Double(bounds.width) / Double(source.width), Double(bounds.height) / Double(source.height))
        display = StreamDisplaySize(width: max(2, Int(Double(source.width) * factor / 2) * 2),
            height: max(2, Int(Double(source.height) * factor / 2) * 2), frameRate: viewport.frameRate)
        let configuration = SCStreamConfiguration()
        configuration.width = display.width; configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(display.frameRate))
        configuration.queueDepth = 3; configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.scalesToFit = true; configuration.capturesAudio = true
        // A Mac can host and view simultaneously without feeding its incoming
        // Nocturne audio back into the outgoing desktop stream.
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = DesktopStreaming.audioSampleRate
        configuration.channelCount = DesktopStreaming.audioChannels
        try encoder.configure(display)
        return configuration
    }
    func start(_ viewport: AppWindowViewport) async throws {
        let configuration = try configuration(viewport)
        let stream = SCStream(filter: SCContentFilter(display: source, excludingWindows: []), configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: encoder.queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audio.queue)
        try await stream.startCapture()
        guard !stopped else { try? await stream.stopCapture(); throw NocturneError.disconnected }
    }
    func resize(_ viewport: AppWindowViewport) async throws {
        guard !stopped, let stream else { throw NocturneError.disconnected }
        try await stream.updateConfiguration(configuration(viewport))
        guard !stopped else { throw NocturneError.disconnected }
    }
    func input(_ input: AppWindowInput) throws {
        guard !stopped, CGDisplayIsActive(displayID) != 0 else { throw NocturneError.disconnected }
        guard AXIsProcessTrusted() else { throw NocturneError.permissionDenied }
        for event in events.events(for: input, frame: CGDisplayBounds(displayID), windowID: nil) { event.post(tap: .cghidEventTap) }
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        for event in events.release(windowID: nil) { event.post(tap: .cghidEventTap) }
        encoder.stop(); audio.stop()
        if let stream { self.stream = nil; Task { try? await stream.stopCapture() } }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { encoder.encode(sampleBuffer) }
        else if type == .audio { audio.encode(sampleBuffer) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.stop(); self.ended(error)
        }
    }
}

/// Backpressure is independent of video encoding. At most one audio buffer waits
/// for the socket; a slow viewer drops fresh samples instead of accumulating lag.
private final class DesktopAudioSender: @unchecked Sendable {
    let queue = DispatchQueue(label: "nocturne.desktop-audio", qos: .userInteractive)
    private let send: AppWindowSend
    private var pending = false
    private var stopped = false
    init(send: @escaping AppWindowSend) { self.send = send }
    func encode(_ sample: CMSampleBuffer) {
        guard !stopped, !pending, let description = CMSampleBufferGetFormatDescription(sample),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2,
              format.mSampleRate == Double(DesktopStreaming.audioSampleRate) else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard (1...DesktopStreaming.maximumAudioFrames).contains(frames) else { return }
        let size = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retained) == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var data = Data(count: frames * 2 * MemoryLayout<Float>.size)
        if buffers.count == 1, let bytes = buffers[0].mData, buffers[0].mDataByteSize == data.count {
            data = Data(bytes: bytes, count: data.count)
        } else if buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData,
                  buffers.allSatisfy({ $0.mDataByteSize == frames * MemoryLayout<Float>.size }) {
            data.withUnsafeMutableBytes { raw in
                let output = raw.bindMemory(to: Float.self)
                let a = left.assumingMemoryBound(to: Float.self), b = right.assumingMemoryBound(to: Float.self)
                for index in 0..<frames { output[index * 2] = a[index]; output[index * 2 + 1] = b[index] }
            }
        } else { return }
        var packet = Packet(.desktopAudio); packet.audio = DesktopAudioFrame(data: data, frames: frames)
        pending = true
        send(packet) { [weak self] _ in
            guard let self else { return }; self.queue.async { self.pending = false }
        }
    }
    func stop() { queue.sync { stopped = true } }
}
