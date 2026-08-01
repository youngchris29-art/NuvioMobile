import SwiftUI
import SharedCore

/// Presented when the user taps Play. Resolves streams for the title, lists the playable ones
/// grouped by addon, and opens the native player on selection.
///
/// Debrid: torrent/`clientResolve` results from installed addons (no direct URL) are listed when
/// in-app debrid resolution is enabled, and resolve to a direct link at click time through the
/// shared `DirectDebridPlaybackResolver` (mobile parity: `App.kt:2157`, `StreamsScreen.kt:363`).
/// Failures surface as a transient toast using the same wording as the shared `toastMessage()`.
///
/// Badges: rows render imported badge-pack chips, the file-size chip, TOP/BOTTOM placement, the
/// optional addon logo and the "- <Provider> Instant" cached suffix (mobile `StreamCard` parity).
///
/// Grouping: each addon's streams sit under a collapsed-by-default, focusable header (name,
/// stream count, per-addon loading spinner). Rows only build while their group is expanded — a
/// `LazyVStack` throughout — so the picker no longer lags while addons are still resolving
/// (previously every addon's rows were built eagerly in one long always-expanded list). A lone
/// addon auto-expands; anything past that stays collapsed until picked, and never
/// auto-collapses/re-expands as later addons stream in.
///
/// Focus: rows and group headers carry stable focus keys. Initial focus lands on the first
/// stream row when there's a single, auto-expanded group, otherwise on the first group's header.
/// Collapsing a group that holds focus retargets focus to that group's header first. (Previously
/// the dev test-stream button at the bottom was the only focusable view while loading, so focus
/// landed — and stayed — at the bottom of the list.)
struct StreamPickerView: View {
    let type: String
    let videoId: String
    let title: String

    let parentMetaId: String
    let season: Int?
    let episode: Int?
    /// All episodes of the parent series (from `MetaDetails.videos`); enables next-episode
    /// autoplay in the player. Empty for movies or launch paths without the series meta.
    let episodes: [MetaVideo]

    @StateObject private var model: StreamsViewModel
    @State private var selected: PlaybackContext?
    /// Episodes fetched on demand when a series launch path didn't supply them (Home
    /// continue-watching, Detail's primary Play). Filled from `MetaDetailsRepository.fetch`
    /// (cache-first, side-effect free) so next-episode autoplay works from every path.
    @State private var fetchedEpisodes: [MetaVideo] = []
    /// Row key currently mid debrid-resolve (drives the row spinner; one resolve at a time).
    @State private var resolvingKey: String?
    /// Transient failure message (debrid resolve errors), auto-dismissed after a few seconds.
    @State private var toast: String?
    @FocusState private var focusedRow: String?
    /// Addon ids whose group is currently expanded. Collapsed (absent) by default; see
    /// `body`'s auto-expand-single-group handling and `toggleExpansion(_:)`.
    @State private var expandedGroups: Set<String> = []
    /// Guards the one-time auto-expand check so a second addon streaming in later never
    /// collapses/re-expands anything under the user (no layout shifts under focus).
    @State private var didAutoExpand = false
    /// External players installed on this Apple TV (FEAT-5). Probed once per appearance via the
    /// shared `ExternalPlayerPlatform` — `canOpenURL` only returns true for schemes declared in
    /// Info.plist's `LSApplicationQueriesSchemes` (Infuse, VLC, Outplayer), so testers without
    /// any of them installed never see the handoff option at all. Empty ⇒ no menu is attached.
    @State private var externalPlayers: [ExternalPlayerApp] = []
    /// User-chosen default player (Settings → Playback → Default Player). Empty = built-in.
    /// Same device-local key `DefaultPlayerRow` writes; validated against the live probe below
    /// so an uninstalled default silently reverts to built-in instead of dead-ending playback.
    @AppStorage("default_external_player_id") private var defaultExternalPlayerId = ""
    @Environment(\.dismiss) private var dismiss

    private static let testRowKey = "test-stream"
    private let testStreamURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!

