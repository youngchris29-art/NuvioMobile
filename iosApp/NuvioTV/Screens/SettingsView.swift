import SwiftUI
import SharedCore

/// The Settings tab: Account (sign in / sign out), Playback (Skip Intro toggle) and Home Rows
/// (enable/disable + reorder the Home catalog rows).
struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @StateObject private var trakt = TraktViewModel()
    @StateObject private var debrid = DebridViewModel()
    @StateObject private var remote = RemoteSetupViewModel()
    @StateObject private var plugins = PluginsViewModel()
    @StateObject private var badges = BadgeSettingsViewModel()
    @EnvironmentObject private var auth: AuthViewModel
    @State private var confirmingSignOut = false
    @State private var confirmingTraktDisconnect = false
    /// Provider id pending a debrid disconnect confirmation (drives the alert).
    @State private var debridDisconnectId: String?
    /// Which category's sections are shown in the detail pane (split-view, tvOS-Settings style).
    @State private var selectedCategory: SettingsCategory = .accountServices
    @FocusState private var focusedCategory: SettingsCategory?
    /// Mirrors HomeView's `hero_poster_focus_only` @AppStorage key (same UserDefaults key, read
    /// independently here) so this toggle can flip the Home hero's focus-gated artwork fade back
    /// on for testers who preferred the original behavior. Local-only, not synced.
    @AppStorage("hero_poster_focus_only") private var heroPosterFocusOnly = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                HStack(alignment: .top, spacing: 0) {
                    categorySidebar
                        .frame(width: 460)
                        .focusSection()

                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
                            Text(selectedCategory.title)
                                .font(Theme.Font.screenTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)

                        section("Account", .accountServices) {
                            if auth.isAnonymous {
                                SettingsActionRow(
                                    title: "Sign In to Nuvio",
                                    subtitle: "Sync your library, watch progress, and profiles across devices. Local guest data on this Apple TV will be cleared.",
                                    systemImage: "person.crop.circle.badge.plus"
                                ) {
                                    confirmingSignOut = true
                                }
                            } else {
                                SettingsActionRow(
                                    title: "Sign Out",
                                    subtitle: "Signed in as \(auth.accountEmail ?? "your Nuvio account"). Local data on this Apple TV will be cleared.",
                                    systemImage: "rectangle.portrait.and.arrow.right"
                                ) {
                                    confirmingSignOut = true
                                }
                            }
                        }

                        section("Theme", .appearance) {
                            Text("The accent color used for focus rings, highlights, and controls. Applies instantly and syncs per profile.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: 1100, alignment: .leading)
                            ThemePickerRow(selectedName: model.themeName) { model.setTheme($0) }
                        }

                        section("Trakt", .accountServices) {
                            traktSection
                        }

                        section("Debrid", .accountServices) {
                            debridSection
                        }

                        section("Playback", .playback) {
                            // Hidden entirely unless an external player (Infuse) is installed —
                            // see DefaultPlayerRow.
                            DefaultPlayerRow()
                            SettingsToggleRow(
                                title: "Skip Intro",
                                subtitle: "Show a Skip button during intros and outros",
                                isOn: model.skipIntroEnabled
                            ) {
                                model.setSkipIntro(!model.skipIntroEnabled)
                            }
                            SettingsToggleRow(
                                title: "Match Content Frame Rate",
                                subtitle: "Switch the display mode to the video's native frame rate and dynamic range. Also enable Match Content in tvOS Settings \u{2192} Video and Audio.",
                                isOn: model.matchFrameRate
                            ) {
                                model.setMatchFrameRate(!model.matchFrameRate)
                            }
                            SettingsToggleRow(
                                title: "Enhanced Video Renderer",
                                subtitle: "Use the gpu-next (libplacebo) renderer for better HDR tone-mapping. Experimental \u{2014} Apple TV hardware only (ignored on the Simulator). Applies to the next video.",
                                isOn: model.enhancedRenderer
                            ) {
                                model.setEnhancedRenderer(!model.enhancedRenderer)
                            }
                            SettingsToggleRow(
                                title: "Native player for Dolby Vision (beta)",
                                subtitle: "Play Dolby Vision, HDR10 and other compatible MKVs through the native AVPlayer engine for true DV output on Apple TV 4K; everything else stays on the mpv player. Profile 7 discs convert to 8.1 on the fly, and TrueHD/DTS-only audio plays as AAC 5.1.",
                                isOn: model.nativeDolbyVision
                            ) {
                                model.setNativeDolbyVision(!model.nativeDolbyVision)
                            }
                            if model.nativeDolbyVision {
                                SettingsToggleRow(
                                    title: "Keep Profile 7 FEL on mpv",
                                    subtitle: "Profile 7 FEL releases carry enhancement data the 8.1 conversion must discard. Turn on to keep those files on the mpv player (plays as HDR10, nothing discarded) instead of native Dolby Vision. MEL releases convert losslessly and always play native.",
                                    isOn: model.dvP7FelMpv
                                ) {
                                    model.setDvP7FelMpv(!model.dvP7FelMpv)
                                }
                            }
                            tuningChipRow(
                                title: "Streaming Buffer",
                                options: [(0, "Default"), (64, "64 MB"), (150, "150 MB"), (512, "512 MB")],
                                selected: model.bufferMB
                            ) { model.setBufferMB($0) }
                            tuningChipRow(
                                title: "Network Readahead",
                                options: [(0, "Default"), (30, "30 s"), (60, "60 s"), (120, "120 s")],
                                selected: model.readaheadSec
                            ) { model.setReadaheadSec($0) }
                            Text("Buffer changes apply to the next playback. Larger buffers smooth out flaky connections at the cost of memory.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: 1100, alignment: .leading)
                        }

                        section("Subtitles", .playback) {
                            if let style = model.subtitleStyle {
                                SubtitleAppearanceControls(
                                    style: style,
                                    onTextColor: { model.setSubtitleTextColor($0) },
                                    onSize: { model.setSubtitleFontSize($0) },
                                    onBackground: { model.setSubtitleBackground($0) },
                                    onBold: { model.setSubtitleBold($0) },
                                    onOutline: { model.setSubtitleOutline($0) }
                                )
                            } else {
                                Text("Loading subtitle settings\u{2026}")
                                    .font(Theme.Font.body)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }

                        section("Audio & Subtitle Language", .playback) {
                            Text("When playback starts, auto-select the audio and subtitle tracks in your preferred language (when a matching track exists).")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: 1100, alignment: .leading)
                            LanguageSelectRow(
                                title: "Audio",
                                options: LanguageOptions.audio,
                                selected: model.preferredAudioLanguage
                            ) { model.setPreferredAudioLanguage($0) }
                            LanguageSelectRow(
                                title: "Subtitles",
                                options: LanguageOptions.subtitle,
                                selected: model.preferredSubtitleLanguage
                            ) { model.setPreferredSubtitleLanguage($0) }
                        }

                        section("Poster Style", .appearance) {
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
                            SettingsToggleRow(
                                title: "Hero Poster Only When Focused",
                                subtitle: heroPosterFocusOnly
                                    ? "On \u{00B7} Home hero artwork fades in only while the hero carousel is focused"
                                    : "Off \u{00B7} Home hero artwork is always visible",
                                isOn: heroPosterFocusOnly
                            ) {
                                heroPosterFocusOnly.toggle()
                            }
                        }

                        section("Card Depth", .appearance) {
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

                        section("Stream Badges", .appearance) {
                            streamBadgesSection
                        }

                        section("Metadata (TMDB)", .contentSources) {
                            Text("Add a free TMDB API key to enrich titles with cast profiles, studios & networks, collections, and better artwork. Create one at themoviedb.org \u{2192} Settings \u{2192} API (v3 auth). Titles you open after enabling will be enriched.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: 1100, alignment: .leading)

                            if model.tmdbHasKey {
                                SettingsToggleRow(
                                    title: "TMDB Enrichment",
                                    subtitle: model.tmdbEnabled ? "On \u{00B7} API key saved" : "Off \u{00B7} API key saved",
                                    isOn: model.tmdbEnabled
                                ) {
                                    model.setTmdbEnabled(!model.tmdbEnabled)
                                }
                                SettingsToggleRow(
                                    title: "TMDB Release Dates",
                                    subtitle: model.tmdbUseReleaseDates
                                        ? "On \u{00B7} TMDB air dates override add-on release dates"
                                        : "Off \u{00B7} add-on release dates are used as-is",
                                    isOn: model.tmdbUseReleaseDates
                                ) {
                                    model.setTmdbUseReleaseDates(!model.tmdbUseReleaseDates)
                                }
                                SettingsActionRow(
                                    title: "Remove API Key",
                                    subtitle: "Clears the saved TMDB key and turns enrichment off.",
                                    systemImage: "trash"
                                ) {
                                    model.clearTmdbKey()
                                }
                            } else {
                                TmdbKeyEntryRow { model.saveTmdbKey($0) }
                            }
                        }

                        section("Ratings (MDBList)", .contentSources) {
                            Text("Add a free MDBList API key to show IMDb, Rotten Tomatoes, Metacritic, Trakt and Letterboxd scores in a title's Details. Create one at mdblist.com \u{2192} Preferences \u{2192} API Access. Titles you open after enabling will show the ratings.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: 1100, alignment: .leading)

                            if model.mdbListHasKey {
                                SettingsToggleRow(
                                    title: "MDBList Ratings",
                                    subtitle: model.mdbListEnabled ? "On \u{00B7} API key saved" : "Off \u{00B7} API key saved",
                                    isOn: model.mdbListEnabled
                                ) {
                                    model.setMdbListEnabled(!model.mdbListEnabled)
                                }
                                SettingsActionRow(
                                    title: "Remove API Key",
                                    subtitle: "Clears the saved MDBList key and turns ratings off.",
                                    systemImage: "trash"
                                ) {
                                    model.clearMdbListKey()
                                }
                            } else {
                                DebridKeyEntryRow(providerName: "MDBList", placeholder: "MDBList API key") {
                                    model.saveMdbListKey($0)
                                }
                            }
                        }

                        section("Plugins", .contentSources) {
                            pluginsSection
                        }

                        section("Remote Setup", .advanced) {
                            remoteSetupSection
                        }

                        section("Home Rows", .homeScreen) {
                            if model.catalogs.isEmpty {
                                Text("Install add-ons to customize your Home rows.")
                                    .font(Theme.Font.body)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            } else {
                                SettingsToggleRow(
                                    title: "Show Catalog Type in Titles",
                                    subtitle: model.showCatalogType
                                        ? "On \u{00B7} rows read like \u{201C}Popular - Movies\u{201D}"
                                        : "Off \u{00B7} rows use the add-on's catalog name",
                                    isOn: model.showCatalogType
                                ) {
                                    model.setShowCatalogType(!model.showCatalogType)
                                }
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
                        .padding(Theme.Spacing.screen)
                        .frame(maxWidth: 1500, alignment: .leading)
                    }
                    .focusSection()
                }
            }
        }
        .onAppear {
            model.start()
            trakt.start()
            debrid.start()
            plugins.start()
            badges.start()
        }
        .onDisappear {
            model.stop()
            trakt.stop()
            debrid.stop()
            plugins.stop()
            badges.stop()
            remote.stop()
        }
        .alert(
            "Apply changes from browser?",
            isPresented: Binding(
                get: { remote.pendingChange != nil },
                set: { if !$0 { remote.rejectPending() } }
            )
        ) {
            Button("Apply") { remote.confirmPending() }
            Button("Decline", role: .cancel) { remote.rejectPending() }
        } message: {
            Text(remote.pendingSummary)
        }
        .alert("Disconnect Trakt?", isPresented: $confirmingTraktDisconnect) {
            Button("Disconnect", role: .destructive) { trakt.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scrobbling stops and this Apple TV's Trakt access token is revoked. Your Trakt history is untouched.")
        }
        .alert(
            "Disconnect debrid provider?",
            isPresented: Binding(
                get: { debridDisconnectId != nil },
                set: { if !$0 { debridDisconnectId = nil } }
            )
        ) {
            Button("Disconnect", role: .destructive) {
                if let id = debridDisconnectId { debrid.disconnect(id) }
                debridDisconnectId = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this provider's key from this profile. Streams will no longer resolve through it.")
        }
        .alert(
            auth.isAnonymous ? "Switch to a Nuvio account?" : "Sign out?",
            isPresented: $confirmingSignOut
        ) {
            Button(auth.isAnonymous ? "Continue" : "Sign Out", role: .destructive) {
                // Clears the session AND wipes local data (AccountDataCleaner seam), then the root
                // gate drops to the Welcome screen where an account can be signed in.
                auth.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                auth.isAnonymous
                    ? "Guest data on this Apple TV (profiles, library, watch progress) will be cleared. You can then sign in on the welcome screen."
                    : "Local data on this Apple TV will be cleared. Your synced data stays in your Nuvio account."
            )
        }
    }

    /// The Trakt section body — four states: keys missing / connected / awaiting code approval /
    /// disconnected. The device flow runs in the shared repo; this just renders its uiState.
    /// The Plugins section body: master switch + per-scraper toggles. Repos are managed on the
    /// phone and arrive via cloud sync (sync-only v1) — reflected in the empty-state copy.
    @ViewBuilder
    private var pluginsSection: some View {
        Text("JS plugin providers add extra stream sources. Install a repository by its manifest URL \u{2014} it syncs to your other Nuvio devices automatically.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        SettingsToggleRow(
            title: "Enable Plugins",
            subtitle: "Run enabled plugin providers when loading streams.",
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
                        Text("\(repo.scraperCount) provider\(repo.scraperCount == 1 ? "" : "s")")
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
                                ? "v\(scraper.version)"
                                : "\(scraper.description_) \u{00B7} v\(scraper.version)",
                            isOn: scraper.enabled
                        ) {
                            plugins.toggleScraper(scraper, !scraper.enabled)
                        }
                    }
                }
            }
            SettingsActionRow(
                title: "Refresh Plugins",
                subtitle: "Re-download provider code from every repository.",
                systemImage: "arrow.clockwise"
            ) {
                plugins.refreshAll()
            }
        }
    }

    /// The Stream Badges section body: toggles + placement + imported badge-pack management,
    /// all backed by the shared `StreamBadgeSettingsRepository` (syncs across devices).
    @ViewBuilder
    private var streamBadgesSection: some View {
        Text("Badge packs add quality / HDR / audio-channel chips to stream results. Import a pack by its JSON URL \u{2014} packs imported on the Nuvio mobile app sync here automatically. Tip: Remote Setup (Advanced) lets you paste the URL from a phone browser.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        SettingsToggleRow(
            title: "File Size Badges",
            subtitle: "Show the video size (GB/MB) as a chip on stream results.",
            isOn: badges.showFileSizeBadges
        ) {
            badges.setShowFileSizeBadges(!badges.showFileSizeBadges)
        }
        SettingsToggleRow(
            title: "Show Add-on Logo",
            subtitle: "Show each result's add-on logo and name on the right of the row.",
            isOn: badges.showAddonLogo
        ) {
            badges.setShowAddonLogo(!badges.showAddonLogo)
        }
        SettingsToggleRow(
            title: "Badges Above Title",
            subtitle: badges.badgesOnTop
                ? "Badge chips render above the stream name."
                : "Badge chips render below the stream description.",
            isOn: badges.badgesOnTop
        ) {
            badges.setBadgesOnTop(!badges.badgesOnTop)
        }

        if badges.imports.isEmpty {
            Text("No badge packs imported yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else {
            ForEach(badges.imports, id: \.sourceUrl) { pack in
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(BadgeSettingsViewModel.packLabel(pack.sourceUrl))
                            .font(Theme.Font.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text("\(pack.enabledFilterCount) filter\(pack.enabledFilterCount == 1 ? "" : "s") \u{00B7} \(pack.sourceUrl)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if pack.isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Palette.accent)
                    } else {
                        Button("Set Active") { badges.setActive(pack.sourceUrl) }
                            .buttonStyle(.chip)
                            .font(Theme.Font.meta)
                    }
                    Button {
                        badges.deletePack(pack.sourceUrl)
                    } label: {
                        Image(systemName: "trash")
                            .font(Theme.Font.caption)
                    }
                    .buttonStyle(.chip)
                }
            }
        }

        BadgeUrlEntryRow(isImporting: badges.isImporting) { badges.importPack(url: $0) }

        if let status = badges.statusMessage {
            Text(status)
                .font(Theme.Font.caption)
                .foregroundStyle(status.hasPrefix("Imported") ? Theme.Palette.textSecondary : .red)
        }
    }

    /// The Remote Setup section body: start/stop the LAN config server and, while it runs, show
    /// the URL + QR a phone/laptop browser uses to manage add-ons, Home rows, API keys, and
    /// badge packs. Changes proposed from the browser surface as a confirm alert on this screen.
    @ViewBuilder
    private var remoteSetupSection: some View {
        Text("Manage add-ons, Home rows, API keys, and stream badge packs from a phone or laptop browser on the same network \u{2014} no on-screen keyboard. Changes only apply after you confirm them here.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        if let url = remote.serverURL {
            HStack(alignment: .top, spacing: 40) {
                if let qr = remote.qrImage {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scan the code, or open in any browser:")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text(url)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Keep this Settings screen open while you make changes.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            SettingsActionRow(
                title: "Stop Remote Setup",
                subtitle: "Closes the local config page.",
                systemImage: "stop.circle"
            ) {
                remote.stop()
            }
        } else {
            SettingsActionRow(
                title: "Start Remote Setup",
                subtitle: remote.startFailed
                    ? "Couldn't start the local server. Check the network connection and try again."
                    : "Starts a local config page on your network.",
                systemImage: "network"
            ) {
                remote.start()
            }
        }
    }

    @ViewBuilder
    private var traktSection: some View {
        if !trakt.credentialsConfigured {
            Text("Trakt isn't configured in this build. Add TRAKT_CLIENT_ID and TRAKT_CLIENT_SECRET to local.properties, then rebuild the shared framework.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        } else if trakt.isConnected {
            SettingsActionRow(
                title: "Disconnect Trakt",
                subtitle: "Connected as \(trakt.username ?? "your Trakt account") \u{00B7} watched history is scrobbled automatically as you play.",
                systemImage: "checkmark.circle.fill"
            ) {
                confirmingTraktDisconnect = true
            }
        } else if let code = trakt.deviceUserCode {
            TraktActivationCard(
                code: code,
                verificationUrl: trakt.deviceVerificationUrl ?? "https://trakt.tv/activate"
            ) {
                trakt.cancelActivation()
            }
        } else {
            Text("Scrobble what you watch on this Apple TV to your Trakt profile (movies and episodes are marked watched automatically).")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
            SettingsActionRow(
                title: trakt.isLoading ? "Requesting code\u{2026}" : "Connect Trakt",
                subtitle: "Shows a short code to enter at trakt.tv/activate on your phone or computer.",
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                trakt.connect()
            }
            if let error = trakt.errorMessage {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Debrid (native TorBox/Premiumize resolution via the shared debrid stack)

    @ViewBuilder
    private var debridSection: some View {
        Text("Connect a debrid service to resolve cached torrent results into direct streaming links on this Apple TV \u{2014} no pre-configured addon URL needed. Keys are per profile and sync between Apple TVs.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        ForEach(debrid.providers, id: \.id) { provider in
            debridProviderRows(provider)
        }

        if debrid.hasAnyKey {
            SettingsToggleRow(
                title: "Resolve Streams with Debrid",
                subtitle: "Turn cached torrent results into direct links automatically",
                isOn: debrid.resolverEnabled
            ) {
                debrid.setResolverEnabled(!debrid.resolverEnabled)
            }
        }

        if debrid.resolverProviders.count > 1 {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Preferred resolver")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(debrid.resolverProviders, id: \.id) { provider in
                        Button {
                            debrid.setPreferredResolver(provider.id)
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                if debrid.activeResolverId == provider.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                Text(provider.displayName)
                            }
                            .font(Theme.Font.meta)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                        }
                        .buttonStyle(.chip(selected: debrid.activeResolverId == provider.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func debridProviderRows(_ provider: DebridProvider) -> some View {
        if debrid.isConnected(provider.id) {
            SettingsActionRow(
                title: "\(provider.displayName) \u{00B7} Connected",
                subtitle: debrid.activeResolverId == provider.id
                    ? "Active resolver \u{00B7} press to disconnect"
                    : "Press to disconnect",
                systemImage: "checkmark.circle.fill"
            ) {
                debridDisconnectId = provider.id
            }
        } else if debrid.authProviderId == provider.id {
            switch debrid.authPhase {
            case .starting:
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Requesting a sign-in code from \(provider.displayName)\u{2026}")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            case .waiting:
                if let session = debrid.activeSession {
                    DebridActivationCard(
                        providerName: provider.displayName,
                        code: session.userCode,
                        verificationUrl: session.friendlyVerificationUrl
                    ) {
                        debrid.cancelActivation()
                    }
                }
            case .failed(let message):
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1100, alignment: .leading)
                SettingsActionRow(
                    title: "Dismiss",
                    subtitle: "Back to the connect options for \(provider.displayName).",
                    systemImage: "xmark.circle"
                ) {
                    debrid.cancelActivation()
                }
            case .idle:
                EmptyView()
            }
        } else {
            SettingsActionRow(
                title: "Connect \(provider.displayName)",
                subtitle: "Shows a short code to enter on your phone (device sign-in).",
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                debrid.connect(provider)
            }
            DebridKeyEntryRow(providerName: provider.displayName) { key in
                debrid.saveManualKey(provider.id, key: key)
            }
        }
    }

    /// A labeled row of value chips for the device-local player tuning knobs.
    private func tuningChipRow(
        title: String,
        options: [(value: Int, label: String)],
        selected: Int,
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.md) {
                ForEach(options, id: \.value) { option in
                    Button {
                        onSelect(option.value)
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            if selected == option.value {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(option.label)
                        }
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                    .buttonStyle(.chip(selected: selected == option.value))
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        _ category: SettingsCategory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Only the selected category's sections render into the detail pane; the body is not even
        // built for other categories (keeps focus + perf clean).
        Group {
            if category == selectedCategory {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text(title)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    content()
                }
                // Each settings section is a focus region: vertical swipes enter the nearest section
                // without needing precise horizontal alignment with the next control.
                .focusSection()
            }
        }
    }

    /// Left column: one focusable row per category. Focusing a row live-updates the detail pane
    /// (tvOS Settings pattern); swiping right enters the pane.
    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Settings")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.bottom, Theme.Spacing.md)

            ForEach(SettingsCategory.allCases) { category in
                Button {
                    selectedCategory = category
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: category.icon)
                            .font(.system(size: 30))
                            .frame(width: 40)
                        Text(category.title)
                            .font(Theme.Font.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(
                        category == selectedCategory
                            ? Theme.Palette.accent
                            : Theme.Palette.textPrimary
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.settingsRow)
                .focused($focusedCategory, equals: category)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.screen)
        .onChange(of: focusedCategory) { _, newValue in
            // Live-preview the focused category in the detail pane.
            if let newValue { selectedCategory = newValue }
        }
    }
}

/// Settings categories for the split-view sidebar. Order here is the sidebar order.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case accountServices
    case playback
    case appearance
    case homeScreen
    case contentSources
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accountServices: return "Account & Services"
        case .playback: return "Playback"
        case .appearance: return "Appearance"
        case .homeScreen: return "Home Screen"
        case .contentSources: return "Content Sources"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .accountServices: return "person.crop.circle"
        case .playback: return "play.rectangle"
        case .appearance: return "paintbrush"
        case .homeScreen: return "house"
        case .contentSources: return "square.stack.3d.up"
        case .advanced: return "gearshape.2"
        }
    }
}

/// A row of theme swatches (one per shared `AppTheme`); the selected one wears a ring. Swatch
/// colors mirror `AppTheme.nativeAccentHex` (and Theme.Palette.applyTheme's table).
private struct ThemePickerRow: View {
    let selectedName: String
    let onSelect: (AppTheme) -> Void

    private static let options: [(theme: AppTheme, label: String, colorHex: UInt32)] = [
        (.crimson, "Crimson", 0xE53935),
        (.ocean, "Ocean", 0x1E88E5),
        (.violet, "Violet", 0x8E24AA),
        (.emerald, "Emerald", 0x43A047),
        (.amber, "Amber", 0xFB8C00),
        (.rose, "Rose", 0xD81B60),
        (.white, "White", 0xF5F5F5),
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
                    .buttonStyle(.poster)
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
                .scaleEffect(isFocused ? 1.15 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
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

/// Shown while a Trakt device-code flow awaits approval: the big user code, where to enter it,
/// a waiting spinner (the shared repo polls in the background), and a Cancel row.
private struct TraktActivationCard: View {
    let code: String
    let verificationUrl: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("On your phone or computer, go to")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(verificationUrl)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("and enter this code:")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(code)
                .font(.system(size: 72, weight: .bold, design: .monospaced))
                .kerning(12)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.vertical, Theme.Spacing.md)
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Waiting for approval\u{2026} this screen updates automatically.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            SettingsActionRow(
                title: "Cancel",
                subtitle: "Stop waiting and dismiss the code.",
                systemImage: "xmark.circle"
            ) {
                onCancel()
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
    }
}

/// Shown while a debrid device-code flow awaits approval (mirrors `TraktActivationCard`).
private struct DebridActivationCard: View {
    let providerName: String
    let code: String
    let verificationUrl: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("On your phone or computer, go to")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(verificationUrl)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("and enter this code:")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(code)
                .font(.system(size: 72, weight: .bold, design: .monospaced))
                .kerning(12)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.vertical, Theme.Spacing.md)
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Waiting for \(providerName) approval\u{2026} this screen updates automatically.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            SettingsActionRow(
                title: "Cancel",
                subtitle: "Stop waiting and dismiss the code.",
                systemImage: "xmark.circle"
            ) {
                onCancel()
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
    }
}

/// Manual API-key entry row (debrid fallback, MDBList, and similar key-gated services).
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

/// URL entry + import button for a stream badge pack (mirrors `PluginRepoEntryRow`).
private struct BadgeUrlEntryRow: View {
    let isImporting: Bool
    let onImport: (String) -> Void
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "tag")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("Badge pack JSON URL", text: $url)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .padding(Theme.Spacing.lg)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            Button {
                if !url.isEmpty {
                    onImport(url)
                    url = ""
                }
            } label: {
                if isImporting {
                    ProgressView()
                } else {
                    Label("Import Badge Pack", systemImage: "plus")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xxs + 2)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)
        }
    }
}

private struct DebridKeyEntryRow: View {
    let providerName: String
    var placeholder: String?
    let onSave: (String) -> Void
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "key")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField(placeholder ?? "Or paste a \(providerName) API key", text: $key)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .padding(Theme.Spacing.lg)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            Button {
                if !key.isEmpty {
                    onSave(key)
                    key = ""
                }
            } label: {
                Label("Save Key", systemImage: "checkmark")
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

/// A focusable settings row that performs an action on select (chevron affordance).
private struct SettingsActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: systemImage)
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsRow)
    }
}

/// A focusable settings row that toggles a boolean on select.
/// "Default Player" chooser (FEAT-5 follow-up): built-in vs. any installed external player
/// (Infuse / VLC / Outplayer — whichever the Info.plist allowlist probe finds). When an
/// external player is the default, plain Select on a stream row hands off to it instead of the
/// in-app player, and the row's long-press menu gains a "Play in NuvioTV Player" escape hatch
/// (StreamPickerView reads the same key).
///
/// Self-contained on purpose: owns its own `availablePlayers()` probe and @AppStorage binding so
/// SettingsView doesn't grow more state. Renders NOTHING when no external player is installed —
/// a "Default Player" row whose only option is the built-in player is dead UI, and hiding it
/// matches the picker's own behavior (no Infuse ⇒ no handoff affordances anywhere).
///
/// The stored id is deliberately device-local (@AppStorage, not synced): which apps are
/// installed differs per Apple TV, so a synced default would dangle on every other device.
private struct DefaultPlayerRow: View {
    @AppStorage("default_external_player_id") private var defaultExternalPlayerId = ""
    /// Probed at init, NOT in `.onAppear`: with no players this row renders nothing, and
    /// SwiftUI never fires `onAppear` for a view that renders empty — an onAppear probe
    /// therefore deadlocks the row into permanent invisibility (found on a real Apple TV with
    /// Infuse installed: the probe returned Infuse fine, but never got the chance to run).
    /// Init runs on the main thread (canOpenURL requirement) every time SettingsView rebuilds,
    /// so install/remove of a player is picked up at least as often as the old per-appearance
    /// probe — and the calls are a few cheap registry lookups.
    private let externalPlayers: [ExternalPlayerApp] = ExternalPlayerPlatform.shared.availablePlayers()

    /// Display name for the current selection (row trailing value).
    private var selectedName: String {
        externalPlayers.first { $0.id == defaultExternalPlayerId }?.name ?? "NuvioTV (Built-in)"
    }

    var body: some View {
        if !externalPlayers.isEmpty {
            // Dropdown rather than inline chips: renders as a normal settings row showing the
            // current choice; Select pops the native tvOS menu. The embedded Picker gets
            // radio-style checkmarks in the menu for free, bound straight to the stored id.
            Menu {
                Picker("Default Player", selection: $defaultExternalPlayerId) {
                    Text("NuvioTV (Built-in)").tag("")
                    ForEach(externalPlayers, id: \.id) { player in
                        Text(player.name).tag(player.id)
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.lg) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.Palette.accent)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Default Player")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(defaultExternalPlayerId.isEmpty
                            ? "Streams play in the built-in player. Hold a stream to open it in an external player instead."
                            : "Streams open in \(selectedName). Hold a stream to play it in NuvioTV instead; if \(selectedName) can\u{2019}t open, playback falls back to the built-in player.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                    Text(selectedName)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(.settingsRow)
            .onAppear {
                // Safe here: this onAppear is on the VISIBLE content, so it actually fires.
                // A stored default whose app was uninstalled silently reverts to built-in —
                // the picker independently guards against this too, but clearing here keeps
                // the row's displayed value honest. When NO player is installed the row is
                // hidden and a stale id survives harmlessly; the stream picker's membership
                // check already ignores it.
                if !defaultExternalPlayerId.isEmpty,
                   !externalPlayers.contains(where: { $0.id == defaultExternalPlayerId }) {
                    defaultExternalPlayerId = ""
                }
            }
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Bool
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
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 34))
                    .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsRow)
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

            Button(action: onDown) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.chip)

            Button(action: onToggle) {
                Image(systemName: item.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.enabled ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            .buttonStyle(.chip)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity)
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

/// Subtitle appearance controls: a live preview plus text color, size, background, bold and outline.
/// Colors are `SubtitleColor` argb longs (0xAARRGGBB). The player reads these on the next file load.
private struct SubtitleAppearanceControls: View {
    let style: SubtitleStyleState
    let onTextColor: (Int64) -> Void
    let onSize: (Int32) -> Void
    let onBackground: (Int64) -> Void
    let onBold: (Bool) -> Void
    let onOutline: (Bool) -> Void

    private let textColors: [(name: String, argb: Int64)] = [
        ("White", 0xFFFFFFFF), ("Yellow", 0xFFFFFF00), ("Cyan", 0xFF00FFFF), ("Green", 0xFF00FF00)
    ]
    private let sizes: [(name: String, sp: Int32)] = [
        ("Small", 14), ("Medium", 18), ("Large", 24), ("X-Large", 30)
    ]
    private let backgrounds: [(name: String, argb: Int64)] = [
        ("Off", 0x00000000), ("Semi", 0x80000000), ("Solid", 0xFF000000)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            preview

            controlRow("Text Color") {
                ForEach(textColors, id: \.argb) { entry in
                    Button { onTextColor(entry.argb) } label: {
                        SubtitleColorSwatch(
                            fill: color(entry.argb),
                            colorHex: UInt32(entry.argb & 0xFFFFFF),
                            isSelected: style.textColor == entry.argb
                        )
                    }
                    .buttonStyle(.poster)
                }
            }

            controlRow("Size") {
                ForEach(sizes, id: \.sp) { entry in
                    chip(entry.name, selected: style.fontSizeSp == entry.sp) { onSize(entry.sp) }
                }
            }

            controlRow("Background") {
                ForEach(backgrounds, id: \.argb) { entry in
                    chip(entry.name, selected: style.backgroundColor == entry.argb) { onBackground(entry.argb) }
                }
            }

            SettingsToggleRow(title: "Bold", subtitle: "Use a heavier subtitle font", isOn: style.bold) {
                onBold(!style.bold)
            }
            SettingsToggleRow(title: "Outline", subtitle: "Draw an outline around text for readability", isOn: style.outlineEnabled) {
                onOutline(!style.outlineEnabled)
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.black)
            Text("The quick brown fox")
                .font(.system(size: 34, weight: style.bold ? .bold : .regular))
                .foregroundStyle(color(style.textColor))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(color(style.backgroundColor))
        }
        .frame(height: 130)
        .frame(maxWidth: 700)
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

    private func color(_ argb: Int64) -> Color {
        Color(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255.0,
            green: Double((argb >> 8) & 0xFF) / 255.0,
            blue: Double(argb & 0xFF) / 255.0,
            opacity: Double((argb >> 24) & 0xFF) / 255.0
        )
    }
}

/// A subtitle text-color swatch: selection wears a ring that contrasts with the swatch's own
/// fill; focus scales + shadows the circle (platter-free, same focus language as the theme
/// swatches).
private struct SubtitleColorSwatch: View {
    let fill: Color
    /// Raw RGB backing `fill`, so the selection ring can pick a shade that stays visible against
    /// it — a static accent ring nearly disappeared on the White swatch when the app theme was
    /// also White (same problem `SwatchLabel` fixes for the theme picker).
    let colorHex: UInt32
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 46, height: 46)
            .overlay(
                Circle().stroke(
                    isSelected ? Theme.Palette.onColor(forFillHex: colorHex) : Theme.Palette.textSecondary.opacity(0.4),
                    lineWidth: isSelected ? 4 : 1
                )
            )
            .scaleEffect(isFocused ? 1.15 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
            .padding(Theme.Spacing.xs)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Language options for the audio/subtitle preference pickers. Special sentinels (`device`,
/// `original`, `none`) match the shared `AudioLanguageOption`/`SubtitleLanguageOption` constants;
/// labels are local since the shared label table lives in the mobile module.
private enum LanguageOptions {
    static let languages: [(name: String, code: String)] = [
        ("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Italian", "it"), ("Portuguese", "pt"), ("Japanese", "ja"), ("Korean", "ko"),
        ("Chinese", "zh"), ("Russian", "ru"), ("Hindi", "hi"), ("Arabic", "ar")
    ]
    static var audio: [(name: String, code: String)] {
        [("Device", "device"), ("Original", "original")] + languages
    }
    static var subtitle: [(name: String, code: String)] {
        [("Off", "none"), ("Device", "device")] + languages
    }
}

/// A horizontally-scrolling row of language chips; the current selection is tinted.
private struct LanguageSelectRow: View {
    let title: String
    let options: [(name: String, code: String)]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(options, id: \.code) { option in
                        Button { onSelect(option.code) } label: {
                            Text(option.name)
                                .font(Theme.Font.meta)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.xxs + 2)
                        }
                        .buttonStyle(.chip(selected: selected == option.code))
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
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

    private let sizes: [(name: String, dp: Int32)] = [("Small", 105), ("Medium", 126), ("Large", 154)]
    private let corners: [(name: String, dp: Int32)] = [("Square", 0), ("Rounded", 12), ("Round", 28)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            controlRow("Size") {
                ForEach(sizes, id: \.dp) { size in
                    chip(size.name, selected: widthDp == size.dp) { onSize(size.dp) }
                }
            }
            controlRow("Corners") {
                ForEach(corners, id: \.dp) { corner in
                    chip(corner.name, selected: cornerDp == corner.dp) { onCorner(corner.dp) }
                }
            }

            SettingsToggleRow(title: "Hide Titles", subtitle: "Show posters without a title label", isOn: hideLabels) {
                onHideLabels(!hideLabels)
            }
            SettingsToggleRow(title: "Landscape Rows", subtitle: "Show Home & Search catalog rows as wide 16:9 cards", isOn: landscapeRows) {
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

    private let edgeOptions: [(name: String, value: Int32)] = [("Subtle", 28), ("Balanced", 42), ("Bold", 56)]
    private let sheenOptions: [(name: String, value: Int32)] = [("Off", 0), ("Soft", 10), ("Bright", 16)]
    private let coverageOptions: [(name: String, value: Int32)] = [("Top", 0), ("Half", 50), ("Full", 100)]
    private let surfaces: [(name: String, subtitle: String, surface: CardDepthSurface)] = [
        ("Posters", "Catalog & search posters", .posters),
        ("Continue Watching", "Home Continue Watching cards", .continueWatching),
        ("Episodes", "Episode thumbnails", .episodeCards),
        ("Cast", "Cast avatars", .cast),
        ("Trailers", "Trailer rows", .trailers),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Add a raised edge highlight and a glossy top sheen to cards for a little more depth.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)

            SettingsToggleRow(title: "Card Depth", subtitle: "Enable the edge highlight and top sheen", isOn: style.enabled) {
                onEnabled(!style.enabled)
            }

            if style.enabled {
                controlRow("Edge") {
                    ForEach(edgeOptions, id: \.value) { opt in
                        chip(opt.name, selected: Int32(style.edgeStrength) == opt.value) { onEdge(opt.value) }
                    }
                }
                controlRow("Sheen") {
                    ForEach(sheenOptions, id: \.value) { opt in
                        chip(opt.name, selected: Int32(style.sheenStrength) == opt.value) { onSheen(opt.value) }
                    }
                }
                controlRow("Edge Coverage") {
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
