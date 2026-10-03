import SwiftUI
import SharedCore

/// "Sources" category content (detail-settings-revamp W2-C): where streams, metadata, ratings,
/// library/progress and search results come from. Absorbs the old "Content Sources" pane plus the
/// Auto-Play Source and source-filter sections that used to live under Playback. Logic and
/// bindings are unchanged. Returns ROWS ONLY; the pane scaffold supplies the List.
struct SourcesSettingsPane: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var plugins: PluginsViewModel

    var body: some View {
        Group {
            // Orivio batch, item 1: Detail's Play button honours this (a plain press starts the
            // first source in the Sources order; hold Play opens the list instead).
            SettingsSection(
                String(localized: "Auto-Play Source"),
                footer: String(localized: "Play starts the first source in your Sources order by itself. Hold Play to choose one.")
            ) {
                SettingsToggleRow(
                    title: String(localized: "Auto-Play Best Source"),
                    isOn: Binding(get: { model.autoPlayBestSource }, set: { model.setAutoPlayBestSource($0) }),
                    descriptionID: .sourcesAutoPlayBest
                )
                if model.autoPlayBestSource {
                    SettingsToggleRow(
                        title: String(localized: "Cached Sources Only"),
                        subtitle: String(localized: "Only start a link your debrid service already has cached; otherwise show the list."),
                        isOn: Binding(get: { model.autoPlayCachedOnly }, set: { model.setAutoPlayCachedOnly($0) }),
                        descriptionID: .sourcesAutoPlayCachedOnly
                    )
                }
            }

            // Orivio batch: global source ordering + filters, applied to every add-on's streams.
            SettingsSection(
                String(localized: "Source Filters"),
                footer: String(localized: "Applies to every add-on's sources on this Apple TV.")
            ) {
                SettingsPickerRow(
                    title: String(localized: "Sort Sources"),
                    selection: Binding(get: { model.streamSortMode }, set: { model.setStreamSortMode($0) }),
                    options: SourceSettingOptions.sortKeys,
                    descriptionID: .sourcesSort,
                    label: SourceSettingOptions.sortName(forKey:)
                )
                SettingsPickerRow(
                    title: String(localized: "Minimum Resolution"),
                    subtitle: String(localized: "Sources with no resolution tag are kept."),
                    selection: Binding(get: { model.streamMinimumQuality }, set: { model.setStreamMinimumQuality($0) }),
                    options: SourceSettingOptions.minimumQualityKeys,
                    descriptionID: .sourcesMinResolution,
                    label: SourceSettingOptions.minimumQualityName(forKey:)
                )
                SettingsPickerRow(
                    title: String(localized: "Dolby Vision"),
                    selection: Binding(get: { model.streamDolbyVisionFilter }, set: { model.setStreamDolbyVisionFilter($0) }),
                    options: SourceSettingOptions.featureFilterKeys,
                    descriptionID: .sourcesDvFilter,
                    label: SourceSettingOptions.featureFilterName(forKey:)
                )
                SettingsPickerRow(
                    title: String(localized: "HDR"),
                    selection: Binding(get: { model.streamHdrFilter }, set: { model.setStreamHdrFilter($0) }),
                    options: SourceSettingOptions.featureFilterKeys,
                    descriptionID: .sourcesHdrFilter,
                    label: SourceSettingOptions.featureFilterName(forKey:)
                )
                // Only meaningful while a debrid service is connected and enabled: nothing is
                // "cached" otherwise.
                if model.debridCanResolvePlayableLinks {
                    SettingsToggleRow(
                        title: String(localized: "Cached Sources Only"),
                        subtitle: String(localized: "Hide sources your debrid service has not cached."),
                        isOn: Binding(get: { model.streamCachedOnly }, set: { model.setStreamCachedOnly($0) }),
                        descriptionID: .sourcesCachedOnlyFilter
                    )
                }
            }

            SettingsSection(String(localized: "Metadata (TMDB)")) {
                Text("Enrich titles with cast profiles, studios & networks, collections, and better artwork. Titles you open after enabling will be enriched.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)

                SettingsToggleRow(
                    title: String(localized: "TMDB Enrichment"),
                    subtitle: String(localized: "Bundled key \u{2014} no setup needed"),
                    isOn: Binding(
                        get: { model.tmdbEnabled },
                        set: { model.setTmdbEnabled($0) }
                    ),
                    descriptionID: .sourcesTmdbEnrichment
                )
                if model.tmdbHasPersonalKey {
                    SettingsDestructiveRow(
                        title: String(localized: "Remove Personal API Key"),
                        subtitle: String(localized: "Personal key saved. Removing it goes back to the built-in key."),
                        systemImage: "trash",
                        descriptionID: .sourcesTmdbKey
                    ) {
                        model.clearTmdbKey()
                    }
                } else {
                    Group {
                        DebridKeyEntryRow(
                            providerName: "TMDB",
                            placeholder: String(localized: "Personal API Key (Optional)"),
                            descriptionID: .sourcesTmdbKey
                        ) {
                            model.saveTmdbKey($0)
                        }
                        Text("Leave empty to use the built-in key.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }
                }
                SettingsToggleRow(
                    title: String(localized: "TMDB Release Dates"),
                    subtitle: model.tmdbUseReleaseDates
                        ? String(localized: "TMDB air dates override add-on release dates")
                        : String(localized: "add-on release dates are used as-is"),
                    isOn: Binding(
                        get: { model.tmdbUseReleaseDates },
                        set: { model.setTmdbUseReleaseDates($0) }
                    ),
                    descriptionID: .sourcesTmdbReleaseDates
                )
                Text("Language for TMDB titles, descriptions, logos and the Home hero. Device follows this Apple TV's language.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)
                SettingsPickerRow(
                    title: String(localized: "Metadata Language"),
                    selection: Binding(
                        get: { model.tmdbLanguageSelection },
                        set: { model.setTmdbLanguage($0) }
                    ),
                    options: LanguageOptions.tmdbMetadata.map(\.code),
                    descriptionID: .sourcesTmdbLanguage,
                    label: { LanguageOptions.name(forCode: $0, in: LanguageOptions.tmdbMetadata) }
                )
            }

            SettingsSection(String(localized: "Ratings (MDBList)")) {
                Text("Show IMDb, Rotten Tomatoes, Metacritic, Trakt and Letterboxd scores in a title's Details. Connect MDBList in Services, or add a free API key from mdblist.com \u{2192} Preferences \u{2192} API Access. Titles you open afterwards will show the ratings.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)

                SettingsToggleRow(
                    title: String(localized: "MDBList Ratings"),
                    subtitle: model.mdbListHasPersonalKey ? String(localized: "API key saved") : nil,
                    isOn: Binding(
                        get: { model.mdbListEnabled },
                        set: { model.setMdbListEnabled($0) }
                    ),
                    descriptionID: .sourcesMdblistRatings
                )
                if model.mdbListHasPersonalKey {
                    SettingsDestructiveRow(
                        title: String(localized: "Remove API Key"),
                        subtitle: String(localized: "Clears the saved MDBList key."),
                        systemImage: "trash",
                        descriptionID: .sourcesMdblistKey
                    ) {
                        model.clearMdbListKey()
                    }
                } else {
                    Group {
                        if model.mdbListUsingAccount {
                            Text("Using your connected MDBList account.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: 1100, alignment: .leading)
                        } else {
                            Text("Connect MDBList in Services, or enter a key.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: 1100, alignment: .leading)
                        }
                        DebridKeyEntryRow(
                            providerName: "MDBList",
                            placeholder: model.mdbListUsingAccount
                                ? String(localized: "Personal API Key (Optional)")
                                : String(localized: "MDBList API key"),
                            descriptionID: .sourcesMdblistKey
                        ) {
                            model.saveMdbListKey($0)
                        }
                        if model.mdbListUsingAccount {
                            Text("A personal key overrides the account.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: 1100, alignment: .leading)
                        }
                    }
                }
            }

            SettingsSection(String(localized: "Library & Watch Progress")) {
                librarySection
            }

            // FEAT-10 (tester ask): choose which catalogs Search fans out to. Fewer sources
            // means faster, more focused results — the fan-out across every search-capable
            // catalog of every addon is also the app's biggest single burst of requests.
            SettingsSection(String(localized: "Search Sources")) {
                searchSourcesSection
            }

            SettingsSection(String(localized: "Plugins")) {
                pluginsSection
            }
        }
    }

    /// Display names for the Library Source / Watch Progress Source pickers below, keyed by the
    /// shared repo's provider-neutral mode strings.
    private static let librarySourceLabels: [(name: String, code: String)] = [
        (String(localized: "Nuvio Library"), "local"),
        (String(localized: "Trakt"), "trakt"),
        (String(localized: "Simkl"), "simkl"),
        (String(localized: "MDBList"), "mdblist"),
    ]
    private static let watchProgressSourceLabels: [(name: String, code: String)] = [
        (String(localized: "Nuvio Sync"), "nuvio_sync"),
        (String(localized: "Trakt"), "trakt"),
        (String(localized: "Simkl"), "simkl"),
        (String(localized: "MDBList"), "mdblist"),
    ]

    /// Library Source (which backend the Library tab reads from) and Watch Progress Source (which
    /// backend owns Continue Watching / watched history). Both are provider-neutral picks backed by
    /// `TrackingSettingsRepository`; the shared layer falls back to the local/Nuvio option on its
    /// own if the chosen provider isn't connected (`effectiveLibrarySourceMode` /
    /// `effectiveWatchProgressSource`), so this pane doesn't need to gate the options itself.
    @ViewBuilder
    private var librarySection: some View {
        Text("Choose where your library and watch progress are saved. Connect Trakt, Simkl, or MDBList in Services first to use them as a source \u{2014} otherwise this Apple TV falls back to its local/Nuvio option automatically.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        SettingsPickerRow(
            title: String(localized: "Library Source"),
            selection: Binding(
                get: { model.librarySourceMode },
                set: { model.setLibrarySourceMode($0) }
            ),
            options: Self.librarySourceLabels.map(\.code),
            descriptionID: .sourcesLibrarySource,
            label: { code in LanguageOptions.name(forCode: code, in: Self.librarySourceLabels) }
        )

        SettingsPickerRow(
            title: String(localized: "Watch Progress Source"),
            selection: Binding(
                get: { model.watchProgressSource },
                set: { model.setWatchProgressSource($0) }
            ),
            options: Self.watchProgressSourceLabels.map(\.code),
            descriptionID: .sourcesWatchProgressSource,
            label: { code in LanguageOptions.name(forCode: code, in: Self.watchProgressSourceLabels) }
        )
    }

    /// FEAT-10: one toggle per search-capable catalog. Rows derive from the installed addons
    /// (SettingsViewModel's addon watcher), the disabled set is local to this Apple TV.
    @ViewBuilder
    private var searchSourcesSection: some View {
        // Upstream 7c1c6578: on/off switch for recording new recent searches (and showing
        // existing ones) on the Search screen. rc13: this Apple TV only — `SearchHistoryStorage`
        // has no sync export/import, the key is a device-local NSUserDefaults value (unlike
        // "Hide Discover" below, which really is synced per profile).
        SettingsToggleRow(
            title: String(localized: "Recent Searches"),
            subtitle: model.recentSearchesEnabled
                ? String(localized: "Search remembers what you've searched for")
                : String(localized: "Past searches are hidden and new ones aren't saved"),
            isOn: Binding(
                get: { model.recentSearchesEnabled },
                set: { model.setRecentSearchesEnabled($0) }
            ),
            descriptionID: .sourcesRecentSearches
        )

        // UX-8 (u/mrStevenx3, restated three times, finally "completely hide the Discover
        // section"): one container-level toggle. Synced per profile — deliberately NOT under the
        // "this Apple TV only" caption below, which describes the per-catalog rows.
        SettingsToggleRow(
            title: String(localized: "Hide Discover"),
            subtitle: model.hideDiscover
                ? String(localized: "Search shows only the search field and recent searches")
                : String(localized: "Search shows the Discover section (types, catalogs, genres) below the field"),
            isOn: Binding(
                get: { model.hideDiscover },
                set: { model.setHideDiscover($0) }
            ),
            descriptionID: .sourcesHideDiscover
        )

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
                // Legacy bare keys disable a whole collision group; exact-match misses that (Codex finding 2/4 follow-up).
                let disabled = SearchRepository.shared.isSearchSourceDisabled(optionKey: option.key, disabledCatalogKeys: model.disabledSearchSourceKeys)
                SettingsToggleRow(
                    title: "\(option.catalogName) \u{00B7} \(option.typeLabel)",
                    subtitle: disabled
                        ? String(localized: "\(option.addonName) \u{00B7} skipped when searching")
                        : String(localized: "\(option.addonName)"),
                    isOn: Binding(
                        get: { !disabled },
                        set: { model.setSearchSource(key: option.key, disabled: !$0) }
                    ),
                    descriptionID: .sourcesSearchCatalog
                )
            }

            // BUG-33 defect 1 (P1, twice re-opened): the tester's only way to confirm a
            // deselected catalog was actually skipped was a device log capture — and the
            // diagnostic that shipped logged at debug level, which os_log hides by default
            // (BUG-11). This mirrors it in-app: one caption naming exactly which catalogs the
            // last search hit, screenshot-able from this exact pane.
            Text(model.lastSearchFanOut ?? String(localized: "No search performed yet."))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
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
            isOn: Binding(
                get: { plugins.pluginsEnabled },
                set: { plugins.setPluginsEnabled($0) }
            ),
            descriptionID: .sourcesPluginsEnabled
        )

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
                                .settingsDescription(.sourcesPluginRepo, title: String(localized: "Remove Repository"), systemImage: "trash")
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
                            isOn: Binding(
                                get: { scraper.enabled },
                                set: { plugins.toggleScraper(scraper, $0) }
                            ),
                            descriptionID: .sourcesPluginScraper
                        )
                    }
                }
            }
            SettingsActionRow(
                title: String(localized: "Refresh Plugins"),
                subtitle: String(localized: "Re-download provider code from every repository."),
                systemImage: "arrow.clockwise",
                descriptionID: .sourcesPluginsRefresh
            ) {
                plugins.refreshAll()
            }
        }
    }
}

