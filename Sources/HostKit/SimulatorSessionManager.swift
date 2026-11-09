import Foundation
import NocturneKit

public protocol SimulatorBackend: Sendable {
    var supportsInput: Bool { get }
    func devices() async throws -> [RemoteSimulator]
    func open(device: String, session: String) async throws
    func frame(device: String, session: String) async throws -> SimulatorFrame
    func input(_ touch: SimulatorTouch, device: String, session: String, geometry: SimulatorDisplayGeometry) async throws
    func cancelInput(session: String) async
    func close(session: String) async
}
public extension SimulatorBackend {
    var supportsInput: Bool { false }
    func open(device: String, session: String) async throws {}
    func input(_ touch: SimulatorTouch, device: String, session: String, geometry: SimulatorDisplayGeometry) async throws { throw NocturneError.permissionDenied }
    func cancelInput(session: String) async {}
    func close(session: String) async {}
}

/// Connection-owned display/control leases. Input is serialized, tied to a recent
/// frame, and released before a lease is closed or a different display is used.
public actor SimulatorSessionManager {
    private struct Reference {
        let revision: String
        let geometry: SimulatorDisplayGeometry
        let time: Date
    }
    private struct Contact {
        let geometry: SimulatorDisplayGeometry
        var touch: SimulatorTouch
        var time: Date
    }
    private struct Lease {
        let owner: UUID
        let device: String
        var touched: Date
        var opening: Task<Void, Error>?
        var capture: Task<SimulatorFrame, Error>?
        var input: Task<Void, Error>?
        var lastCapture: Date?
        var frames: [Reference] = []
        var contact: Contact?
    }
    public nonisolated let supportsInput: Bool
    private let backend: any SimulatorBackend
    private let now: @Sendable () -> Date
    private var leases: [String: Lease] = [:]
    private var listing: (id: UUID, owner: UUID, task: Task<[RemoteSimulator], Error>)?
    public init(backend: any SimulatorBackend, now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend; self.now = now; supportsInput = backend.supportsInput
    }
    public func handle(_ packet: Packet, connection: UUID, isConnected: @Sendable () -> Bool = { true }) async throws -> Packet {
        await expire()
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
            guard leases.count < 2, !leases.values.contains(where: { $0.owner == connection || (supportsInput && $0.device == id) }) else {
                throw NocturneError.remote("Stop the current simulator stream first. Only one connection can control a simulator.")
            }
            let session = UUID().uuidString
            let opening = Task { try await backend.open(device: id, session: session) }
            leases[session] = Lease(owner: connection, device: id, touched: now(), opening: opening)
            do {
                try await opening.value
                guard isConnected(), leases[session]?.owner == connection else { throw NocturneError.disconnected }
                leases[session]?.opening = nil
                reply.sessionID = session; reply.simulatorID = id
            } catch { await close(session); throw error }
        case .simulatorFrame:
            guard let id = packet.sessionID, let lease = leases[id], lease.owner == connection else { throw NocturneError.permissionDenied }
            guard lease.opening == nil, lease.capture == nil else { throw NocturneError.remote("Wait for the current simulator frame.") }
            if let last = lease.lastCapture, now().timeIntervalSince(last) < 0.5 {
                throw NocturneError.remote("Simulator previews are limited to two frames per second.")
            }
            let backend = backend
            let capture = Task { try await backend.frame(device: lease.device, session: id) }
            leases[id]?.capture = capture; leases[id]?.touched = now(); leases[id]?.lastCapture = now()
            do {
                let frame = try await capture.value
                guard isConnected(), leases[id]?.owner == connection else { throw NocturneError.disconnected }
                guard frame.isValid else { throw NocturneError.invalidFrame }
                leases[id]?.capture = nil; leases[id]?.touched = now()
                if let geometry = frame.geometry {
                    if let contact = leases[id]?.contact, contact.geometry != geometry {
                        leases[id]?.contact = nil
                        await backend.cancelInput(session: id)
                        guard isConnected(), leases[id]?.owner == connection else { throw NocturneError.disconnected }
                    }
                    var frames = leases[id]?.frames ?? []
                    frames = frames.filter { $0.geometry == geometry && now().timeIntervalSince($0.time) <= 2 }
                    frames.append(Reference(revision: frame.revision, geometry: geometry, time: now()))
                    leases[id]?.frames = Array(frames.suffix(4))
                } else {
                    leases[id]?.frames = []
                    if leases[id]?.contact != nil { leases[id]?.contact = nil; await backend.cancelInput(session: id) }
                }
                reply.sessionID = id; reply.simulatorID = lease.device; reply.simulatorFrame = frame
            } catch { await close(id); throw error }
        case .simulatorInput:
            guard let id = packet.sessionID, let lease = leases[id], lease.owner == connection else { throw NocturneError.permissionDenied }
            guard supportsInput, lease.opening == nil else { throw NocturneError.remote("Simulator touch input is unavailable on this host.") }
            guard lease.input == nil else { throw NocturneError.remote("Wait for the current simulator touch.") }
            guard let touch = packet.simulatorTouch, touch.isValid else { await cancelContact(id); throw NocturneError.invalidFrame }
            let geometry: SimulatorDisplayGeometry
            if touch.phase == .down {
                guard lease.contact == nil, touch.sequence == 0,
                      let frame = lease.frames.first(where: { $0.revision == touch.frameRevision && now().timeIntervalSince($0.time) <= 2 }) else {
                    await cancelContact(id); throw NocturneError.remote("This simulator frame is stale. Wait for the next frame and try again.")
                }
                geometry = frame.geometry
            } else {
                guard let contact = lease.contact, contact.touch.gestureID == touch.gestureID,
                      contact.touch.frameRevision == touch.frameRevision, touch.sequence == contact.touch.sequence + 1 else {
                    await cancelContact(id); throw NocturneError.invalidFrame
                }
                geometry = contact.geometry
            }
            let backend = backend
            let input = Task { try await backend.input(touch, device: lease.device, session: id, geometry: geometry) }
            leases[id]?.input = input
            leases[id]?.contact = (touch.phase == .up || touch.phase == .cancel) ? nil : Contact(geometry: geometry, touch: touch, time: now())
            leases[id]?.touched = now()
            do {
                try await input.value
                guard isConnected(), leases[id]?.owner == connection else { throw NocturneError.disconnected }
                leases[id]?.input = nil
            } catch { await close(id); throw error }
        case .simulatorClose:
            guard let id = packet.sessionID else { throw NocturneError.invalidFrame }
            if let lease = leases[id] {
                guard lease.owner == connection else { throw NocturneError.permissionDenied }
                await close(id)
            }
        default: throw NocturneError.invalidFrame
        }
        return reply
    }
    private func cancelContact(_ id: String) async {
        leases[id]?.contact = nil
        await backend.cancelInput(session: id)
    }
    private func close(_ id: String) async {
        let lease = leases.removeValue(forKey: id)
        lease?.opening?.cancel(); lease?.capture?.cancel(); lease?.input?.cancel()
        // A native open already running on its worker must settle before final
        // close, otherwise it could publish a connection after revocation.
        if let opening = lease?.opening { _ = await opening.result }
        await backend.close(session: id)
    }
    public func disconnected(_ connection: UUID) async {
        if listing?.owner == connection { listing?.task.cancel(); listing = nil }
        for id in leases.keys.filter({ leases[$0]?.owner == connection }) { await close(id) }
    }
    public func expire() async {
        for id in leases.keys.filter({ now().timeIntervalSince(leases[$0]!.touched) > SimulatorStreaming.leaseDuration }) { await close(id) }
        for id in leases.keys.filter({ leases[$0]?.contact.map { now().timeIntervalSince($0.time) > 2 } ?? false }) { await cancelContact(id) }
    }
    public func stop() async {
        listing?.task.cancel(); listing = nil
        for id in Array(leases.keys) { await close(id) }
    }
}
