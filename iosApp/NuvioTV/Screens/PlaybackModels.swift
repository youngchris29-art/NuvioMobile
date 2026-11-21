import CryptoKit
import Foundation
import SharedCore

// Engine-agnostic playback models shared by every player engine (libmpv today; the native
// AVPlayer path added in later phases). Extracted from MPVPlayerView.swift in Phase 0 of the
// hybrid-player work so both engines — and the router/prober — depend on one set of types.
// See docs/tvos-hybrid-player-plan.md.

/// UserDefaults keys for device-local player tuning (Settings > Playback). Device-specific
/// hardware knobs, deliberately NOT synced.
enum PlayerTuning {
    static let bufferMBKey = "player.bufferMB"
    static let readaheadSecKey = "player.readaheadSec"
    static let matchFrameRateKey = "player.matchFrameRate"
    /// Opt into mpv's `gpu-next` (libplacebo) video output for better HDR tone-mapping. Device-only
    /// (never applied on the simulator, where libplacebo's vo asserts). Applies to the next playback.
    static let enhancedRendererKey = "player.enhancedRenderer"
    /// Route Dolby Vision / native-friendly files to the AVPlayer engine for true DV output.
    /// ON by default since beta.13 (registered in NuvioTVApp.init; docs/tvos-native-player-info-panel-plan.md);
    /// gates all engine routing.
    static let nativeDVKey = "player.nativeDolbyVision"
    /// Sub-setting of the native-DV beta: keep DV Profile 7 FEL files on mpv instead of converting
    /// them to 8.1 (the conversion discards FEL enhancement data; MEL converts losslessly and is
    /// unaffected by this preference).
    static let dvP7FelMpvKey = "player.dvP7FelPreferMpv"
    /// What holding Left/Right does in the mpv player: "step" (default) or "scan". Device-local.
    static let holdModeKey = "player.holdMode"
    /// What one click on Left/Right does in the mpv player: "skip10" (default) or "chapter". Device-local.
    static let edgeClickModeKey = "player.edgeClickMode"
    /// Show the time of day while the mpv player controls are up. Device-local, off by default.
    static let showClockKey = "player.showClock"
    /// "Show cast in player" (Insights, 2026-11-01): the Cast pill on both engines. Device-local, on by default.
    static let showCastInPlayerKey = "player.showCastInPlayer"
    static var showCastInPlayer: Bool {
        UserDefaults.standard.object(forKey: showCastInPlayerKey) as? Bool ?? true
    }
    /// mpv only: extra loudness in dB (0, 2, 4, 6, 8, 10). Device-local, default 0.
    static let boostDbKey = "player.boostDb"
    /// mpv only: "off" (default) or "dialogue". Device-local.
    static let audioModeKey = "player.audioMode"
}

// MARK: - Aether (Phase 1)

/// Device-local keys for the experimental Aether engine (Settings > Playback). Like the rest of
/// `PlayerTuning` these are hardware knobs and are never synced. Defaults are applied at read time
/// (`AetherTuning`), so no `register(defaults:)` call is needed.
extension PlayerTuning {
    static let aetherEngineKey = "player.aetherEngine"
    static let aetherObjectAudioKey = "player.aetherObjectAudio"
    static let aetherObjectAudioLayoutKey = "player.aetherObjectAudioLayout"
    static let aetherDualLayerDVKey = "player.aetherDualLayerDV"
    static let aetherStyledSubsToMpvKey = "player.aetherStyledSubsToMpv"
    static let aetherLosslessBridgeKey = "player.aetherLosslessBridge"
    /// Aether disk cache (GitHub #29): 0 Off (default), 5, 10, 20 GB, -1 Maximum. Device-local, never
    /// synced, not in the sign-out wipe (a hardware knob like `bufferMBKey`). Read once per fresh load.
    static let diskCacheGBKey = "player.diskCacheGB"
}

