import SwiftUI
import SharedCore

/// "Home Screen" category content: hero banner + hero sources, inline trailer previews, catalog
/// type labels, and the Home Rows enable/reorder list. Extracted from SettingsView.swift (Phase 2
/// HIG revamp file split) — logic and wiring preserved verbatim, only regrouped into a
/// per-category pane.
struct HomeScreenSettingsPane: View {
    @ObservedObject var model: SettingsViewModel

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
    @AppStorage("trailer_playback_location") private var trailerPlaybackLocation = "poster"

    var body: some View {
        SettingsSection(String(localized: "Home Rows")) {
            // Catalog-independent: the Upcoming row is fed by watch progress + Library, so its
            // switch must stay reachable when no catalog add-on is installed (Codex round 1).
            //
            // It is also this pane's BUG-47 floor, and that is load-bearing, not incidental:
            // it sits OUTSIDE the `model.catalogs.isEmpty` branch below, so whatever the catalog
            // list does — arrives, shrinks, empties — the Home Screen pane always has at least one
            // focusable row for the focus engine to land on, and the sidebar can always enter it.
            // Do not move this row inside the branch.
            SettingsToggleRow(
                title: String(localized: "Upcoming Episodes"),
                subtitle: upcomingRowEnabled
                    ? String(localized: "A row under Continue Watching with your shows' next episodes airing in the next 14 days")
                    : String(localized: "No Upcoming row on Home"),
                isOn: $upcomingRowEnabled
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
                    systemImage: "arrow.clockwise"
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
                SettingsToggleRow(
                    title: String(localized: "Show Hero"),
                    subtitle: model.heroEnabled
                        ? String(localized: "A rotating banner built from up to 2 of your catalogs, switching to the focused title as you browse")
                        : String(localized: "No rotating banner \u{2014} the top of Home shows the focused title's artwork and description"),
                    isOn: Binding(
                        get: { model.heroEnabled },
                        set: { model.setHeroEnabled($0) }
                    )
                )

                // Collections are hard-forced to heroSourceEnabled = false on the
                // Kotlin side (HomeCatalogSettingsRepository.normalizePreferences),
                // so they never appear as a hero source — filter defensively here too.
                //
                // Everything inside this branch configures the ROTATING banner specifically —
                // its layout and which catalogs feed it — so it stays hidden with Show Hero off,
                // where there are no hero pages to lay out or source (FEAT-15: the focus panel
                // always uses the pinned Nuvio presentation, see HomeView.heroNuvioStyle).
                if model.heroEnabled {
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
                        isOn: $heroNuvioStyle
                    )

                    // Focus note (2026-08-29): this guard removes the whole group — header
                    // included — when the last non-collection catalog goes away, so a focused hero
                    // source row loses its entire subtree in one pass. That is tolerable ONLY
                    // because the "Nuvio-Style Hero" toggle directly above is an adjacent
                    // focusable row in the same List section for the engine to fall back to;
                    // the group is never the only focusable thing on screen. Keep it that way if
                    // this branch is ever rearranged.
                    let heroSourceCatalogs = model.catalogs.filter { !$0.isCollection }
                    if !heroSourceCatalogs.isEmpty {
                        HeroSourcesGroup(
                            items: heroSourceCatalogs,
                            onToggle: { key, enabled in model.setHeroSource(key: key, enabled: enabled) }
                        )
                    }
                }

                SettingsToggleRow(
                    title: String(localized: "Trailers on Focus"),
                    // Codex gate r3/r4: the enabled summary names the surface that will ACTUALLY
                    // play — "Hero" only when the hero location can take effect (same conditions
                    // as the two fallback captions below); otherwise the poster, which is what
                    // the user will see in the classic layout or with no hero source enabled.
                    subtitle: !inlineTrailersEnabled
                        ? String(localized: "Posters show artwork only")
                        : heroLocationEffective
                            ? String(localized: "The hero plays a muted trailer preview after a moment of focus on a poster")
                            : String(localized: "Posters play a muted trailer preview after a moment of focus"),
                    isOn: $inlineTrailersEnabled
                )

                if inlineTrailersEnabled {
                    trailerLocationRow
                }

                SettingsToggleRow(
                    title: String(localized: "Autoplay Hero Trailer"),
                    subtitle: heroTrailerAutoplay
                        ? String(localized: "The hero plays its trailer by itself, without waiting for focus")
                        : String(localized: "The hero shows artwork only"),
                    isOn: $heroTrailerAutoplay
                )

                SettingsToggleRow(
                    title: String(localized: "Show Catalog Type in Titles"),
                    subtitle: model.showCatalogType
                        ? String(localized: "rows read like \u{201C}Popular - Movies\u{201D}")
                        : String(localized: "rows use the add-on's catalog name"),
                    isOn: Binding(
                        get: { model.showCatalogType },
                        set: { model.setShowCatalogType($0) }
                    )
                )

                HomeCatalogsGroup(
                    items: model.catalogs,
                    onToggle: { model.toggleCatalog($0) },
                    onUp: { model.moveUp($0) },
                    onDown: { model.moveDown($0) }
                )
            }
        }
    }

    /// Settings-side mirror of `HomeView.heroFocusTrailerMode`'s settings terms: "Hero" is
    /// selected AND the layout pins a hero (Show Hero off → focus panel; Nuvio-style on with at
    /// least one hero source, the best proxy Settings has for the hero fan-out producing a
    /// surface). Exactly the complement of the two fallback captions in `trailerLocationRow`.
    private var heroLocationEffective: Bool {
        guard trailerPlaybackLocation == "hero" else { return false }
        if !model.heroEnabled { return true }
        return heroNuvioStyle && model.catalogs.contains(where: { $0.heroSourceEnabled })
    }

    /// Dependent chip row shown only while "Trailers on Focus" is on: picks whether the muted
    /// preview plays in the poster card (default) or the hero banner. The classic (non-Nuvio-
    /// style) hero layout has no artwork region to preview into, so a caption explains that
    /// "Hero" falls back to the poster there.
    @ViewBuilder
    private var trailerLocationRow: some View {
        SettingsPickerRow(
            title: String(localized: "Trailer Location"),
            selection: Binding(
                get: { trailerPlaybackLocation },
                set: { trailerPlaybackLocation = $0 }
            ),
            options: ["poster", "hero"],
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

/// The "Hero Sources" sub-list under Show Hero: collapsed by default behind a single focusable
/// header row (title + live "N of 2 selected" summary + chevron); pressing Select reveals the
/// per-catalog toggle rows inline. Mirrors the Compose `HeroSourcesDropdown`
/// (HomescreenSettingsPage.kt) logic — an OFF row goes non-interactive once the limit is reached;
/// ON rows can always toggle off.
///
/// tvOS has no usable `DisclosureGroup` (poor/inconsistent focus highlighting — see the identical
/// note on `StreamPickerView.groupHeader`), so this is a plain `Button` header + conditional
/// content, not a DisclosureGroup. `isExpanded` is plain `@State` (no persistence): the section
/// starts collapsed every time this view is (re)built, i.e. on every visit to Settings. Collapsing
/// normally happens from the header row's own Button action, so focus is already on the header
/// at that moment — no separate FocusState retargeting is needed the way StreamPickerView's
/// multi-trigger expansion needs it. The one collapse that is NOT user-driven is the empty-`items`
/// guard in `body`, and it deliberately doesn't retarget focus either: by the time it fires, every
/// row it could have retargeted to is already gone, and the header it collapses back to is the
/// focusable row that stayed mounted through the whole pass.
private struct HeroSourcesGroup: View {
    let items: [HomeCatalogSettingsItem]
    let onToggle: (_ key: String, _ enabled: Bool) -> Void
    @State private var isExpanded = false

    private var selectedCount: Int {
        items.filter { $0.heroSourceEnabled }.count
    }

    private var limit: Int {
        Int(HomeCatalogSettingsRepository.shared.HERO_SOURCE_SELECTION_LIMIT)
    }

    /// "N of 2 selected", plus the selected catalogs' display titles once at least one is on —
    /// gives the collapsed header a useful preview instead of just a count.
    private var summary: String {
        let selectedNames = items.filter { $0.heroSourceEnabled }.map(\.displayTitle)
        guard !selectedNames.isEmpty else {
            return String(localized: "\(selectedCount) of \(limit) selected")
        }
        let joined = selectedNames.joined(separator: ", ")
        return String(localized: "\(selectedCount) of \(limit) selected \u{00B7} \(joined)")
    }

    /// Rows show only when the user expanded the group AND there is something to show. Gating the
    /// content on the data as well as on `isExpanded` means the expanded platter can never render
    /// with zero focusable children inside it — not even for the single frame between `items`
    /// shrinking to empty and the `onChange` below resetting the expansion state.
    private var showsRows: Bool { isExpanded && !items.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SettingsDisclosureRow(
                title: String(localized: "Hero Sources"),
                subtitle: summary,
                // The chevron reports what is actually on screen, not the raw state, so it can't
                // point "up" at a platter that `showsRows` has already withheld.
                isExpanded: showsRows
            ) {
                isExpanded.toggle()
            }

            if showsRows {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(items, id: \.key) { item in
                        HeroSourceRow(
                            item: item,
                            interactive: item.heroSourceEnabled || selectedCount < limit
                        ) { enabled in
                            onToggle(item.key, enabled)
                        }
                    }
                }
                .padding(.leading, Theme.Spacing.md)
            }
        }
        // NO `.animation(_:value: isExpanded)` and no `.transition(.opacity)` here any more, and
        // that is the fix, not an oversight (device video 2026-08-29, §(b) "removing a catalog →
        // big white screen"). This group is ONE List row holding a `ForEach` of focusable toggle
        // rows, so an add-on emission can delete the row that currently holds focus. The two
        // modifiers could not be scoped to "expansion only": the empty-`items` guard below changes
        // `isExpanded` in the SAME transaction as the shrink, which is exactly the transaction an
        // `.animation(value:)` picks up — so the focus engine would be reassigning against a
        // subtree that is mid-fade rather than one that is simply gone. Unanimated, the removal
        // lands in a single pass and the system reassigns to a surviving sibling row on its own,
        // which is the behaviour this repo prefers over any hand-rolled retarget. Correctness over
        // polish: the price is that expanding/collapsing now snaps.
        //
        // The guard itself: if the list empties while expanded, drop back to the collapsed header —
        // never leave an expanded platter whose entire focusable subtree just vanished (BUG-47
        // class). The header row is a plain `Button` that stays mounted in every state, so it is
        // the stable focusable ancestor the engine lands on. Defensive as written — the call site
        // only builds this group when the filtered list is non-empty, so today the group is removed
        // wholesale instead (focus then falls to the adjacent "Nuvio-Style Hero" toggle row) — but
        // the invariant now lives with the view that has to honour it.
        .onChange(of: items.isEmpty) { _, isEmpty in
            if isEmpty { isExpanded = false }
        }
    }
}

