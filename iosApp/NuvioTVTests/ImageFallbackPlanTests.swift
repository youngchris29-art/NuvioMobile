import XCTest
@testable import NuvioTV

/// Custom poster URL feature: `CachedAsyncImage` retries the original art once when the pattern
/// URL fails. The attempt order lives in the pure `ImageFallbackPlan`.
@MainActor
final class ImageFallbackPlanTests: XCTestCase {
    private let custom = URL(string: "https://posters.example/tt1.jpg")!
    private let raw = URL(string: "https://addon.example/tt1.jpg")!

    private struct Boom: Error {}

    func testCandidatesPrimaryThenDistinctFallback() {
        XCTAssertEqual(ImageFallbackPlan.candidates(primary: custom, fallback: raw), [custom, raw])
        XCTAssertEqual(ImageFallbackPlan.candidates(primary: custom, fallback: custom), [custom])
        XCTAssertEqual(ImageFallbackPlan.candidates(primary: custom, fallback: nil), [custom])
        XCTAssertEqual(ImageFallbackPlan.candidates(primary: nil, fallback: raw), [raw])
        XCTAssertTrue(ImageFallbackPlan.candidates(primary: nil, fallback: nil).isEmpty)
    }

    func testPrimaryFailureTriesFallbackOnce() async {
        var fetched: [URL] = []
        let result: String? = await ImageFallbackPlan.firstLoaded(
            candidates: [custom, raw],
            fetch: { url in
                fetched.append(url)
                if url == self.custom { throw Boom() }
                return "raw"
            }
        )
        XCTAssertEqual(result, "raw")
        XCTAssertEqual(fetched, [custom, raw])
    }

    func testFailsOnlyAfterBothAttempts() async {
        var fetched: [URL] = []
        var failures: [URL] = []
        let result: String? = await ImageFallbackPlan.firstLoaded(
            candidates: [custom, raw],
            fetch: { url in fetched.append(url); throw Boom() },
            onFailure: { failures.append($0) }
        )
        XCTAssertNil(result)
        XCTAssertEqual(fetched, [custom, raw])
        XCTAssertEqual(failures, [custom, raw])
    }

    func testKnownFailedPrimarySkippedButLastCandidateStillTried() async {
        var fetched: [URL] = []
        let skipped: String? = await ImageFallbackPlan.firstLoaded(
            candidates: [custom, raw],
            skip: { $0 == self.custom },
            fetch: { url in fetched.append(url); return "ok" }
        )
        XCTAssertEqual(skipped, "ok")
        XCTAssertEqual(fetched, [raw])

        fetched = []
        let single: String? = await ImageFallbackPlan.firstLoaded(
            candidates: [custom],
            skip: { _ in true },
            fetch: { url in fetched.append(url); return "ok" }
        )
        XCTAssertEqual(single, "ok")
        XCTAssertEqual(fetched, [custom])
    }
}
