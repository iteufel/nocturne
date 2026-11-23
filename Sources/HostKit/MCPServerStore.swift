import Foundation
import Combine
import NocturneKit

/// One Mac-owned list shared by local settings and authenticated chat clients.
/// Credentials stay in Keychain, never UserDefaults or provider command arguments.
@MainActor
public final class MCPServerStore: ObservableObject {
    @Published public private(set) var servers: [MCPServerConfiguration] = []
    private let read: () throws -> Data?
    private let write: (Data) throws -> Void
    public nonisolated init(read: @escaping () throws -> Data? = { try SecureStore.read("chat.mcpServers") },
                            write: @escaping (Data) throws -> Void = { try SecureStore.write($0, account: "chat.mcpServers") }) {
        self.read = read; self.write = write
    }
    @discardableResult public func load() throws -> [MCPServerConfiguration] {
        let values = try read().map { try JSONDecoder().decode([MCPServerConfiguration].self, from: $0) } ?? []
        try MCPServerConfiguration.validate(values)
        servers = values; return values
    }
    @discardableResult public func save(_ server: MCPServerConfiguration) throws -> [MCPServerConfiguration] {
        try server.validate()
        var values = try load()
        if let index = values.firstIndex(where: { $0.id == server.id }) { values[index] = server }
        else { values.append(server) }
        return try persist(values)
    }
    @discardableResult public func remove(_ id: String) throws -> [MCPServerConfiguration] {
        try persist(load().filter { $0.id != id })
    }
    private func persist(_ values: [MCPServerConfiguration]) throws -> [MCPServerConfiguration] {
        try MCPServerConfiguration.validate(values)
        try write(JSONEncoder().encode(values)); servers = values; return values
    }
}
