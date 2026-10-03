import XCTest
@testable import NuvioTV

/// Custom poster URL feature: `CachedAsyncImage` retries the original art once when the pattern
/// URL fails. The attempt order lives in the pure `ImageFallbackPlan`.
///
/// beta.19-rc1 verdict (I1, BUG-134): the chain is now `[upgraded larger file, primary, fallback]`
/// (at most three), the first frame prefers the head at the requested size, then any placeholder, and
/// every non-last candidate gets the short request window and the failure memo, not just a custom
/// primary.
@MainActor
final class ImageFallbackPlanTests: XCTestCase {
    private let custom = URL(string: "https://posters.example/tt1.jpg")!
    private let raw = URL(string: "https://addon.example/tt1.jpg")!
    private let medium = URL(string: "https://images.metahub.space/poster/medium/tt0111161/img")!
    private let large = URL(string: "https://images.metahub.space/poster/large/tt0111161/img")!

    private struct Boom: Error {}

    func testCandidatesPrimaryThenDistinctFallback() {
        XCTAssertEqual(ImageFallbackPlan.candidates(upgraded: nil, primary: custom, fallback: raw), [custom, raw])
        XCTAssertEqual(ImageFallbackPlan.candidates(upgraded: nil, primary: custom, fallback: custom), [custom])
        XCTAssertEqual(ImageFallbackPlan.candidates(upgraded: nil, primary: custom, fallback: nil), [custom])
        XCTAssertEqual(ImageFallbackPlan.candidates(upgraded: nil, primary: nil, fallback: raw), [raw])
        XCTAssertTrue(ImageFallbackPlan.candidates(upgraded: nil, primary: nil, fallback: nil).isEmpty)
        // The two-argument form (kept for source compatibility) is the same without an upgrade.
        XCTAssertEqual(ImageFallbackPlan.candidates(primary: custom, fallback: raw), [custom, raw])
    }

