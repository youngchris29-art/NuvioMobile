import XCTest
@testable import NuvioTV

/// beta.18 verdict (BUG-127): pins the lighter Detail scrim stops and the synopsis-panel constants.
final class DetailScrimTests: XCTestCase {

    func testScrimStops() {
        XCTAssertEqual(DetailScrim.horizontalLeading, 0.80, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.horizontalMid, 0.30, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.horizontalTrailing, 0.18, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.horizontalTrailingOverPoster, 0.26, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.verticalClearUntil, 0.60, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.verticalBottom, 0.70, accuracy: 1e-9)
    }

    func testPanelConstants() {
        XCTAssertEqual(DetailScrim.panelWidth, 560)
        XCTAssertEqual(DetailScrim.panelCornerRadius, 24)
        XCTAssertEqual(DetailScrim.panelMaxLines, 18) // review r1 (P3-6)
        XCTAssertEqual(DetailScrim.panelGlassTint, 0.30, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.panelFlatFill, 0.55, accuracy: 1e-9)
    }

    /// All 4 combinations: flat when either input is true, and always exactly what the chips do.
    ///
    /// beta.19-rc1 verdict (D2, BUG-140): scrolling is not an input — the synopsis panel stays glass
    /// while the page scrolls, like the chips (it used to flatten with them, 8 rows).
    func testPanelFlatTruthTable() {
        for trailer in [false, true] {
            for glassOff in [false, true] {
                let expected = trailer || glassOff
                XCTAssertEqual(
                    DetailScrim.panelUsesFlatFill(trailerActive: trailer, glassDisabled: glassOff),
                    expected, "trailer=\(trailer) glassDisabled=\(glassOff)")
                XCTAssertEqual(
                    DetailScrim.panelUsesFlatFill(trailerActive: trailer, glassDisabled: glassOff),
                    DetailView.chipGlassFlat(trailerActive: trailer, glassDisabled: glassOff),
                    "panel and chips must follow one rule: trailer=\(trailer) glassDisabled=\(glassOff)")
            }
        }
    }
}
