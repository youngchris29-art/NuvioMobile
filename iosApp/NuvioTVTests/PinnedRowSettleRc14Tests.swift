import XCTest
import CoreGraphics
@testable import NuvioTV

/// rc14 (Steven rc13 verdict, 2026-09-30) — the pure helpers behind the settle corrector's late-rest
/// handling (BUG-121), the short-row layout compensation (BUG-122), and the Row Settle pane's
/// restPred/restErr tail ordering.
///
/// Pure-value tests on purpose, like `PinnedRowSettleDirectionTests`: `settlePlan`'s own state is
/// `nonisolated(unsafe) private static` and needs a live scroll host to drive, so what is asserted
/// here is the predicates it branches on and the string surgery the pane applies — not where the
/// focus engine actually parks a row. That is the device pass, read off the Row Settle pane.
final class PinnedRowSettleRc14Tests: XCTestCase {

    private let epsilon: CGFloat = 0.001

    // MARK: - restLawToTail

    /// The About pane draws each settle line with `.truncationMode(.middle)`, so a field in the
    /// middle of the line is exactly the one a photo never shows — and `settlePlan` appends the rest
    /// law pair mid-line. For the PANE only, `restLawToTail` moves ` restPred=… restErr=…` to the end.
    func testRestLawToTailMovesThePairToTheEnd() {
        let line = "row=x margin=-8 net=0 vh=470 restPred=-13.5 restErr=5.9 clearance=30 inBand=1 nudge=0"
        let result = PinnedRowSettle.restLawToTail(line)
        XCTAssertTrue(result.hasSuffix(" restPred=-13.5 restErr=5.9"), result)
        // The pair is gone from the middle: only the tail carries it.
        let tail = " restPred=-13.5 restErr=5.9"
        let middle = String(result.dropLast(tail.count))
        XCTAssertFalse(middle.contains("restPred"), middle)
        XCTAssertFalse(middle.contains("restErr"), middle)
        // Nothing else moved or changed: every other field survives, in order.
        XCTAssertEqual(result, "row=x margin=-8 net=0 vh=470 clearance=30 inBand=1 nudge=0" + tail)
    }

    func testRestLawToTailLeavesALineWithoutThePairUnchanged() {
        let line = "row=x margin=-8 net=0 vh=470 clearance=30 inBand=1 nudge=0"
        XCTAssertEqual(PinnedRowSettle.restLawToTail(line), line)
        // A half-present pair (restPred with no restErr after it) is not a pair either.
        let half = "row=x margin=-8 restPred=-13.5 clearance=30"
        XCTAssertEqual(PinnedRowSettle.restLawToTail(half), half)
    }

    func testRestLawToTailLeavesALineWhoseTailAlreadyHoldsThePairUnchanged() {
        let line = "row=x margin=-8 net=0 vh=470 clearance=30 restPred=-13.5 restErr=5.9"
        XCTAssertEqual(PinnedRowSettle.restLawToTail(line), line)
    }

    // MARK: - lateRestDeferral (BUG-121)

    /// A settle whose title sits more than the row's own height below the clip edge is a rest the
    /// engine has not produced yet (late content: the row realised after focus landed on it).
    func testLateRestDeferralFiresOnlyPastTheRowsOwnHeight() {
        XCTAssertTrue(PinnedRowSettle.lateRestDeferral(margin: 410, rowHeight: 385))
        XCTAssertFalse(PinnedRowSettle.lateRestDeferral(margin: 130, rowHeight: 366))
        XCTAssertFalse(PinnedRowSettle.lateRestDeferral(margin: -8, rowHeight: 502))
        // No measured row height means no basis to defer.
        XCTAssertFalse(PinnedRowSettle.lateRestDeferral(margin: 100, rowHeight: 0))
    }

    /// How many settle re-checks a late rest gets before the ordinary correction runs: two (0.5 s
    /// at `settleDelay`), leaving the third hop of the caller's three-hop chain for the
    /// correction itself (review r1 P2).
    func testMaxLateRestRetriesLeavesOneHopForTheCorrection() {
        XCTAssertEqual(PinnedRowSettle.maxLateRestRetries, 2)
    }

    // MARK: - topRestExempt (BUG-122)

