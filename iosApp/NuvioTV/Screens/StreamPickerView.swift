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
/// List: one flat, lazy list of stream rows (`LazyVStack`, so rows build as they scroll into view
/// and the picker does not lag while addons are still resolving). In the "All" view each addon's
/// rows sit under a small non-focusable section label (name, plus its own "Fetching…" spinner
/// while it is still answering); under a source chip the labels are hidden.
///
/// Focus: rows carry stable focus keys. Initial focus lands on the first stream row once streams
/// arrive. (Previously the dev test-stream button at the bottom was the only focusable view while
/// loading, so focus landed — and stayed — at the bottom of the list.)
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
    /// Stream picker A (P1): the title's backdrop for `StreamPickerBackdrop`. Presenters with the
    /// catalog record pass it; the others leave nil and the picker reads the details cache.
    let background: String?
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
    /// P3.3: the saved position for the resume pill (nil = none known). Presenters that have an
    /// entry pass it; the pill is hidden under "Start Over".
    let resumePositionMs: Int64?
    /// P3.3: the saved fraction (0...1) when only a percentage is known (Trakt / Simkl rows).
    let resumeFraction: Double?
    /// A toast shown when the picker opens on its list (the Up Next failover picker's explanation).
    let notice: String?
    /// P5 B22: set by presenters that push a Detail page once the picker closes; forwarded to the
    /// player's post-play More Like This row.
    let onOpenTitle: ((MetaPreview) -> Void)?
    /// P5 B22: the post-play poster the viewer picked, held until the picker itself closes.
    @State private var postPlayPick: MetaPreview?

    @StateObject private var model: StreamsViewModel
    @StateObject private var autoPlay: FirstPlayAutoPlayController
    /// First-play auto mode for this visit. BUG-183 (Steven rc7): decided in `init` (a synchronous
    /// settings read, like `PlayerLoadingOverlaySetting`), so the loading cover is up from the
    /// picker's first frame instead of after `onAppear` armed the controller (the list flashed for
    /// about a second). The controller itself is still armed once, at the first appearance. Cleared
    /// when the controller plays, gives up or is cancelled, so every later load — the debrid-Stale
    /// reload — asks for the plain list (`manualSelection`).
    @State private var autoPlayArmed: Bool
    @State private var autoPlayEvaluated = false
    /// BUG-174/183 (Steven rc7): the loading cover stays over the list — while an auto pick's player
    /// is being presented and up (the controller's `.done` alone hid it a beat too early), while
    /// the Up Next failover picker is up, and while the picker closes after a player (the list
    /// must not show on the way out).
    @State private var coverHold = false
    /// BUG-185 (Steven rc9, D6): the held cover is the close-time hold (the picker is leaving after
    /// a player or a hand-off), drawn as plain black: the title logo is for starts only.
    @State private var coverIsCloseHold = false
    /// BUG-185: when the viewer's close of the player reached the cover binding, for the
    /// setter → `onDismiss` timing line (under 100 ms reads as an instant dismiss).
    @State private var playerCloseRequestedAt: CFAbsoluteTime?
    /// BUG-174: the player closed onto something the viewer needs to see on the list (an auto walk
    /// that ended with nothing during a failover). Read once, by `handlePlayerDismissed`.
    @State private var keepListAfterPlayer = false
    /// Review r1 (P2): an external hand-off is waiting for the add-on subtitles (D5).
    @State private var externalHandOffInFlight = false
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
    /// Issue #19 (review r1): the catalog runtime fetched for a launch path that carries no `meta`
    /// (Home / Library continue-watching, a deep link). A Trakt/Simkl percentage-only entry has
    /// no position, so an external player needs this runtime to resume (`externalDurationMs`).
    @State private var fetchedRuntime: String?
    /// Review r2: true while that runtime fetch is in flight, so an external hand-off that comes
    /// first (auto-play, a fast source) waits for it briefly (`ExternalResumePolicy.awaitRuntime`).
    @State private var runtimeFetchPending = false
    /// Row key currently mid debrid-resolve (drives the row spinner; one resolve at a time).
    @State private var resolvingKey: String?
    /// False once the picker left the screen (a Menu press during a resolve): a late result must
    /// not hand a link to an external player from a view that is gone (batch D review r1).
    @State private var pickerOnScreen = false
    /// Batch D review r2 P3-2: the YouTube resolve in flight, by request. `resolvingKey == rowKey`
    /// was no guard at all (only the owning completion ever reset it), and `selected == nil`
    /// missed a playback that started AND ended inside the resolve window (an auto-play pick or
    /// a failover dismissed within the 30 s). The token is minted when a resolve starts and
    /// dropped the moment any playback starts (`selected` set, see `onChange`) or the picker
    /// leaves the screen; a completion whose token is no longer current does nothing.
    @State private var youTubeResolveToken: UUID?
    /// The resolve's Task (review r2 P3-3): cancelled with the token, so a superseded or abandoned
    /// resolve stops the extractor instead of running to the 30 s timeout in the background.
    @State private var youTubeResolveTask: Task<Void, Never>?
    /// Transient failure message (debrid resolve errors), auto-dismissed after a few seconds.
    @State private var toast: String?
    @FocusState private var focusedRow: String?
    /// P1: the backdrop read from the details cache when the presenter passed no `background`.
    @State private var peekedBackground: String?
    /// P2: error chips dropped after the fan-out finished (`SourceChipRow.chipsToDrop`); cleared
    /// when a fan-out starts again.
    @State private var hiddenErrorChips: Set<String> = []
    @State private var errorChipTask: Task<Void, Never>?
    /// P2: the last Left/Right the list turned into a chip step (Android TV's 112 ms throttle). A
    /// reference box, not a value, so the stamp never invalidates the picker's body (review r1).
    @State private var chipMoveThrottle = ChipMoveThrottle()
    /// P4 device pass: the initial placement is VERIFIED, not fire-and-forget. On the box the first
    /// write raced the LazyVStack's row realization and the chip row's own default focus, and the
    /// one-shot latch then stood down with focus on the "All" chip. The target is kept until focus
    /// is seen on it; while focus is still nowhere or on a chip the viewer has not acted on, the
    /// write is re-issued (350 ms apart, three times at most). Any viewer action clears it.
    @State private var initialFocusTarget: String?
    @State private var initialFocusAttempts = 0
    @State private var initialFocusVerifyTask: Task<Void, Never>?
    /// P2 (review r1, P1): the list's initial-focus rules fire once per load. Before P2 they fired
    /// while focus was nowhere or on the test button; now the chips are focusable from the first
    /// frame and take focus before any row exists, so "focus is still on a chip" counts as
    /// unplaced until the viewer has acted on a chip. Re-armed by the stale-link reload.
    @State private var didPlaceListFocus = false
    /// Direction C (card promotion, C-14): the key `placeInitialListFocus` last wrote. When it was a
    /// pill (no stream was eligible yet) and the best-pick card appears while focus still sits on
    /// that pill, focus is promoted to the card. Reset wherever `didPlaceListFocus` is re-armed.
    @State private var placedFocusKey: String?
    /// Direction C: the pending focus request (`requestListFocus`) came from a press (Show all, tier
    /// expand), so the verify pass re-issues THAT key instead of re-targeting the body's first
    /// focus key (the card), which would undo an expand.
    @State private var initialFocusPinned = false
    /// P5 device pass: the viewer pressed a chip, Refresh, or moved along the chips this load. A
    /// load that empties the list (the repository publishes a fresh state before its first group
    /// lands, e.g. a re-open of a title whose cached groups the watcher emitted first) re-arms the
    /// initial-focus rule only while this is false, so a viewer's chip focus is never pulled to the
    /// list by the refresh they asked for.
    @State private var viewerChoseChip = false
    /// P2: a D-pad chip step moves focus to the list's first target once the filtered groups land;
    /// a Select on a chip keeps focus on the chip. Three states (review r3): `.pending` from the
    /// step until the filter handler runs; `.awaitingGroups` when the stepped-to add-on had no
    /// rows yet, completed by the groups handler alone (the two handlers fire in the same update
    /// in no fixed order, so each completes only its own stage).
    @State private var filterFocusRequest: FilterFocusRequest = .none

    enum FilterFocusRequest { case none, pending, awaitingGroups }
    /// P2: anchors `.prefersDefaultFocus` on the selected chip, so Up from the first row lands on it.
    @Namespace private var chipFocusNamespace
    /// External players installed on this Apple TV (FEAT-5). Probed once per appearance via the
    /// shared `ExternalPlayerPlatform` — `canOpenURL` only returns true for schemes declared in
    /// Info.plist's `LSApplicationQueriesSchemes` (Infuse, VLC, Outplayer, VidHub as of FEAT-21,
    /// SenPlayer as of FEAT-56),
    /// so testers without any of them installed never see the handoff option at all. Empty ⇒ no
    /// menu is attached.
    @State private var externalPlayers: [ExternalPlayerApp] = []
    /// User-chosen default player (Settings → Player → Default Player). Empty = built-in.
    /// Same device-local key `DefaultPlayerRow` writes; validated against the live probe below
    /// so an uninstalled default silently reverts to built-in instead of dead-ending playback.
    @AppStorage("default_external_player_id") private var defaultExternalPlayerId = ""
    @Environment(\.dismiss) private var dismiss

    private static let testRowKey = "test-stream"
    /// P3: the zero-height anchor at the top of the list (`scrollTo` target for a chip step).
    private static let listTopKey = "list-top"
    /// Spinner key for a "Try Next Source" resolve (its row may be off-screen or filtered out).
    private static let failoverRowKey = "failover-next"
    /// Spinner key while an external hand-off waits for the add-on subtitles (D5) with no row of
    /// its own (the auto path).
    private static let handOffRowKey = "external-handoff"
    /// `ExternalPlayerApp.id`s of the external players that report the stop position back over an
    /// x-callback return (`ExternalPlaybackReturn`): Infuse (7.6.2+, `x-success` with `position`)
    /// and, FEAT-56 (GitHub #5), SenPlayer (6.1.1+ returns the current playback time on exit; the
    /// query parameter name is unverified on hardware — the `debug.extPlayerProbe` print in
    /// `ContentView.handleDeepLink` shows what it sends). Every other player gets no callback URLs.
    static let returnReportingPlayerIds: Set<String> = ["infuse", "senplayer", "nativeplayer"]
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
        background: String? = nil,
        episodeStill: String? = nil,
        synopsis: String? = nil,
        meta: PlaybackMeta? = nil,
        logoUrl: String? = nil,
        forceManual: Bool = false,
        startFromBeginning: Bool = false,
        resumePositionMs: Int64? = nil,
        resumeFraction: Double? = nil,
        notice: String? = nil,
        onOpenTitle: ((MetaPreview) -> Void)? = nil
    ) {
        self.onOpenTitle = onOpenTitle
        self.meta = meta
        self.logoUrl = logoUrl
        self.forceManual = forceManual
        self.startFromBeginning = startFromBeginning
        self.resumePositionMs = resumePositionMs
        self.resumeFraction = resumeFraction
        self.notice = notice
        self.poster = poster
        self.background = background
        self.episodeStill = episodeStill
        self.synopsis = synopsis
        self.type = type
        self.videoId = videoId
        self.title = title
        self.parentMetaId = parentMetaId ?? videoId
        self.season = season
        self.episode = episode
        self.episodes = episodes
        // BUG-183: decided here, not in `onAppear` — the cover must be in the first frame.
        _autoPlayArmed = State(initialValue: !forceManual && Self.firstStreamAutoPlayOn())
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
            logo: logoUrl,
            meta: meta,
            fileSizeBytes: { let n: Int64? = stream?.behaviorHints.videoSize?.int64Value; return n }(),
            streamAudioDelayMs: { let n: Int? = stream?.behaviorHints.audioDelayMs?.intValue; return n }(),
            requestHeaders: StreamModelsKt.sanitizePlaybackHeaders(
                headers: stream?.behaviorHints.proxyHeaders?.request),
            launchSource: launchSource,
            streamKey: streamKey,
            startFromBeginning: startsOver,
            attempt: attempt,
            listedStream: listedStream,
            // Batch D U2: a ytId-only stream plays a link resolved on this device that expires
            // within hours — never persisted as the entry's last source URL.
            sessionOnlySourceUrl: Self.isYouTubeResolved(listedStream)
        )
    }

    /// Series launch paths that don't carry the episode list (Home continue-watching, Detail's
    /// primary Play) get it fetched here so the player can offer next-episode autoplay. No-op for
    /// paths that already passed `episodes` (EpisodesSection). Issue #19 (review r1): a movie
    /// launched without `meta` and without a saved position (a Trakt/Simkl percentage-only row
    /// from Continue Watching) fetches the same record for its runtime, so an external player can
    /// resume at the percentage (`ExternalResumePolicy.needsCatalogRuntime`).
    private func fetchEpisodesIfNeeded() {
        let isSeries = ["series", "tv", "show", "tvshow"].contains(type.lowercased())
        let needsEpisodes = isSeries && episodes.isEmpty && fetchedEpisodes.isEmpty
        let needsRuntime = ExternalResumePolicy.needsCatalogRuntime(
            isSeries: isSeries, hasMeta: meta != nil || fetchedRuntime != nil,
            hasEpisodes: !episodes.isEmpty || !fetchedEpisodes.isEmpty,
            resumePositionMs: resumePositionMs)
        guard needsEpisodes || needsRuntime else { return }
        // Review r3: a series from Continue Watching needs the episode runtime from this fetch too.
        runtimeFetchPending = needsRuntime
        // The `@Throws` twin: a Kotlin exception out of the plain suspend export aborts the process.
        Task { @MainActor in
            defer { runtimeFetchPending = false }
            do {
                let details = try await MetaDetailsRepository.shared.fetchChecked(
                    type: type, id: parentMetaId, cacheResult: true
                )
                // P1 (review r1): the same record carries the backdrop the picker lacked on this path.
                if background == nil {
                    let fetchedBackground: String? = details?.background
                    if let fetchedBackground, !fetchedBackground.isEmpty { peekedBackground = fetchedBackground }
                }
                if meta == nil, fetchedRuntime == nil {
                    let runtime: String? = details?.runtime
                    if let runtime, !runtime.isEmpty { fetchedRuntime = runtime }
                }
                let videos = details?.videos ?? []
                guard !videos.isEmpty else { return }
                fetchedEpisodes = videos
            } catch {
                print("[StreamPicker] episode list fetch failed: \(error)")
            }
        }
    }

    /// Stream picker A, P1 (`docs/stream-picker-addons-plan-2026-10-25.md` §2): two panes over a
    /// backdrop. Left, `StreamPickerInfoPanel` (static: logo, facts, poster, fan-out progress);
    /// right, `StreamPickerSourcePanel` (one material panel holding the header, the scrolling list
    /// and a footer). The loading cover, the toast and the alerts sit above both, unchanged.
    var body: some View {
        NavigationStack {
            ZStack {
                StreamPickerBackdrop(mode: model.backgroundMode,
                                     imageURL: backdropArt.primary, fallbackURL: backdropArt.fallback)
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        StreamPickerInfoPanel(
                            title: title,
                            logoUrl: logoUrl,
                            poster: poster,
                            season: season,
                            episode: episode,
                            episodes: episodes.isEmpty ? fetchedEpisodes : episodes,
                            meta: meta,
                            progress: model.fanOut
                        )
                        .frame(width: geo.size.width * Self.infoPaneFraction)
                        StreamPickerSourcePanel(content: model.panelBody.mode) {
                            sourceHeader
                        } panelBody: {
                            sourceList
                        } footer: {
                            EmptyView()
                        }
                        .frame(width: geo.size.width * (1 - Self.infoPaneFraction))
                    }
                }
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
                // BUG-182/183: the player's own loading look, no fade of its own (a swap to the
                // player's overlay must be invisible).
                if loadingCoverVisible { loadingCover }
            }
            // Direction C D8: one place pushes the rejected links to the view model, covering every
            // `rejectedKeys = …` site (appear, retry, gave up, failure, healthy, player dismissed).
            .onChange(of: rejectedKeys, initial: true) { _, keys in model.setRejectedKeys(keys) }
            // Direction C (C-14): card promotion, once per card appearance. A viewer who moved off
            // the placed pill is never moved (`promotesToCard` checks focus is still on it).
            .onChange(of: model.panelBody.card != nil) { was, now in
                guard !was, now,
                      StreamPickerFocusPolicy.promotesToCard(focused: focusedRow, placed: placedFocusKey,
                                                             cardAppeared: true) else { return }
                NSLog("[PickerFocus] promote pill->card focused=%@", Self.focusProbeName(focusedRow))
                placedFocusKey = StreamBestPickModel.focusKey
                DispatchQueue.main.async { focusedRow = StreamBestPickModel.focusKey }
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
                if let retry = alert.retry, let engine = alert.retryEngine {
                    Button(engine == .mpv ? LocalizedStringKey("Try with mpv") : LocalizedStringKey("Try Native Player")) {
                        manualFailureAlert = nil
                        // The link is being retried on the other engine: it is not dead yet (a retry
                        // that works but closes before 300 s must not leave it flagged for 8 h).
                        RejectedStreamLinks.keep(retry.streamKey, title: retry.videoId)
                        rejectedKeys = RejectedStreamLinks.rejected(for: videoId)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            selected = retry
                        }
                    }
                }
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
                NSLog("[PickerFocus] groups n=%d focused=%@ latch=%d chips=%d", ids.count, Self.focusProbeName(focusedRow), didPlaceListFocus ? 1 : 0, viewerChoseChip ? 1 : 0)
                guard !ids.isEmpty else {
                    // P5 device pass (Continue Watching re-open): the watcher first emitted the
                    // title's cached groups, focus was placed on row 1, then the fresh load emptied
                    // the list and focus fell to the chips with the latch used up. Re-arm the rule
                    // (as the stale-link reload does) unless the viewer chose a chip this load.
                    if !viewerChoseChip {
                        cancelInitialFocusVerify()
                        didPlaceListFocus = false
                        placedFocusKey = nil
                    }
                    return
                }
                if filterFocusRequest == .awaitingGroups, let target = firstListFocusTarget {
                    filterFocusRequest = .none
                    didPlaceListFocus = true
                    DispatchQueue.main.async { focusedRow = target }
                    return
                }
                // P5 device pass (Living Room box): focus was placed on the first group's row, then
                // the add-ons that landed next sorted above it, the LazyVStack unrealized that row
                // and focus fell to NOWHERE (`focused=nil`): every Select was dead until a D-pad
                // move. Nil focus is never the viewer's choice, so the rule runs again from here.
                // Review: nil is also what focus reads behind the player cover and the failover
                // alert; the rule must not write focus behind either.
                if focusedRow == nil, !loadingCoverVisible, selected == nil, manualFailureAlert == nil {
                    cancelInitialFocusVerify()
                    didPlaceListFocus = false
                    placedFocusKey = nil
                }

                // P3.4: move initial focus once streams (first) arrive (`placeInitialListFocus`).
                // Never while the auto-play overlay holds focus (the list is disabled under it);
                // `focusListAfterAutoPlay()` runs when it lifts.
                placeInitialListFocus()
            }
            .onAppear {
                pickerOnScreen = true
                if background == nil, peekedBackground == nil {
                    // P1: launch paths without the catalog record (Home continue-watching, deep
                    // links) get the title's backdrop from the details cache when it is there.
                    let cached: String? = MetaDetailsRepository.shared.peek(type: type, id: parentMetaId)?.background
                    peekedBackground = (cached ?? "").isEmpty ? nil : cached
                }
                // Main-thread only (UIApplication.canOpenURL); cheap enough to re-probe every
                // appearance so an Infuse install mid-session is picked up next time the picker
                // opens instead of requiring an app relaunch. First, so an auto-play start already
                // knows the viewer's default player.
                externalPlayers = ExternalPlayerPlatform.shared.availablePlayers()
                if !autoPlayEvaluated {
                    autoPlayEvaluated = true
                    // `autoPlayArmed` was decided in `init` (BUG-183).
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
            .onDisappear {
                pickerOnScreen = false
                invalidateYouTubeResolve()
                errorChipTask?.cancel()
                errorChipTask = nil
                cancelInitialFocusVerify()
                model.stop()
            }
            // P2 (review r1 Q1): `prefersDefaultFocus` is documented for default focus, not for a
            // directional move into the chip section, so Up from a row may land on the nearest
            // chip. A move from a non-chip onto a chip other than the selected one is sent on to
            // the selected chip; chip-to-chip moves (Left/Right along the row) are left alone.
            .onChange(of: focusedRow) { old, new in
                // Card promotion only while focus has stayed on the placed pill: leaving it ends the claim.
                if let old, old == placedFocusKey, new != old { placedFocusKey = nil }
                // Direction C (C-8): Down from the card lands on the nearest pill, usually the
                // trailing "Show all"; send it to the first pill.
                if let forward = StreamPickerFocusPolicy.downFromCardForward(old: old, new: new, body: model.panelBody) {
                    DispatchQueue.main.async { focusedRow = forward }
                    return
                }
                guard let new, new.hasPrefix("chip:"), let old else { return }
                if old.hasPrefix("chip:") {
                    // Review r2 (P3): Left/Right along the chips is the viewer acting on them; the
                    // initial-focus rule must not pull them to the list when the first group lands.
                    didPlaceListFocus = true
                    viewerChoseChip = true
                    cancelInitialFocusVerify()
                    return
                }
                // Review r2 (P2): only a real directional move, from a key the list still holds.
                // A row that left the hierarchy (a chip step changed the filter) makes the engine
                // fall back onto some chip; that is not a move to forward, and the chip step's own
                // focus write must win.
                // Direction C: the card, pills and "more" rows count as list keys too.
                guard StreamPickerFocusPolicy.isListKey(old, rowKeys: { key in
                    model.groups.contains(where: { $0.rowKeys.contains(key) })
                }, body: model.panelBody) else { return }
                let selectedKey = model.selectedFilter.map(SourceChipRow.key(for:)) ?? SourceChipRow.allKey
                guard new != selectedKey else { return }
                DispatchQueue.main.async { focusedRow = selectedKey }
            }
            // Review r2 P3-2: every playback start (a row, "Try Next Source", auto-play, the Up
            // Next hand-off — every `selected = …` site) supersedes a YouTube resolve in flight.
            .onChange(of: selected?.id) { _, playing in
                if playing != nil {
                    coverIsCloseHold = false
                    invalidateYouTubeResolve()
                } else {
                    // BUG-174: the player is closing. Cover the list before its slide-down reveals
                    // it when the picker closes too; drop the cover when the list has to show.
                    prepareForPlayerClose()
                }
            }
            .fullScreenCover(item: playerCoverBinding, onDismiss: handlePlayerDismissed) { ctx in
                // `.id(ctx.id)` forces a full player rebuild when autoplay swaps in the next
                // episode's context (a same-position cover would otherwise keep the old libmpv
                // controller and just ignore the new context). Failover swaps in place the same
                // way (`PlaybackContext.attempt` keeps two candidates' ids apart).
                PlayerScreen(
                    context: ctx,
                    onPlayNext: { next in selected = next },
                    onPlaybackFailed: { failure in handlePlaybackFailure(failure, context: ctx) },
                    onPlaybackHealthy: { seconds in handlePlaybackHealthy(seconds, context: ctx) },
                    onOpenTitle: onOpenTitle == nil ? nil : { postPlayPick = $0 }
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

    /// The loading cover is up (BUG-183): auto mode is armed or working (not while a failover
    /// resolves behind the open player), or `coverHold` keeps it.
    private var loadingCoverVisible: Bool {
        StreamPickerCoverPolicy.showsCover(armed: autoPlayArmed, phase: autoPlay.phase,
                                           isFailoverWalk: autoPlay.isFailoverWalk, held: coverHold)
    }

    /// BUG-182/183: the cover itself, out of `body` so the type checker stays fast.
    private var loadingCover: some View {
        let cancel: (() -> Void)? = loadingCoverCancels ? { cancelAutoPlay() } : nil
        let line: String? = PlayerLoadingOverlay.episodeLine(
            season: season, episode: episode,
            episodes: episodes.isEmpty ? fetchedEpisodes : episodes)
        return FirstPlayAutoPlayOverlay(
            title: title,
            parentMetaId: parentMetaId,
            logoUrl: logoUrl,
            episodeLine: line,
            pulseKey: videoId,
            message: loadingCoverMessage,
            onCancel: cancel,
            showsLogo: !coverIsCloseHold
        )
    }

    /// BUG-185 (Steven rc9, D6): the player cover's binding. When the viewer closes the player and
    /// the picker is going to close too (`.closePicker`), the nil is written with animations
    /// disabled, so the player cover leaves without its slide-down and `handlePlayerDismissed`
    /// closes the picker straight after: Back lands on the opener in one pass. Every other close
    /// (the alert, the failover picker, the list) keeps the animated dismiss.
    private var playerCoverBinding: Binding<PlaybackContext?> {
        Binding(
            get: { selected },
            set: { newValue in
                guard newValue == nil, selected != nil, afterPlayerOutcome == .closePicker else {
                    selected = newValue
                    return
                }
                playerCloseRequestedAt = CFAbsoluteTimeGetCurrent()
                if StreamPickerCloseAnimation.uiKitFallback {
                    StreamPickerCloseAnimation.suspendUIKitAnimations()
                }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { selected = nil }
            }
        )
    }

    /// The cover's spoken label while auto mode works; nil while it is only held.
    private var loadingCoverMessage: String? {
        StreamPickerCoverPolicy.message(armed: autoPlayArmed, phase: autoPlay.phase,
                                        isFailoverWalk: autoPlay.isFailoverWalk)
    }

    /// Menu on the cover cancels auto mode only while auto mode is working; a held cover swallows it.
    private var loadingCoverCancels: Bool { loadingCoverMessage != nil }

    /// P1: the info pane's share of the screen width (Android TV and the upstream tablet layout: 40/60).
    private static let infoPaneFraction: CGFloat = 0.4

    /// P1: the backdrop art. The title's backdrop comes from the presenter (`background`), else
    /// from the details cache (`peekedBackground`, read once on appear); `StreamPickerBackdrop.plan`
    /// picks the episode still over it and the poster under it.
    private var backdropArt: (primary: String?, fallback: String?) {
        StreamPickerBackdrop.plan(episodeStill: episodeStill, background: background ?? peekedBackground, poster: poster)
    }

    /// P1/P2: the source panel's header: the source chip row (P2), then the BUG-21 credential
    /// banner (the active debrid credential failed auth on a recent call; without it the only
    /// symptom is every resolve failing while Settings still says "Connected"; not focusable,
    /// purely advisory). P3 adds the resume pill above the chips.
    @ViewBuilder
    private var sourceHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Direction C: the card's kicker carries the resume label, so the standalone pill is
            // hidden while the card is shown (`.list`, and `.tiers` without a card, keep it).
            // Also hidden while the fan-out loads in `.tiers`, so the pill never shows and then
            // vanishes when the card lands (a body jump on every Continue Watching open).
            if let resume = currentResumeLabel,
               !(model.panelBody.mode == .tiers && (model.panelBody.card != nil || model.isLoading)) {
                StreamPickerResumePill(label: resume)
            }
            // P2: the source chips (refresh, All, one per add-on).
            SourceChipRow(
                chips: visibleChips,
                selected: model.selectedFilter,
                anyLoading: model.isLoading,
                focus: $focusedRow,
                namespace: chipFocusNamespace,
                onSelect: { addonId in
                    // The viewer chose where focus is: the initial-focus rule stands down, and a
                    // chip step's stale focus request (review r3) must not move it to the list.
                    didPlaceListFocus = true
                    viewerChoseChip = true
                    filterFocusRequest = .none
                    cancelInitialFocusVerify()
                    model.selectFilter(addonId)
                },
                onRefresh: {
                    didPlaceListFocus = true
                    viewerChoseChip = true
                    filterFocusRequest = .none
                    cancelInitialFocusVerify()
                    model.reload()
                }
            )
            credentialBanner
        }
        // Review r1 (P2 P3): same as the list — nothing behind the loading cover takes a press.
        .disabled(loadingCoverVisible)
    }

    /// P3.3: the resume pill's text (nil when there is nothing to resume); also the card's kicker suffix.
    private var currentResumeLabel: String? {
        StreamPickerResume.label(positionMs: resumePositionMs, fraction: resumeFraction,
                                 startFromBeginning: startsOver)
    }

    /// P2: the chips minus the error chips dropped after the fan-out finished.
    private var visibleChips: [SourceChip] {
        hiddenErrorChips.isEmpty ? model.sourceChips : model.sourceChips.filter { !hiddenErrorChips.contains($0.id) }
    }

    /// P2: Left/Right on the list (full-width rows give the focus engine no horizontal target, so
    /// the press reaches `onMoveCommand`) step the selected chip with wrap, throttled. Up/Down can
    /// arrive here too (hardware showed on 2026-09-30 that `onMoveCommand` also fires after the
    /// engine moved focus, see `HomeView.handleRowsMove`), and are ignored on purpose.
    private func handleListMove(_ direction: MoveCommandDirection) {
        let step: SourceChipRow.StepDirection
        switch direction {
        case .left: step = .previous
        case .right: step = .next
        default: return
        }
        // Direction C: the pills share an HStack, so the engine moves between them; a chip step here
        // would make the 2nd and 3rd pill unreachable (spec C-7). Card, compact and "more" rows are
        // full width and step the chips exactly as full rows do.
        guard StreamPickerFocusPolicy.stepsChips(focused: focusedRow) else { return }
        guard chipMoveThrottle.allows(now: CFAbsoluteTimeGetCurrent()) else { return }
        let chips = visibleChips
        guard !chips.isEmpty else { return }
        let next = SourceChipRow.step(from: model.selectedFilter, chipIds: chips.map(\.id), direction: step)
        guard next != model.selectedFilter else { return }
        filterFocusRequest = .pending
        model.selectFilter(next)
    }

    /// P2/P3: where focus lands in the list after a D-pad chip step: the body's first focus key
    /// (the first row in `.list`; in `.tiers` the card, else the first pill, else the first row).
    private var firstListFocusTarget: String? { model.panelBody.firstFocusKey }

    /// P2: once the fan-out has finished, drop the error chips with no streams after the linger;
    /// a new fan-out cancels the drop and shows every chip again.
    private func scheduleErrorChipDrop(loading: Bool) {
        errorChipTask?.cancel()
        errorChipTask = nil
        if loading {
            if !hiddenErrorChips.isEmpty { hiddenErrorChips = [] }
            return
        }
        guard model.sourceChips.contains(where: { $0.hasError && $0.count == 0 }) else { return }
        errorChipTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(SourceChipRow.errorChipLinger))
            guard !Task.isCancelled else { return }
            let dropped = SourceChipRow.chipsToDrop(model.sourceChips)
            guard !dropped.isEmpty else { return }
            // A dropped chip that was selected: its group is gone from the list anyway, show All.
            if let selected = model.selectedFilter, dropped.contains(selected) {
                model.selectFilter(nil)
            }
            // Focus on any dropped chip (review r2): move it to the selected chip (or "All")
            // instead of wherever the engine lands when the chip vanishes.
            if let focused = focusedRow, dropped.contains(where: { SourceChipRow.key(for: $0) == focused }) {
                let selectedKey = model.selectedFilter.map(SourceChipRow.key(for:)) ?? SourceChipRow.allKey
                focusedRow = dropped.contains(where: { SourceChipRow.key(for: $0) == selectedKey }) ? SourceChipRow.allKey : selectedKey
            }
            hiddenErrorChips = dropped
        }
    }

    /// BUG-21: the credential banner (see `sourceHeader`).
    @ViewBuilder
    private var credentialBanner: some View {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// P1/P3: the scrolling body of the source panel: the sections (`model.sections`: quality tiers or
    /// add-on groups, each with an optional label) over one row per stream, the empty-state reason and
    /// the dev test stream. Review r1 P2-3 (W3-16 F2): the reader lets a row that grows after its
    /// dwell (the release-name file line, `StreamRowDwell`) re-reveal itself; UIKit does not scroll
    /// for a focused view's later resize. See `streamRowView`.
    private var sourceList: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                // Lazy so rows build only as they scroll into view (BUG-5: a non-lazy VStack built
                // every row of every addon up front); there are no collapsed groups any more.
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    // P3 (review r1): a fixed anchor for "scroll to the top" (`scrollTo` needs an
                    // id a lazy stack can resolve; the first row may not be realized yet).
                    // Negative top padding cancels the stack's `sm` gap after a zero-height child.
                    Color.clear.frame(height: 0).id(Self.listTopKey).padding(.top, -Theme.Spacing.sm)
                    // W3-16 (F1/F4): the rows are prebuilt values (`StreamsViewModel` built them, keys
                    // included); the picker only adds what it alone knows. Computed once per list, not per row.
                    let players = externalPlayers.map { StreamRowPlayer(id: $0.id, name: $0.name) }
                    let defaultPlayerId = activeDefaultExternalPlayer?.id
                    // Polish D4: the list iterates the view model's sections (quality tiers, or the
                    // add-on groups in Add-on mode). A label is a non-focusable header; in the All view
                    // add-on labels carry the spinner, tier labels (also under a chip) carry a count.
                    if model.panelBody.mode == .tiers {
                        tiersBody(players: players, defaultPlayerId: defaultPlayerId)
                    } else {
                    ForEach(model.sections) { section in
                        if section.showsLabel {
                            StreamSectionLabel(name: section.title, isLoading: section.isLoading,
                                               count: section.count)
                        }
                        ForEach(section.rows) { row in
                            streamRowView(row, players: players, defaultPlayerId: defaultPlayerId,
                                          scrollProxy: scrollProxy)
                        }
                    }
                    }

                    if let reason = model.emptyReason {
                        VStack(spacing: Theme.Spacing.xs) {
                            // Full text-primary weight: the debrid/filtered case is actionable, not a dead end.
                            Text(reason)
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            if let hint = model.emptyReasonHint {
                                Text(hint)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.xl)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("stream_picker_empty_reason")
                    }

                    // Dev/diagnostics affordance — only when there is nothing real to play, so it
                    // can never steal initial focus from the stream list (the old always-visible
                    // button was the only focusable view while loading → focus started at the
                    // bottom of the screen).
                    // P2: never under a source chip — a filtered-empty list is not "nothing to play".
                    if model.groups.isEmpty && !model.isLoading && model.selectedFilter == nil {
                        VStack(spacing: Theme.Spacing.sm) {
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
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.lg)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Under the loading cover nothing in the list may take focus or a Select.
                .disabled(loadingCoverVisible)
            }
            // Review r1 (P2): the inset lives inside the scroll content, so the focused row's lift
            // and shadow are not clipped at the panel edge (the ScrollView clips its content).
            // Review r2: `lg` below too, for the last row's shadow tail (radius 16, y 8).
            .contentMargins(.horizontal, Theme.Spacing.lg, for: .scrollContent)
            .contentMargins(.top, Theme.Spacing.md, for: .scrollContent)
            .contentMargins(.bottom, Theme.Spacing.lg, for: .scrollContent)
            // P2: Left/Right on a row switch the source chip (Android TV `StreamScreen`).
            .onMoveCommand { handleListMove($0) }
            .onChange(of: model.selectedFilter) { _, _ in
                // After a D-pad chip step the list shows the new source from the top. Focus is set
                // on the next runloop (review r1 P2): the LazyVStack may not have realized the
                // target yet in this tick, and a dropped focus write leaves focus on the old row.
                guard filterFocusRequest == .pending else { return }
                // Review r2 (P3): no listable rows yet (the add-on is still loading): hand the
                // request to the groups onChange, which completes it when its streams land.
                guard let target = firstListFocusTarget else {
                    filterFocusRequest = .awaitingGroups
                    return
                }
                filterFocusRequest = .none
                // Review r2 / P3 r1: the target is always the first row, so scroll to the fixed
                // top anchor first (always realized); the row id then resolves.
                scrollProxy.scrollTo(Self.listTopKey, anchor: .top)
                scrollProxy.scrollTo(target, anchor: .top)
                DispatchQueue.main.async { focusedRow = target }
            }
            // Direction C: the focused card / pill / row / "more" row left the rebuilt body (a row now
            // hidden in a collapsed tier, a tier expanded, the card gone). `repairTarget` names the
            // key that stands in for it. A backstop: Show all and expand place focus themselves.
            // Written async, and only while focus is still on the vanished key, nowhere, or on a chip
            // the engine fell back to; a viewer's own move in the meantime wins. `.list` has no focus
            // keys, so this is inert there.
            .onChange(of: model.panelBody) { old, new in
                let vanished = focusedRow
                guard let target = StreamPickerFocusPolicy.repairTarget(focused: vanished, old: old, new: new)
                else { return }
                DispatchQueue.main.async {
                    guard focusedRow == vanished || focusedRow == nil || focusedRow?.hasPrefix("chip:") == true
                    else { return }
                    focusedRow = target
                }
            }
            .onChange(of: model.isLoading, initial: true) { _, loading in
                scheduleErrorChipDrop(loading: loading)
                // Review r3: a stepped-to add-on that ends with nothing listable retires the request.
                if !loading, model.groups.isEmpty { filterFocusRequest = .none }
                // P3.4: a fan-out that ends with no rows never changes the group ids, so the empty
                // outcome places focus from here (on the "All" chip).
                if !loading { placeInitialListFocus() }
            }
        }
    }

    // MARK: - Rows

    /// W3-16 (BUG-207, F1): one stream row. The row is a `StreamRowView` behind `.equatable()` over
    /// a plain `StreamRowModel`, so it is re-evaluated only when its own model changes — NOT on every
    /// focus move: the old `streamRow` method read the parent's `@FocusState` in every built row
    /// (for BUG-16's line limit), so each move re-ran every row's body. The expansion now reads the
    /// style's `\.settingsRowIsFocused` inside the row. `.focused($focusedRow, equals: key)` stays
    /// HERE, on the call site: initial focus and restore (`placeInitialListFocus`, the chip-step
    /// request, `focusListAfterAutoPlay`) go through the parent's binding and the stable row keys.
    ///
    /// The closures are not part of the row's identity, so they carry the KEY and look the stream up
    /// when pressed (`liveStream(forRowKey:)`): a debrid preparation that swaps a resolved URL into
    /// the same row (`replacePreparedStream`) must reach the press, whether or not the row redrew.
    ///
    /// Review r1 P2-3: the dwell (`StreamRowDwell.dwell`) grows the focused row AFTER the
    /// engine scrolled it into view at its resting height, so on the bottom-most visible row (and
    /// always on the last one) the full name could sit below the fold, and Down, the only way on,
    /// collapses it. `onExpanded` runs once the grown row has laid out and asks the list for a
    /// minimal reveal (`anchor: nil`): it scrolls only when the row overflows, by the overflow. No
    /// animation, like the expansion itself.
    private func streamRowView(_ row: StreamRowModel, players: [StreamRowPlayer],
                               defaultPlayerId: String?, scrollProxy: ScrollViewProxy) -> some View {
        let key = row.key
        let model = row.applying(
            isResolving: resolvingKey == key,
            failedRecently: !rejectedKeys.isEmpty && rejectedKeys.contains(row.playbackKey),
            players: players,
            defaultPlayerId: defaultPlayerId
        )
        return StreamRowView(
            model: model,
            onSelect: { selectRow(key) },
            onBuiltIn: { playRowInBuiltInPlayer(key) },
            onExternal: { playerId in playRowExternally(key, playerId: playerId) },
            onExpanded: { scrollProxy.scrollTo(key, anchor: nil) }
        )
        .equatable()
        .focused($focusedRow, equals: key)
        // The `scrollTo` target (the same value as the `ForEach` identity, so no identity change).
        .id(key)
    }

    /// Direction C: the `.tiers` body, one flat list in the order the model built it (card,
    /// alternatives, then per tier a header, its visible rows and a "more" row). Same call-site
    /// contract as `streamRowView` (BUG-207 / W3-16): every leaf is an `Equatable` value built in
    /// `apply`, `.equatable()` + `.focused($focusedRow, equals:)` + `.id(key)` live HERE, and nothing
    /// reads the picker's focus state. No animation, and no height change on a focus move.
    ///
    /// The card's content (not its key) may change while the fan-out answers; `bestPickUpgradePolicy`
    /// (`.perAnswer`) stays the default. If the device pass shows focus dropping when the card's
    /// content swaps, `StreamsViewModel.bestPickUpgradePolicy = .onCompletion` is the named
    /// fallback (a one-line flip, spec 4.4); it is NOT flipped here.
    @ViewBuilder
    private func tiersBody(players: [StreamRowPlayer], defaultPlayerId: String?) -> some View {
        ForEach(model.panelBody.items) { item in
            switch item {
            case .card(let card):
                StreamBestPickCard(model: card, resumeLabel: currentResumeLabel,
                                   isResolving: resolvingKey == card.rowKey,
                                   onSelect: { selectRow(card.rowKey) })
                    .equatable()
                    .focused($focusedRow, equals: StreamBestPickModel.focusKey)
                    .id(StreamBestPickModel.focusKey)
            case .alternatives(let alternatives):
                StreamAlternativesRow(alternatives: alternatives, resolvingKey: resolvingKey, focus: $focusedRow,
                                      onSelect: { handleAlternative($0) })
                    .id("alternatives")
            case .header(let section):
                StreamSectionLabel(name: section.title, isLoading: section.isLoading, count: section.count)
            case .row(let row):
                compactRowView(row, players: players, defaultPlayerId: defaultPlayerId)
            case .more(let section):
                // The closure is not part of the row's identity, so it carries the section id and
                // reads the live section when pressed (a republish may have moved `firstHiddenKey`).
                let sectionId = section.id
                StreamTierMoreRow(sectionTitle: section.title, hiddenCount: section.hiddenCount,
                                  onSelect: { expandTier(sectionId) })
                    .equatable()
                    .focused($focusedRow, equals: section.moreFocusKey)
                    .id(section.moreFocusKey)
            }
        }
    }

    /// A compact row in the `.tiers` body: `streamRowView`'s twin (no dwell, so no `onExpanded` and
    /// no scroll proxy; compact rows never change height on focus).
    private func compactRowView(_ row: StreamRowModel, players: [StreamRowPlayer],
                                defaultPlayerId: String?) -> some View {
        let key = row.key
        let model = row.applying(
            isResolving: resolvingKey == key,
            failedRecently: !rejectedKeys.isEmpty && rejectedKeys.contains(row.playbackKey),
            players: players,
            defaultPlayerId: defaultPlayerId
        )
        return StreamCompactRowView(
            model: model,
            onSelect: { selectRow(key) },
            onBuiltIn: { playRowInBuiltInPlayer(key) },
            onExternal: { playerId in playRowExternally(key, playerId: playerId) }
        )
        .equatable()
        .focused($focusedRow, equals: key)
        // Own id namespace: after Show all the same row key is drawn by `streamRowView` in this same
        // LazyVStack, and a shared id let the lazy container reuse the stale compact view across the
        // mode flip (the list kept the compact rows). Focus keys stay the plain row key; nothing
        // scrolls to a compact row by id.
        .id("compact:" + key)
    }

    /// Select on a pill: "Show all" opens the A list; the other pills play their stream.
    private func handleAlternative(_ alternative: StreamAlternativeModel) {
        if alternative.kind == .showAll {
            showAllSources()
        } else if let key = alternative.rowKey {
            selectRow(key)
        }
    }

    /// Direction C D4 (spec 7.4): Show all. The viewer chose where focus goes, so the chip-step and
    /// initial-focus rules stand down; the body becomes the A list and focus goes to its first row.
    /// No `scrollTo` (tvOS 27.2 ignores id-based programmatic scrolling; the pill is at the top and
    /// the focus move scrolls), no animation.
    private func showAllSources() {
        filterFocusRequest = .none
        cancelInitialFocusVerify()
        didPlaceListFocus = true
        model.showAll()
        requestListFocus(StreamPickerFocusPolicy.afterShowAll(firstRowKey: model.firstRowKey), pinned: false)
    }

    /// Direction C D5 (spec 7.4): Select on a "more" row. The target is read from the CURRENT
    /// section BEFORE `expandSection` (afterwards the section has no hidden row); focus lands on the
    /// row that took the "more" row's place.
    private func expandTier(_ sectionId: String) {
        guard let section = model.panelBody.sections.first(where: { $0.id == sectionId }) else { return }
        let target = StreamPickerFocusPolicy.afterExpand(section)
        filterFocusRequest = .none
        cancelInitialFocusVerify()
        didPlaceListFocus = true
        model.expandSection(sectionId)
        requestListFocus(target)
    }

    /// A focus request from a press (Show all, tier expand): written on the next runloop and
    /// verified like the initial placement, so a write the lazy list dropped (the row was not
    /// realized yet) is re-issued. Pinned: the verify pass keeps THIS target.
    private func requestListFocus(_ target: String?, pinned: Bool = true) {
        guard let target else { return }
        initialFocusTarget = target
        initialFocusAttempts = 0
        // Show all does not pin: its target is the body's own first focus key, and the unpinned
        // verify keeps the P5 retarget protection.
        initialFocusPinned = pinned
        DispatchQueue.main.async { focusedRow = target }
        scheduleInitialFocusVerify()
    }

    /// The stream currently listed under `key` (nil if the list changed under the press).
    private func liveStream(forRowKey key: String) -> StreamItem? {
        for group in model.groups {
            if let index = group.rowKeys.firstIndex(of: key), index < group.streams.count {
                return group.streams[index]
            }
        }
        return nil
    }

    /// Select on a row: the viewer's default player (`play`).
    private func selectRow(_ key: String) {
        guard let stream = liveStream(forRowKey: key) else { return }
        manualFailoverList = model.groups.flatMap(\.streams)
        play(stream, rowKey: key)
    }

    /// Long-press → "Play in NuvioTV Player" (the escape hatch back from an external default).
    private func playRowInBuiltInPlayer(_ key: String) {
        guard let stream = liveStream(forRowKey: key) else { return }
        manualFailoverList = model.groups.flatMap(\.streams)
        internalPlay(stream, rowKey: key)
    }

    /// Long-press → another installed player.
    private func playRowExternally(_ key: String, playerId: String) {
        guard let stream = liveStream(forRowKey: key) else { return }
        externalPlay(stream, rowKey: key, playerId: playerId)
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
            selected = context(url: url, stream: stream, listedStream: stream, streamKey: streamKey,
                               launchSource: .manual, attempt: attempt)
            return
        }

        // Batch D U2 (upstream 94976222): the add-on gave only a YouTube video id — resolve it on
        // the device to one playable URL (HLS master, else progressive), then play that exactly
        // like a direct link. The listed stream stays the identity (`streamKey`, `listedStream`):
        // the resolved link expires within hours.
        if Self.isYouTubeResolved(stream) {
            guard resolvingKey == nil else { return }
            let token = beginYouTubeResolve(rowKey: rowKey)
            youTubeResolveTask = resolveYouTube(stream) { resolved in
                // Review r1 / r2 P3-2: only the request the token belongs to may act; a playback
                // the viewer started since (another row, "Try Next Source", an auto-play pick,
                // even one already dismissed again) dropped the token, and so did leaving the
                // picker (a Menu press during the resolve).
                guard youTubeResolveToken == token else {
                    print("[StreamPicker] YouTube resolve landed after another playback started — dropped")
                    return
                }
                finishYouTubeResolve()
                guard selected == nil, pickerOnScreen else { return }
                let resolvedUrl: String? = resolved?.playableDirectUrl
                guard let resolved, let resolvedUrl, !resolvedUrl.isEmpty, let url = URL(string: resolvedUrl) else {
                    showToast(Self.youTubeResolveFailedMessage)
                    return
                }
                NextEpisodeEngine.consecutiveAutoPlays = 0
                selected = context(url: url, stream: resolved, listedStream: stream, streamKey: streamKey,
                                   launchSource: .manual, attempt: attempt)
            }
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
                    selected = context(url: url, stream: success.stream, listedStream: stream, streamKey: streamKey,
                                       launchSource: .manual, attempt: attempt)
                    return
                }
            }
            showToast(Self.resolveFailureMessage(result))
            // The toast promises a refresh — deliver it: stale cached links mean the whole
            // result set is old, so re-fetch (focus is preserved; see onChange guard).
            if result is DirectDebridPlayableResult.Stale {
                // P2: the list empties and focus falls to the chips; let the rule place it again.
                cancelInitialFocusVerify()
                didPlaceListFocus = false
                placedFocusKey = nil
                viewerChoseChip = false
                model.reload(forceManual: !autoPlayArmed)
            }
        }
    }

    // MARK: - YouTube resolve (batch D U2)

    /// True when the add-on gave this stream only a YouTube video id (shared `youTubeIdToResolve`).
    /// nil → false, so callers can pass an optional listed stream. Pure and `nonisolated`: the
    /// Up Next engine's stream predicates and `PlaybackFailoverPolicy` call it off the main actor.
    nonisolated static func isYouTubeResolved(_ stream: StreamItem?) -> Bool {
        let youTubeId: String? = stream?.youTubeIdToResolve
        return !(youTubeId ?? "").isEmpty
    }

    static var youTubeResolveFailedMessage: String { String(localized: "Could not load this YouTube video.") }

    /// Resolves a ytId-only stream to a copy carrying one playable URL through the shared
    /// `YouTubeStreamResolver` (the trailer extractor; HLS master playlist, else progressive). The
    /// shared function maps every failure to nil and rethrows only cancellation (review r1 F3),
    /// which `try?` also turns into nil — so a nil is "could not resolve" unless this Task itself
    /// was cancelled, in which case nobody is told anything. Runs on the main actor throughout
    /// (the async export, not the completion-handler twin, so no `@Sendable` hop is needed).
    @discardableResult
    private func resolveYouTube(_ stream: StreamItem, completion: @escaping @MainActor (StreamItem?) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            let resolved: StreamItem? = try? await YouTubeStreamResolver.shared.resolve(stream: stream)
            guard !Task.isCancelled else { return }
            completion(resolved)
        }
    }

    /// Starts a YouTube resolve for `rowKey`: the row spinner (`resolvingKey`, which also keeps
    /// resolves one at a time) plus a fresh request token (review r2 P3-2). Returns the token the
    /// completion must still hold to act.
    private func beginYouTubeResolve(rowKey: String) -> UUID {
        let token = UUID()
        resolvingKey = rowKey
        youTubeResolveToken = token
        return token
    }

    /// The owning completion is done (either way): clears the spinner and the token.
    private func finishYouTubeResolve() {
        resolvingKey = nil
        youTubeResolveToken = nil
        youTubeResolveTask = nil
    }

    /// Supersedes the YouTube resolve in flight, if any: its completion will find a stale token,
    /// its Task is cancelled (review r2 P3-3), and the spinner it owned is cleared so the
    /// one-at-a-time guard reopens. A debrid resolve's spinner (no token) is left alone.
    private func invalidateYouTubeResolve() {
        guard youTubeResolveToken != nil else { return }
        youTubeResolveToken = nil
        youTubeResolveTask?.cancel()
        youTubeResolveTask = nil
        resolvingKey = nil
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
                           rowKey: rowKey, fallbackToInternal: fallbackToInternal)
            return
        }

        // Batch D U2: a ytId-only stream resolves on the device first (see `internalPlay`), then
        // the resolved link is handed off like a direct one.
        if Self.isYouTubeResolved(stream) {
            guard resolvingKey == nil else { return }
            let token = beginYouTubeResolve(rowKey: rowKey)
            youTubeResolveTask = resolveYouTube(stream) { resolved in
                // Review r1 / r2 P3-2: same token guard as `internalPlay` — a Menu press during
                // the resolve must not launch an external player from a view that is gone.
                guard youTubeResolveToken == token else {
                    print("[StreamPicker] YouTube resolve landed after the picker moved on — dropped")
                    return
                }
                finishYouTubeResolve()
                guard selected == nil, pickerOnScreen else { return }
                let resolvedUrl: String? = resolved?.playableDirectUrl
                guard let resolved, let resolvedUrl, !resolvedUrl.isEmpty else {
                    showToast(Self.youTubeResolveFailedMessage)
                    return
                }
                openExternally(urlString: resolvedUrl, stream: resolved, listed: stream, playerId: playerId,
                               rowKey: rowKey, fallbackToInternal: fallbackToInternal)
            }
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
                        rowKey: rowKey,
                        fallbackToInternal: fallbackToInternal
                    )
                    return
                }
            }
            showToast(Self.resolveFailureMessage(result))
            if result is DirectDebridPlayableResult.Stale {
                // P2: the list empties and focus falls to the chips; let the rule place it again.
                cancelInitialFocusVerify()
                didPlaceListFocus = false
                placedFocusKey = nil
                viewerChoseChip = false
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
    /// Orivio batch item 5: a handoff to a player that reports back (`returnReportingPlayerIds`:
    /// Infuse, SenPlayer since FEAT-56, Native Player since FEAT-78) first prepares a shared external-playback session and
    /// passes the player its x-success / x-error callback URLs on this install's own URL scheme, so
    /// the position it reports back is recorded (`ExternalPlaybackReturn`). A handoff that does not
    /// open drops that session again. `listed` is the stream as the list shows it (pre-resolve).
    ///
    /// `autoAttempt` (1-based) marks the first-play auto start handing its pick to the viewer's
    /// external default: its built-in fallback is then an auto start too (`.autoPlay`, the walk
    /// continues on a failure).
    ///
    /// D5 (Steven rc7): the request also carries the add-on subtitles this picker fetched
    /// (`SubtitleRepository`, prefetched since the picker opened), the stream's own first, then the
    /// viewer's preferred subtitle language first (`ExternalSubtitleHandOff`). When that fetch has
    /// not finished, the hand-off waits for it at most `ExternalSubtitleHandOff.waitSeconds`
    /// (row spinner on, one hand-off at a time) and then sends what has arrived.
    ///
    /// BUG-174 (Steven rc7): a hand-off that opened closes the picker, manual picks included (the
    /// auto path always did), so coming back from the external player lands on the page the viewer
    /// started from.
    private func openExternally(urlString: String, stream: StreamItem, listed: StreamItem, playerId: String,
                                rowKey: String? = nil, fallbackToInternal: Bool = false, autoAttempt: Int? = nil) {
        // Review r1 (P2): one hand-off at a time. The subtitle wait makes this asynchronous, so a
        // second Select during it would otherwise open the external player twice.
        guard !externalHandOffInFlight else { return }
        externalHandOffInFlight = true
        let spinnerKey = rowKey ?? Self.handOffRowKey
        resolvingKey = spinnerKey
        let type = type
        let videoId = videoId
        Task { @MainActor in
            let addonSubtitles = await ExternalSubtitleHandOff.liveAddonSubtitles(type: type, videoId: videoId)
            // Review r2: a percentage-only movie row needs the catalog runtime still being fetched.
            if runtimeFetchPending {
                let arrived = await ExternalResumePolicy.awaitRuntime(isPending: { runtimeFetchPending })
                if !arrived { print("[StreamPicker] external resume: runtime fetch still pending after the wait") }
            }
            externalHandOffInFlight = false
            if resolvingKey == spinnerKey { resolvingKey = nil }
            // The viewer left the picker, or something else started playing, while it waited.
            guard pickerOnScreen, selected == nil else {
                print("[StreamPicker] external hand-off dropped: the picker moved on while subtitles loaded")
                return
            }
            openExternallyNow(urlString: urlString, stream: stream, listed: listed, playerId: playerId,
                              addonSubtitles: addonSubtitles, fallbackToInternal: fallbackToInternal,
                              autoAttempt: autoAttempt)
        }
    }

    /// `openExternally` once the add-on subtitles are in hand.
    private func openExternallyNow(urlString: String, stream: StreamItem, listed: StreamItem, playerId: String,
                                   addonSubtitles: [AddonSubtitle], fallbackToInternal: Bool, autoAttempt: Int?) {
        let progress = WatchProgressRepository.shared.progressForVideo(
            videoId: videoId,
            parentMetaId: parentMetaId,
            seasonNumber: season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: episode.map { KotlinInt(int: Int32($0)) }
        )
        // Issue #19: percentage-only rows (Trakt/Simkl) are scaled by the catalog runtime here
        // (`ExternalResumePolicy`); "Start Over" and completed entries still send 0.
        let resume = ExternalResumePolicy.resume(
            startsOver: startsOver, entry: progress,
            fallbackDurationMs: externalDurationMs(progress: progress)
        )
        let resumeMs = resume.positionMs
        print("[StreamPicker] external resume player=\(playerId) source=\(resume.source.rawValue) positionMs=\(resumeMs)")
        var launchSessionId: String?
        var callbackSuccessUrl: String?
        var callbackErrorUrl: String?
        if Self.returnReportingPlayerIds.contains(playerId), let sourceURL = URL(string: urlString) {
            let session = ExternalPlaybackReturn.shared.prepare(
                playerId: playerId,
                sourceUrl: urlString,
                // `listedStream: listed` so a ytId-only stream's session stores no expiring link.
                playbackSession: PlaybackProgressRecorder.playbackSession(
                    for: context(url: sourceURL, stream: stream, listedStream: listed)),
                durationMs: externalDurationMs(progress: progress).map { KotlinLong(value: $0) }
            )
            let callbacks = ExternalPlaybackCallbacks.shared.build(
                scheme: AppCallbackScheme.value, playerId: playerId, sessionId: session.id
            )
            launchSessionId = session.id
            callbackSuccessUrl = callbacks.first.map { $0 as String }
            callbackErrorUrl = callbacks.second.map { $0 as String }
        }
        let subtitles = ExternalSubtitleHandOff.requestSubtitles(stream: stream, addonSubtitles: addonSubtitles)
        print("[StreamPicker] external hand-off player=\(playerId) subtitles=\(subtitles.count) (stream=\(stream.externalSubtitles.count) addon=\(addonSubtitles.count))")
        let request = ExternalPlayerPlaybackRequest(
            sourceUrl: urlString,
            title: title,
            streamTitle: nil,
            sourceHeaders: [:],
            resumePositionMs: resumeMs,
            // Each player's builder keeps its own rules (VLC/VidHub take the first; Native
            // Player keeps http(s) SRT only), so the order here is what decides.
            subtitles: subtitles,
            season: season.map { KotlinInt(int: Int32($0)) },
            episode: episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: nil,
            skipSegmentsJson: nil,
            // Infuse and SenPlayer only (nil for every other player): where the player reports the
            // stop position.
            callbackSuccessUrl: callbackSuccessUrl,
            callbackErrorUrl: callbackErrorUrl
        )
        // BUG-185 (Steven rc9, D6): build the URL, close the picker FIRST, then leave the app, so
        // coming back from the external player lands on the opener with no loading cover to flash
        // (the old order opened the player while the picker, under its cover, was still up).
        let intent = ExternalPlayerPlatform.shared.buildIntent(request: request, playerId: playerId)
        if let success = intent as? ExternalPlayerIntentResultSuccess, let url = success.intent as? URL {
            if UserDefaults.standard.bool(forKey: "debug.extPlayerProbe") {
                // Knob-gated, console-only (the shared `open` rule): the URL embeds debrid tokens.
                NSLog("%@", "[ExtPlayerProbe] open player=\(playerId) url=\(url.absoluteString)")
            }
            // BUG-174: handed off — the picker leaves (manual picks too); Back from the external
            // player returns to the page that opened it.
            closePicker()
            let sessionId = launchSessionId
            // Not capturing the view: the picker is dismissing by the time this runs.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                UIApplication.shared.open(url, options: [:]) { opened in
                    // Upstream 99ced26a (as `ExternalPlayerPlatform.apple.kt`'s `open`): a launch
                    // that carried a return callback but never opened drops its pending session
                    // (`cancelLaunch(sessionId:)` only drops it if it is still this one).
                    if !opened, let sessionId {
                        print("[StreamPicker] external player did not open; dropping its return session")
                        ExternalPlaybackReturn.shared.cancelLaunch(sessionId: sessionId)
                    }
                }
            }
            return
        }
        if let launchSessionId {
            // Nothing was handed off: drop the pending return session (only if it is still this one).
            ExternalPlaybackReturn.shared.cancelLaunch(sessionId: launchSessionId)
        }
        if fallbackToInternal, let url = URL(string: urlString) {
            showToast(String(localized: "Couldn\u{2019}t open the external player \u{2014} playing in NuvioTV."))
            NextEpisodeEngine.consecutiveAutoPlays = 0
            if let autoAttempt {
                autoPlayLog("[AutoPlay] external player \(playerId) did not open — attempt #\(autoAttempt) plays in NuvioTV")
                selected = context(url: url, stream: stream, listedStream: listed, streamKey: listed.playbackStreamKey,
                                   launchSource: .autoPlay, attempt: autoAttempt - 1)
            } else {
                selected = context(url: url, stream: stream, listedStream: listed, streamKey: listed.playbackStreamKey,
                                   launchSource: .manual)
            }
        } else {
            // An auto pick's cover was held for the hand-off: the list shows with the toast.
            coverHold = false
            showToast(String(localized: "Couldn\u{2019}t open the external player."))
        }
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
        if let minutes = PlaybackMeta.runtimeMinutes(meta?.runtime ?? fetchedRuntime), minutes > 0 {
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
            // BUG-183: the cover stays up while the player is presented (`.done` alone would hide
            // it and show the list for a beat before the player's cover is up).
            coverHold = true
            autoPlayArmed = false
            NextEpisodeEngine.consecutiveAutoPlays = 0
            if case let .external(playerId) = FirstPlayAutoPlayController.Policy.startDestination(
                isFailover: isFailover, defaultExternalPlayerId: activeDefaultExternalPlayer?.id
            ) {
                // The viewer's default player is external: the auto pick goes there, as Select on a
                // row would. Handed off, the picker leaves too (`openExternally`, BUG-174); a
                // handoff that does not open plays in NuvioTV as this same auto start.
                autoPlayLog("[AutoPlay] attempt #\(attempt) to external player \(playerId) key=\(candidate.streamKey)")
                openExternally(urlString: url.absoluteString, stream: resolved, listed: candidate.stream,
                               playerId: playerId, fallbackToInternal: true, autoAttempt: attempt)
                return
            }
            // Set straight from the event: during a failover this swaps the open player in place.
            selected = context(url: url, stream: resolved, listedStream: candidate.stream,
                               streamKey: candidate.streamKey, launchSource: .autoPlay, attempt: attempt - 1)
        case let .gaveUp(reason, duringFailover):
            autoPlayArmed = false
            rejectedKeys = RejectedStreamLinks.rejected(for: videoId)
            if duringFailover {
                // The viewer already left the player: nothing to explain. Review r1 (P3): the cover
                // stays, the picker is closing behind the player.
                guard selected != nil else {
                    autoPlayLog("[AutoPlay] walk ended (\(reason)) after the player had closed — nothing shown, rejected=\(rejectedKeys.count)")
                    return
                }
                // BUG-174: this close shows the list (with the toast below), not the opener.
                keepListAfterPlayer = true
                selected = nil
            }
            coverHold = false
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
        coverHold = false
        focusListAfterAutoPlay()
    }

    /// Initial focus for the list once the overlay lifts (same target as the first-streams rule: the first row).
    private func focusListAfterAutoPlay() {
        DispatchQueue.main.async { placeInitialListFocus() }
    }

    /// P3.4: the list's initial-focus rule. The first row once the list has rows; once the fan-out
    /// has finished with none, the "All" chip, so an empty outcome still leaves a control inside
    /// the panel focused (the empty-pushed-view eject class: Menu with focus stranded on the tab
    /// bar exits the app). Once per load, and never off a row the viewer moved to
    /// (`listFocusIsPlaceable`). Nothing while the loading cover is up (the panel is disabled).
    private func placeInitialListFocus() {
        guard !loadingCoverVisible, listFocusIsPlaceable else { return }
        // Direction C: the choice lives in `StreamPickerFocusPolicy.initialTarget` (the body's first
        // focus key: the card, else a pill, else the first row; the first row in `.list`), with the
        // chip as the empty-outcome fallback. Auto-play cancel and a walk that gave up land here too.
        var outcomeChipKey: String?
        if !model.isLoading, model.fanOut.hasOutcome {
            // Review r1: the selected chip when there is one (a stale-link reload keeps it), "All"
            // otherwise or when that chip was dropped as an error chip.
            let selectedKey = model.selectedFilter.map(SourceChipRow.key(for:)) ?? SourceChipRow.allKey
            let selectedDropped = model.selectedFilter.map { hiddenErrorChips.contains($0) } ?? false
            outcomeChipKey = selectedDropped ? SourceChipRow.allKey : selectedKey
        }
        guard let target = StreamPickerFocusPolicy.initialTarget(body: model.panelBody,
                                                                 outcomeChipKey: outcomeChipKey)
        else { return }
        NSLog("[PickerFocus] place target=%@ focused=%@", Self.focusProbeName(target), Self.focusProbeName(focusedRow))
        didPlaceListFocus = true
        placedFocusKey = target
        initialFocusTarget = target
        initialFocusAttempts = 0
        initialFocusPinned = false
        DispatchQueue.main.async { focusedRow = target }
        scheduleInitialFocusVerify()
    }

    /// P4 device pass: 350 ms after a placement, check that focus arrived. A dropped write (the row
    /// was not realized yet) or the engine's own default focus (the chip row) leaves it nil or on a
    /// chip: write the target again, up to three times. Focus anywhere else means the viewer moved
    /// it, and the request ends. A target that left the list (the filter changed) is replaced by the
    /// current first row.
    private func scheduleInitialFocusVerify() {
        initialFocusVerifyTask?.cancel()
        initialFocusVerifyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let wanted = initialFocusTarget else { return }
            NSLog("[PickerFocus] verify attempt=%d wanted=%@ focused=%@", initialFocusAttempts,
                  Self.focusProbeName(wanted), Self.focusProbeName(focusedRow))
            if focusedRow == wanted { initialFocusTarget = nil; return }
            let unplaced = focusedRow == nil || focusedRow?.hasPrefix("chip:") == true
            guard unplaced, initialFocusAttempts < 3 else { initialFocusTarget = nil; return }
            // P5 device pass (Continue Watching re-open, Living Room box): the first group to
            // answer placed its row, then the add-ons that landed next sorted ABOVE it, so the
            // wanted row sat off-screen, unrealized by the LazyVStack, and four writes were
            // dropped while focus stayed on the refresh chip. Re-target to the CURRENT first row
            // (realized at the top) whenever the list has one; a chip target stays as asked.
            let target: String
            // A pin holds only while its key is still a live target (the viewer may have stepped the
            // chips or collapsed the body since); otherwise fall back to the body's first focus key.
            let pinHolds = initialFocusPinned
                && (model.panelBody.focusKeys.contains(wanted)
                    || (model.panelBody.mode == .list && model.groups.contains { $0.rowKeys.contains(wanted) }))
            if wanted.hasPrefix("chip:") || pinHolds {
                target = wanted
            } else if let first = model.panelBody.firstFocusKey {
                target = first
            } else {
                initialFocusTarget = nil
                return
            }
            initialFocusAttempts += 1
            initialFocusTarget = target
            focusedRow = target
            scheduleInitialFocusVerify()
        }
    }

    /// Focus keys for the `[PickerFocus]` probes: a row key carries the add-on id, which carries
    /// the manifest URL (a config leak into console logs, the rig-log staging class), so a row is
    /// logged by its position only.
    private static func focusProbeName(_ key: String?) -> String {
        guard let key else { return "nil" }
        // Review: an add-on chip's key is "chip:<add-on id>", and that id carries the manifest URL.
        if key == SourceChipRow.allKey || key == SourceChipRow.refreshKey || key == testRowKey { return key }
        // Direction C: the card and the pills are fixed words; a "more" key carries the section id,
        // which in Add-on mode carries the manifest URL, so it logs as "more".
        if key == StreamBestPickModel.focusKey || key.hasPrefix(StreamPickerFocusPolicy.pillPrefix) { return key }
        if key.hasPrefix(StreamPickerFocusPolicy.morePrefix) { return "more" }
        return key.hasPrefix("chip:") ? "chip" : "row"
    }

    /// The viewer acted (a chip press, a move along the chips, a row): no more re-issues.
    private func cancelInitialFocusVerify() {
        initialFocusVerifyTask?.cancel()
        initialFocusVerifyTask = nil
        initialFocusTarget = nil
        initialFocusPinned = false
    }

    /// P2 (review r1, P1): the list's initial-focus rules may move focus: once per load, and only
    /// while focus is nowhere, on the hidden test button, or on a chip the viewer has not acted on.
    private var listFocusIsPlaceable: Bool {
        guard !didPlaceListFocus else { return false }
        guard let focusedRow else { return true }
        return focusedRow == Self.testRowKey || focusedRow.hasPrefix("chip:")
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
        print("[Failover] failure source=\(ctx.launchSource) attempt=\(ctx.attempt) played=\(Int(failure.secondsPlayed))s key=\(ctx.streamKey) kind=\(failure.kind.rawValue) http=\(failure.httpStatus.map(String.init) ?? "-") reason=\(failure.reason)")
        if PlaybackFailoverPolicy.shouldKeep(secondsPlayed: failure.secondsPlayed), ctx.videoId == videoId {
            startOverHonoured = true
        }
        if !failure.kind.remembersLink, failure.secondsPlayed < PlaybackFailoverPolicy.healthySeconds {
            // BUG-143: the link is fine (network / offline / cancelled / our own engine), and its
            // debrid resolve is still good: neither remembered nor invalidated.
            print("[Failover] reject key=\(ctx.streamKey) kind=\(failure.kind.rawValue) transient=1 skipped")
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
            var retryContext: PlaybackContext?
            var retryEngine: PlaybackEngine?
            if failure.otherEngineEligible {
                let engine: PlaybackEngine = failure.engine == .mpv ? .native : .mpv
                var retry = ctx
                retry.forcedEngine = engine
                retry.resumeAtSec = failure.positionSec
                retry.attempt = ctx.attempt + 1
                retry.launchSource = .manual
                retryContext = retry
                retryEngine = engine
            }
            pendingManualFailureAlert = ManualFailureAlert(
                reason: failure.reason,
                next: nextManualStream(after: ctx),
                attempt: ctx.attempt + 1,
                retry: retryContext,
                retryEngine: retryEngine
            )
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
        guard let index = PlaybackFailoverPolicy.nextManualIndex(
            streams: list,
            failedKey: ctx.streamKey,
            failedAddonId: ctx.providerAddonId,
            rejected: RejectedStreamLinks.rejected(for: videoId)
        ) else { return nil }
        return list[index]
    }

    /// What the closing player leads to (BUG-174): the queued alert, the queued Up Next failover
    /// picker, the list (an auto walk that ended with nothing), or — everything else, manual picks
    /// included — closing the picker so Back lands on the page that opened it.
    private var afterPlayerOutcome: StreamPickerExitPolicy.AfterPlayer {
        StreamPickerExitPolicy.afterPlayerClosed(
            alertQueued: pendingManualFailureAlert != nil,
            failoverPickerQueued: pendingFailoverTarget != nil,
            listRequested: keepListAfterPlayer
        )
    }

    /// `selected` went nil (the player is closing; its slide-down has not revealed the list yet).
    /// BUG-174: when the picker closes too (or the Up Next failover picker takes over), the loading
    /// cover goes over the list first, with no animation, so the list never shows on the way out;
    /// when the list has to show (the alert, an ended walk), the cover drops.
    private func prepareForPlayerClose() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            switch afterPlayerOutcome {
            case .closePicker:
                coverHold = true
                coverIsCloseHold = true
            case .openFailoverPicker:
                coverHold = true
                coverIsCloseHold = false
            case .raiseAlert, .keepList:
                coverHold = false
                coverIsCloseHold = false
            }
        }
    }

    /// The player cover closed. A context swap (failover, Up Next) re-presents instead and leaves
    /// `selected` set; a real close raises whatever the failure queued — never in the same runloop
    /// as the dismissal — or closes the picker as well (BUG-174, Steven rc7: Back from a player
    /// returns to the page you started from, manual picks included; D1).
    private func handlePlayerDismissed() {
        StreamPickerCloseAnimation.resumeUIKitAnimations()
        if let requestedAt = playerCloseRequestedAt {
            playerCloseRequestedAt = nil
            let ms = Int((CFAbsoluteTimeGetCurrent() - requestedAt) * 1000)
            print("[StreamPicker] BUG-185 player close: setter \u{2192} onDismiss \(ms) ms uiKitFallback=\(StreamPickerCloseAnimation.uiKitFallback ? 1 : 0)")
        }
        guard selected == nil else { return }
        // P5 B22 review r1 (P3-1): a post-play pick is handed to the presenter only when this
        // close also closes the picker; any other outcome drops it, so it never fires on a later Back.
        let pick = postPlayPick
        postPlayPick = nil
        rejectedKeys = RejectedStreamLinks.rejected(for: videoId)
        let outcome = afterPlayerOutcome
        // Review r1 (P3): read once per close, so it never carries to the next one.
        keepListAfterPlayer = false
        switch outcome {
        case .raiseAlert:
            guard let pending = pendingManualFailureAlert else { return }
            pendingManualFailureAlert = nil
            coverHold = false
            coverIsCloseHold = false
            DispatchQueue.main.async { manualFailureAlert = pending }
        case .openFailoverPicker:
            guard let pending = pendingFailoverTarget else { return }
            pendingFailoverTarget = nil
            // The nested picker's own close closes this one too: the cover keeps the list hidden
            // under it and on the way out.
            coverHold = true
            coverIsCloseHold = false
            DispatchQueue.main.async { failoverTarget = pending }
        case .keepList:
            keepListAfterPlayer = false
            coverHold = false
            coverIsCloseHold = false
            autoPlay.cancel(why: "player closed")
        case .closePicker:
            // A failover still resolving behind the closed player must not reopen it.
            autoPlay.cancel(why: "player closed")
            if let pick { onOpenTitle?(pick) }
            closePicker()
        }
    }

    /// The Up Next failover picker closed (Back from its list, or its own player closed it).
    /// BUG-174: this picker's list is for the episode before, so the picker closes as well and
    /// Back lands on the page that opened it.
    private func handleFailoverPickerDismissed() {
        closePicker()
    }

    /// BUG-174: closes the picker without the list showing — the cover goes up and both changes
    /// run without animation (the picker's own slide-down would otherwise reveal the list).
    private func closePicker() {
        var instant = Transaction()
        instant.disablesAnimations = true
        // BUG-185: the close-time hold is plain black (no logo flash on the way out).
        withTransaction(instant) {
            coverHold = true
            coverIsCloseHold = true
        }
        // Not gated on `pickerOnScreen`: the player's full-screen cover can take the picker off
        // screen (`onDisappear`) until after this runs.
        DispatchQueue.main.async {
            withTransaction(instant) { dismiss() }
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
        /// The same stream on the other engine ("Try with mpv" / "Try Native Player"); nil when
        /// the other engine cannot take it.
        let retry: PlaybackContext?
        let retryEngine: PlaybackEngine?
    }
}

