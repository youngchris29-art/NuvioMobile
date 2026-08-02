import XCTest

/// Pure-logic coverage for FEAT-14 (opt-in accent-colored focus ring on artwork cards) — see
/// `Theme.Palette.focusRingHex(accentFocusHex:)` in `NuvioTV/DesignSystem/Theme.swift`.
///
/// Deliberately does NOT launch `XCUIApplication` (unlike `NuvioTVUITests.swift`'s device-driving
/// suite) — these are plain, fast asserts against a decision function, following the same
/// hand-mirrored-function convention as `StreamBadgeColorTests.swift` (see that file's header for
/// why: `NuvioTVUITests` is a genuine UI-testing target with no `BUNDLE_LOADER`/`TEST_HOST`, so
/// `@testable import NuvioTV` type-checks but fails at link time — nothing embeds the app's object
/// code into this bundle). This file keeps a small, exact mirror of just the pure functions under
/// test instead.
///
/// Keep this in sync by hand with `Theme.Palette.focusRingHex(accentFocusHex:)` /
/// `Theme.Palette.luminance(fromHexString:)` whenever that logic changes.
final class AccentFocusRingTests: XCTestCase {

    // MARK: - Mirror of Theme.Palette.luminance(fromHexString:)

    private func luminance(fromHexString hexString: String) -> Double? {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 3 || s.count == 6 || s.count == 8,
              let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b: Double
        switch s.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15.0
            g = Double((value >> 4) & 0xF) / 15.0
            b = Double(value & 0xF) / 15.0
        case 6:
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
        default: // 8: RRGGBBAA
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
        }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - Mirror of Theme.Palette.focusRingHex(accentFocusHex:)

    private static let fallbackHex = "1A1A1A"

    private func focusRingHex(accentFocusHex: String) -> String {
        guard let lum = luminance(fromHexString: accentFocusHex), lum > 0.75 else {
            return accentFocusHex
        }
        return Self.fallbackHex
    }

    // MARK: - The seven themes' accentFocus hexes (Theme.swift:37-49's applyTheme table)

    private static let crimsonFocusHex = "FF5252"
    private static let oceanFocusHex = "42A5F5"
    private static let violetFocusHex = "AB47BC"
    private static let emeraldFocusHex = "66BB6A"
    private static let amberFocusHex = "FFA726"
    private static let roseFocusHex = "EC407A"
    private static let whiteFocusHex = "FFFFFF"

    // MARK: - Dark/saturated themes: ring keeps the theme's own accent color

    func testCrimsonFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.crimsonFocusHex), Self.crimsonFocusHex)
    }

    func testOceanFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.oceanFocusHex), Self.oceanFocusHex)
    }

    func testVioletFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.violetFocusHex), Self.violetFocusHex)
    }

    func testEmeraldFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.emeraldFocusHex), Self.emeraldFocusHex)
    }

    /// Amber is the brightest of the six saturated themes (luminance ~0.69) — closest to the
    /// 0.75 threshold without crossing it, so it's the sharpest regression check that the
    /// threshold isn't accidentally too low.
    func testAmberFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.amberFocusHex), Self.amberFocusHex)
    }

    func testRoseFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.roseFocusHex), Self.roseFocusHex)
    }

    // MARK: - White theme: near-white focus hex falls back to the fixed dark ring

    /// The White theme's accentFocus (0xFFFFFF, luminance 1.0) is the one case a near-white ring
    /// would vanish against the system focus platter/lift brightness — this is the whole reason
    /// `focusRingHex` exists.
    func testWhiteFocusHex_fallsBackToFixedDarkRing() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.whiteFocusHex), Self.fallbackHex)
    }

    // MARK: - Determinism

    func testFocusRingHex_isDeterministic() {
        for hex in [Self.crimsonFocusHex, Self.oceanFocusHex, Self.violetFocusHex,
                    Self.emeraldFocusHex, Self.amberFocusHex, Self.roseFocusHex, Self.whiteFocusHex] {
            XCTAssertEqual(focusRingHex(accentFocusHex: hex), focusRingHex(accentFocusHex: hex))
        }
    }

    // MARK: - Threshold boundary
    //
    // For a gray hex (R == G == B == v), the Rec. 709 weights sum to 1.0, so luminance reduces
    // exactly to v/255 — no rounding fuzz. 0.75 * 255 = 191.25, so 0xBF (191 → 0.74902) sits just
    // below the threshold and 0xC0 (192 → 0.75294) sits just above it, giving two exact,
    // deterministic asserts either side of the `> 0.75` guard.

    /// Just below the threshold (0xBF, luminance ≈ 0.749): the guard's `>` doesn't trip, so the
    /// theme color is kept.
    func testJustBelowThreshold_keepsThemeColor() {
        XCTAssertEqual(focusRingHex(accentFocusHex: "BFBFBF"), "BFBFBF")
    }

    /// Just above the threshold (0xC0, luminance ≈ 0.753): the guard trips and falls back.
    func testJustAboveThreshold_fallsBack() {
        XCTAssertEqual(focusRingHex(accentFocusHex: "C0C0C0"), Self.fallbackHex)
    }

    /// Comfortably below the threshold, for a non-boundary sanity check.
    func testMidGray_keepsThemeColor() {
        XCTAssertEqual(focusRingHex(accentFocusHex: "808080"), "808080")
    }

    // MARK: - Malformed/missing input falls through unchanged (nil luminance short-circuits)

    func testMalformedHex_returnsInputUnchanged() {
        XCTAssertEqual(focusRingHex(accentFocusHex: "not-a-hex"), "not-a-hex")
    }

    func testEmptyHex_returnsInputUnchanged() {
        XCTAssertEqual(focusRingHex(accentFocusHex: ""), "")
    }
}
