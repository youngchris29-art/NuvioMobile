import XCTest
@testable import NuvioTV

/// BUG-200 (GitHub #9 item 1), the studio-chip half: in the default cell (Accent Focus Ring off,
/// zoom on) `CompanyChip` lifts itself as one tile. Its row passes `cardFocusButtonStyle(lift:
/// .manual)` (a custom style, no system treatment) and the chip resolves through
/// `PlainLabelRing.smallLabelLift` (ring mode's ×1.12 `smallLabelRise` scale, without the platter).
/// Under `.borderless` only the logo lifted out of the white capsule, and the system lift measured
/// ×1.19 on the 52 pt capsule, past the 16 pt row gap. Ring and No Zoom cells must stay exactly
/// what they were.
@MainActor
final class CompanyChipLiftTests: XCTestCase {
    private let cells: [(accent: Bool, noZoom: Bool)] = [(false, false), (true, false), (false, true), (true, true)]

    private func kind(_ lift: CardButtonLift, accent: Bool, noZoom: Bool) -> CardButtonStyleKind {
        CardButtonStyleKind.resolve(noZoomOnFocus: noZoom, accentFocusRing: accent, lift: lift)
    }

    // MARK: - CardButtonLift resolution

    /// The new case: a custom style in both zoom-on cells, the still style with No Zoom, never the
    /// bare `.borderless`.
    func testManualLiftResolvesToACustomStyleInEveryCell() {
        XCTAssertEqual(kind(.manual, accent: false, noZoom: false), .ring)
        XCTAssertEqual(kind(.manual, accent: true, noZoom: false), .ring)
        XCTAssertEqual(kind(.manual, accent: false, noZoom: true), .still)
        XCTAssertEqual(kind(.manual, accent: true, noZoom: true), .still)
        for cell in cells {
            XCTAssertNotEqual(kind(.manual, accent: cell.accent, noZoom: cell.noZoom), .borderless,
                              "accent=\(cell.accent) noZoom=\(cell.noZoom)")
        }
    }

    /// Every other card class is untouched: `.card` and `.plain` resolve exactly the BUG-93/108
    /// table, and `.manual` differs from `.card` in the default cell only.
    func testCardAndPlainResolutionIsUnchanged() {
        XCTAssertEqual(kind(.card, accent: false, noZoom: false), .borderless)
        XCTAssertEqual(kind(.card, accent: true, noZoom: false), .ring)
        XCTAssertEqual(kind(.card, accent: false, noZoom: true), .still)
        XCTAssertEqual(kind(.card, accent: true, noZoom: true), .still)
        XCTAssertEqual(kind(.plain, accent: false, noZoom: false), .borderless)
        XCTAssertEqual(kind(.plain, accent: true, noZoom: false), .borderless)
        XCTAssertEqual(kind(.plain, accent: false, noZoom: true), .still)
        XCTAssertEqual(kind(.plain, accent: true, noZoom: true), .still)
        for cell in cells where cell.accent || cell.noZoom {
            XCTAssertEqual(kind(.manual, accent: cell.accent, noZoom: cell.noZoom),
                           kind(.card, accent: cell.accent, noZoom: cell.noZoom),
                           "accent=\(cell.accent) noZoom=\(cell.noZoom)")
        }
    }

    // MARK: - The chip's own lift

    /// The default cell is the new treatment: the chip's manual scale.
    func testDefaultCellIsTheChipsManualLift() {
        XCTAssertEqual(PlainLabelRing.smallLabelLift(accentFocusRing: false, noZoomOnFocus: false), .manualScale)
        // Before BUG-200 the chip resolved this cell to the no-op `.still` under `.borderless`.
        XCTAssertEqual(PlainLabelRing.lift(accentFocusRing: false, noZoomOnFocus: false), .still(ringed: false))
    }

