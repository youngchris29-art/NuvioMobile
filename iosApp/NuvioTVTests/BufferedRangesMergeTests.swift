import XCTest
@testable import NuvioTV

final class BufferedRangesMergeTests: XCTestCase {
    private func r(_ s: Double, _ e: Double) -> BufferedRange { BufferedRange(start: s, end: e) }

    func testUnsortedInputIsSorted() {
        XCTAssertEqual(BufferedRange.merge([r(100, 120), r(0, 10)], gapSec: 5, durationSec: 600),
                       [r(0, 10), r(100, 120)])
    }

    func testGapUnderThresholdMerges() {
        XCTAssertEqual(BufferedRange.merge([r(0, 10), r(14.9, 20)], gapSec: 5, durationSec: 600), [r(0, 20)])
    }

    func testGapAtThresholdStaysApart() {
        XCTAssertEqual(BufferedRange.merge([r(0, 10), r(15, 20)], gapSec: 5, durationSec: 600),
                       [r(0, 10), r(15, 20)])
    }

    func testOverlappingMerge() {
        XCTAssertEqual(BufferedRange.merge([r(0, 30), r(10, 20), r(25, 50)], gapSec: 5, durationSec: 600),
                       [r(0, 50)])
    }

    func testClampToDurationAndDropEmpty() {
        XCTAssertEqual(BufferedRange.merge([r(-5, 10), r(590, 700), r(30, 30), r(40, 35)], gapSec: 5, durationSec: 600),
                       [r(0, 10), r(590, 600)])
    }

    func testEmptyInEmptyOut() {
        XCTAssertEqual(BufferedRange.merge([], gapSec: 5, durationSec: 600), [])
    }
}
