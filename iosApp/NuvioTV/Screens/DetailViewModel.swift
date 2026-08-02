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
    /// Trakt community comments (empty while Trakt is disconnected — the shared repo no-ops).
    @Published private(set) var comments: [TraktCommentReview] = []
    /// IMDb episode ratings keyed "season:episode" (api.imdbapi.dev, keyless).
    @Published private(set) var episodeRatings: [String: Double] = [:]
    /// Episodes to badge as watched, keyed "season:episode" — explicit Watched marks OR
    /// effectively-completed watch progress (mirrors mobile's player episode rows).
    @Published private(set) var watchedEpisodeKeys: Set<String> = []
    /// Series-level primary play action (Resume SxEy / Play SxEy, honoring behaviorHints
    /// defaultVideoId) from the shared resolver; nil for movies or while meta loads.
    @Published private(set) var seriesAction: SeriesPrimaryAction?
    /// IMDb parental-guide severities (empty when the title has no tt-id or no guide data).
    @Published private(set) var parentalWarnings: [ParentalWarning] = []
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
    // Latest shared-state emissions (the exported StateFlow interface has no `value` accessor,
    // so the watchers below capture what the series primary action needs).
    private var latestProgressEntries: [WatchProgressEntry] = []
    private var latestWatchedItems: [WatchedItem] = []
    private var latestCwPrefs: ContinueWatchingPreferencesUiState?
    private var didRequestTrailer = false
    private var didRequestComments = false
    private var didRequestRatings = false
    private var didRequestGuide = false

    private let preview: MetaPreview
    private var type: String { preview.type }
    private var id: String { preview.id }

    init(preview: MetaPreview) {
        self.preview = preview
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
            if let state = emitted as? WatchedUiState { self.latestWatchedItems = state.items }
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
        refreshFlags()

        MetaDetailsRepository.shared.load(type: type, id: id)
    }

    func stop() {
        detailWatcher?.cancel(); detailWatcher = nil
        watchedWatcher?.cancel(); watchedWatcher = nil
        libraryWatcher?.cancel(); libraryWatcher = nil
        progressWatcher?.cancel(); progressWatcher = nil
        cwPrefsWatcher?.cancel(); cwPrefsWatcher = nil
        trailerVideoURL = nil
        didRequestTrailer = false
        // Only the current owner clears the shared repo — a source screen disappearing mid-push
        // must not cancel the destination's request (HI-005).
        if Self.currentOwner == ownerToken {
            Self.currentOwner = nil
            MetaDetailsRepository.shared.clear()
        }
    }

    // MARK: - Hero trailer

    /// Once per title: pick the best trailer (`selectHeroTrailer`), resolve its YouTube URL into a
    /// directly-playable stream via the shared `HeroTrailerResolver`, and publish it. Fails soft —
    /// if nothing resolves, `trailerVideoURL` stays nil and Detail keeps the static backdrop.
    private func resolveTrailerIfNeeded(_ meta: MetaDetails) {
        guard !didRequestTrailer else { return }
        let trailers = meta.trailers
        guard !trailers.isEmpty,
              let trailer = HeroTrailerSelectorKt.selectHeroTrailer(trailers: trailers) else { return }
        didRequestTrailer = true

        var youtubeUrl = trailer.youtubePlaybackUrl()
        #if DEBUG
        // Sim verification knob for the SABR repackaging path: force every Detail hero trailer to a
        // specific videoId (e.g. rNZ0xKaCdus) so [TrailerRepack]/[TrailerQuality] logs are
        // deterministic. `defaults write <bundle> debug.trailerSmokeVideoId <id>`.
        if let forced = UserDefaults.standard.string(forKey: "debug.trailerSmokeVideoId"), !forced.isEmpty {
            youtubeUrl = "https://www.youtube.com/watch?v=\(forced)"
        }
        #endif
        HeroTrailerResolver.shared.resolveYouTube(youtubeUrl: youtubeUrl) { [weak self] source, _ in
            DispatchQueue.main.async {
                guard let self, let source else { return }
                // AVPlayer-friendly URL only (tvOS plays trailers via AVPlayer, not libmpv):
                // a local byte-range HLS repackage of the demuxed 1080p pair when the extractor
                // surfaced one (SABR fallback), else the progressive/HLS URL as before. Nil →
                // static backdrop when only adaptive VP9/AV1 exists.
                TrailerLocalHLS.shared.playbackURL(for: source) { [weak self] url in
                    guard let self, let url else { return }
                    self.trailerVideoURL = url
                }
            }
        }
    }

    /// The trailer surface reports it couldn't start (undecodable/stalled) — drop it so Detail keeps
    /// the static backdrop. Not retried for this title.
    func trailerFailed() {
        trailerVideoURL = nil
    }

    /// Trailers row: resolve one trailer's YouTube URL into an AVPlayer-friendly stream and present
    /// it full-screen (with sound — unlike the muted hero loop).
    func playTrailer(_ trailer: MetaTrailer) {
        guard resolvingTrailerId == nil else { return }
        resolvingTrailerId = trailer.id
        HeroTrailerResolver.shared.resolveYouTube(youtubeUrl: trailer.youtubePlaybackUrl()) { [weak self] source, _ in
            DispatchQueue.main.async {
                guard let self, let source else {
                    self?.resolvingTrailerId = nil
                    return
                }
                TrailerLocalHLS.shared.playbackURL(for: source) { [weak self] url in
                    guard let self else { return }
                    self.resolvingTrailerId = nil
                    guard let url else { return }
                    self.trailerPlayback = TrailerPlaybackItem(id: trailer.id, url: url, title: trailer.name)
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
            ?? ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: id) else { return }
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
        seriesAction = computeSeriesAction()
    }

    /// Mirrors mobile's Detail screen: shared `seriesPrimaryAction` over the full progress +
    /// watched state (resume beats next-up; first released episode — or the addon's
    /// behaviorHints.defaultVideoId — for a fresh series).
    private func computeSeriesAction() -> SeriesPrimaryAction? {
        guard let meta, EpisodesSection.isSeriesLike(meta) else { return nil }
        return meta.seriesPrimaryAction(
            entries: latestProgressEntries,
            watchedItems: latestWatchedItems,
            todayIsoDate: CurrentDateProvider.shared.todayIsoDate(),
            preferFurthestEpisode: latestCwPrefs?.upNextFromFurthestEpisode ?? true,
            showUnairedNextUp: latestCwPrefs?.showUnairedNextUp ?? false
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
    }
}

/// One resolved trailer ready for full-screen playback (`id` keys the presenting cover).
struct TrailerPlaybackItem: Identifiable {
    let id: String
    let url: String
    let title: String
}
