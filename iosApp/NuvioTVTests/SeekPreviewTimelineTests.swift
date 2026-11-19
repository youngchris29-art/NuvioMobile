import XCTest
@testable import NuvioTV

/// Review r3 P2 #2: a live reconnect starts a new preview timeline (`SeekPreviewTimeline`,
/// `ThumbScheduler.resetForNewTimeline`, `HarvestScheduler.resetForNewTimeline`).
final class SeekPreviewTimelineTests: XCTestCase {
    typealias T = ThumbScheduler

    private func inputs(now: TimeInterval, opened: Bool = true,
                        _ edit: (inout T.Inputs) -> Void = { _ in }) -> T.Inputs {
        var i = T.Inputs(now: now, positionSec: 100, durationSec: 600, paused: false,
                         cacheWait: false, cacheSec: 30, cacheTrendSec: 0, cacheReachesEnd: false, cacheFill: 0.2,
                         seekInFlight: false, previewActive: false, recentInput: false, harvestInFlight: false,
                         store: .empty, bytesRead: 0, byteBudget: 40 * T.mib,
                         scrubCeiling: T.scrubCeiling(budget: 40 * T.mib), opened: opened)
        edit(&i)
        return i
    }

    private func facts(index: [Double], size: Int64? = 2_000_000_000) -> ThumbFileFacts {
        ThumbFileFacts(container: "matroska,webm", durationSec: 600, sizeBytes: size, keyframeIndex: index,
                       hdr: .sdr, openMs: 120)
    }

    /// A scheduler mid-session on the old timeline: opened, one scrub frame stored at 300 (tried),
    /// a second scrub job in flight at 420, a third miss pending at 500, and a keyframe index.
    private func busyScheduler() -> (T, inFlight: T.Job) {
        var t = T(enabled: true)
        t.setKeyframeIndex(stride(from: 0.0, through: 590, by: 10).map { $0 })
        t.noteScrubMiss(target: 300, now: 100)
        XCTAssertTrue(t.shouldOpen(inputs(now: 100, opened: false)))
        let first = t.next(inputs(now: 100.06))!
        XCTAssertEqual(first, .scrub(300))
        t.noteStarted(first, now: 100.06)
        t.noteFinished(first, result: .stored(keyframeSec: 300), now: 100.5)
        t.noteScrubMiss(target: 420, now: 101)
        let second = t.next(inputs(now: 101.1))!
        t.noteStarted(second, now: 101.1)
        t.noteScrubMiss(target: 500, now: 101.2)
        XCTAssertEqual(t.tried, [300])
        XCTAssertEqual(t.inFlight, .scrub(420))
        XCTAssertNotNil(t.pendingScrubDueAt)
        XCTAssertTrue(t.openRequested)
        return (t, second)
    }

    // MARK: ThumbScheduler

    func testResetDropsEverythingKeyedByTheOldTimeline() {
        var (t, _) = busyScheduler()
        t.resetForNewTimeline()
        XCTAssertTrue(t.tried.isEmpty)
        XCTAssertNil(t.inFlight)
        XCTAssertNil(t.pendingScrubDueAt)
        XCTAssertTrue(t.keyframeIndex.isEmpty)
        XCTAssertFalse(t.openRequested, "the closed thumbnailer's open is forgotten")
        XCTAssertEqual(t.healthyPlaySec, 0)
        XCTAssertFalse(t.takePassEnded(), "the old decoder is gone: nothing to release")
        XCTAssertEqual(t.decoded, 1, "the decode count is the playback's")
        XCTAssertNil(t.stopped)
    }

    func testAReusedTimestampIsNotSuppressedAfterTheReset() {
        var (t, _) = busyScheduler()
        t.resetForNewTimeline()
        t.noteScrubMiss(target: 300, now: 200)              // 300 was tried on the old timeline
        XCTAssertEqual(t.next(inputs(now: 200.06)), .scrub(300))
    }

    func testWithoutTheResetTheOldTriedSetSuppressesIt() {
        var (t, inFlight) = busyScheduler()
        t.noteFinished(inFlight, result: .stored(keyframeSec: 420), now: 101.5)
        t.noteScrubMiss(target: 300, now: 200)              // replaces the pending 500
        // A card is up (no pre-warm): the scrub at 300 is dropped as already tried.
        XCTAssertNil(t.next(inputs(now: 200.06) { $0.previewActive = true }), "the class of bug the reset removes")
        XCTAssertNil(t.pendingScrubDueAt)
    }

