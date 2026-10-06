import Combine
import Foundation
import SwiftUI
import SharedCore

/// Next-episode autoplay orchestration for the tvOS player (Phase 8b).
///
/// Swift port of mobile's `PlayerNextEpisodeAutoPlay` orchestration on the shared pieces:
///  - next-episode resolution over the `PlaybackContext.episodes` list (aired episodes only),
///  - trigger thresholds from shared `PlayerSettingsUiState` (percentage / minutes-before-end),
///  - stream resolution via shared `PlayerStreamsRepository.loadEpisodeStreams`,
///  - stream choice via shared `StreamAutoPlaySelector` (binge-group preference included),
///  - a 3-2-1 countdown, then handing the new `PlaybackContext` back to the presenter.
///
/// Mobile parity notes: the default settings (MANUAL mode + prefer-binge-group) auto-select the
/// first stream, preferring the current stream's binge group — same as the phone. Downloads are
/// skipped (not functional on tvOS) and outro-segment timing is simplified to the settings
/// threshold, except that a post-credits scene after the last outro holds the trigger until the
/// scene ends (shared `nextEpisodeHoldUntilMs`, upstream 77ce8a73).
@MainActor
final class NextEpisodeEngine: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case searching
        case counting(Int)
        case stillWatching
        case noStream
    }

    /// Consecutive episodes started WITHOUT any remote interaction. Any handled press in the
    /// player resets it (see `MPVTVPlayerViewController.pressesBegan`), as does a manual stream
    /// pick in `StreamPickerView`. At `stillWatchingThreshold` the countdown ends in a
    /// "Still watching?" prompt instead of autoplaying (Android TV parity).
    static var consecutiveAutoPlays = 0
    static let stillWatchingThreshold = 3

    @Published private(set) var phase: Phase = .hidden
    @Published private(set) var nextEpisodeTitle = ""
    @Published private(set) var sourceName: String?

    /// Alternate streams for the CURRENTLY-playing video (in-player source switching).
    @Published private(set) var sources: [StreamItem] = []
    @Published private(set) var sourcesLoading = false
    private var sourcesWatcher: FlowWatcher?
    /// Identity of the current `loadSources()` request. `episodeStreamsState` is a shared StateFlow
    /// that replays its last value on subscribe — without this, a new subscription can adopt the
    /// previous episode's (or the autoplay search's) streams as if they were ours (ME-005).
    private var sourceLoadGeneration = 0

    /// The engine's one outside dependency that the trigger tests replace: the stream load that
    /// both the FEAT-49 preload and `beginSearch()` issue. `.live` is the shared repository.
    /// (Tier 2 note: a warmup-aware loader slots in here; keep the request key stable.)
    struct Hooks {
        var loadStreams: (_ type: String, _ videoId: String, _ season: KotlinInt?, _ episode: KotlinInt?) -> Void
        /// Invoked first thing in `beginSearch()`, before the `settings` guard, so tests can see
        /// that a search was attempted. No-op in `.live`.
        var searchBegan: () -> Void = {}

        /// `nonisolated` so the init's default argument can be read off the main actor without a warning.
        nonisolated static var live: Hooks {
            Hooks(loadStreams: { type, videoId, season, episode in
                PlayerStreamsRepository.shared.loadEpisodeStreams(
                    type: type,
                    videoId: videoId,
                    season: season,
                    episode: episode,
                    forceRefresh: false
                )
            })
        }
    }

    /// The slice of `PlayerSettingsUiState` the trigger reads, as plain Swift values so
    /// `NextEpisodeTriggerPolicy` is testable without SharedCore singletons.
    struct TriggerSettings: Equatable {
        var percentageMode: Bool
        var thresholdPercent: Double
        var thresholdMinutesBeforeEnd: Double
        var autoPlayTimeoutSeconds: Int
        var preloadEnabled: Bool
    }

    private let context: PlaybackContext
    private let onPlayNext: (PlaybackContext) -> Void
    private let hooks: Hooks

    /// Panel accessors (the playback-settings panel renders episode/source sections from these).
    var episodes: [MetaVideo] { context.episodes }
    /// Exposed for the player's episode jump list (watched-badge lookups).
    var parentMetaId: String { context.parentMetaId }
    var contentType: String { context.contentType }
    var currentSeason: Int? { context.season }
    var currentEpisode: Int? { context.episode }
    var currentUrlString: String { context.url.absoluteString }

    /// True while a manual episode jump is searching — plays immediately when a stream is found
    /// (no countdown, no Still Watching gate: a jump IS user interaction).
    private var immediatePlay = false

    private var settings: PlayerSettingsUiState?
    /// Built from `settings` in the same watcher callback; `onProgress` reads only this.
    private var trigger: TriggerSettings?
    private var settingsWatcher: FlowWatcher?
    /// mpv only: closes of the in-player panel (source-list collision, FEAT-49 layer 2).
    private var panelWatch: AnyCancellable?
    private var streamsWatcher: FlowWatcher?
    private var countdownTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    private var nextVideo: MetaVideo?
    private var triggered = false
    private var cancelled = false
    /// FEAT-49 Tier 1 (upstream 22c9ab20): the next episode's streams were requested silently
    /// ahead of the card. `beginSearch()` then hits the repository's request-key dedupe.
    private var preloaded = false
    /// #2150 rider: the up-next chip was dismissed with Menu (not a seek or exit cancel).
    private var dismissedByUser = false
    /// #2150 rider: the end-of-file re-arm already happened once this session.
    private var rearmedAtEnd = false
    /// Last tick seen by `onProgress`, so a dismissal can tell whether it happened at the end.
    private var lastProgress: (positionSec: Double, durationSec: Double)?
    private var selectedStream: StreamItem?
    /// A debrid resolve for the selected next-episode stream is in flight (play-time resolution).
    private var resolvingNext = false
    /// Latest emission from `episodeStreamsState` (the exported StateFlow has no sync `.value`).
    private var latestStreamsState: StreamsUiState?
    /// The playing title's skip intervals (post-credits included), handed in by both player
    /// screens once fetched. Drives the post-credits hold in `onProgress` (upstream 77ce8a73).
    var skipIntervals: [SkipInterval] = []

    init(context: PlaybackContext, onPlayNext: @escaping (PlaybackContext) -> Void, hooks: Hooks = .live) {
        self.context = context
        self.onPlayNext = onPlayNext
        self.hooks = hooks
    }

    /// Tests only: skip `prime()` (shared settings + shuffle singletons) and set the next episode
    /// and the trigger settings directly.
    func configureForTesting(nextVideo: MetaVideo?, trigger: TriggerSettings) {
        self.nextVideo = nextVideo
        self.trigger = trigger
    }

    /// Tests only: `dismissIfVisible()` needs a live card (`phase != .hidden`), which needs
    /// `settings` (nil in tests). This reproduces its effect on a card dismissed before the end
    /// (`dismissedByUser` + sticky `cancelled`) without `cancel()`'s SharedCore teardown.
    func simulateDismissForTesting() {
        dismissedByUser = true
        cancelled = true
    }

    // MARK: - Lifecycle

    /// Wires the mpv player state's up-next hooks and resolves the next aired episode (if any).
    func start(state: MPVPlaybackState) {
        prime()
        state.upNextPlayNow = { [weak self] in self?.playNow() ?? false }
        state.upNextCancel = { [weak self] in self?.cancel() }
        state.upNextDismiss = { [weak self] in self?.dismissIfVisible() ?? false }
        state.upNextVisible = { [weak self] in self.map { $0.phase != .hidden } ?? false }
        // FEAT-49 layer 2: the in-player source list (mpv only) shares `episodeStreamsState` and
        // clears it, which throws away a preload. When the panel closes, release the list's
        // watcher so the preload guard opens again, and re-issue a preload the list clobbered.
        panelWatch = state.$panelOpen
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] open in
                guard !open else { return }
                self?.sourceListClosed()
            }
    }

    /// Only with the preload toggle on: with it off nothing waits on `sourcesWatcher`, and the
    /// list keeps today's behaviour (its watcher lives until the next `loadSources`/search).
    private func sourceListClosed() {
        guard trigger?.preloadEnabled == true, sourcesWatcher != nil else { return }
        cancelSourceLoad()
        if preloaded && !triggered {
            preloaded = false
            print("[UpNext] preload invalidated by the source list — will re-issue")
        }
    }

    /// Engine-agnostic start for the native AVPlayer path: same settings watch + next-episode
    /// resolution, without the mpv-specific remote hooks (the countdown still auto-plays via
    /// `onProgress` → `onPlayNext`). See docs/tvos-hybrid-player-plan.md.
    func startNative() { prime() }

    private func prime() {
        PlayerSettingsRepository.shared.ensureLoaded()
        settingsWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? PlayerSettingsUiState else { return }
            self.settings = value
            self.trigger = TriggerSettings(settings: value)
        }

        if ShuffleNextEpisode.shared.isEnabled(contentId: context.parentMetaId, contentType: context.contentType) {
            // Shuffle is on for this show: a nil pick means nothing is left, NOT "play the next
            // one in order" (upstream keeps no sequential fallback), so up-next stays hidden.
            nextVideo = ShuffleNextEpisode.shared.nextPlaybackEpisode(
                contentId: context.parentMetaId,
                contentType: context.contentType,
                videos: context.episodes,
                currentSeason: context.season.map { KotlinInt(int: Int32($0)) },
                currentEpisode: context.episode.map { KotlinInt(int: Int32($0)) }
            )
        } else {
            nextVideo = Self.resolveNextAiredEpisode(
                episodes: context.episodes,
                currentSeason: context.season,
                currentEpisode: context.episode
            )
        }
        if let next = nextVideo {
            nextEpisodeTitle = Self.episodeTitle(next)
        }
    }

    func stop() {
        settingsWatcher?.cancel()
        settingsWatcher = nil
        panelWatch?.cancel()
        panelWatch = nil
        sourcesWatcher?.cancel()
        sourcesWatcher = nil
        tearDownSearch()
    }

    // MARK: - Manual episode jump (player panel)

    /// Jump straight to an arbitrary episode: search its streams and play the auto-selected one
    /// immediately. Reuses the autoplay search/selection machinery without the countdown.
    func jumpToEpisode(_ episode: MetaVideo) {
        guard settings != nil else { return }
        tearDownSearch()
        cancelSourceLoad()
        Self.consecutiveAutoPlays = 0
        cancelled = false
        triggered = true          // the threshold trigger must not re-fire for this session
        // The #2150 re-arm is for the automatic next episode only; after a jump `nextVideo` is the
        // jumped-to episode, so a dismissed jump must never come back at end of file.
        dismissedByUser = false
        rearmedAtEnd = true
        selectedStream = nil
        immediatePlay = true
        nextVideo = episode
        nextEpisodeTitle = Self.episodeTitle(episode)
        beginSearch()
    }

    // MARK: - Source switching (player panel)

    /// Load alternate streams for the video that's playing right now.
    func loadSources() {
        guard !sourcesLoading else { return }
        sourcesLoading = true
        sources = []

        // Reset the shared flow *before* subscribing so the StateFlow replay is the cleared state,
        // not a previous request's results; then subscribe *before* triggering the load so no
        // emission is missed. Late emissions from a superseded request are dropped by generation.
        sourcesWatcher?.cancel()
        PlayerStreamsRepository.shared.clearEpisodeStreams()
        sourceLoadGeneration += 1
        let generation = sourceLoadGeneration

        // The first emission may be the cleared-state replay (empty, not loading) — don't let it
        // end the loading phase before the load has actually produced anything.
        var sawActivity = false
        sourcesWatcher = FlowWatcherKt.watch(PlayerStreamsRepository.shared.episodeStreamsState) { [weak self] emitted in
            guard let self, generation == self.sourceLoadGeneration,
                  let state = emitted as? StreamsUiState else { return }
            self.sources = self.allStreams(state.groups)
            if state.isAnyLoading || !state.groups.isEmpty { sawActivity = true }
            if sawActivity, !state.isAnyLoading { self.sourcesLoading = false }
        }

        PlayerStreamsRepository.shared.loadEpisodeStreams(
            type: context.contentType,
            videoId: context.videoId,
            season: context.season.map { KotlinInt(int: Int32($0)) },
            episode: context.episode.map { KotlinInt(int: Int32($0)) },
            forceRefresh: false
        )
    }

    private func cancelSourceLoad() {
        sourceLoadGeneration += 1
        sourcesWatcher?.cancel()
        sourcesWatcher = nil
        sources = []
        sourcesLoading = false
    }

    /// Switch the current video to a different stream (position resumes via saved watch progress).
    /// Returns false when the stream can't be played at all; true means "handled" — a debrid
    /// stream resolves asynchronously first (the panel may dismiss; playback switches when the
    /// link lands, ~1s for cached torrents, and a failed resolve leaves playback untouched).
    func playSource(_ stream: StreamItem) -> Bool {
        let direct: String? = stream.playableDirectUrl
        if let direct, !direct.isEmpty, let url = URL(string: direct) {
            switchToSource(stream: stream, url: url, listed: stream)
            return true
        }
        guard DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: stream) else { return false }
        let season = context.season.map { KotlinInt(int: Int32($0)) }
        let episode = context.episode.map { KotlinInt(int: Int32($0)) }
        // The `@Throws` twin: a Kotlin exception out of the plain suspend export aborts the process.
        Task { @MainActor [weak self] in
            let result: DirectDebridPlayableResult?
            do {
                result = try await DirectDebridPlaybackResolver.shared.resolveToPlayableStreamChecked(
                    stream: stream, season: season, episode: episode
                )
            } catch {
                print("[UpNext] source switch resolve threw: \(error)")
                result = nil
            }
            guard let self, let success = result as? DirectDebridPlayableResult.Success else { return }
            let resolved: String? = success.stream.playableDirectUrl
            guard let resolved, !resolved.isEmpty, let url = URL(string: resolved) else { return }
            self.switchToSource(stream: success.stream, url: url, listed: stream)
        }
        return true
    }

    /// `listed` is the stream as the source list showed it (pre-resolve): its key is what a failure
    /// is remembered under. The viewer chose it, so the context is `.manual`.
    private func switchToSource(stream: StreamItem, url: URL, listed: StreamItem) {
        Self.consecutiveAutoPlays = 0

        let switched = PlaybackContext(
            url: url,
            title: context.title,
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            season: context.season,
            episode: context.episode,
            poster: context.poster,
            background: context.background,
            providerName: stream.addonName,
            providerAddonId: stream.addonId,
            streamTitle: stream.streamLabel,
            streamSubtitle: { let s: String? = stream.description_; return s }(),
            externalSubtitles: (stream.externalSubtitles).map { sub in
                SubtitleFile(url: sub.url, language: sub.language, name: { let n: String? = sub.name; return n }())
            },
            bingeGroup: { let bg: String? = stream.behaviorHints.bingeGroup; return bg }(),
            episodes: context.episodes,
            synopsis: context.synopsis,
            episodeStill: context.episodeStill,
            meta: context.meta,
            fileSizeBytes: { let n: Int64? = stream.behaviorHints.videoSize?.int64Value; return n }(),
            requestHeaders: StreamModelsKt.sanitizePlaybackHeaders(
                headers: stream.behaviorHints.proxyHeaders?.request),
            launchSource: .manual,
            streamKey: listed.playbackStreamKey,
            listedStream: listed
        )
        onPlayNext(switched)
    }

    private func tearDownSearch() {
        streamsWatcher?.cancel()
        streamsWatcher = nil
        countdownTask?.cancel()
        countdownTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        hideTask?.cancel()
        hideTask = nil
        PlayerStreamsRepository.shared.clearEpisodeStreams()
        // The repository key was just cleared, so the next search is a fresh fetch, not a replay.
        preloaded = false
    }

    // MARK: - Trigger

    /// Called on every player position tick; fires the search once near the end of playback.
    /// The threshold math lives in `NextEpisodeTriggerPolicy` (unchanged from the inline version).
    func onProgress(positionSec: Double, durationSec: Double) {
        lastProgress = (positionSec, durationSec)
        guard nextVideo != nil, durationSec > 0, let trigger else { return }
        if cancelled {
            rearmIfEndedAfterDismiss(positionSec: positionSec, durationSec: durationSec)
            return
        }
        guard !triggered else { return }

        let holdUntilSec = postCreditsHoldUntilSec(durationSec: durationSec)
        let reachesNow = NextEpisodeTriggerPolicy.reachesThreshold(
            positionSec: positionSec, durationSec: durationSec, trigger: trigger,
            holdUntilSec: holdUntilSec, endOfFileSlack: Self.endOfFileSlack
        )

        // FEAT-49 Tier 1 (upstream 22c9ab20): request the next episode's streams one lead window
        // before the card would appear, silently: no phase change, no watcher, no timeout, no
        // subtitle prefetch (the subtitle repository is single-slot and would swap the panel's
        // subs early). Never while the in-player source list owns the shared streams flow.
        if !reachesNow, trigger.preloadEnabled, !preloaded, sourcesWatcher == nil,
           !WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000)) {
            let lead = NextEpisodeTriggerPolicy.preloadLeadSeconds(timeoutSeconds: trigger.autoPlayTimeoutSeconds)
            if NextEpisodeTriggerPolicy.reachesThreshold(
                positionSec: positionSec + lead, durationSec: durationSec, trigger: trigger,
                holdUntilSec: holdUntilSec, endOfFileSlack: Self.endOfFileSlack
            ) {
                preloadNextEpisodeStreams(positionSec: positionSec, durationSec: durationSec, leadSec: lead)
            }
        }

        if reachesNow {
            triggered = true
            beginSearch()
        }
    }

    /// Upstream 77ce8a73: never over a post-credits scene. When the last outro is followed by one
    /// (only when the provider reports an explicit post-credits segment), the shared hold REPLACES
    /// the threshold — it is already max(scene end, user threshold). Within `endOfFileSlack` of
    /// the end still counts as reached (see `NextEpisodeTriggerPolicy.reachesThreshold`).
    private func postCreditsHoldUntilSec(durationSec: Double) -> Double? {
        guard let settings else { return nil }
        guard let hold = PostCreditsHoldKt.nextEpisodeHoldUntilMs(
            intervals: skipIntervals,
            durationMs: Int64(durationSec * 1000),
            thresholdMode: settings.nextEpisodeThresholdMode,
            thresholdPercent: settings.nextEpisodeThresholdPercent,
            thresholdMinutesBeforeEnd: settings.nextEpisodeThresholdMinutesBeforeEnd
        ) else { return nil }
        return Double(hold.int64Value) / 1000.0
    }

    /// Same type / video id / season / episode as `beginSearch()`, so the repository's request
    /// key matches and the later search is a no-op that replays these results.
    private func preloadNextEpisodeStreams(positionSec: Double, durationSec: Double, leadSec: Double) {
        guard let next = nextVideo else { return }
        preloaded = true
        let videoId = Self.episodeVideoId(metaId: context.parentMetaId, episode: next)
        print("[UpNext] preload begin — \(videoId) lead=\(Int(leadSec))s pos=\(Int(positionSec))/\(Int(durationSec))s")
        hooks.loadStreams(context.contentType, videoId, next.season, next.episode)
    }

    // MARK: - #2150 rider: autoplay at end of file after a dismissed card
    //
    // DELIBERATE REVERSAL (Christian, 2026-10-02). tvOS used to keep a Menu dismissal sticky for
    // the whole playback session, modelled on upstream #858 (4026ec92). Upstream #2150 (f0f980b3)
    // changed that: a dismissed card no longer blocks autoplay once the episode really ends. This
    // block adopts #2150. It re-arms once per session (`rearmedAtEnd`), so Menu on the re-armed
    // card sticks; seek/exit cancels never re-arm (only `dismissIfVisible` sets
    // `dismissedByUser`). Gated on `nextVideo != nil` (aired-filtered), not on
    // `streamAutoPlayNextEpisodeEnabled`, which tvOS never reads.
    //
    // To revert to the sticky dismissal, delete: `dismissedByUser`, `rearmedAtEnd` and
    // `lastProgress` (properties), the `if cancelled { … }` block at the top of `onProgress`
    // (restore `!cancelled` to its guard), `rearmIfEndedAfterDismiss`, `isAtEndOfFile`, the
    // `dismissedByUser =` line in `dismissIfVisible`, the two rider lines in `jumpToEpisode`,
    // and `NextEpisodeTriggerPolicy.shouldRearmAfterDismiss` with its tests.
    private func rearmIfEndedAfterDismiss(positionSec: Double, durationSec: Double) {
        // a Menu during the final resolve must not race a second search
        guard !resolvingNext, NextEpisodeTriggerPolicy.shouldRearmAfterDismiss(
            positionSec: positionSec, durationSec: durationSec,
            dismissedByUser: dismissedByUser, alreadyRearmed: rearmedAtEnd,
            endOfFileSlack: Self.endOfFileSlack
        ) else { return }
        rearmedAtEnd = true
        dismissedByUser = false
        cancelled = false
        triggered = true
        selectedStream = nil
        print("[UpNext] re-armed at end of file after a dismissed card")
        beginSearch()
    }

    /// True when the last tick sat within `endOfFileSlack` of the end.
    private var isAtEndOfFile: Bool {
        guard let last = lastProgress, last.durationSec > 0 else { return false }
        return last.positionSec >= last.durationSec - Self.endOfFileSlack
    }

    /// See the post-credits hold in `onProgress`.
    private static let endOfFileSlack: Double = 1.5

    // MARK: - User actions (wired into the Siri-remote handler via MPVPlaybackState)

    /// Down-press while the card is up: play immediately when a stream is ready. Also confirms
    /// the "Still watching?" prompt. Returns true when consumed (so the skip pill doesn't fire).
    func playNow() -> Bool {
        guard let stream = selectedStream, let next = nextVideo else { return false }
        switch phase {
        case .counting, .stillWatching:
            countdownTask?.cancel()
            Self.consecutiveAutoPlays = 0
            play(stream: stream, next: next)
            return true
        default:
            return false
        }
    }

    /// Backward seek / exit: abandon autoplay (or an in-flight jump) for this playback session.
    func cancel() {
        guard triggered || phase != .hidden else { return }
        cancelled = true
        immediatePlay = false
        phase = .hidden
        tearDownSearch()
    }

    /// Menu/back while the up-next chip is up (any non-hidden phase: "Finding source…", the
    /// countdown, "Still watching?", or the no-stream toast): dismiss it for the rest of this
    /// playback session — the sticky `cancelled` flag keeps the threshold from re-firing, which is
    /// the state half of upstream 4026ec92 (#858) tvOS already had; this is the gesture half it
    /// lacked (Menu used to exit the whole player straight through the chip). Returns true when
    /// the press was consumed so the caller does NOT also exit; false when nothing is showing, so
    /// Menu falls through to its normal exit. `.stillWatching` → `.hidden` lets the mpv post-play
    /// cover appear at EOF exactly as after a seek-cancel. Exception since 2026-10-02: the #2150
    /// rider re-arms once at end of file after a dismissal (see `rearmIfEndedAfterDismiss`).
    func dismissIfVisible() -> Bool {
        guard phase != .hidden else { return false }
        // A press is proof someone's watching (the native path has no other reset point).
        Self.consecutiveAutoPlays = 0
        // #2150 rider: only a card dismissed BEFORE the end re-arms at end of file (upstream's
        // effect is keyed on isEnded changing, so a dismissal at EOF stays dismissed), and never
        // "Still watching?" — Menu there means stop, and a re-arm would skip the gate.
        // Only the live card counts: dismissing the no-stream toast must not arm a re-arm.
        switch phase {
        case .searching, .counting: dismissedByUser = !isAtEndOfFile
        default: dismissedByUser = false
        }
        cancel()
        return true
    }

    // MARK: - Search + selection

    private func beginSearch() {
        hooks.searchBegan()
        guard let next = nextVideo, let settings else { return }
        // The search and the source list share the repo's episodeStreamsState flow — never both.
        cancelSourceLoad()
        phase = .searching
        sourceName = nil

        let videoId = Self.episodeVideoId(metaId: context.parentMetaId, episode: next)
        print("[UpNext] search begin — \(videoId) s\(next.season?.stringValue ?? "?")e\(next.episode?.stringValue ?? "?") preloaded=\(preloaded)")
        hooks.loadStreams(context.contentType, videoId, next.season, next.episode)
        // Prefetch the next episode's addon subtitles alongside the stream search — the current
        // session already side-loaded/baked its own subs, and the rebuilt player's fetch call
        // deduplicates against this one.
        SubtitleRepository.shared.fetchAddonSubtitles(type: context.contentType, videoId: videoId)

        streamsWatcher = FlowWatcherKt.watch(PlayerStreamsRepository.shared.episodeStreamsState) { [weak self] emitted in
            guard let self, let state = emitted as? StreamsUiState else { return }
            self.latestStreamsState = state
            print("[UpNext] streams: groups=\(state.groups.count) playable=\(self.allStreams(state.groups).count) loading=\(state.isAnyLoading)")
            self.handleStreams(state, settings: settings)
        }

        // Bounded auto-select timeout (mobile default 3s, clamped 1–30).
        let timeoutSeconds = min(max(Int(settings.streamAutoPlayTimeoutSeconds), 1), 30)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            guard let self, !Task.isCancelled, self.selectedStream == nil, !self.cancelled else { return }
            // At timeout: pick from whatever has arrived so far; if nothing yet and addons are
            // still responding, let the watcher finish the job when loading completes.
            let state = self.latestStreamsState
            let groups = state?.groups ?? []
            print("[UpNext] timeout(\(timeoutSeconds)s): groups=\(groups.count) loading=\(state?.isAnyLoading ?? false)")
            if !groups.isEmpty {
                self.attemptSelection(groups: groups, settings: settings, loadFinished: !(state?.isAnyLoading ?? false))
            }
            // Hard deadline: a hung addon can leave the flow "loading" forever, which used to strand
            // the card at "Finding source…" with no terminal state. Give stragglers a grace window
            // past the soft timeout, then resolve with whatever exists (or "no stream").
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, self.selectedStream == nil, !self.cancelled else { return }
            let late = self.latestStreamsState
            print("[UpNext] hard deadline: groups=\(late?.groups.count ?? 0) loading=\(late?.isAnyLoading ?? false) — resolving")
            self.attemptSelection(groups: late?.groups ?? [], settings: settings, loadFinished: true)
        }
    }

    private func handleStreams(_ state: StreamsUiState, settings: PlayerSettingsUiState) {
        guard selectedStream == nil, !cancelled else { return }
        let groups = state.groups
        if groups.isEmpty && state.isAnyLoading { return }

        if state.isAnyLoading {
            // Early exit while still loading: only for a same-binge-group match (mobile parity).
            attemptBingeGroupOnlySelection(groups: groups, settings: settings)
            // Upstream 58864ec1 (#1825): "still loading" is judged inside the configured auto-play
            // source scope. Once every in-scope source has finished, an out-of-scope source still
            // fetching must neither delay the pick nor be picked — the selector already filters
            // by scope, so a miss here is terminal, not "wait for more". With the default
            // ALL_SOURCES scope this is exactly the old `!isAnyLoading` condition.
            guard selectedStream == nil, !cancelled else { return }
            let scope = effectiveAutoPlaySource(settings)
            if StreamAutoPlayLoadingPolicyKt.areAutoPlaySourcesLoaded(groups, source: scope, installedAddonIds: state.installedAddonIds) {
                print("[UpNext] in-scope sources loaded (\(scope)) while others still fetch — selecting now")
                attemptSelection(groups: groups, settings: settings, loadFinished: true, installedAddonIds: state.installedAddonIds)
            }
        } else {
            attemptSelection(groups: groups, settings: settings, loadFinished: true, installedAddonIds: state.installedAddonIds)
        }
    }

    /// Mobile parity: in MANUAL mode, next-episode/binge settings force first-stream selection over
    /// every source; otherwise the user's configured scope applies. Shared by the loading policy
    /// and the selector so they can never disagree about what "in scope" means.
    private func effectiveAutoPlaySource(_ settings: PlayerSettingsUiState) -> StreamAutoPlaySource {
        let manualAutoSelect = settings.streamAutoPlayMode == StreamAutoPlayMode.manual &&
            (settings.streamAutoPlayNextEpisodeEnabled || settings.streamAutoPlayPreferBingeGroup)
        return manualAutoSelect ? StreamAutoPlaySource.allSources : settings.streamAutoPlaySource
    }

    private func allStreams(_ groups: [AddonStreamGroup]) -> [StreamItem] {
        groups.flatMap { group in
            group.streams.filter {
                let direct: String? = $0.playableDirectUrl
                if !(direct ?? "").isEmpty { return true }
                // Debrid setups: torrent/clientResolve results carry NO direct URL — they resolve
                // to one at play time (exactly like the stream picker's click path). Without this,
                // an all-debrid account always ends in "no stream found" even though every result
                // is instantly playable.
                return DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: $0)
            }
        }
    }

    private func attemptBingeGroupOnlySelection(groups: [AddonStreamGroup], settings: PlayerSettingsUiState) {
        guard settings.streamAutoPlayPreferBingeGroup, context.bingeGroup != nil else { return }
        if let match = select(from: groups, settings: settings, bingeGroupOnly: true,
                              installedAddonIds: latestStreamsState?.installedAddonIds ?? []) {
            didSelect(match)
        }
    }

    private func attemptSelection(groups: [AddonStreamGroup], settings: PlayerSettingsUiState, loadFinished: Bool,
                                  installedAddonIds: Set<String>? = nil) {
        guard selectedStream == nil, !cancelled else { return }
        let installed = installedAddonIds ?? latestStreamsState?.installedAddonIds ?? []
        if let match = select(from: groups, settings: settings, bingeGroupOnly: false, installedAddonIds: installed) {
            didSelect(match)
        } else if loadFinished {
            finishWithoutStream()
        }
    }

    private func select(from groups: [AddonStreamGroup], settings: PlayerSettingsUiState, bingeGroupOnly: Bool,
                        installedAddonIds: Set<String>) -> StreamItem? {
        // Orivio batch item 2: links that failed recently for the episode about to play are never
        // auto-selected again (`RejectedStreamLinks`, keyed like the picker's).
        let rejected: Set<String> = nextVideo.map {
            RejectedStreamLinks.rejected(for: Self.episodeVideoId(metaId: context.parentMetaId, episode: $0))
        } ?? []
        let streams = allStreams(groups).filter { rejected.isEmpty || !rejected.contains($0.playbackStreamKey) }
        guard !streams.isEmpty else { return nil }

        // Mobile parity: in MANUAL mode, next-episode/binge settings force first-stream selection.
        let manualAutoSelect = settings.streamAutoPlayMode == StreamAutoPlayMode.manual &&
            (settings.streamAutoPlayNextEpisodeEnabled || settings.streamAutoPlayPreferBingeGroup)
        // Upstream f2c9b9f9 (beta.12 port): the fallback toggle joins the condition — with
        // "Fallback when binge group fails" OFF, a manual-mode binge-group miss shows the stream
        // picker instead of auto-selecting the first stream (default ON = legacy behavior).
        let bingeGroupOnlyManualMode = manualAutoSelect &&
            (!settings.streamAutoPlayNextEpisodeEnabled ||
                !settings.streamAutoPlayNextEpisodeFallbackEnabled) &&
            settings.streamAutoPlayPreferBingeGroup

        let effectiveMode = manualAutoSelect ? StreamAutoPlayMode.firstStream : settings.streamAutoPlayMode
        let effectiveSource = effectiveAutoPlaySource(settings)
        let effectiveAddons: Set<String> = manualAutoSelect ? [] : settings.streamAutoPlaySelectedAddons
        let effectivePlugins: Set<String> = manualAutoSelect ? [] : settings.streamAutoPlaySelectedPlugins
        let effectiveRegex = manualAutoSelect ? "" : settings.streamAutoPlayRegex
        let preferredBingeGroup: String? = settings.streamAutoPlayPreferBingeGroup ? context.bingeGroup : nil
        // beta.19-rc1 verdict (A, BUG-136): "Auto-Play Best Source" (the user's own FIRST_STREAM
        // mode) ranks the streams that arrived by quality, the same as the stream picker's
        // first-play walk. The mobile-parity forced first-stream (MANUAL mode with the next-episode
        // or binge-group toggles) keeps list order. Kotlin default arguments do not bridge to
        // Swift, so the ranking is passed explicitly.
        let ranking: StreamAutoPlayRanking = (effectiveMode == StreamAutoPlayMode.firstStream && !manualAutoSelect)
            ? StreamAutoPlayPlatform.shared.firstStreamRanking
            : StreamAutoPlayRanking.listOrder

        if bingeGroupOnly && preferredBingeGroup == nil { return nil }

        let debrid = DebridSettingsRepository.shared.snapshot()
        // Only the groups the shared repository marked as installed addons count as "addons" for the
        // source scope; the rest are plugin groups. Previously every group was treated as an installed
        // addon, so INSTALLED_ADDONS_ONLY let plugins through and ENABLED_PLUGINS_ONLY matched nothing.
        // The set is authoritative — an EMPTY set is a valid plugin-only fan-out (Codex r1), not
        // "unknown", so there is deliberately no all-groups fallback.
        let installedAddonNames = Set(groups.filter { installedAddonIds.contains($0.addonId) }.map { $0.addonName })

        return StreamAutoPlaySelector.shared.selectAutoPlayStream(
            streams: streams,
            mode: effectiveMode,
            regexPattern: effectiveRegex,
            source: effectiveSource,
            installedAddonNames: installedAddonNames,
            selectedAddons: effectiveAddons,
            selectedPlugins: effectivePlugins,
            preferredBingeGroup: preferredBingeGroup,
            preferBingeGroupInSelection: settings.streamAutoPlayPreferBingeGroup,
            bingeGroupOnly: bingeGroupOnly || bingeGroupOnlyManualMode,
            debridEnabled: debrid.canResolvePlayableLinks,
            activeResolverProviderId: { let id: String? = debrid.activeResolverProviderId; return id }(),
            ranking: ranking
        )
    }

    private func didSelect(_ stream: StreamItem) {
        guard selectedStream == nil, !cancelled, let next = nextVideo else { return }
        print("[UpNext] selected — \(stream.addonName): \(stream.streamLabel)")
        selectedStream = stream
        sourceName = stream.addonName
        timeoutTask?.cancel()
        streamsWatcher?.cancel()
        streamsWatcher = nil

        // Manual episode jump: play as soon as a stream resolves — no countdown, no
        // Still Watching gate (the jump itself is user interaction).
        if immediatePlay {
            immediatePlay = false
            play(stream: stream, next: next)
            return
        }

        countdownTask = Task { [weak self] in
            for second in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled, !self.cancelled else { return }
                self.phase = .counting(second)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled, !self.cancelled else { return }
            // The countdown finished untouched. If this would be the Nth unattended autoplay in
            // a row, ask instead of playing — a down-press (playNow) resumes and resets the run.
            if Self.consecutiveAutoPlays >= Self.stillWatchingThreshold - 1 {
                self.phase = .stillWatching
                return
            }
            Self.consecutiveAutoPlays += 1
            self.play(stream: stream, next: next)
        }
    }

    private func finishWithoutStream() {
        guard selectedStream == nil, !cancelled else { return }
        print("[UpNext] no stream found")
        timeoutTask?.cancel()
        streamsWatcher?.cancel()
        streamsWatcher = nil
        phase = .noStream
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.phase = .hidden
        }
    }

    private func play(stream: StreamItem, next: MetaVideo) {
        let urlString: String? = stream.playableDirectUrl
        if let urlString, !urlString.isEmpty, let url = URL(string: urlString) {
            phase = .hidden
            onPlayNext(makeNextContext(stream: stream, url: url, next: next, listed: stream))
            return
        }

        // Debrid stream — resolve to a direct link first (picker-click parity). The card keeps its
        // last state during the ~1s resolve; failure resolves to the "no stream" card.
        guard !resolvingNext else { return }
        resolvingNext = true
        print("[UpNext] resolving debrid stream — \(stream.addonName)")
        // The `@Throws` twin: a Kotlin exception out of the plain suspend export aborts the process.
        Task { @MainActor [weak self] in
            let result: DirectDebridPlayableResult?
            do {
                result = try await DirectDebridPlaybackResolver.shared.resolveToPlayableStreamChecked(
                    stream: stream, season: next.season, episode: next.episode
                )
            } catch {
                print("[UpNext] debrid resolve threw: \(error)")
                result = nil
            }
            guard let self else { return }
            self.resolvingNext = false
            guard !self.cancelled else { return }
            if let success = result as? DirectDebridPlayableResult.Success {
                let resolved: String? = success.stream.playableDirectUrl
                if let resolved, !resolved.isEmpty, let url = URL(string: resolved) {
                    print("[UpNext] resolved — playing next episode")
                    self.phase = .hidden
                    self.onPlayNext(self.makeNextContext(stream: success.stream, url: url, next: next, listed: stream))
                    return
                }
            }
            print("[UpNext] debrid resolve failed — \(String(describing: result))")
            self.selectedStream = nil          // reopen finishWithoutStream's guard
            self.finishWithoutStream()
        }
    }

    /// Kotlin-bridged optional strings: blank counts as missing (addons send "" for no still).
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// `listed` is the selected stream before any debrid resolve: its key is what a failure of the
    /// next episode is remembered under (`StreamPickerView` handles the `.nextEpisode` failure).
    private func makeNextContext(stream: StreamItem, url: URL, next: MetaVideo, listed: StreamItem) -> PlaybackContext {
        PlaybackContext(
            url: url,
            title: Self.episodeTitle(next),
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: Self.episodeVideoId(metaId: context.parentMetaId, episode: next),
            season: next.season?.value,
            episode: next.episode?.value,
            poster: context.poster,
            background: context.background,
            providerName: stream.addonName,
            providerAddonId: stream.addonId,
            streamTitle: stream.streamLabel,
            streamSubtitle: { let s: String? = stream.description_; return s }(),
            externalSubtitles: (stream.externalSubtitles).map { sub in
                SubtitleFile(url: sub.url, language: sub.language, name: { let n: String? = sub.name; return n }())
            },
            bingeGroup: { let bg: String? = stream.behaviorHints.bingeGroup; return bg }(),
            episodes: context.episodes,
            // The next episode's own still/overview only — never the previous episode's.
            synopsis: Self.nonEmpty(next.overview),
            episodeStill: Self.nonEmpty(next.thumbnail),
            meta: context.meta,
            fileSizeBytes: { let n: Int64? = stream.behaviorHints.videoSize?.int64Value; return n }(),
            requestHeaders: StreamModelsKt.sanitizePlaybackHeaders(
                headers: stream.behaviorHints.proxyHeaders?.request),
            launchSource: .nextEpisode,
            streamKey: listed.playbackStreamKey,
            listedStream: listed
        )
    }

    // MARK: - Episode resolution (Swift port of mobile's PlayerNextEpisodeRules)

    static func resolveNextAiredEpisode(episodes: [MetaVideo], currentSeason: Int?, currentEpisode: Int?) -> MetaVideo? {
        guard let currentSeason, let currentEpisode else { return nil }
        let sorted = episodes
            .compactMap { video -> (MetaVideo, Int, Int)? in
                guard let s = video.season?.value, let e = video.episode?.value else { return nil }
                return (video, s, e)
            }
            .sorted { a, b in a.1 == b.1 ? a.2 < b.2 : a.1 < b.1 }

        guard let index = sorted.firstIndex(where: { $0.1 == currentSeason && $0.2 == currentEpisode }),
              index + 1 < sorted.count
        else { return nil }

        let next = sorted[index + 1].0
        let released: String? = next.released
        return hasAired(released) ? next : nil
    }

    /// Treats missing/unparseable dates as aired (mobile behavior). Delegates to the shared
    /// core/time parser so zoned timestamps compare as real instants and date-only values use
    /// UTC midnight — the old Swift port compared local calendar dates and mis-gated episodes
    /// around midnight/timezone boundaries (fixed upstream in v0.3.0; kept in sync here).
    static func hasAired(_ raw: String?) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return EpisodeReleaseDateParserKt.isEpisodeReleaseAired(raw: raw, nowEpochMs: nowMs)?.boolValue ?? true
    }

    // MARK: - Formatting (matches EpisodesSection so watch-progress keys stay consistent)

    static func episodeVideoId(metaId: String, episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return "\(metaId):\(s):\(e)"
        }
        return episode.id
    }

    static func episodeTitle(_ episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return "S\(s)E\(e) \u{00B7} \(episode.title)"
        }
        return episode.title
    }
}