    func testChainOrderUpgradeThenPrimaryThenFallback() {
        XCTAssertEqual(ImageFallbackPlan.candidates(upgraded: large, primary: medium, fallback: raw), [large, medium, raw])
        // Deduped: an upgrade equal to the primary, or a fallback equal to either, never repeats.
        XCTAssertEqual(ImageFallbackPlan.candidates(upgraded: medium, primary: medium, fallback: raw), [medium, raw])
        XCTAssertEqual(ImageFallbackPlan.candidates(upgraded: large, primary: medium, fallback: large), [large, medium])
        XCTAssertEqual(ImageFallbackPlan.candidates(upgraded: large, primary: medium, fallback: nil), [large, medium])
        // At most three, so a walk can never loop.
        XCTAssertLessThanOrEqual(ImageFallbackPlan.candidates(upgraded: large, primary: medium, fallback: raw).count, 3)
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
        // Head uncached, a placeholder cached, nothing known-failed: the placeholder is only a stand-in.
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(headCached: false, placeholderCached: true,
                                            primaryFailed: false, hasFallback: true),
            .showPlaceholderThenFetch)
        // ...and the walk that follows fetches the head first.
        var fetched: [URL] = []
        let result: String? = await ImageFallbackPlan.firstLoaded(
            candidates: [custom, raw],
            skip: { _ in false },
            fetch: { url in fetched.append(url); return url == self.custom ? "custom" : "raw" }
        )
        XCTAssertEqual(result, "custom")
        XCTAssertEqual(fetched, [custom])
    }

    func testPlaceholderShownThenHeadFetched() async {
        // A smaller decode (or a sibling rendition) of the same picture is in memory, the head at the
        // requested size is not: show the placeholder with no shimmer, then fetch the head and swap.
        // This is also the single-URL case, which used to be `.fetch`: a placeholder needs no fallback.
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(headCached: false, placeholderCached: true,
                                            primaryFailed: false, hasFallback: false),
            .showPlaceholderThenFetch)
        var fetched: [URL] = []
        let result: String? = await ImageFallbackPlan.firstLoaded(
            candidates: [large, medium],
            skip: { _ in false },
            fetch: { url in fetched.append(url); return url == self.large ? "large" : "medium" }
        )
        XCTAssertEqual(result, "large")
        XCTAssertEqual(fetched, [large])
    }

    func testInitialRenderOtherCases() {
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(headCached: false, placeholderCached: true,
                                            primaryFailed: true, hasFallback: true), .showFallback)
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(headCached: true, placeholderCached: true,
                                            primaryFailed: false, hasFallback: true), .showHead)
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(headCached: false, placeholderCached: false,
                                            primaryFailed: false, hasFallback: true), .fetch)
        // The head wins over everything, known-failed or not.
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(headCached: true, placeholderCached: false,
                                            primaryFailed: true, hasFallback: true), .showHead)
        // Nothing in memory is a plain fetch whatever else is true.
        XCTAssertEqual(
            ImageFallbackPlan.initialRender(headCached: false, placeholderCached: false,
                                            primaryFailed: true, hasFallback: false), .fetch)
    }

    func testNonLastCandidateFailureRecorded() async {
        // The upgraded larger file 404s (a definitive failure): it is recorded, the primary loads.
        ArtworkStore.clearFailedURLs()
        defer { ArtworkStore.clearFailedURLs() }
        let candidates = [large, medium]
        var fetched: [URL] = []
        let result: String? = await ImageFallbackPlan.firstLoaded(
            candidates: candidates,
            skip: { ArtworkStore.hasFailed($0) },
            fetch: { url in
                fetched.append(url)
                if url == self.large { throw ArtworkFetchError.http(404) }
                return "medium"
            },
            onFailure: { url, error in
                ImageFallbackPlan.recordFailureIfNeeded(url, in: candidates, error: error)
            }
        )
        XCTAssertEqual(result, "medium")
        XCTAssertEqual(fetched, [large, medium])
        XCTAssertTrue(ArtworkStore.hasFailed(large))
        XCTAssertFalse(ArtworkStore.hasFailed(medium))

        // A remount skips the known-missing file and goes straight to the primary.
        fetched = []
        let second: String? = await ImageFallbackPlan.firstLoaded(
            candidates: candidates,
            skip: { ArtworkStore.hasFailed($0) },
            fetch: { url in fetched.append(url); return "medium" }
        )
        XCTAssertEqual(second, "medium")
        XCTAssertEqual(fetched, [medium])
    }

    func testFailureRecordingRules() {
        ArtworkStore.clearFailedURLs()
        defer { ArtworkStore.clearFailedURLs() }
        let candidates = [large, medium, raw]
        // Transient failures are never recorded.
        ImageFallbackPlan.recordFailureIfNeeded(large, in: candidates, error: URLError(.timedOut))
        ImageFallbackPlan.recordFailureIfNeeded(large, in: candidates, error: ArtworkFetchError.http(503))
        XCTAssertFalse(ArtworkStore.hasFailed(large))
        // The LAST candidate is never recorded, even on a 404: nothing is behind it and a remount must retry.
        ImageFallbackPlan.recordFailureIfNeeded(raw, in: candidates, error: ArtworkFetchError.http(404))
        XCTAssertFalse(ArtworkStore.hasFailed(raw))
        // A middle candidate is.
        ImageFallbackPlan.recordFailureIfNeeded(medium, in: candidates, error: ArtworkFetchError.notImage)
        XCTAssertTrue(ArtworkStore.hasFailed(medium))
        // A single-URL load records nothing.
        ArtworkStore.clearFailedURLs()
        ImageFallbackPlan.recordFailureIfNeeded(custom, in: [custom], error: ArtworkFetchError.http(404))
        XCTAssertFalse(ArtworkStore.hasFailed(custom))
    }

    func testNonLastCandidatesGetTheShortRequestWindow() {
        let candidates = [large, medium, raw]
        XCTAssertEqual(ImageFallbackPlan.requestTimeout(for: large, in: candidates), 8)
        XCTAssertEqual(ImageFallbackPlan.requestTimeout(for: medium, in: candidates), 8)
        XCTAssertNil(ImageFallbackPlan.requestTimeout(for: raw, in: candidates))
        // A plain single-URL load keeps the session's own window.
        XCTAssertNil(ImageFallbackPlan.requestTimeout(for: custom, in: [custom]))
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
