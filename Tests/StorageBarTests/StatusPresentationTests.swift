import XCTest
@testable import StorageBar

final class StatusPresentationTests: XCTestCase {
    func testTitlesForDisplayModes() {
        let disk = DiskInfo(
            volumeName: "Test",
            total: 100_000_000_000,
            available: 25_000_000_000,
            free: 25_000_000_000
        )

        XCTAssertEqual(StatusPresentation.title(for: disk, display: .freeSpace), " 25.0 GB")
        XCTAssertEqual(StatusPresentation.title(for: disk, display: .usedPercent), " 75%")
        XCTAssertEqual(StatusPresentation.title(for: disk, display: .iconOnly), "")
    }

    func testSeverityBoundaries() {
        XCTAssertEqual(
            StatusPresentation.severity(forAvailableBytes: 9_999_999_999, warnBelowGB: 10),
            .warning
        )
        XCTAssertEqual(
            StatusPresentation.severity(forAvailableBytes: 4_999_999_999, warnBelowGB: 10),
            .critical
        )
        XCTAssertEqual(
            StatusPresentation.severity(forAvailableBytes: 5_000_000_000, warnBelowGB: 10),
            .warning
        )
        XCTAssertEqual(
            StatusPresentation.severity(forAvailableBytes: 10_000_000_000, warnBelowGB: 10),
            .normal
        )
        XCTAssertEqual(
            StatusPresentation.severity(forAvailableBytes: 1, warnBelowGB: 0),
            .normal
        )
    }

    func testLowSpaceTransitionHysteresis() {
        var transition = StatusPresentation.lowSpaceTransition(
            availableBytes: 9_999_999_999,
            warnBelowGB: 10,
            alreadyNotified: false
        )
        XCTAssertTrue(transition.shouldNotify)
        XCTAssertTrue(transition.newNotifiedFlag)

        transition = StatusPresentation.lowSpaceTransition(
            availableBytes: 9_000_000_000,
            warnBelowGB: 10,
            alreadyNotified: transition.newNotifiedFlag
        )
        XCTAssertFalse(transition.shouldNotify)
        XCTAssertTrue(transition.newNotifiedFlag)

        transition = StatusPresentation.lowSpaceTransition(
            availableBytes: 10_500_000_000,
            warnBelowGB: 10,
            alreadyNotified: transition.newNotifiedFlag
        )
        XCTAssertFalse(transition.shouldNotify)
        XCTAssertTrue(transition.newNotifiedFlag)

        transition = StatusPresentation.lowSpaceTransition(
            availableBytes: 11_000_000_000,
            warnBelowGB: 10,
            alreadyNotified: transition.newNotifiedFlag
        )
        XCTAssertFalse(transition.shouldNotify)
        XCTAssertTrue(transition.newNotifiedFlag)

        transition = StatusPresentation.lowSpaceTransition(
            availableBytes: 11_000_000_001,
            warnBelowGB: 10,
            alreadyNotified: transition.newNotifiedFlag
        )
        XCTAssertFalse(transition.shouldNotify)
        XCTAssertFalse(transition.newNotifiedFlag)

        transition = StatusPresentation.lowSpaceTransition(
            availableBytes: 1,
            warnBelowGB: 0,
            alreadyNotified: true
        )
        XCTAssertFalse(transition.shouldNotify)
        XCTAssertFalse(transition.newNotifiedFlag)
    }
}
