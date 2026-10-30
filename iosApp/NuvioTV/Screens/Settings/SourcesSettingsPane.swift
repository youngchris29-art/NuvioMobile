import SwiftUI
import SharedCore

/// "Sources" category content (detail-settings-revamp W2-C): where streams, metadata, ratings,
/// library/progress and search results come from. Absorbs the old "Content Sources" pane plus the
/// Auto-Play Source and source-filter sections that used to live under Playback. Logic and
/// bindings are unchanged. Returns ROWS ONLY; the pane scaffold supplies the List.
struct SourcesSettingsPane: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var plugins: PluginsViewModel
    /// P4.1: the shared badge/picker settings (Source Background lives with them in the shared repository).
    @ObservedObject var badges: BadgeSettingsViewModel
    /// B6: device-local Search layout. Read through `SearchRowsMode.resolve` so a stale or
    /// unknown stored value shows the default.
    @AppStorage(SearchRowsMode.defaultsKey) private var searchRowsModeRaw = SearchRowsMode.defaultValue.rawValue
    /// The viewer's own open/closed choice per plugin repository, by manifest URL (absent = the
    /// default rule, `PluginsViewModel.isRepositoryExpanded`: collapsed, except a lone repository).
    /// Stored as the choice itself, never as a flip of the default, so installing or removing
    /// another repository cannot invert it; never set in `onAppear`, which a lazy List re-fires.
    @State private var pluginRepoExpanded: [String: Bool] = [:]
    /// Drives the "Remove repository?" confirmation.
    @State private var pendingPluginRepoRemoval: PluginRepositoryItem?
    /// W3-2 (c): the manifest URL of a repository whose removal was just confirmed. Once it leaves
    /// `plugins.repositories` the manifest field takes focus (the Remove row it came from is gone).
    @State private var pendingFocusAfterRemoval: String?
    @FocusState private var manifestFieldFocused: Bool
    /// BUG-213 focus hand-off for the TMDB and MDBList key rows. Save swaps the key field and Save
    /// rows for the Remove row, and Remove swaps them back, so the focused control leaves the
    /// hierarchy both ways. The pressed row arms its replacement ("tmdb:remove" / "tmdb:field",
    /// "mdblist:remove" / "mdblist:field"); the replacement claims focus once when it appears. One
    /// value, so a later press simply overwrites an armed one.
    @State private var keyFocusHandOff: String?

    private func keyHandOff(_ target: String) -> Binding<Bool> {
        Binding(
            get: { keyFocusHandOff == target },
            set: { if !$0, keyFocusHandOff == target { keyFocusHandOff = nil } }
        )
    }

    /// Whether a saved key will stick: both repositories store the trimmed key, and a blank one
    /// clears it, which swaps nothing (so nothing may be armed for it).
    private static func keepsKey(_ key: String) -> Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchRowsModeBinding: Binding<SearchRowsMode> {
        Binding(
            get: { SearchRowsMode.resolve(searchRowsModeRaw) },
            set: { searchRowsModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            // Orivio batch, item 1: Detail's Play button honours this (a plain press starts a
            // source by itself; hold Play opens the list instead). beta.19-rc1 verdict (A,
            // BUG-136): "best" is now a real ranking among the sources that arrived (resolution,
            // then HDR / Dolby Vision, then cached, then file size), not the first one in the list.
            SettingsSection(
                String(localized: "Auto-Play Source"),
                footer: String(localized: "Play starts the best source that has arrived: highest resolution first, then HDR or Dolby Vision, then cached links, then the largest file. Hold Play to choose one.")
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

            // Stream picker A, P4.1 (decision D1): the picker's backdrop. Cinematic by default on tvOS;
            // Normal is today's plain background. Stored with the badge settings (per profile, synced).
            SettingsSection(String(localized: "Source List")) {
                SettingsPickerRow(
                    title: String(localized: "Source Background"),
                    selection: Binding(get: { badges.backgroundMode }, set: { badges.setBackgroundMode($0) }),
                    options: SourceSettingOptions.backgroundModes,
                    descriptionID: .sourcesBackground,
                    label: SourceSettingOptions.backgroundModeName(for:)
                )
                // Polish batch D5: how the picker groups its rows. Default Quality, stored with the
                // badge settings (per profile on this Apple TV, not synced).
                SettingsPickerRow(
                    title: String(localized: "Group Sources By"),
                    selection: Binding(get: { badges.groupingMode }, set: { badges.setGroupingMode($0) }),
                    options: SourceSettingOptions.groupingModes,
                    descriptionID: .sourcesGrouping,
                    label: SourceSettingOptions.groupingModeName(for:)
                )
                // Direction C D9: what the source list opens on. Default Best Pick, stored with the
                // badge settings (per profile on this Apple TV, not synced).
                SettingsPickerRow(
                    title: String(localized: "Source List Opens With"),
                    selection: Binding(get: { badges.listOpensWith }, set: { badges.setListOpensWith($0) }),
                    options: SourceSettingOptions.listOpensWithModes,
                    descriptionID: .sourcesOpensWith,
                    label: SourceSettingOptions.listOpensWithName(for:)
                )
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
                        keyFocusHandOff = "tmdb:field"
                        model.clearTmdbKey()
                    }
                    .claimsFocusAfterSwap(keyHandOff("tmdb:remove"))
                } else {
                    Group {
                        DebridKeyEntryRow(
                            providerName: "TMDB",
                            placeholder: String(localized: "Personal API Key (Optional)"),
                            descriptionID: .sourcesTmdbKey,
                            fieldFocusHandOff: keyHandOff("tmdb:field")
                        ) { key in
                            if Self.keepsKey(key) { keyFocusHandOff = "tmdb:remove" }
                            model.saveTmdbKey(key)
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
                // A pushed list page, not a Menu: 75 entries, and a tvOS Menu opens on its first
                // entry (see `SettingsListPickerRow`).
                SettingsListPickerRow(
                    title: String(localized: "Metadata Language"),
                    selection: Binding(
                        get: { model.tmdbLanguageSelection },
                        set: { model.setTmdbLanguage($0) }
                    ),
                    // FEAT-84: Device + the 74 bare codes, A–Z (regional tags would read back as
                    // their primary subtag and check the wrong row; see `LanguageOptions`).
                    options: LanguageOptions.codes(LanguageOptions.tmdbMetadataCodes, keeping: model.tmdbLanguageSelection, pinned: 1),
                    descriptionID: .sourcesTmdbLanguage,
                    label: LanguageOptions.name(forCode:)
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
                        keyFocusHandOff = "mdblist:field"
                        model.clearMdbListKey()
                    }
                    .claimsFocusAfterSwap(keyHandOff("mdblist:remove"))
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
                            descriptionID: .sourcesMdblistKey,
                            fieldFocusHandOff: keyHandOff("mdblist:field")
                        ) { key in
                            if Self.keepsKey(key) { keyFocusHandOff = "mdblist:remove" }
                            model.saveMdbListKey(key)
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
        // has no sync export/import, the key is a device-local NSUserDefaults value (unlike the
        // Hide Discover flag behind Appearance > Discover, which really is synced per profile).
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

        // Search & Discover batch (B6): replaces the UX-8 "Hide Discover" toggle, which moved into
        // Appearance > Navigation > Discover (placement Off). Device-local.
        SettingsPickerRow(
            title: String(localized: "Search Results"),
            selection: searchRowsModeBinding,
            options: SearchRowsMode.allCases,
            descriptionID: .sourcesSearchRowsMode,
            label: { $0.label }
        )
        .accessibilityIdentifier("settings.searchRowsMode")

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
    /// Review r1 P2-1 / r2 P2-1: whatever removed a repository (the alert, a sync), both pending
    /// values clear once its URL has left the list, and focus moves to the manifest field.
    private func reconcilePendingRemoval(_ urls: [String]) {
        if let pending = pendingPluginRepoRemoval, !urls.contains(pending.manifestUrl) {
            pendingPluginRepoRemoval = nil
        }
        if let removed = pendingFocusAfterRemoval, !urls.contains(removed) {
            pendingFocusAfterRemoval = nil
            // Focus moves at once. If the device pass shows the List winning the race with the
            // dismissing alert, the device pass decides on a delay instead:
            // Task { try? await Task.sleep(for: .milliseconds(350)); manifestFieldFocused = true }
            manifestFieldFocused = true
        }
    }

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

        SettingsToggleRow(
            title: String(localized: "Group by Repository"),
            subtitle: String(localized: "In the streams list, show one group per repository instead of one per provider."),
            isOn: Binding(
                get: { plugins.groupStreamsByRepository },
                set: { plugins.setGroupStreamsByRepository($0) }
            ),
            descriptionID: .sourcesPluginsGroupByRepository
        )

        PluginRepoEntryRow(isInstalling: plugins.isInstalling, fieldFocused: $manifestFieldFocused) { plugins.addRepository($0) }
            // The repositories observer lives on the entry row because it is ALWAYS present: inside
            // the list's `else` branch it was torn down in the same update that removed the LAST
            // repository, so focus never moved and the pending values stayed set (review r1 P2-1).
            // Whatever removed the URL (the alert, a sync), both pending values clear here.
            // Wave 3 review r2 (P2-1): the entry row is a LAZY List row. With a long provider list
            // expanded it is off screen when Remove is confirmed, and an off-screen row runs no
            // `onChange`; so the same reconcile also runs when the row (re)appears.
            .onChange(of: plugins.repositories.map(\.manifestUrl)) { _, urls in
                reconcilePendingRemoval(urls)
            }
            .onAppear { reconcilePendingRemoval(plugins.repositories.map(\.manifestUrl)) }

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
            // Each repository yields SEPARATE List rows (one focusable row each): a header that
            // collapses/expands it, an optional error caption, and, while expanded, one row per
            // provider plus a Remove row. Wrapping them in one VStack made the List treat the
            // whole block as a single focusable row, so one click flipped every provider at once.
            // Repositories start collapsed so a long provider list doesn't bury the next repo.
            ForEach(plugins.repositories, id: \.manifestUrl) { repo in
                let isExpanded = PluginsViewModel.isRepositoryExpanded(stored: pluginRepoExpanded[repo.manifestUrl],
                                                                       repositoryCount: plugins.repositories.count)
                // Providers listed A–Z (Finder-style: case-insensitive, "Provider 2" before "Provider 10").
                let repoScrapers = PluginsViewModel.sortedScrapers(plugins.scrapers(in: repo))
                let enabledCount: Int = repoScrapers.filter { $0.enabled }.count
                Button {
                    pluginRepoExpanded[repo.manifestUrl] = !isExpanded
                } label: {
                    SettingsRowChrome {
                        SettingsRowLabel(
                            title: repo.name,
                            // Review r1 P3 (plural): one key per grammatical number, so every
                            // language gets a real singular instead of "1 of 1 providers on".
                            subtitle: repoScrapers.count == 1
                                ? String(localized: "\(enabledCount) of 1 provider on")
                                : String(localized: "\(enabledCount) of \(repoScrapers.count) providers on"),
                            systemImage: isExpanded ? "chevron.down" : "chevron.right",
                            descriptionID: .sourcesPluginRepoHeader
                        )
                    } trailing: {
                        if repo.isRefreshing {
                            ProgressView().scaleEffect(0.6)
                        }
                    }
                }
                .accessibilityHint(isExpanded ? String(localized: "Collapses the provider list.") : String(localized: "Shows the provider list."))
                if let error = repo.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.red)
                }
                if isExpanded {
                    // One switch for the whole repository, above its providers.
                    if repoScrapers.count > 1 {
                        SettingsToggleRow(
                            title: String(localized: "All Providers"),
                            subtitle: String(localized: "Turn every provider in \(repo.name) on or off."),
                            isOn: Binding(
                                get: { PluginsViewModel.isRepositoryOn(repoScrapers) },
                                set: { plugins.setRepositoryEnabled(repo, $0) }
                            ),
                            descriptionID: .sourcesPluginRepoAll
                        )
                    }
                    ForEach(repoScrapers, id: \.id) { scraper in
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
                    SettingsDestructiveRow(
                        title: String(localized: "Remove Repository"),
                        subtitle: String(localized: "Removes \(repo.name) and its providers."),
                        systemImage: "trash",
                        descriptionID: .sourcesPluginRepo
                    ) {
                        pendingPluginRepoRemoval = repo
                    }
                    // Review r1 P2-5: the alert lives on the Remove row itself (one presenter, on the
                    // row that is focused when pressed), not on the Section.
                    .alert(
                        String(localized: "Remove repository?"),
                        isPresented: Binding(
                            get: { pendingPluginRepoRemoval?.manifestUrl == repo.manifestUrl },
                            set: { if !$0 { pendingPluginRepoRemoval = nil } }
                        )
                    ) {
                        Button(String(localized: "Remove"), role: .destructive) {
                            pluginRepoExpanded[repo.manifestUrl] = nil
                            // Review r2 (P3-3): cleared here too, so a row that leaves while the
                            // alert is up (a sync removal) cannot leave the request pending.
                            pendingPluginRepoRemoval = nil
                            pendingFocusAfterRemoval = repo.manifestUrl
                            plugins.removeRepository(repo)
                        }
                        Button(String(localized: "Cancel"), role: .cancel) {}
                    } message: {
                        Text("\(repo.name) and its providers will be removed from this Apple TV.")
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

    /// P4.1: the picker backdrop choices, Cinematic first (the tvOS default).
    static let backgroundModes: [StreamBackgroundMode] = [.cinematic, .normal]

    static func backgroundModeName(for mode: StreamBackgroundMode) -> String {
        switch mode {
        case .normal: return String(localized: "Normal")
        default: return String(localized: "Cinematic")
        }
    }

    /// Polish batch D5: the source grouping choices, Quality first (the default).
    static let groupingModes: [StreamGroupingMode] = [.quality, .addon]

    static func groupingModeName(for mode: StreamGroupingMode) -> String {
        switch mode {
        case .addon: return String(localized: "Add-on")
        default: return String(localized: "Quality")
        }
    }

    /// Direction C D9: Best Pick first (the default).
    static let listOpensWithModes: [StreamListOpensWith] = [.bestPick, .fullList]

    static func listOpensWithName(for mode: StreamListOpensWith) -> String {
        switch mode {
        case .fullList: return String(localized: "Full List")
        default: return String(localized: "Best Pick")
        }
    }

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
/// row; the shared repo normalizes the URL and appends /manifest.json).
///
/// BUG-213 (GitHub #10): this used to be ONE List row holding the field and the Install button,
/// and a tvOS List row is one focus target (the BUG-197 diagnosis), so the two highlighted as one
/// block and Select did not reach the field. The `Group` body now yields TWO List rows, the same
/// split `MdbListActivationCard` uses: the manifest field row (its rest platter follows the
/// field's `@FocusState`, a `TextField` has no label to read `\.isFocused` from) and an Install
/// kit row. `@State url` stays owned by this struct, so both rows share it. The in-content
/// `.glassEffect` is gone: glass belongs to floating chrome (HIG hybrid contract), and the List
/// row already has the system's background and focus treatment.
private struct PluginRepoEntryRow: View {
    let isInstalling: Bool
    var fieldFocused: FocusState<Bool>.Binding
    let onInstall: (String) -> Void
    @State private var url = ""

    var body: some View {
        Group {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "puzzlepiece.extension")
                    .font(SettingsRowFont.title)
                    .foregroundStyle(.secondary)
                TextField("Repository manifest URL", text: $url)
                    .textFieldStyle(.plain)
                    .font(SettingsRowFont.title)
                    .focused(fieldFocused)
            }
            .modifier(SettingsRestPlatter(explicitFocus: fieldFocused.wrappedValue))
            .settingsDescription(.sourcesPluginRepoAdd, title: String(localized: "Repository manifest URL"), systemImage: "puzzlepiece.extension", focused: fieldFocused.wrappedValue)

            // Not `.disabled(isInstalling)`: the pressed button lost focus. Guarded in the action,
            // and the label stays the same row while installing (the spinner rides in `trailing`).
            Button {
                if !url.isEmpty, !isInstalling {
                    onInstall(url)
                    url = ""
                }
            } label: {
                SettingsRowChrome {
                    SettingsRowLabel(
                        title: String(localized: "Install Repository"),
                        systemImage: "plus",
                        descriptionID: .sourcesPluginRepoAdd
                    )
                } trailing: {
                    if isInstalling {
                        ProgressView().scaleEffect(0.6)
                    }
                }
            }
        }
    }
}
