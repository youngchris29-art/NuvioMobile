import SwiftUI
import SharedCore

/// "Content Sources" category content: TMDB metadata enrichment, MDBList ratings, and JS plugin
/// providers. Extracted from SettingsView.swift (Phase 2 HIG revamp file split) — logic and
/// wiring preserved verbatim, only regrouped into a per-category pane.
struct ContentSourcesSettingsPane: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var plugins: PluginsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
            settingsSection(String(localized: "Metadata (TMDB)")) {
                Text("Add a free TMDB API key to enrich titles with cast profiles, studios & networks, collections, and better artwork. Create one at themoviedb.org \u{2192} Settings \u{2192} API (v3 auth). Titles you open after enabling will be enriched.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)

                if model.tmdbHasKey {
                    SettingsToggleRow(
                        title: String(localized: "TMDB Enrichment"),
                        subtitle: model.tmdbEnabled ? String(localized: "On \u{00B7} API key saved") : String(localized: "Off \u{00B7} API key saved"),
                        isOn: model.tmdbEnabled
                    ) {
                        model.setTmdbEnabled(!model.tmdbEnabled)
                    }
                    SettingsToggleRow(
                        title: String(localized: "TMDB Release Dates"),
                        subtitle: model.tmdbUseReleaseDates
                            ? String(localized: "On \u{00B7} TMDB air dates override add-on release dates")
                            : String(localized: "Off \u{00B7} add-on release dates are used as-is"),
                        isOn: model.tmdbUseReleaseDates
                    ) {
                        model.setTmdbUseReleaseDates(!model.tmdbUseReleaseDates)
                    }
                    Text("Language for TMDB titles, descriptions, logos and the Home hero. Device follows this Apple TV's language.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                    LanguageSelectRow(
                        title: String(localized: "Metadata Language"),
                        options: LanguageOptions.tmdbMetadata,
                        selected: model.tmdbLanguageSelection
                    ) { model.setTmdbLanguage($0) }
                    SettingsActionRow(
                        title: String(localized: "Remove API Key"),
                        subtitle: String(localized: "Clears the saved TMDB key and turns enrichment off."),
                        systemImage: "trash"
                    ) {
                        model.clearTmdbKey()
                    }
                } else {
                    TmdbKeyEntryRow { model.saveTmdbKey($0) }
                }
            }

            settingsSection(String(localized: "Ratings (MDBList)")) {
                Text("Add a free MDBList API key to show IMDb, Rotten Tomatoes, Metacritic, Trakt and Letterboxd scores in a title's Details. Create one at mdblist.com \u{2192} Preferences \u{2192} API Access. Titles you open after enabling will show the ratings.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)

                if model.mdbListHasKey {
                    SettingsToggleRow(
                        title: String(localized: "MDBList Ratings"),
                        subtitle: model.mdbListEnabled ? String(localized: "On \u{00B7} API key saved") : String(localized: "Off \u{00B7} API key saved"),
                        isOn: model.mdbListEnabled
                    ) {
                        model.setMdbListEnabled(!model.mdbListEnabled)
                    }
                    SettingsActionRow(
                        title: String(localized: "Remove API Key"),
                        subtitle: String(localized: "Clears the saved MDBList key and turns ratings off."),
                        systemImage: "trash"
                    ) {
                        model.clearMdbListKey()
                    }
                } else {
                    DebridKeyEntryRow(providerName: "MDBList", placeholder: String(localized: "MDBList API key")) {
                        model.saveMdbListKey($0)
                    }
                }
            }

            // FEAT-10 (tester ask): choose which catalogs Search fans out to. Fewer sources
            // means faster, more focused results — the fan-out across every search-capable
            // catalog of every addon is also the app's biggest single burst of requests.
            settingsSection(String(localized: "Search Sources")) {
                searchSourcesSection
            }

            settingsSection(String(localized: "Plugins")) {
                pluginsSection
            }
        }
    }

    /// FEAT-10: one toggle per search-capable catalog. Rows derive from the installed addons
    /// (SettingsViewModel's addon watcher), the disabled set is local to this Apple TV.
    @ViewBuilder
    private var searchSourcesSection: some View {
        Text("Choose which catalogs Search looks through. Fewer sources means faster, more focused results. Applies to this Apple TV only.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        if model.searchSourceOptions.isEmpty {
            Text("No installed add-on offers search. Install a catalog add-on with search support and its sources will appear here.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        } else {
            ForEach(model.searchSourceOptions, id: \.key) { option in
                let disabled = model.disabledSearchSourceKeys.contains(option.key)
                SettingsToggleRow(
                    title: "\(option.catalogName) \u{00B7} \(option.typeLabel)",
                    subtitle: disabled
                        ? String(localized: "Off \u{00B7} \(option.addonName) \u{00B7} skipped when searching")
                        : String(localized: "On \u{00B7} \(option.addonName)"),
                    isOn: !disabled
                ) {
                    model.setSearchSource(key: option.key, disabled: !disabled)
                }
            }
        }
    }

    /// The Plugins section body: master switch + per-scraper toggles. Repos are managed on the
    /// phone and arrive via cloud sync (sync-only v1) — reflected in the empty-state copy.
    @ViewBuilder
    private var pluginsSection: some View {
        Text("JS plugin providers add extra stream sources. Install a repository by its manifest URL \u{2014} it syncs to your other Nuvio devices automatically.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        SettingsToggleRow(
            title: String(localized: "Enable Plugins"),
            subtitle: String(localized: "Run enabled plugin providers when loading streams."),
            isOn: plugins.pluginsEnabled
        ) {
            plugins.setPluginsEnabled(!plugins.pluginsEnabled)
        }

        PluginRepoEntryRow(isInstalling: plugins.isInstalling) { plugins.addRepository($0) }

        if let status = plugins.statusMessage {
            Text(status)
                .font(Theme.Font.caption)
                .foregroundStyle(status.hasPrefix("Installed") ? Theme.Palette.textSecondary : .red)
        }

        if plugins.repositories.isEmpty {
            Text("No plugin repositories installed yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else {
            ForEach(plugins.repositories, id: \.manifestUrl) { repo in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(repo.name)
                            .font(Theme.Font.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if repo.isRefreshing {
                            ProgressView().scaleEffect(0.6)
                        }
                        Text(repo.scraperCount == 1 ? String(localized: "1 provider") : String(localized: "\(repo.scraperCount) providers"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Button {
                            plugins.removeRepository(repo)
                        } label: {
                            Image(systemName: "trash")
                                .font(Theme.Font.caption)
                        }
                        .buttonStyle(.chip)
                    }
                    if let error = repo.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.red)
                    }
                    ForEach(plugins.scrapers(in: repo), id: \.id) { scraper in
                        SettingsToggleRow(
                            title: scraper.name,
                            subtitle: scraper.description_.isEmpty
                                ? String(localized: "v\(scraper.version)")
                                : String(localized: "\(scraper.description_) \u{00B7} v\(scraper.version)"),
                            isOn: scraper.enabled
                        ) {
                            plugins.toggleScraper(scraper, !scraper.enabled)
                        }
                    }
                }
            }
            SettingsActionRow(
                title: String(localized: "Refresh Plugins"),
                subtitle: String(localized: "Re-download provider code from every repository."),
                systemImage: "arrow.clockwise"
            ) {
                plugins.refreshAll()
            }
        }
    }
}

