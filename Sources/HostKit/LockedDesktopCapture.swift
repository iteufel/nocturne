import AppKit
@preconcurrency import AVFoundation
import NocturneKit

/// loginwindow capture uses the same AVFoundation screen source as the embedded
/// streaming engine. It does not depend on a shareable app/window catalog.
@MainActor
final class LockedDesktopCapture: NSObject, DesktopCapture, AVCaptureVideoDataOutputSampleBufferDelegate {
    let displayID: UInt32
    private(set) var display = StreamDisplaySize(width: 1920, height: 1080, frameRate: 60)
    private let encoder: AppWindowVideoEncoder
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "nocturne.locked-desktop")
    private var events = AppWindowEventState()
    private var stopped = false
    init(displayID: UInt32, send: @escaping AppWindowSend) {
        self.displayID = displayID
        encoder = AppWindowVideoEncoder(send: { packet, completion in
            var packet = packet; packet.operation = .desktopVideo; send(packet, completion)
        })
        super.init()
    }
    func start(_ viewport: AppWindowViewport) async throws {
        guard !stopped, viewport.isValid, CGDisplayIsActive(displayID) != 0,
              let budget = viewport.pixels(width: Double(viewport.width), height: Double(viewport.height)),
              let input = AVCaptureScreenInput(displayID: displayID) else { throw NocturneError.disconnected }
        let width = Double(CGDisplayPixelsWide(displayID)), height = Double(CGDisplayPixelsHigh(displayID))
        guard width > 0, height > 0 else { throw NocturneError.disconnected }
        let factor = min(Double(budget.width) / width, Double(budget.height) / height)
        display = .init(width: max(2, Int(width * factor / 2) * 2), height: max(2, Int(height * factor / 2) * 2), frameRate: viewport.frameRate)
        input.minFrameDuration = CMTime(value: 1, timescale: CMTimeScale(display.frameRate))
        input.capturesCursor = true
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: display.width, kCVPixelBufferHeightKey as String: display.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect]
        output.setSampleBufferDelegate(self, queue: encoder.queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NocturneError.remote("The Mac could not capture its lock screen. Check Screen Recording permission, then reconnect.")
        }
        session.addInput(input); session.addOutput(output)
        try encoder.configure(display)
        let session = session
        await withCheckedContinuation { continuation in
            queue.async { session.startRunning(); continuation.resume() }
        }
        guard !stopped, session.isRunning else { throw NocturneError.disconnected }
    }
    func resize(_ viewport: AppWindowViewport) {
        // Keep login capture stable while credentials are being entered. The
        // viewer fits this image; unlock restores ordinary adaptive encoding.
    }
    func input(_ input: AppWindowInput) throws {
        guard !stopped, AXIsProcessTrusted(), CGDisplayIsActive(displayID) != 0 else { throw NocturneError.permissionDenied }
        for event in events.events(for: input, frame: CGDisplayBounds(displayID), windowID: nil) { event.post(tap: .cghidEventTap) }
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        for event in events.release(windowID: nil) { event.post(tap: .cghidEventTap) }
        encoder.stop()
        let session = session
        queue.async { session.stopRunning() }
    }
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        encoder.encode(sampleBuffer, requiresScreenStatus: false)
    }
}
