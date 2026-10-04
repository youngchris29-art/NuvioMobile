import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (R1, BUG-132): which colour the morphed inline-trailer tile's focus ring wears.
/// Steven's 72 Heures / Elize frames: with "Focus Ring Takes Poster Color" on, the pink or gold ring
/// turned white the moment the trailer tile replaced the poster card, because the tile read neither
/// the setting nor `ArtworkColorStore`. The table mirrors `PosterCard`'s rule: the accent ring takes
/// precedence over No Zoom's still ring, and the poster colour replaces whichever ring can draw.
final class InlineTrailerTileTintTests: XCTestCase {

    /// Spelled out: a bare `.none` can resolve to `Optional.none` inside `XCTAssertEqual`'s generics.
    private let noRing = InlineTrailerTileTint.RingSource.none

    private func ring(setting: Bool = false, accent: Bool = false, noZoom: Bool = false,
                      focused: Bool = true, color: Bool = false) -> InlineTrailerTileTint.RingSource {
        InlineTrailerTileTint.ringSource(settingOn: setting, accentRing: accent, noZoom: noZoom,
                                         focused: focused, hasPosterColor: color)
    }

    func testSettingOffKeepsTheAccentRing() {
        // Even when the store has a colour for the art, the setting off draws what the tile always drew.
        XCTAssertEqual(ring(setting: false, accent: true, color: false), .accent)
        XCTAssertEqual(ring(setting: false, accent: true, color: true), .accent)
    }

    func testSettingOnAccentRingWithColorWearsThePosterColor() {
        XCTAssertEqual(ring(setting: true, accent: true, color: true), .poster)
    }

    func testSettingOnAccentRingWithGreyArtKeepsAccent() {
        // test87 skips on this: grey art has no colour, and the ring legitimately stays the accent colour.
        XCTAssertEqual(ring(setting: true, accent: true, color: false), .accent)
    }

    func testNoZoomRingWithoutColorIsTheStillRing() {
        XCTAssertEqual(ring(setting: true, noZoom: true, color: false), .still)
        XCTAssertEqual(ring(setting: false, noZoom: true, color: true), .still)
    }

    func testNoZoomRingWithColorWearsThePosterColor() {
        XCTAssertEqual(ring(setting: true, noZoom: true, color: true), .poster)
    }

    func testAccentRingTakesPrecedenceOverNoZoom() {
        XCTAssertEqual(ring(setting: false, accent: true, noZoom: true), .accent)
        XCTAssertEqual(ring(setting: true, accent: true, noZoom: true, color: true), .poster)
    }

    func testRingOffAndZoomOnDrawsNoRing() {
        // The default look: the focused card lifts and nothing is stroked, whatever the setting says.
        XCTAssertEqual(ring(setting: true, color: true), noRing)
        XCTAssertEqual(ring(setting: false, color: false), noRing)
    }

    func testUnfocusedDrawsNoRing() {
        XCTAssertEqual(ring(setting: true, accent: true, focused: false, color: true), noRing)
        XCTAssertEqual(ring(setting: false, noZoom: true, focused: false), noRing)
    }

    func testRawValuesAreTheProbeSpelling() {
        // `debug_trailerTile ring=<…>` reads these (test87).
        XCTAssertEqual(InlineTrailerTileTint.RingSource.poster.rawValue, "poster")
        XCTAssertEqual(InlineTrailerTileTint.RingSource.accent.rawValue, "accent")
        XCTAssertEqual(InlineTrailerTileTint.RingSource.still.rawValue, "still")
        XCTAssertEqual(noRing.rawValue, "none")
    }
}
