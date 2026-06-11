import XCTest
@testable import StorageBar

final class UpdateCheckerNetworkTests: XCTestCase {
    private var originalSession: URLSession!

    override func setUp() {
        super.setUp()
        originalSession = UpdateChecker.session
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        UpdateChecker.session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        UpdateChecker.session.invalidateAndCancel()
        UpdateChecker.session = originalSession
        StubURLProtocol.statusCode = 200
        StubURLProtocol.data = Data()
        StubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testFetchLatestReturnsReleaseFromValidResponse() throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.data = Data("""
        {"tag_name":"v1.2.3","html_url":"https://example.com/release"}
        """.utf8)
        let expectation = expectation(description: "fetch latest")

        UpdateChecker.fetchLatest { result in
            switch result {
            case .success(let latest):
                XCTAssertEqual(latest.version, "v1.2.3")
                XCTAssertEqual(latest.page.absoluteString, "https://example.com/release")
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "StorageBar/\(version)")
    }

    func testFetchLatestFailsForHTTPError() {
        StubURLProtocol.statusCode = 500
        StubURLProtocol.data = Data("""
        {"message":"server error"}
        """.utf8)
        let expectation = expectation(description: "fetch latest")

        UpdateChecker.fetchLatest { result in
            if case .success(let latest) = result {
                XCTFail("expected failure, got \(latest)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
    }

    func testFetchLatestFailsForMalformedJSON() {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.data = Data("not json".utf8)
        let expectation = expectation(description: "fetch latest")

        UpdateChecker.fetchLatest { result in
            if case .success(let latest) = result {
                XCTFail("expected failure, got \(latest)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
    }

    func testFetchLatestFailsWithoutTagName() {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.data = Data("""
        {"html_url":"https://example.com/release"}
        """.utf8)
        let expectation = expectation(description: "fetch latest")

        UpdateChecker.fetchLatest { result in
            if case .success(let latest) = result {
                XCTFail("expected failure, got \(latest)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var statusCode = 200
    static var data = Data()
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
