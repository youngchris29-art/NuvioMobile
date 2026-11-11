import XCTest
import SwiftUI
@testable import NuvioTV

/// The stream badge chips' colour decisions (BUG-28, BUG-43, GitHub #25), against the production
/// functions in `NuvioTV/DesignSystem/StreamBadges.swift`. These cases lived in the UI test target
/// as a hand-copied mirror of the logic until this hosted target could import the app; the mirror
/// is gone, so the two cannot drift.
@MainActor
final class StreamBadgeColorTests: XCTestCase {
    private typealias Chip = StreamBadgeChipView
    private typealias Decision = StreamBadgeChipView.ChipColorDecision

    private func decide(text: String, tag: String, focused: Bool) -> Decision {
        Chip.effectiveTextChipColors(textColorHex: text, tagColorHex: tag, isFocused: focused)
    }

    // MARK: - At rest: contrast guard on a too-close pack pair (BUG-28)

    func testWhiteOnWhitePack_unfocused_appliesContrastGuard() {
        XCTAssertEqual(decide(text: "FFFFFF", tag: "F5F5F5", focused: false),
                       Decision(fg: .computedOnBg, bg: .pack, showBorder: true))
    }

    func testDarkOnDarkPack_appliesContrastGuard_restAndFocused() {
        // Dark on dark: the guard answers with the light text (semantic at rest).
        XCTAssertEqual(decide(text: "1A1A1A", tag: "0D0D0D", focused: false),
                       Decision(fg: .semantic, bg: .pack, showBorder: true))
        XCTAssertEqual(decide(text: "1A1A1A", tag: "0D0D0D", focused: true),
                       Decision(fg: .fixedLight, bg: .pack, showBorder: true))
    }

    func testWellContrastedPack_unfocused_keepsPackColors() {
        XCTAssertEqual(decide(text: "FFFFFF", tag: "1A1A1A", focused: false),
                       Decision(fg: .pack, bg: .pack, showBorder: true))
    }

    func testMissingHexes_unfocused_usesSemanticDefaults() {
        XCTAssertEqual(decide(text: "", tag: "", focused: false),
                       Decision(fg: .semantic, bg: .semantic, showBorder: true))
    }

    func testMissingTagColorOnly_unfocused_guardsAgainstSemanticDefaultBg() {
        XCTAssertEqual(decide(text: "FFFFFF", tag: "", focused: false),
                       Decision(fg: .pack, bg: .semantic, showBorder: true))
    }

    // MARK: - At rest: `tagColor` present, `textColor` missing (BUG-43)

    func testMissingTextColor_lightTagColor_unfocused_appliesContrastGuard() {
        XCTAssertEqual(decide(text: "", tag: "F5F5F5", focused: false),
                       Decision(fg: .computedOnBg, bg: .pack, showBorder: true))
    }

    func testMissingTextColor_darkTagColor_unfocused_keepsSemanticForeground() {
        XCTAssertEqual(decide(text: "", tag: "0D0D0D", focused: false),
                       Decision(fg: .semantic, bg: .pack, showBorder: true))
        XCTAssertEqual(decide(text: "", tag: "242424", focused: false),
                       Decision(fg: .semantic, bg: .pack, showBorder: true))
    }

    // MARK: - 8-digit hex is AARRGGBB (BUG-43)

    func testEightDigitHex_readsAsArgb() {
        let dark = Theme.Palette.luminance(fromHexString: "#FF1A1A1A")
        XCTAssertNotNil(dark)
        XCTAssertLessThan(dark ?? 1, 0.15)
        let light = Theme.Palette.luminance(fromHexString: "#FFF5F5F5")
        XCTAssertNotNil(light)
        XCTAssertGreaterThan(light ?? 0, 0.85)
        XCTAssertEqual(decide(text: "", tag: "#FFF5F5F5", focused: false),
                       Decision(fg: .computedOnBg, bg: .pack, showBorder: true))
    }

