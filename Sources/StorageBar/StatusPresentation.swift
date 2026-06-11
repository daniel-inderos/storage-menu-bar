import Foundation

enum StatusPresentation {
    enum Severity: Equatable {
        case normal
        case warning
        case critical
    }

    /// Status button title for the selected menu bar display mode.
    static func title(for disk: DiskInfo, display: MenuBarDisplay) -> String {
        switch display {
        case .freeSpace:
            return " " + SystemStats.formatBytesShort(disk.available)
        case .usedPercent:
            return String(format: " %.0f%%", disk.usedFraction * 100)
        case .iconOnly:
            return ""
        }
    }

    /// Storage warning severity for the current available space.
    static func severity(forAvailableBytes availableBytes: Int64, warnBelowGB: Int) -> Severity {
        let availableGB = Double(availableBytes) / 1_000_000_000
        let warnGB = Double(warnBelowGB)
        if warnGB > 0 && availableGB < warnGB / 2 {
            return .critical
        } else if warnGB > 0 && availableGB < warnGB {
            return .warning
        } else {
            return .normal
        }
    }

    /// Notification state transition for low available space.
    static func lowSpaceTransition(
        availableBytes: Int64,
        warnBelowGB: Int,
        alreadyNotified: Bool
    ) -> (shouldNotify: Bool, newNotifiedFlag: Bool) {
        let warnGB = Double(warnBelowGB)
        guard warnGB > 0 else {
            return (shouldNotify: false, newNotifiedFlag: false)
        }
        let availableGB = Double(availableBytes) / 1_000_000_000
        if availableGB < warnGB {
            return (shouldNotify: !alreadyNotified, newNotifiedFlag: true)
        } else if availableGB > warnGB * 1.1 {
            // Hysteresis: re-arm only once comfortably back above the threshold.
            return (shouldNotify: false, newNotifiedFlag: false)
        } else {
            return (shouldNotify: false, newNotifiedFlag: alreadyNotified)
        }
    }
}
