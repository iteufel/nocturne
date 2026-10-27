import Foundation
import NocturneKit

/// Draft values are independent of the saved configuration used by running services.
public struct ServerSettings: Equatable {
    public var launchAtLogin = false
    public var screenSharing: Bool
    public var terminal: Bool
    public var files: Bool
    public var microphone: Bool
    public var chats: Bool
    public var sharedFolder: URL
    public var display: String
    public var headlessDisplay: Bool
    public var disablePhysicalDisplays: Bool
    public var remoteAccess: Bool
    public var brokerURL: String
    public var hasEnabledServices: Bool { screenSharing || terminal || files || microphone || chats }

    public init(defaults: UserDefaults = .standard) {
        screenSharing = defaults.object(forKey: "allowScreenSharing") == nil || defaults.bool(forKey: "allowScreenSharing")
        terminal = defaults.bool(forKey: "allowTerminal")
        files = defaults.bool(forKey: "allowFiles")
        microphone = defaults.bool(forKey: "allowMicrophone")
        chats = defaults.bool(forKey: "allowChats")
        sharedFolder = defaults.string(forKey: "sharedFolder").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Nocturne Shared", isDirectory: true)
        let displays = DisplaySettings(defaults: defaults)
        display = displays.physicalDisplay
        headlessDisplay = displays.headlessEnabled
        disablePhysicalDisplays = displays.disablePhysicalDisplays
        remoteAccess = defaults.bool(forKey: "remoteAccessEnabled")
        brokerURL = defaults.string(forKey: "remoteBrokerURL") ?? "https://nocturne.alkal.de"
    }

    public func validated() throws -> Self {
        var result = self
        result.brokerURL = brokerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteAccess {
            result.brokerURL = try RemoteAccess.validateBroker(result.brokerURL)
        }
        return result
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(screenSharing, forKey: "allowScreenSharing")
        defaults.set(terminal, forKey: "allowTerminal")
        defaults.set(files, forKey: "allowFiles")
        defaults.set(microphone, forKey: "allowMicrophone")
        defaults.set(chats, forKey: "allowChats")
        defaults.set(sharedFolder.path, forKey: "sharedFolder")
        defaults.set(display, forKey: "streamDisplay")
        defaults.set(headlessDisplay, forKey: "headlessDisplayEnabled")
        defaults.set(disablePhysicalDisplays, forKey: "disablePhysicalDisplays")
        defaults.set(remoteAccess, forKey: "remoteAccessEnabled")
        defaults.set(brokerURL, forKey: "remoteBrokerURL")
    }
}