/// TMDB API key entry: a tvOS `TextField` (opens the full-screen keyboard, dismisses on commit) plus
/// a Save button. The shared repo trims the key and enables enrichment; we only guard against empty.
private struct TmdbKeyEntryRow: View {
    let onSave: (String) -> Void
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "key")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("TMDB API Key (v3 auth)", text: $key)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .padding(Theme.Spacing.lg)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            Button {
                if !key.isEmpty { onSave(key) }
            } label: {
                Label("Save & Enable", systemImage: "checkmark")
                    .font(Theme.Font.meta)
                    .prominentAccentLabel()
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xxs + 2)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.accent)
            .disabled(key.isEmpty)
        }
    }
}

/// Manifest-URL entry for installing a plugin repository from the TV (mirrors the addon install
/// row; the shared repo normalizes the URL and appends /manifest.json).
private struct PluginRepoEntryRow: View {
    let isInstalling: Bool
    let onInstall: (String) -> Void
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("Repository manifest URL", text: $url)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .padding(Theme.Spacing.lg)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            Button {
                if !url.isEmpty {
                    onInstall(url)
                    url = ""
                }
            } label: {
                if isInstalling {
                    ProgressView()
                } else {
                    Label("Install Repository", systemImage: "plus")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xxs + 2)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInstalling)
        }
    }
}
