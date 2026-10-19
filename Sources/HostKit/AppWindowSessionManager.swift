import Foundation
import NocturneKit

public typealias AppWindowSend = (Packet, @escaping (Error?) -> Void) -> Void

@MainActor
public protocol AppWindowCapture: AnyObject {
    var window: RemoteAppWindow { get }
    var display: StreamDisplaySize { get }
    func resize(_ viewport: AppWindowViewport) async throws
    func input(_ input: AppWindowInput) async throws
    func stop()
}

@MainActor
public protocol AppWindowHosting: AnyObject {
    func applications() throws -> [RemoteApplication]
    func icon(applicationID: String) throws -> Data
    func windows(applicationID: String?) async throws -> [RemoteAppWindow]
    func launch(applicationID: String) async throws -> [RemoteAppWindow]
    func capture(applicationID: String, windowID: UInt32, viewport: AppWindowViewport,
                 send: @escaping AppWindowSend, ended: @escaping (Error) -> Void) async throws -> AppWindowCapture
}

/// Every capture and input lease belongs to one authenticated socket. Reserving a
/// window before awaiting capture prevents duplicate opens and disconnect races.
@MainActor
public final class AppWindowSessionManager {
    private struct Lease {
        let id: String
        let connection: UUID
        let device: String
        let windowID: UInt32
        let send: AppWindowSend
        var touched: TimeInterval
        var capture: AppWindowCapture?
        var resizing = false
    }
    private let host: AppWindowHosting
    private let now: () -> TimeInterval
    private var leases: [UUID: Lease] = [:]
    public init(host: AppWindowHosting, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.host = host; self.now = now
    }
    public func handle(_ packet: Packet, connection: UUID, device: String, isConnected: () -> Bool = { true }, send: @escaping AppWindowSend) async throws -> Packet {
        expire()
        guard isConnected() else { throw NocturneError.disconnected }
        var reply = packet.reply()
        switch packet.operation {
        case .appList:
            // Page the catalog so even large installations remain below the frame limit.
            let apps = try host.applications()
            let offset = packet.offset ?? 0
            guard offset >= 0, offset <= apps.count else { throw NocturneError.invalidFrame }
            let end = min(apps.count, Int(offset) + 64)
            reply.applications = Array(apps[Int(offset)..<end]); reply.offset = Int64(end); reply.eof = end == apps.count
            if offset == 0 { reply.windows = try await host.windows(applicationID: nil) }
        case .appIcon:
            guard let id = packet.applicationID else { throw NocturneError.invalidFrame }
            reply.data = try host.icon(applicationID: id)
        case .appLaunch:
            guard let id = packet.applicationID else { throw NocturneError.invalidFrame }
            reply.windows = try await host.launch(applicationID: id)
        case .appOpen:
            guard leases[connection] == nil, let id = packet.sessionID, UUID(uuidString: id) != nil,
                  let app = packet.applicationID, let window = packet.windowID,
                  let viewport = packet.viewport, viewport.isValid else { throw NocturneError.invalidFrame }
            guard leases.count < AppStreaming.maximumWindows,
                  leases.values.filter({ $0.device == device }).count < AppStreaming.maximumWindowsPerDevice else {
                throw NocturneError.remote("Close an app stream before opening another window.")
            }
            guard !leases.values.contains(where: { $0.windowID == window }) else {
                throw NocturneError.remote("This Mac window is already streaming. Choose another window of the app.")
            }
            leases[connection] = Lease(id: id, connection: connection, device: device, windowID: window, send: send, touched: now())
            do {
                let capture = try await host.capture(applicationID: app, windowID: window, viewport: viewport, send: { frame, completion in
                    var frame = frame; frame.sessionID = id; send(frame, completion)
                }, ended: { [weak self] error in
                    self?.end(connection, session: id, error: error)
                })
                guard leases[connection]?.id == id, isConnected() else {
                    capture.stop(); throw NocturneError.disconnected
                }
                leases[connection]?.capture = capture
                leases[connection]?.touched = now()
                reply.sessionID = id; reply.window = capture.window; reply.display = capture.display
            } catch {
                if leases[connection]?.id == id { release(connection) }
                throw error
            }
        case .appResize, .appInput, .appHeartbeat:
            guard let lease = leases[connection], packet.sessionID == lease.id,
                  let capture = lease.capture else { throw NocturneError.permissionDenied }
            leases[connection]?.touched = now()
            if packet.operation == .appResize {
                guard let viewport = packet.viewport, viewport.isValid, !lease.resizing else { throw NocturneError.invalidFrame }
                leases[connection]?.resizing = true
                defer { if leases[connection]?.id == lease.id { leases[connection]?.resizing = false } }
                do { try await capture.resize(viewport) }
                catch { end(connection, session: lease.id, error: error); throw error }
                guard leases[connection]?.id == lease.id else { throw NocturneError.disconnected }
                reply.window = capture.window; reply.display = capture.display
            } else if packet.operation == .appInput {
                guard let input = packet.input, input.isValid else { throw NocturneError.invalidFrame }
                try await capture.input(input)
            }
            reply.sessionID = lease.id
        case .appClose:
            if let lease = leases[connection], packet.sessionID == lease.id { release(connection) }
            reply.sessionID = packet.sessionID
        default: throw NocturneError.invalidFrame
        }
        guard isConnected() else { throw NocturneError.disconnected }
        return reply
    }
    public func disconnected(_ connection: UUID) {
        // Pending appOpen operations must not acquire a capture after this socket closes.
        release(connection)
    }
    public func expire() {
        for (connection, lease) in leases where now() - lease.touched >= AppStreaming.heartbeatTimeout {
            end(connection, session: lease.id, error: NocturneError.remote("The app window connection expired. Reconnect to continue."))
        }
    }
    public func stop() {
        for connection in Array(leases.keys) { release(connection) }
    }
    private func release(_ connection: UUID) { leases.removeValue(forKey: connection)?.capture?.stop() }
    private func end(_ connection: UUID, session: String, error: Error) {
        guard let lease = leases[connection], lease.id == session else { return }
        release(connection)
        var event = Packet(.appEnded); event.sessionID = session; event.error = error.localizedDescription
        lease.send(event) { _ in }
    }
}
