import Combine
import Foundation
import SharedCore

/// Loads and observes the full metadata for a single title via the shared `MetaDetailsRepository`,
/// and tracks its Watched / Library state via the shared `WatchedRepository` / `LibraryRepository`.
///
/// `MetaDetailsRepository.load(type:id:)` kicks off the fetch (cache-first, then addon/TMDB enrich);
/// `uiState` (a `StateFlow<MetaDetailsUiState>`) emits `{isLoading, meta, errorMessage}` as it resolves.
/// The watched/library flags are recomputed from their repositories on every emission so the Detail
/// action buttons stay in sync after a toggle (persisted per-profile via the Phase 0 seams).
@MainActor
final class DetailViewModel: ObservableObject {
    @Published private(set) var meta: MetaDetails?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWatched: Bool = false
    @Published private(set) var isSaved: Bool = false
    /// Resolved, directly-playable trailer video URL for the hero (nil until/unless one resolves).
    @Published private(set) var trailerVideoURL: String?
    /// BUG-81: the YouTube video id `trailerVideoURL` was extracted from, handed to the trailer
    /// surfaces so the letterbox probe can key its persisted zoom on something that survives a
    /// re-extraction. Always written together with `trailerVideoURL`, so the two never disagree
    /// about which stream is on screen. See `TrailerHeroPlayer.videoId`.
    @Published private(set) var trailerVideoId: String?
    /// Trakt community comments (empty while Trakt is disconnected — the shared repo no-ops).
    @Published private(set) var comments: [TraktCommentReview] = []
    /// IMDb episode ratings keyed "season:episode" (api.imdbapi.dev, keyless).
    @Published private(set) var episodeRatings: [String: Double] = [:]
    /// rc14 (Steven rc13 verdict, 2026-09-30): whether episode cards show their rating badge at all
    /// (show all / watched only / hide), from the shared `MetaScreenSettingsRepository` — the
    /// Settings → Poster Style "Episode Ratings" row. Watched in `start()` so a change made in
    /// Settings applies the next time Detail is on screen without a relaunch.
    @Published private(set) var episodeRatingsVisibility: EpisodeRatingsVisibility = .showAll
    /// Episodes to badge as watched, keyed "season:episode" — explicit Watched marks OR
    /// effectively-completed watch progress (mirrors mobile's player episode rows).
    @Published private(set) var watchedEpisodeKeys: Set<String> = []
    /// Series-level primary play action (Resume SxEy / Play SxEy, honoring behaviorHints
    /// defaultVideoId) from the shared resolver; nil for movies or while meta loads.
    @Published private(set) var seriesAction: SeriesPrimaryAction?
    /// C (upstream `972109f9`): whether the Play button should be enabled — false only once
    /// `meta` has resolved and no addon/plugin/embedded/download source can serve this title (or,
    /// for a series, there's no primary action to play at all). True while `meta` is still
    /// loading so the button never flashes disabled for a frame. See `computeIsPlayEnabled()`.
    @Published private(set) var isPlayEnabled = true
    /// Whether the Settings "Auto-Play Best Source" switch (`StreamAutoPlayMode.firstStream`) is on.
    /// Drives hold-Play on the action row: the "Choose Source…" menu only has items while a plain
    /// press would otherwise skip the source list. Seeded synchronously in `init` (see there) and
    /// kept current by `playerSettingsWatcher`.
    @Published private(set) var autoPlayFirstStreamOn = false
    /// FEAT-35 (Cinematic ratings strip): whether MDBList ratings can arrive at all — the setting is
    /// on with credentials (`MdbListSettings.isActive`) and at least one provider is enabled, the
    /// same test `MdbListMetadataService.shouldFetchForMeta` runs. Seeded synchronously (correction
    /// F4) so the strip's slot is decided before the first paint, then kept current by
    /// `mdbListWatcher`.
    @Published private(set) var mdbListRatingsActive = false
    /// FEAT-35 (Cinematic Start Over): the title has a saved position Start Over can discard —
    /// the series primary action's resume position, or a resumable movie entry
    /// (`DetailStartOver.isAvailable`). Written only when it changes (correction F21a).
    @Published private(set) var hasResumableProgress = false
    /// IMDb parental-guide severities (empty when the title has no tt-id or no guide data).
    @Published private(set) var parentalWarnings: [ParentalWarning] = []
    /// Episode shuffle (upstream `23b048c3`/`da92f36c`): whether Detail offers the Shuffle button
    /// at all — the global switch is on, the title is a series, and it has at least one numbered
    /// episode (or shuffle is already on for it, so the user can always turn it off again).
    @Published private(set) var shuffleOffered = false
    /// Effective per-show settings (`EpisodeShuffleProfile.settings`: `enabled` is already false
    /// when the global switch is off or the title isn't a series).
    @Published private(set) var shuffleSettings = EpisodeShuffleSettings(enabled: false, includeWatched: false)
    /// The episode shuffle picked for this show (nil while shuffle is off or nothing is left to
    /// pick). Stable across Detail visits: see `refreshShuffle()`.
    @Published private(set) var shufflePick: MetaVideo?
    /// Whether `shufflePick` has a playback source (the same `PlaybackAvailability` gate as Play).
    @Published private(set) var shufflePickPlayable = true
    /// Shuffle is on in Unwatched mode but every episode is watched (the "caught up" state).
    @Published private(set) var shuffleCaughtUp = false
    /// Resolved full-screen trailer (from the Trailers row); drives a player cover with sound.
    @Published var trailerPlayback: TrailerPlaybackItem?
    /// Trailer currently resolving (spinner on its row card).
    @Published private(set) var resolvingTrailerId: String?