    init(
        type: String,
        videoId: String,
        title: String,
        parentMetaId: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        episodes: [MetaVideo] = []
    ) {
        self.type = type
        self.videoId = videoId
        self.title = title
        self.parentMetaId = parentMetaId ?? videoId
        self.season = season
        self.episode = episode
        self.episodes = episodes
        _model = StateObject(wrappedValue: StreamsViewModel(
            type: type, videoId: videoId, parentMetaId: parentMetaId, season: season, episode: episode
        ))
    }

    private func context(url: URL, stream: StreamItem?) -> PlaybackContext {
        PlaybackContext(
            url: url,
            title: title,
            contentType: type,
            parentMetaId: parentMetaId,
            videoId: videoId,
            season: season,
            episode: episode,
            poster: nil,
            background: nil,
            providerName: stream?.addonName,
            providerAddonId: stream?.addonId,
            streamTitle: stream.map { $0.streamLabel },
            streamSubtitle: { let s: String? = stream?.description_; return s }(),
            externalSubtitles: (stream?.externalSubtitles ?? []).map { sub in
                SubtitleFile(url: sub.url, language: sub.language, name: { let n: String? = sub.name; return n }())
            },
            bingeGroup: { let bg: String? = stream?.behaviorHints.bingeGroup; return bg }(),
            episodes: episodes.isEmpty ? fetchedEpisodes : episodes
        )
    }

    /// Series launch paths that don't carry the episode list (Home continue-watching, Detail's
    /// primary Play) get it fetched here so the player can offer next-episode autoplay. No-op for
    /// movies and for paths that already passed `episodes` (EpisodesSection).
    private func fetchEpisodesIfNeeded() {
        guard episodes.isEmpty, fetchedEpisodes.isEmpty,
              ["series", "tv", "show", "tvshow"].contains(type.lowercased()) else { return }
        MetaDetailsRepository.shared.fetch(type: type, id: parentMetaId) { details, _ in
            let videos = details?.videos ?? []
            guard !videos.isEmpty else { return }
            // Suspend completions can land off-main; hop before mutating view state.
            DispatchQueue.main.async { fetchedEpisodes = videos }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Lazy so collapsed groups' rows (the overwhelming majority while addons are
                // still streaming in) are never built at all — this was the lag source (BUG-5):
                // a non-lazy VStack built every row of every addon up front.
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl - Theme.Spacing.xs) {
                    Text(title)
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    // BUG-21 follow-up: the active debrid credential failed auth on a recent
                    // call — without this banner the only symptom is every resolve failing
                    // while Settings still says "Connected". Not focusable; purely advisory.
                    if let warning = model.credentialWarning {
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(warning)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        .padding(Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.yellow.opacity(0.12))
                        )
                        .frame(maxWidth: 1100, alignment: .leading)
                    }

                    if model.isLoading {
                        HStack(spacing: Theme.Spacing.md) {
                            ProgressView()
                            Text("Finding streams\u{2026}").foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }

                    ForEach(model.groups) { group in
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            groupHeader(group)
                            // Collapsed groups render nothing at all (not just off-screen —
                            // absent from the hierarchy), which is what actually kills the lag:
                            // the old always-expanded list built every row of every addon.
                            if expandedGroups.contains(group.id) {
                                LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                    ForEach(Array(group.streams.enumerated()), id: \.offset) { index, stream in
                                        streamRow(stream, key: StreamsViewModel.rowKey(groupId: group.id, index: index))
                                    }
                                }
                                .padding(.top, Theme.Spacing.xs)
                            }
                        }
                        // Each addon group is its own focus section: D-pad up/down navigates
                        // between group headers and (when expanded) that group's rows without
                        // leaking focus into a sibling group's rows.
                        .focusSection()
                    }

