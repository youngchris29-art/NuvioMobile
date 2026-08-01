import SwiftUI

/// Central design tokens for the tvOS app.
///
/// Mirrors the mobile app's default **Crimson** dark palette (see composeApp `ThemeColors.kt` +
/// `Theme.kt`) so the two clients read as one product. Use these everywhere instead of hardcoding
/// fonts, colors, paddings, and sizes per-screen.
enum Theme {

    // MARK: - Color

    enum Palette {
        /// App background (deepest layer).
        static let background = Color(hex: 0x0D0D0D)
        /// Elevated surface (cards, sheets, shimmer base).
        static let surface = Color(hex: 0x1A1A1A)
        /// Higher-elevation surface (chips, controls).
        static let surfaceElevated = Color(hex: 0x242424)
        /// Brand accent — mutable so the user's theme choice applies (see `applyTheme`). Reads are
        /// re-evaluated when ContentView re-identifies the tree on a theme change, so plain static
        /// access everywhere keeps working. `nonisolated(unsafe)`: only mutated on the main actor.
        nonisolated(unsafe) static var accent = Color(hex: 0xE53935)
        /// Focus ring / highlight (brighter accent). Mutable — follows the theme with `accent`.
        nonisolated(unsafe) static var accentFocus = Color(hex: 0xFF5252)
        /// Text/icon color for content drawn ON an `accent`/`accentFocus` fill (selected chips,
        /// filled badges, etc). Mutable — recomputed by `applyTheme` from the accent's luminance so
        /// the near-white White theme gets dark text/icons while every other (darker/saturated)
        /// theme keeps the existing light `textPrimary`. Only use this where text sits on a solid
        /// accent fill — accent borders/rings don't need it.
        nonisolated(unsafe) static var accentText = Color(hex: 0x0D0D0D)

        /// Retints the palette for a shared `AppTheme` (by enum name). Accents mirror mobile's
        /// `ThemeColors.kt` (`AppTheme.nativeAccentHex`), with a brighter focus variant per theme.
        static func applyTheme(named name: String) {
            let accentHex: UInt32
            switch name {
            case "OCEAN":   accentHex = 0x1E88E5; accentFocus = Color(hex: 0x42A5F5)
            case "VIOLET":  accentHex = 0x8E24AA; accentFocus = Color(hex: 0xAB47BC)
            case "EMERALD": accentHex = 0x43A047; accentFocus = Color(hex: 0x66BB6A)
            case "AMBER":   accentHex = 0xFB8C00; accentFocus = Color(hex: 0xFFA726)
            case "ROSE":    accentHex = 0xD81B60; accentFocus = Color(hex: 0xEC407A)
            case "WHITE":   accentHex = 0xF5F5F5; accentFocus = Color(hex: 0xFFFFFF)
            default:        accentHex = 0xE53935; accentFocus = Color(hex: 0xFF5252) // CRIMSON
            }
            accent = Color(hex: accentHex)
            accentText = onColor(forFillHex: accentHex)
        }

        /// Picks a legible text/icon color for a solid fill, by simple relative-luminance
        /// threshold: dark text for light fills (e.g. the White theme's near-white accent), the
        /// app's light `textPrimary` otherwise. Not full WCAG contrast math — just enough to keep
        /// text readable against any of the app's accent colors. Threshold sits well above the
        /// brightest saturated accent (Amber, ~0.6) so every existing theme keeps its current
        /// light text; only near-white fills (the White theme, ~0.96) cross it.
        static func onColor(forFillHex hex: UInt32) -> Color {
            let r = Double((hex >> 16) & 0xFF) / 255.0
            let g = Double((hex >> 8) & 0xFF) / 255.0
            let b = Double(hex & 0xFF) / 255.0
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return luminance > 0.75 ? Color(hex: 0x0D0D0D) : textPrimary
        }

