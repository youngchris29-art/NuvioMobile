import XCTest
@testable import NuvioTV

/// beta.18 verdict (BUG-126): the `debug.rowStepAB` bitmask and the hero-commit wait policy.
final class RowStepABTests: XCTestCase {
    func testBitDecoding() {
        let d = RowStepAB.deferHeroCommitUntilRest
        let h = RowStepAB.handlerOnlyRowStateOffBody
        XCTAssertFalse(RowStepAB.isSet(d, in: 0)); XCTAssertFalse(RowStepAB.isSet(h, in: 0))
        XCTAssertTrue(RowStepAB.isSet(d, in: 1));  XCTAssertFalse(RowStepAB.isSet(h, in: 1))
        XCTAssertFalse(RowStepAB.isSet(d, in: 2)); XCTAssertTrue(RowStepAB.isSet(h, in: 2))
        XCTAssertTrue(RowStepAB.isSet(d, in: 3));  XCTAssertTrue(RowStepAB.isSet(h, in: 3))
    }

    func testCommitWaitsWhileMotionIsFresh() {
        XCTAssertEqual(RowStepAB.heroCommitDelay(sinceMotion: 0.0, elapsed: 0), 0.05)
    }

    func testCommitsAtOnceWhenQuiet() {
        XCTAssertNil(RowStepAB.heroCommitDelay(sinceMotion: 0.2, elapsed: 0))
        XCTAssertNil(RowStepAB.heroCommitDelay(sinceMotion: 0.12, elapsed: 0))
    }

    func testNeverWaitsPastCap() {
        XCTAssertNil(RowStepAB.heroCommitDelay(sinceMotion: 0.0, elapsed: 0.5))
        XCTAssertEqual(RowStepAB.heroCommitDelay(sinceMotion: 0.0, elapsed: 0.48)!, 0.02, accuracy: 0.0001)
        var elapsed: TimeInterval = 0
        var steps = 0
        while let wait = RowStepAB.heroCommitDelay(sinceMotion: 0.0, elapsed: elapsed) {
            elapsed += wait; steps += 1
            if steps > 100 { XCTFail("unbounded wait"); break }
        }
        XCTAssertEqual(elapsed, 0.5, accuracy: 0.0001)
    }
}
