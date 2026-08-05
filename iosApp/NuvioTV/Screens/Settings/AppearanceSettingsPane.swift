import SwiftUI
import SharedCore

/// A titled row of value chips (poster size/corners, card-depth edge/sheen/coverage, FEAT-8's
/// trailer duration, etc.). Hoisted out of `PosterStyleControls` (FEAT-8) to a file-private free
/// function so any section in this file can build the same chip-selector row without duplicating
/// it — `PosterStyleControls` itself just calls this now.
@ViewBuilder
private func controlRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        Text(title)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
        HStack(spacing: Theme.Spacing.md) { content() }
    }
}

/// A single selectable value chip, paired with `controlRow`. Hoisted alongside it (see above).
private func chip(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(label)
            .font(Theme.Font.meta)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xxs + 2)
    }
    .buttonStyle(.chip(selected: selected))
}

/// "Appearance" category content: accent theme, poster card style, card depth effect, and stream
/// badges. Extracted from SettingsView.swift (Phase 2 HIG revamp file split) — logic and wiring
/// preserved verbatim, only regrouped into a per-category pane.
struct AppearanceSettingsPane: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var badges: BadgeSettingsViewModel

    /// Mirrors HomeView's `hero_poster_focus_only` @AppStorage key (same UserDefaults key, read
    /// independently here) so this toggle can flip the Home hero's focus-gated artwork fade back
    /// on for testers who preferred the original behavior. Local-only, not synced.
    @AppStorage("hero_poster_focus_only") private var heroPosterFocusOnly = false
    /// Mirrors DetailView's `detail_trailer_autoplay` key. Local-only, not synced.
    @AppStorage("detail_trailer_autoplay") private var detailTrailerAutoplay = true
    /// Mirrors DetailView's `detail_poster_backdrop` key. Local-only, not synced.
    @AppStorage("detail_poster_backdrop") private var detailPosterBackdrop = true
    /// UX-4b: the muted background trailer on detail pages (distinct from auto-play above).
    @AppStorage("detail_trailer_background") private var detailTrailerBackground = true
    /// FEAT-8: mirrors DetailView's `detail_trailer_duration` key. 0 = play forever.
    @AppStorage("detail_trailer_duration") private var detailTrailerDuration = 0
    /// FEAT-9: mirrors DetailView's `detail_action_icons_only` key.
    @AppStorage("detail_action_icons_only") private var detailActionIconsOnly = false
    /// FEAT-7: mirrors SettingsView's own `settings_style` key (same UserDefaults key, read
    /// independently here) so this pane's chip row and the sidebar it controls stay in sync.
    @AppStorage("settings_style") private var settingsStyle = "default"
    /// FEAT-14: opt-in accent-colored focus ring on artwork cards (PosterCard/LandscapeCard).
    /// Default OFF — off must render byte-identical to the pre-FEAT-14 tree, so PosterCard reads
    /// this same key independently rather than through a passed-down flag.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// BUG-36: opt-in "focus without motion" for artwork cards (PosterCard/LandscapeCard). Default
    /// OFF — off keeps the two existing treatments (system lift, or the accent ring's manual
    /// scale). Same independent-read pattern as the ring above; the cards resolve both keys into a
    /// single `CardFocusMode`.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
            settingsSection(String(localized: "Theme")) {
                Text("The accent color used for focus rings, highlights, and controls. Applies instantly and syncs per profile.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)
                ThemePickerRow(selectedName: model.themeName) { model.setTheme($0) }

                // FEAT-14: opt-in accent focus ring on artwork cards. Default OFF — off renders
                // byte-identical to today (PosterCard/LandscapeCard skip the overlay entirely).
                SettingsToggleRow(
                    title: String(localized: "Accent Focus Ring"),
                    subtitle: accentFocusRing
                        ? String(localized: "On \u{00B7} Focused artwork shows a ring in your accent color")
                        : String(localized: "Off \u{00B7} Focused artwork uses the system highlight only"),
                    isOn: accentFocusRing
                ) {
                    accentFocusRing.toggle()
                }

                // BUG-36 (tester ask, twice): focus on a card lifts and zooms it slightly. This
                // turns the zoom off outright — the card holds its size and marks focus with the
                // ring (or a highlight border when the ring is off) and a shadow instead. Default
                // OFF, so the stock focus motion is unchanged for everyone else.
                SettingsToggleRow(
                    title: String(localized: "No Zoom on Focus"),
                    subtitle: noZoomOnFocus
                        ? String(localized: "On \u{00B7} Focused cards keep their size \u{2014} highlight and shadow only")
                        : String(localized: "Off \u{00B7} Focused cards lift and zoom slightly"),
                    isOn: noZoomOnFocus
                ) {
                    noZoomOnFocus.toggle()
                }

                settingsStyleRow
            }

            settingsSection(String(localized: "Poster Style")) {
                PosterStyleControls(
                    widthDp: model.posterWidthDp,
                    cornerDp: model.posterCornerRadiusDp,
                    hideLabels: model.posterHideLabels,
                    landscapeRows: model.posterLandscapeRows,
                    onSize: { model.setPosterWidth($0) },
                    onCorner: { model.setPosterCorner($0) },
                    onHideLabels: { model.setPosterHideLabels($0) },
                    onLandscape: { model.setPosterLandscapeRows($0) },
                    onReset: { model.resetPosterStyle() }
                )
                // Default (off) always shows the Home hero's backdrop artwork — a beta
                // tester read the old focus-only fade as a bug ("hero posts don't
                // work"). This restores that original fade for anyone who preferred it.
                // BUG-24/UX-1: the old name ("Hero Poster Only When Focused") confused two
                // testers in opposite directions — one asked for the OFF behavior thinking it
                // was missing (UX-1), one reported the toggle "does nothing" while describing
                // exactly what ON does (BUG-24). The name now states the action.
                SettingsToggleRow(
                    title: String(localized: "Hide Hero Artwork While Browsing"),
                    subtitle: heroPosterFocusOnly
                        ? String(localized: "On \u{00B7} Artwork shows while the hero is highlighted and hides once you move down into the rows")
                        : String(localized: "Off \u{00B7} Hero artwork stays visible while you browse"),
                    isOn: heroPosterFocusOnly
                ) {
                    heroPosterFocusOnly.toggle()
                }
                SettingsToggleRow(
                    title: String(localized: "Auto-Play Trailer on Detail"),
                    subtitle: detailTrailerAutoplay
                        ? String(localized: "On \u{00B7} Play the trailer full screen shortly after opening a title")
                        : String(localized: "Off \u{00B7} Trailers only play when selected"),
                    isOn: detailTrailerAutoplay
                ) {
                    detailTrailerAutoplay.toggle()
                }
                // UX-4b (tester ask): the auto-play toggle above never controlled the muted
                // trailer looping BEHIND the detail description — that had no switch at all.
                SettingsToggleRow(
                    title: String(localized: "Background Trailer on Detail"),
                    subtitle: detailTrailerBackground
                        ? String(localized: "On \u{00B7} A muted trailer plays behind the description on detail pages")
                        : String(localized: "Off \u{00B7} Detail pages stay on the still artwork"),
                    isOn: detailTrailerBackground
                ) {
                    detailTrailerBackground.toggle()
                }
                // FEAT-8: only meaningful while the background trailer itself is on.
                if detailTrailerBackground {
                    trailerDurationRow
                }
                SettingsToggleRow(
                    title: String(localized: "Poster in Detail Background"),
                    subtitle: detailPosterBackdrop
                        ? String(localized: "On \u{00B7} Show the title's poster on the right side of detail pages")
                        : String(localized: "Off \u{00B7} Detail pages show only the backdrop"),
                    isOn: detailPosterBackdrop
                ) {
                    detailPosterBackdrop.toggle()
                }
                // FEAT-9
                SettingsToggleRow(
                    title: String(localized: "Icon-Only Detail Buttons"),
                    subtitle: detailActionIconsOnly
                        ? String(localized: "On \u{00B7} Buttons show icons only")
                        : String(localized: "Off \u{00B7} Buttons show text and icons"),
                    isOn: detailActionIconsOnly
                ) {
                    detailActionIconsOnly.toggle()
                }
            }

            settingsSection(String(localized: "Card Depth")) {
                CardDepthControls(
                    style: model.cardDepth,
                    onEnabled: { model.setCardDepthEnabled($0) },
                    onEdge: { model.setCardDepthEdge($0) },
                    onSheen: { model.setCardDepthSheen($0) },
                    onCoverage: { model.setCardDepthCoverage($0) },
                    onSurface: { model.setCardDepthSurface($0, $1) },
                    onReset: { model.resetCardDepth() }
                )
            }

            settingsSection(String(localized: "Stream Badges")) {
                StreamBadgesSection(badges: badges)
            }
        }
    }

    /// FEAT-8: how long the muted background trailer plays before fading back to the still
    /// backdrop. 0 ("Always") is the original play-forever behavior.
    private var trailerDurationRow: some View {
        let options: [(value: Int, label: String)] = [
            (30, String(localized: "30s")),
            (60, String(localized: "1 min")),
            (90, String(localized: "90s")),
            (0, String(localized: "Always")),
        ]
        return controlRow(String(localized: "Trailer Duration")) {
            ForEach(options, id: \.value) { option in
                chip(option.label, selected: detailTrailerDuration == option.value) {
                    detailTrailerDuration = option.value
                }
            }
        }
    }

    /// FEAT-7: Default keeps the sidebar's category icons at normal row height; Minimal drops the
    /// icons and tightens row padding for a denser list. (A third "Top Bar" style was scoped out.)
    private var settingsStyleRow: some View {
        let options: [(value: String, label: String)] = [
            ("default", String(localized: "Default")),
            ("minimal", String(localized: "Minimal")),
        ]
        return controlRow(String(localized: "Settings Style")) {
            ForEach(options, id: \.value) { option in
                chip(option.label, selected: settingsStyle == option.value) {
                    settingsStyle = option.value
                }
            }
        }
    }
}

