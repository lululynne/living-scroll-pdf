import Foundation
import XCTest
@testable import LivingScrollPDF

final class UpdateCheckerTests: XCTestCase {
    private final class FakeSession: UpdateNetworking {
        var result: Result<(Data, URLResponse), Error>

        init(_ result: Result<(Data, URLResponse), Error>) { self.result = result }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try result.get()
        }
    }

    private func defaults() -> UserDefaults {
        let suite = "UpdateCheckerTests.\(UUID().uuidString)"
        let value = UserDefaults(suiteName: suite)!
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }

    private func response(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.test/version.json")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func manifest(version: String = "0.10.0") -> Data {
        Data("""
        {"latest":{"version":"\(version)","date":"2026-11-27","download_url":"https://example.test/app.zip","notes_zh":["修复"],"notes_en":["Fixes"],"min_macos":"14","published":true},"releases":[]}
        """.utf8)
    }

    func testVersionComparisonUsesNumericSegments() {
        XCTAssertEqual(UpdateChecker.compareVersions("0.10.0", "0.9.0"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compareVersions("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compareVersions("0.2.1", "0.3.0"), .orderedAscending)
    }

    func testParsesManifestAndFindsAvailableUpdate() async throws {
        let checker = UpdateChecker(baseURL: URL(string: "https://example.test")!, session: FakeSession(.success((manifest(), response()))), defaults: defaults(), currentVersion: "0.9.0")
        let result = try await checker.check()
        guard case .available(let release, let current) = result else { return XCTFail("expected available update") }
        XCTAssertEqual(release.version, "0.10.0")
        XCTAssertEqual(current, "0.9.0")
        XCTAssertEqual(release.notesZH, ["修复"])
    }

    func testFailurePathRejectsNonSuccessHTTP() async {
        let checker = UpdateChecker(session: FakeSession(.success((manifest(), response(status: 500)))), defaults: defaults(), currentVersion: "0.9.0")
        do {
            _ = try await checker.check()
            XCTFail("expected HTTP failure")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    func testTwentyFourHourThrottleAndSkipVersion() {
        let defaults = defaults()
        let checker = UpdateChecker(defaults: defaults, currentVersion: "0.2.1")
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(checker.shouldCheckAutomatically(now: now))
        checker.markChecked(at: now)
        XCTAssertFalse(checker.shouldCheckAutomatically(now: now.addingTimeInterval(23 * 60 * 60 + 59)))
        XCTAssertTrue(checker.shouldCheckAutomatically(now: now.addingTimeInterval(24 * 60 * 60)))
        checker.skip(version: "0.3.0")
        XCTAssertEqual(checker.skippedVersion, "0.3.0")
    }
}
