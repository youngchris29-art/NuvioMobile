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

    var body: some View {
        settingsSection(String(localized: "Home Rows")) {
            if model.catalogs.isEmpty {
                Text("Install add-ons to customize your Home rows.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                SettingsToggleRow(
                    title: String(localized: "Show Hero"),
                    subtitle: model.heroEnabled
                        ? String(localized: "On \u{00B7} Home opens with a rotating banner built from up to 2 of your catalogs")
                        : String(localized: "Off \u{00B7} Home starts directly with catalog rows"),
                    isOn: model.heroEnabled
                ) {
                    model.setHeroEnabled(!model.heroEnabled)
                }

                // Collections are hard-forced to heroSourceEnabled = false on the
                // Kotlin side (HomeCatalogSettingsRepository.normalizePreferences),
                // so they never appear as a hero source — filter defensively here too.
                if model.heroEnabled {
                    // UX-2 hero redesign v2: title/description on the left with the artwork
                    // reading on the right (Nuvio-style, OPT-IN) vs the classic lower-left
                    // logo layout (default).
                    SettingsToggleRow(
                        title: String(localized: "Nuvio-Style Hero"),
                        subtitle: heroNuvioStyle
                            ? String(localized: "On \u{00B7} Title and description on the left, artwork on the right")
                            : String(localized: "Off \u{00B7} Classic layout with the logo on the lower left"),
                        isOn: heroNuvioStyle
                    ) {
                        heroNuvioStyle.toggle()
                    }

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
                    subtitle: inlineTrailersEnabled
                        ? String(localized: "On \u{00B7} Posters play a muted trailer preview after a moment of focus")
                        : String(localized: "Off \u{00B7} Posters show artwork only"),
                    isOn: inlineTrailersEnabled
                ) {
                    inlineTrailersEnabled.toggle()
                }

                SettingsToggleRow(
                    title: String(localized: "Show Catalog Type in Titles"),
                    subtitle: model.showCatalogType
                        ? String(localized: "On \u{00B7} rows read like \u{201C}Popular - Movies\u{201D}")
                        : String(localized: "Off \u{00B7} rows use the add-on's catalog name"),
                    isOn: model.showCatalogType
                ) {
                    model.setShowCatalogType(!model.showCatalogType)
                }

                HomeCatalogsGroup(
                    items: model.catalogs,
                    onToggle: { model.toggleCatalog($0) },
                    onUp: { model.moveUp($0) },
                    onDown: { model.moveDown($0) }
                )
            }
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
/// only ever happens from the header row's own Button action, so focus is already on the header
/// at that moment — no separate FocusState retargeting is needed the way StreamPickerView's
/// multi-trigger expansion needs it.
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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SettingsDisclosureRow(
                title: String(localized: "Hero Sources"),
                subtitle: summary,
                isExpanded: isExpanded
            ) {
                isExpanded.toggle()
            }

            if isExpanded {
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
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

/// The per-catalog enable/reorder list under "Show Catalog Type in Titles": collapsed by default
/// behind a header row ("Catalogs" + "N of M enabled" summary + chevron), matching the Hero
/// Sources treatment above per the same device feedback. Expanding reveals the existing
/// `CatalogSettingRow` list unchanged — enable/move up/move down behave exactly as before.
private struct HomeCatalogsGroup: View {
    let items: [HomeCatalogSettingsItem]
    let onToggle: (HomeCatalogSettingsItem) -> Void
    let onUp: (HomeCatalogSettingsItem) -> Void
    let onDown: (HomeCatalogSettingsItem) -> Void
    @State private var isExpanded = false

    private var enabledCount: Int {
        items.filter { $0.enabled }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SettingsDisclosureRow(
                title: String(localized: "Catalogs"),
                subtitle: String(localized: "\(enabledCount) of \(items.count) enabled"),
                isExpanded: isExpanded
            ) {
                isExpanded.toggle()
            }

            if isExpanded {
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
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

/// Shared collapsed/expanded header row for the two collapsible Home Screen groups above: title +
/// a live summary subtitle + a chevron that rotates 180° between collapsed (pointing down) and
/// expanded (pointing up). Styled like the section's other top-level rows (`SettingsToggleRow`,
/// `DefaultPlayerRow`) so it reads as a peer row, not a nested control.
private struct SettingsDisclosureRow: View {
    let title: String
    let subtitle: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsRow)
    }
}

/// A single Hero Sources row: catalog title + add-on, with an on/off indicator. Non-interactive
/// (dimmed, ignores input) when the 2-source limit is reached and this row is currently off.
private struct HeroSourceRow: View {
    let item: HomeCatalogSettingsItem
    let interactive: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Button {
            onToggle(!item.heroSourceEnabled)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(item.displayTitle)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text(item.addonName)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: item.heroSourceEnabled ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Font.body)
                    .foregroundStyle(item.heroSourceEnabled ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(maxWidth: .infinity)
            .opacity(interactive ? 1 : 0.4)
        }
        .buttonStyle(.settingsRow)
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
                    .foregroundStyle(item.enabled ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            .buttonStyle(.chip)
            .accessibilityLabel(item.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity)
    }
}
