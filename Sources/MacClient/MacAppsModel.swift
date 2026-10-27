import AppKit
import Combine
import NocturneKit

@MainActor
public final class MacAppsModel: ObservableObject {
    public let serverID: String
    public let name: String
    public let connection: WorkspaceConnection
    @Published public private(set) var applications: [RemoteApplication] = []
    @Published public private(set) var windows: [RemoteAppWindow] = []
    @Published public private(set) var icons: [String: NSImage] = [:]
    @Published public private(set) var loading = false
    @Published public private(set) var opening: String?
    @Published public private(set) var error: String?
    var onAuthenticated: ((PairingInvitation) throws -> Void)?
    private let invitation: PairingInvitation
    private var generation = UUID()
    init(invitation: PairingInvitation, identity: WorkspaceIdentity) {
        self.invitation = invitation; name = invitation.name
        serverID = WorkspaceIdentity.fingerprint(invitation.secret)
        connection = WorkspaceConnection(identity: identity, remoteStreaming: false)
    }
    public func stop() {
        generation = UUID(); connection.disconnect(); loading = false; opening = nil
        applications = []; windows = []; icons = [:]
    }
    public func load() async {
        guard !loading else { return }
        let epoch = generation; loading = true; error = nil
        defer { if generation == epoch { loading = false } }
        do {
            if connection.state != .connected {
                try await connection.connect(invitation, restoreTerminalSessions: false, rediscover: true)
                guard epoch == generation else { return }
                guard connection.capabilities.contains(AppStreaming.capability) else {
                    throw NocturneError.remote("Enable Screen sharing and update Nocturne on the host Mac to open its app windows.")
                }
                guard let refreshed = connection.connectedInvitation else { throw NocturneError.disconnected }
                do { try onAuthenticated?(refreshed) }
                catch { connection.disconnect(); throw error }
            }
            var apps: [RemoteApplication] = [], windows: [RemoteAppWindow] = [], offset: Int64 = 0
            while true {
                var request = Packet(.appList); request.offset = offset
                let reply = try await connection.request(request, timeout: 30)
                guard epoch == generation else { return }
                guard let page = reply.applications, page.count <= 64,
                      let next = reply.offset, next == offset + Int64(page.count),
                      reply.eof != nil, next > offset || reply.eof == true else { throw NocturneError.invalidFrame }
                apps.append(contentsOf: page)
                guard apps.count <= 10_000 else { throw NocturneError.invalidFrame }
                if offset == 0 { windows = reply.windows ?? []; error = reply.windowsError }
                if reply.eof == true { break }; offset = next
            }
            guard Set(apps.map(\.id)).count == apps.count else { throw NocturneError.invalidFrame }
            self.applications = apps; self.windows = windows
        } catch {
            guard epoch == generation else { return }
            self.error = error.localizedDescription
            // Do not retain an unusable initial catalog connection.
            if applications.isEmpty { connection.disconnect() }
        }
    }
    public func icon(_ app: RemoteApplication) async {
        guard icons[app.id] == nil, connection.state == .connected else { return }
        let epoch = generation
        var request = Packet(.appIcon); request.applicationID = app.id
        guard let reply = try? await connection.request(request), epoch == generation,
              let data = reply.data, data.count <= 131_072, let image = NSImage(data: data) else { return }
        icons[app.id] = image
    }
    public func launch(_ app: RemoteApplication) async -> [RemoteAppWindow] {
        guard opening == nil, applications.contains(where: { $0.id == app.id }) else { return [] }
        let epoch = generation; opening = app.id; error = nil
        defer { if generation == epoch { opening = nil } }
        do {
            var request = Packet(.appLaunch); request.applicationID = app.id
            let reply = try await connection.request(request, timeout: 30)
            guard generation == epoch else { return [] }
            guard let windows = reply.windows, !windows.isEmpty,
                  windows.allSatisfy({ $0.applicationID == app.id }) else { throw NocturneError.invalidFrame }
            self.windows.removeAll { $0.applicationID == app.id }; self.windows.append(contentsOf: windows)
            return windows
        } catch { if generation == epoch { self.error = error.localizedDescription }; return [] }
    }
}
