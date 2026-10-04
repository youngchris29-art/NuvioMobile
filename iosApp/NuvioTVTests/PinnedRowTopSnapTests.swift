import XCTest
import CoreGraphics
@testable import NuvioTV

/// T1 leg 2 (Steven beta.19-rc1 verdict, 2026-10-03; BUG-66 residual): the pure predicates behind
/// the top-rest snap in `PinnedRowSettle.settlePlan`. With `-debug.tabBarRestFix 2`, a FIRST row
/// resting a few points below the true top (Steven's pane: `y=-13 st=part`, a tab bar that follows
/// the rows 1:1) is scrolled back to offset 0 as an ordinary settle correction.
///
/// Pure-value tests, like `PinnedRowSettleRc14Tests`: `settlePlan`'s own state needs a live scroll
/// host. What is pinned here is when the snap applies (`topSnapApplies`), what holds it back
/// (`topSnapHold`), and the two-settle confirmation (`TopSnapCandidate`). Where the engine actually
/// parks row 1 is the device session's call (Test profile, three cold launches).
@MainActor
final class PinnedRowTopSnapTests: XCTestCase {

    /// `Theme.Size.heroPinnedRowsHeadroom`: the rows list's top inset, i.e. the first row's top in
    /// content coordinates.
    private let headroom: CGFloat = 8

    func testHeadroomAndMaxArePinned() {
        XCTAssertEqual(Theme.Size.heroPinnedRowsHeadroom, headroom)
        XCTAssertEqual(PinnedRowSettle.topSnapMax, 48)
    }

    // MARK: - topSnapApplies

    /// Leg 0 is what ships; leg 1 is the relink, which never touches the corrector.
    func testLeg0NeverSnaps() {
        for leg in [0, 1, 3, -1] {
            XCTAssertFalse(PinnedRowSettle.topSnapApplies(leg: leg, offsetY: 13, rowContentTop: 8,
                                                          headroom: headroom), "leg \(leg)")
        }
    }

    /// Steven's case: the first row rested 13 pt deep. Its frame then reads `rowTop = 8 − 13`, and
    /// its top in content coordinates is back at the headroom.
    func testSnapsFirstRowSmallOffset() {
        let offsetY: CGFloat = 13
        let rowTop: CGFloat = headroom - offsetY
        XCTAssertTrue(PinnedRowSettle.topSnapApplies(leg: 2, offsetY: offsetY,
                                                     rowContentTop: rowTop + offsetY,
                                                     headroom: headroom))
        // Both ends of the window, and the 1 pt slack on the row's own top.
        XCTAssertTrue(PinnedRowSettle.topSnapApplies(leg: 2, offsetY: 1, rowContentTop: 8, headroom: headroom))
        XCTAssertTrue(PinnedRowSettle.topSnapApplies(leg: 2, offsetY: 48, rowContentTop: 8, headroom: headroom))
        XCTAssertTrue(PinnedRowSettle.topSnapApplies(leg: 2, offsetY: 13, rowContentTop: 9, headroom: headroom))
    }

    /// At the true top there is nothing to snap (`topRestExempt` owns that rest).
    func testNoSnapAtZero() {
        for offsetY: CGFloat in [0, 0.5, -4] {
            XCTAssertFalse(PinnedRowSettle.topSnapApplies(leg: 2, offsetY: offsetY, rowContentTop: 8,
                                                          headroom: headroom), "offset \(offsetY)")
        }
    }

    /// A deeper first-row rest is the up-walk deep park, not "a few points"; the ordinary
    /// corrector and the Up-into-hero reveal own it.
    func testNoSnapBeyondMax() {
        for offsetY: CGFloat in [48.5, 100, 600] {
            XCTAssertFalse(PinnedRowSettle.topSnapApplies(leg: 2, offsetY: offsetY, rowContentTop: 8,
                                                          headroom: headroom), "offset \(offsetY)")
        }
    }