    /// Ring on and both No Zoom cells: byte-identical to the pre-BUG-200 resolver
    /// (`PlainLabelRing.lift`), platter included.
    func testRingAndNoZoomCellsAreUnchanged() {
        for cell in cells where cell.accent || cell.noZoom {
            XCTAssertEqual(PlainLabelRing.smallLabelLift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom),
                           PlainLabelRing.lift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom),
                           "accent=\(cell.accent) noZoom=\(cell.noZoom)")
        }
        XCTAssertEqual(PlainLabelRing.smallLabelLift(accentFocusRing: true, noZoomOnFocus: false), .manualScale)
        XCTAssertEqual(PlainLabelRing.smallLabelLift(accentFocusRing: false, noZoomOnFocus: true), .still(ringed: false))
        XCTAssertEqual(PlainLabelRing.smallLabelLift(accentFocusRing: true, noZoomOnFocus: true), .still(ringed: true))
        // Ring mode keeps the platter + shadow it always drew (`focusShadow`'s default, true).
        XCTAssertTrue(PlainLabelRing.smallLabelPlatter(accentFocusRing: true, noZoomOnFocus: false))
    }

    /// BUG-108's invariant for the new case: the cells where `cardFocusButtonStyle(lift: .manual)`
    /// installs `RingCardButtonStyle` (no system lift) are exactly the cells where the chip draws
    /// `.manualScale` for itself. Break either side and a focused chip has no lift at all, or its
    /// manual scale compounds with the system treatment.
    func testChipDrawsItsOwnLiftExactlyWhereTheButtonWearsTheCustomZoomStyle() {
        for cell in cells {
            let style = kind(.manual, accent: cell.accent, noZoom: cell.noZoom)
            let lift = PlainLabelRing.smallLabelLift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom)
            switch style {
            case .ring:
                XCTAssertEqual(lift, .manualScale, "accent=\(cell.accent) noZoom=\(cell.noZoom)")
            case .still:
                XCTAssertEqual(lift, .still(ringed: cell.accent), "accent=\(cell.accent) noZoom=\(cell.noZoom)")
            case .borderless:
                XCTFail("a .manual label never sits under .borderless: accent=\(cell.accent) noZoom=\(cell.noZoom)")
            }
            XCTAssertNotEqual(lift, .systemLift, "accent=\(cell.accent) noZoom=\(cell.noZoom)")
        }
    }

    /// The default cell scales the white capsule alone: no black platter + 22 pt shadow behind it.
    func testDefaultCellDrawsNoPlatter() {
        XCTAssertFalse(PlainLabelRing.smallLabelPlatter(accentFocusRing: false, noZoomOnFocus: false))
        // No Zoom never reaches `manualLift`; the flag is false there too, so it reads truthfully.
        XCTAssertFalse(PlainLabelRing.smallLabelPlatter(accentFocusRing: false, noZoomOnFocus: true))
        XCTAssertFalse(PlainLabelRing.smallLabelPlatter(accentFocusRing: true, noZoomOnFocus: true))
    }

    /// SwiftUI draws the chip's lift in every cell now (no system layer), so the focused chip is
    /// raised above its neighbours in each one; the default cell flipped from the system lift's
    /// implicit layer (`raisesFocusedCard == false`) to an explicit `zIndex`.
    func testFocusedChipIsRaisedInEveryCell() {
        XCTAssertFalse(CardFocusMode.resolve(accentFocusRing: false, noZoomOnFocus: false).raisesFocusedCard)
        for cell in cells {
            XCTAssertTrue(PlainLabelRing.smallLabelLift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom).raisesFocusedCard,
                          "accent=\(cell.accent) noZoom=\(cell.noZoom)")
        }
    }

    // MARK: - Geometry (BUG-111's spacing math, now for the default cell too)

    /// The default cell uses ring mode's small-label rise: ×1.12 on the 52 pt capsule, inside the
    /// sim measurement window (×1.08 … ×1.13), and the widest 212 pt chip grows 12.7 pt per side
    /// inside the 16 pt row gap.
    func testDefaultCellScaleStaysInsideTheRowGap() {
        let height = CompanyChipMetrics.capsuleHeight
        let scale = cardLiftScale(artworkHeight: height, rise: CompanyChipMetrics.focusRise)
        XCTAssertEqual(scale, PlainLabelRing.smallLabelScaleCeiling, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(scale, 1.08)
        XCTAssertLessThanOrEqual(scale, 1.13)
        let widestChip: CGFloat = 212
        let growthPerSide = widestChip * (scale - 1) / 2
        XCTAssertEqual(growthPerSide, 12.72, accuracy: 0.01)
        XCTAssertLessThan(growthPerSide, Theme.Spacing.md)
        // The rise is the scale's own top-edge travel; nothing else moves the capsule vertically.
        XCTAssertEqual(CompanyChipMetrics.focusRise, height * (scale - 1) / 2, accuracy: 0.001)
    }
}