/// Defaults and readers for the Aether settings. A missing key reads as its default, so the
/// settings model and the router agree without registering defaults at launch.
nonisolated enum AetherTuning {
    static let defaultLayout = "7.1.4"
    static let layouts = ["5.1.2", "5.1.4", "7.1.2", "7.1.4", "9.1.6"]

    static func bool(_ key: String, default value: Bool, defaults: UserDefaults = .standard) -> Bool {
        // bool(forKey:) coerces launch-argument strings ("YES", "1", "true") that `as? Bool` rejects.
        defaults.object(forKey: key) != nil ? defaults.bool(forKey: key) : value
    }

    static func layout(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: PlayerTuning.aetherObjectAudioLayoutKey) ?? defaultLayout
        return layouts.contains(stored) ? stored : defaultLayout
    }

    static func isEngineEnabled(defaults: UserDefaults = .standard) -> Bool {
        bool(PlayerTuning.aetherEngineKey, default: false, defaults: defaults)
    }
    static func isObjectAudioEnabled(defaults: UserDefaults = .standard) -> Bool {
        bool(PlayerTuning.aetherObjectAudioKey, default: false, defaults: defaults)
    }
    static func isDualLayerDVEnabled(defaults: UserDefaults = .standard) -> Bool {
        bool(PlayerTuning.aetherDualLayerDVKey, default: false, defaults: defaults)
    }
    static func keepStyledSubsOnMpv(defaults: UserDefaults = .standard) -> Bool {
        bool(PlayerTuning.aetherStyledSubsToMpvKey, default: true, defaults: defaults)
    }
    static func isLosslessBridgeEnabled(defaults: UserDefaults = .standard) -> Bool {
        bool(PlayerTuning.aetherLosslessBridgeKey, default: true, defaults: defaults)
    }
    /// The stored Disk Cache choice. A missing key reads 0 = Off; any value that is not a choice reads Off.
    static func diskCacheChoice(defaults: UserDefaults = .standard) -> AetherDiskCacheChoice {
        AetherDiskCacheChoice(rawValue: defaults.integer(forKey: PlayerTuning.diskCacheGBKey))
    }
}

/// Everything the player needs to render a stream and record watch progress for it.
struct PlaybackContext: Identifiable {
    let url: URL
    let title: String
    let contentType: String      // "movie" / "series"
    let parentMetaId: String
    let videoId: String
    let season: Int?
    let episode: Int?
    let poster: String?
    let background: String?
    let providerName: String?
    let providerAddonId: String?
    let streamTitle: String?
    let streamSubtitle: String?
    let externalSubtitles: [SubtitleFile]
    /// Binge group of the playing stream (steers next-episode auto-select toward the same release).
    var bingeGroup: String? = nil
    /// All episodes of the parent series (empty for movies) — enables next-episode autoplay.
    var episodes: [MetaVideo] = []
    /// Title/episode synopsis for the native player's Info tab header (nil when the launch path
    /// has no meta at hand — the header simply omits it).
    var synopsis: String? = nil
    /// 16:9 episode still for the native player's Info tab header. Kept apart from `poster`,
    /// which stays the catalog/series poster (the progress recorder persists `poster` as the
    /// parent artwork — a still must never leak into it). nil → the header shows `poster`.
    var episodeStill: String? = nil
    /// BUG-184 (Steven, 2026-10-19: "the title logo pulsing on the loading screen is always in
    /// English"): the title logo the opening screen shows (Detail's, TMDB-localized when TMDB is
    /// on), for the loading overlay. nil falls back to metahub's English logo.
    var logo: String? = nil
    /// Catalog metadata for the player's Info tab chip row (year · runtime · rating · genres). nil
    /// when the launch path has no meta at hand — the chips simply omit them.
    var meta: PlaybackMeta? = nil
    /// Declared file size of the playing stream (addon `behaviorHints.videoSize`), for the Info chips.
    var fileSizeBytes: Int64? = nil
    /// `behaviorHints.filename` of the playing stream. With `fileSizeBytes` and `videoHash` it goes
    /// out as the add-on subtitle request's extras (`subtitleRequestExtras`); when nil the shared
    /// helper falls back to the URL's last path segment.
    var streamFilename: String? = nil
    /// `behaviorHints.videoHash` (OpenSubtitles hash) when the add-on declared one. nil → the
    /// player computes it lazily from the resolved URL (`fetchAddonSubtitlesForPlayback`).
    var videoHash: String? = nil
    /// `behaviorHints.audioDelayMs` of the playing stream (P5 N1), already clamped to ±60 s. mpv only.
    var streamAudioDelayMs: Int? = nil
    /// Sanitized HTTP request headers the addon declared for this stream
    /// (`behaviorHints.proxyHeaders.request` via shared `sanitizePlaybackHeaders` — Referer /
    /// User-Agent a scraper CDN requires; GitHub issue #2 "Some video no stream"). Empty for the
    /// overwhelming majority of streams. Consumed by BOTH engines: mpv (`http-header-fields`)
    /// and the native path's FFmpeg source opens (MediaProbe + RemuxSession `headers` option).
    var requestHeaders: [String: String] = [:]
    /// Who started this playback (orivio batch item 2): a viewer's own pick, the picker's
    /// first-play auto-start, or the Up Next engine. Decides what a playback failure does next
    /// (`PlaybackFailoverPolicy.response(for:)`), and the engines treat a placeholder clip as a
    /// failure only outside `.manual`.
    var launchSource: PlaybackLaunchSource = .manual
    /// `StreamItem.playbackStreamKey` of the stream as LISTED (before any debrid resolve), so a
    /// failure can be remembered against the link the pickers will see again. Empty for the test
    /// stream and launch paths without a stream (Library, smoke tests): those are never remembered.
    var streamKey: String = ""
    /// "Start Over": both engines ignore saved progress for this playback.
    var startFromBeginning: Bool = false
    /// Failover attempt index for this visit (0 = first try). Joins `id` only when > 0, so two
    /// candidates that resolve to the same URL still rebuild the player (and re-key the cover).
    var attempt: Int = 0
    /// The stream as listed (pre-resolve), so a failed debrid link's 15-minute resolve cache entry
    /// can be dropped (`DirectDebridPlaybackResolver.invalidate` is keyed on the listed stream).
    /// nil on launch paths without a stream.
    var listedStream: StreamItem? = nil
    /// W4 (upstream ff7500fdd): set on an Up Next hand-off and on every in-place fallback of one:
    /// the sources auto selection tried for this episode before the one playing (its own key
    /// included; shared's opaque keys, never built here) and how many further ones it moved to. The
    /// in-player fallback goes on from it, so the budget is per episode. Nil on every source the
    /// viewer picked.
    var sourceFallback: PlayerSourceFallbackTried? = nil
    /// Failure-alert retry ("Try with mpv" / "Try Native Player"): pins the engine for this attempt.
    var forcedEngine: PlaybackEngine? = nil
    /// Failure-alert retry: both engines resume from here instead of the saved progress (> 10 s).
    var resumeAtSec: Double? = nil
    /// Batch D U2: `url` was resolved on this device from an add-on `ytId`-only stream and expires
    /// within hours, so it is session-only — neither engine writes it to the watch-progress
    /// entry's `lastSourceUrl` (the field mobile's "reuse last link" reads back), see
    /// `persistedSourceUrl`. The stream's identity for the failover memory is its `yt:` key.
    var sessionOnlySourceUrl: Bool = false

