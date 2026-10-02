import XCTest
import SwiftUI
@testable import NuvioTV

/// beta.18 verdict (BUG-118, R3): the Soft row-edge-fade mask geometry (`RowSoftEdgeMask.segments`,
/// the same function the live view builds from).
final class RowSoftEdgeMaskTests: XCTestCase {
    private let width: CGFloat = 1000
    private let margin: CGFloat = 140

    func testRestWithAllowanceCutsHardAtMinusAllowance() {
        let s = RowSoftEdgeMask.segments(width: width, margin: margin, restClipAllowance: 36, leadingActive: false)
        XCTAssertEqual(s[0], .init(start: -margin, end: -36, kind: .clear))
        XCTAssertEqual(s[1], .init(start: -36, end: 0, kind: .solid))
    }

    func testScrolledRampInSpansWholeMargin() {
        let s = RowSoftEdgeMask.segments(width: width, margin: margin, restClipAllowance: 36, leadingActive: true)
        XCTAssertEqual(s[0], .init(start: -margin, end: 0, kind: .rampIn))
    }

    func testRampOutSpansWholeTrailingMargin() {
        for active in [false, true] {
            let s = RowSoftEdgeMask.segments(width: width, margin: margin, restClipAllowance: 36, leadingActive: active)
            XCTAssertEqual(s.last, .init(start: width, end: width + margin, kind: .rampOut))
        }
    }

    func testRestWithoutAllowanceIsSingleSolidLeadingPiece() {
        let s = RowSoftEdgeMask.segments(width: width, margin: margin, restClipAllowance: 0, leadingActive: false)
        XCTAssertEqual(s[0], .init(start: -margin, end: 0, kind: .solid))
        XCTAssertEqual(s.count, 3)
    }

    func testMarginIsScreenInsetPlusSideSafeArea() {
        XCTAssertEqual(RowSoftEdgeMask.margin, Theme.Spacing.screen + PinnedRowGeometry.sideSafeArea)
    }

    func testSegmentsAreContiguous() {
        for active in [false, true] {
            for allowance: CGFloat in [0, 36] {
                let s = RowSoftEdgeMask.segments(width: width, margin: margin, restClipAllowance: allowance, leadingActive: active)
                for i in 1..<s.count { XCTAssertEqual(s[i - 1].end, s[i].start) }
            }
        }
    }
}
