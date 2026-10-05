import SwiftUI
import SharedCore

/// "Home Screen" category content: hero banner + hero sources, inline trailer previews, catalog
/// type labels, and the Home Rows enable/reorder list. Extracted from SettingsView.swift (Phase 2
/// HIG revamp file split) — logic and wiring preserved verbatim, only regrouped into a
/// per-category pane.
///
/// 2026-08-30 fix: "Hero Sources" and "Catalogs" used to be single composite child views
/// (`HeroSourcesGroup`/`HomeCatalogsGroup`), each rendering a disclosure header PLUS every
/// expanded row inside its own body. Because every direct child of `SettingsSection` here is ONE
/// tvOS `List` row, and a `List` row exposes exactly ONE focus target, that made every expanded
/// toggle row and every catalog chip permanently unreachable — down from an expanded header
/// skipped straight to the next section row, and right did nothing. This is the root cause behind
/// the beta tester's repeated "impossible to select the catalogs for the home page or the Hero"
/// report across three betas (reproduced in the simulator 2026-08-29/30). The fix hoists every
/// expanded row to be a direct `SettingsSection` child in its own right — see the per-view
/// comments below for what that retired.
///
/// Home Stage & Strip (H8, 2026-10-05): a new first "Layout" section holds the Home Layout picker
/// (Stage by default, Classic = the previous Home) and, in Stage only, the Ambient Background
/// switch. Stage has no rotating banner, so it hides the four rows that only configure one: Show
/// Hero, Nuvio-Style Hero, Hero Sources and Autoplay Hero Trailer. Their stored values are never
/// touched; they simply do nothing in Stage and are back as they were when the layout returns to
/// Classic. Trailer Location reads Background / In Row in Stage (the stage always exists, so
/// Background always takes effect) and keeps today's Hero / Poster wording and captions in
/// Classic. Upcoming Episodes, Catalogs and Show Catalog Type are the same in both layouts.
struct HomeScreenSettingsPane: View {
    @ObservedObject var model: SettingsViewModel

    /// Home Stage & Strip (H1): which Home the viewer gets, `HomeLayout.rawValue` ("stage" |
    /// "classic"). Device-local, not synced; HomeView and the folder page read the same key live
    /// through `HomeLayout`, so the flip applies as soon as the picker writes it. An unset or
    /// unknown value reads as the default (Stage).
    @AppStorage(HomeLayout.defaultsKey) private var homeLayoutRaw = HomeLayout.defaultValue.rawValue

    /// Home Stage & Strip (H3): the soft wash of the focused title's colors behind the stage.
    /// Default ON. Local-only, not synced; the wash layer reads the same key
    /// (`AmbientWashSetting`). Only offered while Home Layout is Stage.
    @AppStorage(AmbientWashSetting.defaultsKey) private var ambientBackground = AmbientWashSetting.defaultValue

    /// Mirrors the poster-card's `inline_trailers_enabled` key (BrowseComponents.swift) so this
    /// toggle can turn off the muted trailer-on-focus preview. Local-only, not synced.
    @AppStorage("inline_trailers_enabled") private var inlineTrailersEnabled = false

    /// Mirrors HomeHeroForeground's `hero_nuvio_style` key (UX-2 hero redesign v2, opt-in —
    /// classic layout is the default). Local-only.
    @AppStorage("hero_nuvio_style") private var heroNuvioStyle = false

    /// Mirrors HomeView's `home_upcoming_row_enabled` key: the "Upcoming" row of followed shows'
    /// next airing episodes, directly under Continue Watching. Default ON. Local-only.
    @AppStorage("home_upcoming_row_enabled") private var upcomingRowEnabled = true

    /// FEAT-25: mirrors HomeView's `hero_trailer_autoplay` key — the hero plays its own trailer
    /// with no focus required. Default OFF. Local-only, not synced.
    @AppStorage("hero_trailer_autoplay") private var heroTrailerAutoplay = false

    /// Where the "Trailers on Focus" muted preview plays: the poster card itself (default) or the
    /// hero banner. Only meaningful while `inlineTrailersEnabled` is on. Local-only, not synced.
    /// The raw values stay "poster" / "hero" in both layouts; only the picker wording differs (Stage
    /// reads them as In Row / Background, Classic as Poster / Hero).
    @AppStorage("trailer_playback_location") private var trailerPlaybackLocation = "poster"