    /// What the progress writers store as `lastSourceUrl`: the playing URL, or nil for a
    /// session-only link (`sessionOnlySourceUrl`).
    var persistedSourceUrl: String? { sessionOnlySourceUrl ? nil : url.absoluteString }

    /// File extras for the add-on subtitle request (`subtitles/<type>/<id>/<extras>.json`):
    /// filename (URL basename fallback), declared size and hash. nil when nothing usable, and for
    /// local `file:` playback (shared `SubtitleRequestExtras.of`).
    var subtitleRequestExtras: SubtitleRequestExtras? {
        SubtitleRequestExtras.companion.of(
            filename: streamFilename,
            videoSize: fileSizeBytes.map { KotlinLong(value: $0) },
            videoHash: videoHash,
            sourceUrl: url.absoluteString)
    }

    /// Kick the add-on subtitle fetch for this playback, the call every player makes at start.
    /// Sends `subtitleRequestExtras` right away, then — when no hash was declared and `url` is a
    /// remote http(s) file — computes the OpenSubtitles hash from two 64 KiB range requests
    /// (with this stream's `requestHeaders`) and re-queries the add-ons with it. `url` is the
    /// resolved URL (debrid links are resolved before the context is built). Completion is still
    /// signalled on `SubtitleRepository.requestKey(type:videoId:)`, extras or not.
    func fetchAddonSubtitlesForPlayback() {
        SubtitleRepository.shared.fetchAddonSubtitlesWithHashComputation(
            type: contentType,
            videoId: videoId,
            extras: subtitleRequestExtras,
            sourceUrl: url.absoluteString,
            sourceHeaders: requestHeaders)
    }

    // Headers join the identity (Codex 2026-08-20 round 3): two sources for the same episode can
    // share a URL but require different headers; StreamPickerView rebuilds the player and
    // PlayerScreen re-keys its probe on this id, so header changes must re-key too or a stale
    // controller keeps the old headers and an auth-gated stream 403s. The joins use ASCII unit /
    // record separators, which `sanitizePlaybackHeaders` guarantees can never appear in a key or
    // value (it rejects all control characters), so the fingerprint is unambiguous — a plain
    // "&"/"=" join could collide on values containing those characters (Codex round 4).
    var id: String {
        let headerFingerprint = requestHeaders.isEmpty
            ? ""
            : "|" + requestHeaders
                .sorted { $0.key < $1.key }
                .map { "\($0.key)\u{1F}\($0.value)" }
                .joined(separator: "\u{1E}")
        let attemptSuffix = attempt > 0 ? "|a\(attempt)" : ""
        return "\(videoId)|\(url.absoluteString)\(headerFingerprint)\(attemptSuffix)"
    }
}

