import XCTest
import SwiftUI
@testable import NuvioTV

/// beta.19-rc1 verdict (F, FEAT-54): the one edge-fade curve (`EdgeFadeCurve`, smootherstep) shared
/// by the row mask and the folder page's fades, and the ramp length it is measured over.
final class EdgeFadeCurveTests: XCTestCase {
    func testEndpoints() {
        XCTAssertEqual(EdgeFadeCurve.alpha(0), 0)
        XCTAssertEqual(EdgeFadeCurve.alpha(1), 1)
        XCTAssertEqual(EdgeFadeCurve.alpha(0.5), 0.5, accuracy: 1e-12)
        // Clamped outside 0…1; NaN reads as clear.
        XCTAssertEqual(EdgeFadeCurve.alpha(-1), 0)
        XCTAssertEqual(EdgeFadeCurve.alpha(2), 1)
        XCTAssertEqual(EdgeFadeCurve.alpha(.nan), 0)
    }

    func testMonotonic() {
        var previous = EdgeFadeCurve.alpha(0)
        for i in 1...100 {
            let value = EdgeFadeCurve.alpha(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(value, previous, "u=\(Double(i) / 100)")
            previous = value
        }
    }

    /// Zero slope at both ends: no knee where the ramp meets the bezel or the solid part.
    func testFlatAtBothEnds() {
        XCTAssertLessThan(EdgeFadeCurve.alpha(0.02), 0.0001)
        XCTAssertGreaterThan(EdgeFadeCurve.alpha(0.98), 0.9999)
    }

    /// The spec's pinned values (L = 250, d = distance from the bezel in points).
    func testTablePinned() {
        let length = Double(RowEdgeFade.rampLength)
        XCTAssertEqual(length, 250)
        let table: [(d: Double, alpha: Double)] = [
            (0, 0), (50, 0.058), (100, 0.317), (125, 0.500), (140, 0.611),
            (186, 0.890), (201, 0.945), (221, 0.987), (250, 1),
        ]
        for row in table {
            XCTAssertEqual(EdgeFadeCurve.alpha(row.d / length), row.alpha, accuracy: 0.001, "d=\(row.d)")
        }
    }

    /// The focused card's outer edge rests ≈ 201–221 pt from the bezel (portrait) and ≥ 186 pt
    /// (landscape): it must be essentially untouched.
    func testFocusedCardIsBarelyTouched() {
        let length = Double(RowEdgeFade.rampLength)
        XCTAssertGreaterThanOrEqual(EdgeFadeCurve.alpha(201 / length), 0.94)
        XCTAssertGreaterThanOrEqual(EdgeFadeCurve.alpha(186 / length), 0.88)
    }

    func testNineStops() {
        for rising in [true, false] {
            let stops = EdgeFadeCurve.stops(rising: rising)
            XCTAssertEqual(stops.count, 9)
            XCTAssertEqual(stops.count, EdgeFadeCurve.stopCount)
            for (index, stop) in stops.enumerated() {
                XCTAssertEqual(Double(stop.location), Double(index) * 0.125, accuracy: 1e-9, "rising=\(rising) index=\(index)")
            }
        }
    }
}
