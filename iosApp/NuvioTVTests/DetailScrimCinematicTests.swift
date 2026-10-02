import XCTest
@testable import NuvioTV

/// FEAT-35 (Detail revamp, Cinematic): pins the Cinematic scrim stops and enforces the plan's
/// "Steven's BUG-127 stops are the ceiling" rule point by point. The classic stops stay pinned by
/// `DetailScrimTests`, unchanged.
final class DetailScrimCinematicTests: XCTestCase {

    func testCinematicStops() {
        XCTAssertEqual(DetailScrim.cinematicHorizontalLeading, 0.55, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicHorizontalMid, 0.15, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicHorizontalTrailing, 0.00, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicHorizontalTrailingOverPoster, 0.10, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicVerticalClearUntil, 0.60, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicVerticalBottom, 0.60, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicRadialOpacity, 0.55, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicRadialEndRadiusFraction, 0.70, accuracy: 1e-9)
    }

    /// The ceiling: the Cinematic composite is never darker than Classic's anywhere on an 11 × 11
    /// grid, with and without the poster layer. If this fails, lower `cinematicRadialOpacity` in
    /// 0.05 steps; never raise any value.
    func testCinematicNeverDarkerThanClassic() {
        for overPoster in [false, true] {
            for i in 0...10 {
                for j in 0...10 {
                    let x = Double(i) / 10
                    let y = Double(j) / 10
                    let classic = DetailScrim.classicCompositeAlpha(x: x, y: y, overPoster: overPoster)
                    let cinematic = DetailScrim.cinematicCompositeAlpha(x: x, y: y, overPoster: overPoster)
                    XCTAssertLessThanOrEqual(cinematic, classic + 1e-9,
                                             "x=\(x) y=\(y) overPoster=\(overPoster)")
                }
            }
        }
    }

    /// Spot values of the composite math, so a change to the helpers is caught even when the
    /// ceiling still holds.
    func testCompositeSpotValues() {
        // Top-left: classic is the horizontal leading stop alone (the vertical is still clear).
        XCTAssertEqual(DetailScrim.classicCompositeAlpha(x: 0, y: 0, overPoster: false), 0.80, accuracy: 1e-9)
        // Bottom-left: 1 − (1 − 0.80)(1 − 0.70).
        XCTAssertEqual(DetailScrim.classicCompositeAlpha(x: 0, y: 1, overPoster: false), 0.94, accuracy: 1e-9)
        // Cinematic bottom-left adds the full radial: 1 − 0.45 × 0.40 × 0.45.
        XCTAssertEqual(DetailScrim.cinematicCompositeAlpha(x: 0, y: 1, overPoster: false), 0.919, accuracy: 1e-9)
        // Top-right of the cinematic scrim, no poster: the radial is out of reach and both gradients
        // are clear there.
        XCTAssertEqual(DetailScrim.cinematicCompositeAlpha(x: 1, y: 0, overPoster: false), 0, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicCompositeAlpha(x: 1, y: 0, overPoster: true), 0.10, accuracy: 1e-9)
    }
}
