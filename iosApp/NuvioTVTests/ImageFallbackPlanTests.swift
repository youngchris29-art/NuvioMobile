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
            onFailure: { url, _ in failures.append(url) }
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

    func testInitialRenderUncachedPrimaryCachedFallbackStillFetchesPrimary() async {
        // Primary uncached, fallback cached, primary not failed: fallback is only a placeholder.
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(primaryCached: false, fallbackCached: true,
                                            primaryFailed: false, hasFallback: true),
            .showFallbackThenFetchPrimary)
        // ...and the walk that follows fetches the primary first.
        var fetched: [URL] = []
        let result: String? = await ImageFallbackPlan.firstLoaded(
            candidates: [custom, raw],
            skip: { _ in false },
            fetch: { url in fetched.append(url); return url == self.custom ? "custom" : "raw" }
        )
        XCTAssertEqual(result, "custom")
        XCTAssertEqual(fetched, [custom])
    }

    func testInitialRenderOtherCases() {
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(primaryCached: false, fallbackCached: true,
                                            primaryFailed: true, hasFallback: true), .showFallback)
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(primaryCached: true, fallbackCached: true,
                                            primaryFailed: false, hasFallback: true), .showPrimary)
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(primaryCached: false, fallbackCached: false,
                                            primaryFailed: false, hasFallback: true), .fetch)
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(primaryCached: false, fallbackCached: true,
                                            primaryFailed: false, hasFallback: false), .fetch)
    }

    func testOnlyDefinitiveFailuresAreRecorded() {
        XCTAssertTrue(ArtworkStore.isDefinitiveFailure(ArtworkFetchError.http(404)))
        XCTAssertTrue(ArtworkStore.isDefinitiveFailure(ArtworkFetchError.notImage))
        XCTAssertFalse(ArtworkStore.isDefinitiveFailure(ArtworkFetchError.http(503)))
        XCTAssertFalse(ArtworkStore.isDefinitiveFailure(ArtworkFetchError.http(429)))
        XCTAssertFalse(ArtworkStore.isDefinitiveFailure(URLError(.timedOut)))
        XCTAssertFalse(ArtworkStore.isDefinitiveFailure(URLError(.notConnectedToInternet)))
        XCTAssertFalse(ArtworkStore.isDefinitiveFailure(CancellationError()))
    }

    func testFailureMemoExpiresAndClears() {
        ArtworkStore.clearFailedURLs()
        let t0 = Date()
        ArtworkStore.noteFailure(custom, now: t0)
        XCTAssertTrue(ArtworkStore.hasFailed(custom, now: t0.addingTimeInterval(60)))
        XCTAssertFalse(ArtworkStore.hasFailed(custom, now: t0.addingTimeInterval(ArtworkStore.failedURLTTL + 1)))
        ArtworkStore.noteFailure(custom, now: t0)
        ArtworkStore.clearFailedURLs()
        XCTAssertFalse(ArtworkStore.hasFailed(custom, now: t0))
    }
}