                    if let reason = model.emptyReason {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            // Primary reason renders at full text-primary weight — prominent,
                            // not the muted secondary tone the plain "nothing found" empty
                            // states get elsewhere on tvOS — since the debrid/filtered case is
                            // actionable rather than a dead end.
                            Text(reason)
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            if let hint = model.emptyReasonHint {
                                Text(hint)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                        .padding(.top, Theme.Spacing.xs)
                    }

                    // Dev/diagnostics affordance — only when there is nothing real to play, so it
                    // can never steal initial focus from the stream list (the old always-visible
                    // button was the only focusable view while loading → focus started at the
                    // bottom of the screen).
                    if model.groups.isEmpty && !model.isLoading {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Test")
                                .font(Theme.Font.sectionTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Button {
                                selected = context(url: testStreamURL, stream: nil)
                            } label: {
                                Label("Play test stream (Apple HLS sample)", systemImage: "play.circle")
                                    .padding(.vertical, Theme.Spacing.xs)
                            }
                            .buttonStyle(.glass)
                            .focused($focusedRow, equals: Self.testRowKey)
                        }
                        .padding(.top, Theme.Spacing.lg)
                    }
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Palette.background.ignoresSafeArea())
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                        .background(Theme.Surface.overlay, in: Capsule())
                        .padding(.bottom, Theme.Spacing.xl)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: model.groups.map(\.id)) { _, ids in
                guard !ids.isEmpty else { return }
                // Auto-expand exactly once, only when the very first batch of groups turns out
                // to be a single addon. Never re-evaluated afterward, so a second addon
                // streaming in later doesn't retroactively collapse or expand anything.
                if !didAutoExpand {
                    didAutoExpand = true
                    if ids.count == 1 { expandedGroups = [ids[0]] }
                }

                // Move initial focus once groups (first) arrive: to the first stream row when
                // there's a single, auto-expanded group (unchanged from before collapsing was
                // added), otherwise to the first group's header. Never steals focus after the
                // user has moved it to a real row/header: only fires while focus is nowhere or
                // on the (now hidden) test button.
                guard focusedRow == nil || focusedRow == Self.testRowKey else { return }
                if ids.count == 1, let firstKey = model.firstRowKey {
                    DispatchQueue.main.async { focusedRow = firstKey }
                } else if let firstId = ids.first {
                    DispatchQueue.main.async { focusedRow = Self.headerKey(groupId: firstId) }
                }
            }
            .onAppear {
                model.start()
                fetchEpisodesIfNeeded()
                // Main-thread only (UIApplication.canOpenURL); cheap enough to re-probe every
                // appearance so an Infuse install mid-session is picked up next time the picker
                // opens instead of requiring an app relaunch.
                externalPlayers = ExternalPlayerPlatform.shared.availablePlayers()
                // Head start for the player: addon subtitles for this title begin fetching while
                // the user is still choosing a stream, so the native path's pre-master window
                // (and the mpv side-load) see results instead of racing the network. The player's
                // own fetch call deduplicates against this one.
                SubtitleRepository.shared.fetchAddonSubtitles(type: type, videoId: videoId)
            }
            .onDisappear { model.stop() }
            .fullScreenCover(item: $selected) { ctx in
                // `.id(ctx.id)` forces a full player rebuild when autoplay swaps in the next
                // episode's context (a same-position cover would otherwise keep the old libmpv
                // controller and just ignore the new context).
                PlayerScreen(context: ctx, onPlayNext: { next in selected = next })
                    .ignoresSafeArea()
                    .id(ctx.id)
            }
        }
    }

    // MARK: - Group headers

    private static func headerKey(groupId: String) -> String { "header:\(groupId)" }

    /// Collapsed by default: a focusable header row per addon (name, stream count, chevron, and
    /// a per-addon spinner while that addon is still loading — the shared `AddonStreamGroup`
    /// carries `isLoading` per addon already, so this reflects real per-addon state rather than
    /// the global "any addon still loading" flag). Deliberately a plain `Button`, not
    /// `DisclosureGroup` — tvOS focus/highlight on `DisclosureGroup` is poor and inconsistent
    /// with the rest of this screen's rows.
    private func groupHeader(_ group: StreamsViewModel.Group) -> some View {
        let key = Self.headerKey(groupId: group.id)
        let isExpanded = expandedGroups.contains(group.id)

        return Button {
            toggleExpansion(group)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 20, alignment: .center)
                Text(group.addonName)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(group.streams.count == 1 ? String(localized: "1 stream") : String(localized: "\(group.streams.count) streams"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if group.isLoading {
                    ProgressView().scaleEffect(0.7)
                }
                Spacer()
            }
            .padding(.vertical, Theme.Spacing.xs + 2)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.settingsRow)
        .focused($focusedRow, equals: key)
    }

    private func toggleExpansion(_ group: StreamsViewModel.Group) {
        if expandedGroups.contains(group.id) {
            // Collapsing a group that currently holds focus would otherwise leave focus on a
            // row that's about to disappear from the hierarchy — retarget to the header first.
            if let focusedRow, focusedRow.hasPrefix("\(group.id)#") {
                self.focusedRow = Self.headerKey(groupId: group.id)
            }
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
            // Expanding keeps focus on the header (SwiftUI doesn't move it on select), matching
            // the requirement that expand never steals focus.
        }
    }

    // MARK: - Rows

    private func streamRow(_ stream: StreamItem, key: String) -> some View {
        // Kotlin nullable Strings surface as non-optional Swift String, so widen explicitly.
        let desc: String? = stream.description_
        let badges: [StreamBadge] = stream.badges
        let sizeBytes: Int64? = stream.behaviorHints.videoSize?.int64Value
        let showSize = model.showFileSizeBadges && sizeBytes != nil
        let hasBadgeRow = !badges.isEmpty || showSize

        return Button {
            play(stream, rowKey: key)
        } label: {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    if hasBadgeRow && model.badgesOnTop {
                        badgeRow(badges: badges, sizeBytes: showSize ? sizeBytes : nil)
                    }
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(rowTitle(stream))
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2)
                        if resolvingKey == key {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                    if let desc, !desc.isEmpty {
                        // BUG-16 (final form): 3 lines while browsing, unlimited on the FOCUSED
                        // row. Release names are dot/underscore-separated with no break points,
                        // so no fixed cap fits all of them ("works for some links but not all"
                        // — the reporter, on the 3-line beta.7 fix); expanding the row under
                        // focus guarantees the name you're actually reading is never truncated,
                        // without a marquee and without inflating every row in the list.
                        Text(desc)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(focusedRow == key ? nil : 3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if hasBadgeRow && !model.badgesOnTop {
                        badgeRow(badges: badges, sizeBytes: showSize ? sizeBytes : nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if model.showAddonLogo {
                    addonLogoColumn(stream)
                }
            }
            .padding(.vertical, Theme.Spacing.xs + 2)
            .padding(.horizontal, Theme.Spacing.sm)
        }
        // `.settingsRow` (platter-free, soft white highlight + accent ring) replaces the system
        // `.glass` style: Liquid Glass's focus platter goes near-white, which made this row's
        // title text (statically `textPrimary`, near-white) unreadable on focus.
        .buttonStyle(.settingsRow)
        .focused($focusedRow, equals: key)
        // FEAT-5: long-press → the OTHER player(s). With the built-in default, the menu offers
        // the installed external players; with an external default (plain Select already hands
        // off) it inverts to offer "Play in NuvioTV Player" plus any non-default externals. The
        // modifier is skipped entirely when no external player is installed, so the long-press
        // stays inert rather than opening an empty menu.
        .modifier(ExternalPlayMenu(
            players: externalPlayers,
            defaultPlayerId: activeDefaultExternalPlayer?.id,
            onExternal: { player in
                externalPlay(stream, rowKey: key, playerId: player.id)
            },
            onBuiltIn: {
                internalPlay(stream, rowKey: key)
            }
        ))
    }

    @ViewBuilder
    private func badgeRow(badges: [StreamBadge], sizeBytes: Int64?) -> some View {
        // BUG-16: this used to be one plain HStack with up to 8 badge chips (each up to
        // `StreamBadgeMetrics.maxImageWidth` = 180pt for image-based community badge packs) plus
        // the size chip — none of them width-flexible. An HStack whose children are all
        // non-shrinking ignores the width it's offered and reports the full sum of its children
        // back to its parent instead. That inflated "ideal" width bubbled up through the
        // title/description VStack and the row's outer HStack, widening the *whole row* — and
        // since every row shares one LazyVStack, effectively the whole list — past the screen.
        // The addon-logo column and the tail end of the badges/size chip then rendered off the
        // trailing edge, which is what testers saw as "no space left" for title/size/seeders.
        //
        // Fix: hand `ViewThatFits` a ladder of candidates from "every badge" down to "just an
        // overflow count", widest first. It measures each against the width actually left over
        // once title/description and the addon-logo column have claimed theirs, and renders the
        // first one that fits — so this row can never again demand more width than it's given.
        // The size chip is pinned first in every candidate since it's core metadata (like
        // seeders), not decoration, and every candidate shares the same fixed container height,
        // so switching between them never changes the row's height class.
        let displayBadges = Array(badges.prefix(8))
        let hiddenBeyondCap = max(0, badges.count - 8)
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: displayBadges.count, through: 0, by: -1)), id: \.self) { visible in
                badgeRowVariant(
                    displayBadges: displayBadges,
                    visibleCount: visible,
                    hiddenCount: (displayBadges.count - visible) + hiddenBeyondCap,
                    sizeBytes: sizeBytes
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One `ViewThatFits` candidate for `badgeRow`: the size chip (if any) + the first
    /// `visibleCount` badges + a non-focusable "+N" overflow chip for everything else.
    /// `hiddenCount` folds in both badges dropped by this candidate and any beyond the 8-badge
    /// display cap, so the count the user sees is always accurate.
    private func badgeRowVariant(
        displayBadges: [StreamBadge],
        visibleCount: Int,
        hiddenCount: Int,
        sizeBytes: Int64?
    ) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let sizeBytes {
                StreamFileSizeChip(bytes: sizeBytes)
            }
            ForEach(Array(displayBadges.prefix(visibleCount).enumerated()), id: \.offset) { _, badge in
                StreamBadgeChipView(badge: badge)
            }
            if hiddenCount > 0 {
                BadgeOverflowChip(count: hiddenCount)
            }
        }
    }

    private func addonLogoColumn(_ stream: StreamItem) -> some View {
        VStack(spacing: Theme.Spacing.xxs) {
            let logo: String? = stream.addonLogo
            if let logo, !logo.isEmpty, let url = URL(string: logo) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(stream.addonName)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 150)
    }

    /// Row title with the mobile "- <Provider> Instant" suffix on debrid-cached torrent rows
    /// (`StreamCard.kt:instantServiceLabel`), shown only while debrid resolution is enabled and
    /// no custom stream-name template is active.
    private func rowTitle(_ stream: StreamItem) -> String {
        let base = stream.streamLabel
        guard model.instantSuffixEnabled,
              let status = stream.debridCacheStatus,
              status.state == .cached else { return base }
        var provider = DebridProviders.shared.shortName(id: status.providerId)
        if provider.trimmingCharacters(in: .whitespaces).isEmpty {
            provider = status.providerName.trimmingCharacters(in: .whitespaces)
        }
        if provider.isEmpty {
            provider = DebridProviders.shared.displayName(id: status.providerId)
        }
        return provider.isEmpty ? base : String(localized: "\(base) - \(provider) Instant")
    }

    // MARK: - Playback / debrid resolve

    /// The validated default external player, or nil for built-in. Membership in the probed
    /// `externalPlayers` list is required — a stale stored id (player uninstalled since it was
    /// chosen) must not hijack every Select into a failed handoff.
    private var activeDefaultExternalPlayer: ExternalPlayerApp? {
        guard !defaultExternalPlayerId.isEmpty else { return nil }
        return externalPlayers.first { $0.id == defaultExternalPlayerId }
    }

    /// Select on a stream row. Routes to the user's default player (Settings → Playback):
    /// external default ⇒ hand off (with automatic fallback to the built-in player if the
    /// handoff fails), otherwise the built-in pipeline.
    private func play(_ stream: StreamItem, rowKey: String) {
        if let defaultPlayer = activeDefaultExternalPlayer {
            externalPlay(stream, rowKey: rowKey, playerId: defaultPlayer.id, fallbackToInternal: true)
            return
        }
        internalPlay(stream, rowKey: rowKey)
    }

    private func internalPlay(_ stream: StreamItem, rowKey: String) {
        let direct: String? = stream.playableDirectUrl
        if let direct, !direct.isEmpty, let url = URL(string: direct) {
            // A manual stream pick is user interaction — reset the Still Watching run.
            NextEpisodeEngine.consecutiveAutoPlays = 0
            selected = context(url: url, stream: stream)
            return
        }

        // Torrent / clientResolve result → resolve through the in-app debrid connection.
        guard resolvingKey == nil else { return }
        guard DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: stream) else {
            showToast(String(localized: "This stream needs a debrid account. Connect one in Settings \u{2192} Debrid."))
            return
        }
        resolvingKey = rowKey
        DirectDebridPlaybackResolver.shared.resolveToPlayableStream(
            stream: stream,
            season: season.map { KotlinInt(int: Int32($0)) },
            episode: episode.map { KotlinInt(int: Int32($0)) }
        ) { result, _ in
            // Kotlin suspend completions can land off-main; hop before touching view state.
            DispatchQueue.main.async {
                resolvingKey = nil
                if let success = result as? DirectDebridPlayableResult.Success {
                    let resolvedUrl: String? = success.stream.playableDirectUrl
                    if let resolvedUrl, !resolvedUrl.isEmpty, let url = URL(string: resolvedUrl) {
                        NextEpisodeEngine.consecutiveAutoPlays = 0
                        selected = context(url: url, stream: success.stream)
                        return
                    }
                }
                showToast(Self.resolveFailureMessage(result))
                // The toast promises a refresh — deliver it: stale cached links mean the whole
                // result set is old, so re-fetch (focus is preserved; see onChange guard).
                if result is DirectDebridPlayableResult.Stale {
                    model.reload()
                }
            }
        }
    }

    // MARK: - External player handoff (FEAT-5)

    /// Hands the stream to an installed external player (Infuse today) instead of the in-app
    /// player — reached from a row long-press, or from plain Select when that player is the
    /// user's default. Mirrors `internalPlay(_:rowKey:)`'s two branches — direct URLs open
    /// immediately; torrent/clientResolve results go through the same debrid resolve first,
    /// reusing `resolvingKey` so the row spinner and the one-at-a-time guard behave identically
    /// for both destinations.
    ///
    /// `fallbackToInternal` is set on the default-player route only: a failed handoff there
    /// would strand a user whose Select no longer plays anything, so it degrades to the built-in
    /// player. The explicit long-press route keeps the honest failure toast instead — the user
    /// asked for Infuse specifically, silently playing elsewhere would be surprising.
    private func externalPlay(_ stream: StreamItem, rowKey: String, playerId: String, fallbackToInternal: Bool = false) {
        let direct: String? = stream.playableDirectUrl
        if let direct, !direct.isEmpty {
            openExternally(urlString: direct, stream: stream, playerId: playerId, fallbackToInternal: fallbackToInternal)
            return
        }

        guard resolvingKey == nil else { return }
        guard DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: stream) else {
            showToast(String(localized: "This stream needs a debrid account. Connect one in Settings \u{2192} Debrid."))
            return
        }
        resolvingKey = rowKey
        DirectDebridPlaybackResolver.shared.resolveToPlayableStream(
            stream: stream,
            season: season.map { KotlinInt(int: Int32($0)) },
            episode: episode.map { KotlinInt(int: Int32($0)) }
        ) { result, _ in
            DispatchQueue.main.async {
                resolvingKey = nil
                if let success = result as? DirectDebridPlayableResult.Success {
                    let resolvedUrl: String? = success.stream.playableDirectUrl
                    if let resolvedUrl, !resolvedUrl.isEmpty {
                        openExternally(
                            urlString: resolvedUrl,
                            stream: success.stream,
                            playerId: playerId,
                            fallbackToInternal: fallbackToInternal
                        )
                        return
                    }
                }
                showToast(Self.resolveFailureMessage(result))
                if result is DirectDebridPlayableResult.Stale {
                    model.reload()
                }
            }
        }
    }

    /// Builds the shared playback request and opens the target player via its x-callback-url
    /// scheme. Title/season/episode feed `buildPlayerTitle()` so Infuse shows
    /// "Show — S02E05" instead of a bare debrid CDN filename. Subtitles are omitted for now:
    /// the addon-subtitle URLs live player-side and Infuse fetches its own — revisit if
    /// testers ask. Must run on the main thread (UIApplication.open under the hood).
    private func openExternally(urlString: String, stream: StreamItem, playerId: String, fallbackToInternal: Bool = false) {
        let request = ExternalPlayerPlaybackRequest(
            sourceUrl: urlString,
            title: title,
            streamTitle: nil,
            sourceHeaders: [:],
            resumePositionMs: 0,
            subtitles: nil,
            season: season.map { KotlinInt(int: Int32($0)) },
            episode: episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: nil,
            skipSegmentsJson: nil
        )
        let result = ExternalPlayerPlatform.shared.open(request: request, playerId: playerId)
        // SharedCore lowercases the whole Kotlin enum entry name (see KMP bridging notes).
        guard result != ExternalPlayerOpenResult.opened else { return }
        if fallbackToInternal, let url = URL(string: urlString) {
            showToast(String(localized: "Couldn\u{2019}t open the external player \u{2014} playing in NuvioTV."))
            NextEpisodeEngine.consecutiveAutoPlays = 0
            selected = context(url: url, stream: stream)
        } else {
            showToast(String(localized: "Couldn\u{2019}t open the external player."))
        }
    }

    /// Mirrors the shared `DirectDebridPlayableResult.toastMessage()` wording (tvOS renders the
    /// English fallbacks; matching locally avoids depending on the ext-fun's bridged name).
    /// BUG-21: `Error` now carries a step-specific diagnostic ("TorBox: adding the item failed
    /// (HTTP 403 · BAD_TOKEN: …)") built shared-side — show it verbatim so a tester's toast
    /// names the exact failing call instead of the old catch-all.
    private static func resolveFailureMessage(_ result: DirectDebridPlayableResult?) -> String {
        switch result {
        case is DirectDebridPlayableResult.MissingApiKey:
            return String(localized: "Connect an account in Settings.")
        case is DirectDebridPlayableResult.NotCached:
            return String(localized: "Not cached on your debrid service.")
        case is DirectDebridPlayableResult.Stale:
            return String(localized: "This link expired. Refreshing results.")
        case let error as DirectDebridPlayableResult.Error:
            return error.message ?? String(localized: "Could not open this link.")
        default:
            return String(localized: "Could not open this link.")
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if toast == shown {
                withAnimation { toast = nil }
            }
        }
    }
}

