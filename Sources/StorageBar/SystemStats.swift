import Foundation
import IOKit
import IOKit.ps

struct DiskInfo {
    let volumeName: String
    let total: Int64
    /// Finder-style available space (includes purgeable space the system can reclaim).
    let available: Int64
    /// Space that is actually free right now.
    let free: Int64

    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, available - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct VolumeInfo {
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
}

struct BatteryInfo {
    let percent: Int
    let isCharging: Bool
    let onACPower: Bool
    /// Estimated minutes until empty (only meaningful when discharging).
    let timeToEmpty: Int?
    /// Estimated minutes until fully charged (only meaningful when charging).
    let timeToFull: Int?
    let cycleCount: Int?
    /// Current maximum capacity as a percentage of design capacity.
    let healthPercent: Int?
}

enum SystemStats {
    typealias CPUTicks = (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)

    private static var prevCPUTicks: CPUTicks?

    static func disk() -> DiskInfo? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        return DiskInfo(
            volumeName: values.volumeName ?? "Macintosh HD",
            total: Int64(total),
            available: available,
            free: free
        )
    }

    /// Mounted, user-visible volumes other than the startup disk.
    static func otherVolumes() -> [VolumeInfo] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]
        ) else { return [] }
        var volumes: [VolumeInfo] = []
        for url in urls where url.path != "/" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsBrowsable == true,
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            volumes.append(VolumeInfo(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                total: Int64(total),
                available: Int64(values.volumeAvailableCapacity ?? 0)
            ))
        }
        return volumes
    }

    /// Total allocated size of everything under `url`. Walks the tree, so run it
    /// off the main thread. Returns nil when the directory itself can't be read
    /// (e.g. ~/.Trash without Full Disk Access) — that's "unknown", not zero.
    /// Unreadable entries deeper in the tree are skipped.
    static func directorySize(_ url: URL) -> Int64? {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            return nil
        }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Used memory with Activity Monitor's formula:
    /// app memory (internal - purgeable) + wired + compressed.
    static func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let pages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return (pages * UInt64(pageSize), ProcessInfo.processInfo.physicalMemory)
    }

    /// Overall CPU usage in percent, computed from the tick delta since the previous call.
    /// Returns nil on the first call (no baseline yet).
    static func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks: CPUTicks = (
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
        defer { prevCPUTicks = ticks }
        guard let prev = prevCPUTicks else { return nil }
        return cpuUsage(from: prev, to: ticks)
    }

    static func cpuUsage(from prev: CPUTicks, to ticks: CPUTicks) -> Double? {
        let user = UInt64(ticks.user &- prev.user)
        let system = UInt64(ticks.system &- prev.system)
        let idle = UInt64(ticks.idle &- prev.idle)
        let nice = UInt64(ticks.nice &- prev.nice)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }

    static func loadAverage() -> Double? {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) >= 1 else { return nil }
        return load[0]
    }

    static func uptime() -> String {
        // ProcessInfo.systemUptime excludes time asleep; kern.boottime gives
        // wall-clock time since boot, matching the `uptime` command.
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let seconds: Int
        if sysctl(&mib, 2, &boottime, &size, nil, 0) == 0, boottime.tv_sec > 0 {
            seconds = Int(Date().timeIntervalSince1970) - Int(boottime.tv_sec)
        } else {
            seconds = Int(ProcessInfo.processInfo.systemUptime)
        }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any] else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?
                .takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            // Time estimates are in minutes; 0 or -1 means unknown / still calculating.
            func minutes(_ key: String) -> Int? {
                guard let value = desc[key] as? Int, value > 0 else { return nil }
                return value
            }
            let details = smartBatteryDetails()
            return BatteryInfo(
                percent: current * 100 / max,
                isCharging: (desc[kIOPSIsChargingKey] as? Bool) ?? false,
                onACPower: (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                timeToEmpty: minutes(kIOPSTimeToEmptyKey),
                timeToFull: minutes(kIOPSTimeToFullChargeKey),
                cycleCount: details.cycleCount,
                healthPercent: details.healthPercent
            )
        }
        return nil
    }

    /// Cycle count and health from the battery's IORegistry entry. MaxCapacity is
    /// normalized to 100 on Apple Silicon, so prefer the raw capacity readings.
    private static func smartBatteryDetails() -> (cycleCount: Int?, healthPercent: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        func intProp(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        let cycles = intProp("CycleCount")
        var health: Int?
        // System Settings derives "Maximum Capacity" from NominalChargeCapacity,
        // so prefer it to match what the user sees there.
        if let design = intProp("DesignCapacity"), design > 0,
           let maxCapacity = intProp("NominalChargeCapacity") ?? intProp("AppleRawMaxCapacity") {
            // A fresh battery's raw capacity can exceed its design capacity; cap at 100.
            health = min(100, Int((Double(maxCapacity) / Double(design) * 100).rounded()))
        }
        return (cycles, health)
    }

    // MARK: Formatting

    /// Long form for the menu, e.g. "245.93 GB" (decimal units, matches Finder).
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// "45m" or "1h 5m".
    static func formatMinutes(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Compact form for the menu bar title, e.g. "246 GB" or "85.3 GB".
    static func formatBytesShort(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1000 { return String(format: "%.2f TB", gb / 1000) }
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
