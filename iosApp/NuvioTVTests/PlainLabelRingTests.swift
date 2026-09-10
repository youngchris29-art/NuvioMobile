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
}