    func testAlphaFromHex() throws {
        XCTAssertEqual(Theme.Palette.alpha(fromHexString: "FFD500"), 1)
        XCTAssertEqual(Theme.Palette.alpha(fromHexString: "#FFF"), 1)
        XCTAssertEqual(Theme.Palette.alpha(fromHexString: "#00000000"), 0)
        XCTAssertEqual(try XCTUnwrap(Theme.Palette.alpha(fromHexString: "#20FFD500")), 32.0 / 255.0, accuracy: 0.0001)
        XCTAssertNil(Theme.Palette.alpha(fromHexString: ""))
        XCTAssertNil(Theme.Palette.alpha(fromHexString: "zzz"))
    }

    // MARK: - Focused: the pack's colours survive (GitHub #25)

    /// The device screenshot case: blue, purple and orange chips with white text. Until beta 22
    /// every focused chip became the same 8 % grey with dark text.
    func testColouredPack_focused_keepsPackColors() {
        for tag in ["3D5AFE", "7C3AED", "E67E22"] {
            XCTAssertEqual(decide(text: "FFFFFF", tag: tag, focused: true),
                           Decision(fg: .pack, bg: .pack, showBorder: true, darkBase: false), tag)
        }
    }

    /// An opaque fill is judged the same focused or not: the chip draws its own background.
    func testOpaquePack_focusedMatchesRest() {
        for (text, tag) in [("FFFFFF", "F5F5F5"), ("FFFFFF", "1A1A1A"), ("000000", "FFD500")] {
            let rest = decide(text: text, tag: tag, focused: false)
            let focused = decide(text: text, tag: tag, focused: true)
            XCTAssertEqual(focused, rest, "\(text) on \(tag)")
            XCTAssertFalse(focused.darkBase)
        }
    }

    /// The semantic near-white flips dark on the focused row (BUG-28), so a chip that keeps a dark
    /// background takes the fixed near-white instead.
    func testMissingTextColor_focused_usesFixedLightOnDarkFills() {
        XCTAssertEqual(decide(text: "", tag: "242424", focused: true),
                       Decision(fg: .fixedLight, bg: .pack, showBorder: true, darkBase: false))
        XCTAssertEqual(decide(text: "", tag: "", focused: true),
                       Decision(fg: .fixedLight, bg: .semantic, showBorder: true, darkBase: false))
        XCTAssertEqual(decide(text: "", tag: "F5F5F5", focused: true),
                       Decision(fg: .computedOnBg, bg: .pack, showBorder: true, darkBase: false))
    }

    /// The tinted packs: a 12 % gold fill with gold text. It is a dark chip, so the gold text
    /// stays (at rest too: judged by the raw hue it used to be swapped for near-black), and on the
    /// platter the tint sits on the dark base, not on white.
    func testTranslucentTint_keepsPackTextAndGetsDarkBaseOnlyWhenFocused() {
        XCTAssertEqual(decide(text: "FFD500", tag: "#20FFD500", focused: false),
                       Decision(fg: .pack, bg: .pack, showBorder: true, darkBase: false))
        XCTAssertEqual(decide(text: "FFD500", tag: "#20FFD500", focused: true),
                       Decision(fg: .pack, bg: .pack, showBorder: true, darkBase: true))
        XCTAssertEqual(decide(text: "", tag: "#00000000", focused: true),
                       Decision(fg: .fixedLight, bg: .pack, showBorder: true, darkBase: true))
    }

    /// A faint white tint with black text is a dark chip: black-on-dark must trip the guard.
    /// (Judged by the raw hue it used to pass as "black on white".)
    func testTranslucentLightTint_darkText_getsLightText() {
        XCTAssertEqual(decide(text: "000000", tag: "#20FFFFFF", focused: false),
                       Decision(fg: .semantic, bg: .pack, showBorder: true, darkBase: false))
        XCTAssertEqual(decide(text: "000000", tag: "#20FFFFFF", focused: true),
                       Decision(fg: .fixedLight, bg: .pack, showBorder: true, darkBase: true))
    }

    /// The dark base is for any fill that is not fully opaque.
    func testAlphaBoundary() {
        XCTAssertTrue(decide(text: "000000", tag: "#FEFFFFFF", focused: true).darkBase)
        XCTAssertFalse(decide(text: "000000", tag: "#FFFFFFFF", focused: true).darkBase)
        XCTAssertTrue(Chip.imageChipSurface(filled: true, tagColorHex: "#FEFFFFFF", isFocused: true).darkBase)
        XCTAssertFalse(Chip.imageChipSurface(filled: true, tagColorHex: "#FFFFFFFF", isFocused: true).darkBase)
    }

