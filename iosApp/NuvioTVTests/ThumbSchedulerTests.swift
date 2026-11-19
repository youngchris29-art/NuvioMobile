import XCTest
@testable import NuvioTV

final class ThumbSchedulerTests: XCTestCase {
    typealias T = ThumbScheduler

    /// A healthy, opened, idle 600 s file at position 100, store empty, no index.
    private func inputs(now: TimeInterval = 100, position: Double = 100, duration: Double = 600,
                        _ edit: (inout T.Inputs) -> Void = { _ in }) -> T.Inputs {
        var i = T.Inputs(now: now, positionSec: position, durationSec: duration, paused: false,
                         cacheWait: false, cacheSec: 30, cacheTrendSec: 0, cacheReachesEnd: false, cacheFill: 0.2,
                         seekInFlight: false, previewActive: false, recentInput: false, harvestInFlight: false,
                         store: .empty, bytesRead: 0, byteBudget: 40 * T.mib,
                         scrubCeiling: T.scrubCeiling(budget: 40 * T.mib), opened: true)
        edit(&i)
        return i
    }

    /// Starts and finishes `job` as stored at its own stamp.
    private func finish(_ t: inout T, _ job: T.Job, at now: TimeInterval, kf: Double? = nil) {
        t.noteStarted(job, now: now)
        t.noteFinished(job, result: .stored(keyframeSec: kf ?? job.sec), now: now)
    }

    // 1
    func testDisabledNeverRunsOrOpens() {
        var t = T(enabled: false)
        t.noteScrubMiss(target: 300, now: 0)
        XCTAssertNil(t.next(inputs()))
        XCTAssertFalse(t.shouldOpen(inputs(now: 0) { $0.opened = false }))
        XCTAssertEqual(t.stopped, .modeOff)
    }

    // 2
    func testScrubMissDebouncesFiftyMillisecondsAndLastWins() {
        var t = T(enabled: true)
        t.noteScrubMiss(target: 300, now: 100)
        XCTAssertNil(t.next(inputs(now: 100.04) { $0.previewActive = true }))
        t.noteScrubMiss(target: 420, now: 100.04)          // newer miss replaces
        XCTAssertNil(t.next(inputs(now: 100.06) { $0.previewActive = true }))
        XCTAssertEqual(t.next(inputs(now: 100.1) { $0.previewActive = true }), .scrub(420))
    }

    // 3
    func testScrubSnapsToKeyframeAtOrBefore() {
        var t = T(enabled: true)
        t.setKeyframeIndex(stride(from: 0.0, through: 598, by: 2).map { $0 })
        t.noteScrubMiss(target: 401.3, now: 0)
        XCTAssertEqual(t.next(inputs(now: 1) { $0.previewActive = true }), .scrub(400))
        // Sparse index (median gap 100 > 3 × 10): the target itself.
        var s = T(enabled: true)
        s.setKeyframeIndex([0, 100, 200, 300, 400, 500])
        s.noteScrubMiss(target: 401.3, now: 0)
        XCTAssertEqual(s.next(inputs(now: 1) { $0.previewActive = true }), .scrub(401.3))
    }

    // 4: a scrub waits for the in-flight pre-warm, then pre-empts the rest of the pass.
    func testScrubPreemptsQueuedPrewarmAfterInFlightFinishes() {
        var t = T(enabled: true)
        let first = t.next(inputs(now: 100))
        guard case .prewarm = first else { return XCTFail("expected a pre-warm, got \(String(describing: first))") }
        t.noteStarted(first!, now: 100)
        t.noteScrubMiss(target: 500, now: 100.1)
        XCTAssertNil(t.next(inputs(now: 100.2) { $0.previewActive = true }), "one in flight")
        t.noteFinished(first!, result: .stored(keyframeSec: first!.sec), now: 100.3)
        let scrub = t.next(inputs(now: 100.3) { $0.previewActive = true })
        XCTAssertEqual(scrub, .scrub(500))
        finish(&t, scrub!, at: 100.6)
        XCTAssertNil(t.next(inputs(now: 101) { $0.previewActive = true }), "no pre-warm while scrubbing")
        t.noteScrubEnded(now: 102)
        XCTAssertNil(t.next(inputs(now: 103.9)), "2 s quiet after the scrub, and the next 10 s tick")
        XCTAssertNotNil(t.next(inputs(now: 110.1)))
    }