    /// beta.19-rc1 verdict (M4, FEAT-52 "Trailer Start Delay"): how long a focus-dwelled trailer waits
    /// before it starts. Same device-local `@AppStorage` pattern as the three trailer keys above (no
    /// Kotlin, no sync); the value is `TrailerStartDelay.rawValue` ("auto" | "1" | "2" | "3") and
    /// `TrailerStartDelay.current()` reads it once per dwell. Default Automatic = the rows have
    /// stopped moving, plus one second.
    @AppStorage(TrailerStartDelay.storageKey) private var trailerStartDelay = TrailerStartDelay.automatic.rawValue

    /// 2026-08-30 fix: replaces the `isExpanded` that used to live inside the now-deleted
    /// `HeroSourcesGroup`/`HomeCatalogsGroup`. Plain `@State`, same behavior as before — no
    /// persistence, so both sections start collapsed on every (re)visit to Settings.
    @State private var heroSourcesExpanded = false
    @State private var catalogsExpanded = false

    /// Home Stage & Strip (H1): the layout this pane is configuring, resolved through
    /// `HomeLayout.resolve` so an unset or unknown stored value reads as Stage, the same as every
    /// other reader.
    private var isStage: Bool { HomeLayout.resolve(homeLayoutRaw) == .stage }

    var body: some View {
        layoutSection

        SettingsSection(String(localized: "Home Rows")) {
            // Catalog-independent: the Upcoming row is fed by watch progress + Library, so its
            // switch must stay reachable when no catalog add-on is installed (Codex round 1).
            //
            // It is also this pane's BUG-47 floor, and that is load-bearing, not incidental:
            // it sits OUTSIDE the `model.catalogs.isEmpty` branch below, so whatever the catalog
            // list does — arrives, shrinks, empties — the Home Screen pane always has at least one
            // focusable row for the focus engine to land on, and the sidebar can always enter it.
            // Do not move this row inside the branch. (The Home Layout picker in the section above
            // is now a second always-present row; this one keeps its floor role regardless.)
            SettingsToggleRow(
                title: String(localized: "Upcoming Episodes"),
                subtitle: upcomingRowEnabled
                    ? String(localized: "A row under Continue Watching with your shows' next episodes airing in the next 14 days")
                    : String(localized: "No Upcoming row on Home"),
                isOn: $upcomingRowEnabled,
                descriptionID: .homeUpcoming
            )

            if model.catalogs.isEmpty {
                Text("Install add-ons to customize your Home rows.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)

                // Prevents the "removing a catalog gives a big white screen" report (device video
                // 2026-08-29, §(b) of the batch plan). This branch is not just an empty state the
                // user arrives on — it is a state the pane can FLIP INTO while the user's focus is
                // on a catalog toggle in the `else` branch: an add-on removal, a profile switch, or
                // the definitions clobber this batch's `SettingsViewModel` guards close, and the
                // entire focusable subtree below (hero sources, catalog rows, both expanded groups)
                // disappears in ONE update pass. With only static `Text` here, the branch that
                // replaces it has nothing focusable in it at all, so the engine has to jump the
                // length of the section for a survivor — a focusable row standing where the removed
                // content stood gives it a local landing target instead.
                //
                // Refresh is also the honest recovery action for the state that actually produced
                // the report: the add-ons are still installed, their manifests just aren't loaded,
                // so re-fetching them repopulates the catalog definitions without quitting the app.
                // With genuinely zero add-ons installed it is a no-op (`refreshAll()` iterates the
                // enabled list) — the row still earns its place as this branch's focusable anchor.
                SettingsActionRow(
                    title: String(localized: "Refresh Add-ons"),
                    subtitle: String(localized: "Re-check installed add-ons for catalogs."),
                    systemImage: "arrow.clockwise",
                    descriptionID: .homeRefreshAddons
                ) {
                    AddonRepository.shared.refreshAll()
                }
            } else {
                // FEAT-15 (and BUG-24, the same request in disguise): OFF no longer means "no
                // hero region". It means "no ROTATING banner" — the top of Home becomes the
                // focused title's own backdrop and description, updating as you move through the
                // rows. The old copy ("Home starts directly with catalog rows") described a
                // behavior that also silently took the description panel away with it, which is
                // precisely the trap the reporter hit three times; both states now state what
                // they DO, and neither implies losing the description.
                //
                // Home Stage & Strip (H8): Stage has no rotating banner or focus panel to
                // configure, so Show Hero and the two groups below it that configure the banner
                // (Nuvio-Style Hero, Hero Sources) exist only in Classic. Their stored values are
                // never touched: they do nothing in Stage and are back as they were in Classic.
                if !isStage {
                    SettingsToggleRow(
                        title: String(localized: "Show Hero"),
                        subtitle: model.heroEnabled
                            ? String(localized: "A rotating banner built from up to 2 of your catalogs, switching to the focused title as you browse")
                            : String(localized: "No rotating banner \u{2014} the top of Home shows the focused title's artwork and description"),
                        isOn: Binding(
                            get: { model.heroEnabled },
                            set: { model.setHeroEnabled($0) }
                        ),
                        descriptionID: .homeShowHero
                    )
                }

                // Everything inside this branch configures the ROTATING banner specifically —
                // its layout and which catalogs feed it — so it stays hidden with Show Hero off,
                // where there are no hero pages to lay out or source (FEAT-15: the focus panel
                // always uses the pinned Nuvio presentation, see HomeView.heroNuvioStyle). It is
                // also Classic-only (see above).
                if !isStage && model.heroEnabled {
                    // UX-2 hero redesign v2: title/description on the left with the artwork
                    // reading on the right (Nuvio-style, OPT-IN) vs the classic lower-left
                    // logo layout (default). UX-7 extension: the Nuvio-style hero is also
                    // PINNED to the top of Home (it becomes the fixed top of a VStack and the
                    // rows get their own ScrollView below it) — only the rows scroll, so the ON
                    // copy names that too; classic still scrolls the hero away with the rows.
                    SettingsToggleRow(
                        title: String(localized: "Nuvio-Style Hero"),
                        subtitle: heroNuvioStyle
                            ? String(localized: "Title and description on the left, artwork on the right, hero pinned while rows scroll")
                            : String(localized: "Classic layout with the logo on the lower left"),
                        isOn: $heroNuvioStyle,
                        descriptionID: .homeNuvioStyleHero
                    )

                    // Collections are hard-forced to heroSourceEnabled = false on the Kotlin side
                    // (HomeCatalogSettingsRepository.normalizePreferences), so they never appear
                    // as a hero source — filter defensively here too.
                    //
                    // Focus note (2026-08-30): "Hero Sources" is a `SettingsDisclosureRow` header
                    // row followed, only while expanded, by one `HeroSourceRow` per item below it
                    // — each a SEPARATE `SettingsSection` child, i.e. a separate List row with its
                    // own native focus target. Before this fix, the header and every expanded row
                    // lived together inside one `HeroSourcesGroup` view that was itself a single
                    // List row, so tvOS's one-focus-target-per-row rule meant none of the expanded
                    // toggles could ever be focused (see the file header comment for the device
                    // repro). There is no more group-local `isExpanded`, no `focusedChild`
                    // `@FocusState`, and no `settingsRowPlatterActive` publication to keep in sync
                    // with the data here — a removed row is just a removed List row, and the
                    // system reassigns focus to a surviving sibling on its own. If this list ever
                    // empties while expanded, `heroSourcesExpanded` simply stops mattering: the
                    // `if !heroSourceCatalogs.isEmpty` guard around the header below removes the
                    // header too, and the adjacent "Nuvio-Style Hero" toggle above is the
                    // guaranteed-present fallback landing row (same BUG-47 reasoning as always).
                    let heroSourceCatalogs = model.catalogs.filter { !$0.isCollection }
                    if !heroSourceCatalogs.isEmpty {
                        SettingsDisclosureRow(
                            title: String(localized: "Hero Sources"),
                            subtitle: heroSourcesSummary,
                            isExpanded: heroSourcesExpanded && !heroSourceCatalogs.isEmpty,
                            descriptionID: .homeHeroSources
                        ) {
                            heroSourcesExpanded.toggle()
                        }

                        if heroSourcesExpanded && !heroSourceCatalogs.isEmpty {
                            ForEach(heroSourceCatalogs, id: \.key) { item in
                                HeroSourceRow(
                                    item: item,
                                    interactive: item.heroSourceEnabled || heroSelectedCount < heroLimit
                                ) { enabled in
                                    model.setHeroSource(key: item.key, enabled: enabled)
                                }
                            }
                        }
                    }
                }

                SettingsToggleRow(
                    title: String(localized: "Trailers on Focus"),
                    subtitle: trailersOnFocusSubtitle,
                    isOn: $inlineTrailersEnabled,
                    descriptionID: .homeTrailersOnFocus
                )

                if inlineTrailersEnabled {
                    trailerLocationRow
                }

                // Home Stage & Strip (H8): the hero's own autoplay is a Classic-banner setting; the
                // stage has no such switch (its trailer is Trailer Location above), so the row is
                // Classic-only and its stored value is left alone.
                if !isStage {
                    SettingsToggleRow(
                        title: String(localized: "Autoplay Hero Trailer"),
                        subtitle: heroTrailerAutoplay
                            ? String(localized: "The hero plays its trailer by itself, without waiting for focus")
                            : String(localized: "The hero shows artwork only"),
                        isOn: $heroTrailerAutoplay,
                        descriptionID: .homeHeroTrailerAutoplay
                    )
                }

                // beta.19-rc1 verdict (M4, FEAT-52): only while a trailer can actually start on a dwell
                // — the poster/hero preview on focus, or (Classic only) the hero's own autoplay. With
                // both off there is nothing for the delay to delay. Sits right after the switches that
                // enable it. In Stage only Trailers on Focus can start one: a stored Autoplay Hero
                // Trailer value does nothing there, so it must not keep this row up.
                if inlineTrailersEnabled || (!isStage && heroTrailerAutoplay) {
                    trailerStartDelayRow
                }

                SettingsToggleRow(
                    title: String(localized: "Show Catalog Type in Titles"),
                    subtitle: model.showCatalogType
                        ? String(localized: "rows read like \u{201C}Popular - Movies\u{201D}")
                        : String(localized: "rows use the add-on's catalog name"),
                    isOn: Binding(
                        get: { model.showCatalogType },
                        set: { model.setShowCatalogType($0) }
                    ),
                    descriptionID: .homeCatalogType
                )

                // Focus note (2026-08-30): same hoist as Hero Sources above — "Catalogs" is a
                // header row followed, only while expanded, by one `CatalogSettingRow` per
                // catalog, each its own `SettingsSection` child / List row. This is the group the
                // device video (2026-08-29) caught rendering blank: `HomeCatalogsGroup` put its
                // rows' text and reorder chips straight into a shared List row, where none of them
                // ever got the system's focused-row label inversion, and (independently) none of
                // them could ever actually receive focus for the reason in the file header
                // comment. `CatalogSettingRow` is also reshaped below — see its own comment — so a
                // single row can stay reachable without needing three separate focus targets.
                SettingsDisclosureRow(
                    title: String(localized: "Catalogs"),
                    subtitle: catalogsSummary,
                    isExpanded: catalogsExpanded && !model.catalogs.isEmpty,
                    descriptionID: .homeCatalogs
                ) {
                    catalogsExpanded.toggle()
                }

                if catalogsExpanded && !model.catalogs.isEmpty {
                    ForEach(model.catalogs, id: \.key) { item in
                        CatalogSettingRow(
                            item: item,
                            onToggle: { model.toggleCatalog(item) },
                            onUp: { model.moveUp(item) },
                            onDown: { model.moveDown(item) }
                        )
                    }
                }
            }
        }
        // The expansion flags now outlive the branches that render their groups (they used to be
        // `@State` INSIDE the group views, destroyed with them), so reset them when the owning
        // branch disappears — otherwise toggling Show Hero off and on, or the catalog list
        // emptying and repopulating, would resurrect a stale expanded state instead of the
        // documented collapsed-on-recreation behavior (Codex 2026-08-30 P3).
        .onChange(of: model.heroEnabled) { _, enabled in
            if !enabled { heroSourcesExpanded = false }
        }
        .onChange(of: model.catalogs.isEmpty) { _, isEmpty in
            if isEmpty {
                heroSourcesExpanded = false
                catalogsExpanded = false
            }
        }
        // The Hero Sources group can also vanish alone: every remaining catalog being a
        // collection removes just that header while the pane and Catalogs group stay.
        .onChange(of: model.catalogs.contains(where: { !$0.isCollection })) { _, hasCatalogSources in
            if !hasCatalogSources { heroSourcesExpanded = false }
        }
        // Home Stage & Strip (H8): Hero Sources only exists in Classic, so entering Stage drops its
        // expansion too (same reasoning as the resets above: a stale flag would resurrect an
        // expanded group the next time Classic returns, instead of the collapsed-on-recreation
        // behavior). Written from here because the picker lives in the sibling Layout section.
        .onChange(of: homeLayoutRaw) { _, raw in
            if HomeLayout.resolve(raw) == .stage { heroSourcesExpanded = false }
        }
    }

    // MARK: - Layout section (Home Stage & Strip, H8)

    /// The new first section: the Home Layout picker (always present, so the pane has a second
    /// focus floor beside Upcoming Episodes) and, in Stage only, the Ambient Background switch.
    /// Both sit outside the `model.catalogs.isEmpty` branch below, so they stay reachable with no
    /// add-on installed. Stage and Classic read the same `home_layout` key through `HomeLayout`:
    /// HomeView and the folder page see a flip live, with no remount and no relaunch.
    @ViewBuilder
    private var layoutSection: some View {
        SettingsSection(String(localized: "Layout")) {
            SettingsPickerRow(
                title: String(localized: "Home Layout"),
                selection: Binding(
                    get: { HomeLayout.resolve(homeLayoutRaw) },
                    set: { homeLayoutRaw = $0.rawValue }
                ),
                options: HomeLayout.allCases,
                descriptionID: .homeLayout,
                label: { $0.label }
            )

            // The wash is part of the stage (it fills the background behind the focused title), so
            // there is nothing for the switch to control in Classic. Its stored value is kept.
            if isStage {
                SettingsToggleRow(
                    title: String(localized: "Ambient Background"),
                    subtitle: ambientBackground
                        ? String(localized: "A soft wash of the focused title's colors fills the background")
                        : String(localized: "Plain background"),
                    isOn: $ambientBackground,
                    descriptionID: .homeAmbientBackground
                )
            }
        }
    }

    /// The "Trailers on Focus" subtitle. Codex gate r3/r4: the enabled summary names the surface
    /// that will ACTUALLY play. Classic says "hero" only when the hero location can take effect
    /// (same conditions as the two fallback captions in `trailerLocationRow`); otherwise the
    /// poster, which is what the viewer will see in the classic layout or with no hero source
    /// enabled. Home Stage & Strip (H8): Stage always has a stage, so Background always takes
    /// effect and says so; In Row keeps the poster wording.
    private var trailersOnFocusSubtitle: String {
        guard inlineTrailersEnabled else { return String(localized: "Posters show artwork only") }
        if heroLocationEffective {
            return isStage
                ? String(localized: "Trailers play muted behind the title at the top after you rest on a poster")
                : String(localized: "The hero plays a muted trailer preview after a moment of focus on a poster")
        }
        return String(localized: "Posters play a muted trailer preview after a moment of focus")
    }

    /// Settings-side mirror of `HomeView.heroFocusTrailerMode`'s settings terms: "Hero" is
    /// selected AND the layout pins a hero (Show Hero off → focus panel; Nuvio-style on with at
    /// least one hero source, the best proxy Settings has for the hero fan-out producing a
    /// surface). Exactly the complement of the two fallback captions in `trailerLocationRow`.
    ///
    /// Home Stage & Strip (H8): the stage always exists, so in Stage "Background" (the stored
    /// "hero") always takes effect and none of the Classic conditions apply.
    private var heroLocationEffective: Bool {
        if isStage { return trailerPlaybackLocation == "hero" }
        guard trailerPlaybackLocation == "hero" else { return false }
        if !model.heroEnabled { return true }
        return heroNuvioStyle && model.catalogs.contains(where: { $0.heroSourceEnabled })
    }

    /// FEAT-52 "Trailer Start Delay": Automatic (the rows stop moving, then one second) or a fixed
    /// 1 / 2 / 3 s counted from focus, never before the rows stop. The description is the kit's
    /// focused-row explainer: Classic keeps its own copy, and Stage has one that does not mention
    /// the hero (each id is written as a literal in its own branch, which is what the description
    /// coverage test scans for).
    @ViewBuilder
    private var trailerStartDelayRow: some View {
        if isStage {
            SettingsPickerRow(
                title: String(localized: "Trailer Start Delay"),
                selection: trailerStartDelayBinding,
                options: TrailerStartDelay.allCases,
                descriptionID: .homeTrailerStartDelayStage,
                label: { $0.label }
            )
        } else {
            SettingsPickerRow(
                title: String(localized: "Trailer Start Delay"),
                selection: trailerStartDelayBinding,
                options: TrailerStartDelay.allCases,
                descriptionID: .homeTrailerStartDelay,
                label: { $0.label }
            )
        }
    }

    private var trailerStartDelayBinding: Binding<TrailerStartDelay> {
        Binding(get: { TrailerStartDelay(rawValue: trailerStartDelay) ?? .automatic },
                set: { trailerStartDelay = $0.rawValue })
    }

    private var trailerLocationBinding: Binding<String> {
        Binding(
            get: { trailerPlaybackLocation },
            set: { trailerPlaybackLocation = $0 }
        )
    }

    /// Dependent chip row shown only while "Trailers on Focus" is on: picks whether the muted
    /// preview plays in the poster card (default) or the hero banner. The classic (non-Nuvio-
    /// style) hero layout has no artwork region to preview into, so a caption explains that
    /// "Hero" falls back to the poster there.
    ///
    /// Home Stage & Strip (H8): in Stage the same two stored values read Background ("hero", the
    /// trailer plays behind the title at the top) and In Row ("poster", the focused poster turns
    /// into the playing card), Background listed first. The stage always exists, so neither
    /// Classic fallback caption applies there. Classic is unchanged: Poster / Hero and both
    /// captions.
    @ViewBuilder
    private var trailerLocationRow: some View {
        if isStage {
            SettingsPickerRow(
                title: String(localized: "Trailer Location"),
                selection: trailerLocationBinding,
                options: ["hero", "poster"],
                descriptionID: .homeTrailerLocationStage,
                label: { $0 == "hero" ? String(localized: "Background") : String(localized: "In Row") }
            )
        } else {
            SettingsPickerRow(
                title: String(localized: "Trailer Location"),
                selection: trailerLocationBinding,
                options: ["poster", "hero"],
                descriptionID: .homeTrailerLocation,
                label: { $0 == "hero" ? String(localized: "Hero") : String(localized: "Poster") }
            )
            if trailerPlaybackLocation == "hero" && model.heroEnabled && !heroNuvioStyle {
                Text("In the classic hero layout, trailers play in the poster.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            // Same silent-mismatch guard for the other configuration where "Hero" cannot take
            // effect: Nuvio-style layout but zero hero sources selected, so the hero fan-out can
            // never produce a surface and `heroFocusTrailerMode`'s latch never sets.
            if trailerPlaybackLocation == "hero" && model.heroEnabled && heroNuvioStyle
                && !model.catalogs.contains(where: { $0.heroSourceEnabled }) {
                Text("Hero needs a hero source enabled below; until then, trailers play in the poster.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    // MARK: - Hero Sources summary (moved out of the deleted `HeroSourcesGroup`, 2026-08-30)

    /// Collections are hard-forced to `heroSourceEnabled = false` on the Kotlin side
    /// (HomeCatalogSettingsRepository.normalizePreferences); filtered out here too, matching the
    /// `heroSourceCatalogs` filter at the call site above.
    private var heroSelectedCount: Int {
        model.catalogs.filter { !$0.isCollection && $0.heroSourceEnabled }.count
    }

    private var heroLimit: Int {
        Int(HomeCatalogSettingsRepository.shared.HERO_SOURCE_SELECTION_LIMIT)
    }

    /// "N of 2 selected", plus the selected catalogs' display titles once at least one is on —
    /// gives the collapsed header a useful preview instead of just a count.
    private var heroSourcesSummary: String {
        let selectedNames = model.catalogs
            .filter { !$0.isCollection && $0.heroSourceEnabled }
            .map(\.displayTitle)
        guard !selectedNames.isEmpty else {
            return String(localized: "\(heroSelectedCount) of \(heroLimit) selected")
        }
        let joined = selectedNames.joined(separator: ", ")
        return String(localized: "\(heroSelectedCount) of \(heroLimit) selected \u{00B7} \(joined)")
    }

    // MARK: - Catalogs summary (moved out of the deleted `HomeCatalogsGroup`, 2026-08-30)

    private var catalogsSummary: String {
        let enabledCount = model.catalogs.filter { $0.enabled }.count
        return String(localized: "\(enabledCount) of \(model.catalogs.count) enabled")
    }
}

/// Shared collapsed/expanded header row for the two collapsible Home Screen lists above: title +
/// a live summary subtitle + a chevron that rotates 180° between collapsed (pointing down) and
/// expanded (pointing up).
///
/// 2026-08-30 fix: this is now a plain `SettingsActionRow`-shaped `Button` — no focus-binding
/// params, no `settingsRowPlatterActive`/`settingsRowIsFocused` reads, no `colorScheme` flip. It
/// used to take a `@FocusState` binding from its parent group so the group could tell whether ITS
/// one List row's platter was up (BUG-65 container half), because the header shared that List row
/// with every expanded child. Now this row is its OWN `SettingsSection` child, i.e. its own List
/// row, so the system's native focused-row label inversion reaches the whole Button label the
/// ordinary way every other kit row gets it — the same way `SettingsActionRow` always has. That
/// retires the container-focus problem for this file specifically (BUG-65's platter-legibility
/// fix, the env keys in DesignSystem/FlatControlStyles.swift, and the `@FocusState`-publishing
/// pattern all still apply to other custom containers elsewhere in the app — nothing here changes
/// them, they just have no publisher left in this file, so they default to false / are inert).
private struct SettingsDisclosureRow: View {
    let title: String
    let subtitle: String
    let isExpanded: Bool
    /// FEAT-50: passed straight to the label (the `\.isFocused` read site).
    var descriptionID: SettingsDescriptionID? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // D11 V2 (Gate 2 sim pass, `g2-pane-4-detailpage-row.png`): the shared kit chrome, so
            // this row sits on the same rest platter as every row around it (and the platter fades
            // out on focus exactly like theirs). Trailing glyph stays the up/down disclosure
            // chevron, in the kit's trailing-value size and `.secondary`.
            SettingsRowChrome {
                SettingsRowLabel(title: title, subtitle: subtitle, descriptionID: descriptionID)
            } trailing: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(SettingsRowFont.subtitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A single Hero Sources row: catalog title + add-on, with an on/off indicator. At the 2-source
/// limit an OFF row is INERT — it still takes focus and still reads normally, it just refuses the
/// toggle and says why.
///
/// 2026-08-30 fix: as of this fix each `HeroSourceRow` is its own `SettingsSection` child / List
/// row (see the call site in `HomeScreenSettingsPane.body`), so it is a genuinely independent
/// focus target — down/up from one row lands on the next, same as every other Settings row. It no
/// longer takes or publishes any focus-binding params: those existed only so `HeroSourcesGroup`
/// (deleted) could detect that a child of its single shared List row had focus. That is also why
/// the plain `\.isFocused` read below is sufficient here where BUG-65 needed the three-way
/// `onPlatter` test: this file has no custom container left to publish the other two.
///
/// Wave 9(b), device pass on the Living Room ATV: `.disabled(!interactive)` was a FOCUS TRAP. With
/// 2 of 2 selected, every OFF row is disabled, so tvOS skips all of them — and from the last
/// selected row an up-swipe does not land on the row above (there isn't a focusable one), it
/// EJECTS to the tab bar. That is the BUG-47 empty-pushed-view class wearing a different hat: a
/// region whose only reachable controls have been removed stops being navigable. It also hides the
/// reason — a dimmed unfocusable row explains nothing about why it cannot be turned on.
///
/// So: keep the row focusable, refuse the write at the binding, de-emphasize it visually only
/// while it is NOT on the focus platter (dimming a focused row is the BUG-58/65 contrast class —
/// on the near-white platter a 0.4-opacity label is exactly the "vanishes into the platter"
/// failure those bugs are about), and replace the subtitle with the reason. Turning any ON row off
/// re-enables the rest immediately: `interactive` is recomputed from `heroSelectedCount` at the
/// call site on every model publish, so the captions and the toggles come back together.
private struct HeroSourceRow: View {
    let item: HomeCatalogSettingsItem
    let interactive: Bool
    let onToggle: (Bool) -> Void

    fileprivate static let limitReachedCaption = String(
        localized: "Limit reached — turn another source off first"
    )

    /// Built from a bare `Toggle` rather than `SettingsToggleRow` for one reason: the focus-aware
    /// dimming has to live INSIDE the toggle's label (Codex Wave 9 r3). SwiftUI populates
    /// `\.isFocused` for the focusable control and its DESCENDANTS; it never propagates upward. The
    /// first version of this fix read it on the view that CONTAINS the toggle, so it was
    /// permanently false and an inert row stayed at 0.4 opacity even while focused — dim text on
    /// the near-white platter, which is precisely the BUG-58/65 contrast failure the guard existed
    /// to avoid. `SettingsToggleRow` builds its own label and takes no label closure, so the label
    /// is constructed here instead; everything else it does is reproduced exactly, including the
    /// `.accessibilityValue` the harness's `toggleState` helper reads (beta.13 wave 2).
    ///
    /// Interactive rows are unchanged by construction: same `Toggle` over the same
    /// `SettingsRowLabel` with the same accessibility value, `dimmed: false` makes the opacity a
    /// literal 1, and an empty hint is what VoiceOver already reports for a row with no hint.
    var body: some View {
        Toggle(isOn: Binding(
            get: { item.heroSourceEnabled },
            // Inert, not disabled: the row keeps focus and the press is simply not honoured.
            set: { newValue in
                guard interactive else { return }
                onToggle(newValue)
            }
        )) {
            HeroSourceRowLabel(
                title: item.displayTitle,
                subtitle: interactive ? item.addonName : Self.limitReachedCaption,
                dimmed: !interactive
            )
        }
        // D11 V1/V2 (Gate 2 sim pass): the same style `SettingsToggleRow` applies, so an expanded
        // hero source shows the capsule switch, sits on the rest platter with the kit insets, and
        // keeps the system focus platter. The label (and its `\.isFocused` dimming read) stays
        // inside the style's Button label, so the Wave 9 r3 reasoning above still holds.
        .toggleStyle(SettingsSwitchToggleStyle())
        // Kept from `SettingsToggleRow`: the UITest harness's state-aware toggle helper reads this
        // exact value, and it is a friendlier VoiceOver value than "1"/"0".
        .accessibilityValue(item.heroSourceEnabled ? Text("On") : Text("Off"))
        // VoiceOver gets the same sentence the caption shows, since the caption is the only thing
        // distinguishing an inert row from an ordinary off one.
        .accessibilityHint(interactive ? Text("") : Text(Self.limitReachedCaption))
    }
}

/// The label half of a `HeroSourceRow`, split out purely so `\.isFocused` is read from inside the
/// toggle's label — the only place SwiftUI populates it. See `HeroSourceRow.body`.
private struct HeroSourceRowLabel: View {
    let title: String
    let subtitle: String
    let dimmed: Bool
    @Environment(\.isFocused) private var isFocused

    /// The pre-C4 dimming value, kept so an at-limit row still reads as unavailable at 10 feet.
    private static let inertRowOpacity: Double = 0.4

    var body: some View {
        SettingsRowLabel(title: title, subtitle: subtitle, descriptionID: .homeHeroSource)
            // Never dim what the platter is currently lighting: on the near-white focus platter a
            // 0.4-opacity label is the "vanishes into the platter" failure (BUG-58/65).
            .opacity(dimmed && !isFocused ? Self.inertRowOpacity : 1)
    }
}

/// A Home-catalog row: title + add-on, with an enable/disable indicator and reorder via long-press
/// context menu.
///
/// 2026-08-30 fix, full redesign: the previous shape put three independent focus targets (an
/// enable toggle chip plus up/down reorder chips) inside one row. Hoisting `CatalogSettingRow`
/// itself out to be its own List row (see the call site above) fixes reachability for the row as a
/// whole, but three chips *within* one row would just recreate the identical one-focus-target trap
/// one level down — a List row still exposes only one focus target, so at most one of those three
/// chips could ever be focused. Rather than hoist the chips too (which would triple the row count
/// and make "enable" and "reorder" show up as separate list entries), the whole row is now ONE
/// `Button` whose primary action is the enable toggle, with reorder moved to a long-press
/// `.contextMenu` (same pattern as the Library tab's remove-from-library menu, see
/// `LibraryView.swift`). Down/up navigation between catalogs — the reorder gesture people actually
/// reach for while scanning a list — now just works, and Select+hold reaches the rarer reorder
/// action without needing its own focus target.
private struct CatalogSettingRow: View {
    let item: HomeCatalogSettingsItem
    let onToggle: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void

    var body: some View {
        Button(action: onToggle) {
            // D11 V1/V2 (Gate 2 sim pass): the kit row chrome (rest platter, kit insets) and the
            // kit's capsule switch glyph in place of the old checkmark circle, so an expanded
            // catalog reads like every toggle row around it. Still one Button (the reorder
            // context menu needs it); the glyph is decorative, state stays in the accessibility
            // value below.
            SettingsRowChrome {
                SettingsRowLabel(title: item.displayTitle, subtitle: item.addonName, descriptionID: .homeCatalog)
                    .opacity(item.enabled ? 1 : 0.55)
            } trailing: {
                SettingsSwitchGlyph(isOn: item.enabled)
            }
        }
        .contextMenu {
            Button {
                onUp()
            } label: {
                Label(String(localized: "Move Up"), systemImage: "chevron.up")
            }
            Button {
                onDown()
            } label: {
                Label(String(localized: "Move Down"), systemImage: "chevron.down")
            }
        }
        .accessibilityLabel(item.displayTitle)
        .accessibilityValue(item.enabled ? Text("Enabled") : Text("Disabled"))
    }
}
