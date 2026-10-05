import SwiftUI
import SharedCore

/// "Appearance" category content: accent theme, poster card style, card depth effect, and stream
/// badges. Extracted from SettingsView.swift (Phase 2 HIG revamp file split) — logic and wiring
/// preserved verbatim, only regrouped into a per-category pane.
///
/// beta.15 §C (C3a): converted onto the native-List Settings kit (SettingsRowViews.swift, C1) —
/// the pane body returns its sections directly (no `VStack(spacing: sectionGap)` wrapper), every
/// toggle binds straight to an @AppStorage/view-model value, and every text-label chip row
/// (Settings Style, Poster Size/Corners, Trailer Duration, Card Depth Edge/Sheen/Coverage) is now
/// a `SettingsPickerRow` menu. The Theme swatches stay a custom row — the kit has no
/// colour-swatch primitive.
struct AppearanceSettingsPane: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var badges: BadgeSettingsViewModel
    /// Swatch to refocus after a theme-change remount; consumed by [ThemePickerRow].
    @Binding var pendingThemeSwatchFocus: String?
    /// FEAT-30/31, H9: which row ("navigation" / "railVisibility" / "typeface") should reclaim
    /// focus after a theme-`.id()`-driven remount; consumed by this pane's own `.onAppear` below,
    /// same contract as `pendingThemeSwatchFocus`/`ThemePickerRow`.
    @Binding var pendingAppearanceRowFocus: String?
    /// Backs the `.focused($appearanceRowFocus, equals:)` modifiers on the Navigation, Rail and
    /// Typeface rows below. `SettingsPickerRow`'s own body is a single `Menu` (see
    /// `SettingsRowViews.swift`), so `.focused` applied to the row view — not to something inside
    /// it — still binds correctly: SwiftUI's `focused(_:equals:)` on a container reports focus
    /// when any focusable descendant (here, the row's `Menu`) has it, and there is exactly one
    /// such descendant per row.
    @FocusState private var appearanceRowFocus: String?

    /// Mirrors HomeView's `hero_poster_focus_only` @AppStorage key (same UserDefaults key, read
    /// independently here) so this toggle can flip the Home hero's focus-gated artwork fade back
    /// on for testers who preferred the original behavior. Local-only, not synced.
    @AppStorage("hero_poster_focus_only") private var heroPosterFocusOnly = false
    /// FEAT-7: mirrors SettingsView's own `settings_style` key (same UserDefaults key, read
    /// independently here) so this pane's chip row and the sidebar it controls stay in sync.
    @AppStorage("settings_style") private var settingsStyle = "default"
    /// H9 (FEAT-45, replacing FEAT-30's Sidebar): device-local key, not synced. Owning reader is
    /// `NavigationChrome` (`TabBarImmersiveHideModifier`, `NavigationRail`) — `"tabs"` (default)
    /// keeps the top tab bar, `"rail"` swaps it for the navigation rail; FEAT-30's stored
    /// `"sidebar"` reads as Rail (and migrates once at launch). Folded into ContentView's `.id`
    /// remount key alongside `theme`/`ui_font`, so writing this key remounts the tree.
    @AppStorage(NavigationChrome.styleKey) private var navigationStyle = NavigationChrome.Style.tabs.rawValue
    /// H9: the rail's visibility, device-local. `"always"` (default) reserves the rail's width on
    /// every page; `"browsing"` floats it and slides it away while browsing. Also part of the `.id`
    /// remount key (it changes every tab root's inset).
    @AppStorage(NavigationChrome.railVisibilityKey) private var railVisibility = NavigationChrome.RailVisibility.always.rawValue
    /// Home Stage & Strip (P3 #22): Hide Hero Artwork While Browsing only means something in
    /// Classic, so the row hides in Stage. Live, like every Home Layout reader.
    @AppStorage(HomeLayout.defaultsKey) private var homeLayoutRaw = HomeLayout.defaultValue.rawValue
    /// FEAT-31: device-local key, not synced. Owning reader is `Theme.Font` (DesignSystem/Theme.swift)
    /// — `"system"` (default) or `"openSans"`. Also folded into ContentView's `.id` remount key, so
    /// writing this key remounts the tree the same way a theme change does.
    @AppStorage(Theme.AppFontFamily.defaultsKey) private var uiFont = Theme.AppFontFamily.system.rawValue
    /// FEAT-14: opt-in accent-colored focus ring on artwork cards (PosterCard/LandscapeCard).
    /// Default OFF — off must render byte-identical to the pre-FEAT-14 tree, so PosterCard reads
    /// this same key independently rather than through a passed-down flag.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// FEAT-46 (rc14, Steven rc13 verdict, 2026-09-30): the accent ring takes the focused poster's
    /// dominant color instead of the accent. Default OFF; only offered while `accentFocusRing` is
    /// on. The card views read this same key independently (same pattern as the ring above).
    @AppStorage("focus_ring_poster_color") private var focusRingPosterColor = false
    /// beta.18 verdict (FEAT-46 corrected / FEAT-40 follow-up): the card-depth edge rail takes each
    /// poster's dominant color instead of white. Default OFF; only offered while Card Depth is on.
    /// The four card views (poster, landscape, saga, folder tile) read this same key independently.
    @AppStorage("depth_rail_poster_color") private var depthRailPosterColor = false
    /// BUG-36: opt-in "focus without motion" for artwork cards (PosterCard/LandscapeCard). Default
    /// OFF — off keeps the two existing treatments (system lift, or the accent ring's manual
    /// scale). Same independent-read pattern as the ring above; the cards resolve both keys into a
    /// single `CardFocusMode`.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    /// beta.19-rc1 verdict (F, FEAT-54): the row edge fade, promoted from the Developer pane's
    /// BUG-118 A/B. Device-local, live: every row's `RowEdgeEffectStyleModifier` reads the same key,
    /// so a change applies at once. Off by default (`RowEdgeFadeSetting.defaultValue`).
    @AppStorage(RowEdgeFadeSetting.defaultsKey) private var rowEdgeFade = RowEdgeFadeSetting.defaultValue.rawValue

    private static let settingsStyleOptions: [(value: String, label: String)] = [
        ("default", String(localized: "Default")),
        ("minimal", String(localized: "Minimal")),
    ]
    /// H9 row options. Values are the raw `sidebar_style` UserDefaults strings (`NavigationChrome
    /// .Style`); the binding below normalises FEAT-30's "sidebar" to "rail" on read.
    private static let navigationOptions: [(value: String, label: String)] = [
        (NavigationChrome.Style.tabs.rawValue, String(localized: "Top Tabs")),
        (NavigationChrome.Style.rail.rawValue, String(localized: "Rail")),
    ]
    /// H9 Rail row options. Values are the raw `rail_visibility` strings.
    private static let railVisibilityOptions: [(value: String, label: String)] = [
        (NavigationChrome.RailVisibility.always.rawValue, String(localized: "Always Visible")),
        (NavigationChrome.RailVisibility.whileBrowsing.rawValue, String(localized: "Hide While Browsing")),
    ]
    /// FEAT-31 row options. Values are `Theme.AppFontFamily.rawValue`, so the picker never drifts
    /// from the type the storage key actually feeds.
    private static let typefaceOptions: [(value: String, label: String)] = Theme.AppFontFamily.allCases.map {
        ($0.rawValue, $0.displayName)
    }

    /// Wraps `navigationStyle` so picking a navigation style arms the focus-restore hint BEFORE the
    /// `@AppStorage` write — the write is what re-identifies ContentView's `.id()`-keyed tree, so
    /// anything set after it belongs to a view already being torn down (same ordering rule as
    /// `pendingThemeSwatchFocus` in `ThemePickerRow.onSelect` above). Normalises on get (P4 §4.1):
    /// a launch-argument "sidebar" shows "Rail", not a blank pill.
    private var navigationStyleBinding: Binding<String> {
        Binding(
            get: { NavigationChrome.style(raw: navigationStyle).rawValue },
            set: { newValue in
                // Codex r2: a re-pick of the current value changes no `.id`, so no remount would
                // consume the hint — it would then steal focus on the next unrelated remount.
                guard newValue != NavigationChrome.style(raw: navigationStyle).rawValue else { return }
                pendingAppearanceRowFocus = "navigation"
                navigationStyle = newValue
            }
        )
    }

    /// Same wrapper for the Rail row (its write remounts the tree too).
    private var railVisibilityBinding: Binding<String> {
        Binding(
            get: { NavigationChrome.railVisibility(raw: railVisibility).rawValue },
            set: { newValue in
                guard newValue != NavigationChrome.railVisibility(raw: railVisibility).rawValue else { return }
                pendingAppearanceRowFocus = "railVisibility"
                railVisibility = newValue
            }
        )
    }

    /// Wraps `uiFont` so selecting a typeface arms the focus-restore hint and applies the family
    /// to `Theme.Font` first, then writes the `@AppStorage` value. Both must precede the state
    /// write deliberately: ContentView's `.id` remount key includes `ui_font`, so the remount that
    /// follows this write must see the tokens already resolved to the new family (and the hint
    /// already armed), not the stale cache from before `apply(_:)` ran.
    private var uiFontBinding: Binding<String> {
        Binding(
            get: { uiFont },
            set: { newValue in
                guard newValue != uiFont else { return }  // Codex r2, same reason as above
                pendingAppearanceRowFocus = "typeface"
                Theme.Font.apply(Theme.AppFontFamily(rawValue: newValue) ?? .system)
                uiFont = newValue
            }
        )
    }

    var body: some View {
        Group {
            content
        }
        .onAppear {
            // FEAT-30/31: mirrors ThemePickerRow's own consumption block above — put focus back
            // on the row the user just picked instead of letting the post-remount focus engine
            // default to the tab bar. No `DispatchQueue.main.async` delay here, matching
            // ThemePickerRow's `.onAppear` (it reads/clears the hint synchronously; it isn't
            // waiting for anything to finish laying out). Cleared immediately so an unrelated
            // later remount, or a fresh entry into Settings, does not steal focus back into
            // Appearance.
            guard let row = pendingAppearanceRowFocus else { return }
            pendingAppearanceRowFocus = nil
            appearanceRowFocus = row
        }
    }

    @ViewBuilder
    private var content: some View {
        SettingsSection(String(localized: "Theme")) {
            Text("The accent color used for focus rings, highlights, and controls. Applies instantly and syncs per profile.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
            ThemePickerRow(
                selectedName: model.themeName,
                pendingFocus: $pendingThemeSwatchFocus
            ) { theme in
                // Only arm the hint for a REAL change: re-picking the current theme publishes
                // nothing, so no remount consumes the hint and it would sit armed until some later
                // entry into Appearance stole focus into the swatch. Record BEFORE the set —
                // setTheme re-identifies the app root, so anything written after it belongs to a
                // view that is already being torn down.
                if theme.name != model.themeName {
                    pendingThemeSwatchFocus = theme.name
                }
                model.setTheme(theme)
            }

            // FEAT-14: opt-in accent focus ring on artwork cards. Default OFF — off renders
            // byte-identical to today (PosterCard/LandscapeCard skip the overlay entirely).
            SettingsToggleRow(
                title: String(localized: "Accent Focus Ring"),
                subtitle: String(localized: "Focused artwork shows a ring in your accent color"),
                isOn: $accentFocusRing,
                descriptionID: .appearanceAccentFocusRing
            )
            // FEAT-46 (rc14, Steven rc13 verdict, 2026-09-30): only meaningful while the ring itself is on.
            // rc14 FEAT-46 — shown whenever a ring can draw (the accent ring, or No Zoom's still
            // ring), since the cards honour the setting for both (review r1 P3).
            if accentFocusRing || noZoomOnFocus {
                SettingsToggleRow(
                    title: String(localized: "Ring Takes Poster Color"),
                    subtitle: String(localized: "The focus ring uses the focused poster's dominant color"),
                    isOn: $focusRingPosterColor,
                    descriptionID: .appearanceRingPosterColor
                )
            }
            // beta.18 verdict (FEAT-46 corrected / FEAT-40 follow-up): "Depth Takes Poster Color".
            // Gated on Card Depth itself: with depth off there is no rail to colour.
            if model.cardDepth.enabled {
                SettingsToggleRow(
                    title: String(localized: "Depth Takes Poster Color"),
                    // review r1 (P3-7): cards already on screen recolor when their artwork reloads.
                    subtitle: String(localized: "Card depth edges take each poster's dominant color as artwork loads"),
                    isOn: $depthRailPosterColor,
                    descriptionID: .appearanceDepthPosterColor
                )
            }

            // F (beta.19-rc1 verdict): No Zoom and Row Edge Fade share one `Group` so this
            // section's builder keeps the ten direct children it had. The Group adds no layout of its
            // own: a `Section` flattens it into two rows.
            Group {
                // BUG-36 (tester ask, twice): focus on a card lifts and zooms it slightly. This
                // turns the zoom off outright — the card holds its size and marks focus with the
                // ring (or a highlight border when the ring is off) and a shadow instead. Default
                // OFF, so the stock focus motion is unchanged for everyone else.
                SettingsToggleRow(
                    title: String(localized: "No Zoom on Focus"),
                    subtitle: String(localized: "Focused cards keep their size \u{2014} highlight and shadow only"),
                    isOn: $noZoomOnFocus,
                    descriptionID: .appearanceNoZoomOnFocus
                )

                // F (Steven beta.19-rc1 verdict, 2026-10-03; FEAT-54): how the left and right edges
                // of rows fade. Soft is the app-drawn eased fade, System is tvOS's own scroll-edge
                // effect, Off draws none (the default since the F.5 frame-time gate). An unknown stored value reads as the default,
                // so the picker always shows one of the three.
                SettingsPickerRow(
                    title: String(localized: "Row Edge Fade"),
                    selection: Binding(
                        get: { RowEdgeFadeSetting.resolve(rowEdgeFade) },
                        set: { rowEdgeFade = $0.rawValue }
                    ),
                    options: RowEdgeFadeSetting.allCases,
                    descriptionID: .appearanceRowEdgeFade,
                    label: { $0.label }
                )
                .accessibilityIdentifier("appearance_row_edge_fade")
            }

            // FEAT-38: pure black background for OLED screens. Backed by
            // `ThemeSettingsRepository.amoledEnabled` (profile-scoped, synced) via
            // `SettingsViewModel.amoledEnabled`/`setAmoled(_:)`; applied to `Theme.Palette.background`
            // by `AppThemeModel`. `surface`/`surfaceElevated` are untouched, so cards keep contrast.
            SettingsToggleRow(
                title: String(localized: "OLED True Black"),
                subtitle: String(localized: "Pure black background for OLED screens"),
                isOn: Binding(
                    get: { model.amoledEnabled },
                    set: { model.setAmoled($0) }
                ),
                descriptionID: .appearanceOledBlack
            )

            // FEAT-7: Default keeps the sidebar's category icons at normal row height; Minimal
            // drops the icons and tightens row padding for a denser list. (A third "Top Bar"
            // style was scoped out.)
            SettingsPickerRow(
                title: String(localized: "Settings Style"),
                selection: $settingsStyle,
                options: Self.settingsStyleOptions.map(\.value),
                descriptionID: .appearanceSettingsStyle,
                label: { value in Self.settingsStyleOptions.first { $0.value == value }?.label ?? value }
            )

            // H9 (FEAT-45): Top Tabs or the navigation rail, plus the Rail row directly below it,
            // shown only with Rail. One `Group`, so this section's builder keeps the ten direct
            // children it had (the Row Edge Fade group above follows the same rule). Default
            // "tabs" is byte-identical to today.
            Group {
                SettingsPickerRow(
                    title: String(localized: "Navigation"),
                    subtitle: String(localized: "Rail swaps the top tab bar for a column of icons on the left."),
                    selection: navigationStyleBinding,
                    options: Self.navigationOptions.map(\.value),
                    descriptionID: .appearanceNavigation,
                    label: { value in Self.navigationOptions.first { $0.value == value }?.label ?? value }
                )
                .accessibilityIdentifier("appearance_row_navigation")
                .focused($appearanceRowFocus, equals: "navigation")

                if NavigationChrome.style(raw: navigationStyle) == .rail {
                    SettingsPickerRow(
                        title: String(localized: "Rail"),
                        selection: railVisibilityBinding,
                        options: Self.railVisibilityOptions.map(\.value),
                        descriptionID: .appearanceRail,
                        label: { value in Self.railVisibilityOptions.first { $0.value == value }?.label ?? value }
                    )
                    .accessibilityIdentifier("appearance_row_rail")
                    .focused($appearanceRowFocus, equals: "railVisibility")
                }
            }

            // FEAT-31: opt-in Open Sans typeface. The binding's setter applies the font family
            // BEFORE writing `uiFont` — ContentView's `.id` remount key reads `ui_font` from
            // UserDefaults, so the resolved-font cache (Theme.Font.apply) must already reflect the
            // new family by the time that remount observes the write, not after.
            SettingsPickerRow(
                title: String(localized: "Typeface"),
                selection: uiFontBinding,
                options: Self.typefaceOptions.map(\.value),
                descriptionID: .appearanceTypeface,
                label: { value in Self.typefaceOptions.first { $0.value == value }?.label ?? value }
            )
            .accessibilityIdentifier("appearance_row_typeface")
            .focused($appearanceRowFocus, equals: "typeface")
        }

        SettingsSection(String(localized: "Poster Style")) {
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
            // Home Stage & Strip (P3 #22): Classic only — Stage has no hero carousel to fade.
            if HomeLayout.resolve(homeLayoutRaw) == .classic {
                SettingsToggleRow(
                    title: String(localized: "Hide Hero Artwork While Browsing"),
                    subtitle: String(localized: "Artwork shows while the hero is highlighted and hides once you move down into the rows"),
                    isOn: $heroPosterFocusOnly,
                    descriptionID: .appearanceHideHeroArtwork
                )
            }
        }

        SettingsSection(String(localized: "Custom Posters")) {
            SettingsLinkRow(
                title: String(localized: "Custom Posters"),
                subtitle: String(localized: "Use a poster service like RPDB for artwork."),
                systemImage: "photo.on.rectangle",
                descriptionID: .appearanceCustomPosters
            ) {
                CustomPostersSettingsView()
            }
        }

        SettingsSection(String(localized: "Card Depth")) {
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

        SettingsSection(String(localized: "Stream Badges")) {
            StreamBadgesSection(badges: badges)
        }
    }
}

/// A row of theme swatches (one per shared `AppTheme`); the selected one wears a ring. Swatch
/// colors mirror `AppTheme.nativeAccentHex` (and Theme.Palette.applyTheme's table).
private struct ThemePickerRow: View {
    let selectedName: String
    @Binding var pendingFocus: String?
    let onSelect: (AppTheme) -> Void

    @FocusState private var focusedSwatch: String?

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
                    .focused($focusedSwatch, equals: option.label)
                }
            }
            .padding(.vertical, Theme.Spacing.sm)
        }
        .onAppear {
            // The press remounted the tree; put focus back where the user left it instead of
            // letting the focus engine default to the tab bar. Cleared immediately so an
            // unrelated later remount (or a fresh entry into Settings) does not grab focus.
            guard let pending = pendingFocus else { return }
            pendingFocus = nil
            focusedSwatch = Self.options.first { $0.theme.name == pending }?.label
        }
    }
}

