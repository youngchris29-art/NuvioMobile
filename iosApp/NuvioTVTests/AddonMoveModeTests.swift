import XCTest
@testable import NuvioTV

/// Add-ons hub v2 (A4): the pure Move mode reducer.
final class AddonMoveModeTests: XCTestCase {

    func testNotMovingIsInert() {
        var mode = AddonMoveMode()
        XCTAssertFalse(mode.isMoving)
        XCTAssertNil(mode.step(.down, currentIndex: 0, count: 4, now: 0))
        XCTAssertNil(mode.commit())
        XCTAssertNil(mode.cancel())
        XCTAssertFalse(mode.isMoving)
    }

    func testStepsAreThrottledAndBounded() {
        var mode = AddonMoveMode()
        mode.start(manifestUrl: "a", index: 1)
        XCTAssertEqual(mode.step(.down, currentIndex: 1, count: 4, now: 0), 2)
        XCTAssertNil(mode.step(.down, currentIndex: 2, count: 4, now: 0.05))
        XCTAssertEqual(mode.step(.down, currentIndex: 2, count: 4, now: 0.2), 3)
        XCTAssertNil(mode.step(.down, currentIndex: 3, count: 4, now: 1.0))
        XCTAssertNil(mode.step(.up, currentIndex: 0, count: 4, now: 2.0))
    }

    func testRejectedEndStepDoesNotStartThrottle() {
        var mode = AddonMoveMode()
        mode.start(manifestUrl: "a", index: 3)
        XCTAssertNil(mode.step(.down, currentIndex: 3, count: 4, now: 1.0))
        XCTAssertNil(mode.lastStepAt)
        XCTAssertEqual(mode.step(.up, currentIndex: 3, count: 4, now: 1.01), 2)
    }

    func testCancelReturnsOriginAndClears() {
        var mode = AddonMoveMode()
        mode.start(manifestUrl: "a", index: 2)
        _ = mode.step(.down, currentIndex: 2, count: 4, now: 0)
        let result = mode.cancel()
        XCTAssertEqual(result?.manifestUrl, "a")
        XCTAssertEqual(result?.origin, 2)
        XCTAssertFalse(mode.isMoving)
        XCTAssertEqual(mode.origin, 0)
        XCTAssertNil(mode.lastStepAt)
    }

    func testCommitReturnsUrlAndClears() {
        var mode = AddonMoveMode()
        mode.start(manifestUrl: "a", index: 2)
        _ = mode.step(.up, currentIndex: 2, count: 4, now: 0)
        XCTAssertEqual(mode.commit(), "a")
        XCTAssertFalse(mode.isMoving)
        XCTAssertEqual(mode.origin, 0)
        XCTAssertNil(mode.lastStepAt)
    }

    func testStartReplacesMoveInProgress() {
        var mode = AddonMoveMode()
        mode.start(manifestUrl: "a", index: 1)
        mode.start(manifestUrl: "b", index: 3)
        XCTAssertEqual(mode.movingUrl, "b")
        XCTAssertEqual(mode.origin, 3)
        XCTAssertNil(mode.lastStepAt)
    }

    func testIsMovingUrlMatchesOnlyMovingAddon() {
        var mode = AddonMoveMode()
        XCTAssertFalse(mode.isMoving("a"))
        mode.start(manifestUrl: "a", index: 0)
        XCTAssertTrue(mode.isMoving("a"))
        XCTAssertFalse(mode.isMoving("b"))
    }
}