extension PlaybackContext {
    /// W4: the same episode on another source (an in-place fallback). Stream fields come from
    /// `stream` (the resolved one) and `listed` (as listed: the failure memory's key); the episode,
    /// artwork, Start Over and launch source stay. `resumeAtSec` is where the replacement starts
    /// (nil keeps this context's own rule: saved progress, or Start Over); `attempt` keeps the two
    /// contexts' ids apart, so the player is rebuilt even when both resolve to one URL.
    func replacingSource(stream: StreamItem, url: URL, listed: StreamItem, attempt: Int,
                         sourceFallback: PlayerSourceFallbackTried?, resumeAtSec: Double?) -> PlaybackContext {
        var next = PlaybackContext(
            url: url,
            title: title,
            contentType: contentType,
            parentMetaId: parentMetaId,
            videoId: videoId,
            season: season,
            episode: episode,
            poster: poster,
            background: background,
            providerName: stream.addonName,
            providerAddonId: stream.addonId,
            streamTitle: stream.streamLabel,
            streamSubtitle: { let s: String? = stream.description_; return s }(),
            externalSubtitles: stream.externalSubtitles.map { sub in
                SubtitleFile(url: sub.url, language: sub.language, name: { let n: String? = sub.name; return n }())
            },
            bingeGroup: { let bg: String? = stream.behaviorHints.bingeGroup; return bg }(),
            episodes: episodes,
            synopsis: synopsis,
            episodeStill: episodeStill,
            logo: logo,
            meta: meta,
            fileSizeBytes: { let n: Int64? = stream.behaviorHints.videoSize?.int64Value; return n }(),
            streamFilename: { let f: String? = stream.behaviorHints.filename; return f }(),
            videoHash: { let h: String? = stream.behaviorHints.videoHash; return h }(),
            streamAudioDelayMs: { let n: Int? = stream.behaviorHints.audioDelayMs?.intValue; return n }(),
            requestHeaders: StreamModelsKt.sanitizePlaybackHeaders(headers: stream.behaviorHints.proxyHeaders?.request),
            launchSource: launchSource,
            streamKey: listed.playbackStreamKey,
            startFromBeginning: startFromBeginning,
            attempt: attempt,
            listedStream: listed,
            // Auto selection never picks a ytId-only stream; kept for the rule's sake.
            sessionOnlySourceUrl: StreamPickerView.isYouTubeResolved(listed)
        )
        next.sourceFallback = sourceFallback
        next.resumeAtSec = resumeAtSec ?? self.resumeAtSec
        return next
    }
}

/// W4 review r1: "what the viewer last asked for", as a generation. Every choice of the viewer's own
/// (a source picked in the list or in the player's Sources panel, even one still resolving; Menu or
/// close; an episode jump; Play Next; Up Next's hand-off) bumps it. An automatic walk (first-play
/// failover, the in-player episode walk) takes a ticket when it starts, and every event of it
/// (`.play`, `.gaveUp`, a late refresh, its candidate load) is applied only while the ticket is still
/// current: the viewer's choice wins even before `selected` has changed. While a choice is pending
/// (asked for, not on screen yet) no automatic walk starts for the context still on screen.
struct AutoWalkIntentGate: Equatable {
    private(set) var generation = 0
    private(set) var presentedGeneration = 0

    /// The viewer chose something.
    mutating func viewerChose() { generation += 1 }
    /// A context went on screen (or the player closed): it is what the viewer last asked for.
    mutating func contextPresented() { presentedGeneration = generation }

    /// The ticket a walk started now carries.
    var ticket: Int { generation }
    /// The viewer asked for something the screen does not show yet (a pick still resolving).
    var viewerChoicePending: Bool { generation != presentedGeneration }
    /// May an automatic walk start (or react) for the context on screen?
    var allowsAutomaticWalk: Bool { !viewerChoicePending }
    /// Is an event of the walk holding `ticket` still allowed to change the screen?
    func accepts(_ ticket: Int?) -> Bool {
        guard let ticket else { return false }
        return ticket == generation && !viewerChoicePending
    }

    /// A walk's `.play` swap: its ticket is current and the context it replaces (when known) is
    /// still the one presented.
    func admitsSwap(ticket: Int?, replacing: String?, presented: String?) -> Bool {
        guard accepts(ticket) else { return false }
        guard let replacing else { return true }
        return replacing == presented
    }
}

/// Who started a playback (see `PlaybackContext.launchSource`).
enum PlaybackLaunchSource: Equatable {
    /// The viewer picked the stream (a picker row, "Try Next Source", the in-player source list).
    case manual
    /// The stream picker's first-play auto-start (`FirstPlayAutoPlayController`).
    case autoPlay
    /// The Up Next engine's next episode (`NextEpisodeEngine.makeNextContext`).
    case nextEpisode
}

