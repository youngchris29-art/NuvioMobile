import XCTest
import CoreGraphics
@testable import NuvioTV

/// 1 × 1 frames; the encoded bytes are irrelevant here.
nonisolated private struct TinyCodec: PreviewFrameCodec {
    func encode(_ image: CGImage) -> Data? { Data(count: 16) }
    func decode(_ data: Data) -> CGImage? { SeekPreviewStoreTests.image(width: 1) }
}

/// Batch G (Steven rc7): BUG-180 (player overlays over the mpv video) and BUG-181 (empty scrub card
/// on Dolby Vision).
final class PlayerOverlayCostTests: XCTestCase {

    // MARK: BUG-181: nearest-frame fallback

    private func store() -> SeekPreviewStore {
        SeekPreviewStore(streamKey: "test", codec: TinyCodec(), maxEntries: 200, maxBytes: 6 * 1024 * 1024)
    }

    func testNearestReturnsFrameBeyondTheToleranceWithinItsReach() async {
        let s = store()
        await s.insert(SeekPreviewStoreTests.image(width: 4), at: 100)
        let exact = await s.match(near: 200)
        XCTAssertNil(exact, "100 s off is past the default tolerance")
        let nearest = await s.nearest(to: 200)
        XCTAssertEqual(nearest?.sec, 100)
        // Device pass: past two minutes the placeholder card shows instead.
        let far = await s.nearest(to: 900)
        XCTAssertNil(far)
    }

    func testDarkFrameFilter() {
        XCTAssertTrue(HarvestFrameFilter.isNearlyBlack(SeekPreviewStoreTests.image(width: 32, height: 18)))
        let ctx = CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        XCTAssertFalse(HarvestFrameFilter.isNearlyBlack(ctx.makeImage()!))
    }

    func testNearestPicksTheCloserFrameAndTheEarlierOnATie() async {
        let s = store()
        await s.insert(SeekPreviewStoreTests.image(width: 4), at: 100)
        await s.insert(SeekPreviewStoreTests.image(width: 4), at: 300)
        let near250 = await s.nearest(to: 250)
        XCTAssertEqual(near250?.sec, 300)
        let tie = await s.nearest(to: 200)
        XCTAssertEqual(tie?.sec, 100)
    }

    func testNearestOnAnEmptyStoreIsNil() async {
        let nearest = await store().nearest(to: 50)
        XCTAssertNil(nearest)
    }

    func testStoreAsSourceExposesNearest() async {
        let s = store()
        await s.insert(SeekPreviewStoreTests.image(width: 4), at: 10)
        let source: SeekPreviewSource = s
        let hit = await source.nearest(to: 100)
        XCTAssertEqual(hit?.sec, 10)
    }

    // MARK: BUG-180: harvest waits while an overlay is up

    func testHarvestDoesNotCountTimeWithAnOverlayUp() {
        var h = HarvestScheduler(intervalSec: 10)
        var fired = false
        for i in 0..<30 {
            fired = h.tick(now: Double(i), playing: true, transportIdle: true, seekInFlight: false,
                           recentInput: false, overlayUp: true) || fired
        }
        XCTAssertFalse(fired)
        XCTAssertEqual(h.playedSinceLast, 0)
        var firstFire: Double?
        for i in 30..<45 where firstFire == nil {
            if h.tick(now: Double(i), playing: true, transportIdle: true, seekInFlight: false, recentInput: false) {
                firstFire = Double(i)
            }
        }
        XCTAssertEqual(firstFire, 39, "ten seconds of play once the overlay closed (the tick at 30 counts the second from 29)")
    }

    func testDueSeekHarvestWaitsForTheOverlayToClose() {
        var h = HarvestScheduler(intervalSec: 10)
        _ = h.tick(now: 0, playing: true, transportIdle: true, seekInFlight: false, recentInput: false)
        h.noteSeekLanded(now: 0)
        XCTAssertFalse(h.tick(now: 1.5, playing: true, transportIdle: true, seekInFlight: false,
                              recentInput: false, overlayUp: true))
        XCTAssertTrue(h.tick(now: 2, playing: true, transportIdle: true, seekInFlight: false, recentInput: false))
    }

    // MARK: BUG-180: decode pre-warm waits, a scrub does not

    private func inputs(now: TimeInterval, overlayUp: Bool, previewActive: Bool = false) -> ThumbScheduler.Inputs {
        ThumbScheduler.Inputs(now: now, positionSec: 100, durationSec: 600, paused: false,
                              cacheWait: false, cacheSec: 30, cacheTrendSec: 0, cacheReachesEnd: false, cacheFill: 0.2,
                              seekInFlight: false, previewActive: previewActive, recentInput: false, harvestInFlight: false,
                              store: .empty, bytesRead: 0, byteBudget: 40 * ThumbScheduler.mib,
                              scrubCeiling: ThumbScheduler.scrubCeiling(budget: 40 * ThumbScheduler.mib), opened: true,
                              overlayUp: overlayUp)
    }

    func testPrewarmWaitsWhileAnOverlayIsUp() {
        var t = ThumbScheduler(enabled: true)
        XCTAssertNil(t.next(inputs(now: 1, overlayUp: true)))
        guard case .prewarm? = t.next(inputs(now: 1, overlayUp: false)) else {
            return XCTFail("pre-warm runs once the overlay closes")
        }
    }

    func testScrubJobRunsWithTheBarUp() {
        var t = ThumbScheduler(enabled: true)
        t.noteScrubMiss(target: 300, now: 0)
        XCTAssertEqual(t.next(inputs(now: 1, overlayUp: true, previewActive: true)), .scrub(300))
    }

    // MARK: BUG-180: Stream Info rates are rounded before the equality gate

    func testStreamInfoRateRounding() {
        XCTAssertEqual(MPVTVPlayerViewController.streamInfoRate(4.26, unit: "MB/s"), "4.3 MB/s")
        XCTAssertEqual(MPVTVPlayerViewController.streamInfoRate(23.4, unit: "Mbps"), "23 Mbps")
        XCTAssertEqual(MPVTVPlayerViewController.streamInfoRate(23.49, unit: "Mbps"),
                       MPVTVPlayerViewController.streamInfoRate(22.6, unit: "Mbps"))
    }
}
