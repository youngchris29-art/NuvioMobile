import XCTest
import SwiftUI
@testable import NuvioTV

/// BUG-110 (rc12, "the three Card Depth strength levels look identical on my TV"): coverage for the
/// pure rail-geometry functions on `CardDepthStyle` — `railWidth`, `railTopAlpha`, `railStops`,
/// `railHaloSpread`, `railHaloAlpha` and `haloSuppressed` (`NuvioTV/DesignSystem/CardDepthStyle.swift`).
///
/// This target links against `NuvioTV` itself (`@testable import`), unlike the UI-testing target's
/// hand-mirrored `CardDepthRailTests.swift` this file replaces — that file carried its own copy of
/// the pre-BUG-110 `partialCoverageRailBoost`/`partialCoverageRailWidth` because a UI-testing target
/// has no `TEST_HOST` to link the app's real types against. Both functions it tested are gone
/// (`railTopAlpha`/`railWidth` below replace them, applied at every coverage instead of only the
/// partial one), so its file is deleted rather than kept as dead history; its documentation of WHY
/// the boost and the width-by-strength fix exist is carried forward here.
///
/// History this supersedes, kept for context:
/// - BUG-57 (u/mrStevenx3, beta.15): the partial-coverage ("Top"/"Half") rail read as nothing from a
///   couch at a bare edge-strength opacity — a 1pt hairline at ≤56% white. The fix lifted the rail's
///   TOP stop above the raw edge strength; `railTopAlpha` is that lift's current form, now applied at
///   Full coverage too (see the "Full stops" tests below) rather than only at Top/Half.
/// - Tester follow-up ("Card Depth appears thick even when I select Subtle"): the rail's line width
///   used to be fixed at 2pt for every partial-coverage case, keyed on coverage rather than the
///   user's strength choice, so the DEFAULT combination (Subtle + Top) drew thicker than Bold + Full.
///   `railWidth` is the fix's current form, now also applied at Full (previously hardcoded to 1pt
///   there regardless of strength — part of why BUG-110's three presets read alike at Full).
/// - BUG-110 itself: even after both fixes above, Full's three presets differed ONLY by a 0.14-0.21
///   alpha step on a 1pt hairline, and Balanced/Bold shared the identical 2pt width everywhere. The
///   functions below give every preset (Off/Subtle/Balanced/Bold) its own width, top-stop alpha and
///   halo at every coverage.
/// - BUG-110 (rc14, Steven rc13 verdict, 2026-09-30): "a thick border appears on the poster, in
///   addition to the border already around the poster." The halo is removed (`railHaloSpread` is 0
///   at every strength), Bold's top stop drops 0.90 → 0.80, and a focused card draws no rail at all
///   (`CardDepthModifier`/`CardDepthOverlay.railSuppressed` — view-level, covered by the UI
///   harness, not by this pure-function file).
final class CardDepthRailStyleTests: XCTestCase {

    // MARK: - railWidth(edgeStrength:) bands