/// A row of theme swatches (one per shared `AppTheme`); the selected one wears a ring. Swatch
/// colors mirror `AppTheme.nativeAccentHex` (and Theme.Palette.applyTheme's table).
private struct ThemePickerRow: View {
    let selectedName: String
    let onSelect: (AppTheme) -> Void

    private static let options: [(theme: AppTheme, label: String, colorHex: UInt32)] = [
        (.crimson, String(localized: "Crimson"), 0xE53935),
        (.ocean, String(localized: "Ocean"), 0x1E88E5),
        (.violet, String(localized: "Violet"), 0x8E24AA),
        (.emerald, String(localized: "Emerald"), 0x43A047),
        (.amber, String(localized: "Amber"), 0xFB8C00),
        (.rose, String(localized: "Rose"), 0xD81B60),
        (.white, String(localized: "White"), 0xF5F5F5),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(Self.options, id: \.label) { option in
                    Button {
                        onSelect(option.theme)
                    } label: {
                        SwatchLabel(
                            color: Color(hex: option.colorHex),
                            colorHex: option.colorHex,
                            label: option.label,
                            isSelected: option.theme.name == selectedName
                        )
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, Theme.Spacing.sm)
        }
    }
}

/// A single theme swatch: colored circle + name. Selection wears a ring; focus scales the circle
/// and brightens the label (platter-free, mirrors the poster-tile focus language).
private struct SwatchLabel: View {
    let color: Color
    /// Raw hex backing `color`, so the selection ring can pick a shade that stays visible against
    /// it — the White swatch's fill (0xF5F5F5) is close enough to `textPrimary` that a static
    /// near-white ring all but disappeared on it.
    let colorHex: UInt32
    let label: String
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 56, height: 56)
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Theme.Palette.onColor(forFillHex: colorHex) : .clear,
                        lineWidth: 4
                    )
                )
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(
                    isSelected || isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
                )
        }
        .padding(Theme.Spacing.sm)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Poster card style controls: size, corner radius, hide-titles and landscape-rows toggles, and a