    // 5
    func testGlobalGatesBlockBothKinds() {
        let gates: [(String, (inout T.Inputs) -> Void)] = [
            ("cacheWait", { $0.cacheWait = true }),
            ("seekInFlight", { $0.seekInFlight = true }),
            ("harvestInFlight", { $0.harvestInFlight = true }),
            ("not opened", { $0.opened = false }),
        ]
        for (name, gate) in gates {
            var t = T(enabled: true)
            t.noteScrubMiss(target: 300, now: 0)
            XCTAssertNil(t.next(inputs(now: 1, gate)), name)
            var p = T(enabled: true)
            XCTAssertNil(p.next(inputs(now: 1, gate)), name)
            XCTAssertNotNil(p.next(inputs(now: 1)), "\(name): passes once the gate clears")
        }
    }

    // 6
    func testRecentInputBlocksPrewarmOnly() {
        var t = T(enabled: true)
        XCTAssertNil(t.next(inputs { $0.recentInput = true }))
        t.noteScrubMiss(target: 300, now: 100)
        XCTAssertEqual(t.next(inputs(now: 100.1) { $0.recentInput = true }), .scrub(300))
    }

    // 7 (C2): both health branches, the fall rule, and the end-of-file override.
    func testCacheHealthBranches() {
        let t = T(enabled: true)
        XCTAssertTrue(t.cacheHealthy(inputs { $0.cacheSec = 15; $0.cacheFill = 0 }), "15 s is healthy")
        XCTAssertTrue(t.cacheHealthy(inputs { $0.cacheSec = 12; $0.cacheFill = 0.9 }), "a 12 s cache at 0.9 fill is healthy")
        XCTAssertFalse(t.cacheHealthy(inputs { $0.cacheSec = 12; $0.cacheFill = 0.3 }), "a 12 s cache at 0.3 fill is not")
        XCTAssertFalse(t.cacheHealthy(inputs { $0.cacheSec = 40; $0.cacheTrendSec = -2.5 }), "falling more than 2 s")
        XCTAssertTrue(t.cacheHealthy(inputs { $0.cacheSec = 40; $0.cacheTrendSec = -2 }))
        XCTAssertTrue(t.cacheHealthy(inputs { $0.cacheSec = 3; $0.cacheFill = 0; $0.cacheTrendSec = -5; $0.cacheReachesEnd = true }))
        var p = T(enabled: true)
        XCTAssertNil(p.next(inputs { $0.cacheSec = 12; $0.cacheFill = 0.3 }))
        XCTAssertNotNil(p.next(inputs { $0.cacheSec = 12; $0.cacheFill = 0.9 }))
        XCTAssertEqual(T.cacheFill(forwardBytes: 90 * T.mib, maxBytes: 150 * T.mib), 0.6, accuracy: 1e-9)
        XCTAssertEqual(T.cacheFill(forwardBytes: 10, maxBytes: 0), 0)
        XCTAssertTrue(T.cacheReachesEnd(positionSec: 580, cacheSec: 19.5, durationSec: 600))
        XCTAssertFalse(T.cacheReachesEnd(positionSec: 500, cacheSec: 19.5, durationSec: 600))
    }

    // 8: a buffering pause (paused-for-cache) blocks; a user pause does not.
    func testBufferingBlocksButUserPauseAllowsPrewarm() {
        var t = T(enabled: true)
        XCTAssertNil(t.next(inputs { $0.cacheWait = true }))
        XCTAssertNotNil(t.next(inputs { $0.paused = true }))
    }

