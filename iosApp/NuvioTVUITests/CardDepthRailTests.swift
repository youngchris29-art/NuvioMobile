import XCTest

/// Pure-logic coverage for BUG-57 — the partial-coverage (Top/Half) edge rail boost in
/// `CardDepthStyle.partialCoverageRailBoost(edge:)` (`NuvioTV/DesignSystem/CardDepthStyle.swift`).
///
/// Same hand-mirrored-function convention as `AccentFocusRingTests.swift` / `StreamBadgeColorTests.swift`
/// (this is a UI-testing target with no TEST_HOST, so the app's types can't be linked). Keep the mirror
/// in sync by hand with the production function.
///
/// Why it exists: on beta.11 the "Top" mode drew a 1 pt hairline at ≤ edge-strength opacity — invisible
/// from a couch (reporter: "still not correct", Full "works well"). The partial modes now draw a 2 pt
/// rail whose top stop is the edge strength ×1.5, capped at 0.9; Full is untouched.
final class CardDepthRailTests: XCTestCase {

    // MARK: - Mirror of CardDepthStyle.partialCoverageRailBoost(edge:)

    private func partialCoverageRailBoost(edge: Double) -> Double {
        min(max(edge, 0) * 1.5, 0.9)
    }

    func testSubtleEdgeIsLifted() {
        XCTAssertEqual(partialCoverageRailBoost(edge: 0.28), 0.42, accuracy: 0.0001)
    }

    func testBalancedEdgeIsLifted() {
        XCTAssertEqual(partialCoverageRailBoost(edge: 0.42), 0.63, accuracy: 0.0001)
    }

    func testBoldEdgeIsLiftedAndBelowCap() {
        XCTAssertEqual(partialCoverageRailBoost(edge: 0.56), 0.84, accuracy: 0.0001)
    }

    func testCapHoldsForMaxStrength() {
        XCTAssertEqual(partialCoverageRailBoost(edge: 1.0), 0.9, accuracy: 0.0001)
    }

    func testZeroAndNegativeStayZero() {
        XCTAssertEqual(partialCoverageRailBoost(edge: 0), 0)
        XCTAssertEqual(partialCoverageRailBoost(edge: -0.3), 0)
    }

    func testBoostNeverBelowInput() {
        for e in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertGreaterThanOrEqual(partialCoverageRailBoost(edge: e), min(e, 0.9) - 1e-9, "edge \(e)")
        }
    }
}
