import XCTest
@testable import StorageBar

final class BatteryEstimationTests: XCTestCase {
    func testBatteryMinutesReturnsNilForNilInput() {
        XCTAssertNil(SystemStats.batteryMinutes(nil))
    }

    func testBatteryMinutesReturnsNilForZero() {
        XCTAssertNil(SystemStats.batteryMinutes(0))
    }

    func testBatteryMinutesReturnsNilForNegativeValue() {
        XCTAssertNil(SystemStats.batteryMinutes(-1))
    }

    func testBatteryMinutesReturnsNilForSentinelValue() {
        XCTAssertNil(SystemStats.batteryMinutes(65535))
    }

    func testBatteryMinutesAcceptsSevenDayBoundaryMinusOne() {
        XCTAssertEqual(SystemStats.batteryMinutes(10079), 10079)
    }

    func testBatteryMinutesReturnsNilAtSevenDayBoundary() {
        XCTAssertNil(SystemStats.batteryMinutes(10080))
    }

    func testBatteryMinutesAcceptsNormalValue() {
        XCTAssertEqual(SystemStats.batteryMinutes(712), 712)
    }

    func testEstimatedChargeMinutesReturnsTaperedHappyPath() {
        XCTAssertEqual(
            SystemStats.estimatedChargeMinutes(
                currentCapacity: 2000,
                maxCapacity: 5000,
                chargeRateMilliamps: 1000
            ),
            216
        )
    }

    func testEstimatedChargeMinutesReturnsNilForNilCurrentCapacity() {
        XCTAssertNil(
            SystemStats.estimatedChargeMinutes(
                currentCapacity: nil,
                maxCapacity: 5000,
                chargeRateMilliamps: 1000
            )
        )
    }

    func testEstimatedChargeMinutesReturnsNilForNilMaxCapacity() {
        XCTAssertNil(
            SystemStats.estimatedChargeMinutes(
                currentCapacity: 2000,
                maxCapacity: nil,
                chargeRateMilliamps: 1000
            )
        )
    }

    func testEstimatedChargeMinutesReturnsNilWhenMaxCapacityEqualsCurrentCapacity() {
        XCTAssertNil(
            SystemStats.estimatedChargeMinutes(
                currentCapacity: 5000,
                maxCapacity: 5000,
                chargeRateMilliamps: 1000
            )
        )
    }

    func testEstimatedChargeMinutesReturnsNilWhenMaxCapacityIsLessThanCurrentCapacity() {
        XCTAssertNil(
            SystemStats.estimatedChargeMinutes(
                currentCapacity: 5000,
                maxCapacity: 2000,
                chargeRateMilliamps: 1000
            )
        )
    }

    func testEstimatedChargeMinutesReturnsNilForNilChargeRate() {
        XCTAssertNil(
            SystemStats.estimatedChargeMinutes(
                currentCapacity: 2000,
                maxCapacity: 5000,
                chargeRateMilliamps: nil
            )
        )
    }

    func testEstimatedChargeMinutesReturnsNilForChargeRateBelowGate() {
        XCTAssertNil(
            SystemStats.estimatedChargeMinutes(
                currentCapacity: 2000,
                maxCapacity: 5000,
                chargeRateMilliamps: 99
            )
        )
    }

    func testEstimatedChargeMinutesAcceptsChargeRateAtGate() {
        XCTAssertEqual(
            SystemStats.estimatedChargeMinutes(
                currentCapacity: 4900,
                maxCapacity: 5000,
                chargeRateMilliamps: 100
            ),
            72
        )
    }

    func testTelemetryChargeRateMilliampsUsesChargingSignConvention() {
        XCTAssertEqual(
            SystemStats.telemetryChargeRateMilliamps(
                batteryPowerMilliwatts: -15000,
                voltageMillivolts: 12000
            ),
            1250
        )
    }

    func testTelemetryChargeRateMilliampsReturnsNilForPositivePower() {
        XCTAssertNil(
            SystemStats.telemetryChargeRateMilliamps(
                batteryPowerMilliwatts: 15000,
                voltageMillivolts: 12000
            )
        )
    }

    func testTelemetryChargeRateMilliampsReturnsNilForZeroPower() {
        XCTAssertNil(
            SystemStats.telemetryChargeRateMilliamps(
                batteryPowerMilliwatts: 0,
                voltageMillivolts: 12000
            )
        )
    }

    func testTelemetryChargeRateMilliampsReturnsNilForNilPower() {
        XCTAssertNil(
            SystemStats.telemetryChargeRateMilliamps(
                batteryPowerMilliwatts: nil,
                voltageMillivolts: 12000
            )
        )
    }

    func testTelemetryChargeRateMilliampsReturnsNilForNilVoltage() {
        XCTAssertNil(
            SystemStats.telemetryChargeRateMilliamps(
                batteryPowerMilliwatts: -15000,
                voltageMillivolts: nil
            )
        )
    }

    func testTelemetryChargeRateMilliampsReturnsNilForZeroVoltage() {
        XCTAssertNil(
            SystemStats.telemetryChargeRateMilliamps(
                batteryPowerMilliwatts: -15000,
                voltageMillivolts: 0
            )
        )
    }

    func testBatteryChargeRateMilliampsReturnsNilForNilInput() {
        XCTAssertNil(SystemStats.batteryChargeRateMilliamps(nil))
    }

    func testBatteryChargeRateMilliampsReturnsNilForZero() {
        XCTAssertNil(SystemStats.batteryChargeRateMilliamps(0))
    }

    func testBatteryChargeRateMilliampsReturnsAbsoluteValueForNegativeAmperage() {
        XCTAssertEqual(SystemStats.batteryChargeRateMilliamps(-1500), 1500)
    }

    func testBatteryChargeRateMilliampsReturnsPositiveAmperage() {
        XCTAssertEqual(SystemStats.batteryChargeRateMilliamps(1500), 1500)
    }
}