    /// A rest at the scroll view's true top whose row sits BELOW the band is the layout's own
    /// position for the first row — correcting it would scroll the first row under the hero.
    func testTopRestExemptOnlyAtTheTrueTopAndBelowTheBand() {
        XCTAssertTrue(PinnedRowSettle.topRestExempt(offsetY: 0, margin: 56, bandHigh: 48))
        // Scrolled away from the top: an ordinary rest, so the corrector keeps its job.
        XCTAssertFalse(PinnedRowSettle.topRestExempt(offsetY: 12, margin: 56, bandHigh: 48))
        // At the top but inside the band: nothing to exempt.
        XCTAssertFalse(PinnedRowSettle.topRestExempt(offsetY: 0, margin: 40, bandHigh: 48))
        // Sub-point offsets from layout rounding still count as the top (the gate is ≤ 0.5).
        XCTAssertTrue(PinnedRowSettle.topRestExempt(offsetY: 0.4, margin: 56, bandHigh: 48))
    }

    // MARK: - shortRowLayoutCompensation (BUG-122)

    /// `rowCardLinkFrameFloor` grows a short row's FOCUSABLE frame (Continue Watching, Upcoming, a
    /// collection row); the compensation is the negative bottom padding that cancels the layout
    /// growth so the visible spacing to the next row does not change.
    func testShortRowLayoutCompensationCancelsTheFloorGrowth() {
        // A 313pt natural label under a 521.333pt floor: the whole difference is compensated.
        XCTAssertEqual(PinnedRowGeometry.shortRowLayoutCompensation(floor: 521.333, naturalLabel: 313,
                                                                    isLastRow: false),
                       208.333, accuracy: 0.001)
        // The LAST row's growth is Home's bottom inset's job (`pinnedLastRowHeight`), as in rc11.
        XCTAssertEqual(PinnedRowGeometry.shortRowLayoutCompensation(floor: 521.333, naturalLabel: 313,
                                                                    isLastRow: true),
                       0, accuracy: epsilon)
        // No floor published (inactive regime): nothing to compensate.
        XCTAssertEqual(PinnedRowGeometry.shortRowLayoutCompensation(floor: 0, naturalLabel: 313,
                                                                    isLastRow: false),
                       0, accuracy: epsilon)
        // A label already past the floor (a uniform poster row): never negative compensation.
        XCTAssertEqual(PinnedRowGeometry.shortRowLayoutCompensation(floor: 500, naturalLabel: 520,
                                                                    isLastRow: false),
                       0, accuracy: epsilon)
    }

    // MARK: - appliedSlide (rc14 device round 3)

    /// A title that would still be off screen after sliding applies 0; a title inside the
    /// viewport (or partially clipped) applies its measurement. The recycled-row case from
    /// Christian's Up walk: measured 72 with the title 300pt above the clip edge → 0.
    func testAppliedSlideIsZeroForAnOffScreenTitle() {
        XCTAssertEqual(PinnedRowTitle.appliedSlide(visibleMinY: 300, titleHeight: 38, measured: 72), 0)
        XCTAssertEqual(PinnedRowTitle.appliedSlide(visibleMinY: 110, titleHeight: 38, measured: 72), 0)
        XCTAssertEqual(PinnedRowTitle.appliedSlide(visibleMinY: 109, titleHeight: 38, measured: 72), 72)
        XCTAssertEqual(PinnedRowTitle.appliedSlide(visibleMinY: 8, titleHeight: 38, measured: 8), 8)
        XCTAssertEqual(PinnedRowTitle.appliedSlide(visibleMinY: -20, titleHeight: 38, measured: 0), 0)
    }

    /// Round 4 (F3): the Reading itself carries the on-screen verdict the applied slide is derived
    /// from — a title entirely above the viewport reads `onScreen == false` even at the 72 cap.
    func testReadingCarriesTheOnScreenVerdict() {
        let far = PinnedRowTitle.reading(geometry: .init(visibleMinY: 300, titleHeight: 38),
                                         artworkHeight: 351, cardTopReach: 92, captionVisible: false,
                                         rowIsFocused: true, treatment: .cardTreatment,
                                         mode: .init(noZoom: false, accentRing: false))
        XCTAssertEqual(far.slide, 72)
        XCTAssertFalse(far.onScreen)
        let rest = PinnedRowTitle.reading(geometry: .init(visibleMinY: 8, titleHeight: 38),
                                          artworkHeight: 351, cardTopReach: 92, captionVisible: false,
                                          rowIsFocused: true, treatment: .cardTreatment,
                                          mode: .init(noZoom: false, accentRing: false))
        XCTAssertEqual(rest.slide, 8)
        XCTAssertTrue(rest.onScreen)
    }
}
