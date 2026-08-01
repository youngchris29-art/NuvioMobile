import XCTest

/// Pure-logic coverage for BUG-28 (stream-list badge chips rendering white-on-white on the White
/// accent theme) — see `StreamBadgeChipView.effectiveTextChipColors` in
/// `NuvioTV/DesignSystem/StreamBadges.swift`.
///
/// Deliberately does NOT launch `XCUIApplication` (unlike `NuvioTVUITests.swift`'s device-driving
/// suite) — these are plain, fast asserts against a decision function.
///
/// Why this file mirrors the production logic instead of importing it: `NuvioTVUITests` is a
/// genuine `com.apple.product-type.bundle.ui-testing` target (`TEST_TARGET_NAME = NuvioTV`, no
/// `BUNDLE_LOADER`/`TEST_HOST` in project.pbxproj). Unlike a hosted *unit* test bundle — which is
/// `dlopen`-ed into the app process via `BUNDLE_LOADER`, so `@testable import` both compiles and
/// links — a UI test bundle runs in its own `XCTRunner` process and only ever talks to the app
/// under test through the accessibility/XPC bridge. `@testable import NuvioTV` here would type-check
/// (the app module's interface is visible) but fail at LINK time the moment a symbol is actually
/// referenced, since nothing embeds the app's object code into this bundle. So this file keeps a
/// small, exact mirror of just the pure enums/function under test — no `SharedCore`/`ImageIO`/
/// `UIKit` dependencies, nothing that needs the app to actually run. If `NuvioTV` ever grows a real
/// (hosted) Unit Testing target, these cases should move there as genuine `@testable import` tests
/// against the real `StreamBadgeChipView.effectiveTextChipColors` instead of this mirror — and this
/// file should be deleted so the two can't drift.
///
/// Keep this in sync by hand with `StreamBadgeChipView.effectiveTextChipColors` /
/// `Theme.Palette.luminance(fromHexString:)` whenever that logic changes.
final class StreamBadgeColorTests: XCTestCase {

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

    // MARK: - Mirror of StreamBadgeChipView's pure color-decision types

    private enum ChipFgSource: Equatable {
        case semantic
        case pack
        case computedOnBg
        case focusedFixed
    }

    private enum ChipBgSource: Equatable {
        case semantic
        case pack
        case focusedFixed
    }

    private struct ChipColorDecision: Equatable {
        var fg: ChipFgSource
        var bg: ChipBgSource
        var showBorder: Bool
    }

    private static let defaultBgHex = "242424"

    // MARK: - Mirror of StreamBadgeChipView.effectiveTextChipColors

    private func effectiveTextChipColors(
        textColorHex: String,
        tagColorHex: String,
        isFocused: Bool
    ) -> ChipColorDecision {
        if isFocused {
            return ChipColorDecision(fg: .focusedFixed, bg: .focusedFixed, showBorder: false)
        }

        let packBgLum = luminance(fromHexString: tagColorHex)
        let bgSource: ChipBgSource = packBgLum != nil ? .pack : .semantic

        guard let fgLum = luminance(fromHexString: textColorHex) else {
            return ChipColorDecision(fg: .semantic, bg: bgSource, showBorder: true)
        }

        let effectiveBgLum = packBgLum ?? luminance(fromHexString: Self.defaultBgHex)!
        if abs(fgLum - effectiveBgLum) < 0.3 {
            return ChipColorDecision(fg: .computedOnBg, bg: bgSource, showBorder: true)
        }
        return ChipColorDecision(fg: .pack, bg: bgSource, showBorder: true)
    }

    // MARK: - Focused: always ignores the pack

    /// The reporter's case: a pack whose `textColor`/`tagColor` are both near-white. Focused, the
    /// row's platter is already near-white, so BOTH pack hexes must be discarded outright.
    func testWhiteOnWhitePack_focused_ignoresPackEntirely() {
        let decision = effectiveTextChipColors(textColorHex: "FFFFFF", tagColorHex: "F5F5F5", isFocused: true)
        XCTAssertEqual(decision, ChipColorDecision(fg: .focusedFixed, bg: .focusedFixed, showBorder: false))
    }

    func testDarkOnDarkPack_focused_ignoresPackEntirely() {
        let decision = effectiveTextChipColors(textColorHex: "1A1A1A", tagColorHex: "0D0D0D", isFocused: true)
        XCTAssertEqual(decision, ChipColorDecision(fg: .focusedFixed, bg: .focusedFixed, showBorder: false))
    }

    func testMissingHexes_focused_ignoresPackEntirely() {
        let decision = effectiveTextChipColors(textColorHex: "", tagColorHex: "", isFocused: true)
        XCTAssertEqual(decision, ChipColorDecision(fg: .focusedFixed, bg: .focusedFixed, showBorder: false))
    }

    // MARK: - Unfocused: contrast guard on a too-close pack pair

    /// BUG-28 reproduction: near-white fg on near-white bg, unfocused. The guard must kick in and
    /// swap the foreground for a computed pick rather than trusting the pack's illegible pair.
    func testWhiteOnWhitePack_unfocused_appliesContrastGuard() {
        let decision = effectiveTextChipColors(textColorHex: "FFFFFF", tagColorHex: "F5F5F5", isFocused: false)
        XCTAssertEqual(decision.fg, .computedOnBg)
        XCTAssertEqual(decision.bg, .pack)
        XCTAssertTrue(decision.showBorder)
    }

    /// Symmetric case: near-black fg on near-black bg should trip the same guard (dark-on-dark is
    /// just as illegible as white-on-white).
    func testDarkOnDarkPack_unfocused_appliesContrastGuard() {
        let decision = effectiveTextChipColors(textColorHex: "1A1A1A", tagColorHex: "0D0D0D", isFocused: false)
        XCTAssertEqual(decision.fg, .computedOnBg)
        XCTAssertEqual(decision.bg, .pack)
        XCTAssertTrue(decision.showBorder)
    }

    // MARK: - Unfocused: well-contrasted pack keeps its own colors

    func testWellContrastedPack_unfocused_keepsPackColors() {
        let decision = effectiveTextChipColors(textColorHex: "FFFFFF", tagColorHex: "1A1A1A", isFocused: false)
        XCTAssertEqual(decision.fg, .pack)
        XCTAssertEqual(decision.bg, .pack)
        XCTAssertTrue(decision.showBorder)
    }

    // MARK: - Unfocused: defaults when the pack supplies no colors

    func testMissingHexes_unfocused_usesSemanticDefaults() {
        let decision = effectiveTextChipColors(textColorHex: "", tagColorHex: "", isFocused: false)
        XCTAssertEqual(decision.fg, .semantic)
        XCTAssertEqual(decision.bg, .semantic)
        XCTAssertTrue(decision.showBorder)
    }

    /// Missing `tagColor` alone: the guard should compare against the semantic default background
    /// luminance (0x242424, dark) rather than crashing or silently ignoring the guard.
    func testMissingTagColorOnly_unfocused_guardsAgainstSemanticDefaultBg() {
        // White text against the (missing → semantic dark default) background: well-contrasted,
        // so the pack's own text color should still be used.
        let decision = effectiveTextChipColors(textColorHex: "FFFFFF", tagColorHex: "", isFocused: false)
        XCTAssertEqual(decision.fg, .pack)
        XCTAssertEqual(decision.bg, .semantic)
        XCTAssertTrue(decision.showBorder)
    }
}
