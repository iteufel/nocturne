import Foundation

/// Preserve an existing physical-monitor selection when introducing the explicit
/// virtual-monitor switch. In particular, never opt a recovery configuration back
/// into display management merely because it predates this setting.
public struct DisplaySettings {
    public let headlessEnabled: Bool
    public let physicalDisplay: String
    public let disablePhysicalDisplays: Bool

    public init(defaults: UserDefaults = .standard) {
        physicalDisplay = defaults.string(forKey: "streamDisplay") ?? ""
        headlessEnabled = (defaults.object(forKey: "headlessDisplayEnabled") as? Bool) ?? physicalDisplay.isEmpty
        disablePhysicalDisplays = defaults.bool(forKey: "disablePhysicalDisplays")
    }
}