/// BUG-185 (Steven rc9): the fallback if a disabled-animations Transaction on the cover binding
/// still lets the player cover slide down. `-debug.pickerCloseUIKitNoAnim YES` (read per close,
/// any build) also turns UIKit animations off from the binding's setter until the player cover's
/// `onDismiss`, with a 1 s watchdog so a dismiss that never reports cannot leave the whole app
/// unanimated.
@MainActor
enum StreamPickerCloseAnimation {
    static var uiKitFallback: Bool { UserDefaults.standard.bool(forKey: "debug.pickerCloseUIKitNoAnim") }

    private static var suspended = false
    private static var generation = 0

    static func suspendUIKitAnimations() {
        suspended = true
        generation += 1
        let mine = generation
        UIView.setAnimationsEnabled(false)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard suspended, generation == mine else { return }
            print("[StreamPicker] BUG-185 UIKit animation watchdog fired (no onDismiss within 1 s)")
            resumeUIKitAnimations()
        }
    }

    static func resumeUIKitAnimations() {
        guard suspended else { return }
        suspended = false
        UIView.setAnimationsEnabled(true)
    }
}

/// BUG-174 / BUG-183 (Steven rc7): the stream picker's loading cover and what a closing player
/// leads to. Pure, so `StreamPickerExitPolicyTests` pins every case.
enum StreamPickerCoverPolicy {
    typealias Phase = FirstPlayAutoPlayController.Phase

