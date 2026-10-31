import XCTest
import SharedCore
@testable import NuvioTV

/// BUG-216 (GitHub #9 item 1, the Home collection half): in the default cell (Accent Focus Ring
/// off, zoom on) a Home folder tile lifts as one tile, cover and caption together. It used to
/// resolve through `PlainLabelRing.lift`, which answered the no-op `.still` there and left the
/// `.borderless` button's image-only lift. The system lift was measured on the sim and does NOT
/// hold the pinned row's 20 pt clip allowance (poster 23.5 pt, square 22.3 pt, landscape 13.5 pt),
/// so the tile takes the `CompanyChip` route: `FolderLabelLift` answers `.manualScale` in both
/// zoom-on cells, read with `cardFocusButtonStyle(lift: FolderTile.buttonLift)`. Ring and No Zoom
/// cells must stay exactly what they were.
@MainActor
final class FolderLabelLiftTests: XCTestCase {
    private let cells: [(accent: Bool, noZoom: Bool)] = [(false, false), (true, false), (false, true), (true, true)]

    private func kind(_ lift: CardButtonLift, accent: Bool, noZoom: Bool) -> CardButtonStyleKind {
        CardButtonStyleKind.resolve(noZoomOnFocus: noZoom, accentFocusRing: accent, lift: lift)
    }

    // MARK: - The four cells

    /// The new default cell: the tile's own manual scale (before BUG-216 the no-op `.still`).
    func testDefaultCellIsTheManualLift() {
        XCTAssertEqual(FolderLabelLift.lift(accentFocusRing: false, noZoomOnFocus: false), .manualScale)
        XCTAssertEqual(PlainLabelRing.lift(accentFocusRing: false, noZoomOnFocus: false), .still(ringed: false))
    }

    func testRingCellIsTheManualLift() {
        XCTAssertEqual(FolderLabelLift.lift(accentFocusRing: true, noZoomOnFocus: false), .manualScale)
    }

    func testNoZoomCellsStayStill() {
        XCTAssertEqual(FolderLabelLift.lift(accentFocusRing: false, noZoomOnFocus: true), .still(ringed: false))
        XCTAssertEqual(FolderLabelLift.lift(accentFocusRing: true, noZoomOnFocus: true), .still(ringed: true))
    }