/// reset. Values are the shared dp presets (scaled to tvOS points by `PosterStyle`).
private struct PosterStyleControls: View {
    let widthDp: Int32
    let cornerDp: Int32
    let hideLabels: Bool
    let landscapeRows: Bool
    let onSize: (Int32) -> Void
    let onCorner: (Int32) -> Void
    let onHideLabels: (Bool) -> Void
    let onLandscape: (Bool) -> Void
    let onReset: () -> Void

    private let sizes: [(name: String, dp: Int32)] = [
        (String(localized: "Small"), 105), (String(localized: "Medium"), 126), (String(localized: "Large"), 154)
    ]
    private let corners: [(name: String, dp: Int32)] = [
        (String(localized: "Square"), 0), (String(localized: "Rounded"), 12), (String(localized: "Round"), 28)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            controlRow(String(localized: "Size")) {
                ForEach(sizes, id: \.dp) { size in
                    chip(size.name, selected: widthDp == size.dp) { onSize(size.dp) }
                }
            }
            controlRow(String(localized: "Corners")) {
                ForEach(corners, id: \.dp) { corner in
                    chip(corner.name, selected: cornerDp == corner.dp) { onCorner(corner.dp) }
                }
            }

            SettingsToggleRow(title: String(localized: "Hide Titles"), subtitle: String(localized: "Show posters without a title label"), isOn: hideLabels) {
                onHideLabels(!hideLabels)
            }
            SettingsToggleRow(title: String(localized: "Landscape Rows"), subtitle: String(localized: "Show Home & Search catalog rows as wide 16:9 cards"), isOn: landscapeRows) {
                onLandscape(!landscapeRows)
            }

            Button(role: .destructive, action: onReset) {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    .font(Theme.Font.meta)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs + 2)
            }
            .buttonStyle(.chip)
        }
    }
}

