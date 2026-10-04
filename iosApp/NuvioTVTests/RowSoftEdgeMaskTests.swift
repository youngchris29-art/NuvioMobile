import XCTest
import SwiftUI
@testable import NuvioTV

/// beta.18 verdict (BUG-118, R3) → beta.19-rc1 verdict (F, FEAT-54): the Soft row-edge-fade mask
/// geometry (`RowSoftEdgeMask.segments`, the same function the live view builds from). Ramps now
/// run `rampLength` in from the BEZEL (so they start inside the row frame), each side has its own
/// margin, and the vertical overdraw is 72 pt.
@MainActor
final class RowSoftEdgeMaskTests: XCTestCase {
    private let width: CGFloat = 1000
    private let standard = RowEdgeMargins(leading: 140, trailing: 140)
    private let ramp: CGFloat = 250

    private func segments(width: CGFloat? = nil, margins: RowEdgeMargins? = nil, rampLength: CGFloat? = nil,
                          allowance: CGFloat, active: Bool) -> [RowSoftEdgeMask.Segment] {
        RowSoftEdgeMask.segments(width: width ?? self.width, margins: margins ?? standard,
                                 rampLength: rampLength ?? ramp, restClipAllowance: allowance,
                                 leadingActive: active)
    }

    func testRestWithAllowanceCutsHardAtMinusAllowance() {
        let s = segments(allowance: 36, active: false)
        XCTAssertEqual(s[0], .init(start: -140, end: -36, kind: .clear))
        XCTAssertEqual(s[1], .init(start: -36, end: 0, kind: .solid))
        XCTAssertEqual(s[2], .init(start: 0, end: width + 140 - ramp, kind: .solid))
    }

    func testRestWithoutAllowanceIsSingleSolidLeadingPiece() {
        let s = segments(allowance: 0, active: false)
        XCTAssertEqual(s[0], .init(start: -140, end: 0, kind: .solid))
        XCTAssertEqual(s.count, 3)
    }

    /// The scrolled leading ramp runs from the bezel (−140) to 250 pt in, i.e. 110 pt inside the
    /// row frame.
    func testScrolledLeadingRampStartsInsideFrame() {
        let s = segments(width: 1640, allowance: 36, active: true)
        XCTAssertEqual(s[0], .init(start: -140, end: 110, kind: .rampIn))
        XCTAssertEqual(s[1], .init(start: 110, end: 1530, kind: .solid))
    }

    func testTrailingRampStartsInsideFrame() {
        for active in [false, true] {
            let s = segments(width: 1640, allowance: 36, active: active)
            XCTAssertEqual(s.last, .init(start: 1530, end: 1780, kind: .rampOut), "active=\(active)")
        }
    }

    /// A row narrower than two ramps: each ramp is capped at margin + width/2 (190 for a 100 pt
    /// row), so the two never overlap and the middle piece shrinks to zero.
    func testRampClampsOnNarrowRows() {
        XCTAssertEqual(RowSoftEdgeMask.effectiveRamp(250, margin: 140, width: 100), 190)
        let s = segments(width: 100, allowance: 0, active: true)
        XCTAssertEqual(s[0], .init(start: -140, end: 50, kind: .rampIn))
        XCTAssertEqual(s[1], .init(start: 50, end: 50, kind: .solid))
        XCTAssertEqual(s.last, .init(start: 50, end: 240, kind: .rampOut))
    }

    /// A host with different chrome (the Stage strip with the rail Always Visible) passes its own
    /// margins; each side ramps from its own bezel.
    func testAsymmetricMargins() {
        let margins = RowEdgeMargins(leading: 116, trailing: 140)
        let s = segments(width: 1640, margins: margins, allowance: 36, active: true)
        XCTAssertEqual(s[0], .init(start: -116, end: 134, kind: .rampIn))
        XCTAssertEqual(s.last, .init(start: 1530, end: 1780, kind: .rampOut))
        let rest = segments(width: 1640, margins: margins, allowance: 36, active: false)
        XCTAssertEqual(rest[0], .init(start: -116, end: -36, kind: .clear))
    }

    /// Critique #12: the overdraw shrank from 400 to 72 pt; it must still hold everything a
    /// focused card draws past the row frame (lift + shadow radius + shadow y + ring).
    func testVerticalOverdrawCoversLiftShadowRing() {
        XCTAssertGreaterThanOrEqual(RowSoftEdgeMask.verticalOverdraw,
                                    Theme.Size.heroPinnedRowFocusLiftAllowance + 22 + 10 + ringWidth)
        XCTAssertEqual(RowSoftEdgeMask.verticalOverdraw, 72)
    }

    func testMarginIsScreenInsetPlusSideSafeArea() {
        XCTAssertEqual(RowSoftEdgeMask.margin, Theme.Spacing.screen + PinnedRowGeometry.sideSafeArea)
        XCTAssertEqual(RowEdgeMargins.standard, RowEdgeMargins(leading: RowSoftEdgeMask.margin,
                                                               trailing: RowSoftEdgeMask.margin))
    }

    func testSegmentsAreContiguousAndSpanBezelToBezel() {
        let marginSets = [standard, RowEdgeMargins(leading: 116, trailing: 140), RowEdgeMargins(leading: 0, trailing: 0)]
        for width: CGFloat in [0, 100, 1000, 1640] {
            for margins in marginSets {
                for active in [false, true] {
                    for allowance: CGFloat in [0, 36, 400] {
                        let s = segments(width: width, margins: margins, allowance: allowance, active: active)
                        let tag = "width=\(width) margins=\(margins) active=\(active) allowance=\(allowance)"
                        XCTAssertEqual(s.first?.start, -margins.leading, tag)
                        XCTAssertEqual(s.last?.end, width + margins.trailing, tag)
                        for i in 1..<s.count { XCTAssertEqual(s[i - 1].end, s[i].start, tag) }
                        for seg in s { XCTAssertGreaterThanOrEqual(seg.end, seg.start, tag) }
                    }
                }
            }
        }
    }
}