    /// The decision → colour mapping: the fixed colours never follow the row's scheme flip.
    func testResolvedForegroundUsesFixedColoursOffTheSemanticPath() {
        func colour(_ text: String, _ tag: String, focused: Bool) -> Color {
            Chip.resolvedForeground(decide(text: text, tag: tag, focused: focused), textColorHex: text, tagColorHex: tag)
        }
        XCTAssertEqual(colour("FFFFFF", "F5F5F5", focused: false), Chip.computedDarkText)
        XCTAssertEqual(colour("FFFFFF", "F5F5F5", focused: true), Chip.computedDarkText)
        XCTAssertEqual(colour("1A1A1A", "0D0D0D", focused: true), Chip.fixedLightText)
        XCTAssertEqual(colour("", "#20FFD500", focused: true), Chip.fixedLightText)
        XCTAssertEqual(colour("1A1A1A", "0D0D0D", focused: false), Theme.Palette.textPrimary)
        XCTAssertEqual(colour("FFFFFF", "3D5AFE", focused: true), Color(hexString: "FFFFFF"))
    }

    func testEffectiveBackgroundLuminanceBlendsByAlpha() {
        let base = Chip.effectiveBackgroundLuminance(tagColorHex: "")
        XCTAssertEqual(base, Theme.Palette.luminance(fromHexString: "1A1A1A") ?? -1, accuracy: 0.0001)
        XCTAssertEqual(Chip.effectiveBackgroundLuminance(tagColorHex: "#00FFFFFF"), base, accuracy: 0.0001)
        XCTAssertEqual(Chip.effectiveBackgroundLuminance(tagColorHex: "FFFFFF"), 1, accuracy: 0.0001)
        let tint = Chip.effectiveBackgroundLuminance(tagColorHex: "#20FFD500")
        XCTAssertGreaterThan(tint, base)
        XCTAssertLessThan(tint, 0.3)
    }

    // MARK: - Image chips (GitHub #25)

    private typealias Surface = StreamBadgeChipView.ImageChipSurface

    // MARK: - Chip base, parity, transparent pack colours (GitHub #25 follow-up)

    func testChipBaseIsTheRowRestingSurface() {
        XCTAssertEqual(Chip.chipBaseHex, "1A1A1A")
        XCTAssertEqual(Chip.chipBase, Theme.Palette.surface)
        XCTAssertEqual(Theme.Palette.luminance(fromHexString: Chip.chipBaseHex) ?? -1,
                       Theme.Palette.luminance(fromHexString: "1A1A1A") ?? -2, accuracy: 0.0001)
        XCTAssertEqual(Chip.resolvedBackground(Decision(fg: .semantic, bg: .semantic, showBorder: true),
                                               tagColorHex: ""), Chip.chipBase)
    }

    func testIsFilled_exactMatchParity() {
        for yes in ["filled", "FILLED", " filled ", "Filled"] { XCTAssertTrue(Chip.isFilled(tagStyle: yes), yes) }
        for no in ["bordered", "filled and bordered", "", "outlined"] { XCTAssertFalse(Chip.isFilled(tagStyle: no), no) }
    }

    func testPackHex_transparentCountsAsMissing() {
        XCTAssertEqual(Chip.packHex("#00000000"), "")
        XCTAssertEqual(Chip.packHex("#00FFFFFF"), "")
        XCTAssertEqual(Chip.packHex("#FFFFFF"), "#FFFFFF")
        XCTAssertEqual(Chip.packHex("#80FFFFFF"), "#80FFFFFF")
        XCTAssertEqual(Chip.packHex(""), "")
    }

    func testTransparentTextColour_fallsBackToLightText() {
        XCTAssertEqual(Chip.effectiveTextChipColors(textColorHex: Chip.packHex("#00FFFFFF"), tagColorHex: "", isFocused: false).fg, .semantic)
        XCTAssertEqual(Chip.effectiveTextChipColors(textColorHex: Chip.packHex("#00FFFFFF"), tagColorHex: "", isFocused: true).fg, .fixedLight)
        // The guard itself also drops a transparent text colour.
        XCTAssertEqual(Chip.effectiveTextChipColors(textColorHex: "#00FFFFFF", tagColorHex: "", isFocused: true).fg, .fixedLight)
    }

