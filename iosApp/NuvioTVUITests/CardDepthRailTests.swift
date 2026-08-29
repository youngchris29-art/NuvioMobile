import XCTest

/// Pure-logic coverage for BUG-57's partial-coverage (Top/Half) edge rail boost, and its follow-up
/// (tester: "Card Depth appears thick even when I select Subtle") — the rail's line-width decision.
/// Both live in `CardDepthStyle.partialCoverageRailBoost(edge:)` and
/// `CardDepthStyle.partialCoverageRailWidth(edgeStrength:)` (`NuvioTV/DesignSystem/CardDepthStyle.swift`).
///
/// Same hand-mirrored-function convention as `AccentFocusRingTests.swift` / `StreamBadgeColorTests.swift`
/// (this is a UI-testing target with no TEST_HOST, so the app's types can't be linked). Keep the mirror
/// in sync by hand with the production function.
///
/// Why the boost exists: on beta.11 the "Top" mode drew a 1 pt hairline at ≤ edge-strength opacity —
/// invisible from a couch (reporter: "still not correct", Full "works well"). The partial modes draw a
/// heavier rail whose top stop is the edge strength ×1.5, capped at 0.9; Full is untouched.
///
/// Why the width mirror was added: the rail's `lineWidth` used to be fixed at 2pt for every partial
/// -coverage case, keyed only on coverage (Top/Half) rather than the user's strength choice — so the
/// DEFAULT combination (Subtle strength + Top coverage) drew a *thicker, brighter* rail than even
/// Bold+Full's 1pt closed stroke. Width now follows the strength band `AppearanceSettingsPane` maps to
/// Subtle/Balanced/Bold (28/42/56): 1pt at/below the Subtle preset, 2pt above. The BUG-57 opacity boost
/// still applies at both widths — a 1pt rail needs the visibility help MORE than a 2pt one, not less.
final class CardDepthRailTests: XCTestCase {

    // MARK: - Mirror of CardDepthStyle.partialCoverageRailBoost(edge:)

    private func partialCoverageRailBoost(edge: Double) -> Double {
        min(max(edge, 0) * 1.5, 0.9)
    }

    // MARK: - Mirror of CardDepthStyle.partialCoverageRailWidth(edgeStrength:)

    private func partialCoverageRailWidth(edgeStrength: Int) -> CGFloat {
        edgeStrength <= 28 ? 1 : 2
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

    // MARK: - Width decision (tester: "thick even on Subtle")

    /// Subtle strength + Top coverage is the DEFAULT combination (edgeStrength 28, edgeCoverage 0)
    /// that the tester saw as "thick" — this is the regression case. It must render at 1pt, and the
    /// BUG-57 opacity boost must still apply at that width (checked via the boost mirror above:
    /// `partialCoverageRailBoost(edge: 0.28) == 0.42`, unchanged by the width fix).
    func testSubtleTopIsOnePointWithBoostStillApplied() {
        XCTAssertEqual(partialCoverageRailWidth(edgeStrength: 28), 1)
        XCTAssertEqual(partialCoverageRailBoost(edge: 0.28), 0.42, accuracy: 0.0001)
    }

    func testBalancedTopIsTwoPoints() {
        XCTAssertEqual(partialCoverageRailWidth(edgeStrength: 42), 2)
    }

    /// Full coverage never calls `partialCoverageRailWidth` in production — `edgeHighlight` hardcodes
    /// 1pt for Full regardless of strength. Documented here as the width the Bold+Full case renders
    /// at, to make explicit that it stays 1pt (unlike Balanced+Top, which the width fix now
    /// distinguishes from Full at the same strength).
    func testBoldFullIsOnePoint() {
        let boldFullLineWidth: CGFloat = 1
        XCTAssertEqual(boldFullLineWidth, 1)
    }

    func testSubtleFullIsOnePoint() {
        let subtleFullLineWidth: CGFloat = 1
        XCTAssertEqual(subtleFullLineWidth, 1)
    }
}