extension NextEpisodeEngine.TriggerSettings {
    init(settings: PlayerSettingsUiState) {
        self.init(
            percentageMode: settings.nextEpisodeThresholdMode == NextEpisodeThresholdMode.percentage,
            thresholdPercent: Double(settings.nextEpisodeThresholdPercent),
            thresholdMinutesBeforeEnd: Double(settings.nextEpisodeThresholdMinutesBeforeEnd),
            autoPlayTimeoutSeconds: Int(settings.streamAutoPlayTimeoutSeconds),
            preloadEnabled: settings.preloadNextEpisodeSources
        )
    }
}

/// Pure trigger decisions for `NextEpisodeEngine` (unit-tested in `NextEpisodeEngineTests`).
enum NextEpisodeTriggerPolicy {
    /// The up-next threshold, verbatim from the pre-FEAT-49 `onProgress`: percentage clamped to
    /// 97–100, minutes-before-end clamped to 0–3.5. A non-nil post-credits hold REPLACES the
    /// threshold, and within `endOfFileSlack` of the end counts as reached (upstream's
    /// `isEnded ||`: the position at EOF can sit a frame short of the duration).
    static func reachesThreshold(positionSec: Double, durationSec: Double,
                                 trigger: NextEpisodeEngine.TriggerSettings,
                                 holdUntilSec: Double?, endOfFileSlack: Double) -> Bool {
        if let holdUntilSec {
            // Compared in whole milliseconds, as the inline version did against the Kotlin Long.
            let holdMs = Int64((holdUntilSec * 1000).rounded())
            return Int64(positionSec * 1000) >= holdMs || positionSec >= durationSec - endOfFileSlack
        }
        if trigger.percentageMode {
            let percent = min(max(trigger.thresholdPercent, 97), 100)
            return positionSec / durationSec >= percent / 100.0
        }
        let minutes = min(max(trigger.thresholdMinutesBeforeEnd, 0), 3.5)
        return (durationSec - positionSec) <= minutes * 60.0
    }

    /// How far ahead of the threshold the preload fires: one auto-play timeout window (upstream),
    /// floored at 30 s. tvOS has no timeout row, so this is 30 s in practice.
    static func preloadLeadSeconds(timeoutSeconds: Int) -> Double {
        max(Double(timeoutSeconds), 30)
    }

    /// #2150 rider: re-arm once, at end of file, after a Menu dismissal.
    static func shouldRearmAfterDismiss(positionSec: Double, durationSec: Double,
                                        dismissedByUser: Bool, alreadyRearmed: Bool,
                                        endOfFileSlack: Double) -> Bool {
        guard dismissedByUser, !alreadyRearmed, durationSec > 0 else { return false }
        return positionSec >= durationSec - endOfFileSlack
    }
}