    /// The cover is over the list: held (an auto pick's player being presented or up, the Up Next
    /// failover picker up, the picker closing), auto mode armed but not started yet (the first
    /// frame, before `onAppear` arms the controller), or auto mode working — except a failover
    /// walk, which resolves behind the open player.
    static func showsCover(armed: Bool, phase: Phase, isFailoverWalk: Bool, held: Bool) -> Bool {
        if held { return true }
        return message(armed: armed, phase: phase, isFailoverWalk: isFailoverWalk) != nil
    }

    /// The cover's spoken label while auto mode works ("Finding the best source…"); nil otherwise.
    static func message(armed: Bool, phase: Phase, isFailoverWalk: Bool) -> String? {
        if phase == .idle { return armed ? FirstPlayAutoPlayController.Policy.overlayMessage(for: .searching) : nil }
        guard !isFailoverWalk else { return nil }
        return FirstPlayAutoPlayController.Policy.overlayMessage(for: phase)
    }
}

enum StreamPickerExitPolicy {
    enum AfterPlayer: Equatable {
        /// "Couldn't play this source" (a manual pick failed): the picker stays on its list.
        case raiseAlert
        /// The Up Next episode's source failed: its own picker opens over this one.
        case openFailoverPicker
        /// An auto walk ended with nothing during a failover: the list shows with a toast.
        case keepList
        /// D1: everything else — the picker closes with the player.
        case closePicker
    }

