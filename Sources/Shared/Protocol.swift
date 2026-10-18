import Foundation

public enum WorkspaceProtocol {
    public static let version = 4
    public static let port: UInt16 = 48555
    public static let service = "_nocturne._tcp"
    public static let maximumFrame = 1_048_576
    public static let chunkSize = 196_608
    public static let terminalHistoryLimit = 524_288
    public static let maximumTerminals = 8
}

public enum Operation: String, Codable {
    case hello, authenticate, ping, pairStream, list, read, uploadBegin, uploadChunk, uploadCommit, uploadCancel
    case terminalList, terminalAttach, terminalOpen, terminalInput, terminalResize, terminalClose, terminalOutput, terminalExit, terminalClosed
    case displayPrepare, displayHeartbeat, displayRelease
}

public struct RemoteTerminal: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public var running: Bool
    public var columns: Int
    public var rows: Int
    public init(id: String, name: String, running: Bool = true, columns: Int, rows: Int) {
        self.id = id; self.name = name; self.running = running; self.columns = columns; self.rows = rows
    }
}

public struct RemoteFile: Codable, Identifiable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date
    public init(name: String, path: String, isDirectory: Bool, size: Int64, modified: Date) {
        self.name = name; self.path = path; self.isDirectory = isDirectory; self.size = size; self.modified = modified
    }
}

/// Length-prefixed JSON over mutually authenticated TLS. Binary chunks are bounded, base64 encoded Data.
public struct Packet: Codable {
    public var id = UUID().uuidString
    public var operation: Operation
    public var version: Int? = nil
    public var error: String? = nil
    public var name: String? = nil
    public var path: String? = nil
    public var offset: Int64? = nil
    public var size: Int64? = nil
    public var data: Data? = nil
    public var transferID: String? = nil
    public var sessionID: String? = nil
    public var terminal: RemoteTerminal? = nil
    public var terminals: [RemoteTerminal]? = nil
    public var columns: Int? = nil
    public var rows: Int? = nil
    public var eof: Bool? = nil
    public var files: [RemoteFile]? = nil
    public var capabilities: [String]? = nil
    public var certificate: Data? = nil
    public var signature: Data? = nil
    public var enrollmentToken: Data? = nil
    public var display: StreamDisplaySize? = nil
    public init(_ operation: Operation, id: String = UUID().uuidString) { self.operation = operation; self.id = id }
    public func reply(error: String? = nil) -> Packet {
        var result = Packet(operation, id: id); result.error = error; return result
    }
}

public enum NocturneError: LocalizedError, Equatable {
    case invalidInvitation, invalidFrame, disconnected, timeout, remote(String), invalidPath, permissionDenied, invalidTransfer
    public var errorDescription: String? {
        switch self {
        case .invalidInvitation: return "This pairing link is invalid. Copy a new link from Nocturne Server on your Mac."
        case .invalidFrame: return "The server sent an invalid message."
        case .disconnected: return "Connection closed. Reconnect to your Mac to continue."
        case .timeout: return "The Mac did not respond in time. Check that Nocturne Server is running."
        case .remote(let message): return message
        case .invalidPath: return "This path is outside the shared folder or contains a symbolic link."
        case .permissionDenied: return "Enable this feature in Nocturne Server on your Mac."
        case .invalidTransfer: return "The transfer is incomplete or out of order. Start it again."
        }
    }
}

public enum FrameCodec {
    public static func encode(_ packet: Packet) throws -> Data {
        let payload = try JSONEncoder().encode(packet)
        guard payload.count <= WorkspaceProtocol.maximumFrame else { throw NocturneError.invalidFrame }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }
    public static func length(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw NocturneError.invalidFrame }
        let value = header.reduce(0) { ($0 << 8) | Int($1) }
        guard value > 0, value <= WorkspaceProtocol.maximumFrame else { throw NocturneError.invalidFrame }
        return value
    }
}

/// The secret is deliberately excluded from UserDefaults and Bonjour announcements.
public struct PairingInvitation: Codable, Equatable {
    public let host: String
    public let port: UInt16
    public let name: String
    public let secret: Data
    public let enrollmentToken: Data?
    public init(host: String, port: UInt16 = WorkspaceProtocol.port, name: String, secret: Data, enrollmentToken: Data? = nil) throws {
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }), !host.contains("/"), port > 0, secret.count == 32, enrollmentToken == nil || enrollmentToken?.count == 32 else { throw NocturneError.invalidInvitation }
        self.host = host; self.port = port; self.name = name; self.secret = secret; self.enrollmentToken = enrollmentToken
    }
    public init(url: URL) throws {
        guard url.scheme == "nocturne", url.host == "pair",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems else { throw NocturneError.invalidInvitation }
        func value(_ key: String) -> String? { items.first(where: { $0.name == key })?.value }
        guard let host = value("host"), let encoded = value("key"), let secret = Data(base64Encoded: encoded),
              let portString = value("port"), let port = UInt16(portString), ["1", "2"].contains(value("v")) else { throw NocturneError.invalidInvitation }
        let token = value("token").flatMap { Data(base64Encoded: $0) }
        guard value("v") != "2" || token?.count == 32 else { throw NocturneError.invalidInvitation }
        try self.init(host: host, port: port, name: value("name") ?? host, secret: secret, enrollmentToken: token)
    }
    public var url: URL {
        var parts = URLComponents(); parts.scheme = "nocturne"; parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "v", value: enrollmentToken == nil ? "1" : "2"), URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "key", value: secret.base64EncodedString())]
        if let enrollmentToken { parts.queryItems?.append(URLQueryItem(name: "token", value: enrollmentToken.base64EncodedString())) }
        return parts.url!
    }
}

public enum StreamInputMode: String, CaseIterable, Identifiable {
    case touch, trackpad
    public var id: String { rawValue }
    public var title: String { self == .touch ? "Touch" : "Trackpad" }
    public var symbol: String { self == .touch ? "hand.point.up.left" : "rectangle.and.hand.point.up.left" }
    public var explanation: String {
        self == .touch
            ? "Tap where you want to click. Move your finger to drag; hold still for a right-click. Pinch with two fingers to zoom."
            : "Slide one finger to move the pointer. Tap to click, tap with two fingers to right-click, or slide two fingers to scroll. Hold one finger, then move it to drag."
    }
}

public struct StreamPreferences: Codable, Equatable {
    public var resolution = "Match device"
    public var frameRate = 60
    public var bitrate = 20
    public var hdr = false
    public var framePacing = true
    public var touchControls = false
    public var absolutePointer = false
    public var statistics = false
    public var multiController = true
    // Preserve the existing stored key so saved touch/trackpad choices survive upgrades.
    public var inputMode: StreamInputMode {
        get { absolutePointer ? .touch : .trackpad }
        set { absolutePointer = newValue == .touch }
    }
    public init() {}
    public var dimensions: (width: Int, height: Int) {
        switch resolution { case "720p": return (1280, 720); case "1440p": return (2560, 1440); case "4K": return (3840, 2160); default: return (1920, 1080) }
    }
}

public enum WorkspaceLayout: String {
    case compact, expanded
    public static func resolve(width: Double) -> WorkspaceLayout { width >= 700 ? .expanded : .compact }
}
