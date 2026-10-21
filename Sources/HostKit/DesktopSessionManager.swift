import Foundation
import NocturneKit

@MainActor
public protocol DesktopCapture: AnyObject {
    var display: StreamDisplaySize { get }
    var displayID: UInt32 { get }
    var screenLocked: Bool { get }
    func resize(_ viewport: AppWindowViewport) async throws
    func input(_ input: AppWindowInput) throws
    func stop()
}

public extension DesktopCapture {
    var screenLocked: Bool { false }
}

@MainActor
public protocol DesktopHosting: AnyObject {
    func displays() async throws -> [RemoteDesktopDisplay]
    func capture(displayID: UInt32?, viewport: AppWindowViewport,
                 send: @escaping AppWindowSend, ended: @escaping (Error) -> Void) async throws -> DesktopCapture
}

/// Desktop input is global. Reserve a single control lease before awaiting
/// capture, and bind every command to its authenticated connection and session.
@MainActor
public final class DesktopSessionManager {
    private struct Lease {
        let id: String
        let connection: UUID
        let send: AppWindowSend
        var touched: TimeInterval
        var capture: DesktopCapture?
        var resizing = false
    }
    private let host: DesktopHosting
    private let now: () -> TimeInterval
    private var lease: Lease?
    public init(host: DesktopHosting, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.host = host; self.now = now
    }
    public func handle(_ packet: Packet, connection: UUID, isConnected: () -> Bool = { true },
                       send: @escaping AppWindowSend) async throws -> Packet {
        expire()
        guard isConnected() else { throw NocturneError.disconnected }
        var reply = packet.reply()
        switch packet.operation {
        case .desktopList:
            reply.displays = try await host.displays()
        case .desktopOpen:
            guard lease == nil else { throw NocturneError.remote("This Mac’s desktop is already in use. Disconnect the other Mac first.") }
            guard let id = packet.sessionID, UUID(uuidString: id) != nil,
                  let viewport = packet.viewport, viewport.isValid else { throw NocturneError.invalidFrame }
            lease = Lease(id: id, connection: connection, send: send, touched: now())
            do {
                let capture = try await host.capture(displayID: packet.displayID, viewport: viewport, send: { event, completion in
                    var event = event; event.sessionID = id; send(event, completion)
                }, ended: { [weak self] error in self?.end(connection, session: id, error: error) })
                guard lease?.id == id, lease?.connection == connection, isConnected() else {
                    capture.stop(); throw NocturneError.disconnected
                }
                lease?.capture = capture; lease?.touched = now()
                reply.sessionID = id; reply.display = capture.display; reply.displayID = capture.displayID; reply.screenLocked = capture.screenLocked
            } catch {
                if lease?.id == id, lease?.connection == connection { stop() }
                throw error
            }
        case .desktopResize, .desktopInput, .desktopHeartbeat, .desktopClose:
            guard let current = lease, current.connection == connection, current.id == packet.sessionID,
                  let capture = current.capture else { throw NocturneError.permissionDenied }
            lease?.touched = now(); reply.sessionID = current.id
            reply.display = capture.display; reply.displayID = capture.displayID; reply.screenLocked = capture.screenLocked
            if packet.operation == .desktopClose { stop() }
            else if packet.operation == .desktopInput {
                guard let input = packet.input, input.isValid else { throw NocturneError.invalidFrame }
                try capture.input(input)
            } else if packet.operation == .desktopResize {
                guard let viewport = packet.viewport, viewport.isValid, !current.resizing else { throw NocturneError.invalidFrame }
                lease?.resizing = true
                defer { if lease?.id == current.id { lease?.resizing = false } }
                do { try await capture.resize(viewport) }
                catch { end(connection, session: current.id, error: error); throw error }
                guard lease?.id == current.id, lease?.connection == connection else { throw NocturneError.disconnected }
                reply.display = capture.display; reply.displayID = capture.displayID
            }
        default: throw NocturneError.invalidFrame
        }
        guard isConnected() else { throw NocturneError.disconnected }
        return reply
    }
    public func disconnected(_ connection: UUID) { if lease?.connection == connection { stop() } }
    public func expire() {
        if let lease, now() - lease.touched >= AppStreaming.heartbeatTimeout {
            end(lease.connection, session: lease.id, error: NocturneError.remote("The desktop connection expired. Reconnect to continue."))
        }
    }
    public func stop() { let capture = lease?.capture; lease = nil; capture?.stop() }
    private func end(_ connection: UUID, session: String, error: Error) {
        guard let current = lease, current.id == session, current.connection == connection else { return }
        stop()
        var event = Packet(.desktopEnded); event.sessionID = session; event.error = error.localizedDescription
        current.send(event) { _ in }
    }
}