/// Card-depth controls: a master toggle, then edge/sheen/coverage strength presets and per-surface
/// enables (progressively revealed once on), plus a reset. Mirrors composeApp's card-depth section;
/// the effect itself is rendered by `View.nuvioCardDepth`. Preset values match the Compose page.
private struct CardDepthControls: View {
    let style: CardDepthStyle
    let onEnabled: (Bool) -> Void
    let onEdge: (Int32) -> Void
    let onSheen: (Int32) -> Void
    let onCoverage: (Int32) -> Void
    let onSurface: (CardDepthSurface, Bool) -> Void
    let onReset: () -> Void

    private let edgeOptions: [(name: String, value: Int32)] = [
        (String(localized: "Subtle"), 28), (String(localized: "Balanced"), 42), (String(localized: "Bold"), 56)
    ]
    private let sheenOptions: [(name: String, value: Int32)] = [
        (String(localized: "Off"), 0), (String(localized: "Soft"), 10), (String(localized: "Bright"), 16)
    ]
    private let coverageOptions: [(name: String, value: Int32)] = [
        (String(localized: "Top"), 0), (String(localized: "Half"), 50), (String(localized: "Full"), 100)
    ]
    private let surfaces: [(name: String, subtitle: String, surface: CardDepthSurface)] = [
        (String(localized: "Posters"), String(localized: "Catalog & search posters"), .posters),
        (String(localized: "Continue Watching"), String(localized: "Home Continue Watching cards"), .continueWatching),
        (String(localized: "Episodes"), String(localized: "Episode thumbnails"), .episodeCards),
        (String(localized: "Cast"), String(localized: "Cast avatars"), .cast),
        (String(localized: "Trailers"), String(localized: "Trailer rows"), .trailers),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Add a raised edge highlight and a glossy top sheen to cards for a little more depth.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)

            SettingsToggleRow(title: String(localized: "Card Depth"), subtitle: String(localized: "Enable the edge highlight and top sheen"), isOn: style.enabled) {
                onEnabled(!style.enabled)
            }

            if style.enabled {
                controlRow(String(localized: "Edge")) {
                    ForEach(edgeOptions, id: \.value) { opt in
                        chip(opt.name, selected: Int32(style.edgeStrength) == opt.value) { onEdge(opt.value) }
                    }
                }
                controlRow(String(localized: "Sheen")) {
                    ForEach(sheenOptions, id: \.value) { opt in
                        chip(opt.name, selected: Int32(style.sheenStrength) == opt.value) { onSheen(opt.value) }
                    }
                }
                controlRow(String(localized: "Edge Coverage")) {
                    ForEach(coverageOptions, id: \.value) { opt in
                        chip(opt.name, selected: Int32(style.edgeCoverage) == opt.value) { onCoverage(opt.value) }
                    }
                }

                Text("Apply To")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                ForEach(surfaces, id: \.name) { entry in
                    SettingsToggleRow(title: entry.name, subtitle: entry.subtitle, isOn: isOn(entry.surface)) {
                        onSurface(entry.surface, !isOn(entry.surface))
                    }
                }
            }

            Button(role: .destructive, action: onReset) {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    .font(Theme.Font.meta)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs + 2)
            }
            .buttonStyle(.chip)
        }
    }

    private func isOn(_ surface: CardDepthSurface) -> Bool {
        switch surface {
        case .posters: return style.postersEnabled
        case .continueWatching: return style.continueWatchingEnabled
        case .episodeCards: return style.episodeCardsEnabled
        case .cast: return style.castEnabled
        case .trailers: return style.trailersEnabled
        }
    }

    @ViewBuilder
    private func controlRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.md) { content() }
        }
    }

    private func chip(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.meta)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xxs + 2)
        }
        .buttonStyle(.chip(selected: selected))
    }
}
