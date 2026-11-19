import XCTest
@testable import NuvioTV

/// GitHub #33: the click latch, the composed preview-request lifecycle (design review r2-2) and
/// the completion rule (r1-5, r2-5).
final class SeekPreviewLifecycleTests: XCTestCase {

    // MARK: ClickPreviewLatch

    typealias Latch = ClickPreviewLatch

    func testQuickLandingEndsAtTheDwell() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        XCTAssertEqual(l.nextDeadline, 10 + Latch.fallbackSec)
        l.landed(generation: 3, now: 10.2)
        XCTAssertEqual(l.nextDeadline!, 10 + Latch.minDwellSec, accuracy: 1e-9)
        l.tick(now: 11.1)
        XCTAssertNotNil(l.active, "still inside the dwell")
        l.tick(now: 11.21)
        XCTAssertNil(l.active)
        XCTAssertNil(l.nextDeadline)
    }

    func testDelayedLandingEndsAtTheLanding() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.tick(now: 12)
        XCTAssertNotNil(l.active)
        l.landed(generation: 3, now: 12.5)
        XCTAssertEqual(l.nextDeadline, 12.5)
        l.tick(now: 12.5)
        XCTAssertNil(l.active)
    }

    func testNoLandingEndsAtTheFallback() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.tick(now: 13.99)
        XCTAssertNotNil(l.active)
        l.tick(now: 14)
        XCTAssertNil(l.active)
    }

    func testANewerSeekLandingSupersedes() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.landed(generation: 2, now: 10.1)
        XCTAssertEqual(l.nextDeadline, 14, "an older landing is ignored")
        l.landed(generation: 4, now: 10.2)
        XCTAssertNil(l.active)
    }

    func testRejected() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.rejected(generation: 2)
        XCTAssertNotNil(l.active, "another generation's rejection is ignored")
        l.rejected(generation: 4)
        XCTAssertNotNil(l.active)
        l.rejected(generation: 3)
        XCTAssertNil(l.active)
    }

    func testSecondClickReplaces() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.landed(generation: 3, now: 10.1)
        l.clicked(targetSec: 120, generation: 4, now: 10.5)
        XCTAssertEqual(l.active, Latch.Active(targetSec: 120, generation: 4, shownAt: 10.5, deadline: 14.5))
        l.landed(generation: 3, now: 10.75)
        XCTAssertEqual(l.nextDeadline, 14.5, "the first click's late landing does not end the second card")
    }

    func testClear() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.clear()
        XCTAssertNil(l.active)
        XCTAssertNil(l.nextDeadline)
        l.landed(generation: 3, now: 11)
        l.rejected(generation: 3)
        l.tick(now: 20)
        XCTAssertNil(l.active)
    }

    func testNextDeadlineInEachState() {
        var l = Latch()
        XCTAssertNil(l.nextDeadline, "idle")
        l.clicked(targetSec: 1, generation: 1, now: 0)
        XCTAssertEqual(l.nextDeadline, 4, "waiting for the landing")
        l.landed(generation: 1, now: 0.5)
        XCTAssertEqual(l.nextDeadline!, 1.2, accuracy: 1e-9, "landed inside the dwell")
        l.clicked(targetSec: 1, generation: 2, now: 5)
        l.landed(generation: 2, now: 7)
        XCTAssertEqual(l.nextDeadline, 7, "landed after the dwell")
    }

    // MARK: SeekPreviewLifecycle

    typealias LC = SeekPreviewLifecycle
    typealias Key = SeekPreviewLifecycle.Key
    typealias E = SeekPreviewLifecycle.Effects

    private static let both = SeekPreviewCapability(fillsWatched: true, fillsUnwatched: true)
    private static let watched = SeekPreviewCapability(fillsWatched: true, fillsUnwatched: false)

    private func key(_ t: Double?, _ c: SeekPreviewCapability = both, gen: Int = 0, alive: Bool = true) -> Key {
        Key(requestTargetSec: t, capability: c, sourceGeneration: gen, alive: alive)
    }

    func testUnchanged() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(10)), [])
        XCTAssertEqual(LC.effects(from: key(nil), to: key(nil)), [])
    }

    func testTeardown() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(10, alive: false)), E.cleanup.union(.clearLatch))
        XCTAssertEqual(LC.effects(from: key(nil), to: key(nil, alive: false)), E.cleanup.union(.clearLatch))
        XCTAssertEqual(LC.effects(from: key(nil, alive: false), to: key(10, alive: false)), [], "nothing after teardown")
    }

    func testSourceGenerationChanged() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(10, gen: 1)), E.cleanup.union(.requestNow))
        XCTAssertEqual(LC.effects(from: key(10), to: key(20, gen: 1)), E.cleanup.union(.requestNow))
        XCTAssertEqual(LC.effects(from: key(nil), to: key(nil, gen: 1)), E.cleanup)
    }

    func testCapabilityLost() {
        // `any` lost: the plan has no request target any more (card time only).
        XCTAssertEqual(LC.effects(from: key(10), to: key(nil, .none)), E.cleanup)
        // `fillsUnwatched` lost, watched kept: cleaned up, then the same target asks again.
        XCTAssertEqual(LC.effects(from: key(10), to: key(10, Self.watched)), E.cleanup.union(.requestNow))
    }

    func testCapabilityGained() {
        XCTAssertEqual(LC.effects(from: key(nil, .none), to: key(10)), [.requestNow])
        XCTAssertEqual(LC.effects(from: key(10, Self.watched), to: key(10)), [.requestNow],
                       "fillsUnwatched gained during a stationary target")
        XCTAssertEqual(LC.effects(from: key(nil, .none), to: key(nil)), [], "no target, nothing to ask")
    }

    func testTargetEdges() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(nil)), E.cleanup)
        XCTAssertEqual(LC.effects(from: key(nil), to: key(10)), [.requestNow])
        XCTAssertEqual(LC.effects(from: key(10), to: key(20)), [.requestNow], "a move is a throttled sample")
    }

    // Combined edges (r2-2): every independent cleanup still runs.

    func testCapabilityGainPlusTargetExit() {
        XCTAssertEqual(LC.effects(from: key(10, Self.watched), to: key(nil)), E.cleanup)
    }

    func testSourceChangePlusTargetExit() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(nil, gen: 1)), E.cleanup)
    }

    func testSourceChangePlusTeardown() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(10, gen: 1, alive: false)), E.cleanup.union(.clearLatch),
                       "teardown dominates: never a request")
    }

    func testCapabilityLossPlusTargetMove() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(20, Self.watched)), E.cleanup.union(.requestNow))
    }

    // MARK: SeekPreviewCompletion

    typealias C = SeekPreviewCompletion
    private func plan(_ t: Double?) -> SeekPreviewPlan {
        SeekPreviewPlan(requestTargetSec: t, cardTargetSec: t, placeholderAllowed: true)
    }

    func testStaleGenerationDoesNothing() {
        let d = C.decide(requestGeneration: 1, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(100), shownSec: 100)
        XCTAssertEqual(d, C.Decision.stale)
        XCTAssertFalse(d.finishThrottle)
        XCTAssertNil(d.refineTargetSec)
    }

    func testCurrentAccepted() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(100), shownSec: 96)
        XCTAssertEqual(d, C.Decision(frame: .publish, finishThrottle: true, refineTargetSec: 100))
    }

    func testCurrentOutOfReach() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(300), shownSec: 100)
        XCTAssertEqual(d.frame, .keep, "120 s reach measured against the current target")
        XCTAssertTrue(d.finishThrottle)
        XCTAssertNil(d.refineTargetSec, "the old target is never refined")
    }

    func testCurrentNilSameTargetClears() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(100), shownSec: nil)
        XCTAssertEqual(d, C.Decision(frame: .clear, finishThrottle: true, refineTargetSec: 100))
    }

    func testCurrentNilMovedTargetKeeps() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(140), shownSec: nil)
        XCTAssertEqual(d, C.Decision(frame: .keep, finishThrottle: true, refineTargetSec: nil))
    }

    func testMovedTargetStillPublishesAFrameInReach() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(140), shownSec: 101)
        XCTAssertEqual(d, C.Decision(frame: .publish, finishThrottle: true, refineTargetSec: nil))
    }

    func testNoCurrentTargetOnlyFinishes() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: .none, shownSec: 100)
        XCTAssertEqual(d, C.Decision(frame: .keep, finishThrottle: true, refineTargetSec: nil))
    }
}
