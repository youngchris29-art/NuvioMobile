import XCTest
@testable import NuvioTV

/// Review r4 #1, owner's call: after a live reconnect Whole Video stops reading unwatched parts for
/// the rest of the playback; the harvest keeps going into the new store
/// (`SeekPreviewTimeline.liveReconnected`, `ThumbStopReason.reconnected`).
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

    private let wholeVideo = SeekPreviewCapability.mpv(mode: .decode, effectiveHarvestIntervalSec: 10)

    /// A scheduler mid-session: opened, one scrub frame stored at 300 (tried), a second scrub job
    /// in flight at 420, a third miss pending at 500, and a keyframe index.
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
        XCTAssertEqual(t.inFlight, .scrub(420))
        XCTAssertNotNil(t.pendingScrubDueAt)
        return (t, second)
    }

    private func busyTimeline() -> (SeekPreviewTimeline, inFlight: T.Job) {
        let (t, job) = busyScheduler()
        var line = SeekPreviewTimeline(capability: wholeVideo, thumbs: t, harvest: HarvestScheduler(intervalSec: 10))
        XCTAssertTrue(line.opened(facts(index: [0, 10, 20, 30]), budget: 40 * T.mib))
        return (line, job)
    }

    // MARK: No decode after a reconnect

    func testAfterReconnectNoDecodeJobOfAnyKindStarts() {
        var (line, _) = busyTimeline()
        line.liveReconnected()
        XCTAssertEqual(line.thumbs.stopped, .reconnected)
        XCTAssertNil(line.thumbs.inFlight, "the slot is free: the harvest is not held behind a dropped job")
        XCTAssertNil(line.thumbs.pendingScrubDueAt, "the pending scrub goes")

        // Open requests: neither a scrub miss nor a minute of healthy play reopens.
        for k in 0..<120 {
            XCTAssertFalse(line.thumbs.shouldOpen(inputs(now: 200 + Double(k) * 0.5, opened: false)))
        }
        // Scrub, hold and click misses are refused, and refinement is never asked for.
        line.thumbs.noteScrubMiss(target: 450, now: 300)
        XCTAssertNil(line.thumbs.pendingScrubDueAt)
        XCTAssertFalse(line.thumbs.lookupWantsRefine(target: 450, matchSec: nil))
        XCTAssertFalse(line.thumbs.lookupWantsRefine(target: 450, matchSec: 400))
        XCTAssertFalse(line.thumbs.shouldOpen(inputs(now: 300.06, opened: false)))
        // Pre-warm and scrub jobs: none, even with a (hypothetically) open thumbnailer and a quiet,
        // healthy cache.
        for k in 0..<60 {
            XCTAssertNil(line.thumbs.next(inputs(now: 300.06 + Double(k) * 10)))
        }
        XCTAssertFalse(line.thumbs.idleCloseWanted(now: 1000, previewActive: false, requestLeftOpen: true))
    }

    func testTheReconnectStopIsStickyAcrossLaterReconnectsAndKeepsAnEarlierStop() {
        var line = SeekPreviewTimeline(capability: wholeVideo, thumbs: T(enabled: true), harvest: HarvestScheduler(intervalSec: 10))
        line.liveReconnected()
        line.liveReconnected()
        XCTAssertEqual(line.thumbs.stopped, .reconnected)
        XCTAssertEqual(line.generation, 2)

        var refused = SeekPreviewTimeline(capability: wholeVideo, thumbs: T(enabled: true), harvest: HarvestScheduler(intervalSec: 10))
        refused.thumbs.stop(.httpRefused)
        refused.liveReconnected()
        XCTAssertEqual(refused.thumbs.stopped, .httpRefused, "the first stop's reason stays for the Info row")
        XCTAssertFalse(refused.capability.fillsUnwatched)
    }

    // MARK: Capability

    func testReconnectReportsHarvestOnlyWithFillsWatchedUnchanged() {
        var line = SeekPreviewTimeline(capability: wholeVideo, thumbs: T(enabled: true), harvest: HarvestScheduler(intervalSec: 10))
        XCTAssertEqual(line.capability, SeekPreviewCapability(fillsWatched: true, fillsUnwatched: true))
        line.liveReconnected()
        XCTAssertEqual(line.capability, SeekPreviewCapability(fillsWatched: true, fillsUnwatched: false))
        XCTAssertEqual(line.generation, 1, "the coordinator fences on the new generation")

        // No harvest (the simulator, a crash guard): nothing fills the card after the reconnect.
        var noHarvest = SeekPreviewTimeline(capability: .mpv(mode: .decode, effectiveHarvestIntervalSec: 0),
                                            thumbs: T(enabled: true), harvest: HarvestScheduler(intervalSec: 0))
        noHarvest.liveReconnected()
        XCTAssertEqual(noHarvest.capability, .none)

        // Watched Parts: already harvest-only, unchanged.
        let watched = SeekPreviewCapability.mpv(mode: .harvest, effectiveHarvestIntervalSec: 10)
        var harvestOnly = SeekPreviewTimeline(capability: watched, thumbs: T(enabled: false), harvest: HarvestScheduler(intervalSec: 10))
        harvestOnly.liveReconnected()
        XCTAssertEqual(harvestOnly.capability, watched)
        XCTAssertEqual(harvestOnly.thumbs.stopped, .modeOff)
    }

    // MARK: Bytes

    func testReconnectKeepsTheBytesChargedBefore() {
        var (line, _) = busyTimeline()
        line.noteThumbnailerClosed(charged: 3 * T.mib)       // an idle close
        XCTAssertEqual(line.bytesCharged(openThumbnailer: 2 * T.mib), 5 * T.mib)
        // The reconnect: the open thumbnailer closes first (its charge so far stays), then the stop.
        line.noteThumbnailerClosed(charged: 2 * T.mib)
        line.liveReconnected()
        XCTAssertEqual(line.bytesCharged(openThumbnailer: nil), 5 * T.mib, "the budget is never refunded")
        XCTAssertEqual(line.byteBudget, 40 * T.mib)
    }

    /// The budget bound: only the one request in flight at the reconnect can still read, and its
    /// late completion is dropped and not counted; nothing new starts after it.
    func testLateCompletionFromTheClosedThumbnailerIsDroppedAndUncounted_BudgetOverrunBoundedByOneInFlightRequest() {
        let closedThumbnailer = NSObject()
        let closed = ObjectIdentifier(closedThumbnailer)
        var (line, inFlight) = busyTimeline()
        let jobGeneration = line.generation                   // the 420 job started here
        line.noteThumbnailerClosed(charged: 2 * T.mib)
        line.liveReconnected()
        let decodedBefore = line.thumbs.decoded
        // The closed thumbnailer's late result: no thumbnailer is open, and the generation moved.
        XCTAssertFalse(SeekPreviewTimeline.decodeBelongs(jobGeneration: jobGeneration, jobThumbnailer: closed,
                                                         currentGeneration: line.generation, currentThumbnailer: nil))
        // So the controller never calls `noteFinished` for it, and the charge stays what the close took.
        XCTAssertEqual(inFlight, .scrub(420))
        XCTAssertFalse(line.thumbs.tried.contains(420))
        XCTAssertEqual(line.thumbs.decoded, decodedBefore)
        XCTAssertEqual(line.bytesCharged(openThumbnailer: nil), 2 * T.mib)
        XCTAssertNil(line.thumbs.next(inputs(now: 500)), "and no request follows it")
    }

    func testNegativeChargesAreIgnored() {
        var line = SeekPreviewTimeline(capability: wholeVideo, thumbs: T(enabled: true), harvest: HarvestScheduler(intervalSec: 10))
        line.noteThumbnailerClosed(charged: -5)
        XCTAssertEqual(line.bytesCharged(openThumbnailer: -3), 0)
    }

    func testDecodeBelongsNeedsTheGenerationAndTheThumbnailer() {
        let a = NSObject(), b = NSObject()
        let ia = ObjectIdentifier(a), ib = ObjectIdentifier(b)
        XCTAssertTrue(SeekPreviewTimeline.decodeBelongs(jobGeneration: 2, jobThumbnailer: ia, currentGeneration: 2, currentThumbnailer: ia))
        XCTAssertFalse(SeekPreviewTimeline.decodeBelongs(jobGeneration: 1, jobThumbnailer: ia, currentGeneration: 2, currentThumbnailer: ia),
                       "same object, older timeline")
        XCTAssertFalse(SeekPreviewTimeline.decodeBelongs(jobGeneration: 2, jobThumbnailer: ia, currentGeneration: 2, currentThumbnailer: ib),
                       "an idle close and reopen")
        XCTAssertFalse(SeekPreviewTimeline.decodeBelongs(jobGeneration: 2, jobThumbnailer: ia, currentGeneration: 2, currentThumbnailer: nil))
    }

    // MARK: Harvest

    func testHarvestKeepsRunningAfterTheReconnect() {
        var line = SeekPreviewTimeline(capability: wholeVideo, thumbs: T(enabled: true), harvest: HarvestScheduler(intervalSec: 10))
        line.harvest.noteSeekLanded(now: 2)
        XCTAssertNotNil(line.harvest.seekHarvestDue)
        line.liveReconnected()
        XCTAssertNil(line.harvest.seekHarvestDue, "a seek harvest from before the reconnect goes")
        XCTAssertEqual(line.harvest.intervalSec, 10)
        var fired = false
        for k in 1...30 where !fired {
            fired = line.harvest.tick(now: 10 + Double(k) * 0.5, playing: true, transportIdle: true,
                                      seekInFlight: false, recentInput: false)
        }
        XCTAssertTrue(fired, "the harvest keeps capturing, into the reconnect's new store")
    }

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

    // MARK: First load

    func testFirstLoadIsUnaffected() {
        var line = SeekPreviewTimeline(capability: wholeVideo, thumbs: T(enabled: true), harvest: HarvestScheduler(intervalSec: 10))
        XCTAssertEqual(line.generation, 0)
        XCTAssertEqual(line.capability, wholeVideo)
        XCTAssertNil(line.thumbs.stopped)
        line.thumbs.noteScrubMiss(target: 300, now: 100)
        XCTAssertTrue(line.thumbs.shouldOpen(inputs(now: 100, opened: false)))
        XCTAssertEqual(line.thumbs.next(inputs(now: 100.06)), .scrub(300))
        // The first open fixes the budget and learns the index; an idle reopen learns nothing.
        XCTAssertTrue(line.opened(facts(index: [0, 6, 12]), budget: 40 * T.mib))
        XCTAssertEqual(line.thumbs.keyframeIndex, [0, 6, 12])
        XCTAssertFalse(line.opened(facts(index: [1, 2], size: 9_000_000_000), budget: 150 * T.mib))
        XCTAssertEqual(line.thumbs.keyframeIndex, [0, 6, 12])
        XCTAssertEqual(line.byteBudget, 40 * T.mib)
    }
}
