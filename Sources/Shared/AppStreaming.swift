import Foundation

public enum AppStreaming {
    public static let capability = "app-windows-v1"
    public static let maximumWindows = 8
    public static let maximumWindowsPerDevice = 4
    public static let maximumVideoBytes = 4_194_304
    public static let videoChunkSize = 196_608
    public static let heartbeatTimeout: TimeInterval = 20
}

/// Reassemble one bounded H.264 access unit. Large keyframes are fragmented so
/// high-detail Retina windows cannot overflow the workspace's JSON frame limit.
public struct AppWindowVideoAssembler {
    private var id: String?
    private var data = Data()
    private var expected: Int64 = 0
    private var sets: [Data] = []
    private var timestamp: Double = 0
    public init() {}
    public mutating func reset() { id = nil; data = Data(); expected = 0; sets = [] }
    public mutating func receive(_ packet: Packet) throws -> AppWindowVideoFrame? {
        guard [.appVideo, .desktopVideo].contains(packet.operation), let video = packet.video, video.isValid else { throw NocturneError.invalidFrame }
        if packet.transferID == nil, packet.offset == nil, packet.size == nil { reset(); return video }
        guard let frameID = packet.transferID, !frameID.isEmpty, frameID.utf8.count <= 64,
              let offset = packet.offset, let total = packet.size,
              total > 0, total <= AppStreaming.maximumVideoBytes, offset >= 0, offset <= total,
              video.data.count <= AppStreaming.videoChunkSize,
              Int64(video.data.count) <= total - offset else { throw NocturneError.invalidFrame }
        if offset == 0 {
            reset(); id = frameID; expected = total; sets = video.parameterSets; timestamp = video.timestamp
        }
        guard id == frameID, expected == total, data.count == offset, sets == video.parameterSets, timestamp == video.timestamp else {
            throw NocturneError.invalidFrame
        }
        data.append(video.data)
        guard data.count == expected else { return nil }
        let result = AppWindowVideoFrame(data: data, parameterSets: sets, timestamp: timestamp)
        reset(); return result
    }
}

public struct RemoteApplication: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public init(id: String, name: String, bundleIdentifier: String? = nil) {
        self.id = id; self.name = name; self.bundleIdentifier = bundleIdentifier
    }
}

public struct RemoteAppWindow: Codable, Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let applicationID: String
    public let title: String
    public let width: Int
    public let height: Int
    public let isResizable: Bool?
    public init(id: UInt32, applicationID: String, title: String, width: Int, height: Int, isResizable: Bool? = nil) {
        self.id = id; self.applicationID = applicationID; self.title = title; self.width = width; self.height = height; self.isResizable = isResizable
    }
}

/// Scene dimensions are in points. Capture dimensions are Retina pixels; changing
/// the scene must change the Mac window's layout, not just stretch its video.
public struct AppWindowViewport: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let scale: Double
    public let frameRate: Int
    public init(width: Int, height: Int, scale: Double, frameRate: Int = 60) {
        self.width = width; self.height = height; self.scale = scale; self.frameRate = frameRate
    }
    public var isValid: Bool {
        (240...4096).contains(width) && (160...4096).contains(height) &&
        scale.isFinite && (1...3).contains(scale) && [30, 60].contains(frameRate)
    }
    public func pixels(width: Double, height: Double) -> StreamDisplaySize? {
        guard isValid, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let w = width * scale, h = height * scale
        guard w.isFinite, h.isFinite else { return nil }
        let factor = min(1, 4096 / max(w, h))
        let result = StreamDisplaySize(width: Int((w * factor / 2).rounded()) * 2,
            height: Int((h * factor / 2).rounded()) * 2, frameRate: frameRate)
        return result.isValidAppWindow ? result : nil
    }
}

extension StreamDisplaySize {
    /// App windows can be smaller than desktop streams, especially on 1× displays.
    /// Keep even H.264 dimensions and the same pixel ceiling without stretching them.
    public var isValidAppWindow: Bool {
        (2...4096).contains(width) && (2...4096).contains(height) &&
        width % 2 == 0 && height % 2 == 0 && [30, 60].contains(frameRate)
    }
}

public struct AppWindowVideoFrame: Codable, Sendable {
    public let data: Data
    public let parameterSets: [Data]
    public let timestamp: Double
    public init(data: Data, parameterSets: [Data], timestamp: Double) {
        self.data = data; self.parameterSets = parameterSets; self.timestamp = timestamp
    }
    public var isValid: Bool {
        !data.isEmpty && data.count <= AppStreaming.maximumVideoBytes && timestamp.isFinite &&
        parameterSets.count == 2 && parameterSets.allSatisfy { !$0.isEmpty && $0.count <= 4096 }
    }
}

public struct AppWindowInput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case move, down, up, scroll, keyDown, keyUp, text }
    public var kind: Kind
    public var x: Double = 0
    public var y: Double = 0
    public var button: Int = 0
    public var clickCount: Int? = nil
    public var deltaX: Double = 0
    public var deltaY: Double = 0
    public var keyCode: UInt16 = 0
    public var modifiers: UInt64 = 0
    public var text: String = ""
    public init(_ kind: Kind) { self.kind = kind }
    public var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) &&
        (0...2).contains(button) && (1...3).contains(clickCount ?? 1) && deltaX.isFinite && deltaY.isFinite &&
        abs(deltaX) <= 4096 && abs(deltaY) <= 4096 && keyCode <= 127 && text.utf16.count <= 1024
    }
}

/// Contains no pairing secrets; safe for UIKit scene restoration activities.
public struct AppWindowRoute: Codable, Equatable, Identifiable, Sendable {
    public let serverID: String
    public let applicationID: String
    public let windowID: UInt32
    public let title: String
    public var contentIdentifier: String { "app-window:\(serverID):\(windowID)" }
    public var id: String { contentIdentifier }
    public init(serverID: String, applicationID: String, windowID: UInt32, title: String) {
        self.serverID = serverID; self.applicationID = applicationID; self.windowID = windowID; self.title = title
    }
}
