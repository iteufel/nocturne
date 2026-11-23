import Foundation
import Combine

@MainActor
public final class MCPServersModel: ObservableObject {
    @Published public private(set) var servers: [MCPServerConfiguration] = []
    @Published public private(set) var busy = false
    @Published public private(set) var loaded = false
    @Published public private(set) var error: String?
    private let fetch: () async throws -> [MCPServerConfiguration]
    private let upsert: (MCPServerConfiguration) async throws -> [MCPServerConfiguration]
    private let delete: (String) async throws -> [MCPServerConfiguration]
    public init(fetch: @escaping () async throws -> [MCPServerConfiguration],
                save: @escaping (MCPServerConfiguration) async throws -> [MCPServerConfiguration],
                remove: @escaping (String) async throws -> [MCPServerConfiguration]) {
        self.fetch = fetch; self.upsert = save; self.delete = remove
    }
    public convenience init(connection: WorkspaceConnection) {
        func request(_ operation: Operation, server: MCPServerConfiguration? = nil, id: String? = nil) async throws -> [MCPServerConfiguration] {
            guard connection.state == .connected, connection.capabilities.contains(MCPServerConfiguration.capability) else {
                throw NocturneError.remote("Connect to your Mac and update Nocturne on the Mac to manage MCP servers.")
            }
            let invitation = connection.connectedInvitation
            var packet = Packet(operation); packet.mcpServer = server; packet.sessionID = id
            let response = try await connection.request(packet, timeout: 30)
            guard connection.connectedInvitation == invitation, connection.state == .connected else { throw NocturneError.disconnected }
            guard let values = response.mcpServers else { throw NocturneError.invalidFrame }
            try MCPServerConfiguration.validate(values); return values
        }
        self.init(fetch: { try await request(.chatMCPList) }, save: { try await request(.chatMCPSave, server: $0) },
                  remove: { try await request(.chatMCPRemove, id: $0) })
    }
    public func refresh() async {
        _ = await perform { try await self.fetch() }
    }
    @discardableResult public func save(_ server: MCPServerConfiguration) async -> Bool {
        await perform { try server.validate(); return try await self.upsert(server) }
    }
    public func remove(_ id: String) async {
        _ = await perform { try await self.delete(id) }
    }
    private func perform(_ action: () async throws -> [MCPServerConfiguration]) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil; defer { busy = false }
        do { servers = try await action(); loaded = true; return true }
        catch { self.error = NocturneLocalization.message(error.localizedDescription); return false }
    }
}
