import XCTest
@testable import StorageBar

final class FormattingTests: XCTestCase {
    func testFormatBytesShort() {
        XCTAssertEqual(SystemStats.formatBytesShort(246_000_000_000), "246 GB")
        XCTAssertEqual(SystemStats.formatBytesShort(85_300_000_000), "85.3 GB")
        XCTAssertEqual(SystemStats.formatBytesShort(1_500_000_000_000), "1.50 TB")
        XCTAssertEqual(SystemStats.formatBytesShort(500_000_000), "500 MB")
    }

    func testFormatMinutes() {
        XCTAssertEqual(SystemStats.formatMinutes(45), "45m")
        XCTAssertEqual(SystemStats.formatMinutes(60), "1h 0m")
        XCTAssertEqual(SystemStats.formatMinutes(65), "1h 5m")
        XCTAssertEqual(SystemStats.formatMinutes(150), "2h 30m")
    }
}

final class DiskInfoTests: XCTestCase {
    func testDerivedValues() {
        let disk = DiskInfo(volumeName: "Test", total: 1000, available: 400, free: 300)
        XCTAssertEqual(disk.used, 600)
        XCTAssertEqual(disk.purgeable, 100)
        XCTAssertEqual(disk.usedFraction, 0.6, accuracy: 0.0001)
    }

    func testValuesNeverNegative() {
        // available can momentarily exceed total in odd snapshots; derived values must clamp.
        let disk = DiskInfo(volumeName: "Test", total: 100, available: 150, free: 200)
        XCTAssertEqual(disk.used, 0)
        XCTAssertEqual(disk.purgeable, 0)
    }

    func testZeroTotalDoesNotDivideByZero() {
        let disk = DiskInfo(volumeName: "Test", total: 0, available: 0, free: 0)
        XCTAssertEqual(disk.usedFraction, 0)
    }
}

final class SystemStatsLiveTests: XCTestCase {
    func testDiskReturnsPlausibleValues() throws {
        let disk = try XCTUnwrap(SystemStats.disk())
        XCTAssertGreaterThan(disk.total, 0)
        XCTAssertGreaterThan(disk.available, 0)
        // No upper bound: important-usage capacity can briefly exceed total.
    }

    func testMemoryReturnsPlausibleValues() throws {
        let memory = try XCTUnwrap(SystemStats.memory())
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThan(memory.used, memory.total)
    }

    func testCPUUsageAfterTwoSamples() {
        _ = SystemStats.cpuUsage()
        Thread.sleep(forTimeInterval: 0.1)
        let usage = SystemStats.cpuUsage()
        XCTAssertNotNil(usage)
        if let usage {
            XCTAssertGreaterThanOrEqual(usage, 0)
            XCTAssertLessThanOrEqual(usage, 100)
        }
    }

    func testUptimeFormat() {
        let uptime = SystemStats.uptime()
        let pattern = #"^(\d+d )?(\d+h )?\d+m$"#
        XCTAssertNotNil(
            uptime.range(of: pattern, options: .regularExpression),
            "unexpected uptime format: \(uptime)"
        )
    }

    func testDirectorySizeOfUnreadableDirectoryIsNil() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertNil(SystemStats.directorySize(missing))
    }

    func testDirectorySizeCountsFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storagebar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0, count: 10_000).write(to: dir.appendingPathComponent("a.bin"))
        try Data(repeating: 1, count: 20_000).write(to: dir.appendingPathComponent("b.bin"))

        let size = try XCTUnwrap(SystemStats.directorySize(dir))
        // Allocated size is at least the logical bytes written.
        XCTAssertGreaterThanOrEqual(size, 30_000)
    }
}

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("1.2.0", newerThan: "1.1.0"))
        XCTAssertTrue(UpdateChecker.isVersion("v1.2.0", newerThan: "1.1.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.0"))
        XCTAssertTrue(UpdateChecker.isVersion("2.0", newerThan: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isVersion("10.0.0", newerThan: "9.9.9"))
        XCTAssertTrue(UpdateChecker.isVersion("1.2.0", newerThan: "1.2"))
        XCTAssertFalse(UpdateChecker.isVersion("1.1.0", newerThan: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.9", newerThan: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isVersion("v1.1.0", newerThan: "v1.2.0"))
    }
}
