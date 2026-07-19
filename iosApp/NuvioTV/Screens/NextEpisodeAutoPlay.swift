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
/// threshold.
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

    private let context: PlaybackContext
    private let onPlayNext: (PlaybackContext) -> Void

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
    private var settingsWatcher: FlowWatcher?
    private var streamsWatcher: FlowWatcher?
    private var countdownTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    private var nextVideo: MetaVideo?
    private var triggered = false
    private var cancelled = false
    private var selectedStream: StreamItem?
    /// A debrid resolve for the selected next-episode stream is in flight (play-time resolution).
    private var resolvingNext = false
    /// Latest emission from `episodeStreamsState` (the exported StateFlow has no sync `.value`).
    private var latestStreamsState: StreamsUiState?

    init(context: PlaybackContext, onPlayNext: @escaping (PlaybackContext) -> Void) {
        self.context = context
        self.onPlayNext = onPlayNext
    }

    // MARK: - Lifecycle

    /// Wires the mpv player state's up-next hooks and resolves the next aired episode (if any).
    func start(state: MPVPlaybackState) {
        prime()
        state.upNextPlayNow = { [weak self] in self?.playNow() ?? false }
        state.upNextCancel = { [weak self] in self?.cancel() }
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
        }

        nextVideo = Self.resolveNextAiredEpisode(
            episodes: context.episodes,
            currentSeason: context.season,
            currentEpisode: context.episode
        )
        if let next = nextVideo {
            nextEpisodeTitle = Self.episodeTitle(next)
        }
    }

    func stop() {
        settingsWatcher?.cancel()
        settingsWatcher = nil
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
            switchToSource(stream: stream, url: url)
            return true
        }
        guard DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: stream) else { return false }
        DirectDebridPlaybackResolver.shared.resolveToPlayableStream(
            stream: stream,
            season: context.season.map { KotlinInt(int: Int32($0)) },
            episode: context.episode.map { KotlinInt(int: Int32($0)) }
        ) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self, let success = result as? DirectDebridPlayableResult.Success else { return }
                let resolved: String? = success.stream.playableDirectUrl
                guard let resolved, !resolved.isEmpty, let url = URL(string: resolved) else { return }
                self.switchToSource(stream: success.stream, url: url)
            }
        }
        return true
    }

    private func switchToSource(stream: StreamItem, url: URL) {
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
            episodes: context.episodes
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
    }

    // MARK: - Trigger

    /// Called on every player position tick; fires the search once near the end of playback.
    func onProgress(positionSec: Double, durationSec: Double) {
        guard !triggered, !cancelled, nextVideo != nil, durationSec > 0 else { return }
        guard let settings else { return }

        let shouldTrigger: Bool
        if settings.nextEpisodeThresholdMode == NextEpisodeThresholdMode.percentage {
            let percent = min(max(Double(settings.nextEpisodeThresholdPercent), 97), 100)
            shouldTrigger = positionSec / durationSec >= percent / 100.0
        } else {
            let minutes = min(max(Double(settings.nextEpisodeThresholdMinutesBeforeEnd), 0), 3.5)
            shouldTrigger = (durationSec - positionSec) <= minutes * 60.0
        }

        if shouldTrigger {
            triggered = true
            beginSearch()
        }
    }

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

    // MARK: - Search + selection

    private func beginSearch() {
        guard let next = nextVideo, let settings else { return }
        // The search and the source list share the repo's episodeStreamsState flow — never both.
        cancelSourceLoad()
        phase = .searching
        sourceName = nil

        let videoId = Self.episodeVideoId(metaId: context.parentMetaId, episode: next)
        print("[UpNext] search begin — \(videoId) s\(next.season?.stringValue ?? "?")e\(next.episode?.stringValue ?? "?")")
        PlayerStreamsRepository.shared.loadEpisodeStreams(
            type: context.contentType,
            videoId: videoId,
            season: next.season,
            episode: next.episode,
            forceRefresh: false
        )

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
        } else {
            attemptSelection(groups: groups, settings: settings, loadFinished: true)
        }
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
        if let match = select(from: groups, settings: settings, bingeGroupOnly: true) {
            didSelect(match)
        }
    }

    private func attemptSelection(groups: [AddonStreamGroup], settings: PlayerSettingsUiState, loadFinished: Bool) {
        guard selectedStream == nil, !cancelled else { return }
        if let match = select(from: groups, settings: settings, bingeGroupOnly: false) {
            didSelect(match)
        } else if loadFinished {
            finishWithoutStream()
        }
    }

    private func select(from groups: [AddonStreamGroup], settings: PlayerSettingsUiState, bingeGroupOnly: Bool) -> StreamItem? {
        let streams = allStreams(groups)
        guard !streams.isEmpty else { return nil }

        // Mobile parity: in MANUAL mode, next-episode/binge settings force first-stream selection.
        let manualAutoSelect = settings.streamAutoPlayMode == StreamAutoPlayMode.manual &&
            (settings.streamAutoPlayNextEpisodeEnabled || settings.streamAutoPlayPreferBingeGroup)
        let bingeGroupOnlyManualMode = manualAutoSelect &&
            !settings.streamAutoPlayNextEpisodeEnabled &&
            settings.streamAutoPlayPreferBingeGroup

        let effectiveMode = manualAutoSelect ? StreamAutoPlayMode.firstStream : settings.streamAutoPlayMode
        let effectiveSource = manualAutoSelect ? StreamAutoPlaySource.allSources : settings.streamAutoPlaySource
        let effectiveAddons: Set<String> = manualAutoSelect ? [] : settings.streamAutoPlaySelectedAddons
        let effectivePlugins: Set<String> = manualAutoSelect ? [] : settings.streamAutoPlaySelectedPlugins
        let effectiveRegex = manualAutoSelect ? "" : settings.streamAutoPlayRegex
        let preferredBingeGroup: String? = settings.streamAutoPlayPreferBingeGroup ? context.bingeGroup : nil

        if bingeGroupOnly && preferredBingeGroup == nil { return nil }

        let debrid = DebridSettingsRepository.shared.snapshot()
        let installedAddonNames = Set(groups.map { $0.addonName })

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
            activeResolverProviderId: { let id: String? = debrid.activeResolverProviderId; return id }()
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
            onPlayNext(makeNextContext(stream: stream, url: url, next: next))
            return
        }

        // Debrid stream — resolve to a direct link first (picker-click parity). The card keeps its
        // last state during the ~1s resolve; failure resolves to the "no stream" card.
        guard !resolvingNext else { return }
        resolvingNext = true
        print("[UpNext] resolving debrid stream — \(stream.addonName)")
        DirectDebridPlaybackResolver.shared.resolveToPlayableStream(
            stream: stream,
            season: next.season,
            episode: next.episode
        ) { [weak self] result, _ in
            // Kotlin suspend completions can land off-main; hop before touching engine state.
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolvingNext = false
                guard !self.cancelled else { return }
                if let success = result as? DirectDebridPlayableResult.Success {
                    let resolved: String? = success.stream.playableDirectUrl
                    if let resolved, !resolved.isEmpty, let url = URL(string: resolved) {
                        print("[UpNext] resolved — playing next episode")
                        self.phase = .hidden
                        self.onPlayNext(self.makeNextContext(stream: success.stream, url: url, next: next))
                        return
                    }
                }
                print("[UpNext] debrid resolve failed — \(String(describing: result))")
                self.selectedStream = nil          // reopen finishWithoutStream's guard
                self.finishWithoutStream()
            }
        }
    }

    private func makeNextContext(stream: StreamItem, url: URL, next: MetaVideo) -> PlaybackContext {
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
            episodes: context.episodes
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

/// Bottom-trailing "Up Next" card shown by the player near the end of an episode.
struct UpNextCard: View {
    @ObservedObject var engine: NextEpisodeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up Next")
                .font(.caption).bold()
                .foregroundStyle(.white.opacity(0.7))
            Text(engine.nextEpisodeTitle)
                .font(.title3).bold()
                .foregroundStyle(.white)
                .lineLimit(1)

            switch engine.phase {
            case .searching:
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("Finding stream\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                }
            case .counting(let seconds):
                HStack(spacing: 10) {
                    Image(systemName: "chevron.down.circle.fill")
                    Text("Playing in \(seconds)\u{2026} press \u{2193} to play now")
                        .font(.callout)
                }
                .foregroundStyle(.white.opacity(0.9))
                if let source = engine.sourceName {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            case .stillWatching:
                HStack(spacing: 10) {
                    Image(systemName: "chevron.down.circle.fill")
                    Text("Still watching? Press \u{2193} to continue")
                        .font(.callout)
                }
                .foregroundStyle(.white.opacity(0.9))
            case .noStream:
                Text("No stream found for the next episode.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
            case .hidden:
                EmptyView()
            }
        }
        .padding(24)
        .frame(maxWidth: 620, alignment: .leading)
        // Liquid Glass over the playing video; the dark tint keeps text readable on bright scenes.
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Theme.Palette.accent.opacity(0.5), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}