    /// Ring on and both No Zoom cells: byte-identical to the pre-BUG-216 resolver.
    func testRingAndNoZoomCellsAreUnchanged() {
        for cell in cells where cell.accent || cell.noZoom {
            XCTAssertEqual(FolderLabelLift.lift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom),
                           PlainLabelRing.lift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom),
                           "accent=\(cell.accent) noZoom=\(cell.noZoom)")
        }
    }

    /// The system lift overshot the clip allowance on posters and squares, so no cell answers it.
    func testNoCellAnswersTheSystemLift() {
        for cell in cells {
            XCTAssertNotEqual(FolderLabelLift.lift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom),
                              .systemLift, "accent=\(cell.accent) noZoom=\(cell.noZoom)")
        }
    }

    // MARK: - The button style relation (BUG-108's invariant)

    /// The row's link wears `.manual` (`FolderTile.buttonLift`, the value the call site reads), and
    /// the cells where that installs `RingCardButtonStyle` (no system lift) are exactly the cells
    /// where the tile draws `.manualScale` for itself; the still style goes with `.still`. Break
    /// either side and a focused tile has no lift at all, or its manual scale compounds with the
    /// system treatment.
    func testTileDrawsItsOwnLiftExactlyWhereTheButtonWearsTheCustomStyle() {
        XCTAssertEqual(FolderTile.buttonLift, .manual)
        for cell in cells {
            let style = kind(FolderTile.buttonLift, accent: cell.accent, noZoom: cell.noZoom)
            let lift = FolderLabelLift.lift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom)
            switch style {
            case .ring:
                XCTAssertEqual(lift, .manualScale, "accent=\(cell.accent) noZoom=\(cell.noZoom)")
            case .still:
                XCTAssertEqual(lift, .still(ringed: cell.accent), "accent=\(cell.accent) noZoom=\(cell.noZoom)")
            case .borderless:
                XCTFail("a folder tile never sits under .borderless: accent=\(cell.accent) noZoom=\(cell.noZoom)")
            }
        }
    }

    /// One rule for every `.manual` label: `FolderLabelLift` and `CompanyChip`'s `smallLabelLift`
    /// both forward to `PlainLabelRing.manualLabelLift`, in every cell.
    func testSharesTheManualLabelRuleWithTheChip() {
        for cell in cells {
            let shared = PlainLabelRing.manualLabelLift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom)
            XCTAssertEqual(FolderLabelLift.lift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom), shared)
            XCTAssertEqual(PlainLabelRing.smallLabelLift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom), shared)
        }
    }

    /// SwiftUI draws the tile's lift in every zoom-on cell now (no system layer), so the row must
    /// raise the focused tile above its neighbours itself (`CollectionRowView.liftedTileZIndex`
    /// reads this); the default cell flipped from the system lift's implicit layer to an explicit
    /// `zIndex`.
    func testFocusedTileIsRaisedInEveryCell() {
        XCTAssertFalse(CardFocusMode.resolve(accentFocusRing: false, noZoomOnFocus: false).raisesFocusedCard)
        for cell in cells {
            XCTAssertTrue(FolderLabelLift.lift(accentFocusRing: cell.accent, noZoomOnFocus: cell.noZoom).raisesFocusedCard,
                          "accent=\(cell.accent) noZoom=\(cell.noZoom)")
        }
    }

    // MARK: - Geometry against the pinned row's budget

    private func folder(_ shape: String) -> CollectionFolder {
        CollectionFolder(id: "f", title: "Folder", coverImageUrl: nil, focusGifUrl: nil,
                         focusGifEnabled: true, mobileFocusGifEnabled: true, coverEmoji: nil,
                         tileShape: shape, hideTitle: false, sources: [], catalogSources: [],
                         heroBackdropUrl: nil, heroVideoUrl: nil, titleLogoUrl: nil)
    }

    /// Small / Medium / Large poster widths (poster height = width x 1.5: 274.5 / 330 / 403.3).
    private let posterWidths: [CGFloat] = [183, 220, 268.9]

    /// The default cell rises by exactly the clip allowance the pinned row reserves, for every tile
    /// shape at every Poster Size, through the tile's own `artworkHeight(for:style:)` and the card
    /// scale (`cardLiftScale`): the top edge travels `rise`, whatever the height.
    func testDefaultCellRiseIsTheClipAllowanceOnEveryTileShapeAndSize() {
        let allowance = PinnedRowTitle.focusLiftAllowance(artworkHeight: nil, captionVisible: true,
                                                          treatment: .cardTreatment,
                                                          mode: .init(noZoom: false, accentRing: false))
        XCTAssertEqual(allowance, Theme.Size.heroPinnedRowFocusLiftAllowance)
        XCTAssertEqual(allowance, 20)
        for width in posterWidths {
            var style = PosterStyle()
            style.width = width
            style.height = width * 1.5
            for shape in ["poster", "landscape", "square"] {
                let height = FolderTile.artworkHeight(for: folder(shape), style: style)
                let scale = cardLiftScale(artworkHeight: height)
                XCTAssertEqual(height * (scale - 1) / 2, allowance, accuracy: 0.001, "\(shape) at width \(width)")
            }
        }
        // No Zoom: nothing rises, nothing is charged.
        XCTAssertEqual(PinnedRowTitle.focusLiftAllowance(artworkHeight: nil, captionVisible: true,
                                                         treatment: .cardTreatment,
                                                         mode: .init(noZoom: true, accentRing: false)), 0)
    }

    /// A landscape tile (16:9, `width` tall) grows the most sideways, ~35.6 pt per side at any
    /// Poster Size; the row's 40 pt `landscapeLiftRowGap` (applied whenever the row holds a landscape
    /// folder, regardless of the ring setting) clears it, and the other shapes clear `rowGap` (28).
    func testTileGrowthStaysInsideTheRowGap() {
        for width in posterWidths {
            var style = PosterStyle()
            style.width = width
            style.height = width * 1.5
            for shape in ["poster", "landscape", "square"] {
                let tile = folder(shape)
                let height = FolderTile.artworkHeight(for: tile, style: style)
                let tileWidth = tile.posterShape == PosterShape.landscape ? style.width * 16 / 9 : style.width
                let growthPerSide = tileWidth * (cardLiftScale(artworkHeight: height) - 1) / 2
                let gap = tile.posterShape == PosterShape.landscape
                    ? Theme.Spacing.landscapeLiftRowGap : Theme.Spacing.rowGap
                XCTAssertLessThan(growthPerSide, gap, "\(shape) at width \(width)")
            }
        }
    }
}