    // 9
    func testSeekLandingQuietsPrewarmThreeSeconds() {
        var t = T(enabled: true)
        t.noteSeekLanded(now: 100)
        XCTAssertNil(t.next(inputs(now: 102.9)))
        XCTAssertNotNil(t.next(inputs(now: 103)))
    }

    // 10
    func testAtMostEightPerTickThenNextPassAfterTenSeconds() {
        var t = T(enabled: true)
        var now = 100.0
        var issued = 0
        while let job = t.next(inputs(now: now)) {
            finish(&t, job, at: now)
            issued += 1
            now += 0.1
            if issued > 20 { break }
        }
        XCTAssertEqual(issued, 8, "back to back, then idle")
        XCTAssertTrue(t.takePassEnded())
        XCTAssertFalse(t.takePassEnded(), "reported once")
        XCTAssertNil(t.next(inputs(now: 109.9)))
        XCTAssertNotNil(t.next(inputs(now: 110)))
    }

    // 11
    func testByteBudgetStopsPrewarmScrubContinuesToCeilingThenStops() {
        var t = T(enabled: true)
        let budget = 40 * T.mib
        XCTAssertNil(t.next(inputs { $0.bytesRead = budget }))
        XCTAssertEqual(t.prewarmStopped, .byteBudget)
        XCTAssertNil(t.stopped)
        t.noteScrubMiss(target: 300, now: 100)
        XCTAssertEqual(t.next(inputs(now: 100.1) { $0.bytesRead = budget + 10 * T.mib }), .scrub(300))
        t.noteFinished(.scrub(300), result: .stored(keyframeSec: 300), now: 100.2)
        t.noteScrubMiss(target: 400, now: 100.3)
        XCTAssertNil(t.next(inputs(now: 100.4) { $0.bytesRead = T.scrubCeiling(budget: budget) }))
        XCTAssertEqual(t.stopped, .byteBudget)
        XCTAssertEqual(T.byteBudget(fileSize: nil), 40 * T.mib)
        // r2 P3 #2: the 16 MB floor, capped at a tenth of the file.
        XCTAssertEqual(T.byteBudget(fileSize: 121_896_911), 12_189_691, "the smoke fixture: a tenth")
        XCTAssertEqual(T.byteBudget(fileSize: 300 * T.mib), 16 * T.mib, "a TV episode: the floor")
        XCTAssertEqual(T.byteBudget(fileSize: 2_000 * T.mib), 40 * T.mib, "2 %")
        XCTAssertEqual(T.byteBudget(fileSize: 10 * T.mib), T.mib, "a tiny file: a tenth")
        XCTAssertEqual(T.byteBudget(fileSize: 0), 40 * T.mib, "unknown")
        XCTAssertEqual(T.byteBudget(fileSize: 60_000 * T.mib), 150 * T.mib)
        XCTAssertEqual(T.scrubCeiling(budget: budget), 90 * T.mib)
    }

