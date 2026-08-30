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
        /// Raw hex backing `accentFocus`, set alongside it in `applyTheme`. FEAT-14 needs the
        /// hex (not just the `Color`) to run it through `focusRingHex(accentFocusHex:)` for the
        /// opt-in accent focus ring on artwork cards. Defaults to CRIMSON's focus hex, matching
        /// `accentFocus`'s own default above.
        nonisolated(unsafe) static var accentFocusHex = "FF5252"

        /// Retints the palette for a shared `AppTheme` (by enum name). Accents mirror mobile's
        /// `ThemeColors.kt` (`AppTheme.nativeAccentHex`), with a brighter focus variant per theme.
        static func applyTheme(named name: String) {
            let accentHex: UInt32
            let focusHex: UInt32
            switch name {
            case "OCEAN":   accentHex = 0x1E88E5; focusHex = 0x42A5F5
            case "VIOLET":  accentHex = 0x8E24AA; focusHex = 0xAB47BC
            case "EMERALD": accentHex = 0x43A047; focusHex = 0x66BB6A
            case "AMBER":   accentHex = 0xFB8C00; focusHex = 0xFFA726
            case "ROSE":    accentHex = 0xD81B60; focusHex = 0xEC407A
            case "WHITE":   accentHex = 0xF5F5F5; focusHex = 0xFFFFFF
            default:        accentHex = 0xE53935; focusHex = 0xFF5252 // CRIMSON
            }
            accent = Color(hex: accentHex)
            accentFocus = Color(hex: focusHex)
            accentFocusHex = String(format: "%06X", focusHex)
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
            default: // 8: AARRGGBB — Android/Compose convention, matching `Color(hexString:)`.
                // BUG-43: reading these bytes as RRGGBBAA fed the contrast guards a luminance
                // computed from the WRONG channels (alpha in, blue out) for every 8-digit pack
                // color — see the parity note in `Color(hexString:)`.
                r = Double((value >> 16) & 0xFF) / 255.0
                g = Double((value >> 8) & 0xFF) / 255.0
                b = Double(value & 0xFF) / 255.0
            }
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        /// FEAT-14: decides the accent focus ring's actual draw color, given the current theme's
        /// `accentFocus` hex. Originally mirrored BUG-28's `onColor(forFillHex:)` — a luminance
        /// threshold routed near-white hexes to a fixed dark fallback ("1A1A1A") so they wouldn't
        /// vanish against the system focus platter/lift brightness. BUG-40 (beta feedback): that
        /// reasoning doesn't hold for the ring, this function's only caller (`focusRingColor` in
        /// `PosterCard.swift`). Ring mode never puts artwork under the system platter — it swaps
        /// out `.hoverEffect(.highlight)` for a manual `.scaleEffect` (`CardFocusTreatment`, also
        /// in `PosterCard.swift`) specifically so the ring is the only focus indicator drawn, and
        /// it carries its own stroke over the artwork rather than a fill needing on-light-fill
        /// text contrast. So a user who picks the White theme and turns the ring on should see a
        /// white ring, not a grey one. No dark fallback: the ring always draws in the theme's own
        /// focus color.
        static func focusRingHex(accentFocusHex: String) -> String {
            accentFocusHex
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
        /// Card titles under posters (was fixed 24pt → caption2, 23pt).
        static let cardTitle = SwiftUI.Font.caption2
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
        /// `heroForegroundTopPad`'s lower-third placement). Currently unreferenced: the
        /// Nuvio-style hero is pinned above the rows now and uses the compacted
        /// `heroPinnedTopPad` instead. Kept as the in-scroll Nuvio value in case that layout
        /// comes back.
        static let heroForegroundTopPadNuvio: CGFloat = 120
        /// Width of the right-anchored artwork panel in the Nuvio-style hero (tvOS layout is
        /// a fixed 1920pt canvas). Its left ~30% fades out via a gradient mask, so the flat
        /// background region behind the 680pt info panel meets the art in a smooth blend.
        static let heroNuvioArtworkWidth: CGFloat = 1250
        // Pinned Nuvio hero (UX-7 extension): when the Nuvio-style hero is pinned above the rows
        // (a VStack split — hero fixed on top, rows ScrollView takes the remainder) the two share
        // ONE 1080pt screen instead of the hero scrolling away, so the hero region has to be
        // compacted. Height budget, measured in the sim:
        //   ~76 tab-bar safe area + 8 top pad + ~490 carousel (452 + page dots) + 0 gap ≈ 574,
        // leaving ~506pt for the rows viewport. A default poster row's FOCUS FRAME is
        //   72 top reach + 330 poster + 16 gap + ~28 caption + 48 bottom reach ≈ 494 ≤ 506 —
        // both reaches must fit INSIDE the viewport or the focus engine can't reveal the whole
        // frame and rest positions degrade. Oversized user Poster Style settings can exceed the
        // budget; that degrades to partially-revealed frames (art-edge cuts), same as before the
        // reaches existed. Shrink these only against that budget. Classic is untouched: it
        // keeps `heroForegroundTopPad`, and `heroCarouselHeight` is shared by both layouts.
        /// Compact pinned-hero slots (device round 6): the full 452pt carousel left the rows
        /// viewport at ~506pt, and a reach-extended row focus frame (~490) PLUS the focus
        /// engine's own reveal margin (~60, device-measured) did not fit — unsatisfiable
        /// reveals produced stuck rests, cut captions, and trapped focus. The pinned hero
        /// renders a COMPACT foreground instead (smaller logo slot, 2-line synopsis, tighter
        /// vertical padding): content = 16 + (110 logo + 16 + 32 meta + 16 + 72 synopsis) +
        /// 16 + 56 CTA + 16 ≈ 350 → frame 352, freeing ~100pt (rows viewport ≈ 606).
        /// Classic keeps the full-size slots everywhere.
        static let heroCarouselHeightPinned: CGFloat = 352
        static let heroLogoSlotHeightPinned: CGFloat = 110
        /// 2-line synopsis in the compact pinned hero (3 lines in full Nuvio).
        static let heroSynopsisSlotHeightPinned: CGFloat = 72
        /// Top padding above the PINNED hero header (pinned Nuvio mode only — the classic
        /// in-scroll layout keeps `heroForegroundTopPad`).
        static let heroPinnedTopPad: CGFloat = 8
        /// Gap between the pinned hero header and the top of the rows ScrollView below it.
        /// 0: the page-dots row inside the carousel already carries its own whitespace.
        static let heroPinnedRowsGap: CGFloat = 10
        /// Top content inset INSIDE the pinned rows ScrollView. Small: the real protection
        /// against device rest-position error lives per-row in `heroPinnedRowTopPad` (below) —
        /// this only sets where row 1 rests at true top (8 + 88; with the original 72 reach,
        /// 8 + 72 ≈ the 80 the round-2 fix used).
        static let heroPinnedRowsHeadroom: CGFloat = 8
        /// Per-row top band in the PINNED rows list (replaces the LazyVStack's sectionGap in
        /// pinned mode, which drops to 0), AND the `rowCardTopReach` each row card extends its
        /// focusable frame upward by in pinned mode (see BrowseComponents). Device rounds 1–4
        /// of the pinned-hero pass (2026-08-03): hardware rests the focus engine's
        /// scroll-to-reveal systematically high (BUG-30 residual class; every tvOS scroll is
        /// reveal-driven — swipes drive focus, there is no free momentum scrolling), and the
        /// pinned clip edge turned that into cropped poster tops / bisected titles. Padding
        /// OUTSIDE the card frame can never fix that (the reveal target excludes it — rounds
        /// 2–3 proved it on device); the card frames themselves reach up through this band, so
        /// the reveal always includes the section title. Also the row-to-row visual gap in
        /// pinned mode (88 vs classic's 48 sectionGap — slightly airier by design).
        ///
        /// BUG-53 (2026-08-11 device pass): 72 → 88. On the beta.12 build rests are
        /// deterministic — every settled rest parks the slid title bottom EXACTLY at the
        /// artwork top, zero slack — so the system `hoverEffect(.highlight)` lift (~10–16pt)
        /// on a row's leftmost cards clipped the title. Widening the band (and with it the
        /// reach — deliberately coupled: a reach larger than the band would overlap the
        /// previous row's focus frames) to 88 gives the parked title a 16pt cushion above
        /// the art. Reach is the most regression-prone dial (the sim bisected reach 100 =
        /// focus resolution dies outright; 72 was the long-proven value): any focus
        /// hesitation or missed navigation on device means reverting to 72.
        static let heroPinnedRowTopPad: CGFloat = 88
        /// Downward card reach in pinned mode (device round 5): scrolling DOWN, the reveal
        /// rests short in the mirror direction, leaving the focused card's caption — and up to
        /// ~40pt of art — below the fold. Extending the focus frame down by this much makes the
        /// reveal pull the row fully above the fold even with that shortfall. Smaller than the
        /// top reach because there is no title band to cover below, only the rest error.
        static let heroPinnedRowBottomReach: CGFloat = 44
        /// Top inset of the section title OVERLAID inside a pinned row's reach band (the title
        /// floats over the transparent region the cards' focus frames cover, so the engine's
        /// reveal always shows it). Band above the art = shelf padding (24) + top reach (88)
        /// = 112; the title (~40) sits at this inset with a ~24pt static gap to the art
        /// (~12pt back when the reach was 72/band 96) so that the distance from the button
        /// frame's top to the title's top exceeds the device's measured reveal residual — a
        /// full-residual rest still shows the whole title. Reach history: 72 was the
        /// long-proven value (the sim freeze bisected to reach 100, where focus resolution
        /// dies); raised to 88 for BUG-53 — see `heroPinnedRowTopPad`.
        ///
        /// BUG-37 CORRECTION (2026-08-05): that "~48pt" was the inset read against the wrong
        /// anchor. The overlay is attached to the SHELF (the horizontal ScrollView), whose top is
        /// where this inset is measured from, while the card's focusable frame — the thing the
        /// engine's scroll-to-reveal actually aligns — starts `Spacing.lg` (24) further down,
        /// inside the shelf's own vertical padding. The real button-top→title-top margin is
        /// 48 − 24 = **24pt**, roughly half the device's 40–67pt rest envelope, which is exactly
        /// why titles still vanish on hardware while the sim looks correct. The inset itself is
        /// left alone (it is the resting look device round 8 signed off); the shortfall is
        /// absorbed by the slide below.
        static let heroPinnedRowTitleInset: CGFloat = 48
        /// BUG-37 (2026-08-05): how far the overlaid title may ride DOWN to stay inside the rows
        /// viewport when the device rests short of the reveal target.
        ///
        /// No static inset can cover the envelope. The whole band above the art is
        /// shelf padding (24) + reach (88) = 112pt and the title is ~40pt tall, so the largest
        /// static button-top→title-top margin the band can offer is 112 − 40 − 24 = 48pt —
        /// at the time of measurement (reach 72, band 96, margin 32pt) under the 40–67pt error
        /// either way, whether the title hangs off the shelf (today) or off the card frame.
        /// Widening the band further means a reach approaching 100, the sim-bisected value
        /// where focus resolution dies outright, so that door is shut too. (The 40–67pt
        /// envelope itself no longer reproduces on beta.12 — rests are deterministic — but
        /// the slide stays: it is what parks the title at the clip edge at every rest.)
        /// Hence a render-time slide (`pinnedRowTitleTracking`, BrowseComponents) with this
        /// clamp: 72 covers the full 0–67pt envelope on top of the 24pt static margin, and bounds
        /// how far a deeply-clipped row's title may ride over its own artwork (worst case ~62pt
        /// of a 330pt poster, at rests where the clip edge is cutting that art anyway).
        static let heroPinnedRowTitleMaxSlide: CGFloat = 72
        /// Wave 4 item 6 (tester report, `docs/steven-batch-plan-2026-08-29.md`): how much of a
        /// row's ARTWORK a slid title may cover, as a fraction of that artwork's height.
        ///
        /// `heroPinnedRowTitleMaxSlide` bounds the SLIDE; what the viewer actually judges is the
        /// INTRUSION — how far the title's bottom edge ends up PAST the artwork's top edge. At a
        /// settled rest the title's bottom sits `(Spacing.lg + heroPinnedRowTopPad) −
        /// (heroPinnedRowTitleInset + titleHeight)` = (24 + 88) − (48 + ~38) ≈ **26pt** above the
        /// art, so a full 72pt slide intrudes ≈ **46pt**. That 46 is a FIXED number measured
        /// against a SCALED card:
        ///
        ///     Poster Size       artwork height              46pt intrusion
        ///     Small  (105 dp)   275pt (183 × 1.5)           16.7%
        ///     Medium (126 dp)   330pt                       13.9%
        ///     Large  (154 dp)   403pt                       11.4%
        ///     Landscape rows    203pt                       22.7%
        ///     Folder tile,      183pt (square/16:9 folder   25.1%  ← the tester's
        ///       Small             tiles take their height           "Streaming Services" row
        ///                         from `style.width`)
        ///
        /// A poster's top sixth is usually empty margin, so the fixed cap reads as harmless there;
        /// a folder tile's is not — square/landscape folder covers are CENTRED WORDMARKS on a short
        /// tile, so the same 46pt lands on the only thing the tile exists to show.
        ///
        /// 9% is the budget: under the ~10% top band that stays visually empty on virtually all
        /// poster art, and never tighter than the ~26pt of static clearance a deterministic beta.12
        /// rest needs — the resolved cap is `clearance + budget` (see `PinnedRowTitle.maxSlide`),
        /// so a settled rest, which parks the title's bottom exactly at the artwork's top edge, is
        /// unchanged at every Poster Size. Only deeply-clipped rows (mid-scroll, or a row well
        /// above the focused one) give up slide, and those are rows whose art the clip edge is
        /// cutting anyway.
        static let heroPinnedRowTitleArtIntrusionFraction: CGFloat = 0.09
        /// Allowance for the SYSTEM focus lift, in points — how far a focused card's artwork rises
        /// above its resting top under `CardFocusMode.systemLift`, and therefore how much deeper a
        /// slid title cuts into the art the viewer is actually looking at.
        ///
        /// Pixel-measured on the FA87 sim fixture (2026-08-30) and — the part that matters —
        /// measured as the SAME ~20pt at Medium AND at Large. It is deliberately NOT derived from
        /// `cardSystemLiftScale`: the SYSTEM hover effect's rise does not grow with the card, which
        /// is precisely why the rc1 report ("titles continue to overlap the posters … only at
        /// Large") is not a lift problem and why nothing here is allowed to become a reason to
        /// touch that constant.
        ///
        /// This is ONE of three cases. `PinnedRowTitle.focusLiftAllowance` (BrowseComponents)
        /// resolves the active focus mode the same way `CardFocusMode.resolve` does and returns 0
        /// for "No Zoom on Focus" (Wave 7 made that genuinely zero-lift) or a scale-derived rise
        /// for ring mode; this constant is the default mode's value. Nothing lays out against it —
        /// it feeds the settle re-reveal's correction budget, the visibility belt's threshold, and
        /// the `intrLifted=` probe field.
        static let heroPinnedRowFocusLiftAllowance: CGFloat = 20
        /// Hard ceiling on ONE settle re-reveal correction (`PinnedRowSettle`, BrowseComponents).
        ///
        /// The measured Large failure needs ~90pt (sim probe 2026-08-30: `margin=-86..-100`,
        /// `slide=72` saturated, `net` negative). 220 leaves generous room for a taller card or
        /// text configuration while making it impossible for one bad measurement to fling the
        /// page: a correction larger than this is a broken measurement, not a rest worth chasing.
        static let heroPinnedRowSettleMaxNudge: CGFloat = 220
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
        default: // 8: AARRGGBB — see the BUG-43 note below.
            // BUG-43 (beta.12): every 8-digit hex this app parses is a CROSS-PLATFORM string
            // (badge packs, synced avatar colors) authored in the Android/Compose convention,
            // which mobile reads as AARRGGBB (`StreamBadgeChip.kt`: `8 -> hex`,
            // `6 -> "FF$hex"`). Reading RRGGBBAA here turned an opaque `#FF1A1A1A` chip
            // (dark on mobile) into a ~10%-alpha light ghost on tvOS — the "language badge
            // renders in the light theme" report — and fed garbage luminance into the BUG-28/43
            // contrast guards, which is why the guard-side fix alone never took.
            a = Double((value >> 24) & 0xFF) / 255.0
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
