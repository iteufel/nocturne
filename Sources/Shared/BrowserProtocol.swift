import Foundation

/// Only commands and bounded JPEG frames cross the pairing channel. Web content never runs on the client.
public enum BrowserProtocol {
    public static let capability = "host-browser-v1"
    public static let width = 1024
    public static let height = 768
    public static let maximumImageBytes = 600_000
    public static let leaseSeconds: TimeInterval = 30

    public static func destination(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8_192, !value.isEmpty,
              !value.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }),
              let parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              let url = parts.url else { throw NocturneError.remote("Enter a full http:// or https:// address without credentials.") }
        return url
    }
}

public struct BrowserCommand: Codable, Equatable {
    public enum Action: String, Codable { case open, navigate, back, forward, reload, frame, click, text, enter, tab, backspace, scroll, close }
    public var action: Action
    public var value: String?
    /// Page revision from the displayed frame. Stale input is rejected after navigation.
    public var page: String?
    public var x: Double?
    public var y: Double?
    public init(_ action: Action, value: String? = nil, page: String? = nil, x: Double? = nil, y: Double? = nil) {
        self.action = action; self.value = value; self.page = page; self.x = x; self.y = y
    }
}

public struct BrowserFrame: Codable {
    public var page: String
    public var url: String
    public var title: String
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var loading: Bool
    public var notice: String?
    public var jpeg: Data?
    public init(page: String, url: String, title: String, canGoBack: Bool, canGoForward: Bool, loading: Bool, notice: String? = nil, jpeg: Data? = nil) {
        self.page = page; self.url = url; self.title = title; self.canGoBack = canGoBack; self.canGoForward = canGoForward
        self.loading = loading; self.notice = notice; self.jpeg = jpeg
    }
}