    /// Ownership of the shared (unkeyed) `MetaDetailsRepository`. Nested pushes (Detail → More Like
    /// This → Detail) overlap start/stop: the destination may `load()` before the source's
    /// `onDisappear` fires, and an unconditional `clear()` there wipes the destination's in-flight
    /// request (HI-005). Only the most recent screen to call `start()` owns the repo and may clear it.
    private static var currentOwner: UUID?
    private let ownerToken = UUID()

    private var detailWatcher: FlowWatcher?
    private var watchedWatcher: FlowWatcher?
    private var libraryWatcher: FlowWatcher?
    private var progressWatcher: FlowWatcher?
    private var cwPrefsWatcher: FlowWatcher?
    /// C (upstream `972109f9`): re-evaluates `isPlayEnabled` when the installed-addon set changes,
    /// so enabling an addon (or a plugin scraper elsewhere) re-enables Play without the user
    /// having to leave and re-enter the page.
    private var addonWatcher: FlowWatcher?
    private var shuffleWatcher: FlowWatcher?
    /// rc14: drives `episodeRatingsVisibility` (see above).
    private var metaScreenWatcher: FlowWatcher?
    /// Feeds `autoPlayFirstStreamOn` (hold-Play → "Choose Source…").
    private var playerSettingsWatcher: FlowWatcher?
    /// FEAT-35: feeds `mdbListRatingsActive`.
    private var mdbListWatcher: FlowWatcher?
    // Latest shared-state emissions (the exported StateFlow interface has no `value` accessor,
    // so the watchers below capture what the series primary action needs).
    private var latestProgressEntries: [WatchProgressEntry] = []
    private var latestWatchedItems: [WatchedItem] = []
    private var latestWatchedKeys: Set<String> = []
    private var latestCwPrefs: ContinueWatchingPreferencesUiState?
    private var latestShuffleProfile: EpisodeShuffleProfile?
    /// The shuffle pick the user just started playing, and when (epoch ms). Once watch progress
    /// for it lands after that moment, the pick counts as played and the next one is rolled.
    private var pendingShufflePlay: (videoId: String, season: Int?, episode: Int?, sinceMs: Int64)?
    private var didRequestTrailer = false
    private var didRequestComments = false
    private var didRequestRatings = false
    private var didRequestGuide = false
    /// BUG-101 (War Machine, 2026-09-08): the ranked hero-trailer candidates for the current title
    /// (`HeroTrailerSelectorKt.rankHeroTrailers`) and which one is currently being tried/playing —
    /// a dead/blocked top pick (e.g. a TMDB-listed French trailer whose YouTube id no longer
    /// resolves) falls through to the next ranked candidate instead of leaving Detail with no
    /// trailer at all, even though a playable one (usually the English one `fetchTmdbVideos`
    /// always merges in) sits right behind it.
    private var trailerCandidates: [MetaTrailer] = []
    private var trailerCandidateIndex = 0
    /// One retry after an AVPlayer *playback* failure (as opposed to an extraction miss) per
    /// title — otherwise a title whose every remaining candidate fails to actually play would
    /// retry without end.
    private var trailerRetriedAfterPlaybackFailure = false
    /// Bumped in `stop()` so a completion from a resolution the current title has already walked
    /// away from (a stop()/start() reuse of this same view model instance mid-flight) can never
    /// apply — the identity guard `resolveTrailerIfNeeded`'s completions check before touching
    /// `trailerVideoURL`/`trailerVideoId`.
    private var trailerResolveGeneration = 0

    private let preview: MetaPreview
    private var type: String { preview.type }
    private var id: String { preview.id }
    /// BUG-59: the identity the trailer surfaces remember their measured zoom under.
    var trailerZoomKey: String { TrailerResolutionCache.key(type: type, id: id) }

    init(preview: MetaPreview) {
        self.preview = preview
        // Seed before the first render. The `playerSettingsWatcher` in `start()` only emits after a
        // runloop turn, and with the flag starting `false` the hold-Play wiring changed one beat
        // after Detail appeared; the repository's current value is a synchronous read.
        self.autoPlayFirstStreamOn = Self.readAutoPlayFirstStreamOn()
        // FEAT-35: same reason — the ratings strip's reserved slot must not appear a beat late.
        self.mdbListRatingsActive = Self.readMdbListRatingsActive()
    }

    /// Synchronous read of the MDBList ratings gate (correction F4: `readAutoPlayFirstStreamOn`'s
    /// pattern).
    private static func readMdbListRatingsActive() -> Bool {
        MdbListSettingsRepository.shared.ensureLoaded()
        return isMdbListRatingsActive(MdbListSettingsRepository.shared.uiState.value_ as? MdbListSettings)
    }

    /// `MdbListMetadataService.shouldFetchForMeta`'s settings half. The view reserves the strip's
    /// slot from this alone (`DetailRatings.reservesSlot`, review r1 #1), not from the id half.
    private static func isMdbListRatingsActive(_ settings: MdbListSettings?) -> Bool {
        guard let settings else { return false }
        return settings.isActive && !settings.enabledProvidersInPriorityOrder().isEmpty
    }

    /// Synchronous read of Settings → Playback → Auto-Play Best Source
    /// (`StreamAutoPlayMode.firstStream`), the same read the stream picker does.
    private static func readAutoPlayFirstStreamOn() -> Bool {
        PlayerSettingsRepository.shared.ensureLoaded()
        let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState
        return settings?.streamAutoPlayMode == StreamAutoPlayMode.firstStream
    }

