import XCTest
@testable import StorageBar

final class CPUTickTests: XCTestCase {
    func testMonotonicDeltasReturnBusyPercentage() throws {
        let previous: SystemStats.CPUTicks = (user: 10, system: 20, idle: 30, nice: 40)
        let current: SystemStats.CPUTicks = (user: 30, system: 50, idle: 70, nice: 50)

        let usage = try XCTUnwrap(SystemStats.cpuUsage(from: previous, to: current))

        XCTAssertEqual(usage, 60, accuracy: 0.0001)
    }

    func testWrappedDeltasReturnFinitePercentage() throws {
        let previous: SystemStats.CPUTicks = (
            user: UInt32.max - 5,
            system: UInt32.max - 3,
            idle: UInt32.max - 7,
            nice: UInt32.max - 1
        )
        let current: SystemStats.CPUTicks = (user: 4, system: 6, idle: 2, nice: 8)

        let usage = try XCTUnwrap(SystemStats.cpuUsage(from: previous, to: current))

        XCTAssertTrue(usage.isFinite)
        XCTAssertGreaterThanOrEqual(usage, 0)
        XCTAssertLessThanOrEqual(usage, 100)
    }

    func testZeroTotalDeltaReturnsNil() {
        let ticks: SystemStats.CPUTicks = (user: 10, system: 20, idle: 30, nice: 40)

        XCTAssertNil(SystemStats.cpuUsage(from: ticks, to: ticks))
    }
}
