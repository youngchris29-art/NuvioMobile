import SharedCore
import XCTest
@testable import NuvioTV

/// A loader whose answers the test controls: every call is recorded and suspends until
/// `resolve(_:with:)`, unless `autoAnswer` is set.
@MainActor
private final class WashLoaderStub {
    private(set) var calls: [String] = []
    private var waiting: [String: CheckedContinuation<AmbientWashRenderer.Output?, Never>] = [:]
    /// When set, every load answers at once with it.
    var autoAnswer: AmbientWashRenderer.Output?

    func load(_ art: WashArt) async -> AmbientWashRenderer.Output? {
        calls.append(art.identity)
        if let autoAnswer { return autoAnswer }
        return await withCheckedContinuation { continuation in
            waiting[art.identity] = continuation
        }
    }

    func resolve(_ identity: String, with output: AmbientWashRenderer.Output?) {
        waiting.removeValue(forKey: identity)?.resume(returning: output)
    }
}

/// Home Stage & Strip (H3, W1-B; P2 spec sections 1.3, 1.4 and 4.2): `AmbientWashModel`, the state
/// behind `AmbientWashLayer` (`DesignSystem/AmbientWashLayer.swift`), plus the small pure pieces that
/// sit beside it (`WashArt`, the dimming rule, the probe line). The loader is injected, so a test
/// decides which load resolves when (the production loader is cache, then `ArtworkStore`, then a
/// detached render: nothing here touches the network or the image store). The debounce tests use the
/// real 0.15 s timer, so each of them waits a few tenths of a second.
@MainActor
final class AmbientWashModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makeOutput(luma: Float = 0.2) throws -> AmbientWashRenderer.Output {
        let pixels = [Float](repeating: luma, count: AmbientWashTuning.width * AmbientWashTuning.height * 3)
        let image = try XCTUnwrap(AmbientWashRenderer.makeCGImage(
            pixels, width: AmbientWashTuning.width, height: AmbientWashTuning.height))
        return AmbientWashRenderer.Output(image: image, meanLuma: luma, millis: 1)
    }

    private func art(_ identity: String) -> WashArt {
        WashArt(identity: identity, urls: [URL(string: "https://example.invalid/\(identity).jpg")])
    }

    /// Lets every task the model started run until it suspends or finishes.
    private func drain() async {
        for _ in 0..<30 { await Task.yield() }
    }

    /// Waits (polling every 5 ms, up to `timeout`) for `condition`. `drain()`'s fixed yields are a
    /// timing assumption: on a busy machine the model's next load can start after them (a gate run
    /// on 2026-10-05 failed that way once in many), so assertions about a load that must START wait
    /// for it instead.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeItem(id: String, type: String = "movie", poster: String? = nil, banner: String? = nil) -> MetaPreview {
        MetaPreview(
            id: id, type: type, name: "Title",
            poster: poster, banner: banner, logo: nil,
            posterShape: .landscape,
            description: nil, releaseInfo: nil, rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: [],
            rawPosterUrl: nil,
            landscapePoster: nil,
            rawLandscapePosterUrl: nil,
            customPosterApplied: false
        )
    }

    // MARK: - show

    func testShowCommitsAnIncomingLayerThenPromoteMakesItTheBase() async throws {
        let stub = WashLoaderStub()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        // Cold launch: no layers until the first show resolves.
        XCTAssertNil(model.base)
        XCTAssertNil(model.incoming)
        XCTAssertFalse(model.isShown)

        model.show(art("movie:a"))
        await drain()
        XCTAssertEqual(stub.calls, ["movie:a"])
        XCTAssertNil(model.incoming, "nothing is committed until the image arrives")

        stub.resolve("movie:a", with: try makeOutput(luma: 0.2))
        await drain()
        let incoming = try XCTUnwrap(model.incoming)
        XCTAssertEqual(incoming.identity, "movie:a")
        XCTAssertNil(model.base, "the first layer fades in over the page background")
        XCTAssertEqual(model.incomingOpacity, 0, "it starts invisible; the view animates it to 1")
        XCTAssertEqual(model.generation, 1)
        XCTAssertEqual(incoming.id, 1)
        XCTAssertEqual(model.shownIdentity, "movie:a")
        XCTAssertTrue(model.isShown)
        XCTAssertEqual(model.lastMeanLuma, 0.2, accuracy: 1e-6)

        model.promote(incoming.id)
        XCTAssertEqual(model.base?.identity, "movie:a")
        XCTAssertNil(model.incoming)
        XCTAssertEqual(model.incomingOpacity, 0)
        XCTAssertEqual(model.shownIdentity, "movie:a")
    }

    func testPromoteOfAnotherLayerIsIgnored() async throws {
        let stub = WashLoaderStub()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        model.show(art("movie:a"))
        await drain()
        stub.resolve("movie:a", with: try makeOutput())
        await drain()
        let incoming = try XCTUnwrap(model.incoming)
        model.promote(incoming.id + 99)
        XCTAssertNil(model.base)
        XCTAssertEqual(model.incoming?.id, incoming.id)
    }

    func testShowOfTheSameIdentityIsANoOp() async throws {
        let stub = WashLoaderStub()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        model.show(art("movie:a"))
        model.show(art("movie:a"))   // already being loaded
        await drain()
        XCTAssertEqual(stub.calls, ["movie:a"], "one load, not two")
        stub.resolve("movie:a", with: try makeOutput())
        await drain()
        let incoming = try XCTUnwrap(model.incoming)

        model.show(art("movie:a"))   // already fading in
        await drain()
        XCTAssertEqual(stub.calls, ["movie:a"])
        XCTAssertEqual(model.incoming?.id, incoming.id, "a duplicate show must not restart or cut the fade")
        XCTAssertNil(model.base)

        model.promote(incoming.id)
        model.show(art("movie:a"))   // already the base
        await drain()
        XCTAssertEqual(stub.calls, ["movie:a"])
        XCTAssertEqual(model.generation, 1)
        XCTAssertNil(model.incoming)
    }

    func testShowNilKeepsTheCurrentWash() async throws {
        let stub = WashLoaderStub()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        model.show(art("movie:a"))
        await drain()
        stub.resolve("movie:a", with: try makeOutput())
        await drain()
        let incoming = try XCTUnwrap(model.incoming)
        model.promote(incoming.id)

        model.show(nil)   // the genre chips row, the See All tile
        await drain()
        XCTAssertEqual(model.base?.identity, "movie:a")
        XCTAssertNil(model.incoming)
        XCTAssertEqual(stub.calls, ["movie:a"])
        XCTAssertEqual(model.generation, 1)
    }

    func testStaleLateImageIsDropped() async throws {
        let stub = WashLoaderStub()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        model.show(art("movie:a"))
        model.show(art("movie:b"))
        await drain()
        XCTAssertEqual(stub.calls, ["movie:a", "movie:b"])

        stub.resolve("movie:b", with: try makeOutput(luma: 0.3))
        await drain()
        XCTAssertEqual(model.incoming?.identity, "movie:b")

        // A's image finally lands, after B's: it must not replace B.
        stub.resolve("movie:a", with: try makeOutput(luma: 0.1))
        await drain()
        XCTAssertEqual(model.incoming?.identity, "movie:b")
        XCTAssertNil(model.base)
        XCTAssertEqual(model.generation, 1)
        XCTAssertEqual(model.lastMeanLuma, 0.3, accuracy: 1e-6)
    }

    func testShowDuringAFadePromotesTheIncomingLayerFirst() async throws {
        let stub = WashLoaderStub()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        model.show(art("movie:a"))
        await drain()
        stub.resolve("movie:a", with: try makeOutput())
        await drain()
        XCTAssertEqual(model.incoming?.identity, "movie:a", "A is mid-fade")

        model.show(art("movie:b"))   // synchronous: A is promoted at once
        XCTAssertEqual(model.base?.identity, "movie:a")
        XCTAssertNil(model.incoming)
        XCTAssertEqual(model.incomingOpacity, 0)

        await drain()
        stub.resolve("movie:b", with: try makeOutput())
        await drain()
        XCTAssertEqual(model.incoming?.identity, "movie:b")
        XCTAssertEqual(model.base?.identity, "movie:a")
        XCTAssertEqual(model.generation, 2)
    }

    func testGoingBackToTheShownWashForgetsTheLoadInFlight() async throws {
        let stub = WashLoaderStub()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        model.show(art("movie:a"))
        await drain()
        stub.resolve("movie:a", with: try makeOutput())
        await drain()
        model.promote(try XCTUnwrap(model.incoming).id)

        model.show(art("movie:b"))   // B starts loading
        await drain()
        model.show(art("movie:a"))   // the stage is back on A before B arrived
        await drain()
        stub.resolve("movie:b", with: try makeOutput())
        await drain()
        XCTAssertNil(model.incoming, "B is stale now")
        XCTAssertEqual(model.base?.identity, "movie:a")
        XCTAssertEqual(stub.calls, ["movie:a", "movie:b"], "no second load of A")
        XCTAssertEqual(model.generation, 1)
    }

    func testAFailedLoadKeepsTheCurrentWashAndCanBeRetried() async throws {
        let stub = WashLoaderStub()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        model.show(art("movie:a"))
        await drain()
        stub.resolve("movie:a", with: nil)
        await drain()
        XCTAssertNil(model.incoming)
        XCTAssertNil(model.base)
        XCTAssertEqual(model.generation, 0)

        model.show(art("movie:a"))   // not stuck on "already wanted": the stage can ask again
        await waitUntil { stub.calls.count == 2 }
        XCTAssertEqual(stub.calls, ["movie:a", "movie:a"])
        stub.resolve("movie:a", with: try makeOutput())
        await waitUntil { model.incoming != nil }
        XCTAssertEqual(model.incoming?.identity, "movie:a")
    }

    func testALateCommitCountsAndAnOnTimeOneDoesNot() async throws {
        // On time: a 5 s threshold cannot be missed by a test that resolves at once.
        let onTimeStub = WashLoaderStub()
        let onTime = AmbientWashModel(loader: { await onTimeStub.load($0) }, lateAfter: 5)
        onTime.show(art("movie:a"))
        await drain()
        try await Task.sleep(for: .seconds(0.1))
        onTimeStub.resolve("movie:a", with: try makeOutput())
        await drain()
        XCTAssertEqual(onTime.incoming?.identity, "movie:a")
        XCTAssertEqual(onTime.lateCount, 0)

        // Late: a 20 ms threshold is far behind a load that waits 150 ms. Counted once per late commit.
        let lateStub = WashLoaderStub()
        let late = AmbientWashModel(loader: { await lateStub.load($0) }, lateAfter: 0.02)
        late.show(art("movie:b"))
        await drain()
        try await Task.sleep(for: .seconds(0.15))
        lateStub.resolve("movie:b", with: try makeOutput())
        await drain()
        XCTAssertEqual(late.incoming?.identity, "movie:b")
        XCTAssertEqual(late.lateCount, 1)
    }

    // MARK: - prepare

    func testNothingLoadsInsideTheDebounce() async throws {
        let stub = WashLoaderStub()
        stub.autoAnswer = try makeOutput()
        // A 30 s debounce: still running when this test ends, so the model's deinit has to cancel it.
        let model = AmbientWashModel(loader: { await stub.load($0) }, debounce: 30)
        model.prepare(art("movie:a"))
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(stub.calls, [])
        XCTAssertNil(model.base)
        XCTAssertNil(model.incoming)
    }

    func testThreePreparesWithinTheDebounceLoadOnlyTheLast() async throws {
        let stub = WashLoaderStub()
        stub.autoAnswer = try makeOutput()
        // A 0.15 s debounce (the shipped number is `AmbientWashTuning.prepareDebounce`, pinned in the
        // renderer tests) and three prepares issued back to back, far inside it.
        let model = AmbientWashModel(loader: { await stub.load($0) }, debounce: 0.15)
        model.prepare(art("movie:a"))
        model.prepare(art("movie:b"))
        model.prepare(art("movie:c"))
        try await Task.sleep(for: .seconds(0.6))
        XCTAssertEqual(stub.calls, ["movie:c"], "one load, of the newest")
        // Prepare only warms the cache: it never shows anything.
        XCTAssertNil(model.base)
        XCTAssertNil(model.incoming)
        XCTAssertEqual(model.generation, 0)
    }

    func testPrepareNilCancelsThePendingWarmUp() async throws {
        let stub = WashLoaderStub()
        stub.autoAnswer = try makeOutput()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        model.prepare(art("movie:a"))
        model.prepare(nil)
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertEqual(stub.calls, [])
    }

    func testShowOfThePreparedTitleDoesNotLoadItTwice() async throws {
        let stub = WashLoaderStub()
        stub.autoAnswer = try makeOutput()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        model.prepare(art("movie:a"))
        model.show(art("movie:a"))   // the swap arrives before the debounce fires
        await drain()
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertEqual(stub.calls, ["movie:a"], "the show loads it; the sleeping prepare was cancelled")
        XCTAssertEqual(model.incoming?.identity, "movie:a")
    }

    func testPrepareSkipsTheTitleAlreadyOnScreen() async throws {
        let stub = WashLoaderStub()
        stub.autoAnswer = try makeOutput()
        let model = AmbientWashModel(loader: { await stub.load($0) })
        model.show(art("movie:a"))
        await drain()
        XCTAssertEqual(model.incoming?.identity, "movie:a")
        model.prepare(art("movie:a"))
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertEqual(stub.calls, ["movie:a"], "the wash for the shown title is already rendered")
    }

    // MARK: - Production loader

    func testLiveLoaderAnswersFromTheCacheBeforeAnythingElse() async throws {
        // A title already rendered (by an earlier `prepare` or show) comes straight back: no URL is
        // needed, so nothing reaches `ArtworkStore`.
        let identity = "movie:wash-live-hit-\(UUID().uuidString)"
        let output = try makeOutput(luma: 0.17)
        AmbientWashCache.shared.store(output, for: identity)
        let loaded = await AmbientWashModel.liveLoader(WashArt(identity: identity, urls: []))
        XCTAssertTrue(loaded?.image === output.image)
        XCTAssertEqual(loaded?.meanLuma ?? 0, 0.17, accuracy: 1e-6)
    }

    func testLiveLoaderLoadsNothingForATitleWithNoArtAndNoCacheEntry() async {
        let loaded = await AmbientWashModel.liveLoader(
            WashArt(identity: "movie:wash-live-none-\(UUID().uuidString)", urls: []))
        XCTAssertNil(loaded)
    }

    // MARK: - WashArt

    func testWashArtDedupesKeepsOrderAndCapsAtThree() throws {
        let a = try XCTUnwrap(URL(string: "https://example.invalid/a.jpg"))
        let b = try XCTUnwrap(URL(string: "https://example.invalid/b.jpg"))
        let c = try XCTUnwrap(URL(string: "https://example.invalid/c.jpg"))
        let d = try XCTUnwrap(URL(string: "https://example.invalid/d.jpg"))
        XCTAssertEqual(WashArt(identity: "movie:x", urls: [a, nil, a, b, c, d]).urls, [a, b, c])
        XCTAssertEqual(WashArt(identity: "movie:x", urls: [nil, nil]).urls, [])
        XCTAssertEqual(WashArt(identity: "movie:x", urls: [b, a]).urls, [b, a])
        XCTAssertEqual(WashArt(identity: "movie:x", urls: [a]), WashArt(identity: "movie:x", urls: [a, a]))
        XCTAssertNotEqual(WashArt(identity: "movie:x", urls: [a]), WashArt(identity: "movie:y", urls: [a]))
    }

    func testWashArtFromAnItemUsesTheStageBackdropChainThenThePoster() {
        // A banner wins, then the poster.
        let banner = makeItem(id: "tt0111161", poster: "https://example.invalid/poster.jpg",
                              banner: "https://example.invalid/banner.jpg")
        let withBanner = WashArt(item: banner)
        XCTAssertEqual(withBanner.identity, "movie:tt0111161")
        XCTAssertEqual(withBanner.urls.map(\.absoluteString),
                       ["https://example.invalid/banner.jpg", "https://example.invalid/poster.jpg"])

        // No banner, an IMDb id: the metahub background, then the poster (what the stage art draws).
        let imdb = makeItem(id: "tt0111161", poster: "https://example.invalid/poster.jpg")
        XCTAssertEqual(WashArt(item: imdb).urls.map(\.absoluteString),
                       ["https://images.metahub.space/background/medium/tt0111161/img",
                        "https://example.invalid/poster.jpg"])

        // No banner, no IMDb id: the backdrop chain already IS the poster, so it appears once.
        let other = makeItem(id: "kitsu:1234", poster: "https://example.invalid/poster.jpg")
        XCTAssertEqual(WashArt(item: other).urls.map(\.absoluteString), ["https://example.invalid/poster.jpg"])

        // Nothing at all.
        XCTAssertEqual(WashArt(item: makeItem(id: "kitsu:1234")).urls, [])
    }

    func testWashArtFallbackIsLastAndBlankIsIgnored() {
        let folder = makeItem(id: "nuvio-folder://coll/folder", type: "nuvio.folder",
                              banner: "https://example.invalid/backdrop.jpg")
        let art = WashArt(item: folder, fallback: "https://example.invalid/cover.jpg")
        XCTAssertEqual(art.identity, "nuvio.folder:nuvio-folder://coll/folder")
        XCTAssertEqual(art.urls.map(\.absoluteString),
                       ["https://example.invalid/backdrop.jpg", "https://example.invalid/cover.jpg"])
        // A folder with no backdrop: the cover is the only candidate; a blank fallback adds nothing.
        let bare = makeItem(id: "nuvio-folder://coll/other", type: "nuvio.folder")
        XCTAssertEqual(WashArt(item: bare, fallback: "https://example.invalid/cover.jpg").urls.map(\.absoluteString),
                       ["https://example.invalid/cover.jpg"])
        XCTAssertEqual(WashArt(item: bare, fallback: "").urls, [])
    }

    // MARK: - Small pure pieces

    func testDimmingOpacity() {
        XCTAssertEqual(AmbientWashDimming.opacity(oled: false, increasedContrast: false), 1)
        XCTAssertEqual(AmbientWashDimming.opacity(oled: true, increasedContrast: false), 0.4)
        XCTAssertEqual(AmbientWashDimming.opacity(oled: false, increasedContrast: true), 0.6)
        // OLED wins when both are on.
        XCTAssertEqual(AmbientWashDimming.opacity(oled: true, increasedContrast: true), 0.4)
    }

    func testProbeLineSpelling() {
        XCTAssertEqual(
            AmbientWashProbeLine.line(on: true, oled: false, identity: "movie:tt1", generation: 2, shown: true,
                                      late: 0, luma: 0.1834, millis: 1.26),
            "on=1 oled=0 id=movie:tt1 gen=2 shown=1 late=0 lum=0.18 ms=1.3")
        XCTAssertEqual(
            AmbientWashProbeLine.line(on: false, oled: true, identity: nil, generation: 0, shown: false,
                                      late: 0, luma: 0, millis: 0),
            "on=0 oled=1 id=- gen=0 shown=0 late=0 lum=0.00 ms=0.0")
    }
}