    func start() {
        guard detailWatcher == nil else { return }
        Self.currentOwner = ownerToken

        detailWatcher = FlowWatcherKt.watch(MetaDetailsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MetaDetailsUiState else { return }
            // The shared repo holds one in-flight detail at a time — only adopt emissions for ours.
            // The repo tags every publish with the ORIGINAL request key ("type:id" from the catalog
            // preview we passed to load()); the resolved meta's own id can differ (the repo remaps
            // tmdb: → tt… and the addon returns its canonical id), so we must NOT match on meta.id.
            // The initial/cleared empty state carries no key — fall back to repo ownership for it.
            if let key = state.requestKey {
                if key != "\(self.type):\(self.id)" { return }
            } else if Self.currentOwner != self.ownerToken {
                return
            }
            self.isLoading = state.isLoading
            self.meta = state.meta
            self.errorMessage = state.errorMessage
            if let m = state.meta {
                self.resolveTrailerIfNeeded(m)
                self.fetchCommentsIfNeeded(m)
                self.fetchEpisodeRatingsIfNeeded(m)
                self.fetchParentalGuideIfNeeded(m)
            }
            self.refreshFlags()
        }

        // Live Watched / Library state for the action buttons + per-episode watched badges.
        WatchedRepository.shared.ensureLoaded()
        LibraryRepository.shared.ensureLoaded()
        WatchProgressRepository.shared.ensureLoaded()
        // Hydrate Trakt-sourced per-episode completion for this title (no-op/cached otherwise).
        WatchProgressRepository.shared.refreshEpisodeProgress(contentId: id, forceRefresh: false)
        watchedWatcher = FlowWatcherKt.watch(WatchedRepository.shared.uiState) { [weak self] emitted in
            guard let self else { return }
            if let state = emitted as? WatchedUiState {
                self.latestWatchedItems = state.items
                self.latestWatchedKeys = state.watchedKeys
            }
            self.refreshFlags()
        }
        libraryWatcher = FlowWatcherKt.watch(LibraryRepository.shared.uiState) { [weak self] _ in
            guard let self else { return }
            self.refreshFlags()
        }
        progressWatcher = FlowWatcherKt.watch(WatchProgressRepository.shared.uiState) { [weak self] emitted in
            guard let self else { return }
            if let state = emitted as? WatchProgressUiState { self.latestProgressEntries = state.entries }
            self.refreshFlags()
        }
        cwPrefsWatcher = FlowWatcherKt.watch(ContinueWatchingPreferencesRepository.shared.uiState) { [weak self] emitted in
            guard let self else { return }
            if let state = emitted as? ContinueWatchingPreferencesUiState { self.latestCwPrefs = state }
            self.refreshFlags()
        }
        // C: an addon install/removal/toggle changes what `computeIsPlayEnabled()` sees.
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] _ in
            self?.refreshFlags()
        }
        // Episode shuffle: the per-profile settings (global switch + per-show enable/mode).
        EpisodeShuffleRepository.shared.ensureLoaded()
        shuffleWatcher = FlowWatcherKt.watch(EpisodeShuffleRepository.shared.uiState) { [weak self] emitted in
            guard let self else { return }
            if let profile = emitted as? EpisodeShuffleProfile { self.latestShuffleProfile = profile }
            self.refreshFlags()
        }
        // rc14 (Steven rc13 verdict, 2026-09-30): episode-ratings visibility setting.
        MetaScreenSettingsRepository.shared.ensureLoaded()
        metaScreenWatcher = FlowWatcherKt.watch(MetaScreenSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MetaScreenSettingsUiState else { return }
            self.episodeRatingsVisibility = state.episodeRatingsVisibility
        }
        // Auto-play mode (Settings → Playback → Auto-Play Source): gates the hold-Play menu.
        PlayerSettingsRepository.shared.ensureLoaded()
        playerSettingsWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PlayerSettingsUiState else { return }
            let on = state.streamAutoPlayMode == StreamAutoPlayMode.firstStream
            if self.autoPlayFirstStreamOn != on { self.autoPlayFirstStreamOn = on }
        }
        // FEAT-35: MDBList ratings gate — re-seeded synchronously first (a reused view model may
        // have missed a Settings change while stopped), then watched.
        let mdbListOn = Self.readMdbListRatingsActive()
        if mdbListRatingsActive != mdbListOn { mdbListRatingsActive = mdbListOn }
        mdbListWatcher = FlowWatcherKt.watch(MdbListSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self else { return }
            let on = Self.isMdbListRatingsActive(emitted as? MdbListSettings)
            if self.mdbListRatingsActive != on { self.mdbListRatingsActive = on }
        }
        refreshFlags()

        MetaDetailsRepository.shared.load(type: type, id: id)
    }

    func stop() {
        detailWatcher?.cancel(); detailWatcher = nil
        watchedWatcher?.cancel(); watchedWatcher = nil
        libraryWatcher?.cancel(); libraryWatcher = nil
        progressWatcher?.cancel(); progressWatcher = nil
        cwPrefsWatcher?.cancel(); cwPrefsWatcher = nil
        addonWatcher?.cancel(); addonWatcher = nil
        shuffleWatcher?.cancel(); shuffleWatcher = nil
        metaScreenWatcher?.cancel(); metaScreenWatcher = nil
        playerSettingsWatcher?.cancel(); playerSettingsWatcher = nil
        mdbListWatcher?.cancel(); mdbListWatcher = nil
        trailerVideoURL = nil
        trailerVideoId = nil
        didRequestTrailer = false
        trailerCandidates = []
        trailerCandidateIndex = 0
        trailerRetriedAfterPlaybackFailure = false
        trailerResolveGeneration &+= 1
        // Only the current owner clears the shared repo — a source screen disappearing mid-push
        // must not cancel the destination's request (HI-005).
        if Self.currentOwner == ownerToken {
            Self.currentOwner = nil
            MetaDetailsRepository.shared.clear()
        }
    }

    // MARK: - Hero trailer

    /// Once per title: rank the hero-trailer candidates (`rankHeroTrailers`) and resolve them in
    /// ranked order into a directly-playable stream via the shared `HeroTrailerResolver`,
    /// publishing the first one that actually works. Fails soft — if nothing resolves,
    /// `trailerVideoURL` stays nil and Detail keeps the static backdrop.
    private func resolveTrailerIfNeeded(_ meta: MetaDetails) {
        guard !didRequestTrailer else { return }
        // rc13 (test68/BUG-117): P-1d's debug.trailerForceNoTrailer was only wired into
        // `InlineTrailerCard.swift`'s Home-row trailers (`let trailers = TrailerProbe.forceNoTrailer
        // ? [] : meta.trailers`) — Detail's own hero trailer read `meta.trailers` unconditionally,
        // so a UI test navigating straight into a title via the `-debug.openDeepLink` hook still
        // got a resolved `trailerVideoURL` here, and 4s later `scheduleAutoPlayTrailerIfNeeded()`
        // (below) auto-presented a full-screen trailer cover with no way for the test to have
        // suppressed it — burying the season-poster shelf and action row under a 1-2 minute video
        // regardless of how long the test's poll budget is. Same knob, same gating rule (honored
        // only with `debug.trailerProbe` also on), mirrored here so `-debug.trailerForceNoTrailer`
        // actually means "no trailer" everywhere a title can show one, not just on Home.
        let trailers = TrailerProbe.forceNoTrailer ? [] : meta.trailers
        guard !trailers.isEmpty else { return }
        // BUG-101 (War Machine, 2026-09-08): the FULL ranking, not just the head — a dead/blocked
        // top candidate (e.g. a TMDB-listed French trailer whose YouTube id no longer resolves)
        // falls through to the next one instead of leaving Detail with no trailer at all, even
        // though a playable one (usually the English one `fetchTmdbVideos` always merges in) sits
        // right behind it.
        let ranked = HeroTrailerSelectorKt.rankHeroTrailers(
            trailers: trailers,
            preferredLanguage: TmdbSettingsRepository.shared.snapshot().language
        )
        guard !ranked.isEmpty else { return }
        didRequestTrailer = true
        trailerCandidates = ranked
        trailerCandidateIndex = 0
        trailerRetriedAfterPlaybackFailure = false
        attemptTrailerResolution(generation: trailerResolveGeneration)
    }

    /// BUG-101: walks `trailerCandidates` starting at `trailerCandidateIndex`, advancing to the
    /// next one whenever `HeroTrailerResolver` extraction comes back nil, OR (Finding 3) when
    /// extraction succeeds but `TrailerLocalHLS`'s repack of that source yields no playable URL —
    /// capped at 3 attempts total so a title with nothing but dead links doesn't chain an
    /// unbounded run of extractions. `generation` is the value `trailerResolveGeneration` held
    /// when this title's resolution began; every completion re-checks it before touching
    /// published state, so a stale completion from a resolution this title has already walked
    /// away from (a `stop()`/`start()` reuse of this same view model instance mid-flight) can
    /// never apply.
    private func attemptTrailerResolution(generation: Int) {
        guard trailerCandidateIndex < trailerCandidates.count, trailerCandidateIndex < 3 else { return }
        let trailer = trailerCandidates[trailerCandidateIndex]
        let attemptIndex = trailerCandidateIndex
        let totalCandidates = min(trailerCandidates.count, 3)

        var youtubeUrl = trailer.youtubePlaybackUrl()
        // Sim/device verification knob for the SABR repackaging path: force every Detail hero
        // trailer to a specific videoId (e.g. rNZ0xKaCdus) so [TrailerRepack]/[TrailerQuality]
        // logs are deterministic. `defaults write <bundle> debug.trailerSmokeVideoId <id>`.
        // Phase 0 (BUG-46/UX-9, 2026-08-06): lifted out of `#if DEBUG` — the trailer soak needs
        // this on release sideloads too (testers, device passes), same rationale as
        // `TrailerProbe`/`HomeGeometryProbe` being runtime knobs rather than compile-time ones.
        // BUG-59 (beta.13): honored only together with `debug.trailerProbe` — see the same guard
        // in `InlineTrailerCardModel.resolve` for why.
        if TrailerProbe.enabled, let forced = TrailerProbe.smokeVideoId {
            youtubeUrl = "https://www.youtube.com/watch?v=\(forced)"
        }
        if TrailerProbe.enabled {
            NSLog("[TrailerPipeline] hero resolve candidate=%d/%d id=%@", attemptIndex + 1, totalCandidates, trailer.id)
        }
        HeroTrailerResolver.shared.resolveYouTube(youtubeUrl: youtubeUrl) { [weak self] source, _ in
            DispatchQueue.main.async {
                guard let self, self.trailerResolveGeneration == generation else { return }
                guard let source else {
                    // BUG-101: extraction miss — this candidate's YouTube id didn't resolve
                    // (dead/blocked/deleted). Try the next ranked one rather than give up.
                    self.trailerCandidateIndex = attemptIndex + 1
                    self.attemptTrailerResolution(generation: generation)
                    return
                }
                // AVPlayer-friendly URL only (tvOS plays trailers via AVPlayer, not libmpv):
                // a local byte-range HLS repackage of the demuxed 1080p pair when the extractor
                // surfaced one (SABR fallback), else the progressive/HLS URL as before.
                TrailerLocalHLS.shared.playbackURL(for: source) { [weak self] url in
                    guard let self, self.trailerResolveGeneration == generation else { return }
                    guard let url else {
                        // Finding 3 (BUG-101 follow-up): extraction succeeded but the local repack
                        // yielded nothing playable (conversion failure, no progressive fallback) —
                        // this candidate is a dead end exactly like an extraction miss. Walk to the
                        // next ranked one within the same budget instead of leaving Detail with no
                        // trailer; a playback failure can't help here because no player ever starts.
                        self.trailerCandidateIndex = attemptIndex + 1
                        self.attemptTrailerResolution(generation: generation)
                        return
                    }
                    self.trailerVideoURL = url
                    self.trailerVideoId = source.videoId
                }
            }
        }
    }

    /// The trailer surface reports it couldn't start (undecodable/stalled) — drop it so Detail
    /// keeps the static backdrop, unless a next-ranked candidate is worth one retry first.
    ///
    /// BUG-101: an AVPlayer *playback* failure (as opposed to the extraction miss
    /// `attemptTrailerResolution` already handles) doesn't mean the title has nothing to show —
    /// try the next ranked candidate once before giving up, the same one-retry discipline
    /// `InlineTrailerCardModel.playbackFailed` uses.
    func trailerFailed() {
        trailerVideoURL = nil
        trailerVideoId = nil
        guard !trailerRetriedAfterPlaybackFailure,
              trailerCandidateIndex + 1 < trailerCandidates.count,
              trailerCandidateIndex + 1 < 3 else { return }
        trailerRetriedAfterPlaybackFailure = true
        trailerCandidateIndex += 1
        attemptTrailerResolution(generation: trailerResolveGeneration)
    }

    /// Trailers row: resolve one trailer's YouTube URL into an AVPlayer-friendly stream and present
    /// it full-screen (with sound — unlike the muted hero loop).
    func playTrailer(_ trailer: MetaTrailer) {
        guard resolvingTrailerId == nil else { return }
        resolvingTrailerId = trailer.id
        var youtubeUrl = trailer.youtubePlaybackUrl()
        // Repro-gap fix (2026-08-30 investigation): `resolveTrailerIfNeeded` above honors
        // `debug.trailerSmokeVideoId` (paired with `debug.trailerProbe`, same discipline as
        // `InlineTrailerCardModel.resolve`) so the Detail hero can be pinned to a deterministic
        // video in the simulator; this row-clip path never did, so there was no way to force a
        // "Trailers & Extras" clip to a known stream for repro/soak work. Substituting AFTER
        // `trailer.id` is what keys `resolvingTrailerId`/the eventual `TrailerPlaybackItem.zoomKey`
        // keeps per-card state distinct even though every forced clip resolves the same video.
        if TrailerProbe.enabled, let forced = TrailerProbe.smokeVideoId {
            youtubeUrl = "https://www.youtube.com/watch?v=\(forced)"
        }
        HeroTrailerResolver.shared.resolveYouTube(youtubeUrl: youtubeUrl) { [weak self] source, _ in
            DispatchQueue.main.async {
                guard let self, let source else {
                    self?.resolvingTrailerId = nil
                    return
                }
                TrailerLocalHLS.shared.playbackURL(for: source) { [weak self] url in
                    guard let self else { return }
                    self.resolvingTrailerId = nil
                    guard let url else { return }
                    // C3 (2026-08-30 investigation): a per-clip zoom key, NOT `trailerZoomKey` — see
                    // `TrailerPlaybackItem.zoomKey`'s doc comment. The hero trailer and every row
                    // clip used to share one title-keyed `TrailerZoomCache` entry, so whichever
                    // measured last stomped the other's crop.
                    self.trailerPlayback = TrailerPlaybackItem(
                        id: trailer.id, url: url, title: trailer.name,
                        zoomKey: "\(self.trailerZoomKey):clip:\(trailer.id)",
                        videoId: source.videoId
                    )
                }
            }
        }
    }

    // MARK: - Trakt comments

    /// Once per title: first page of Trakt community comments. The shared repo resolves the Trakt
    /// ids from `meta` itself and returns an empty page when Trakt isn't connected, so the section
    /// simply stays hidden in that case.
    ///
    /// Goes through `TraktCommentsSwiftBridge`: the raw repo call THROWS on HTTP errors (e.g. 401
    /// when the synced Trakt token is rejected), and an undeclared Kotlin exception crossing a
    /// suspend completion terminates the app. The bridge collapses failures to nil.
    private func fetchCommentsIfNeeded(_ meta: MetaDetails) {
        guard !didRequestComments else { return }
        didRequestComments = true
        TraktCommentsSwiftBridge.shared.pageOrNull(meta: meta, page: 1, forceRefresh: false) { [weak self] page, _ in
            DispatchQueue.main.async {
                guard let self, let page else { return }
                self.comments = page.items
            }
        }
    }

    // MARK: - IMDb episode ratings (series only)

    /// Once per series: per-episode IMDb ratings from api.imdbapi.dev (keyless), keyed
    /// "season:episode" for the episode list to badge. Movies and titles without a tt/tmdb id skip.
    private func fetchEpisodeRatingsIfNeeded(_ meta: MetaDetails) {
        guard !didRequestRatings, EpisodesSection.isSeriesLike(meta) else { return }
        let imdbId = ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: meta.id)
            ?? ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: id)
            ?? ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: meta.imdbId)
        let tmdbId = ParentalGuideRepositoryKt.extractParentalGuideTmdbId(value: meta.id)
            ?? ParentalGuideRepositoryKt.extractParentalGuideTmdbId(value: id)
        guard imdbId != nil || tmdbId != nil else { return }
        didRequestRatings = true

        ImdbEpisodeRatingsRepository.shared.getEpisodeRatings(imdbId: imdbId, tmdbId: tmdbId) { [weak self] ratings, _ in
            DispatchQueue.main.async {
                guard let self, let ratings else { return }
                // Kotlin Map<Pair<Int, Int>, Double> — unwrap the KotlinPair keys defensively
                // (generics erase across the ObjC bridge).
                var mapped: [String: Double] = [:]
                for (key, value) in ratings {
                    guard let season = (key.first as? KotlinInt)?.value,
                          let episode = (key.second as? KotlinInt)?.value else { continue }
                    mapped["\(season):\(episode)"] = value.doubleValue
                }
                self.episodeRatings = mapped
            }
        }
    }

    // MARK: - Parental guide

    /// Once per title: IMDb parents-guide severities, mapped to display chips via the shared
    /// `buildParentalWarnings` (labels supplied here — tvOS is English-only).
    private func fetchParentalGuideIfNeeded(_ meta: MetaDetails) {
        guard !didRequestGuide else { return }
        guard let imdbId = ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: meta.id)
            ?? ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: id)
            ?? ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: meta.imdbId) else { return }
        didRequestGuide = true

        ParentalGuideRepository.shared.getParentalGuide(imdbId: imdbId) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self, let result else { return }
                self.parentalWarnings = ParentalGuideRepositoryKt.buildParentalWarnings(
                    guide: result,
                    labels: Self.parentalGuideLabels
                )
            }
        }
    }

    static let parentalGuideLabels = ParentalGuideLabels(
        nudity: String(localized: "Nudity"),
        violence: String(localized: "Violence"),
        profanity: String(localized: "Profanity"),
        alcohol: String(localized: "Alcohol & Drugs"),
        frightening: String(localized: "Frightening Scenes"),
        severe: String(localized: "Severe"),
        moderate: String(localized: "Moderate"),
        mild: String(localized: "Mild")
    )

    // MARK: - Actions

    /// Toggle the title-level watched marker. Uses the shared `MetaPreview.toWatchedItem` builder
    /// (a Kotlin extension → Swift instance method; matches mobile's Detail screen). The repo stamps
    /// `markedAtEpochMs` itself, so we pass 0.
    func toggleWatched() {
        WatchedRepository.shared.toggleWatched(item: preview.toWatchedItem(markedAtEpochMs: 0))
    }

    /// Toggle library membership. Prefers the enriched `meta`, falling back to the preview card.
    /// `toLibraryItem` is a Kotlin extension → Swift instance method; the repo stamps
    /// `savedAtEpochMs` itself, so we pass 0.
    func toggleLibrary() {
        let item: LibraryItem = meta.map { $0.toLibraryItem(savedAtEpochMs: 0) }
            ?? preview.toLibraryItem(savedAtEpochMs: 0)
        LibraryRepository.shared.toggleSaved(item: item)
    }

    private func refreshFlags() {
        isWatched = WatchedRepository.shared.isWatched(id: id, type: type, season: nil, episode: nil)
        isSaved = LibraryRepository.shared.isSaved(id: id, type: type)
        watchedEpisodeKeys = computeWatchedEpisodeKeys()
        refreshShuffle()
        seriesAction = computeSeriesAction()
        isPlayEnabled = computeIsPlayEnabled()
        let resumable = computeHasResumableProgress()
        if hasResumableProgress != resumable { hasResumableProgress = resumable }
    }

    /// FEAT-35: see `hasResumableProgress`. Series read the primary action computed just above;
    /// movies look up the title's own entry the way the stream picker's resume path does.
    private func computeHasResumableProgress() -> Bool {
        if let meta, EpisodesSection.isSeriesLike(meta) {
            let resumeMs = seriesAction?.resumePositionMs?.int64Value
            // Review r1 #3: a percentage-only entry (Trakt/Simkl) leaves `resumePositionMs` nil, so
            // read the primary action's own episode entry too. Skipped when the position decides.
            var episodeEntry: WatchProgressEntry?
            if (resumeMs ?? 0) <= 0, let action = seriesAction {
                episodeEntry = WatchProgressRepository.shared.progressForVideo(
                    videoId: action.videoId, parentMetaId: id,
                    seasonNumber: action.seasonNumber, episodeNumber: action.episodeNumber
                )
            }
            return DetailStartOver.isAvailable(isSeries: true,
                                               seriesResumePositionMs: resumeMs,
                                               seriesEntryFraction: episodeEntry?.progressFraction,
                                               seriesEntryResumable: episodeEntry?.isResumable ?? false,
                                               movieEntryPositionMs: nil, movieEntryResumable: false)
        }
        if meta == nil, preview.type == "series" { return false }
        let videoId = meta?.id ?? id
        let entry = WatchProgressRepository.shared.progressForVideo(
            videoId: videoId, parentMetaId: videoId, seasonNumber: nil, episodeNumber: nil
        )
        return DetailStartOver.isAvailable(isSeries: false, seriesResumePositionMs: nil,
                                           movieEntryPositionMs: entry?.lastPositionMs,
                                           movieEntryFraction: entry?.progressFraction,
                                           movieEntryResumable: entry?.isResumable ?? false)
    }

    // MARK: - Episode shuffle

    /// Title types the shared `EpisodeShuffleProfile.settings` accepts (upstream's set).
    private static let shuffleContentTypes: Set<String> = ["series", "tv", "show", "tvshow"]

    /// Upstream bumps its `visit` counter every time the Detail screen becomes active again, which
    /// re-rolls the pick on every return. tvOS keeps ONE visit per show instead, so the shared
    /// `EpisodeShuffle` session (a process-wide singleton keyed by profile/show/surface/mode) hands
    /// back the same pick on every Detail visit until it is re-rolled (`reshuffle()`), played
    /// (`pendingShufflePlay`), watched in Unwatched mode, or the settings change (`save` clears it).
    private static let shuffleVisit: Int64 = 0

    /// Recomputes every `shuffle*` published value. Called from `refreshFlags()` before
    /// `computeSeriesAction()`, which reads the same shared session.
    private func refreshShuffle() {
        guard let meta, EpisodesSection.isSeriesLike(meta), let profile = latestShuffleProfile else {
            shuffleOffered = false
            shuffleSettings = EpisodeShuffleSettings(enabled: false, includeWatched: false)
            clearShufflePick()
            return
        }
        let settings = profile.settings(contentId: meta.id, contentType: meta.type)
        let hasEpisodes = meta.videos.contains {
            ($0.season?.intValue ?? 0) > 0 && ($0.episode?.intValue ?? 0) > 0
        }
        shuffleOffered = profile.available
            && Self.shuffleContentTypes.contains(meta.type.lowercased())
            && (settings.enabled || hasEpisodes)
        shuffleSettings = settings

        let profileId = ProfileRepository.shared.activeProfileId
        let shuffle = EpisodeShuffleRepository.shared.shuffle
        guard settings.enabled else {
            // Upstream: with shuffle off the Detail pick is forgotten, so turning it back on rolls anew.
            shuffle.clearSelection(profileId: profileId, contentId: meta.id, surface: .detail)
            pendingShufflePlay = nil
            clearShufflePick()
            return
        }
        consumePlayedShufflePick(meta: meta, profileId: profileId)

        let watched = ShuffleEpisodeStateKt.watchedShuffleEpisodes(
            contentId: meta.id, contentType: meta.type, videos: meta.videos, watchedKeys: latestWatchedKeys
        )
        let progress = ShuffleEpisodeStateKt.shuffleEpisodeProgress(contentId: meta.id, entries: latestProgressEntries)
        // Same arguments `shufflePrimaryAction` passes, so both read the same session selection.
        let pick = shuffle.select(
            profileId: profileId, contentId: meta.id, videos: meta.videos,
            includeWatched: settings.includeWatched, watched: watched, progress: progress,
            surface: .detail, current: nil, visit: Self.shuffleVisit, preferredVideoId: nil
        )
        shufflePick = pick
        if let pick {
            shufflePickPlayable = PlaybackAvailability.companion.current(type: type).canPlay(
                type: type, videoId: pick.id, parentMetaId: id,
                seasonNumber: pick.season, episodeNumber: pick.episode
            )
            shuffleCaughtUp = false
        } else {
            shufflePickPlayable = false
            // Caught up vs nothing to shuffle at all: probe the All pool on a THROWAWAY session so
            // the shared one's history and selections stay untouched.
            shuffleCaughtUp = !settings.includeWatched && EpisodeShuffle().select(
                profileId: profileId, contentId: meta.id, videos: meta.videos,
                includeWatched: true, watched: watched, progress: progress,
                surface: .detail, current: nil, visit: Self.shuffleVisit, preferredVideoId: nil
            ) != nil
        }
    }

    private func clearShufflePick() {
        shufflePick = nil
        shufflePickPlayable = true
        shuffleCaughtUp = false
    }

    /// Once watch progress for the pick the user started lands (written after the play began),
    /// that pick is spent: drop the selection so the next `select` rolls a new episode.
    private func consumePlayedShufflePick(meta: MetaDetails, profileId: Int32) {
        guard let pending = pendingShufflePlay else { return }
        // Progress may be keyed by a playback id rather than the addon video id, so a matching
        // season/episode under this show counts too.
        let played = latestProgressEntries.contains { entry in
            guard entry.lastUpdatedEpochMs >= pending.sinceMs else { return false }
            if entry.videoId == pending.videoId { return true }
            guard entry.parentMetaId == meta.id || entry.parentMetaId == id,
                  let season = pending.season, let episode = pending.episode else { return false }
            return entry.seasonNumber?.intValue == season && entry.episodeNumber?.intValue == episode
        }
        guard played else { return }
        pendingShufflePlay = nil
        EpisodeShuffleRepository.shared.shuffle.clearSelection(profileId: profileId, contentId: meta.id, surface: .detail)
    }

    /// Detail is launching `action` (the Play button or the shuffle sheet). If it is the current
    /// shuffle pick, remember it so the pick re-rolls once it has actually been played.
    func noteSeriesPlayStarted(_ action: SeriesPrimaryAction) {
        guard shuffleSettings.enabled, let pick = shufflePick,
              pick.id == action.videoId
                || (pick.season?.intValue == action.seasonNumber?.intValue
                    && pick.episode?.intValue == action.episodeNumber?.intValue) else { return }
        pendingShufflePlay = (
            action.videoId, pick.season?.intValue, pick.episode?.intValue,
            Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// The pick as a playable series action — exactly what `shufflePrimaryAction` builds for it.
    func shufflePickAction() -> SeriesPrimaryAction? {
        guard let pick = shufflePick else { return nil }
        return SeriesPrimaryAction(
            label: pick.playLabel(), videoId: pick.id,
            seasonNumber: pick.season, episodeNumber: pick.episode,
            episodeTitle: pick.title, episodeThumbnail: pick.thumbnail,
            resumePositionMs: nil
        )
    }

    /// "Shuffle Again": forget the current pick; the session keeps its history, so the picker
    /// avoids the episode just shown.
    func reshuffle() {
        guard let meta else { return }
        EpisodeShuffleRepository.shared.shuffle.clearSelection(
            profileId: ProfileRepository.shared.activeProfileId, contentId: meta.id, surface: .detail
        )
        pendingShufflePlay = nil
        refreshFlags()
    }

    func setShuffleEnabled(_ enabled: Bool) {
        saveShuffle(EpisodeShuffleSettings(enabled: enabled, includeWatched: shuffleSettings.includeWatched))
    }

    func setShuffleIncludeWatched(_ includeWatched: Bool) {
        saveShuffle(EpisodeShuffleSettings(enabled: shuffleSettings.enabled, includeWatched: includeWatched))
    }

    /// Writes through the shared repository. A failed write changes nothing: the published
    /// settings still reflect storage, so any control bound to them snaps back.
    @discardableResult
    func saveShuffle(_ settings: EpisodeShuffleSettings) -> Bool {
        guard let meta else { return false }
        let profileId = ProfileRepository.shared.activeProfileId
        guard EpisodeShuffleRepository.shared.save(contentId: meta.id, settings: settings, profileId: profileId) else {
            return false
        }
        // The uiState emission arrives on the next main-queue turn; read the saved profile now so
        // the sheet's controls don't flicker back for a frame.
        latestShuffleProfile = EpisodeShuffleRepository.shared.readProfile(profileId: profileId)
        refreshFlags()
        return true
    }

    /// C (upstream `972109f9`): mirrors the shared `PlaybackAvailability` gate mobile's Compose
    /// screens already apply. Stays `true` while `meta` hasn't resolved yet (no verdict to give);
    /// a movie checks `id`/`type` directly, a series checks the shared resolver's primary action
    /// (its `videoId`/season/episode — the exact episode Play/Resume would launch) and disables
    /// outright when there's no action at all (nothing left to play, e.g. an unaired-only series).
    private func computeIsPlayEnabled() -> Bool {
        guard let meta else { return true }
        let availability = PlaybackAvailability.companion.current(type: type)
        if EpisodesSection.isSeriesLike(meta) {
            guard let action = seriesAction else { return false }
            return availability.canPlay(
                type: type,
                videoId: action.videoId,
                parentMetaId: id,
                seasonNumber: action.seasonNumber,
                episodeNumber: action.episodeNumber
            )
        }
        return availability.canPlay(type: type, videoId: id, parentMetaId: id, seasonNumber: nil, episodeNumber: nil)
    }

    /// Mirrors mobile's Detail screen: shared `seriesPrimaryAction` over the full progress +
    /// watched state (resume beats next-up; first released episode — or the addon's
    /// behaviorHints.defaultVideoId — for a fresh series).
    ///
    /// Episode shuffle on for this show: the shared `shufflePrimaryAction` instead (an in-progress
    /// episode still resumes first; otherwise the shuffle pick, or nil when nothing is left to pick
    /// — no sequential fallback, matching upstream).
    private func computeSeriesAction() -> SeriesPrimaryAction? {
        guard let meta, EpisodesSection.isSeriesLike(meta) else { return nil }
        if shuffleSettings.enabled {
            return meta.shufflePrimaryAction(
                profileId: ProfileRepository.shared.activeProfileId,
                settings: shuffleSettings,
                entries: latestProgressEntries,
                watchedKeys: latestWatchedKeys,
                visit: Self.shuffleVisit,
                shuffle: EpisodeShuffleRepository.shared.shuffle,
                surface: .detail
            )
        }
        return meta.seriesPrimaryAction(
            entries: latestProgressEntries,
            watchedItems: latestWatchedItems,
            todayIsoDate: CurrentDateProvider.shared.todayIsoDate(),
            preferFurthestEpisode: latestCwPrefs?.upNextFromFurthestEpisode ?? true,
            showUnairedNextUp: latestCwPrefs?.showUnairedNextUp ?? false,
            allowRewatch: true
        )
    }

    /// "season:episode" keys for every episode that is explicitly marked watched or whose watch
    /// progress is effectively complete. Pure in-memory lookups against the shared repositories.
    private func computeWatchedEpisodeKeys() -> Set<String> {
        guard let meta, EpisodesSection.isSeriesLike(meta) else { return [] }
        var keys: Set<String> = []
        for episode in meta.videos {
            guard let s = episode.season?.value, let e = episode.episode?.value else { continue }
            let season = KotlinInt(int: Int32(s))
            let number = KotlinInt(int: Int32(e))
            let marked = WatchedRepository.shared.isWatched(id: id, type: type, season: season, episode: number)
            let completed = WatchProgressRepository.shared.progressForVideo(
                videoId: "\(id):\(s):\(e)",
                parentMetaId: id,
                seasonNumber: season,
                episodeNumber: number
            )?.isEffectivelyCompleted == true
            if marked || completed { keys.insert("\(s):\(e)") }
        }
        return keys
    }

    deinit {
        detailWatcher?.cancel()
        watchedWatcher?.cancel()
        libraryWatcher?.cancel()
        progressWatcher?.cancel()
        cwPrefsWatcher?.cancel()
        addonWatcher?.cancel()
        shuffleWatcher?.cancel()
        metaScreenWatcher?.cancel()
        playerSettingsWatcher?.cancel()
        mdbListWatcher?.cancel()
    }
}

/// One resolved trailer ready for full-screen playback (`id` keys the presenting cover).
struct TrailerPlaybackItem: Identifiable {
    let id: String
    let url: String
    let title: String
    /// C3 (2026-08-30 investigation): the identity `TrailerLetterboxProbe`/`TrailerZoomCache`
    /// remembers this clip's measured letterbox zoom under. The Detail hero "Watch Trailer" button
    /// and the auto-play item play the SAME video the Detail hero background loop does, so they use
    /// the canonical title key (`DetailViewModel.trailerZoomKey`) and correctly share its entry.
    /// Every "Trailers & Extras" row clip (`DetailViewModel.playTrailer(_:)`) is a DIFFERENT stream
    /// of the same title, and used to collide on that one title-keyed entry — opening a row clip
    /// right after the hero (or vice versa) inherited whichever measurement ran last, then visibly
    /// re-zoomed mid-playback once its own probe landed. Row clips get their own per-trailer-id key.
    let zoomKey: String
    /// BUG-81: the YouTube video id this clip's stream was extracted from. See
    /// `TrailerHeroPlayer.videoId`; nil is a supported fallback, not an error.
    var videoId: String? = nil
}
