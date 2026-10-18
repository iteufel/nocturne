import Foundation

public struct ServerDevice: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let streamIDs: [String]
    public let workspace: Bool
    public let connected: Bool
    public let address: String?
    public let lastSeen: Date?
    public let streamingEnabled: Bool

    public static func pendingRemoval(id: String, name: String) -> ServerDevice {
        ServerDevice(id: id, name: name, streamIDs: [], workspace: false, connected: false, address: nil, lastSeen: nil, streamingEnabled: false)
    }
    public static func list(streams: [StreamDevice], workspaces: [WorkspaceDevice], connections: [WorkspaceDeviceConnection]) -> [ServerDevice] {
        let ids = Set(streams.map(\.fingerprint) + workspaces.map(\.id) + connections.map(\.id))
        return ids.map { id in
            let streaming = streams.filter { $0.fingerprint == id }
            let workspace = workspaces.first { $0.id == id }
            let connection = connections.first { $0.id == id }
            return ServerDevice(id: id, name: connection?.name ?? workspace?.name ?? streaming.first?.name ?? "Device",
                streamIDs: streaming.map(\.id), workspace: workspace != nil, connected: connection != nil,
                address: connection?.address, lastSeen: workspace?.lastSeen, streamingEnabled: streaming.contains { $0.enabled })
        }.sorted {
            if $0.connected != $1.connected { return $0.connected }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
