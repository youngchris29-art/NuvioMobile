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
                          allowance: CGFloat, active: Bool, trailingActive: Bool = true) -> [RowSoftEdgeMask.Segment] {
        RowSoftEdgeMask.segments(width: width ?? self.width, margins: margins ?? standard,
                                 rampLength: rampLength ?? ramp, restClipAllowance: allowance,
                                 leadingActive: active, trailingActive: trailingActive)
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

    /// Critique #12 shrank the overdraw from 400 pt; it must still hold everything a focused card
    /// draws past the row frame (lift + shadow radius + shadow y + ring) AND the pinned row's top
    /// reach plus the lift, or the focus engine rests the row differently with the mask on
    /// (Gate 4: Soft@72 rested 14 pt off Off on FA87; Soft@160 matched it).
    func testVerticalOverdrawCoversLiftShadowRing() {
        XCTAssertGreaterThanOrEqual(RowSoftEdgeMask.verticalOverdraw,
                                    Theme.Size.heroPinnedRowFocusLiftAllowance + 22 + 10 + ringWidth)
        XCTAssertGreaterThanOrEqual(RowSoftEdgeMask.verticalOverdraw,
                                    Theme.Size.heroPinnedRowTopPad + Theme.Size.heroPinnedRowFocusLiftAllowance)
        XCTAssertEqual(RowSoftEdgeMask.verticalOverdraw, 160)
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
                    for trailingActive in [true, false] {
                        for allowance: CGFloat in [0, 36, 400] {
                            let s = segments(width: width, margins: margins, allowance: allowance, active: active,
                                             trailingActive: trailingActive)
                            let tag = "width=\(width) margins=\(margins) active=\(active) trailing=\(trailingActive) allowance=\(allowance)"
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

    // MARK: Review r1, B P2-2: an expanded inline trailer must never sit in the trailing ramp

    /// The ramp's reach inside the frame is the morph scroll's trailing inset: 110 with the standard
    /// margin and ramp, less on a narrow row (the ramp is capped), 0 when the ramp ends outside it.
    func testTrailingInnerExtent() {
        XCTAssertEqual(RowSoftEdgeMask.trailingInnerExtent(width: 1640, margins: standard, rampLength: 250), 110)
        // Narrow row: the drawn ramp is 140 + 50 = 190, so 50 of it is inside.
        XCTAssertEqual(RowSoftEdgeMask.trailingInnerExtent(width: 100, margins: standard, rampLength: 250), 50)
        XCTAssertEqual(RowSoftEdgeMask.trailingInnerExtent(width: 1640, margins: standard, rampLength: 120), 0)
        // Each side reads its own margin (the Stage strip's chrome).
        XCTAssertEqual(RowSoftEdgeMask.trailingInnerExtent(width: 1640, margins: RowEdgeMargins(leading: 116, trailing: 90),
                                                           rampLength: 250), 160)
        // It is exactly where the drawn rampOut begins, measured from the frame's trailing edge.
        let s = segments(width: 1640, allowance: 36, active: true)
        XCTAssertEqual(1640 - (s.last?.start ?? 0), 110)
    }

    /// Only Soft draws a ramp, so only Soft asks the morph scroll for an inset.
    func testTrailingTileInsetFollowsTheSetting() {
        XCTAssertEqual(RowEdgeFade.trailingTileInset(setting: .soft, rowWidth: 1640, margins: standard, rampLength: 250), 110)
        XCTAssertEqual(RowEdgeFade.trailingTileInset(setting: .system, rowWidth: 1640, margins: standard, rampLength: 250), 0)
        XCTAssertEqual(RowEdgeFade.trailingTileInset(setting: .off, rowWidth: 1640, margins: standard, rampLength: 250), 0)
        XCTAssertEqual(RowEdgeFade.trailingTileInset(setting: .soft, rowWidth: 1640, margins: .standard,
                                                     rampLength: RowEdgeFade.rampLength),
                       RowEdgeFade.rampLength - RowSoftEdgeMask.margin)
    }

    /// The hold (a wide tile clamped at the row's end): solid to the bezel, and the rampOut piece
    /// stays as a zero-width segment so the piece count never changes (the hold eases as a width).
    func testTrailingHoldDrawsSolidToTheBezel() {
        for active in [false, true] {
            let held = segments(width: 1640, allowance: 36, active: active, trailingActive: false)
            let normal = segments(width: 1640, allowance: 36, active: active)
            XCTAssertEqual(held.count, normal.count, "active=\(active)")
            XCTAssertEqual(held.last, .init(start: 1780, end: 1780, kind: .rampOut), "active=\(active)")
            XCTAssertEqual(held[held.count - 2].kind, .solid, "active=\(active)")
            XCTAssertEqual(held[held.count - 2].end, 1780, "active=\(active)")
            // The leading side is untouched by the hold.
            XCTAssertEqual(Array(held.dropLast(2)), Array(normal.dropLast(2)), "active=\(active)")
        }
    }
}
