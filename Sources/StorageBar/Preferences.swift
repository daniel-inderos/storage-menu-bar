import Foundation

enum MenuBarDisplay: String, CaseIterable {
    case freeSpace
    case usedPercent
    case iconOnly

    var label: String {
        switch self {
        case .freeSpace: return "Free Space"
        case .usedPercent: return "Used Percentage"
        case .iconOnly: return "Icon Only"
        }
    }
}

enum Prefs {
    private static let defaults = UserDefaults.standard
    private static let currentBundleIdentifier = "io.github.daniel-inderos.StorageBar"
    private static let legacyBundleIdentifier = "local.storagebar.app"
    private static let migrationFlagKey = "didMigrateLegacyDefaultsFromLocalStorageBarApp"
    private static let persistedKeys = ["menuBarDisplay", "refreshInterval", "warnBelowGB"]

    // One-time bundle identifier rename migration; remove after legacy users have upgraded.
    static func migrateLegacyDefaults() {
        guard Bundle.main.bundleIdentifier == currentBundleIdentifier else { return }
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        defer { defaults.set(true, forKey: migrationFlagKey) }

        let hasCurrentValues = persistedKeys.contains { defaults.object(forKey: $0) != nil }
        guard !hasCurrentValues else { return }
        guard let legacyDefaults = UserDefaults(suiteName: legacyBundleIdentifier) else { return }

        for key in persistedKeys {
            if let value = legacyDefaults.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    static var display: MenuBarDisplay {
        get { MenuBarDisplay(rawValue: defaults.string(forKey: "menuBarDisplay") ?? "") ?? .freeSpace }
        set { defaults.set(newValue.rawValue, forKey: "menuBarDisplay") }
    }

    static var refreshInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: "refreshInterval")
            return value > 0 ? value : 30
        }
        set { defaults.set(newValue, forKey: "refreshInterval") }
    }

    /// Warn when available space drops below this many GB. 0 = off.
    static var warnBelowGB: Int {
        get { defaults.object(forKey: "warnBelowGB") as? Int ?? 25 }
        set { defaults.set(newValue, forKey: "warnBelowGB") }
    }
}
