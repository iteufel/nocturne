import Foundation
import NocturneKit
import DisplayBridge

@MainActor
protocol StreamingDisplayDriver: AnyObject {
    @discardableResult func start() async throws -> UInt32
    @discardableResult func apply(_ size: StreamDisplaySize, disablePhysicalDisplays: Bool) async throws -> UInt32
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
    private var configurationDeadline: Date?
    private var expiryTask: Task<Void, Never>?
    private let driver: StreamingDisplayDriver
    private let timeout: TimeInterval
    private let prepareCapture: (UInt32) async throws -> Void
    public convenience init(prepareCapture: @escaping (UInt32) async throws -> Void) {
        self.init(driver: ProcessStreamingDisplayDriver(), timeout: 20, prepareCapture: prepareCapture)
    }
    init(driver: StreamingDisplayDriver, timeout: TimeInterval, prepareCapture: @escaping (UInt32) async throws -> Void = { _ in }) {
        self.driver = driver; self.timeout = timeout; self.prepareCapture = prepareCapture
    }
    public func start() async throws -> UInt32 {
        let display = try await driver.start()
        guard display != 0 else { throw NocturneError.remote("The virtual monitor did not become available.") }
        lastError = nil; return display
    }
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
            configurationDeadline = now.addingTimeInterval(50)
            scheduleExpiry()
            defer { configuring = false }
            do {
                let display = try await driver.apply(requested, disablePhysicalDisplays: disablePhysicalDisplays)
                guard display != 0 else { throw NocturneError.invalidFrame }
                guard revision == epoch else { throw NocturneError.disconnected }
                // The new framebuffer has a new ID. Do not acknowledge a resize
                // until the video engine is ready to capture that exact display.
                try await prepareCapture(display)
                guard revision == epoch else { throw NocturneError.disconnected }
                configurationDeadline = nil; lease?.renewed = Date(); scheduleExpiry()
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
        if let lease, now >= (configurationDeadline ?? lease.renewed.addingTimeInterval(timeout)) { release() }
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
        lease = nil; configurationDeadline = nil; size = nil; deviceName = nil
        do { try driver.restore(); lastError = nil } catch { lastError = error.localizedDescription }
        onChange?()
    }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let lease else { return }
        let deadline = configurationDeadline ?? lease.renewed.addingTimeInterval(timeout)
        let delay = UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            self?.expire()
        }
    }
}

// Keep native display lifecycle testable without touching WindowServer.
@MainActor
protocol StreamingVirtualDisplay: AnyObject {
    var displayID: UInt32 { get }
    func selectRequestedMode() throws
}
extension NDVirtualDisplay: StreamingVirtualDisplay {}

@MainActor
protocol StreamingDisplayLayout: AnyObject {
    func makePrimary(_ display: UInt32, disableOthers: Bool) throws
    func restore() throws
}
extension NDDisplayLayout: StreamingDisplayLayout {}

@MainActor
struct StreamingDisplayEnvironment {
    var isSessionAvailable: () -> Bool
    var create: (StreamDisplaySize) throws -> StreamingVirtualDisplay
    var captureLayout: (UInt32) -> StreamingDisplayLayout
    static var native: Self {
        .init(isSessionAvailable: { NDDisplayLayout.isSessionAvailable() }, create: {
            try NDVirtualDisplay(width: UInt($0.width), height: UInt($0.height), refreshRate: UInt($0.frameRate))
        }, captureLayout: { NDDisplayLayout(excludingDisplay: $0) })
    }
}

@MainActor
final class NativeStreamingDisplayDriver: StreamingDisplayDriver {
    private let environment: StreamingDisplayEnvironment
    private var display: StreamingVirtualDisplay?
    private var layout: StreamingDisplayLayout?
    private var size: StreamDisplaySize?
    private var revision = UUID()
    convenience init() { self.init(environment: .native) }
    init(environment: StreamingDisplayEnvironment) { self.environment = environment }
    @discardableResult func start() async throws -> UInt32 {
        // Always create the selected virtual monitor, even with physical monitors
        // attached. The engine probes this exact display before accepting streams.
        try await apply(size ?? .init(width: 1920, height: 1080, frameRate: 60), disablePhysicalDisplays: false)
    }
    @discardableResult func apply(_ requested: StreamDisplaySize, disablePhysicalDisplays: Bool) async throws -> UInt32 {
        guard environment.isSessionAvailable() else { throw NocturneError.remote("Unlock this Mac before starting its streaming display.") }
        guard requested.isValid else { throw NocturneError.invalidFrame }
        let epoch = UUID(); revision = epoch
        // The default mode never rearranges, mirrors, resizes, or disables a
        // physical display. Capture targets the virtual ID instead of main.
        if disablePhysicalDisplays, layout == nil { layout = environment.captureLayout(display?.displayID ?? 0) }
        let replacement: StreamingVirtualDisplay
        if let display, size == requested { replacement = display }
        else { replacement = try environment.create(requested) }
        try await settle(replacement, revision: epoch)
        if disablePhysicalDisplays { try layout?.makePrimary(replacement.displayID, disableOthers: true) }
        display = replacement; size = requested
        return replacement.displayID
    }
    func restore() throws {
        revision = UUID()
        try layout?.restore()
        layout = nil
        // Keep the engine's capture target alive between streams. Only Stop
        // destroys it, after physical displays have been restored.
    }
    func stop() throws { try restore(); display = nil; size = nil }
    private func settle(_ display: StreamingVirtualDisplay, revision epoch: UUID) async throws {
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