/// Attaches the "play somewhere else" context menu only when at least one supported external
/// player is installed (FEAT-5). A conditional modifier rather than an inline `.contextMenu` so
/// the no-players case adds NOTHING to the row — an empty context menu would still swallow the
/// long-press and show a blank platter, which reads as broken.
///
/// The menu always offers the destinations plain Select does NOT: with the built-in player as
/// default it lists the external players; with an external default it lists "Play in NuvioTV
/// Player" first (the escape hatch back) plus any other installed externals. The default player
/// itself is omitted — Select already goes there, and a menu entry duplicating Select reads as
/// two different actions.
private struct ExternalPlayMenu: ViewModifier {
    let players: [ExternalPlayerApp]
    /// The validated default external player id, or nil when the built-in player is default.
    let defaultPlayerId: String?
    let onExternal: (ExternalPlayerApp) -> Void
    let onBuiltIn: () -> Void

    func body(content: Content) -> some View {
        if players.isEmpty {
            content
        } else {
            content.contextMenu {
                if defaultPlayerId != nil {
                    Button {
                        onBuiltIn()
                    } label: {
                        Label("Play in NuvioTV Player", systemImage: "play.tv")
                    }
                }
                ForEach(players.filter { $0.id != defaultPlayerId }, id: \.id) { player in
                    Button {
                        onExternal(player)
                    } label: {
                        Label("Open in \(player.name)", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
    }
}