        /// Relative luminance (0–1, Rec. 709 weights) of a `#RGB`/`#RRGGBB`/`#RRGGBBAA` hex
        /// string, using the same parsing rules as `Color(hexString:)`. Returns nil for
        /// empty/malformed input so callers can fall back. Deliberately String-in/Double-out (no
        /// `Color` involved) so pure color-decision logic elsewhere (e.g.
        /// `StreamBadgeChipView.effectiveTextChipColors`, BUG-28) stays unit-testable without
        /// relying on `Color` equality.
        static func luminance(fromHexString hexString: String) -> Double? {
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

        /// Primary text — semantic, resolves against the pinned dark scheme (near-white) and
        /// tracks Increase Contrast automatically. (Was hard-coded 0xF5F7F8.)
        static let textPrimary = Color.primary
        /// Secondary / muted text — semantic. (Was hard-coded 0x969CA3.)
        static let textSecondary = Color.secondary
        /// Hairline / outline color.
        static let outline = Color(hex: 0x252A2A)
        /// Rating star.
        static let star = Color(hex: 0xFFC857)
        /// Progress bar fill (continue watching).
        static let progress = Color(hex: 0xFF5252)
        /// Label color on the system focus platter (near-white). Public mirror of
        /// `FlatControlStyles.FocusLook.onPlatter` — that type stays private to
        /// FlatControlStyles.swift, so call sites elsewhere (e.g. `StreamBadges.swift`, BUG-28)
        /// that need the same "on the white platter" color use this instead of duplicating it.
        static let onFocusPlatter = Color.black.opacity(0.85)
    }

    // MARK: - Surfaces (materials / Liquid Glass)

    /// System materials for floating chrome. Prefer these over the opaque `Palette.surface*`
    /// hexes for anything that OVERLAYS content (modals, pickers, pause cards, chrome over
    /// artwork) — HIG: glass/materials belong to the floating layer, opaque surfaces to the
    /// content layer. `Palette.surface*` remains correct for in-content fills (card shimmer
    /// bases, list row fills) where translucency would just add noise.
    enum Surface {
        /// Large panels presented over content (stream picker, track picker, profile sheets).
        static let panel: Material = .thick
        /// Standard floating overlays (pause info card, confirmation panels).
        static let overlay: Material = .regular
        /// Light-touch chrome riding on media (badges over artwork, transport bar).
        static let chrome: Material = .thin
    }

    // MARK: - Typography (semantic tvOS text styles)
    //
    // Every token maps to a `Font.TextStyle` rather than a fixed point size, so text scales with
    // the user's Larger Text / Bold Text accessibility settings for free (HIG ACCESS-07). The
    // tvOS defaults already sit on the 10-foot size table (body 29, title3 48, title2 57…), so
    // each mapping below is the closest style to the old fixed size — call sites are unchanged.

    enum Font {
        /// Hero display text (was fixed 52pt bold → title2, 57pt): clearer step above screenTitle.
        static let hero = SwiftUI.Font.title2.weight(.bold)
        /// Screen titles (was fixed 48pt bold → title3, 48pt — exact match).
        static let screenTitle = SwiftUI.Font.title3.weight(.bold)
        /// Section/row headers (was fixed 30pt semibold → callout, 31pt).
        static let sectionTitle = SwiftUI.Font.callout.weight(.semibold)
        /// Card titles under posters (was fixed 24pt → caption, 25pt).
        static let cardTitle = SwiftUI.Font.caption
        /// Body copy (was fixed 28pt → body, 29pt — the HIG minimum for body text).
        static let body = SwiftUI.Font.body
        /// Metadata lines — year/runtime/rating (was fixed 26pt semibold → caption, 25pt).
        static let meta = SwiftUI.Font.caption.weight(.semibold)
        /// Fine print (was fixed 22pt → caption2, 23pt).
        static let caption = SwiftUI.Font.caption2
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 40
        /// Overscan-safe screen edge padding.
        static let screen: CGFloat = 60
        /// Vertical gap between stacked sections/rows.
        static let sectionGap: CGFloat = 48
        /// Horizontal gap between cards in a row.
        static let rowGap: CGFloat = 28
    }

    // MARK: - Corner radii

    enum Radius {
        static let chip: CGFloat = 6
        static let card: CGFloat = 12
        static let hero: CGFloat = 16
    }

