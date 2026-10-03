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
///
/// Auto-Play Best Source (orivio batch item 1): with the "first stream" auto-play mode on and the
/// picker not forced manual, a visit opens in auto mode — `FirstPlayAutoPlayController` walks the
/// shared repository's settled candidates under a full-screen "Finding the best source…" overlay
/// and opens the player itself; Back from that player dismisses the picker too. With an external
/// default player (Settings → Player → Default Player) the first auto pick is handed to it and
/// the picker closes; failover always plays in the built-in player. Menu on the overlay
/// drops to the list. Failover (item 2): a presented playback that fails is remembered
/// (`RejectedStreamLinks`) and, by `PlaybackContext.launchSource`, swaps in the next auto
/// candidate, opens a picker for the Up Next episode that failed, or offers "Try Next Source".
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
    /// Info-tab header inputs (optional; launch paths without meta at hand pass nil and the header
    /// omits them). `poster` is the catalog/series poster (also persisted as the parent artwork by
    /// the progress recorder); `episodeStill` is the 16:9 episode image shown in preference to it.
    let poster: String?
    let episodeStill: String?
    let synopsis: String?
    /// Title-level facts for the player's Info tab chips (nil when the caller has no meta).
    let meta: PlaybackMeta?
    /// FEAT-42: the title's configured logo (series/movie `MetaDetails.logo`), shown in place of
    /// the plain text heading when it loads — mobile parity for the stream picker screen. `nil`
    /// on launch paths with no meta at hand (Home continue-watching, Top Shelf).
    let logoUrl: String?
    /// Never auto-start, whatever the auto-play setting says ("Choose Source…", "Play Manually").
    let forceManual: Bool
    /// "Start Over": every playback this picker starts ignores saved progress.
    let startFromBeginning: Bool
    /// A toast shown when the picker opens on its list (the Up Next failover picker's explanation).
    let notice: String?

    @StateObject private var model: StreamsViewModel
    @StateObject private var autoPlay: FirstPlayAutoPlayController
    /// First-play auto mode for this visit. Evaluated once, at the first appearance; cleared when
    /// the controller plays, gives up or is cancelled, so every later load — the re-appearance
    /// after the player, the debrid-Stale reload — asks for the plain list (`manualSelection`).
    @State private var autoPlayArmed = false
    @State private var autoPlayEvaluated = false
    /// The open player was auto-started: closing it dismisses the picker too, so Back lands on the
    /// page that opened the picker.
    @State private var dismissAfterPlayer = false
    /// Up Next failover: the picker for the episode whose source failed, presented once the player
    /// has closed (`pendingFailoverTarget` waits for that).
    @State private var failoverTarget: FailoverTarget?
    @State private var pendingFailoverTarget: FailoverTarget?
    /// Manual-pick failure alert, raised once the player has closed.
    @State private var manualFailureAlert: ManualFailureAlert?
    @State private var pendingManualFailureAlert: ManualFailureAlert?
    /// The list as it was when the viewer picked a row: "Try Next Source" walks this order.
    @State private var manualFailoverList: [StreamItem] = []
    /// Keys of links that failed recently for this title (row caption), re-read at the moments
    /// they can change — `RejectedStreamLinks` itself keeps no cache.
    @State private var rejectedKeys: Set<String> = []
    /// A "Start Over" playback from this picker has played five minutes: the request is honoured,
    /// so a later failover or retry resumes from the saved position instead of starting over again.
    @State private var startOverHonoured = false
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
    /// Info.plist's `LSApplicationQueriesSchemes` (Infuse, VLC, Outplayer, VidHub as of FEAT-21),
    /// so testers without any of them installed never see the handoff option at all. Empty ⇒ no
    /// menu is attached.
    @State private var externalPlayers: [ExternalPlayerApp] = []
    /// User-chosen default player (Settings → Player → Default Player). Empty = built-in.
    /// Same device-local key `DefaultPlayerRow` writes; validated against the live probe below
    /// so an uninstalled default silently reverts to built-in instead of dead-ending playback.
    @AppStorage("default_external_player_id") private var defaultExternalPlayerId = ""
    @Environment(\.dismiss) private var dismiss

    private static let testRowKey = "test-stream"
    /// Spinner key for a "Try Next Source" resolve (its row may be collapsed or off-screen).
    private static let failoverRowKey = "failover-next"
    /// `ExternalPlayerApp.id` of Infuse, the external player that reports playback back.
    private static let infusePlayerId = "infuse"
    private let testStreamURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!

    init(
        type: String,
        videoId: String,
        title: String,
        parentMetaId: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        episodes: [MetaVideo] = [],
        poster: String? = nil,
        episodeStill: String? = nil,
        synopsis: String? = nil,
        meta: PlaybackMeta? = nil,
        logoUrl: String? = nil,
        forceManual: Bool = false,
        startFromBeginning: Bool = false,
        notice: String? = nil
    ) {
        self.meta = meta
        self.logoUrl = logoUrl
        self.forceManual = forceManual
        self.startFromBeginning = startFromBeginning
        self.notice = notice
        self.poster = poster
        self.episodeStill = episodeStill
        self.synopsis = synopsis
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
        _autoPlay = StateObject(wrappedValue: FirstPlayAutoPlayController(
            titleKey: videoId,
            dependencies: .live(type: type, videoId: videoId, season: season, episode: episode)
        ))
    }

    /// `listedStream` is the stream as the list shows it (pre-resolve) and `streamKey` its
    /// `playbackStreamKey`; both empty for the test stream. "Start Over" carries over until a
    /// playback has honoured it (`startOverHonoured`).
    private func context(url: URL, stream: StreamItem?, listedStream: StreamItem? = nil, streamKey: String = "",
                         launchSource: PlaybackLaunchSource = .manual, attempt: Int = 0) -> PlaybackContext {
        PlaybackContext(
            url: url,
            title: title,
            contentType: type,
            parentMetaId: parentMetaId,
            videoId: videoId,
            season: season,
            episode: episode,
            poster: poster,
            background: nil,
            providerName: stream?.addonName,
            providerAddonId: stream?.addonId,
            streamTitle: stream.map { $0.streamLabel },
            streamSubtitle: { let s: String? = stream?.description_; return s }(),
            externalSubtitles: (stream?.externalSubtitles ?? []).map { sub in
                SubtitleFile(url: sub.url, language: sub.language, name: { let n: String? = sub.name; return n }())
            },
            bingeGroup: { let bg: String? = stream?.behaviorHints.bingeGroup; return bg }(),
            episodes: episodes.isEmpty ? fetchedEpisodes : episodes,
            synopsis: synopsis,
            episodeStill: episodeStill,
            meta: meta,
            fileSizeBytes: { let n: Int64? = stream?.behaviorHints.videoSize?.int64Value; return n }(),
            requestHeaders: StreamModelsKt.sanitizePlaybackHeaders(
                headers: stream?.behaviorHints.proxyHeaders?.request),
            launchSource: launchSource,
            streamKey: streamKey,
            startFromBeginning: startsOver,
            attempt: attempt,
            listedStream: listedStream
        )
    }

    /// Series launch paths that don't carry the episode list (Home continue-watching, Detail's
    /// primary Play) get it fetched here so the player can offer next-episode autoplay. No-op for
    /// movies and for paths that already passed `episodes` (EpisodesSection).
    private func fetchEpisodesIfNeeded() {
        guard episodes.isEmpty, fetchedEpisodes.isEmpty,
              ["series", "tv", "show", "tvshow"].contains(type.lowercased()) else { return }
        // The `@Throws` twin: a Kotlin exception out of the plain suspend export aborts the process.
        Task { @MainActor in
            do {
                let details = try await MetaDetailsRepository.shared.fetchChecked(
                    type: type, id: parentMetaId, cacheResult: true
                )
                let videos = details?.videos ?? []
                guard !videos.isEmpty else { return }
                fetchedEpisodes = videos
            } catch {
                print("[StreamPicker] episode list fetch failed: \(error)")
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Lazy so collapsed groups' rows (the overwhelming majority while addons are
                // still streaming in) are never built at all — this was the lag source (BUG-5):
                // a non-lazy VStack built every row of every addon up front.
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl - Theme.Spacing.xs) {
                    // FEAT-42: one heading — the title's logo when it loads, else the plain text
                    // title (mobile shows the series/movie logo on its stream-list screen too).
                    // beta.19-rc1 verdict (I1, BUG-134): the TMDB `original` logo, decoded for the header's slot.
                    TitleLogoHeader(title: title, logoUrl: logoUrl,
                                    decodeSize: .points(width: 600, height: 120), upgrade: .logo)

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
                // Under the auto-play overlay nothing in the list may take focus or a Select.
                .disabled(autoPlayOverlayVisible)
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
            .overlay {
                if autoPlayOverlayVisible, let message = FirstPlayAutoPlayController.Policy.overlayMessage(for: autoPlay.phase) {
                    FirstPlayAutoPlayOverlay(
                        title: title,
                        logoUrl: logoUrl,
                        artworkUrl: episodeStill ?? poster,
                        message: message,
                        onCancel: cancelAutoPlay
                    )
                    .transition(.opacity)
                }
            }
            .onReceive(model.$autoPlayFeed) { feed in autoPlay.ingest(feed) }
            .onReceive(autoPlay.events) { event in handleAutoPlayEvent(event) }
            .alert(
                "Couldn\u{2019}t play this source",
                isPresented: Binding(
                    get: { manualFailureAlert != nil },
                    set: { if !$0 { manualFailureAlert = nil } }
                ),
                presenting: manualFailureAlert
            ) { alert in
                if let next = alert.next {
                    Button("Try Next Source") {
                        manualFailureAlert = nil
                        // Let the alert finish dismissing before the player cover presents.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            internalPlay(next, rowKey: Self.failoverRowKey, attempt: alert.attempt)
                        }
                    }
                }
                Button("Back to Sources", role: .cancel) {
                    manualFailureAlert = nil
                }
            } message: { alert in
                Text(alert.reason)
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
                // on the (now hidden) test button. Never while the auto-play overlay holds focus
                // (the list is disabled under it); `focusListAfterAutoPlay()` runs when it lifts.
                guard !autoPlayOverlayVisible else { return }
                guard focusedRow == nil || focusedRow == Self.testRowKey else { return }
                if ids.count == 1, let firstKey = model.firstRowKey {
                    DispatchQueue.main.async { focusedRow = firstKey }
                } else if let firstId = ids.first {
                    DispatchQueue.main.async { focusedRow = Self.headerKey(groupId: firstId) }
                }
            }
            .onAppear {
                // Main-thread only (UIApplication.canOpenURL); cheap enough to re-probe every
                // appearance so an Infuse install mid-session is picked up next time the picker
                // opens instead of requiring an app relaunch. First, so an auto-play start already
                // knows the viewer's default player.
                externalPlayers = ExternalPlayerPlatform.shared.availablePlayers()
                if !autoPlayEvaluated {
                    autoPlayEvaluated = true
                    autoPlayArmed = !forceManual && Self.firstStreamAutoPlayOn()
                    if autoPlayArmed {
                        autoPlay.arm()
                    } else if let notice {
                        showToast(notice)
                    }
                }
                rejectedKeys = RejectedStreamLinks.rejected(for: videoId)
                model.start(forceManual: !autoPlayArmed)
                fetchEpisodesIfNeeded()
                // Head start for the player: addon subtitles for this title begin fetching while
                // the user is still choosing a stream, so the native path's pre-master window
                // (and the mpv side-load) see results instead of racing the network. The player's
                // own fetch call deduplicates against this one.
                SubtitleRepository.shared.fetchAddonSubtitles(type: type, videoId: videoId)
            }
            .onDisappear { model.stop() }
            .fullScreenCover(item: $selected, onDismiss: handlePlayerDismissed) { ctx in
                // `.id(ctx.id)` forces a full player rebuild when autoplay swaps in the next
                // episode's context (a same-position cover would otherwise keep the old libmpv
                // controller and just ignore the new context). Failover swaps in place the same
                // way (`PlaybackContext.attempt` keeps two candidates' ids apart).
                PlayerScreen(
                    context: ctx,
                    onPlayNext: { next in selected = next },
                    onPlaybackFailed: { failure in handlePlaybackFailure(failure, context: ctx) },
                    onPlaybackHealthy: { seconds in handlePlaybackHealthy(seconds, context: ctx) }
                )
                .ignoresSafeArea()
                .id(ctx.id)
            }
        }
        // Up Next failover: a picker for the episode whose source failed. Attached to the stack,
        // not beside the player cover, so the two presentations never share a view.
        .fullScreenCover(item: $failoverTarget, onDismiss: handleFailoverPickerDismissed) { target in
            StreamPickerView(
                type: target.context.contentType,
                videoId: target.context.videoId,
                title: target.context.title,
                parentMetaId: target.context.parentMetaId,
                season: target.context.season,
                episode: target.context.episode,
                episodes: target.context.episodes,
                poster: target.context.poster,
                episodeStill: target.context.episodeStill,
                synopsis: target.context.synopsis,
                meta: target.context.meta,
                logoUrl: logoUrl,
                forceManual: target.forceManual,
                startFromBeginning: false,
                notice: String(localized: "The next episode\u{2019}s source failed. Choose one below.")
            )
        }
    }

    /// "Start Over" still applies to the next playback this picker starts.
    private var startsOver: Bool { startFromBeginning && !startOverHonoured }

    /// The auto-play overlay is up (not while a failover resolves behind the open player).
    private var autoPlayOverlayVisible: Bool {
        autoPlay.isOverlayVisible && !autoPlay.isFailoverWalk
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
                    .rowTextColor(secondary: true)
                    .frame(width: 20, alignment: .center)
                Text(group.addonName)
                    .font(Theme.Font.sectionTitle)
                    .rowTextColor()
                Text(group.streams.count == 1 ? String(localized: "1 stream") : String(localized: "\(group.streams.count) streams"))
                    .font(Theme.Font.caption)
                    .rowTextColor(secondary: true)
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
            manualFailoverList = model.groups.flatMap(\.streams)
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
                            .rowTextColor()
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
                            .rowTextColor(secondary: true)
                            .lineLimit(focusedRow == key ? nil : 3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if hasBadgeRow && !model.badgesOnTop {
                        badgeRow(badges: badges, sizeBytes: showSize ? sizeBytes : nil)
                    }
                    // Orivio batch item 2: this link failed recently for this title, so the
                    // automatic pickers skip it. Still selectable by hand.
                    if !rejectedKeys.isEmpty, rejectedKeys.contains(stream.playbackStreamKey) {
                        Text("Failed recently")
                            .font(Theme.Font.caption)
                            .rowTextColor(secondary: true)
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
                manualFailoverList = model.groups.flatMap(\.streams)
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
                .rowTextColor(secondary: true)
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

    /// Select on a stream row. Routes to the user's default player (Settings → Player):
    /// external default ⇒ hand off (with automatic fallback to the built-in player if the
    /// handoff fails), otherwise the built-in pipeline.
    private func play(_ stream: StreamItem, rowKey: String) {
        if let defaultPlayer = activeDefaultExternalPlayer {
            externalPlay(stream, rowKey: rowKey, playerId: defaultPlayer.id, fallbackToInternal: true)
            return
        }
        internalPlay(stream, rowKey: rowKey)
    }

    /// A built-in-player playback the viewer chose (a row, the long-press menu, "Try Next Source",
    /// whose `attempt` counts the failed tries before it). Always `.manual`.
    private func internalPlay(_ stream: StreamItem, rowKey: String, attempt: Int = 0) {
        let streamKey = stream.playbackStreamKey
        let direct: String? = stream.playableDirectUrl
        if let direct, !direct.isEmpty, let url = URL(string: direct) {
            // A manual stream pick is user interaction — reset the Still Watching run.
            NextEpisodeEngine.consecutiveAutoPlays = 0
            dismissAfterPlayer = false
            selected = context(url: url, stream: stream, listedStream: stream, streamKey: streamKey,
                               launchSource: .manual, attempt: attempt)
            return
        }

        // Torrent / clientResolve result → resolve through the in-app debrid connection.
        guard resolvingKey == nil else { return }
        guard DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: stream) else {
            showToast(String(localized: "This stream needs a debrid account. Connect one in Settings \u{2192} Services \u{2192} Debrid."))
            return
        }
        resolvingKey = rowKey
        let kotlinSeason = season.map { KotlinInt(int: Int32($0)) }
        let kotlinEpisode = episode.map { KotlinInt(int: Int32($0)) }
        // The `@Throws` twin: a Kotlin exception out of the plain suspend export aborts the process.
        Task { @MainActor in
            let result: DirectDebridPlayableResult?
            do {
                result = try await DirectDebridPlaybackResolver.shared.resolveToPlayableStreamChecked(
                    stream: stream, season: kotlinSeason, episode: kotlinEpisode
                )
            } catch {
                print("[StreamPicker] debrid resolve threw: \(error)")
                result = nil
            }
            resolvingKey = nil
            if let success = result as? DirectDebridPlayableResult.Success {
                let resolvedUrl: String? = success.stream.playableDirectUrl
                if let resolvedUrl, !resolvedUrl.isEmpty, let url = URL(string: resolvedUrl) {
                    NextEpisodeEngine.consecutiveAutoPlays = 0
                    dismissAfterPlayer = false
                    selected = context(url: url, stream: success.stream, listedStream: stream, streamKey: streamKey,
                                       launchSource: .manual, attempt: attempt)
                    return
                }
            }
            showToast(Self.resolveFailureMessage(result))
            // The toast promises a refresh — deliver it: stale cached links mean the whole
            // result set is old, so re-fetch (focus is preserved; see onChange guard).
            if result is DirectDebridPlayableResult.Stale {
                model.reload(forceManual: !autoPlayArmed)
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
            openExternally(urlString: direct, stream: stream, listed: stream, playerId: playerId,
                           fallbackToInternal: fallbackToInternal)
            return
        }

        guard resolvingKey == nil else { return }
        guard DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: stream) else {
            showToast(String(localized: "This stream needs a debrid account. Connect one in Settings \u{2192} Services \u{2192} Debrid."))
            return
        }
        resolvingKey = rowKey
        let kotlinSeason = season.map { KotlinInt(int: Int32($0)) }
        let kotlinEpisode = episode.map { KotlinInt(int: Int32($0)) }
        // The `@Throws` twin: a Kotlin exception out of the plain suspend export aborts the process.
        Task { @MainActor in
            let result: DirectDebridPlayableResult?
            do {
                result = try await DirectDebridPlaybackResolver.shared.resolveToPlayableStreamChecked(
                    stream: stream, season: kotlinSeason, episode: kotlinEpisode
                )
            } catch {
                print("[StreamPicker] debrid resolve threw: \(error)")
                result = nil
            }
            resolvingKey = nil
            if let success = result as? DirectDebridPlayableResult.Success {
                let resolvedUrl: String? = success.stream.playableDirectUrl
                if let resolvedUrl, !resolvedUrl.isEmpty {
                    openExternally(
                        urlString: resolvedUrl,
                        stream: success.stream,
                        listed: stream,
                        playerId: playerId,
                        fallbackToInternal: fallbackToInternal
                    )
                    return
                }
            }
            showToast(Self.resolveFailureMessage(result))
            if result is DirectDebridPlayableResult.Stale {
                model.reload(forceManual: !autoPlayArmed)
            }
        }
    }

    /// Builds the shared playback request and opens the target player via its x-callback-url
    /// scheme. Title/season/episode feed `buildPlayerTitle()` so Infuse shows
    /// "Show — S02E05" instead of a bare debrid CDN filename. Must run on the main thread
    /// (UIApplication.open under the hood).
    ///
    /// FEAT-21 (beta.12): the handoff now carries what the internal player would use —
    /// `resumePositionMs` from the same `progressForVideo` lookup MPV's resume path runs (same
    /// >10s floor, completed entries excluded), and the stream's addon subtitles, so players
    /// whose URL builders consume `sub`/`position` (VidHub `/play`, Infuse, VLC) resume and
    /// subtitle like the built-in player instead of starting cold.
    ///
    /// Orivio batch item 5: an Infuse handoff first prepares a shared external-playback session and
    /// passes Infuse its x-success / x-error callback URLs on this install's own URL scheme, so the
    /// position Infuse reports back is recorded (`ExternalPlaybackReturn`). A handoff that does not
    /// open drops that session again. `listed` is the stream as the list shows it (pre-resolve).
    ///
    /// `autoAttempt` (1-based) marks the first-play auto start handing its pick to the viewer's
    /// external default: its built-in fallback is then an auto start too (`.autoPlay`, Back leaves
    /// the picker, a failure continues the walk). Returns true when the external player opened.
    @discardableResult
    private func openExternally(urlString: String, stream: StreamItem, listed: StreamItem, playerId: String,
                                fallbackToInternal: Bool = false, autoAttempt: Int? = nil) -> Bool {
        let progress = WatchProgressRepository.shared.progressForVideo(
            videoId: videoId,
            parentMetaId: parentMetaId,
            seasonNumber: season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: episode.map { KotlinInt(int: Int32($0)) }
        )
        // Percentage-only rows (Simkl/Trakt) stay 0 here: the real duration is unknown before the
        // file opens, and scaling by the show runtime is the bug being avoided. "Start Over" sends 0.
        let resumeMs: Int64 = {
            guard !startsOver else { return 0 }
            guard let progress, !progress.isCompleted, progress.lastPositionMs > 10_000 else { return 0 }
            return progress.lastPositionMs
        }()
        var launchSessionId: String?
        var callbackSuccessUrl: String?
        var callbackErrorUrl: String?
        if playerId == Self.infusePlayerId, let sourceURL = URL(string: urlString) {
            let session = ExternalPlaybackReturn.shared.prepare(
                playerId: Self.infusePlayerId,
                sourceUrl: urlString,
                playbackSession: PlaybackProgressRecorder.playbackSession(for: context(url: sourceURL, stream: stream)),
                durationMs: externalDurationMs(progress: progress).map { KotlinLong(value: $0) }
            )
            let callbacks = ExternalPlaybackCallbacks.shared.build(
                scheme: AppCallbackScheme.value, playerId: Self.infusePlayerId, sessionId: session.id
            )
            launchSessionId = session.id
            callbackSuccessUrl = callbacks.first.map { $0 as String }
            callbackErrorUrl = callbacks.second.map { $0 as String }
        }
        let request = ExternalPlayerPlaybackRequest(
            sourceUrl: urlString,
            title: title,
            streamTitle: nil,
            sourceHeaders: [:],
            resumePositionMs: resumeMs,
            subtitles: stream.externalSubtitles.map { sub in
                SubtitleInput(url: sub.url, name: { let n: String? = sub.name; return n }() ?? sub.language, lang: sub.language)
            },
            season: season.map { KotlinInt(int: Int32($0)) },
            episode: episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: nil,
            skipSegmentsJson: nil,
            // Infuse only (nil for every other player): where Infuse reports the stop position.
            callbackSuccessUrl: callbackSuccessUrl,
            callbackErrorUrl: callbackErrorUrl
        )
        let result = ExternalPlayerPlatform.shared.open(request: request, playerId: playerId)
        // SharedCore lowercases the whole Kotlin enum entry name (see KMP bridging notes).
        guard result != ExternalPlayerOpenResult.opened else { return true }
        if let launchSessionId {
            // Nothing was handed off: drop the pending return session (only if it is still this one).
            ExternalPlaybackReturn.shared.cancelLaunch(sessionId: launchSessionId)
        }
        if fallbackToInternal, let url = URL(string: urlString) {
            showToast(String(localized: "Couldn\u{2019}t open the external player \u{2014} playing in NuvioTV."))
            NextEpisodeEngine.consecutiveAutoPlays = 0
            if let autoAttempt {
                autoPlayLog("[AutoPlay] external player \(playerId) did not open — attempt #\(autoAttempt) plays in NuvioTV")
                dismissAfterPlayer = true
                selected = context(url: url, stream: stream, listedStream: listed, streamKey: listed.playbackStreamKey,
                                   launchSource: .autoPlay, attempt: autoAttempt - 1)
            } else {
                dismissAfterPlayer = false
                selected = context(url: url, stream: stream, listedStream: listed, streamKey: listed.playbackStreamKey,
                                   launchSource: .manual)
            }
        } else {
            showToast(String(localized: "Couldn\u{2019}t open the external player."))
        }
        return false
    }

    /// Duration for the external-player return: the stored progress entry's, else the episode's
    /// runtime, else the title's catalog runtime. nil = unknown (the shared side then records the
    /// position without a tracker scrobble).
    private func externalDurationMs(progress: WatchProgressEntry?) -> Int64? {
        if let progress, progress.durationMs > 0 { return progress.durationMs }
        let all = episodes.isEmpty ? fetchedEpisodes : episodes
        if let season, let episode,
           let video = all.first(where: { $0.season?.intValue == season && $0.episode?.intValue == episode }),
           let minutes = video.runtime?.intValue, minutes > 0 {
            return Int64(minutes) * 60_000
        }
        if let minutes = PlaybackMeta.runtimeMinutes(meta?.runtime), minutes > 0 {
            return Int64(minutes) * 60_000
        }
        return nil
    }

    // MARK: - First-play auto mode (orivio batch item 1)

    /// "Auto-Play Best Source" is the shared FIRST_STREAM auto-play mode.
    private static func firstStreamAutoPlayOn() -> Bool {
        PlayerSettingsRepository.shared.ensureLoaded()
        let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState
        return settings?.streamAutoPlayMode == StreamAutoPlayMode.firstStream
    }

    private func handleAutoPlayEvent(_ event: FirstPlayAutoPlayController.Event) {
        switch event {
        case let .play(candidate, resolved, url, attempt, isFailover):
            if isFailover, selected == nil {
                // The viewer closed the failed player while the next candidate resolved.
                autoPlayLog("[AutoPlay] failover result after the player closed — dropped")
                return
            }
            autoPlayArmed = false
            NextEpisodeEngine.consecutiveAutoPlays = 0
            if case let .external(playerId) = FirstPlayAutoPlayController.Policy.startDestination(
                isFailover: isFailover, defaultExternalPlayerId: activeDefaultExternalPlayer?.id
            ) {
                // The viewer's default player is external: the auto pick goes there, as Select on a
                // row would. Handed off, the picker leaves too (Back from the player would have);
                // a handoff that does not open plays in NuvioTV as this same auto start.
                autoPlayLog("[AutoPlay] attempt #\(attempt) to external player \(playerId) key=\(candidate.streamKey)")
                let opened = openExternally(urlString: url.absoluteString, stream: resolved, listed: candidate.stream,
                                            playerId: playerId, fallbackToInternal: true, autoAttempt: attempt)
                if opened {
                    DispatchQueue.main.async { dismiss() }
                }
                return
            }
            dismissAfterPlayer = true
            // Set straight from the event: during a failover this swaps the open player in place.
            selected = context(url: url, stream: resolved, listedStream: candidate.stream,
                               streamKey: candidate.streamKey, launchSource: .autoPlay, attempt: attempt - 1)
        case let .gaveUp(reason, duringFailover):
            autoPlayArmed = false
            rejectedKeys = RejectedStreamLinks.rejected(for: videoId)
            if duringFailover {
                // The viewer already left the player: nothing to explain.
                guard selected != nil else {
                    autoPlayLog("[AutoPlay] walk ended (\(reason)) after the player had closed — nothing shown, rejected=\(rejectedKeys.count)")
                    return
                }
                dismissAfterPlayer = false
                selected = nil
            }
            let listedStreams = model.groups.reduce(0) { $0 + $1.streams.count }
            autoPlayLog("[AutoPlay] walk ended (\(reason)) — showing the list: groups=\(model.groups.count) streams=\(listedStreams) rejected=\(rejectedKeys.count) failover=\(duringFailover)")
            if duringFailover || !model.groups.isEmpty {
                showToast(String(localized: "No source could start. Choose one below."))
            }
            focusListAfterAutoPlay()
        }
    }

    /// Menu on the overlay: stop auto mode and show the list; the picker stays.
    private func cancelAutoPlay() {
        autoPlay.cancel(why: "Menu on the overlay")
        autoPlayArmed = false
        focusListAfterAutoPlay()
    }

    /// Initial focus for the list once the overlay lifts (same targets as the first-groups rule).
    private func focusListAfterAutoPlay() {
        DispatchQueue.main.async {
            guard focusedRow == nil || focusedRow == Self.testRowKey else { return }
            let ids = model.groups.map(\.id)
            if ids.count == 1, expandedGroups.contains(ids[0]), let firstKey = model.firstRowKey {
                focusedRow = firstKey
            } else if let firstId = ids.first {
                focusedRow = Self.headerKey(groupId: firstId)
            }
        }
    }

    // MARK: - Failover (orivio batch item 2)

    /// A playback this picker presented failed. The link is remembered when it never got going,
    /// then the launch source decides: swap in the next auto candidate, open a picker for the Up
    /// Next episode, or close to the "Try Next Source" alert.
    private func handlePlaybackFailure(_ failure: PlaybackFailure, context ctx: PlaybackContext) {
        guard selected?.id == ctx.id else {
            print("[Failover] failure for a context no longer presented — ignored")
            return
        }
        print("[Failover] failure source=\(ctx.launchSource) attempt=\(ctx.attempt) played=\(Int(failure.secondsPlayed))s key=\(ctx.streamKey) reason=\(failure.reason)")
        if PlaybackFailoverPolicy.shouldKeep(secondsPlayed: failure.secondsPlayed), ctx.videoId == videoId {
            startOverHonoured = true
        }
        if PlaybackFailoverPolicy.shouldReject(failure) {
            RejectedStreamLinks.reject(ctx.streamKey, title: ctx.videoId)
            if let listed = ctx.listedStream, listed.isAddonDebridCandidate {
                // The resolver would hand the same dead link back for 15 minutes.
                DirectDebridPlaybackResolver.shared.invalidate(
                    stream: listed,
                    season: ctx.season.map { KotlinInt(int: Int32($0)) },
                    episode: ctx.episode.map { KotlinInt(int: Int32($0)) }
                )
            }
        }
        rejectedKeys = RejectedStreamLinks.rejected(for: videoId)

        var response = PlaybackFailoverPolicy.response(for: ctx.launchSource)
        if response == .manualAlert, ctx.videoId != videoId {
            // An in-player source switch on a later episode failed: this picker's list is the
            // wrong title, so open that episode's own picker on its list instead.
            response = .nextEpisodePicker
        }
        switch response {
        case .autoFailover:
            if !autoPlay.failover(afterFailureOf: ctx.streamKey, addonId: ctx.providerAddonId) {
                handleAutoPlayEvent(.gaveUp(.allFailed, duringFailover: true))
            }
        case .nextEpisodePicker:
            let forceManual = ctx.launchSource == .manual || !Self.firstStreamAutoPlayOn()
            pendingFailoverTarget = FailoverTarget(context: ctx, forceManual: forceManual)
            selected = nil
        case .manualAlert:
            pendingManualFailureAlert = ManualFailureAlert(
                reason: failure.reason,
                next: nextManualStream(after: ctx),
                attempt: ctx.attempt + 1
            )
            dismissAfterPlayer = false
            selected = nil
        }
    }

    /// The link played long enough to count as healthy: forget an earlier failure of it.
    private func handlePlaybackHealthy(_ seconds: Double, context ctx: PlaybackContext) {
        guard PlaybackFailoverPolicy.shouldKeep(secondsPlayed: seconds) else { return }
        RejectedStreamLinks.keep(ctx.streamKey, title: ctx.videoId)
        if ctx.videoId == videoId {
            startOverHonoured = true
            rejectedKeys = RejectedStreamLinks.rejected(for: videoId)
        }
    }

    /// The stream "Try Next Source" plays after `ctx`'s: the list as it was when the viewer picked
    /// (falling back to the live list), after the failed one, same add-on first, failed links skipped.
    private func nextManualStream(after ctx: PlaybackContext) -> StreamItem? {
        let list = manualFailoverList.isEmpty ? model.groups.flatMap(\.streams) : manualFailoverList
        let entries = list.map { PlaybackFailoverPolicy.Entry(key: $0.playbackStreamKey, addonId: $0.addonId) }
        guard let index = PlaybackFailoverPolicy.nextManualIndex(
            entries: entries,
            failedKey: ctx.streamKey,
            failedAddonId: ctx.providerAddonId,
            rejected: RejectedStreamLinks.rejected(for: videoId)
        ) else { return nil }
        return list[index]
    }

    /// The player cover closed. A context swap (failover, Up Next) re-presents instead and leaves
    /// `selected` set; a real close raises whatever the failure queued — never in the same runloop
    /// as the dismissal — or, after an auto-started playback, dismisses the picker as well.
    private func handlePlayerDismissed() {
        guard selected == nil else { return }
        rejectedKeys = RejectedStreamLinks.rejected(for: videoId)
        if let pending = pendingManualFailureAlert {
            pendingManualFailureAlert = nil
            DispatchQueue.main.async { manualFailureAlert = pending }
            return
        }
        if let pending = pendingFailoverTarget {
            pendingFailoverTarget = nil
            DispatchQueue.main.async { failoverTarget = pending }
            return
        }
        // A failover still resolving behind the closed player must not reopen it.
        autoPlay.cancel(why: "player closed")
        if dismissAfterPlayer {
            dismissAfterPlayer = false
            DispatchQueue.main.async { dismiss() }
        }
    }

    /// The Up Next failover picker closed. Both pickers share the one `StreamsRepository`, so this
    /// picker's list is reloaded; after an auto-started visit, Back keeps going to the opener.
    private func handleFailoverPickerDismissed() {
        if dismissAfterPlayer {
            dismissAfterPlayer = false
            DispatchQueue.main.async { dismiss() }
            return
        }
        model.stop()
        model.start(forceManual: true)
        rejectedKeys = RejectedStreamLinks.rejected(for: videoId)
    }

    /// Mirrors the shared `DirectDebridPlayableResult.toastMessage()` wording (tvOS renders the
    /// English fallbacks; matching locally avoids depending on the ext-fun's bridged name).
    /// BUG-21: `Error` now carries a step-specific diagnostic ("TorBox: adding the item failed
    /// (HTTP 403 · BAD_TOKEN: …)") built shared-side — show it verbatim so a tester's toast
    /// names the exact failing call instead of the old catch-all.
    private static func resolveFailureMessage(_ result: DirectDebridPlayableResult?) -> String {
        switch result {
        case is DirectDebridPlayableResult.MissingApiKey:
            return String(localized: "Connect an account in Settings \u{2192} Services \u{2192} Debrid.")
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

    /// The Up Next episode (or other foreign video) whose playback failed, for the nested picker.
    private struct FailoverTarget: Identifiable {
        let id = UUID()
        let context: PlaybackContext
        /// Open on the list (auto-play off, or the failed link was the viewer's own pick).
        let forceManual: Bool
    }

    /// "Couldn't play this source": the engine's reason and the stream "Try Next Source" plays.
    private struct ManualFailureAlert: Identifiable {
        let id = UUID()
        let reason: String
        let next: StreamItem?
        /// `PlaybackContext.attempt` for the next try.
        let attempt: Int
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
