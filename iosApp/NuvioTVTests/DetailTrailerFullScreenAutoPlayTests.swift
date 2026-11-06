import XCTest
@testable import NuvioTV

/// A2.4 (D2): the full-screen trailer auto-play is off by default in Apple-style only, under its
/// own key; Cinematic and Classic keep `detail_trailer_autoplay` exactly as before.
@MainActor
final class DetailTrailerFullScreenAutoPlayTests: XCTestCase {
    func testAppleStyleReadsItsOwnKeyAndDefaultsOff() {
        for legacy in [true, false] {
            XCTAssertFalse(DetailTrailerFullScreenAutoPlay.isOn(layout: .appleStyle, stored: nil, legacy: legacy))
            XCTAssertTrue(DetailTrailerFullScreenAutoPlay.isOn(layout: .appleStyle, stored: true, legacy: legacy))
            XCTAssertFalse(DetailTrailerFullScreenAutoPlay.isOn(layout: .appleStyle, stored: false, legacy: legacy))
        }
        XCTAssertFalse(DetailTrailerFullScreenAutoPlay.layoutDefault(.appleStyle))
    }

    func testCinematicAndClassicKeepTheLegacyKey() {
        for layout: DetailLayout in [.cinematic, .classic] {
            for stored: Bool? in [nil, true, false] {
                XCTAssertTrue(DetailTrailerFullScreenAutoPlay.isOn(layout: layout, stored: stored, legacy: true))
                XCTAssertFalse(DetailTrailerFullScreenAutoPlay.isOn(layout: layout, stored: stored, legacy: false))
            }
            XCTAssertTrue(DetailTrailerFullScreenAutoPlay.layoutDefault(layout))
        }
    }

    /// Shipped keys cannot be renamed; `-detail_trailer_fullscreen_autoplay YES` is the launch argument.
    func testKeyLiterals() {
        XCTAssertEqual(DetailSettingsKeys.trailerFullScreenAutoPlay, "detail_trailer_fullscreen_autoplay")
        XCTAssertEqual(DetailSettingsKeys.trailerAutoplay, "detail_trailer_autoplay")
    }
}
