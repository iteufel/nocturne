import Foundation

/// Remote servers are contacted by the agent on the Mac, including localhost URLs.
public struct MCPServerConfiguration: Codable, Equatable, Identifiable, Sendable {
    public static let capability = "chat-mcp-servers-v1"
    public static let maximumServers = 24
    public var id: String
    public var name: String
    public var url: String
    public var headers: [String: String]
    public var enabled: Bool
    public init(id: String = "nocturne_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                name: String = "", url: String = "", headers: [String: String] = [:], enabled: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.headers = headers; self.enabled = enabled
    }
    public func validate() throws {
        let identifier = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !id.isEmpty, id.utf8.count <= 128, id.unicodeScalars.allSatisfy(identifier.contains),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NocturneError.remote("Enter a server name of up to 128 bytes.")
        }
        guard url.utf8.count <= 4096, !url.contains(where: { $0.isWhitespace }),
              let parts = URLComponents(string: url), ["https", "http"].contains(parts.scheme?.lowercased()),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.port == nil || (1...65535).contains(parts.port!), parts.url != nil else {
            throw NocturneError.remote("Enter a full HTTP or HTTPS server URL without a username, password, or fragment.")
        }
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard headers.count <= 16, Set(headers.keys.map { $0.lowercased() }).count == headers.count,
              headers.allSatisfy({ key, value in
                  !key.isEmpty && key.utf8.count <= 128 && key.unicodeScalars.allSatisfy(token.contains) &&
                  value.utf8.count <= 8192 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }), headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16384 else {
            throw NocturneError.remote("Enter unique HTTP header names and single-line values, using at most 16 headers and 16 KB in total.")
        }
    }
    public static func validate(_ servers: [Self]) throws {
        guard servers.count <= maximumServers, Set(servers.map(\.id)).count == servers.count else {
            throw NocturneError.remote("Use at most 24 MCP servers with unique identifiers.")
        }
        try servers.forEach { try $0.validate() }
    }
}