/// A single theme swatch: colored circle + name. Selection wears a full-strength ring; focus
/// wears a slightly lighter ring in the same swatch-contrast color and brightens the label
/// (platter-free — `.borderless` gives only the system lift, no scale of our own). BUG-65: the
/// focused state used to be label-brightening alone, which the reporter couldn't see; the ring
/// makes focus self-describing on every swatch including White (`onColor(forFillHex:)` picks a
/// shade that contrasts the fill, so it can never vanish into it).
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
                        isSelected
                            ? Theme.Palette.onColor(forFillHex: colorHex)
                            : (isFocused ? Theme.Palette.onColor(forFillHex: colorHex).opacity(0.8) : .clear),
                        lineWidth: isSelected ? 4 : 3
                    )
                )
            Text(label)
                .font(Theme.Font.caption)
                // BUG-58 (beta.11 regression from the BUG-50 sweep, device-verified from
                // Christian's clip 2026-08-16): the sweep assumed this `.borderless` button drew
                // the white system focus platter and painted the focused label
                // `onFocusPlatter` (near-black). It doesn't — `.borderless` on tvOS is
                // platter-free (lift only), so the "on-platter" black text landed straight on
                // the dark pane and the focused swatch's name vanished ("Amber" disappears while
                // it has focus). Same shape as ProfileSelectionView's borderless avatar tiles:
                // focus BRIGHTENS the label; selection reads primary at rest.
                .foregroundStyle(
                    (isFocused || isSelected) ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
                )
        }
        .padding(Theme.Spacing.sm)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        // All seven swatches share one id/title, so walking them publishes to the explainer once.
        .settingsDescription(.appearanceTheme, title: String(localized: "Theme"), systemImage: "paintpalette")
    }
}