    /// Any row below the first sits a row height further down in content coordinates.
    func testNoSnapForLaterRows() {
        for rowContentTop: CGFloat in [9.5, 40, 640] {
            XCTAssertFalse(PinnedRowSettle.topSnapApplies(leg: 2, offsetY: 13, rowContentTop: rowContentTop,
                                                          headroom: headroom), "rowContentTop \(rowContentTop)")
        }
    }

    // MARK: - topSnapHold

    private func hold(knob: Bool = false, latched: Bool = false, returned: Bool = false,
                      disarmed: Bool = false, budgetSpent: Bool = false,
                      bottomRoom: CGFloat = 44, offsetY: CGFloat = 13) -> String? {
        PinnedRowSettle.topSnapHold(knobDisarmed: knob, latched: latched, returned: returned,
                                    disarmed: disarmed, budgetSpent: budgetSpent,
                                    bottomRoom: bottomRoom, offsetY: offsetY)
    }

    func testHoldFreeWhenNothingBrakes() {
        XCTAssertNil(hold())
    }

    func testHoldNamesEachBrake() {
        XCTAssertEqual(hold(knob: true), "knob")
        XCTAssertEqual(hold(latched: true), "undone")
        XCTAssertEqual(hold(returned: true), "returned")
        XCTAssertEqual(hold(disarmed: true), "disarmed")
        XCTAssertEqual(hold(budgetSpent: true), "budget")
        // The knob outranks everything: it simulates a corrector that never engages.
        XCTAssertEqual(hold(knob: true, latched: true, returned: true, disarmed: true, budgetSpent: true),
                       "knob")
    }

    /// Moving the row down by `offsetY` must keep the focused card's lockup inside the fold —
    /// the bound every downward correction obeys. 0.5 pt of slack, exact in binary.
    func testHoldBoundKeepsTheLockupOnScreen() {
        XCTAssertNil(hold(bottomRoom: 12.5, offsetY: 13))
        XCTAssertEqual(hold(bottomRoom: 12.25, offsetY: 13), "bound")
        XCTAssertEqual(hold(bottomRoom: -20, offsetY: 13), "bound")
    }

    // MARK: - TopSnapCandidate

    private let candidate = PinnedRowSettle.TopSnapCandidate(seq: 40, rowKey: "cw", offsetY: 13)

    func testCandidateConfirmsTheNextSettleAtTheSameOffset() {
        XCTAssertTrue(candidate.confirms(seq: 41, rowKey: "cw", offsetY: 13))
        XCTAssertTrue(candidate.confirms(seq: 41, rowKey: "cw", offsetY: 13.5))
        XCTAssertTrue(candidate.confirms(seq: 41, rowKey: "cw", offsetY: 12.5))
    }

    /// The engine's reveal was still moving between the two reads.
    func testCandidateRejectsDrift() {
        XCTAssertFalse(candidate.confirms(seq: 41, rowKey: "cw", offsetY: 14))
        XCTAssertFalse(candidate.confirms(seq: 41, rowKey: "cw", offsetY: 9))
    }

    /// Only the very next settle on the same row confirms.
    func testCandidateRejectsAnotherSettleOrRow() {
        XCTAssertFalse(candidate.confirms(seq: 40, rowKey: "cw", offsetY: 13))
        XCTAssertFalse(candidate.confirms(seq: 42, rowKey: "cw", offsetY: 13))
        XCTAssertFalse(candidate.confirms(seq: 41, rowKey: "catalog-0", offsetY: 13))
    }

    /// `settleSeq` wraps (`&+=`); the confirmation follows it.
    func testCandidateFollowsSeqWrap() {
        let atMax = PinnedRowSettle.TopSnapCandidate(seq: Int.max, rowKey: "cw", offsetY: 13)
        XCTAssertTrue(atMax.confirms(seq: Int.min, rowKey: "cw", offsetY: 13))
    }
}