    // MARK: - Standard element sizes

    enum Size {
        static let posterWidth: CGFloat = 220
        static let posterHeight: CGFloat = 330      // 2:3
        static let landscapeWidth: CGFloat = 360
        static let landscapeHeight: CGFloat = 203   // 16:9
        /// Episode thumbnail cards in the Detail episodes row (16:9, larger than landscape cards
        /// so the still + badges stay readable at 10 feet).
        static let episodeWidth: CGFloat = 420
        static let episodeHeight: CGFloat = 236
        static let miniPosterWidth: CGFloat = 180
        static let miniPosterHeight: CGFloat = 270
        static let castAvatar: CGFloat = 140
        static let heroHeight: CGFloat = 480
        /// Height of the full-bleed Home hero backdrop (image + scrim) behind the scrolling rows.
        static let heroBackdropHeight: CGFloat = 820
        /// Top padding that pushes the hero's logo/synopsis overlay down onto the lower third of
        /// the backdrop (mirrors Detail's layout).
        static let heroForegroundTopPad: CGFloat = 340
        /// Fixed height of the hero carousel viewport. Every page reserves identical slot heights
        /// (logo + meta + synopsis + CTA button), so advancing the hero can never reflow the rows
        /// below it — that reflow was the visible "glitch" on every 8s auto-advance. Sized to the
        /// tallest layout's summed slots + paddings (Nuvio-style: 150+32+108+56 + 3×16 + 2×24)
        /// with a little headroom.
        static let heroCarouselHeight: CGFloat = 452
        /// Fixed slot for the hero's "Go to Movie"/"Go to Show" CTA button (the hero's only
        /// focusable element — the info block above it is static content).
        static let heroButtonSlotHeight: CGFloat = 56
        /// Fixed logo/title slot inside a hero page (bottom-aligned; image fits within it).
        static let heroLogoSlotHeight: CGFloat = 150
        static let heroLogoMaxWidth: CGFloat = 520
        /// Fixed single-line metadata slot inside a hero page.
        static let heroMetaSlotHeight: CGFloat = 32
        /// Fixed two-line synopsis slot inside a hero page.
        static let heroSynopsisSlotHeight: CGFloat = 72
        // UX-2 hero redesign, v2: "Nuvio-style" — info panel top-LEFT, artwork reading on the
        // right behind a leading scrim. Same fixed-slot rule as the classic layout: every
        // dimension constant so pages stay layout-identical and the carousel never reflows
        // the rows below. Panel sum stays inside `heroCarouselHeight`
        // (150 + 32 + 108 + spacings ≈ 320 < 344).
        /// Fixed three-line synopsis slot for the fixed-width Nuvio-style panel.
        static let heroSynopsisSlotHeightNuvio: CGFloat = 108
        /// Fixed width of the leading hero info panel (text column) in the Nuvio-style layout.
        static let heroInfoPanelWidth: CGFloat = 680
        /// Nuvio-style raises the info panel toward the top of the backdrop (classic uses
        /// `heroForegroundTopPad`'s lower-third placement).
        static let heroForegroundTopPadNuvio: CGFloat = 120
        /// Width of the right-anchored artwork panel in the Nuvio-style hero (tvOS layout is
        /// a fixed 1920pt canvas). Its left ~30% fades out via a gradient mask, so the flat
        /// background region behind the 680pt info panel meets the art in a smooth blend.
        static let heroNuvioArtworkWidth: CGFloat = 1250
    }
}

extension Color {
    /// Create a color from a 0xRRGGBB literal (sRGB), e.g. `Color(hex: 0xE53935)`.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Parse a `#RGB` / `#RRGGBB` / `#RRGGBBAA` (or unprefixed) hex string, e.g. from a shared
    /// `StreamBadge` color field. Returns nil for empty or malformed input so callers can fall back.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 3 || s.count == 6 || s.count == 8,
              let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: Double
        switch s.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15.0
            g = Double((value >> 4) & 0xF) / 15.0
            b = Double(value & 0xF) / 15.0
            a = 1.0
        case 6:
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        default: // 8: RRGGBBAA
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