/// Poster card style controls: size, corner radius, hide-titles and landscape-rows toggles, and a
/// reset. Values are the shared dp presets (scaled to tvOS points by `PosterStyle`).
///
/// C3a: Size and Corners were text-label chip rows — both are now `SettingsPickerRow` menus; the
/// destructive reset button is now `SettingsDestructiveRow`.
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

    // FEAT-39 (u/mrStevenx3, 2026-09-11): "Large is too big, Medium too small" — 134 dp is the
    // mobile app's own "comfort" preset, so the synced payload stays legal on both platforms;
    // above 335 pt it takes the Large hero-compression dial (see `PinnedRowGeometry`), so it
    // trades one description line for the size.
    private let sizes: [(name: String, dp: Int32)] = [
        (String(localized: "Small"), 105), (String(localized: "Medium"), 126),
        (String(localized: "Medium+"), 134), (String(localized: "Large"), 154)
    ]
    private let corners: [(name: String, dp: Int32)] = [
        (String(localized: "Square"), 0), (String(localized: "Rounded"), 12), (String(localized: "Round"), 28)
    ]

    var body: some View {
        SettingsPickerRow(
            title: String(localized: "Size"),
            selection: Binding(get: { widthDp }, set: { onSize($0) }),
            options: sizes.map(\.dp),
            descriptionID: .appearancePosterSize,
            label: { dp in sizes.first { $0.dp == dp }?.name ?? "\(dp)" }
        )
        SettingsPickerRow(
            title: String(localized: "Corners"),
            selection: Binding(get: { cornerDp }, set: { onCorner($0) }),
            options: corners.map(\.dp),
            descriptionID: .appearancePosterCorners,
            label: { dp in corners.first { $0.dp == dp }?.name ?? "\(dp)" }
        )

        SettingsToggleRow(
            title: String(localized: "Hide Titles"),
            subtitle: String(localized: "Show posters without a title label"),
            isOn: Binding(get: { hideLabels }, set: { onHideLabels($0) }),
            descriptionID: .appearanceHideTitles
        )
        SettingsToggleRow(
            title: String(localized: "Landscape Rows"),
            subtitle: String(localized: "Show Home & Search catalog rows as wide 16:9 cards"),
            isOn: Binding(get: { landscapeRows }, set: { onLandscape($0) }),
            descriptionID: .appearanceLandscapeRows
        )

        SettingsDestructiveRow(title: String(localized: "Reset to Defaults"), systemImage: "arrow.counterclockwise", descriptionID: .appearancePosterReset, action: onReset)
    }
}