/// A playback that failed, as reported by either engine through `PlayerScreen.onPlaybackFailed`:
/// the media never started, mpv hit a load error, a placeholder clip played in an automatic flow,
/// or the stream ended well before its duration.
struct PlaybackFailure: Equatable {
    /// Engine-side diagnostic, shown verbatim in the manual-pick alert.
    let reason: String
    let positionSec: Double
    /// Seconds actually played (native seconds before a fallback included).
    let secondsPlayed: Double
    let startedPlaying: Bool
    /// Which engine reported it (set by `PlayerScreen`).
    var engine: PlaybackEngine = .mpv
    /// The other engine could take this stream: the failure alert offers it as a retry.
    var otherEngineEligible = false
    /// What kind of failure the producer saw (P4, BUG-143). Only kinds whose `remembersLink` is
    /// true may put the link into the rejected-link memory; producers set it.
    var kind: PlaybackFailureKind = .unknown
    /// The HTTP status behind a `.http` failure, when known. Log / diagnostic only.
    var httpStatus: Int? = nil
}

/// Classified cause of a playback failure (P4, BUG-143). The first group is positive evidence
/// against the link and is remembered; the second is about the viewer's network or our own
/// engine and is never remembered.
enum PlaybackFailureKind: String, Equatable, Sendable {
    // Remembered.
    case http, decode, placeholder, endedEarly, noMedia, unknown
    // Not remembered. `.local` = our own engine failed (the B17 item rebuild). `.startTimeout`
    // (W4) = an auto-picked source passed the start-up limit with no first frame: slow is not
    // proof of dead (the BUG-143 rule), so it is never remembered and its resolve is kept.
    case network, offline, cancelled, local, startTimeout

    var remembersLink: Bool {
        switch self {
        case .network, .offline, .cancelled, .local, .startTimeout: false
        default: true
        }
    }
}

/// Startup stage shown by the loading overlay (P4, B24). Declared here so the native coordinator
/// can publish it; `Screens/Player/PlayerLoadingOverlay.swift` adds the views and status text.
enum PlayerLoadingStage: Equatable {
    /// `PlayerScreen` `.deciding` (MediaProbe).
    case checking
    /// Native: remux opening. mpv: loadfile → FILE_LOADED.
    case connecting
    /// Native: signaling known, waiting for map / init / first segment.
    case preparing(dolbyVision: Bool)
    /// Native: holding for the add-on subtitle fetch.
    case subtitles
    /// Native: item not playing yet. mpv: FILE_LOADED → first PLAYBACK_RESTART.
    case buffering(percent: Int?)
    /// The overlay fades out.
    case started

    /// Short token for logs and the DEBUG history label (`buffering(42)`, `preparing(dv)`).
    var logToken: String {
        switch self {
        case .checking: "checking"
        case .connecting: "connecting"
        case .preparing(let dv): dv ? "preparing(dv)" : "preparing"
        case .subtitles: "subtitles"
        case .buffering(let p): p.map { "buffering(\($0))" } ?? "buffering"
        case .started: "started"
        }
    }
}

/// The pure decisions behind next-link failover (orivio batch item 2). The picker and the Up Next
/// engine act on these; `PlaybackFailoverPolicyTests` pins them.
enum PlaybackFailoverPolicy {
    /// A link that played this long is healthy: its failure is not remembered, and reaching it
    /// clears an earlier rejection (`RejectedStreamLinks.keep`).
    static let healthySeconds: Double = 300

    /// Attempts an automatic flow may make per title or episode: the first start plus "Sources to
    /// Try" (Settings › Sources, W4). The budget itself is shared (`PlayerSourceFallback`); this is
    /// only the "first start included" count the walk controller works in.
    nonisolated static func maxAutoAttempts(furtherSources: Int) -> Int {
        1 + max(furtherSources, 0)
    }

    static func maxAutoAttempts(settings: PlayerSettingsUiState?, entry: PlayerSourceFallbackEntry) -> Int {
        maxAutoAttempts(furtherSources: Int(PlayerSourceFallback.shared.furtherSources(settings: settings, entry: entry)))
    }

    /// The overlay's "of m" before a walk has read its own cap: the shared default budget.
    nonisolated static var defaultMaxAutoAttempts: Int {
        maxAutoAttempts(furtherSources: Int(PlayerSourceFallback.shared.DEFAULT_FURTHER_SOURCES))
    }

    /// W4: the start-up limit the host hands a context, nil for a source the viewer picked, for
    /// an Up Next context that carries no tried set, and whenever falling back is off for the
    /// entry point (`limitSeconds` answers nil then: `PlayerSourceFallback.startupLimitSeconds`).
    static func startupLimit(launchSource: PlaybackLaunchSource, hasSourceFallback: Bool,
                             limitSeconds: (PlayerSourceFallbackEntry) -> Int?) -> Double? {
        let entry: PlayerSourceFallbackEntry
        switch launchSource {
        case .manual: return nil
        case .autoPlay: entry = .firstPlay
        case .nextEpisode:
            guard hasSourceFallback else { return nil }
            entry = .nextEpisode
        }
        return limitSeconds(entry).map(Double.init)
    }

