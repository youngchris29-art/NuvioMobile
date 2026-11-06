import XCTest
@testable import NuvioTV

/// Batch M Wave 1 (FEAT-82, Steven rc9): the Detail action buttons follow Poster › Corners —
/// square only at Square (radius 0); Rounded (12) and Round (28) keep the capsule.
final class DetailActionShapeTests: XCTestCase {
    func testOnlySquareCornersSquareTheButtons() {
        XCTAssertTrue(DetailActionShape.isSquare(cornerRadius: 0))
        XCTAssertFalse(DetailActionShape.isSquare(cornerRadius: 12))
        XCTAssertFalse(DetailActionShape.isSquare(cornerRadius: 28))
    }

    /// The default poster style (no synced setting yet) keeps the capsule.
    func testDefaultStyleKeepsTheCapsule() {
        XCTAssertFalse(DetailActionShape.isSquare(cornerRadius: PosterStyle.default.cornerRadius))
    }
}

/// Batch P (FEAT-82 equal squares): the side is Play's measured button height, and only square,
/// icon-only buttons with a measured side take it.
final class DetailActionSquareTests: XCTestCase {
    func testSquareSideNeedsAMeasuredPlay() {
        XCTAssertNil(DetailActionSquare.side(playHeight: 0))
        XCTAssertNil(DetailActionSquare.side(playHeight: 1))
        XCTAssertEqual(DetailActionSquare.side(playHeight: 72.4), 72)
        XCTAssertEqual(DetailActionSquare.side(playHeight: 72.6), 73)
    }

    func testMatchedLabelHeightOnlyForRoundedCorners() {
        XCTAssertEqual(DetailActionSquare.matchedLabelHeight(isSquare: false, tallestSecondaryLabel: 56), 56)
        XCTAssertNil(DetailActionSquare.matchedLabelHeight(isSquare: true, tallestSecondaryLabel: 56), "Square keeps its own sizing")
        XCTAssertNil(DetailActionSquare.matchedLabelHeight(isSquare: false, tallestSecondaryLabel: 0), "nothing measured yet")
        XCTAssertNil(DetailActionSquare.matchedLabelHeight(isSquare: false, tallestSecondaryLabel: 1))
    }

    func testOnlySquareIconButtonsApply() {
        XCTAssertTrue(DetailActionSquare.applies(isSquare: true, iconOnly: true, side: 72))
        XCTAssertFalse(DetailActionSquare.applies(isSquare: false, iconOnly: true, side: 72), "Rounded / Round keep capsules")
        XCTAssertFalse(DetailActionSquare.applies(isSquare: true, iconOnly: false, side: 72), "text labels keep their width")
        XCTAssertFalse(DetailActionSquare.applies(isSquare: true, iconOnly: true, side: nil), "no square before Play is measured")
    }

    /// Wave 3 UI leg (2026-10-22): the style's insets are not equal (FA87 sim: Play's padded label
    /// 314.5 × 42 in a 374.5 × 72 button), so the label is cut narrower than it is tall and the
    /// label plus insets comes out `side × side`.
    func testLabelSizeTakesTheStyleInsetsOffTheSide() throws {
        let label = DetailActionSquare.whole(CGSize(width: 314.5, height: 42))
        let button = DetailActionSquare.whole(CGSize(width: 374.5, height: 72))
        let side = try XCTUnwrap(DetailActionSquare.side(playHeight: button.height))
        let size = try XCTUnwrap(DetailActionSquare.labelSize(side: side, playLabel: label, playButton: button))
        XCTAssertEqual(size, CGSize(width: 12, height: 42))
        XCTAssertEqual(size.width + (button.width - label.width), side, "button width == side")
        XCTAssertEqual(size.height + (button.height - label.height), side, "button height == side")
    }

    func testLabelSizeNeedsBothMeasurements() {
        XCTAssertNil(DetailActionSquare.labelSize(side: 72, playLabel: .zero, playButton: CGSize(width: 375, height: 72)))
        XCTAssertNil(DetailActionSquare.labelSize(side: 72, playLabel: CGSize(width: 315, height: 42), playButton: .zero))
        XCTAssertEqual(DetailActionSquare.labelSize(side: 20, playLabel: CGSize(width: 100, height: 42),
                                                    playButton: CGSize(width: 160, height: 72)),
                       CGSize(width: 1, height: 1), "never a negative frame")
    }

    /// Rounded (12) and Round (28) never reach the square path.
    func testRoundedAndRoundNeverSquare() {
        for radius: CGFloat in [12, 28] {
            XCTAssertFalse(DetailActionSquare.applies(isSquare: DetailActionShape.isSquare(cornerRadius: radius),
                                                      iconOnly: true, side: 72))
        }
    }
}