/// Card-depth controls: a master toggle, then edge/sheen/coverage strength presets and per-surface
/// enables (progressively revealed once on), plus a reset. Mirrors composeApp's card-depth section;
/// the effect itself is rendered by `View.nuvioCardDepth`. Preset values match the Compose page.
///
/// C3a: Edge/Sheen/Coverage were text-label chip rows — all three are now `SettingsPickerRow`
/// menus; the destructive reset button is now `SettingsDestructiveRow`.
private struct CardDepthControls: View {
    let style: CardDepthStyle
    let onEnabled: (Bool) -> Void
    let onEdge: (Int32) -> Void
    let onSheen: (Int32) -> Void
    let onCoverage: (Int32) -> Void
    let onSurface: (CardDepthSurface, Bool) -> Void
    let onReset: () -> Void

    // BUG-110 (rc12): "Off" leads the list so the strength picker itself can switch the rail off
    // without touching the master "Card Depth" toggle (which also silences the sheen). `0` was
    // already a legal synced value — the picker just never offered it — so this is additive: no
    // reset-default or storage-contract change (`CardDepthStyle.edgeStrength` still defaults to 28).
    // Reuses the "Off" string `sheenOptions` below already carries; xcstrings has one shared entry
    // for both (confirmed translated in all 5 locales), so no new key was needed.
    private let edgeOptions: [(name: String, value: Int32)] = [
        (String(localized: "Off"), 0),
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
        Text("Add a raised edge highlight and a glossy top sheen to cards for a little more depth.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)

        SettingsToggleRow(
            title: String(localized: "Card Depth"),
            subtitle: String(localized: "Enable the edge highlight and top sheen"),
            isOn: Binding(get: { style.enabled }, set: { onEnabled($0) }),
            descriptionID: .appearanceCardDepth
        )

        if style.enabled {
            SettingsPickerRow(
                title: String(localized: "Edge"),
                selection: Binding(get: { Int32(style.edgeStrength) }, set: { onEdge($0) }),
                options: edgeOptions.map(\.value),
                descriptionID: .appearanceCardDepthEdge,
                label: { value in edgeOptions.first { $0.value == value }?.name ?? "\(value)" }
            )
            SettingsPickerRow(
                title: String(localized: "Sheen"),
                selection: Binding(get: { Int32(style.sheenStrength) }, set: { onSheen($0) }),
                options: sheenOptions.map(\.value),
                descriptionID: .appearanceCardDepthSheen,
                label: { value in sheenOptions.first { $0.value == value }?.name ?? "\(value)" }
            )
            SettingsPickerRow(
                title: String(localized: "Edge Coverage"),
                selection: Binding(get: { Int32(style.edgeCoverage) }, set: { onCoverage($0) }),
                options: coverageOptions.map(\.value),
                descriptionID: .appearanceCardDepthCoverage,
                label: { value in coverageOptions.first { $0.value == value }?.name ?? "\(value)" }
            )

            Text("Apply To")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            ForEach(surfaces, id: \.name) { entry in
                SettingsToggleRow(
                    title: entry.name,
                    subtitle: entry.subtitle,
                    isOn: Binding(get: { isOn(entry.surface) }, set: { onSurface(entry.surface, $0) }),
                    descriptionID: .appearanceCardDepthSurface
                )
            }
        }

        SettingsDestructiveRow(title: String(localized: "Reset to Defaults"), systemImage: "arrow.counterclockwise", descriptionID: .appearanceCardDepthReset, action: onReset)
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
}
