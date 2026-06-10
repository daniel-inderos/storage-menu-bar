import Foundation
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

enum SystemStats {
    private static var prevCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

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

    /// Used memory the way Activity Monitor counts it: active + wired + compressed.
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
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
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
        let ticks = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { prevCPUTicks = ticks }
        guard let prev = prevCPUTicks else { return nil }
        let busy = (ticks.user - prev.user) + (ticks.system - prev.system) + (ticks.nice - prev.nice)
        let total = busy + (ticks.idle - prev.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }

    static func loadAverage() -> Double? {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) >= 1 else { return nil }
        return load[0]
    }

    static func uptime() -> String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func battery() -> (percent: Int, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any] else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?
                .takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            return (current * 100 / max, charging)
        }
        return nil
    }

    // MARK: Formatting

    /// Long form for the menu, e.g. "245.93 GB" (decimal units, matches Finder).
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
