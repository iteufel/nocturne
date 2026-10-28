import Foundation
import NocturneKit

public protocol SimulatorBackend: Sendable {
    func devices() async throws -> [RemoteSimulator]
    func frame(device: String) async throws -> SimulatorFrame
}

/// Bounded pull channel: at most one capture per lease and two leases per host.
/// A lease belongs to a workspace connection, not just a paired device identity.
public actor SimulatorSessionManager {
    private struct Lease {
        let owner: UUID
        let device: String
        var touched: Date
        var capture: Task<SimulatorFrame, Error>?
        var lastCapture: Date?
    }
    private let backend: any SimulatorBackend
    private let now: @Sendable () -> Date
    private var leases: [String: Lease] = [:]
    private var listing: (id: UUID, owner: UUID, task: Task<[RemoteSimulator], Error>)?
    public init(backend: any SimulatorBackend, now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend; self.now = now
    }
    public func handle(_ packet: Packet, connection: UUID, isConnected: @Sendable () -> Bool = { true }) async throws -> Packet {
        expire()
        guard isConnected() else { throw NocturneError.disconnected }
        var reply = packet.reply()
        switch packet.operation {
        case .simulatorList, .simulatorOpen:
            guard listing == nil else { throw NocturneError.remote("Simulator discovery is already running.") }
            let backend = backend, discoveryID = UUID()
            let discovery = Task { try await backend.devices() }
            listing = (discoveryID, connection, discovery)
            let devices: [RemoteSimulator]
            do {
                devices = try await discovery.value
                guard listing?.id == discoveryID else { throw NocturneError.disconnected }
                listing = nil
            } catch {
                if listing?.id == discoveryID { listing = nil }
                throw error
            }
            guard isConnected() else { throw NocturneError.disconnected }
            guard devices.count <= SimulatorStreaming.maximumDevices,
                  Set(devices.map(\.id)).count == devices.count,
                  devices.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.name.utf8.count <= 512 && $0.runtime.utf8.count <= 512 }) else { throw NocturneError.invalidFrame }
            if packet.operation == .simulatorList { reply.simulators = devices; return reply }
            guard let id = packet.simulatorID, let device = devices.first(where: { $0.id == id }), device.isBooted else {
                throw NocturneError.remote("Start this iOS simulator in Xcode on your Mac first.")
            }
            guard leases.count < 2, !leases.values.contains(where: { $0.owner == connection }) else {
                throw NocturneError.remote("Stop the current simulator preview first.")
            }
            let idLease = UUID().uuidString
            leases[idLease] = Lease(owner: connection, device: id, touched: now())
            reply.sessionID = idLease; reply.simulatorID = id
        case .simulatorFrame:
            guard let id = packet.sessionID, let lease = leases[id], lease.owner == connection else { throw NocturneError.permissionDenied }
            guard lease.capture == nil else { throw NocturneError.remote("Wait for the current simulator frame.") }
            if let last = lease.lastCapture, now().timeIntervalSince(last) < 0.5 {
                throw NocturneError.remote("Simulator previews are limited to two frames per second.")
            }
            let backend = backend
            let capture = Task { try await backend.frame(device: lease.device) }
            leases[id]?.capture = capture; leases[id]?.touched = now(); leases[id]?.lastCapture = now()
            do {
                let frame = try await capture.value
                guard isConnected(), leases[id]?.owner == connection else { throw NocturneError.disconnected }
                guard frame.isValid else { throw NocturneError.invalidFrame }
                leases[id]?.capture = nil; leases[id]?.touched = now()
                reply.sessionID = id; reply.simulatorID = lease.device; reply.simulatorFrame = frame
            } catch {
                leases.removeValue(forKey: id)?.capture?.cancel()
                throw error
            }
        case .simulatorClose:
            guard let id = packet.sessionID else { throw NocturneError.invalidFrame }
            if let lease = leases[id] {
                guard lease.owner == connection else { throw NocturneError.permissionDenied }
                leases.removeValue(forKey: id)?.capture?.cancel()
            }
        case .simulatorInput:
            throw NocturneError.remote("Simulator touch input is unavailable: no supported host input backend is configured.")
        default: throw NocturneError.invalidFrame
        }
        return reply
    }
    public func disconnected(_ connection: UUID) {
        if listing?.owner == connection { listing?.task.cancel(); listing = nil }
        for id in leases.keys.filter({ leases[$0]?.owner == connection }) { leases.removeValue(forKey: id)?.capture?.cancel() }
    }
    public func expire() {
        for id in leases.keys.filter({ now().timeIntervalSince(leases[$0]!.touched) > SimulatorStreaming.leaseDuration }) {
            leases.removeValue(forKey: id)?.capture?.cancel()
        }
    }
    public func stop() {
        listing?.task.cancel(); listing = nil
        leases.values.forEach { $0.capture?.cancel() }; leases.removeAll()
    }
}