    static func startupLimit(for context: PlaybackContext, settings: PlayerSettingsUiState?) -> Double? {
        startupLimit(launchSource: context.launchSource, hasSourceFallback: context.sourceFallback != nil) { entry in
            PlayerSourceFallback.shared.startupLimitSeconds(settings: settings, entry: entry).map { Int($0.int32Value) }
        }
    }

    /// What the picker does when a playback it presented fails.
    enum Response: Equatable {
        /// Swap the next auto-play candidate into the open player.
        case autoFailover
        /// W4: swap the Up Next episode's next source into the open player (the episode walk).
        case episodeFallback
        /// Close the player and open a stream picker for the episode that failed.
        case nextEpisodePicker
        /// Close the player and offer "Try Next Source" / "Back to Sources".
        case manualAlert
    }

    /// Before W4: the launch source alone. Kept as the "no fallback left" answer `route` gives.
    static func response(for source: PlaybackLaunchSource) -> Response {
        switch source {
        case .autoPlay: return .autoFailover
        case .nextEpisode: return .nextEpisodePicker
        case .manual: return .manualAlert
        }
    }

    /// W4: what the picker does with a failure of a context it presented. A pick of the viewer's
    /// never falls back. First play keeps today's walk for any failure (the controller holds its
    /// own budget and gives up itself). An Up Next episode falls back in place while falling back
    /// is on, its tried set is known, a further source is left in its budget and the source either
    /// never started or failed before the healthy mark (decision Q4a); otherwise its picker opens.
    static func route(launchSource: PlaybackLaunchSource, failure: PlaybackFailure, hasSourceFallback: Bool,
                      fallbackActive: Bool, attemptsLeft: Int) -> Response {
        switch launchSource {
        case .manual: return .manualAlert
        case .autoPlay: return .autoFailover
        case .nextEpisode:
            let early = !failure.startedPlaying || failure.secondsPlayed < healthySeconds
            return (hasSourceFallback && fallbackActive && attemptsLeft > 0 && early) ? .episodeFallback : .nextEpisodePicker
        }
    }

    /// W4: further sources an Up Next episode may still move to in the player: its budget minus
    /// what its tried set already used (the first start and the further sources moved to).
    static func episodeAttemptsLeft(sourceFallback: PlayerSourceFallbackTried?, furtherSources: Int) -> Int {
        guard let sourceFallback else { return 0 }
        return maxAutoAttempts(furtherSources: furtherSources) - (1 + Int(sourceFallback.attempts))
    }

    /// W4 (decision Q4a): where a replacement for a failed auto-picked source starts: the failed
    /// position when it had started (more than the engines' 10 s resume floor), else nil (the
    /// context's own rule: saved progress or Start Over). A start-up limit has no failure: nil.
    static func replacementResume(after failure: PlaybackFailure?) -> Double? {
        guard let failure, failure.startedPlaying, failure.positionSec.isFinite, failure.positionSec > 10 else {
            return nil
        }
        return failure.positionSec
    }

    /// Remember the failed link only when it never got going: a source that played for five
    /// minutes and then died is not a bad link. P4 (BUG-143): and only on positive evidence
    /// against the link: a network, offline, cancelled or local-engine failure is not remembered
    /// (the failover walk still moves on).
    static func shouldReject(_ failure: PlaybackFailure) -> Bool {
        failure.secondsPlayed < healthySeconds && failure.kind.remembersLink
    }

    static func shouldKeep(secondsPlayed: Double) -> Bool {
        secondsPlayed >= healthySeconds
    }

    /// A short placeholder clip (debrid "caching" stubs, error videos) counts as a failure only in
    /// an automatic flow; a viewer who picked that link gets what they picked.
    static func treatsPlaceholderClipAsFailure(_ source: PlaybackLaunchSource) -> Bool {
        source != .manual
    }

    /// One listed stream, reduced to what the manual "Try Next Source" choice needs.
    struct Entry: Equatable {
        let key: String
        let addonId: String
    }

    /// Index in `entries` (the list in display order) of the stream "Try Next Source" plays after
    /// `failedKey`: only streams AFTER the failed one, the same add-on's first, then the rest in
    /// list order; rejected keys and the failed key itself are skipped. A failed key that is no
    /// longer in the list (it reloaded) considers the whole list. nil = nothing left to try.
    static func nextManualIndex(entries: [Entry], failedKey: String, failedAddonId: String?,
                                rejected: Set<String>) -> Int? {
        let start = entries.firstIndex { $0.key == failedKey }.map { $0 + 1 } ?? 0
        guard start < entries.count else { return nil }
        let eligible = (start..<entries.count).filter { index in
            let key = entries[index].key
            return !key.isEmpty && key != failedKey && !rejected.contains(key)
        }
        if let failedAddonId, let sameAddon = eligible.first(where: { entries[$0].addonId == failedAddonId }) {
            return sameAddon
        }
        return eligible.first
    }