    func testHisPacks_decisions() {
        let xperience = (style: "filled and bordered", tag: "#00000000", text: "#00000000")
        let sweaty = (style: "bordered", tag: "#00000000", text: "#FFFFFF")
        for p in [xperience, sweaty] {
            let filled = Chip.isFilled(tagStyle: p.style)
            XCTAssertFalse(filled)
            XCTAssertEqual(Chip.imageChipSurface(filled: filled, tagColorHex: p.tag, isFocused: false),
                           Surface(darkBase: false, drawsPackFill: false))
            XCTAssertEqual(Chip.imageChipSurface(filled: filled, tagColorHex: p.tag, isFocused: true),
                           Surface(darkBase: true, drawsPackFill: false))
        }
        func fg(_ text: String, _ focused: Bool) -> StreamBadgeChipView.ChipFgSource {
            Chip.effectiveTextChipColors(textColorHex: text, tagColorHex: "", isFocused: focused).fg
        }
        XCTAssertEqual(fg(sweaty.text, false), .pack)
        XCTAssertEqual(fg(sweaty.text, true), .pack)
        XCTAssertEqual(fg(xperience.text, false), .semantic)
        XCTAssertEqual(fg(xperience.text, true), .fixedLight)
    }


    func testImageChipSurface_atRestDrawsOnlyWhatThePackAsked() {
        XCTAssertEqual(Chip.imageChipSurface(filled: false, tagColorHex: "#000000", isFocused: false),
                       Surface(darkBase: false, drawsPackFill: false))
        XCTAssertEqual(Chip.imageChipSurface(filled: true, tagColorHex: "#000000", isFocused: false),
                       Surface(darkBase: false, drawsPackFill: true))
        XCTAssertEqual(Chip.imageChipSurface(filled: true, tagColorHex: "#20FFD500", isFocused: false),
                       Surface(darkBase: false, drawsPackFill: true))
        XCTAssertEqual(Chip.imageChipSurface(filled: true, tagColorHex: "", isFocused: false),
                       Surface(darkBase: false, drawsPackFill: false))
    }

    func testImageChipSurface_focused() {
        // Transparent artwork: the dark base, as before.
        XCTAssertEqual(Chip.imageChipSurface(filled: false, tagColorHex: "#00000000", isFocused: true),
                       Surface(darkBase: true, drawsPackFill: false))
        // An opaque fill needs nothing under it.
        XCTAssertEqual(Chip.imageChipSurface(filled: true, tagColorHex: "#FFD500", isFocused: true),
                       Surface(darkBase: false, drawsPackFill: true))
        // The tinted packs: the tint over the dark base (it used to tint the white platter).
        XCTAssertEqual(Chip.imageChipSurface(filled: true, tagColorHex: "#20FFD500", isFocused: true),
                       Surface(darkBase: true, drawsPackFill: true))
        // `filled` with a colour that does not parse is a transparent chip.
        XCTAssertEqual(Chip.imageChipSurface(filled: true, tagColorHex: "nope", isFocused: true),
                       Surface(darkBase: true, drawsPackFill: false))
    }

    func testPlatterEdge_onlyForALightOpaqueFillOnThePlatter() {
        XCTAssertTrue(Chip.needsPlatterEdge(drawsPackFill: true, darkBase: false, tagColorHex: "#FFFFFF", isFocused: true))
        XCTAssertFalse(Chip.needsPlatterEdge(drawsPackFill: true, darkBase: false, tagColorHex: "#FFFFFF", isFocused: false))
        XCTAssertFalse(Chip.needsPlatterEdge(drawsPackFill: true, darkBase: false, tagColorHex: "#176BE8", isFocused: true))
        XCTAssertFalse(Chip.needsPlatterEdge(drawsPackFill: true, darkBase: true, tagColorHex: "#20FFFFFF", isFocused: true))
        XCTAssertFalse(Chip.needsPlatterEdge(drawsPackFill: false, darkBase: true, tagColorHex: "#FFFFFF", isFocused: true))
    }
}
