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
