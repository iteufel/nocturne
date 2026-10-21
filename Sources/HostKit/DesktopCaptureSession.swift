import Foundation
import NocturneKit

struct DesktopCaptureTarget: Equatable {
    let displayID: UInt32
    let locked: Bool
}

/// Keep the requested desktop across lock-screen and display changes. The media
/// source is replaceable; the authenticated control lease stays with the viewer.
@MainActor
final class DesktopCaptureSession: DesktopCapture {
    typealias Start = (DesktopCaptureTarget, AppWindowViewport, @escaping (Error) -> Void) async throws -> DesktopCapture
    private let target: () throws -> DesktopCaptureTarget
    private let start: Start
    private let ended: (Error) -> Void
    private var viewport: AppWindowViewport
    private var applied: AppWindowViewport?
    private var current: DesktopCaptureTarget?
    private var capture: DesktopCapture?
    private var updating: Task<Void, Error>?
    private var monitor: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    var display: StreamDisplaySize { capture?.display ?? .init(width: 1920, height: 1080, frameRate: 60) }
    var displayID: UInt32 { capture?.displayID ?? current?.displayID ?? 0 }
    var screenLocked: Bool { current?.locked ?? false }

    init(viewport: AppWindowViewport, target: @escaping () throws -> DesktopCaptureTarget,
         start: @escaping Start, ended: @escaping (Error) -> Void) {
        self.viewport = viewport; self.target = target; self.start = start; self.ended = ended
    }
    static func target(requested: UInt32, main: UInt32, locked: Bool, available: Bool) throws -> DesktopCaptureTarget {
        guard available else { throw NocturneError.remote("Sign in to the host Mac before connecting to its desktop.") }
        return DesktopCaptureTarget(displayID: locked && main != 0 ? main : requested, locked: locked)
    }
    func begin(monitorChanges: Bool = true) async throws {
        try await refresh()
        guard monitorChanges else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, !self.stopped else { return }
                    try await self.refresh()
                } catch {
                    guard let self, !self.stopped, !Task.isCancelled else { return }
                    self.stop(); self.ended(error); return
                }
            }
        }
    }
    func refresh() async throws {
        guard !stopped else { throw NocturneError.disconnected }
        if let updating { try await updating.value; return }
        let task = Task { @MainActor in
            while !self.stopped {
                let next = try self.target(), viewport = self.viewport
                if next != self.current {
                    self.generation = UUID()
                    let generation = self.generation
                    self.capture?.stop(); self.capture = nil
                    let capture = try await self.start(next, viewport, { [weak owner = self] error in
                        Task { @MainActor in
                            guard let self = owner, !self.stopped, self.generation == generation else { return }
                            // A system stop can arrive before the polling timer
                            // observes the lock. Give the new target a chance.
                            do {
                                if try self.target() != next { try await self.refresh(); return }
                            } catch { self.stop(); self.ended(error); return }
                            self.stop(); self.ended(error)
                        }
                    })
                    guard !self.stopped, self.generation == generation else { capture.stop(); throw NocturneError.disconnected }
                    self.capture = capture; self.current = next; self.applied = viewport
                } else if self.applied != viewport {
                    try await self.capture?.resize(viewport); self.applied = viewport
                } else { return }
            }
            throw NocturneError.disconnected
        }
        updating = task
        defer { updating = nil }
        try await task.value
    }
    func resize(_ viewport: AppWindowViewport) async throws { self.viewport = viewport; try await refresh() }
    func input(_ input: AppWindowInput) throws {
        guard !stopped, let capture else { return }
        // Drop input during a target transition instead of sending a click or
        // password keystroke using the previous display's coordinates.
        guard try target() == current else { return }
        try capture.input(input)
    }
    func stop() {
        guard !stopped else { return }; stopped = true; generation = UUID()
        monitor?.cancel(); monitor = nil; updating?.cancel()
        capture?.stop(); capture = nil
    }
}
