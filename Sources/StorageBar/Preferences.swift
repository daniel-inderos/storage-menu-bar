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
