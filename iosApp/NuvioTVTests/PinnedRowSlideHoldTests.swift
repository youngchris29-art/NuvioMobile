import XCTest
import CoreGraphics
@testable import NuvioTV

/// beta.18 verdict (BUG-87/89, R1) — the pinned title's slide hold is released by the settle
/// corrector's rest DECISION, not by its own wall clock. Pure-value tests, like
/// `PinnedRowSettleRc14Tests`: the verdict `commitSlide` switches on, the rest-decision observer
/// registry, the reason the decision line carries, and the timing invariants between the hold's
/// clocks and the corrector's.
@MainActor
final class PinnedRowSlideHoldTests: XCTestCase {

    // MARK: - slideHoldVerdict

    func testZeroTargetWhileMovingSnaps() {
        XCTAssertEqual(PinnedRowTitle.slideHoldVerdict(target: 0, current: 8, moving: true, restPending: false),
                       .snapToZero)
        XCTAssertEqual(PinnedRowTitle.slideHoldVerdict(target: 0, current: 8, moving: true, restPending: true),
                       .snapToZero)
    }

    func testZeroTargetAtRestEases() {
        // A pending decision never holds a 0 target: 0 is never wrong for a contained title.
        XCTAssertEqual(PinnedRowTitle.slideHoldVerdict(target: 0, current: 8, moving: false, restPending: false),
                       .apply)
        XCTAssertEqual(PinnedRowTitle.slideHoldVerdict(target: 0, current: 8, moving: false, restPending: true),
                       .apply)
    }

    func testZeroTargetAlreadyAtZeroIsAPlainApply() {
        XCTAssertEqual(PinnedRowTitle.slideHoldVerdict(target: 0, current: 0, moving: false, restPending: false),
                       .apply)
        XCTAssertEqual(PinnedRowTitle.slideHoldVerdict(target: 0, current: 0, moving: true, restPending: false),
                       .apply)
    }

    func testNonzeroTargetHoldsWhileMovingOrPending() {
        XCTAssertEqual(PinnedRowTitle.slideHoldVerdict(target: 8, current: 0, moving: true, restPending: false),
                       .hold)
        XCTAssertEqual(PinnedRowTitle.slideHoldVerdict(target: 8, current: 0, moving: false, restPending: true),
                       .hold)
        XCTAssertEqual(PinnedRowTitle.slideHoldVerdict(target: 8, current: 0, moving: true, restPending: true),
                       .hold)
    }

    func testNonzeroTargetAtDecidedRestApplies() {
        XCTAssertEqual(PinnedRowTitle.slideHoldVerdict(target: 8, current: 0, moving: false, restPending: false),
                       .apply)
    }

    // MARK: - Rest-decision observers

    func testRestDecisionBroadcastsToEveryRegisteredRow() {
        var calledA = 0
        var calledB = 0
        let keyA = "test.slideHold.a.\(UUID().uuidString)"
        let keyB = "test.slideHold.b.\(UUID().uuidString)"
        let tokenA = PinnedRowSettle.observeRestDecision(rowKey: keyA) { calledA += 1 }
        let tokenB = PinnedRowSettle.observeRestDecision(rowKey: keyB) { calledB += 1 }
        defer {
            PinnedRowSettle.stopObservingRestDecision(rowKey: keyA, token: tokenA)
            PinnedRowSettle.stopObservingRestDecision(rowKey: keyB, token: tokenB)
        }

        // The host app may have live titles registered too, so the count is asserted as a delta.
        let both = PinnedRowSettle.notifyRestDecided(reason: "clean")
        XCTAssertEqual(calledA, 1)
        XCTAssertEqual(calledB, 1)
        XCTAssertGreaterThanOrEqual(both, 2)

        PinnedRowSettle.stopObservingRestDecision(rowKey: keyA, token: tokenA)
        let one = PinnedRowSettle.notifyRestDecided(reason: "clean")
        XCTAssertEqual(calledA, 1, "a stopped observer must not be called")
        XCTAssertEqual(calledB, 2)
        XCTAssertEqual(one, both - 1)
    }

    func testStaleTokenDoesNotUnregisterTheReplacement() {
        var calledOld = 0
        var calledNew = 0
        let key = "test.slideHold.remount.\(UUID().uuidString)"
        let oldToken = PinnedRowSettle.observeRestDecision(rowKey: key) { calledOld += 1 }
        // A `.id()` remount registers the incoming title before the outgoing one tears down.
        let newToken = PinnedRowSettle.observeRestDecision(rowKey: key) { calledNew += 1 }
        defer { PinnedRowSettle.stopObservingRestDecision(rowKey: key, token: newToken) }
        PinnedRowSettle.stopObservingRestDecision(rowKey: key, token: oldToken)

        PinnedRowSettle.notifyRestDecided(reason: "clean")
        XCTAssertEqual(calledOld, 0)
        XCTAssertEqual(calledNew, 1)
    }

    // MARK: - restDecisionReason

    func testRestDecisionReasonFromReports() {
        XCTAssertEqual(PinnedRowSettle.restDecisionReason(report: "row=x margin=-8 nudge=0"), "clean")
        XCTAssertEqual(PinnedRowSettle.restDecisionReason(report: "row=x margin=-8 nudge=0 topRest=1"), "topRest")
        XCTAssertEqual(PinnedRowSettle.restDecisionReason(report: "row=x margin=-90 nudge=0 room=12"), "room")
        XCTAssertEqual(PinnedRowSettle.restDecisionReason(report: "row=- state=nofocus y=120 seq=3"), "nofocus")
        XCTAssertEqual(PinnedRowSettle.restDecisionReason(report: "row=x clearance=30 nudge=0 standDown=lift-deficit"),
                       "standdown")
    }

    // MARK: - Clock invariants

    func testFallbackOutlastsTheCorrectorsDecisionAndNudge() {
        // A decision that is coming (settle at settleDelay, plus a nudge's own nudgeDuration) must
        // always beat the wall-clock fallback, or the title lands before the nudge again.
        XCTAssertGreaterThan(PinnedRowTitle.slideHoldMax,
                             PinnedRowSettle.settleDelay + PinnedRowSettle.nudgeDuration)
    }

    func testCeilingOutlastsTheFallback() {
        XCTAssertLessThan(PinnedRowTitle.slideHoldMax, PinnedRowTitle.slideHoldCeiling)
    }

    func testMotionWindowIsShorterThanTheFallback() {
        XCTAssertLessThan(PinnedRowTitle.slideMotionHold, PinnedRowTitle.slideHoldMax)
    }
}
