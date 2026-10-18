import Foundation
import NocturneKit
import DisplayBridge

@MainActor
protocol StreamingDisplayDriver: AnyObject {
    func start() async throws
    func apply(_ size: StreamDisplaySize, disablePhysicalDisplays: Bool) async throws
    func restore() throws
    func stop() throws
}

/// One authenticated connection owns display control. A missing heartbeat, socket
/// closure, revoked device, server stop, or failed configuration releases it.
@MainActor
public final class DisplaySessionManager {
    public static var isSupported: Bool { NDVirtualDisplay.isSupported() }
    public static var canDisableDisplays: Bool { NDDisplayLayout.canDisableDisplays() }
    public static var isSessionAvailable: Bool { NDDisplayLayout.isSessionAvailable() }
    public var onChange: (() -> Void)?
    public private(set) var size: StreamDisplaySize?
    public private(set) var deviceName: String?
    public private(set) var lastError: String?
    public var isActive: Bool { lease != nil }
    public var disablePhysicalDisplays = false
    private struct Lease {
        let connection: UUID
        let id: String
        var renewed: Date
    }
    private var lease: Lease?
    private var revision = UUID()
    private var configuring = false
    private var expiryTask: Task<Void, Never>?
    private let driver: StreamingDisplayDriver
    private let timeout: TimeInterval
    public convenience init() { self.init(driver: ProcessStreamingDisplayDriver(), timeout: 20) }
    init(driver: StreamingDisplayDriver, timeout: TimeInterval) { self.driver = driver; self.timeout = timeout }
    public func start() async throws { try await driver.start(); lastError = nil }
    public func handle(_ packet: Packet, connection: UUID, name: String, now: Date = Date()) async throws -> Packet {
        guard let id = packet.sessionID, UUID(uuidString: id) != nil else { throw NocturneError.invalidFrame }
        var reply = packet.reply()
        switch packet.operation {
        case .displayPrepare:
            guard let requested = packet.display, requested.isValid else { throw NocturneError.invalidFrame }
            guard !configuring else { throw NocturneError.remote("The display is still being configured. Try again in a moment.") }
            if let lease, lease.connection != connection || lease.id != id {
                throw NocturneError.remote("Another device is using Nocturne Display. Disconnect its stream first.")
            }
            let epoch = UUID(); revision = epoch; configuring = true
            lease = Lease(connection: connection, id: id, renewed: now)
            scheduleExpiry()
            defer { configuring = false }
            do {
                try await driver.apply(requested, disablePhysicalDisplays: disablePhysicalDisplays)
                guard revision == epoch else { throw NocturneError.disconnected }
                size = requested; deviceName = name; lastError = nil
                reply.display = requested; reply.sessionID = id; onChange?()
            } catch {
                if revision == epoch { release() }; throw error
            }
        case .displayHeartbeat, .displayRelease:
            guard lease?.connection == connection, lease?.id == id else { throw NocturneError.permissionDenied }
            if packet.operation == .displayRelease { release() }
            else { lease?.renewed = now; scheduleExpiry() }
        default: throw NocturneError.invalidFrame
        }
        return reply
    }
    public func disconnected(_ connection: UUID) { if lease?.connection == connection { release() } }
    public func expire(now: Date = Date()) {
        if let lease, now.timeIntervalSince(lease.renewed) >= timeout { release() }
    }
    public func restore() { release() }
    public func stop() {
        release()
        do { try driver.stop() } catch { lastError = error.localizedDescription }
        onChange?()
    }
    private func release() {
        revision = UUID()
        expiryTask?.cancel(); expiryTask = nil
        lease = nil; size = nil; deviceName = nil
        do { try driver.restore(); lastError = nil } catch { lastError = error.localizedDescription }
        onChange?()
    }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        let delay = UInt64(timeout * 1_000_000_000)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            self?.expire()
        }
    }
}

@MainActor
final class NativeStreamingDisplayDriver: StreamingDisplayDriver {
    private var display: NDVirtualDisplay?
    private var layout: NDDisplayLayout?
    private var size: StreamDisplaySize?
    private var revision = UUID()
    func start() async throws {
        guard NDDisplayLayout.isSessionAvailable() else { throw NocturneError.remote("Unlock this Mac before starting its streaming display.") }
        // The streaming engine probes capture when starting. Supply a real display
        // first when the Mac has no active monitor (including a closed-lid Mac).
        if !NDDisplayLayout.hasActiveDisplayOtherThan(0) {
            display = try NDVirtualDisplay(width: 1920, height: 1080, refreshRate: 60)
            size = .init(width: 1920, height: 1080, frameRate: 60)
            if let display { try await settle(display, revision: revision) }
        }
    }
    func apply(_ requested: StreamDisplaySize, disablePhysicalDisplays: Bool) async throws {
        let epoch = UUID(); revision = epoch
        if layout == nil { layout = NDDisplayLayout(excludingDisplay: display?.displayID ?? 0) }
        let replacement: NDVirtualDisplay
        if let display, size == requested { replacement = display }
        else { replacement = try NDVirtualDisplay(width: UInt(requested.width), height: UInt(requested.height), refreshRate: UInt(requested.frameRate)) }
        try await settle(replacement, revision: epoch)
        try layout?.makePrimary(replacement.displayID, disableOthers: disablePhysicalDisplays)
        // Switch the primary display before releasing the previous framebuffer.
        // macOS moves its windows onto the replacement, including when headless.
        display = replacement; size = requested
    }
    func restore() throws {
        revision = UUID()
        try layout?.restore()
        layout = nil
        if let display, NDDisplayLayout.hasActiveDisplayOtherThan(display.displayID) { self.display = nil; size = nil }
    }
    func stop() throws { try restore(); display = nil; size = nil }
    private func settle(_ display: NDVirtualDisplay, revision epoch: UUID) async throws {
        var failure: Error = NocturneError.timeout
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard revision == epoch else { throw NocturneError.disconnected }
            do { try display.selectRequestedMode(); return } catch { failure = error }
            // WindowServer publishes a new mode list asynchronously. Yield the main
            // actor so disconnect/Stop can restore displays while it is settling.
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw failure
    }
}