    // Review r1 P1: once the pre-warm has stopped and nothing is pending, the controller closes the
    // thumbnailer; healthy play never reopens it, the next scrub miss does. Review r2 P2 #1: after
    // that scrub it stays open for a minute of no scrub activity, unless the host is still sending.
    func testIdleCloseAfterPrewarmStopAndScrubReopens() {
        var t = T(enabled: true)
        let budget = 40 * T.mib
        func idle(_ now: TimeInterval, previewActive: Bool = false, leftOpen: Bool = false) -> Bool {
            t.idleCloseWanted(now: now, previewActive: previewActive, requestLeftOpen: leftOpen)
        }
        XCTAssertFalse(idle(100), "pre-warm still running")
        XCTAssertNil(t.next(inputs { $0.bytesRead = budget }))
        XCTAssertEqual(t.prewarmStopped, .byteBudget)
        XCTAssertTrue(idle(100), "no scrub since the open: the close follows the pre-warm stop")
        XCTAssertFalse(idle(100, previewActive: true), "not while preview lookups run")
        t.noteIdleClosed()
        // Long healthy play: no reopen.
        for k in 0..<60 {
            XCTAssertFalse(t.shouldOpen(inputs(now: 101 + Double(k)) { $0.opened = false; $0.bytesRead = budget }))
        }
        // A scrub miss reopens, once.
        t.noteScrubMiss(target: 300, now: 170)
        XCTAssertFalse(idle(170), "a scrub is pending")
        XCTAssertTrue(t.shouldOpen(inputs(now: 170.01) { $0.opened = false; $0.bytesRead = budget }))
        XCTAssertFalse(t.shouldOpen(inputs(now: 170.02) { $0.opened = false; $0.bytesRead = budget }))
        let job = t.next(inputs(now: 170.1) { $0.bytesRead = budget })
        XCTAssertEqual(job, .scrub(300))
        t.noteStarted(.scrub(300), now: 170.1)
        XCTAssertFalse(idle(170.2), "a job is in flight")
        t.noteFinished(.scrub(300), result: .stored(keyframeSec: 300), now: 170.5)
        t.noteScrubEnded(now: 171)
        // r2 P2 #1: kept open after the scrub session.
        XCTAssertFalse(idle(172), "a scrub just ended: keep the thumbnailer")
        XCTAssertFalse(idle(230.9), "59.9 s after the scrub ended")
        XCTAssertTrue(idle(172, leftOpen: true), "the host is still sending: close at once")
        XCTAssertTrue(idle(231), "60 s with no scrub activity")
        // A file-level stop is the controller's plain close, not an idle close.
        t.stop(.httpRefused)
        XCTAssertFalse(idle(300))
    }

    // Review r2 P2 #1: scrubs, plays and scrubs again inside a minute: one open, no idle close;
    // every scrub activity (miss, job, end) restarts the minute; the reopen's session counts too.
    func testIdleCloseWaitsSixtySecondsFromTheLastScrubActivity() {
        var t = T(enabled: true)
        let budget = 40 * T.mib
        func idle(_ now: TimeInterval, leftOpen: Bool = false) -> Bool {
            t.idleCloseWanted(now: now, previewActive: false, requestLeftOpen: leftOpen)
        }
        XCTAssertNil(t.next(inputs { $0.bytesRead = budget }))
        XCTAssertTrue(idle(100))
        // The thumbnailer is still open (the controller closes on its next tick); a miss lands first.
        t.noteScrubMiss(target: 200, now: 100.5)
        XCTAssertEqual(t.next(inputs(now: 100.6) { $0.bytesRead = budget }), .scrub(200))
        t.noteStarted(.scrub(200), now: 100.6)
        t.noteFinished(.scrub(200), result: .stored(keyframeSec: 200), now: 101)
        t.noteScrubEnded(now: 102)
        XCTAssertFalse(idle(150))
        // Second session at 150 s, all store hits (no job): the scrub end still counts.
        t.noteScrubEnded(now: 155)
        XCTAssertFalse(idle(161), "60 s from 102 passed, but the session at 155 restarted the minute")
        XCTAssertFalse(idle(214.9))
        XCTAssertTrue(idle(215))
        t.noteIdleClosed()
        // After the close and before any scrub, a close is wanted again (nothing to keep it for).
        XCTAssertTrue(idle(216))
        // The default is a minute.
        XCTAssertEqual(T.Config().idleCloseAfterScrubSec, 60)
    }

    // 12
    func testStoreFullAndFrameCapStopPrewarm() {
        var t = T(enabled: true)
        var full = SeekPreviewSnapshot.empty
        full.acceptsDecode = false
        XCTAssertNil(t.next(inputs { $0.store = full }))
        XCTAssertEqual(t.prewarmStopped, .storeFull)

        var c = T(config: .init(framesPerTick: 8, frameCap: 3), enabled: true)
        var now = 100.0
        while let job = c.next(inputs(now: now)) { finish(&c, job, at: now); now += 0.1 }
        XCTAssertEqual(c.decoded, 3)
        XCTAssertEqual(c.prewarmStopped, .frameCap)

        var r = T(enabled: true)
        let job = r.next(inputs())!
        r.noteStarted(job, now: 100)
        r.noteFinished(job, result: .rejectedFull, now: 100)
        XCTAssertEqual(r.prewarmStopped, .storeFull)
    }

