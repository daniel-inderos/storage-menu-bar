import XCTest
@testable import StorageBar

final class ReclaimScannerTests: XCTestCase {
    private var temporaryRoots: [URL] = []
    private var deniedDirectories: [URL] = []

    override func tearDown() {
        for deniedDirectory in deniedDirectories {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deniedDirectory.path)
        }
        deniedDirectories.removeAll()

        for root in temporaryRoots.reversed() {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()

        super.tearDown()
    }

    func testScanSizedDirectoryReturnsTotalSize() throws {
        let root = try makeTemporaryRoot()
        let sized = root.appendingPathComponent("sized")
        try FileManager.default.createDirectory(at: sized, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10_000).write(to: sized.appendingPathComponent("a.bin"))
        try Data(repeating: 1, count: 20_000).write(to: sized.appendingPathComponent("b.bin"))

        let scanner = makeScanner(for: sized)
        let result = try XCTUnwrap(scanResult(from: scanner))

        if case .size(let n) = result {
            XCTAssertGreaterThanOrEqual(n, 30_000)
        } else {
            XCTFail("expected .size, got \(result)")
        }
    }

    func testScanUnreadableDirectoryReturnsDenied() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")

        let root = try makeTemporaryRoot()
        let denied = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1_024).write(to: denied.appendingPathComponent("blocked.bin"))
        deniedDirectories.append(denied)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)

        let scanner = makeScanner(for: denied)
        let result = try XCTUnwrap(scanResult(from: scanner))

        XCTAssertEqual(result, .denied)
    }

    func testScanNonexistentPathReturnsMissing() throws {
        let root = try makeTemporaryRoot()
        let missing = root.appendingPathComponent("does-not-exist")

        let scanner = makeScanner(for: missing)
        let result = try XCTUnwrap(scanResult(from: scanner))

        XCTAssertEqual(result, .missing)
    }

    func testScanFileInsteadOfDirectoryReturnsMissing() throws {
        let root = try makeTemporaryRoot()
        let file = root.appendingPathComponent("plain-file.txt")
        try Data(repeating: 3, count: 1_024).write(to: file)

        let scanner = makeScanner(for: file)
        let result = try XCTUnwrap(scanResult(from: scanner))

        XCTAssertEqual(result, .missing)
    }

    func testCacheFreshSkipsRescan() throws {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let scanner = try makeCacheTestScanner(now: { fakeNow })

        waitForScanCompletion(scanner)
        fakeNow += 299

        let noCompletion = expectation(description: "fresh cache skips completion")
        noCompletion.isInverted = true
        scanner.scanIfStale(
            resultHandler: { _, _ in },
            completion: { _ in noCompletion.fulfill() }
        )
        wait(for: [noCompletion], timeout: 0.5)
    }

    func testCacheStaleTriggersRescan() throws {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let scanner = try makeCacheTestScanner(now: { fakeNow })

        waitForScanCompletion(scanner)
        fakeNow += 301

        waitForScanCompletion(scanner)
    }

    func testInvalidateCacheForcesRescan() throws {
        let fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let scanner = try makeCacheTestScanner(now: { fakeNow })

        waitForScanCompletion(scanner)
        scanner.invalidateCache()
        waitForScanCompletion(scanner)
    }

    func testConcurrentCallsOnlyRescanOnce() throws {
        let root = try makeTemporaryRoot()
        let many = root.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<50 {
            try Data("file-\(index)".utf8).write(to: many.appendingPathComponent("\(index).txt"))
        }

        let fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let scanner = ReclaimScanner(targets: [makeTarget(for: many)], now: { fakeNow })
        let firstCompletion = expectation(description: "first scan completion")
        let secondCompletion = expectation(description: "second scan completion")
        secondCompletion.isInverted = true
        var completionCount = 0

        let completion: ([ReclaimScanner.ScanResult]) -> Void = { _ in
            completionCount += 1
            if completionCount == 1 {
                firstCompletion.fulfill()
            } else {
                secondCompletion.fulfill()
            }
        }

        scanner.scanIfStale(resultHandler: { _, _ in }, completion: completion)
        scanner.scanIfStale(resultHandler: { _, _ in }, completion: completion)

        wait(for: [firstCompletion], timeout: 5.0)
        wait(for: [secondCompletion], timeout: 0.5)
        XCTAssertEqual(completionCount, 1)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storagebar-reclaim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private func makeTarget(for url: URL) -> ReclaimScanner.Target {
        ReclaimScanner.Target(label: "Test", url: url, accessHint: .filesAndFolders)
    }

    private func makeScanner(for url: URL) -> ReclaimScanner {
        ReclaimScanner(
            targets: [makeTarget(for: url)],
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }

    private func makeCacheTestScanner(now: @escaping () -> Date = Date.init) throws -> ReclaimScanner {
        let root = try makeTemporaryRoot()
        let sized = root.appendingPathComponent("sized")
        try FileManager.default.createDirectory(at: sized, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 1_024).write(to: sized.appendingPathComponent("cache.bin"))
        return ReclaimScanner(targets: [makeTarget(for: sized)], now: now)
    }

    private func scanResult(
        from scanner: ReclaimScanner,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ReclaimScanner.Result? {
        let completionExpectation = expectation(description: "scan completion")
        var result: ReclaimScanner.Result?
        scanner.scanIfStale(
            resultHandler: { _, _ in },
            completion: { scanResults in
                XCTAssertEqual(scanResults.count, 1, file: file, line: line)
                result = scanResults.first?.result
                completionExpectation.fulfill()
            }
        )
        wait(for: [completionExpectation], timeout: 5.0)
        return result
    }

    private func waitForScanCompletion(
        _ scanner: ReclaimScanner,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let completionExpectation = expectation(description: "scan completion")
        scanner.scanIfStale(
            resultHandler: { _, _ in },
            completion: { scanResults in
                XCTAssertEqual(scanResults.count, 1, file: file, line: line)
                completionExpectation.fulfill()
            }
        )
        wait(for: [completionExpectation], timeout: 5.0)
    }
}
