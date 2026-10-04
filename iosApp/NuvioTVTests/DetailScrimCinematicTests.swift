import XCTest
@testable import NuvioTV

/// FEAT-35 (Detail revamp, Cinematic): pins the Cinematic scrim stops and enforces the plan's
/// "Steven's BUG-127 stops are the ceiling" rule point by point. The classic stops stay pinned by
/// `DetailScrimTests`, unchanged.
///
/// beta.19-rc1 verdict (D3, BUG-127): the Cinematic stops were lightened again after Steven's Oak
/// Street and Monstre photos (the art still read darkened). The tests below pin the new stops, keep
/// the Classic ceiling, and add three guards: the new scrim is lighter than build 284fd764's
/// everywhere (old stops kept here as literals), the text block keeps a floor of darkness so the
/// synopsis and meta stay legible, and the art region stays mostly clear.
final class DetailScrimCinematicTests: XCTestCase {

    func testCinematicStops() {
        XCTAssertEqual(DetailScrim.cinematicHorizontalLeading, 0.30, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicHorizontalMid, 0.06, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicHorizontalTrailing, 0.00, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicHorizontalTrailingOverPoster, 0.06, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicVerticalClearUntil, 0.60, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicVerticalBottom, 0.55, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicRadialOpacity, 0.50, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicRadialEndRadiusFraction, 0.62, accuracy: 1e-9)
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
        // Cinematic bottom-left adds the full radial: 1 − (1 − 0.30)(1 − 0.55)(1 − 0.50) = 0.8425.
        XCTAssertEqual(DetailScrim.cinematicCompositeAlpha(x: 0, y: 1, overPoster: false), 0.8425, accuracy: 1e-9)
        // Top-right of the cinematic scrim, no poster: the radial is out of reach and both gradients
        // are clear there. With the poster layer the over-poster trailing stop alone shows.
        XCTAssertEqual(DetailScrim.cinematicCompositeAlpha(x: 1, y: 0, overPoster: false), 0, accuracy: 1e-9)
        XCTAssertEqual(DetailScrim.cinematicCompositeAlpha(x: 1, y: 0, overPoster: true), 0.06, accuracy: 1e-9)
        // Top-left: the horizontal leading stop plus a sliver of the radial (distance 1080 of 1190.4):
        // 1 − 0.70 × (1 − 0.50 × (1 − 1080 / 1190.4)) = 0.3325.
        XCTAssertEqual(DetailScrim.cinematicCompositeAlpha(x: 0, y: 0, overPoster: false), 0.3325, accuracy: 1e-3)
    }

    /// The beta.18 / build 284fd764 Cinematic stops, as literals: the D3 change must be lighter than
    /// these at every point, with and without the poster layer. (A 21 × 21 grid, finer than the
    /// ceiling test above.)
    func testLighterThanBuild284Everywhere() {
        let old = (leading: 0.55, mid: 0.15, trailing: 0.00, trailingOverPoster: 0.10,
                   clearUntil: 0.60, bottom: 0.60, radial: 0.55, radius: 0.70)
        func oldComposite(x: Double, y: Double, overPoster: Bool) -> Double {
            let t = min(max(x, 0), 1)
            let end = overPoster ? old.trailingOverPoster : old.trailing
            let horizontal = t <= 0.5
                ? old.leading + (old.mid - old.leading) * (t / 0.5)
                : old.mid + (end - old.mid) * ((t - 0.5) / 0.5)
            let ty = min(max(y, 0), 1)
            let vertical = ty > old.clearUntil ? old.bottom * (ty - old.clearUntil) / (1 - old.clearUntil) : 0
            let dx = x * DetailScrim.compositeAspectWidth
            let dy = (1 - y) * DetailScrim.compositeAspectHeight
            let distance = (dx * dx + dy * dy).squareRoot()
            let radial = old.radial * max(0, 1 - distance / (old.radius * DetailScrim.compositeAspectWidth))
            return 1 - (1 - horizontal) * (1 - vertical) * (1 - radial)
        }
        // The old literals really are build 284's: its bottom-left composite was 0.919.
        XCTAssertEqual(oldComposite(x: 0, y: 1, overPoster: false), 0.919, accuracy: 1e-9)
        for overPoster in [false, true] {
            for i in 0...20 {
                for j in 0...20 {
                    let x = Double(i) / 20
                    let y = Double(j) / 20
                    let now = DetailScrim.cinematicCompositeAlpha(x: x, y: y, overPoster: overPoster)
                    XCTAssertLessThanOrEqual(now, oldComposite(x: x, y: y, overPoster: overPoster) + 1e-9,
                                             "x=\(x) y=\(y) overPoster=\(overPoster)")
                }
            }
        }
    }

    /// Mean and minimum composite darkness over `region` on a 21 × 21 grid.
    private func stats(x: ClosedRange<Double>, y: ClosedRange<Double>, overPoster: Bool) -> (mean: Double, min: Double) {
        var sum = 0.0
        var lowest = 1.0
        for i in 0...20 {
            for j in 0...20 {
                let px = x.lowerBound + (x.upperBound - x.lowerBound) * Double(i) / 20
                let py = y.lowerBound + (y.upperBound - y.lowerBound) * Double(j) / 20
                let value = DetailScrim.cinematicCompositeAlpha(x: px, y: py, overPoster: overPoster)
                sum += value
                lowest = min(lowest, value)
            }
        }
        return (sum / 441, lowest)
    }

    /// The synopsis/meta block (x 0.03–0.30, y 0.55–0.75) keeps enough darkness under it to stay
    /// legible: mean 0.485 and minimum 0.311 with the D3 stops (0.646 / 0.477 before). If a future
    /// lightening trips this, the text needs its own panel first.
    func testTextBlockFloor() {
        let block = stats(x: 0.03...0.30, y: 0.55...0.75, overPoster: false)
        XCTAssertGreaterThanOrEqual(block.mean, 0.45, "the text block's mean darkness fell below the legibility floor")
        XCTAssertGreaterThanOrEqual(block.min, 0.30, "a point under the text block fell below the legibility floor")
    }

    /// The art region (x 0.5–1, y 0–0.6, no poster layer) stays mostly clear: mean 0.031 (0.081
    /// before).
    func testArtRegionMostlyClear() {
        let art = stats(x: 0.5...1.0, y: 0.0...0.6, overPoster: false)
        XCTAssertLessThanOrEqual(art.mean, 0.04, "the art region is darker than the D3 target")
    }
}