    /// `nextManualIndex` over the listed streams themselves. Batch D review r1: a ytId-only stream
    /// (`StreamPickerView.isYouTubeResolved`) is never the next source — "Try Next Source" is meant
    /// to play at once, and a YouTube resolve takes seconds and may fail — so its key joins the
    /// rejected set. The list stays whole, so the failed stream's own index is still found even
    /// when ytId streams sit before it.
    static func nextManualIndex(streams: [StreamItem], failedKey: String, failedAddonId: String?,
                                rejected: Set<String>) -> Int? {
        let entries = streams.map { Entry(key: $0.playbackStreamKey, addonId: $0.addonId) }
        let youTubeKeys = Set(streams.filter { StreamPickerView.isYouTubeResolved($0) }.map(\.playbackStreamKey))
        return nextManualIndex(entries: entries, failedKey: failedKey, failedAddonId: failedAddonId,
                               rejected: rejected.union(youTubeKeys))
    }
}

/// The key a stream link is remembered under (`RejectedStreamLinks`, `PlaybackContext.streamKey`).
/// Shared by the stream picker, its auto-play controller and the Up Next engine so all three agree.
///
/// Keys are persisted (`RejectedStreamLinks`) and printed in `[AutoPlay]` / `[Failover]` lines, so
/// no link text goes into one in the clear: Torrentio-style debrid links carry the debrid API key
/// in the URL path (`/resolve/<service>/<API key>/…`), and an add-on's `addonId` is
/// `addon:<manifest id>:<manifest URL>`, where a configured manifest URL can hold the same key.
enum PlaybackStreamKey {
    /// `infoHash#fileIdx` for torrent / debrid candidates (the same torrent from two add-ons is the
    /// same file; an info hash is public). Otherwise `<add-on tag>|<link digest>`: the add-on tag
    /// is the hex of the first 4 bytes of SHA-256 of `addonId`, the link digest the hex of the
    /// first 16 bytes of SHA-256 of the stream URL's host+path. The query and fragment never join
    /// the digest (they usually carry a per-session token, so a refreshed token keeps the key). A
    /// stream with no URL but a YouTube video id (batch D U2, an add-on `ytId`-only stream) keys on
    /// `yt:<video id>` — the video id is public and stable, whereas the URL the on-device extractor
    /// resolves it to expires within hours and must never become the identity; one with none of
    /// those digests its label instead; one with nothing has no key (""). Built from the stream as
    /// listed: a debrid resolve's (or a YouTube resolve's) per-session link must not be the identity.
    static func make(infoHash: String?, fileIdx: Int?, addonId: String, url: String?, label: String,
                     youTubeId: String? = nil) -> String {
        if let hash = infoHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !hash.isEmpty {
            return "\(hash)#\(fileIdx.map(String.init) ?? "")"
        }
        if let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let link: String
            if let components = URLComponents(string: raw), let host = components.host, !host.isEmpty {
                link = host.lowercased() + components.path
            } else {
                let bare = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
                    .map(String.init) ?? raw
                link = bare.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                    .map(String.init) ?? bare
            }
            return "\(digestHex(addonId, bytes: 4))|\(digestHex(link, bytes: 16))"
        }
        if let videoId = youTubeId?.trimmingCharacters(in: .whitespacesAndNewlines), !videoId.isEmpty {
            return "\(digestHex(addonId, bytes: 4))|yt:\(videoId)"
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { return "" }
        // The prefix keeps a label's digest apart from a link's.
        return "\(digestHex(addonId, bytes: 4))|\(digestHex("label\u{1F}" + trimmedLabel, bytes: 16))"
    }

    /// Lowercase hex of the first `bytes` bytes of SHA-256 of `text` (UTF-8). The same on every
    /// launch and device, which the persisted keys rely on.
    static func digestHex(_ text: String, bytes: Int) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }
}

extension StreamItem {
    /// See `PlaybackStreamKey.make`. Uses the shared `p2pInfoHash` (top-level hash, the
    /// `clientResolve` hash, a magnet or a `torrent://` URL, normalised) and the matching file index.
    var playbackStreamKey: String {
        let hash: String? = p2pInfoHash
        let index: Int? = p2pFileIdx?.intValue ?? clientResolve?.fileIdx?.intValue
        let rawUrl: String? = url
        let rawExternal: String? = externalUrl
        let rawName: String? = name
        // Review r1: the id the stream would actually be PLAYED through (nil when a URL / hash /
        // externalUrl exists), not the raw `ytId` an add-on may attach to an ordinary link.
        let rawYouTubeId: String? = youTubeIdToResolve
        return PlaybackStreamKey.make(
            infoHash: hash,
            fileIdx: index,
            addonId: addonId,
            url: rawUrl ?? rawExternal,
            label: rawName ?? "",
            youTubeId: rawYouTubeId
        )
    }
}

