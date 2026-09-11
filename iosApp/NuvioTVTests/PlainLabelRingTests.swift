import XCTest
@testable import NuvioTV

/// BUG-102 (rc9, 2026-09-10): the ring verdict for labels that draw their own ring inside the
/// artwork frame (`FolderTile`, `CastCard`). The tester's report was the zoom-on + accent-ring-on
/// cell drawing nothing; every other cell must keep what it did before.
final class PlainLabelRingTests: XCTestCase {
    func testUnfocusedDrawsNothingInEveryMode() {
        for accent in [false, true] {
            for noZoom in [false, true] {
                XCTAssertNil(PlainLabelRing.resolve(accentFocusRing: accent, noZoomOnFocus: noZoom, focused: false),
                             "accent=\(accent) noZoom=\(noZoom)")
            }
        }
    }

    func testDefaultModeDrawsNothingWhenFocused() {
        XCTAssertNil(PlainLabelRing.resolve(accentFocusRing: false, noZoomOnFocus: false, focused: true))
    }

    func testZoomOnAccentRingOnDrawsAccent() {
        // The BUG-102 cell.
        XCTAssertEqual(PlainLabelRing.resolve(accentFocusRing: true, noZoomOnFocus: false, focused: true), .accent)
    }

    func testStillModeWithoutAccentDrawsNeutralStillRing() {
        XCTAssertEqual(PlainLabelRing.resolve(accentFocusRing: false, noZoomOnFocus: true, focused: true), .still)
    }

    func testStillModeWithAccentDrawsAccent() {
        // Mirrors `CardFocusMode.still(ringed: true)`: the accent ring replaces the neutral one.
        XCTAssertEqual(PlainLabelRing.resolve(accentFocusRing: true, noZoomOnFocus: true, focused: true), .accent)
    }

    func testBandReservedWheneverEitherSettingIsOn() {
        XCTAssertFalse(PlainLabelRing.reservesBand(accentFocusRing: false, noZoomOnFocus: false))
        XCTAssertTrue(PlainLabelRing.reservesBand(accentFocusRing: true, noZoomOnFocus: false))
        XCTAssertTrue(PlainLabelRing.reservesBand(accentFocusRing: false, noZoomOnFocus: true))
        XCTAssertTrue(PlainLabelRing.reservesBand(accentFocusRing: true, noZoomOnFocus: true))
    }

    /// BUG-108's invariant, and the whole reason `CardButtonStyleKind` and `PlainLabelRing.lift`
    /// are pure functions: the cell where `cardFocusButtonStyle` installs `RingCardButtonStyle`
    /// (a custom style, which can receive NO system lift) is exactly the cell where a plain label
    /// must draw `.manualScale` for itself. Break either side and the focused tile has no lift at
    /// all, or — the rc9 photo — the artwork lifts and the ring stays behind.
    func testRingModeGivesPlainLabelsTheirOwnLift() {
        for accent in [false, true] {
            for noZoom in [false, true] {
                let kind = CardButtonStyleKind.resolve(noZoomOnFocus: noZoom,
                                                      accentFocusRing: accent,
                                                      lift: .card)
                let lift = PlainLabelRing.lift(accentFocusRing: accent, noZoomOnFocus: noZoom)
                switch kind {
                case .ring:
                    XCTAssertEqual(lift, .manualScale, "accent=\(accent) noZoom=\(noZoom)")
                case .still, .borderless:
                    XCTAssertEqual(lift, .still(ringed: accent), "accent=\(accent) noZoom=\(noZoom)")
                }
            }
        }
    }

    /// `.systemLift` would hang a SECOND `.hoverEffect(.highlight)` inside the native button lift
    /// these labels still wear in the default mode — the one way to make the default render differ.
    func testPlainLabelNeverAsksForTheSystemHoverEffect() {
        for accent in [false, true] {
            for noZoom in [false, true] {
                XCTAssertNotEqual(PlainLabelRing.lift(accentFocusRing: accent, noZoomOnFocus: noZoom),
                                  .systemLift, "accent=\(accent) noZoom=\(noZoom)")
            }
        }
    }

    /// The four `TileFocusLift` tiles are NOT in scope (BUG-104): taking the native lift off them
    /// today would leave them with no focus motion at all.
    func testTileFocusLiftTilesKeepTheNativeLiftInRingMode() {
        XCTAssertEqual(CardButtonStyleKind.resolve(noZoomOnFocus: false,
                                                   accentFocusRing: true,
                                                   lift: .plain), .borderless)
    }

    /// Default mode is byte-identical for every label class — the BUG-93/BUG-108 regression gate.
    func testDefaultModeIsBareBorderlessForEveryLabelClass() {
        for lift in [CardButtonLift.card, .plain] {
            XCTAssertEqual(CardButtonStyleKind.resolve(noZoomOnFocus: false,
                                                       accentFocusRing: false,
                                                       lift: lift), .borderless)
        }
    }

    /// The only cross-file coupling: the pinned row's clip budget charges the same constant the
    /// folder tile's manual scale rises by, at every folder shape.
    func testFolderRowLiftAllowanceIsTheConstantForEveryShape() {
        let mode = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: true)
        for height in [CGFloat(330), 220, 391] { // poster, square, landscape at Medium
            XCTAssertEqual(PinnedRowTitle.focusLiftAllowance(artworkHeight: height,
                                                              captionVisible: true,
                                                              treatment: .cardTreatment,
                                                              mode: mode),
                           Theme.Size.heroPinnedRowFocusLiftAllowance)
        }
    }
}