/// The per-catalog enable/reorder list under "Show Catalog Type in Titles": collapsed by default
/// behind a header row ("Catalogs" + "N of M enabled" summary + chevron), matching the Hero
/// Sources treatment above per the same device feedback. Expanding reveals the existing
/// `CatalogSettingRow` list unchanged — enable/move up/move down behave exactly as before.
///
/// Same focus contract as `HeroSourcesGroup`: no animation over a data-driven row removal, and an
/// empty `items` collapses back to the header rather than leaving an expanded platter behind. This
/// is the group the tester was standing in when the screen died, so the reasoning is spelled out
/// again at the guard in `body` rather than cross-referenced away.
private struct HomeCatalogsGroup: View {
    let items: [HomeCatalogSettingsItem]
    let onToggle: (HomeCatalogSettingsItem) -> Void
    let onUp: (HomeCatalogSettingsItem) -> Void
    let onDown: (HomeCatalogSettingsItem) -> Void
    @State private var isExpanded = false

    private var enabledCount: Int {
        items.filter { $0.enabled }.count
    }

    /// See `HeroSourcesGroup.showsRows` — expanded content is gated on the data as well as on the
    /// user's expansion state, so an emptied list can never render as a platter with no rows.
    private var showsRows: Bool { isExpanded && !items.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SettingsDisclosureRow(
                title: String(localized: "Catalogs"),
                subtitle: String(localized: "\(enabledCount) of \(items.count) enabled"),
                isExpanded: showsRows
            ) {
                isExpanded.toggle()
            }

            if showsRows {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(items, id: \.key) { item in
                        CatalogSettingRow(
                            item: item,
                            onToggle: { onToggle(item) },
                            onUp: { onUp(item) },
                            onDown: { onDown(item) }
                        )
                    }
                }
                .padding(.leading, Theme.Spacing.md)
            }
        }
        // The animation and the opacity transition are gone on purpose — this is the group the
        // 2026-08-29 device video died in ("removing a catalog → big white screen"). It is ONE List
        // row wrapping a `ForEach` of focusable rows, so removing an add-on deletes rows out from
        // under the user's focus; animating that deletion (which an `.animation(value: isExpanded)`
        // does as soon as anything also flips `isExpanded` in the same transaction, e.g. the guard
        // below) leaves the focus engine reassigning against a fading subtree. Unanimated, the rows
        // vanish in one pass and the system moves focus to a surviving sibling row by itself —
        // system focus behaviour, not a hand-rolled retarget.
        //
        // Empty-list guard: collapse back to the header, which is focusable and stays mounted, so
        // the expanded platter is never left with an empty focusable subtree (BUG-47 class).
        // Defensive today — the pane swaps to its `model.catalogs.isEmpty` branch (which now
        // carries its own focusable row) before this group can be handed an empty list — but the
        // group no longer depends on that call-site detail to stay focus-safe.
        .onChange(of: items.isEmpty) { _, isEmpty in
            if isEmpty { isExpanded = false }
        }
    }
}