    // 13
    func testDuplicateMarksSlotAndKeyframeTriedAbortedLeavesSlotRetryable() {
        var t = T(enabled: true)
        t.noteStarted(.prewarm(120), now: 100)
        t.noteFinished(.prewarm(120), result: .duplicate(keyframeSec: 118), now: 100)
        XCTAssertEqual(t.tried, [118, 120])
        XCTAssertEqual(t.decoded, 0)
        t.noteStarted(.prewarm(180), now: 100)
        t.noteFinished(.prewarm(180), result: .aborted, now: 100)
        XCTAssertEqual(t.tried, [118, 120], "aborted adds nothing")
        XCTAssertNil(t.inFlight)
        t.noteStarted(.prewarm(240), now: 100)
        t.noteFinished(.prewarm(240), result: .failed, now: 100)
        XCTAssertEqual(t.tried, [118, 120, 240])
        XCTAssertEqual(T.Outcome(insert: .keptExisting, keyframeSec: 5), .duplicate(keyframeSec: 5))
        XCTAssertEqual(T.Outcome(insert: .replaced, keyframeSec: 5), .stored(keyframeSec: 5))
        XCTAssertEqual(T.Outcome(insert: .invalid, keyframeSec: 5), .failed)
    }

    // 14
    func testCancelKeepsDecodedAndTried() {
        var t = T(enabled: true)
        let a = t.next(inputs(now: 100))!
        finish(&t, a, at: 100)
        let b = t.next(inputs(now: 100.1))!
        t.noteStarted(b, now: 100.1)
        t.cancel()
        XCTAssertNil(t.inFlight)
        XCTAssertEqual(t.decoded, 1)
        XCTAssertEqual(t.tried, [a.sec])
        // The next pass does not repeat the stored slot; the cancelled one can come back.
        let order = T.prewarmOrder(position: 100, duration: 600, spacing: 10, index: [], covered: [], tried: t.tried)
        XCTAssertFalse(order.contains(a.sec))
        XCTAssertTrue(order.contains(b.sec))
    }

    // 15
    func testPrewarmOrderCoarseToFineForwardBiased() {
        let order = T.prewarmOrder(position: 100, duration: 300, spacing: 10, index: [], covered: [], tried: [])
        // Level 60 (0, 60, 120, 180, 240): ahead ×1, behind ×2 → 120 (20), 60 (80), 180 (80), 0 (200), 240 (140)
        XCTAssertEqual(Array(order.prefix(5)), [120, 60, 180, 240, 0])
        // Level 30 adds only the odd multiples: 90 (20), 150 (50), 30 (140), 210 (110), 270 (170)
        XCTAssertEqual(Array(order[5..<10]), [90, 150, 210, 30, 270])
        // Level 10 follows (the playhead's own slot first); nothing repeats.
        XCTAssertEqual(Array(order[10..<12]), [100, 110])
        XCTAssertEqual(Set(order).count, order.count)
        XCTAssertEqual(order.count, 30)                      // 0…290 step 10 (≤ 298)
    }

    // 16
    func testBehindCountsDouble() {
        let order = T.prewarmOrder(position: 300, duration: 600, spacing: 60, index: [], covered: [], tried: [])
        // 300 (0), 360 (60), 240 (120) vs 420 (120): tie → earlier first.
        XCTAssertEqual(Array(order.prefix(4)), [300, 360, 240, 420])
    }