    func testStoreFullStopGoesWithTheOldStoreBudgetStopStays() {
        var t = T(enabled: true)
        var full = SeekPreviewSnapshot.empty
        full.acceptsDecode = false
        XCTAssertNil(t.next(inputs(now: 500) { $0.store = full }))
        XCTAssertEqual(t.prewarmStopped, .storeFull)
        t.resetForNewTimeline()
        XCTAssertNil(t.prewarmStopped, "the new store is empty")

        var b = T(enabled: true)
        XCTAssertNil(b.next(inputs(now: 500) { $0.bytesRead = 41 * T.mib }))
        XCTAssertEqual(b.prewarmStopped, .byteBudget)
        b.resetForNewTimeline()
        XCTAssertEqual(b.prewarmStopped, .byteBudget, "the budget is the playback's")
    }

    func testFileLevelStopStays() {
        var t = T(enabled: true)
        t.stop(.httpRefused)
        t.resetForNewTimeline()
        XCTAssertEqual(t.stopped, .httpRefused)
        var off = T(enabled: false)
        off.resetForNewTimeline()
        XCTAssertEqual(off.stopped, .modeOff)
    }

    func testResetOfAFreshSchedulerChangesNothing() {
        var t = T(enabled: true)
        t.resetForNewTimeline()
        let fresh = T(enabled: true)
        XCTAssertEqual(t.tried, fresh.tried)
        XCTAssertEqual(t.inFlight, fresh.inFlight)
        XCTAssertEqual(t.decoded, fresh.decoded)
        XCTAssertEqual(t.stopped, fresh.stopped)
        XCTAssertEqual(t.prewarmStopped, fresh.prewarmStopped)
        XCTAssertEqual(t.openRequested, fresh.openRequested)
        XCTAssertEqual(t.healthyPlaySec, fresh.healthyPlaySec)
        XCTAssertEqual(t.keyframeIndex, fresh.keyframeIndex)
        XCTAssertNil(t.pendingScrubDueAt)
    }

    // MARK: HarvestScheduler

    func testHarvestResetDropsTheSeekHarvestKeepsTheRest() {
        var h = HarvestScheduler(intervalSec: 10)
        h.noteStarted()
        h.noteFinished(tookMs: 90)                          // slow: tripled for the file
        h.noteSeekLanded(now: 50)                           // backed off: no seek harvest
        XCTAssertNil(h.seekHarvestDue)

        var g = HarvestScheduler(intervalSec: 10)
        XCTAssertFalse(g.tick(now: 1, playing: true, transportIdle: true, seekInFlight: false, recentInput: false))
        XCTAssertFalse(g.tick(now: 2, playing: true, transportIdle: true, seekInFlight: false, recentInput: false))
        g.noteSeekLanded(now: 2)
        g.noteStarted()                                      // a capture is running across the reconnect
        g.noteSeekLanded(now: 3)
        XCTAssertNotNil(g.seekHarvestDue)
        g.resetForNewTimeline()
        XCTAssertNil(g.seekHarvestDue)
        XCTAssertTrue(g.inFlight, "the running capture still finishes and frees it")
        XCTAssertEqual(g.intervalSec, 10)

        h.resetForNewTimeline()
        XCTAssertTrue(h.backedOff)
        XCTAssertEqual(h.intervalSec, 30)
    }

    // MARK: SeekPreviewTimeline