/// Shared collapsed/expanded header row for the two collapsible Home Screen groups above: title +
/// a live summary subtitle + a chevron that rotates 180° between collapsed (pointing down) and
/// expanded (pointing up). C4: converted off the legacy full-width row button style and its
/// focus-aware text-colour modifier onto a plain default-style `Button` (`SettingsActionRow`'s
/// pattern) with a trailing chevron the system list row draws and inverts on focus for free, same
/// as every other kit row in this file.
private struct SettingsDisclosureRow: View {
    let title: String
    let subtitle: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                SettingsRowLabel(title: title, subtitle: subtitle)
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(SettingsRowFont.title)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A single Hero Sources row: catalog title + add-on, with an on/off indicator. Non-interactive
/// (dimmed, disabled) when the 2-source limit is reached and this row is currently off. C4:
/// converted onto `SettingsToggleRow` (a real `Toggle`) instead of the hand-rolled checkmark
/// Button — the disabled state now uses `.disabled`, which the system already dims/ignores input
/// for, so the manual `.opacity(interactive ? 1 : 0.4)` is gone too.
private struct HeroSourceRow: View {
    let item: HomeCatalogSettingsItem
    let interactive: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        SettingsToggleRow(
            title: item.displayTitle,
            subtitle: item.addonName,
            isOn: Binding(
                get: { item.heroSourceEnabled },
                set: { onToggle($0) }
            )
        )
        .disabled(!interactive)
    }
}

/// A Home-catalog row: title + add-on, with reorder (up/down) and an enable toggle.
private struct CatalogSettingRow: View {
    let item: HomeCatalogSettingsItem
    let onToggle: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(item.displayTitle)
                    .font(Theme.Font.body)
                    .foregroundStyle(item.enabled ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                Text(item.addonName)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.lg)

            Button(action: onUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.chip)
            .accessibilityLabel(String(localized: "Move Up"))

            Button(action: onDown) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.chip)
            .accessibilityLabel(String(localized: "Move Down"))

            Button(action: onToggle) {
                Image(systemName: item.enabled ? "checkmark.circle.fill" : "circle")
                    .rowAccentTint(item.enabled)
            }
            .buttonStyle(.chip)
            .accessibilityLabel(item.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity)
    }
}