/// Picker keys + labels for the "Source Filters" section: the Swift string keys `SettingsViewModel`
/// maps to `DebridStreamSortMode` / `DebridStreamMinimumQuality` / `DebridStreamFeatureFilter` (a
/// `Menu` row binds a plain key, not a bridged Kotlin enum).
private enum SourceSettingOptions {
    static let sortKeys = ["default", "quality", "sizeDesc", "sizeAsc"]
    static let minimumQualityKeys = ["any", "720", "1080", "2160"]
    static let featureFilterKeys = ["any", "only", "exclude"]

    static func sortName(forKey key: String) -> String {
        switch key {
        case "quality": return String(localized: "Quality")
        case "sizeDesc": return String(localized: "Largest First")
        case "sizeAsc": return String(localized: "Smallest First")
        default: return String(localized: "Default")
        }
    }

    static func minimumQualityName(forKey key: String) -> String {
        switch key {
        case "720": return String(localized: "720p")
        case "1080": return String(localized: "1080p")
        case "2160": return String(localized: "2160p")
        default: return String(localized: "Any")
        }
    }

    static func featureFilterName(forKey key: String) -> String {
        switch key {
        case "only": return String(localized: "Only")
        case "exclude": return String(localized: "Exclude")
        default: return String(localized: "Any")
        }
    }
}

/// Manifest-URL entry for installing a plugin repository from the TV (mirrors the addon install
/// row; the shared repo normalizes the URL and appends /manifest.json). The text field reports
/// through its own `@FocusState`; the Install label carries the modifier for the button.
private struct PluginRepoEntryRow: View {
    let isInstalling: Bool
    let onInstall: (String) -> Void
    @State private var url = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("Repository manifest URL", text: $url)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .focused($fieldFocused)
            }
            .padding(Theme.Spacing.lg)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .settingsDescription(.sourcesPluginRepoAdd, title: String(localized: "Repository manifest URL"), systemImage: "puzzlepiece.extension", focused: fieldFocused)

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
                        .settingsDescription(.sourcesPluginRepoAdd, title: String(localized: "Install Repository"), systemImage: "plus")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInstalling)
        }
    }
}
