import Foundation
import NocturneKit

/// Configured only on the Mac. A paired client can select an agent, never supply a command to run.
public struct ChatAgentConfiguration: Codable, Equatable, Identifiable, Sendable {
    public enum Transport: String, Codable, CaseIterable, Sendable { case codex, acp }
    public var id: String
    public var name: String
    public var transport: Transport
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public init(id: String = UUID().uuidString, name: String, transport: Transport = .acp,
                executable: String, arguments: [String] = [], directory: String = "") {
        self.id = id; self.name = name; self.transport = transport
        self.executable = executable; self.arguments = arguments; self.directory = directory
    }
    public static let defaults: [ChatAgentConfiguration] = [
        .init(id: "codex", name: "Codex", transport: .codex, executable: "codex", arguments: ["app-server"]),
        .init(id: "claude", name: "Claude Code", executable: "claude-agent-acp")
    ]
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 128, !executable.isEmpty, executable.utf8.count < 4_096,
              !executable.contains("\0"), arguments.count <= 64,
              arguments.allSatisfy({ $0.utf8.count <= 8_192 && !$0.contains("\0") }),
              directory.isEmpty || NSString(string: directory).expandingTildeInPath.hasPrefix("/") else {
            throw NocturneError.remote("Enter a provider name, an executable, and an absolute working directory.")
        }
    }
    static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ([home + "/.local/bin", home + "/.cargo/bin", home + "/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":"))
            .filter { !$0.isEmpty }.joined(separator: ":")
    }
    var executableURL: URL? {
        let command = NSString(string: executable).expandingTildeInPath
        let paths = command.contains("/") ? [command] : Self.searchPath.components(separatedBy: ":").map { $0 + "/" + command }
        return paths.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    var descriptor: ChatProvider {
        ChatProvider(id: id, name: name, available: executableURL != nil,
            detail: executableURL == nil ? "Install \(executable) on your Mac or set its full path in Sharing → Chat providers."
                : transport == .codex ? "Conversations from Codex on this Mac" : "Agent Client Protocol", supportsVoice: transport == .codex)
    }
    func workingDirectory(fallback: URL) throws -> URL {
        let url = directory.isEmpty ? fallback : URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NocturneError.remote("The provider’s working directory no longer exists. Choose a folder on your Mac.")
        }
        return url
    }
}