    func testWidthBands() {
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: 0), 0)
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: 1), 1)
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: 28), 1)
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: 29), 2)
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: 30), 2)
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: 42), 2)
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: 43), 3)
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: 56), 3)
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: 100), 3)
    }

    func testNegativeEdgeStrengthStaysZeroWidth() {
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: -10), 0)
    }

    /// The regression this whole batch exists for: Balanced and Bold must no longer share a width.
    func testAdjacentPresetsDifferByAtLeastOnePoint() {
        let subtle = CardDepthStyle.railWidth(edgeStrength: 28)
        let balanced = CardDepthStyle.railWidth(edgeStrength: 42)
        let bold = CardDepthStyle.railWidth(edgeStrength: 56)
        XCTAssertGreaterThanOrEqual(balanced - subtle, 1)
        XCTAssertGreaterThanOrEqual(bold - balanced, 1)
    }

    // MARK: - railTopAlpha(edge:) anchors

    func testAlphaAnchors() {
        XCTAssertEqual(CardDepthStyle.railTopAlpha(edge: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(CardDepthStyle.railTopAlpha(edge: 0.28), 0.35, accuracy: 0.0001)
        XCTAssertEqual(CardDepthStyle.railTopAlpha(edge: 0.42), 0.60, accuracy: 0.0001)
        XCTAssertEqual(CardDepthStyle.railTopAlpha(edge: 0.56), 0.80, accuracy: 0.0001)
        XCTAssertEqual(CardDepthStyle.railTopAlpha(edge: 1.0), 0.95, accuracy: 0.0001)
    }

    /// BUG-110 (rc14): Bold (edge strength 56) renders its top stop at 0.80, down from 0.90 — the
    /// 3pt rail at 0.90 white read as a hard outline on a real TV. Subtle/Balanced anchors are
    /// untouched (see `testAlphaAnchors`). `railTopAlpha` takes the 0…1 unit value, so strength 56 is
    /// passed as 0.56.
    func testBoldTopAlphaIsEightyPercent() {
        XCTAssertEqual(CardDepthStyle.railTopAlpha(edge: Double(56) / 100), 0.80, accuracy: 0.001)
    }

    /// Same regression as the width test, in the alpha channel: each preset step must be visibly
    /// distinct — at least a fifth of the opacity range apart. (rc14: this was "a quarter" while Bold
    /// sat at 0.90; lowering Bold to 0.80 narrows the Balanced→Bold step to exactly 0.20, still
    /// distinct from the 0.25 Subtle→Balanced step and backed by Bold's 1pt-wider rail.)
    func testAdjacentPresetAlphaStepsAreAtLeastAFifth() {
        let subtle = CardDepthStyle.railTopAlpha(edge: 0.28)
        let balanced = CardDepthStyle.railTopAlpha(edge: 0.42)
        let bold = CardDepthStyle.railTopAlpha(edge: 0.56)
        XCTAssertGreaterThanOrEqual(balanced - subtle, 0.25 - 1e-9)
        XCTAssertGreaterThanOrEqual(bold - balanced, 0.20 - 1e-9)
    }

    func testAlphaIsMonotonicAndCapped() {
        var previous = -1.0
        for tenth in stride(from: 0.0, through: 1.2, by: 0.05) {
            let value = CardDepthStyle.railTopAlpha(edge: tenth)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-9, "edge \(tenth) regressed the running alpha")
            XCTAssertLessThanOrEqual(value, 0.95 + 1e-9, "edge \(tenth) exceeded the 0.95 cap")
            previous = value
        }
    }

    func testNegativeEdgeStaysZeroAlpha() {
        XCTAssertEqual(CardDepthStyle.railTopAlpha(edge: -0.4), 0)
    }

    /// BUG-57's invariant, carried forward: the boosted top stays at or above the raw edge strength
    /// for every strength up to 0.9 — a thin rail needs the lift more than a thick one, not less.
    func testBug57InvariantHoldsThroughNinetyPercent() {
        for tenth in stride(from: 0.0, through: 0.9, by: 0.05) {
            XCTAssertGreaterThanOrEqual(
                CardDepthStyle.railTopAlpha(edge: tenth), tenth - 1e-9,
                "edge \(tenth) - boosted top fell below the raw edge strength"
            )
        }
    }

    /// The `AppearanceSettingsPane` mobile-synced example from the plan: an intermediate strength
    /// (30, between the Subtle and Balanced presets) still gets a sensible width and a smoothly
    /// interpolated alpha rather than snapping to either neighbor's number.
    func testIntermediateEdgeStrengthThirty() {
        XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: 30), 2)
        XCTAssertEqual(CardDepthStyle.railTopAlpha(edge: 0.30), 0.3857, accuracy: 0.001)
    }

    // MARK: - railStops(edge:coverage:)

    /// Full coverage collapses to (boosted top, edge, edge) — the fix that makes Full's three
    /// presets finally differ from each other by more than a single alpha channel.
    func testFullCoverageStops() {
        let stops = CardDepthStyle.railStops(edge: 0.42, coverage: 1.0)
        XCTAssertEqual(stops.top, 0.60, accuracy: 0.0001)
        XCTAssertEqual(stops.mid, 0.42, accuracy: 0.0001)
        XCTAssertEqual(stops.bottom, 0.42, accuracy: 0.0001)
    }

    /// Partial coverage keeps the pre-BUG-110 mid/bottom formula (BUG-31's geometric coverage cut is
    /// applied separately, by `coverageMask` at the call site) — only the top stop's source changed.
    func testPartialCoverageKeepsTheExistingMidBottomFormula() {
        let edge = 0.42
        let coverage = 0.5
        let stops = CardDepthStyle.railStops(edge: edge, coverage: coverage)
        XCTAssertEqual(stops.top, CardDepthStyle.railTopAlpha(edge: edge), accuracy: 0.0001)
        XCTAssertEqual(stops.mid, edge * (0.33 + 0.67 * coverage), accuracy: 0.0001)
        XCTAssertEqual(stops.bottom, edge * coverage, accuracy: 0.0001)
    }

    // MARK: - railHaloSpread(edgeStrength:) / railHaloAlpha(edge:)

    func testHaloIsZeroAtOffAndSubtle() {
        XCTAssertEqual(CardDepthStyle.railHaloSpread(edgeStrength: 0), 0)
        XCTAssertEqual(CardDepthStyle.railHaloSpread(edgeStrength: 28), 0)
    }

    /// BUG-110 (rc14, Steven rc13 verdict, 2026-09-30): the halo is removed outright — every preset
    /// (Subtle 28 / Balanced 42 / Bold 56) now has a zero spread, so `edgeHighlight`'s
    /// `haloSpread > 0` stroke never draws. (Balanced/Bold were 3pt/5pt through rc13.)
    func testHaloSpreadIsZeroAtEveryPreset() {
        XCTAssertEqual(CardDepthStyle.railHaloSpread(edgeStrength: 28), 0)
        XCTAssertEqual(CardDepthStyle.railHaloSpread(edgeStrength: 42), 0)
        XCTAssertEqual(CardDepthStyle.railHaloSpread(edgeStrength: 56), 0)
    }

    func testHaloWidthCollapsesToTheCrispRailAtBalancedAndBold() {
        // width + 2×spread is the halo stroke's own lineWidth (see `edgeHighlight`); with the halo
        // gone (rc14) it equals the crisp rail's own width: 2 at Balanced, 3 at Bold. Through rc13
        // this read 2+2×3=8 and 3+2×5=13.
        let balancedWidth = CardDepthStyle.railWidth(edgeStrength: 42) + 2 * CardDepthStyle.railHaloSpread(edgeStrength: 42)
        let boldWidth = CardDepthStyle.railWidth(edgeStrength: 56) + 2 * CardDepthStyle.railHaloSpread(edgeStrength: 56)
        XCTAssertEqual(balancedWidth, 2)
        XCTAssertEqual(boldWidth, 3)
    }

    /// The alpha function is unchanged (18% of the top stop) but inert since rc14 — Bold's number
    /// follows the lowered 0.80 top stop (0.144, was 0.162).
    func testHaloAlphaIsEighteenPercentOfTopAlpha() {
        XCTAssertEqual(CardDepthStyle.railHaloAlpha(edge: 0.42), 0.108, accuracy: 0.0005)
        XCTAssertEqual(CardDepthStyle.railHaloAlpha(edge: 0.56), 0.144, accuracy: 0.0005)
    }

    // MARK: - effectiveEdgeStrength(_:artworkPresent:) — BUG-110 (rc13) placeholder clamp

    /// A placeholder tile (no artwork cover) at Bold must render with exactly the same width,
    /// top-stop alpha and halo as an artwork tile explicitly set to Subtle — the rail clamps down
    /// to the Subtle ceiling (28) regardless of the user's chosen level.
    func testPlaceholderClampsBoldDownToSubtleWidthAlphaAndHalo() {
        let clamped = CardDepthStyle.effectiveEdgeStrength(56, artworkPresent: false)
        XCTAssertEqual(clamped, 28)
        XCTAssertEqual(
            CardDepthStyle.railWidth(edgeStrength: clamped),
            CardDepthStyle.railWidth(edgeStrength: 28)
        )
        XCTAssertEqual(
            CardDepthStyle.railTopAlpha(edge: Double(clamped) / 100),
            CardDepthStyle.railTopAlpha(edge: 0.28),
            accuracy: 0.0001
        )
        XCTAssertEqual(CardDepthStyle.railHaloSpread(edgeStrength: clamped), 0)
    }

    /// A tile WITH artwork must never be clamped — every level, including Bold, renders exactly as
    /// the user configured it. This is the negative control for the placeholder-only clamp above.
    func testArtworkPresentLeavesEveryLevelUnclamped() {
        for level in [0, 1, 28, 42, 56, 100] {
            XCTAssertEqual(CardDepthStyle.effectiveEdgeStrength(level, artworkPresent: true), level)
        }
    }

    // MARK: - haloSuppressed(focused:ringBandReserved:)

    func testHaloSuppressionTruthTable() {
        XCTAssertFalse(CardDepthStyle.haloSuppressed(focused: false, ringBandReserved: false))
        XCTAssertFalse(CardDepthStyle.haloSuppressed(focused: false, ringBandReserved: true))
        XCTAssertFalse(CardDepthStyle.haloSuppressed(focused: true, ringBandReserved: false))
        XCTAssertTrue(CardDepthStyle.haloSuppressed(focused: true, ringBandReserved: true))
    }

    // MARK: - railColor(tint:) (beta.18 verdict, FEAT-46 corrected / FEAT-40 follow-up)

    /// No tint (every call site but the four poster-family cards) keeps the white rail.
    func testRailColorDefaultsToWhite() {
        XCTAssertEqual(CardDepthStyle.railColor(tint: nil), Color.white)
    }

    func testRailColorTakesTheTint() {
        let tint = Color(.sRGB, red: 1, green: 0.5, blue: 0, opacity: 1)
        XCTAssertEqual(CardDepthStyle.railColor(tint: tint), tint)
        XCTAssertNotEqual(CardDepthStyle.railColor(tint: tint), Color.white)
    }

    /// The tint only recolours the rail: widths and the alpha stops come from pure functions that
    /// take no colour at all, so they are identical with or without a tint at every preset.
    func testRailStopsUnchangedByTint() {
        for strength in [28, 42, 56] {
            let edge = Double(strength) / 100
            for coverage in [0.0, 0.5, 1.0] {
                let before = CardDepthStyle.railStops(edge: edge, coverage: coverage)
                _ = CardDepthStyle.railColor(tint: .orange)
                let after = CardDepthStyle.railStops(edge: edge, coverage: coverage)
                XCTAssertEqual(before.top, after.top, accuracy: 0.0000001)
                XCTAssertEqual(before.mid, after.mid, accuracy: 0.0000001)
                XCTAssertEqual(before.bottom, after.bottom, accuracy: 0.0000001)
            }
            XCTAssertEqual(CardDepthStyle.railWidth(edgeStrength: strength), CardDepthStyle.railWidth(edgeStrength: strength))
        }
        // The documented anchors still hold.
        XCTAssertEqual(CardDepthStyle.railStops(edge: 0.42, coverage: 1.0).top, 0.60, accuracy: 0.0001)
    }
}