    static func afterPlayerClosed(alertQueued: Bool, failoverPickerQueued: Bool, listRequested: Bool) -> AfterPlayer {
        if alertQueued { return .raiseAlert }
        if failoverPickerQueued { return .openFailoverPicker }
        if listRequested { return .keepList }
        return .closePicker
    }
}

/// Issue #19: the resume position handed to an external player (Infuse's `position=`, VLC's, …).
/// Pure, so `PlaybackProgressRecorderTests` pins every case.
///
/// A position-based entry resumes at its saved position (not under ten seconds in). A
/// percentage-only entry (Trakt's /sync/playback and Simkl give a percentage, no position) is
/// scaled by the catalog runtime when its percentage is between 2 and 95 inclusive. This
/// deliberately reverses the old "scaling by the show runtime is the bug being avoided" rule:
/// the in-app players can wait for the file's real duration and apply the percentage there
/// (`pendingResumePercent`), but an external player cannot — Infuse has no percentage
/// parameter, and before hand-off the catalog runtime is the only duration there is. A runtime
/// a minute or two off beats always starting from the beginning. Completed entries and
/// "Start Over" send 0. Note (review r1): `TraktProgressRepository` marks a /sync/playback row
/// at 90 % or more completed (the app-wide completion threshold, the in-app players start those
/// over too), so for Trakt rows the 95 % ceiling never binds; it covers Simkl-style entries.
nonisolated enum ExternalResumePolicy {
    enum Source: String, Sendable {
        case position
        case percent
        case none
    }

    struct Resume: Equatable, Sendable {
        let positionMs: Int64
        let source: Source
    }

    static let minPositionMs: Int64 = 10_000
    static let minPercent: Double = 2
    static let maxPercent: Double = 95

    static let noResume = Resume(positionMs: 0, source: .none)

    /// `fallbackDurationMs` is the episode's runtime, else the title's (`externalDurationMs`).
    static func resume(startsOver: Bool, entry: WatchProgressEntry?,
                       fallbackDurationMs: Int64?) -> Resume {
        guard !startsOver, let entry else { return noResume }
        // Rounded to 0.001 %: the shared Float fraction makes Trakt's 2 % read as 1.9999999.
        let percent = entry.lastPositionMs <= 0 ? (Double(entry.progressFraction) * 100_000).rounded() / 1_000 : 0
        return resume(startsOver: false, isCompleted: entry.isCompleted,
                      lastPositionMs: entry.lastPositionMs, percent: percent,
                      fallbackDurationMs: fallbackDurationMs)
    }

    /// Review r1/r3: whether an external hand-off depends on the catalog record the picker fetches
    /// (`fetchEpisodesIfNeeded`) for a duration. False with a saved position. Otherwise true for a
    /// movie launched with no `meta` (Home / Library continue-watching, deep links) and for a
    /// series launched without its episode list (the episode runtime comes from that fetch).
    static func needsCatalogRuntime(isSeries: Bool, hasMeta: Bool, hasEpisodes: Bool,
                                    resumePositionMs: Int64?) -> Bool {
        guard resumePositionMs == nil else { return false }
        return isSeries ? !hasEpisodes : !hasMeta
    }

    /// Review r2: how long an external hand-off waits for the runtime fetch (same order as the
    /// subtitle wait); after that it sends what it has (position 0 when the runtime never came).
    static let runtimeWaitSeconds: TimeInterval = 1.5

    /// Polls `isPending` until it turns false or `waitSeconds` pass; true when the fetch landed.
    @MainActor
    static func awaitRuntime(isPending: @MainActor () -> Bool,
                             waitSeconds: TimeInterval = runtimeWaitSeconds) async -> Bool {
        let deadline = Date().addingTimeInterval(waitSeconds)
        while isPending() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// Plain-value form. `percent` is 0...100 (only read when `lastPositionMs` is 0).
    static func resume(startsOver: Bool, isCompleted: Bool, lastPositionMs: Int64,
                       percent: Double, fallbackDurationMs: Int64?) -> Resume {
        guard !startsOver, !isCompleted else { return noResume }
        if lastPositionMs > 0 {
            return lastPositionMs > minPositionMs ? Resume(positionMs: lastPositionMs, source: .position) : noResume
        }
        guard percent >= minPercent, percent <= maxPercent,
              let durationMs = fallbackDurationMs, durationMs > 0 else { return noResume }
        let positionMs = Int64((Double(durationMs) * percent / 100).rounded())
        return positionMs > 0 ? Resume(positionMs: positionMs, source: .percent) : noResume
    }
}

/// D5 (Steven rc7): the subtitles an external player is handed — the stream's own first, then the
/// add-on subtitles this app fetched, the viewer's preferred subtitle language(s) first, each URL
/// once, at most `cap`. The players' URL builders apply their own rules after this
/// (`ExternalPlayerPlatform.apple.kt`: VLC and VidHub take the first, Native Player keeps http(s)
/// SRT only), so the order is what matters.
enum ExternalSubtitleHandOff {
    struct Item: Equatable {
        let url: String
        let name: String
        let lang: String
    }

    static let cap = 10
    /// The longest a hand-off waits for an add-on subtitle fetch that has not finished.
    static let waitSeconds: TimeInterval = 1.5

    /// Pure. `matches(trackLanguage, target)` is the shared `languageMatchesPreference` live.
    static func merge(own: [Item], addon: [Item], preferredTargets: [String],
                      matches: (String, String) -> Bool, cap: Int = cap) -> [Item] {
        func rank(_ lang: String) -> Int {
            preferredTargets.firstIndex { matches(lang, $0) } ?? preferredTargets.count
        }
        struct Ranked { let offset: Int; let item: Item; let rank: Int }
        var ranked: [Ranked] = []
        for (offset, item) in addon.enumerated() {
            ranked.append(Ranked(offset: offset, item: item, rank: rank(item.lang)))
        }
        ranked.sort { lhs, rhs in
            lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.offset < rhs.offset
        }
        let rankedAddon: [Item] = ranked.map { $0.item }
        var seen = Set<String>()
        var out: [Item] = []
        for item in own + rankedAddon {
            guard out.count < cap else { break }
            let key = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(item)
        }
        return out
    }

    /// The add-on subtitles for this title: the picker's prefetch (`fetchAddonSubtitles` is a no-op
    /// when that fetch already covers it), waited for at most `waitSeconds` when still running,
    /// then whatever has arrived. "Show only preferred languages" applies, as in both players.
    @MainActor
    static func liveAddonSubtitles(type: String, videoId: String) async -> [AddonSubtitle] {
        let repository = SubtitleRepository.shared
        repository.fetchAddonSubtitles(type: type, videoId: videoId)
        let key = repository.requestKey(type: type, videoId: videoId)
        let deadline = Date().addingTimeInterval(waitSeconds)
        while (repository.completedRequest.value_ as? String) != key, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let subtitles = repository.addonSubtitles.value_ as? [AddonSubtitle] ?? []
        guard let settings = playerSettings() else { return subtitles }
        return PlayerTrackSelectionKt.filterAddonSubtitlesForSettings(subtitles: subtitles, settings: settings)
    }

    /// The request's `subtitles` for `stream` plus `addonSubtitles`, ordered by the viewer's
    /// subtitle language preference (the targets both players resolve).
    @MainActor
    static func requestSubtitles(stream: StreamItem, addonSubtitles: [AddonSubtitle]) -> [SubtitleInput] {
        let own = stream.externalSubtitles.map { sub in
            Item(url: sub.url, name: { let n: String? = sub.name; return n }() ?? sub.language, lang: sub.language)
        }
        let addon = addonSubtitles.map { Item(url: $0.url, name: $0.display, lang: $0.language) }
        let targets: [String] = playerSettings().map {
            PlayerTrackSelectionKt.preferredSubtitleTargetsForSettings(settings: $0)
        } ?? []
        return merge(own: own, addon: addon, preferredTargets: targets) { track, target in
            PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: track, targetLanguage: target)
        }
        .map { SubtitleInput(url: $0.url, name: $0.name, lang: $0.lang) }
    }

    @MainActor
    private static func playerSettings() -> PlayerSettingsUiState? {
        PlayerSettingsRepository.shared.ensureLoaded()
        return PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState
    }
}

/// P2: the Left/Right repeat throttle for the chip step, as a reference so the stamp is not view
/// state (a `@State` value would re-run the picker's body on every press).
nonisolated final class ChipMoveThrottle {
    private var lastAt: CFAbsoluteTime = 0

    /// True when `now` is at least `SourceChipRow.moveRepeatInterval` after the last allowed press.
    func allows(now: CFAbsoluteTime) -> Bool {
        guard now - lastAt >= SourceChipRow.moveRepeatInterval else { return false }
        lastAt = now
        return true
    }
}
