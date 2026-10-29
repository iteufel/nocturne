import Foundation

/// Shared presentation resources. Bundle performs Apple's normal language negotiation;
/// there is deliberately no preference, locale override, or custom language resolver.
public func L(_ key: String, _ arguments: String...) -> String {
    let format = NocturneLocalization.bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: arguments)
}

public func LCount(_ key: String, _ count: Int) -> String {
    let format = NocturneLocalization.bundle.localizedString(forKey: key, value: key, table: nil)
    return String.localizedStringWithFormat(format, count)
}

public enum NocturneLocalization {
    static let bundle = Bundle.module
    /// Shared native resources for App Intents metadata in the app and widget.
    public static var bundleURL: URL { bundle.bundleURL }

    /// Localize only Nocturne's known error envelopes at the receiving UI boundary.
    /// Payloads, protocol identifiers, paths, commands, and provider prose stay intact.
    /// Do not use this on conversation messages, logs, or user-entered values.
    public static func message(_ message: String) -> String {
        let direct = bundle.localizedString(forKey: message, value: message, table: nil)
        if direct != message { return direct }
        for prefix in ["ChatGPT authentication failed", "ChatGPT voice access denied", "Codex voice protocol error", "Codex voice failed"] {
            if message.hasPrefix(prefix + ": ") || message.hasPrefix(prefix + " (") {
                return L(prefix) + message.dropFirst(prefix.count)
            }
        }
        let range = NSRange(message.startIndex..., in: message)
        for (key, pattern) in errorFormats {
            guard let match = pattern.firstMatch(in: message, range: range) else { continue }
            let arguments: [CVarArg] = (1..<match.numberOfRanges).map {
                Range(match.range(at: $0), in: message).map { String(message[$0]) } ?? ""
            }
            let format = bundle.localizedString(forKey: key, value: key, table: nil)
            return String(format: format, locale: Locale.current, arguments: arguments)
        }
        return message
    }

    private static let errorFormats: [(String, NSRegularExpression)] = {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"),
              let data = try? Data(contentsOf: url),
              let strings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [] }
        // Only full, owned error sentences may match dynamic arguments. No generic
        // display labels are used as patterns, and arguments are never translated.
        return strings.keys.sorted().compactMap { key in
            guard key.contains("%@"), (key.count > 45 || key.hasPrefix("Keychain operation failed") || key.hasPrefix("Could not ")), key.hasSuffix(".") else { return nil }
            let pattern = "\\A" + key.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern(for:)).joined(separator: "([\\s\\S]*?)") + "\\z"
            return (key, try! NSRegularExpression(pattern: pattern))
        }
    }()

    public static func pullRequestState(_ value: String) -> String {
        switch value {
        case "open", "active": return L("Open")
        case "closed", "abandoned": return L("Closed")
        case "merged", "completed": return L("Merged")
        default: return value
        }
    }
}
