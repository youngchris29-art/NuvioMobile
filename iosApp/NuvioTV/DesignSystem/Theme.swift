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

        /// Retints the palette for a shared `AppTheme` (by enum name). Accents mirror mobile's
        /// `ThemeColors.kt` (`AppTheme.nativeAccentHex`), with a brighter focus variant per theme.
        static func applyTheme(named name: String) {
            switch name {
            case "OCEAN":   accent = Color(hex: 0x1E88E5); accentFocus = Color(hex: 0x42A5F5)
            case "VIOLET":  accent = Color(hex: 0x8E24AA); accentFocus = Color(hex: 0xAB47BC)
            case "EMERALD": accent = Color(hex: 0x43A047); accentFocus = Color(hex: 0x66BB6A)
            case "AMBER":   accent = Color(hex: 0xFB8C00); accentFocus = Color(hex: 0xFFA726)
            case "ROSE":    accent = Color(hex: 0xD81B60); accentFocus = Color(hex: 0xEC407A)
            case "WHITE":   accent = Color(hex: 0xF5F5F5); accentFocus = Color(hex: 0xFFFFFF)
            default:        accent = Color(hex: 0xE53935); accentFocus = Color(hex: 0xFF5252) // CRIMSON
            }
        }
        /// Primary text on dark backgrounds.
        static let textPrimary = Color(hex: 0xF5F7F8)
        /// Secondary / muted text.
        static let textSecondary = Color(hex: 0x969CA3)
        /// Hairline / outline color.
        static let outline = Color(hex: 0x252A2A)
        /// Rating star.
        static let star = Color(hex: 0xFFC857)
        /// Progress bar fill (continue watching).
        static let progress = Color(hex: 0xFF5252)
    }

    // MARK: - Typography (sized for the 10-foot "lean-back" UI)

    enum Font {
        static let hero = SwiftUI.Font.system(size: 52, weight: .bold)
        static let screenTitle = SwiftUI.Font.system(size: 48, weight: .bold)
        static let sectionTitle = SwiftUI.Font.system(size: 30, weight: .semibold)
        static let cardTitle = SwiftUI.Font.system(size: 24, weight: .regular)
        static let body = SwiftUI.Font.system(size: 28, weight: .regular)
        static let meta = SwiftUI.Font.system(size: 26, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 22, weight: .regular)
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
        /// (logo + meta + synopsis), so advancing the hero can never reflow the rows below it —
        /// that reflow was the visible "glitch" on every 8s auto-advance. Sized to the summed
        /// slots + paddings with a little headroom for the focused card lift.
        static let heroCarouselHeight: CGFloat = 344
        /// Fixed logo/title slot inside a hero page (bottom-aligned; image fits within it).
        static let heroLogoSlotHeight: CGFloat = 150
        static let heroLogoMaxWidth: CGFloat = 520
        /// Fixed single-line metadata slot inside a hero page.
        static let heroMetaSlotHeight: CGFloat = 32
        /// Fixed two-line synopsis slot inside a hero page.
        static let heroSynopsisSlotHeight: CGFloat = 72
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
