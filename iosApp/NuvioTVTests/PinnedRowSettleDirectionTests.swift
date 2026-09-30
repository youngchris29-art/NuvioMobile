import XCTest
import CoreGraphics
@testable import NuvioTV

/// BUG-112 (Item B) — the direction-scoped pull-back brake (`PinnedRowSettle.PullBackLedger`) and
/// the bound arithmetic a re-armed corrector runs into (`PinnedRowSettle.plannedCorrection`).
///
/// Pure-value tests on purpose: `settlePlan`'s own state is `nonisolated(unsafe) private static`
/// and needs a live scroll host to drive, which is why the ledger is a value type in the first
/// place. What these CANNOT prove is which way the device's focus engine anchors a rest — that is
/// the device pass, read off the Row Settle pane's `dir=`/`rearm=`/`pull=` fields.
final class PinnedRowSettleDirectionTests: XCTestCase {

    private func walkDown(_ ledger: inout PinnedRowSettle.PullBackLedger,
                          rows: [String], from y: CGFloat = 0, step: CGFloat = 320)
    -> [PinnedRowSettle.PullBackLedger.SettleResult] {
        rows.enumerated().map { ledger.noteSettle(rowKey: $0.element, offsetY: y + CGFloat($0.offset) * step) }
    }

    func testTwoPullBacksWalkingDownDisarmThatDirection() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = walkDown(&ledger, rows: ["r1", "r2", "r3"])
        XCTAssertEqual(ledger.direction, 1)
        ledger.notePullBack()
        XCTAssertFalse(ledger.disarmed, "one pull-back must not disarm — the budget is \(PinnedRowSettle.maxPullBacksPerSession)")
        ledger.notePullBack()
        XCTAssertTrue(ledger.disarmed)
        XCTAssertEqual(ledger.total, 2)
    }

    func testFirstSettleInTheOppositeDirectionReArms() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = walkDown(&ledger, rows: ["r1", "r2", "r3"])
        ledger.notePullBack(); ledger.notePullBack()
        XCTAssertTrue(ledger.disarmed)
        let result = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        XCTAssertTrue(result.changed, "a reversal after a disarm must release the brake")
        XCTAssertTrue(result.released, "the disarmed ledger itself was released by this flip")
        XCTAssertEqual(ledger.direction, -1)
        XCTAssertFalse(ledger.disarmed, "the up ledger is empty — corrections are back on")
        XCTAssertEqual(ledger.rearms, 1)
        XCTAssertEqual(ledger.total, 2, "evidence is switched, never erased")
    }

    /// Codex P2: a pull-back recorded while direction was still `unknown` plus one recorded
    /// walking DOWN never crosses `maxPullBacksPerSession` in EITHER bucket, so the ledger itself
    /// is never `disarmed` and a plain reversal cannot "release" anything from it (`released` is
    /// false). But the reversal is still real, evidence-backed walk-direction evidence — `changed`
    /// must be true regardless — because `settlePlan` uses `changed` (not `released`) to decide
    /// whether to release the SEPARATE, static verify-miss latch: on hardware the two MISSes that
    /// latch counted were produced by these same two pull-backs seen a second time, so `changed`
    /// alone is the evidence needed, independent of what the ledger's own per-direction counters
    /// happen to read. That latch-release itself lives in `settlePlan` and needs a live host to
    /// exercise — not provable here, only at the ledger level this test covers.
    func testAReversalWithSplitPullBacksReleasesTheVerifyMissLatchSignal() {
        var ledger = PinnedRowSettle.PullBackLedger()
        ledger.notePullBack() // direction still 0 here — counts as `unknown`
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        _ = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        XCTAssertEqual(ledger.direction, 1)
        ledger.notePullBack() // now walking down — counts as `down`
        XCTAssertEqual(ledger.unknown, 1)
        XCTAssertEqual(ledger.down, 1)
        XCTAssertEqual(ledger.up, 0)
        XCTAssertEqual(ledger.total, 2)
        XCTAssertFalse(ledger.disarmed,
            "neither per-direction count reached the budget of \(PinnedRowSettle.maxPullBacksPerSession) — the ledger itself was never disarmed")

        let result = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        XCTAssertTrue(result.changed, "the walk reversed — this is real evidence a reversal happened")
        XCTAssertFalse(result.released, "there was nothing disarmed on the ledger for this flip to release")
        XCTAssertEqual(ledger.total, 2, "evidence is switched, never erased")
        XCTAssertEqual(ledger.direction, -1)
    }

    func testNoReArmWithoutADirectionChange() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = walkDown(&ledger, rows: ["r1", "r2", "r3"])
        ledger.notePullBack(); ledger.notePullBack()
        let result = ledger.noteSettle(rowKey: "r4", offsetY: 960)
        XCTAssertFalse(result.changed, "still walking down")
        XCTAssertFalse(result.released)
        XCTAssertTrue(ledger.disarmed)
        XCTAssertEqual(ledger.rearms, 0)
    }

    func testReSettlingTheSameRowIsNotAHop() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        _ = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        XCTAssertEqual(ledger.direction, 1)
        XCTAssertFalse(ledger.noteSettle(rowKey: "r2", offsetY: 320 - 93).changed)
        XCTAssertEqual(ledger.direction, 1)
    }

    func testSubThresholdHopDoesNotSetADirection() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        XCTAssertFalse(ledger.noteSettle(rowKey: "r2", offsetY: PinnedRowSettle.PullBackLedger.minHopDelta - 1).changed)
        XCTAssertEqual(ledger.direction, 0)
    }

    func testAWobbleStillDisarmsTheSessionForGood() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        _ = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        ledger.notePullBack(); ledger.notePullBack()
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        ledger.notePullBack(); ledger.notePullBack()
        XCTAssertTrue(ledger.hardDisarmed)
        // The direction still flips (the walk really did reverse — `changed` reports geometry),
        // but the flip must never RELEASE the brake past the hard stop.
        let reversal = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        XCTAssertTrue(reversal.changed, "the reversal itself is still observed")
        XCTAssertFalse(reversal.released, "no further re-arm past the hard stop")
        XCTAssertEqual(ledger.rearms, 1, "only the pre-hard-stop reversal counted as a re-arm")
        XCTAssertTrue(ledger.disarmed)
    }

    /// rc13 (BUG-112, second half) — WHY the Up fallback's first rung tells the corrector through
    /// `PinnedRowSettle.noteFocusHop` rather than `noteExternalScroll`.
    ///
    /// The two differ by exactly one statement: `noteExternalScroll` calls `forgetHop()`. This
    /// test is that statement's cost, made explicit. After forgetting, the ledger has no row/offset
    /// pair to compare against, so the NEXT settle — the one the fallback's own hand-off produces —
    /// establishes a new baseline and reports no direction change at all. The direction the walk is
    /// actually going only reappears on the settle AFTER that, one row later. On hardware, where
    /// the whole point of the fallback is that the engine could not make this hop on its own, that
    /// is one full row of up-walk judged under the DOWN-walk's spent, disarmed brake.
    ///
    /// Rung 1 is the case this matters for (it moves no scroll at all, so there is nothing to
    /// forget); rungs 2–4 still forget, correctly, because a programmatic jump is not a walk step.
    func testForgettingTheHopMakesTheNextSettleDirectionless() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = walkDown(&ledger, rows: ["r1", "r2", "r3"])
        XCTAssertEqual(ledger.direction, 1, "three rows down establishes the down-walk")

        // What `noteExternalScroll` does on top of everything `noteFocusHop` does.
        ledger.forgetHop()

        // The fallback lands focus on r2 — a genuine reversal, 320pt back up the page.
        let firstAfterForget = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        XCTAssertFalse(firstAfterForget.changed,
            "with the hop forgotten there is no previous row to compare against, so the reversal is invisible to this settle")
        XCTAssertEqual(ledger.direction, 1,
            "and the ledger is still reporting the DOWN-walk's direction — the up-walk's corrections stay under the down-walk's spent brake")

        // Only the NEXT hop — one whole row later — recovers the direction.
        let second = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        XCTAssertTrue(second.changed, "the direction is only recoverable a full row later")
        XCTAssertEqual(ledger.direction, -1)

        // The counterfactual: keeping the hop (what `noteFocusHop` does) flips on the very first
        // settle after the hand-off.
        var kept = PinnedRowSettle.PullBackLedger()
        _ = walkDown(&kept, rows: ["r1", "r2", "r3"])
        let immediate = kept.noteSettle(rowKey: "r2", offsetY: 320)
        XCTAssertTrue(immediate.changed, "with the hop kept, the fallback's own hand-off IS the direction change")
        XCTAssertEqual(kept.direction, -1)
    }

    func testARegimeChangeClearsTheLedgerCompletely() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        _ = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        ledger.notePullBack()
        ledger.resetAll()
        XCTAssertEqual(ledger.total, 0)
        XCTAssertEqual(ledger.direction, 0)
        XCTAssertEqual(ledger.rearms, 0)
    }

    func testADownwardCorrectionShortenedByTheBoundStillFires() {
        let planned = PinnedRowSettle.plannedCorrection(error: -103, deficit: 103,
                                                        bottomRoom: 93, scrollRoomUp: 400)
        XCTAssertEqual(planned.magnitude, 93, accuracy: 0.001)
        XCTAssertEqual(planned.correction, 93, accuracy: 0.001, "positive = move the content DOWN")
        XCTAssertTrue(planned.bounded)
        XCTAssertGreaterThanOrEqual(planned.magnitude, 2,
            "≥2 is `settlePlan`'s fire threshold — a bounded correction is still a correction")
    }

    func testAnUnboundedCorrectionLandsOnTheTarget() {
        let planned = PinnedRowSettle.plannedCorrection(error: -30, deficit: 30,
                                                        bottomRoom: 93, scrollRoomUp: 400)
        XCTAssertEqual(planned.magnitude, 30, accuracy: 0.001)
        XCTAssertFalse(planned.bounded)
    }

    func testAnUpwardCorrectionIsBoundedByScrollRangeNotByTheRowBottom() {
        let planned = PinnedRowSettle.plannedCorrection(error: 40, deficit: 40,
                                                        bottomRoom: 93, scrollRoomUp: 12)
        XCTAssertEqual(planned.magnitude, 12, accuracy: 0.001)
        XCTAssertEqual(planned.correction, -12, accuracy: 0.001, "negative = move the content UP")
    }

    // MARK: - 2026-09-30 §2.C(ii): a correction that never applied is DROPPED, not a pull-back

    /// Device walk 2026-09-30 13:24:06: nudge fired 4552 → 4540, the offset went 4552 → 4553 and
    /// rested there. The old detector counted that as PULLBACK and two of them disarmed the walk.
    func testACorrectionThatNeverMovedIsDroppedAndNotCounted() {
        var progress = PinnedRowSettle.CorrectionProgress(firedY: 4552, targetY: 4540)
        progress.note(offsetY: 4552)
        progress.note(offsetY: 4553)
        XCTAssertEqual(progress.nudge, -12, accuracy: 0.001)
        XCTAssertTrue(progress.dropped)
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = walkDown(&ledger, rows: ["r1", "r2"])
        XCTAssertEqual(PinnedRowSettle.recordReturn(progress, into: &ledger), .dropped)
        XCTAssertEqual(ledger.total, 0, "a dropped correction must not spend the pull-back budget")
        XCTAssertEqual(PinnedRowSettle.recordReturn(progress, into: &ledger), .dropped)
        XCTAssertFalse(ledger.disarmed)
    }

    /// A correction that landed (1762 → 1750) and was then put back by the engine is still a
    /// real pull-back — the best progress is kept, not the final offset.
    func testACorrectionThatLandedAndWasPutBackIsStillAPullBack() {
        var progress = PinnedRowSettle.CorrectionProgress(firedY: 1762, targetY: 1750)
        for y: CGFloat in [1758, 1752, 1750, 1756, 1762] { progress.note(offsetY: y) }
        XCTAssertEqual(progress.maxProgress, 12, accuracy: 0.001)
        XCTAssertFalse(progress.dropped)
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = walkDown(&ledger, rows: ["r1", "r2"])
        XCTAssertEqual(PinnedRowSettle.recordReturn(progress, into: &ledger), .pulledBack)
        XCTAssertEqual(ledger.total, 1)
    }

    /// The 25 % boundary, in the downward-nudge direction too.
    func testTheDroppedBoundaryIsAQuarterOfTheNudge() {
        var short = PinnedRowSettle.CorrectionProgress(firedY: 100, targetY: 112)
        short.note(offsetY: 102)             // 2 of 12 < 3
        XCTAssertTrue(short.dropped)
        var enough = PinnedRowSettle.CorrectionProgress(firedY: 100, targetY: 112)
        enough.note(offsetY: 103)            // 3 of 12 == 25 %
        XCTAssertFalse(enough.dropped)
        let untouched = PinnedRowSettle.CorrectionProgress(firedY: 100, targetY: 112)
        XCTAssertTrue(untouched.dropped, "no sample at all is no progress")
    }
}
