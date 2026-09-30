import XCTest
@testable import NuvioTV

final class HomeUpPressConsumptionTests: XCTestCase {
    func testNilTimestampIsNotConsumed() {
        XCTAssertFalse(HomeUpPressConsumption.isConsumed(now: 100, lastRowFocusChange: nil))
    }

    func testRecentChangeIsConsumed() {
        XCTAssertTrue(HomeUpPressConsumption.isConsumed(now: 100, lastRowFocusChange: 99.9))
    }

    func testJustOutsideWindowIsNotConsumed() {
        XCTAssertFalse(HomeUpPressConsumption.isConsumed(now: 100.31, lastRowFocusChange: 100.0))
    }

    func testJustInsideWindowIsConsumed() {
        XCTAssertTrue(HomeUpPressConsumption.isConsumed(now: 100, lastRowFocusChange: 99.71))
    }

    func testFutureTimestampIsNotConsumed() {
        XCTAssertFalse(HomeUpPressConsumption.isConsumed(now: 100, lastRowFocusChange: 100.5))
    }
}
