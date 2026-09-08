import XCTest
import SwiftUI
@testable import NuvioTV

/// BUG-96 (beta.18): the unit-point math that lands a focused detail row's top at
/// `DetailRowAnchor.topInset`. `scrollTo(_:anchor:)` aligns the row's anchor point with the scroll
/// view's same anchor point, so the point is solved, not guessed.
final class DetailRowAnchorTests: XCTestCase {

    /// Given the solved point, the row's top lands at the inset: `row.minY = k·vh − k·rh`.
    private func landedTop(rowHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let k = DetailRowAnchor.anchor(rowHeight: rowHeight, viewportHeight: viewportHeight).y
        return k * viewportHeight - k * rowHeight
    }

    func testTypicalRowsLandAtTheInset() {
        for rowHeight: CGFloat in [180, 320, 420, 560] {
            XCTAssertEqual(landedTop(rowHeight: rowHeight, viewportHeight: 1080),
                           DetailRowAnchor.topInset, accuracy: 0.001,
                           "row \(rowHeight)pt must rest with its top at the inset")
        }
    }

    func testAnchorXIsLeading() {
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 300, viewportHeight: 1080).x, 0)
    }

    func testARowTallerThanTheViewportTopAligns() {
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 1200, viewportHeight: 1080), .top)
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 1080, viewportHeight: 1080), .top)
    }

    func testAnchorNeverLeavesTheUnitRange() {
        // A row nearly as tall as the viewport would need k > 1 to reach the inset; it is clamped.
        let point = DetailRowAnchor.anchor(rowHeight: 1060, viewportHeight: 1080)
        XCTAssertEqual(point.y, 1, accuracy: 0.001)
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 0, viewportHeight: 1080, topInset: 0).y, 0)
    }

    func testCustomInsetIsHonoured() {
        XCTAssertEqual(landedTopWithInset(48), 48, accuracy: 0.001)
    }

    private func landedTopWithInset(_ inset: CGFloat) -> CGFloat {
        let k = DetailRowAnchor.anchor(rowHeight: 300, viewportHeight: 1080, topInset: inset).y
        return k * 1080 - k * 300
    }
}

/// BUG-96 (rc5 regression fix): `DetailScrollMotion.segments` is the `moves=` oracle — one motion
/// (engine reveal blended with the anchor pass) must read as `1`, and the old land-then-nudge
/// design (a settle wait long enough for the engine to fully rest before the anchor slid it again)
/// would read as `2`. Fabricated offset arrays stand in for a live `ScrollView`'s per-frame samples.
final class DetailScrollMotionTests: XCTestCase {

    func testSingleRampIsOneSegment() {
        let offsets: [CGFloat] = [0, 40, 90, 150, 220, 300, 390, 460, 500, 520, 528, 530]
        XCTAssertEqual(DetailScrollMotion.segments(offsets), 1)
    }

    func testRampPlateauOfSixThenRampIsTwoSegments() {
        // A ramp settles at 300, holds there for 6 samples (5 stationary deltas plus the delta
        // that lands on the plateau — 6 in all, at/above `stationaryRunToSplit`), then a second
        // ramp begins.
        let ramp1: [CGFloat] = [0, 60, 130, 210, 300]
        let plateau: [CGFloat] = Array(repeating: 300, count: 6)
        let ramp2: [CGFloat] = [300, 380, 470, 560]
        XCTAssertEqual(DetailScrollMotion.segments(ramp1 + plateau + ramp2), 2)
    }

    func testPlateauOnlyIsZeroSegments() {
        let offsets: [CGFloat] = Array(repeating: 200, count: 10)
        XCTAssertEqual(DetailScrollMotion.segments(offsets), 0)
    }

    func testSubThresholdJitterIsIgnored() {
        // Every delta stays under `stationaryThreshold` (0.5pt) — sub-pixel `ScrollView` noise at
        // rest, not real motion.
        let offsets: [CGFloat] = [100, 100.3, 100.1, 100.4, 100.2, 100.0, 100.3]
        XCTAssertEqual(DetailScrollMotion.segments(offsets), 0)
    }

    func testShortStationaryGapInsideARampDoesNotSplitIt() {
        // A 2-sample stationary gap mid-ramp — below `stationaryRunToSplit` (4) — must read as
        // one continuous motion, not two: the fixture case a resized card's layout catching its
        // breath mid-reveal must not be mistaken for the land-then-nudge regression.
        let offsets: [CGFloat] = [0, 50, 110, 110, 110, 180, 260, 340]
        XCTAssertEqual(DetailScrollMotion.segments(offsets), 1)
    }

    func testEmptyAndSingleSampleAreZeroSegments() {
        XCTAssertEqual(DetailScrollMotion.segments([]), 0)
        XCTAssertEqual(DetailScrollMotion.segments([42]), 0)
    }
}