/// Title-level catalog facts shown as chips in the player's Info tab.
struct PlaybackMeta: Equatable {
    var year: String? = nil
    var runtime: String? = nil
    var imdbRating: String? = nil
    var ageRating: String? = nil
    var genres: [String] = []
    /// The title's original language (ISO 639-1) for the "Original" audio preference, resolved the
    /// same way upstream's `resolveLaunchContentLanguage` does (TMDB `original_language`, with the
    /// production country as a tie-break for pt/es/zh variants). nil when the launch path has no
    /// catalog record — the players then fall back to `MetaDetailsRepository.peek`.
    var originalLanguage: String? = nil

    /// From a full catalog record (Detail / episode shelf launch paths).
    init(details: MetaDetails) {
        func nonEmpty(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }
        year = nonEmpty(details.releaseInfo)
        runtime = nonEmpty(details.runtime)
        imdbRating = nonEmpty(details.imdbRating)
        ageRating = nonEmpty(details.ageRating)
        genres = details.genres
        originalLanguage = PlayerLanguagePreferencesKt.resolveContentLanguage(
            language: details.language, country: details.country
        )
    }

    init(year: String? = nil, runtime: String? = nil, imdbRating: String? = nil,
         ageRating: String? = nil, genres: [String] = [], originalLanguage: String? = nil) {
        self.year = year; self.runtime = runtime; self.imdbRating = imdbRating
        self.ageRating = ageRating; self.genres = genres; self.originalLanguage = originalLanguage
    }

    /// Minutes in a catalog runtime string ("1h 30m", "90 min", "1:30", "90"); nil when it has
    /// none. A Swift copy of the shared `parseRuntimeMinutes` (internal to SharedCore), used for
    /// the external-player return's duration when no progress entry knows it yet.
    static func runtimeMinutes(_ raw: String?) -> Int? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        func firstInt(_ pattern: String, group: Int = 1) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: group), in: value) else { return nil }
            return Int(value[range])
        }
        if let hours = firstInt(#"^\s*(\d+)\s*:\s*(\d{1,2})\s*$"#),
           let minutes = firstInt(#"^\s*(\d+)\s*:\s*(\d{1,2})\s*$"#, group: 2) {
            return hours * 60 + minutes
        }
        let hoursToken = firstInt(#"(\d+)\s*h(?:ours?)?"#)
        let minutesToken = firstInt(#"(\d+)\s*m(?:in(?:ute)?s?)?"#)
        if hoursToken != nil || minutesToken != nil {
            return max(hoursToken ?? 0, 0) * 60 + max(minutesToken ?? 0, 0)
        }
        return firstInt(#"^\s*(\d+)\s*$"#).map { max($0, 0) }
    }
}

/// An external subtitle file to side-load into the player.
struct SubtitleFile {
    let url: String
    let language: String
    let name: String?
}

/// One selectable audio or subtitle track.
struct PlayerTrack: Identifiable, Equatable {
    let id: Int          // mpv track id; -1 means "off" (subtitles)
    let label: String
    let isSelected: Bool
}

/// A skippable segment (intro/recap/outro) resolved from `SkipIntroRepository`.
struct SkipSegment {
    let start: Double
    let end: Double
    let type: String
}

/// The currently-offered skip action (shown while playback is inside a `SkipSegment`).
struct SkipPrompt: Equatable {
    let label: String      // e.g. "Skip Intro"
    let targetSec: Double   // absolute seek target (segment end)
}

/// Live stream diagnostics read from libmpv properties (shown by the Stream Info overlay).
struct StreamInfoSnapshot: Equatable {
    /// Router decision label ("Native · DV P8.1" / "mpv · audio truehd"). Diagnostic only in Phase 1.
    var engine = ""
    var videoCodec = ""
    var resolution = ""
    var fps = ""
    var hwdec = ""
    var videoBitrate = ""
    var audio = ""
    var cache = ""

    var rows: [(String, String)] {
        [(String(localized: "Engine"), engine), (String(localized: "Video"), videoCodec),
         (String(localized: "Resolution"), resolution), (String(localized: "Frame rate"), fps),
         (String(localized: "Hardware decode"), hwdec), (String(localized: "Video bitrate"), videoBitrate),
         (String(localized: "Audio"), audio), (String(localized: "Cache"), cache)].filter { !$0.1.isEmpty }
    }
}