    func testNewTimelineKeepsTheBytesAndTheBudget() {
        let (t, _) = busyScheduler()
        var line = SeekPreviewTimeline(thumbs: t, harvest: HarvestScheduler(intervalSec: 10))
        XCTAssertTrue(line.opened(facts(index: [0, 10, 20, 30]), budget: 40 * T.mib))
        XCTAssertEqual(line.byteBudget, 40 * T.mib)
        XCTAssertEqual(line.thumbs.keyframeIndex, [0, 10, 20, 30])
        line.noteThumbnailerClosed(charged: 3 * T.mib)       // an idle close
        XCTAssertEqual(line.bytesCharged(openThumbnailer: 2 * T.mib), 5 * T.mib)

        // The reconnect: the open thumbnailer closes first (its bytes stay), then the reset.
        line.noteThumbnailerClosed(charged: 2 * T.mib)
        let before = line.bytesCharged(openThumbnailer: nil)
        line.beginNewTimeline()
        XCTAssertEqual(line.generation, 1)
        XCTAssertEqual(line.bytesCharged(openThumbnailer: nil), before, "the budget is never refunded")
        XCTAssertEqual(line.byteBudget, 40 * T.mib)
        XCTAssertNil(line.facts, "the old timeline's index and duration go")
        XCTAssertTrue(line.thumbs.tried.isEmpty)
        XCTAssertNil(line.thumbs.inFlight)
        XCTAssertNil(line.thumbs.pendingScrubDueAt)
        XCTAssertTrue(line.thumbs.keyframeIndex.isEmpty)

        // The next open learns the new timeline's index; the budget stays the first open's.
        XCTAssertTrue(line.opened(facts(index: [0, 6, 12], size: 9_000_000_000), budget: 150 * T.mib))
        XCTAssertEqual(line.thumbs.keyframeIndex, [0, 6, 12])
        XCTAssertEqual(line.byteBudget, 40 * T.mib)
        // An idle reopen on the same timeline learns nothing.
        XCTAssertFalse(line.opened(facts(index: [1, 2]), budget: 1))
        XCTAssertEqual(line.thumbs.keyframeIndex, [0, 6, 12])
    }

    func testNegativeChargesAreIgnored() {
        var line = SeekPreviewTimeline(thumbs: T(enabled: true), harvest: HarvestScheduler(intervalSec: 10))
        line.noteThumbnailerClosed(charged: -5)
        XCTAssertEqual(line.bytesCharged(openThumbnailer: -3), 0)
    }

    func testAnOldDecodeNeitherInsertsNorCounts() {
        let oldThumbnailer = NSObject(), newThumbnailer = NSObject()
        let old = ObjectIdentifier(oldThumbnailer), new = ObjectIdentifier(newThumbnailer)
        var (t, inFlight) = busyScheduler()
        var line = SeekPreviewTimeline(thumbs: t, harvest: HarvestScheduler(intervalSec: 10))
        let jobGeneration = line.generation                   // the 420 job started here
        line.beginNewTimeline()
        // The old thumbnailer's late result: a different generation and a closed thumbnailer.
        XCTAssertFalse(SeekPreviewTimeline.decodeBelongs(jobGeneration: jobGeneration, jobThumbnailer: old,
                                                         currentGeneration: line.generation, currentThumbnailer: new))
        XCTAssertFalse(SeekPreviewTimeline.decodeBelongs(jobGeneration: jobGeneration, jobThumbnailer: old,
                                                         currentGeneration: line.generation, currentThumbnailer: nil))
        // So the controller never calls `noteFinished` for it: 420 is not tried on the new timeline,
        // and nothing waits for it (the reset forgot the job).
        XCTAssertFalse(line.thumbs.tried.contains(420))
        XCTAssertNil(line.thumbs.inFlight)
        _ = inFlight
        t = line.thumbs
        XCTAssertTrue(t.tried.isEmpty)
    }

    func testDecodeBelongsNeedsTheGenerationAndTheThumbnailer() {
        let a = NSObject(), b = NSObject()
        let ia = ObjectIdentifier(a), ib = ObjectIdentifier(b)
        XCTAssertTrue(SeekPreviewTimeline.decodeBelongs(jobGeneration: 2, jobThumbnailer: ia, currentGeneration: 2, currentThumbnailer: ia))
        XCTAssertFalse(SeekPreviewTimeline.decodeBelongs(jobGeneration: 1, jobThumbnailer: ia, currentGeneration: 2, currentThumbnailer: ia),
                       "same object, older timeline")
        XCTAssertFalse(SeekPreviewTimeline.decodeBelongs(jobGeneration: 2, jobThumbnailer: ia, currentGeneration: 2, currentThumbnailer: ib),
                       "an idle close and reopen on the same timeline")
        XCTAssertFalse(SeekPreviewTimeline.decodeBelongs(jobGeneration: 2, jobThumbnailer: ia, currentGeneration: 2, currentThumbnailer: nil))
    }
}