    // 17: merge with the store mirror; snap to the index and dedupe.
    func testPrewarmOrderSkipsCoveredSnapsAndDedupes() {
        let index = stride(from: 0.0, through: 598, by: 4).map { $0 }   // GOP 4 s
        let order = T.prewarmOrder(position: 0, duration: 600, spacing: 10, index: index,
                                   covered: [130], tried: [])
        // 120 is within level / 2 of the stored 130 at levels 60 and 30, so it only comes back at
        // the 10 s level (after every coarse slot); 128 (130 snapped) is within 5 s and never does.
        XCTAssertGreaterThan(order.firstIndex(of: 120)!, order.firstIndex(of: 540)!)
        XCTAssertFalse(order.contains(128))
        XCTAssertTrue(order.allSatisfy { index.contains($0) }, "every slot is a keyframe")
        XCTAssertTrue(order.contains(8), "10 snaps to 8")
        XCTAssertEqual(Set(order).count, order.count)

        // The pass skips a slot the store gained after the pass began.
        var t = T(enabled: true)
        let first = t.next(inputs(now: 100, position: 0))!
        finish(&t, first, at: 100)
        let upcoming = T.prewarmOrder(position: 0, duration: 600, spacing: 10, index: [], covered: [], tried: t.tried)
        var mirror = SeekPreviewSnapshot.empty
        mirror.stamps = [upcoming[0]]
        XCTAssertEqual(t.next(inputs(now: 100.1, position: 0) { $0.store = mirror }), .prewarm(upcoming[1]))
    }

    // 18
    func testScrubDuplicateOfStoredOrTriedIsDropped() {
        var t = T(enabled: true)
        var mirror = SeekPreviewSnapshot.empty
        mirror.stamps = [299.5]
        t.noteScrubMiss(target: 300, now: 100)
        XCTAssertNil(t.next(inputs(now: 100.1) { $0.store = mirror; $0.previewActive = true }))
        XCTAssertNil(t.pendingScrubDueAt, "dropped, not retried")
    }

    // 19
    func testShouldOpenOnceOnMissOrAfterTwentySecondsHealthy() {
        var t = T(enabled: true)
        var now = 0.0
        var opened = false
        while now < 30 {
            if t.shouldOpen(inputs(now: now) { $0.opened = false }) { opened = true; break }
            now += 0.5
        }
        XCTAssertTrue(opened)
        XCTAssertEqual(now, 20, accuracy: 0.51)
        XCTAssertFalse(t.shouldOpen(inputs(now: now + 1) { $0.opened = false }), "once")

        var m = T(enabled: true)
        XCTAssertFalse(m.shouldOpen(inputs(now: 0) { $0.opened = false }))
        m.noteScrubMiss(target: 400, now: 1)
        XCTAssertFalse(m.shouldOpen(inputs(now: 1) { $0.opened = false; $0.cacheWait = true }), "not while buffering")
        XCTAssertTrue(m.shouldOpen(inputs(now: 1.1) { $0.opened = false }))

        var p = T(enabled: true)
        for k in 0..<60 { XCTAssertFalse(p.shouldOpen(inputs(now: Double(k)) { $0.opened = false; $0.paused = true })) }
    }

    // 20
    func testTargetSpacingAndMedianGap() {
        XCTAssertEqual(T.targetSpacing(duration: 7200), 10)
        XCTAssertEqual(T.targetSpacing(duration: 10800), 15)
        XCTAssertEqual(T.medianGap([0, 2, 4, 10]), 2)
        XCTAssertNil(T.medianGap([5]))
        XCTAssertTrue(T.isSparse(index: [], spacing: 10))
        XCTAssertFalse(T.isSparse(index: [0, 2, 4], spacing: 10))
    }

    // 21
    func testRefineRuleAndCacheTrend() {
        let t = T(enabled: true)
        XCTAssertTrue(t.lookupWantsRefine(target: 300, matchSec: nil))
        XCTAssertTrue(t.lookupWantsRefine(target: 300, matchSec: 294.9))
        XCTAssertFalse(t.lookupWantsRefine(target: 300, matchSec: 295))
        var trend = ThumbCacheTrend()
        XCTAssertEqual(trend.trendSec(now: 0), 0)
        for k in 0...6 { trend.record(now: Double(k) * 2, cacheSec: 30 - Double(k)) }   // falls 1 s per 2 s
        XCTAssertEqual(trend.trendSec(now: 12), -5, accuracy: 1e-9)   // 12 − 10 = t 2 (29) → 24
    }
}
