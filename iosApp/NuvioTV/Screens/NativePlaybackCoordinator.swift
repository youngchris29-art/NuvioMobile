import AVFoundation
import AVKit
import Combine
import Foundation
import SharedCore
import UIKit

// Phase 3 of the hybrid player: ties Phase 2's remux + loopback server to an AVPlayer for one
// PlaybackContext. Starts the remux, begins playback progressively as soon as the first segment is
// available (rather than waiting for the whole file), and owns the AVPlayer lifecycle — resume seek,
// periodic watch-progress save, and Trakt scrobbling via the shared PlaybackProgressRecorder.
// See docs/tvos-hybrid-player-plan.md.

/// One entry of the native player's Audio menu (D4): a source audio track with a 10-foot display
/// name. `streamIndex` is the avformat stream index handed back to the rebuilt RemuxSession when the
/// user picks this track.
struct NativeAudioTrack: Identifiable, Equatable {
    let streamIndex: Int
    let name: String
    let playable: Bool
    let selected: Bool
    var id: Int { streamIndex }
}

/// Lock-guarded holder for the selected audio stream index (main-thread writes, server-queue reads).
nonisolated final class SelectedAudioBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int?
    var value: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// beta.19-rc1 verdict (P, BUG-139): the caption under the native player's preparing spinner.
/// Pure so it unit-tests without a remux. Dolby Vision is the remux's own report: a Dolby Vision
/// CODECS token (profile 5 is `dvh1.05.xx`, `dvhe` for the in-band variant) or a SUPPLEMENTAL-CODECS
/// token (profile 8.x over an HDR10, SDR or HLG base). Anything else, and "not inspected yet", is
/// plain playback.
nonisolated enum NativePreparingLabel {
    static func isDolbyVision(_ signaling: VideoSignaling?) -> Bool {
        guard let signaling else { return false }
        let codecs = signaling.codecs.lowercased()
        if codecs.hasPrefix("dvh1") || codecs.hasPrefix("dvhe") { return true }
        if let supplemental = signaling.supplementalCodecs, !supplemental.isEmpty { return true }
        return false
    }

    static func text(for signaling: VideoSignaling?) -> String {
        isDolbyVision(signaling)
            ? String(localized: "Preparing Dolby Vision\u{2026}")
            : String(localized: "Preparing playback\u{2026}")
    }
}

@MainActor
final class NativePlaybackCoordinator: ObservableObject {
    enum Phase: Equatable {
        case preparing            // remux spinning up / waiting for the first segment
        case playing
        case failed(String)       // pre-playback failure → dispatcher falls back to mpv
    }

    @Published private(set) var phase: Phase = .preparing
    /// Source audio tracks (Info tab rows) — populated once the remux inspects the streams; the
    /// `selected` flag follows the track the remux is producing (the system Audio tab drives
    /// switching — info-panel W3 — through the master's audio renditions).
    @Published private(set) var audioTracks: [NativeAudioTrack] = []
    /// Caption under the preparing spinner. beta.19-rc1 verdict (P, BUG-139): "Preparing
    /// playback…" until the remux reports a Dolby Vision stream; it used to say "Preparing Dolby
    /// Vision…" for every native-engine file, SDR and HDR10 included.
    @Published private(set) var preparingLabel = NativePreparingLabel.text(for: nil)
    /// Startup stage for the loading overlay (P4, B24): connecting → preparing → (subtitles) →
    /// buffering → started. Moves forward only; a signaling retry or a later item never moves it
    /// back. Each transition logs `[Loading] engine=native stage=… t=+…s`.
    @Published private(set) var loadingStage: PlayerLoadingStage = .connecting
    /// Uptime at `init`, the zero of the `[Loading]` log's `t=`.
    private let loadingStartUptime = ProcessInfo.processInfo.systemUptime
    /// Set once `play()` has been issued on a ready item: a later `.paused` status is then the
    /// viewer's pause, which also ends startup (a ready, paused picture needs no overlay). [C-9]
    private var playIssued = false
    /// Classified cause of the failure behind `phase = .failed(...)` (P4, BUG-143). Nil until a
    /// producer classifies one; the screen passes it on as `PlaybackFailure.kind`.
    @Published private(set) var failureKind: PlaybackFailureKind?
    /// The HTTP status behind a `.http` `failureKind`, when known (log / `PlaybackFailure.httpStatus`).
    private(set) var failureHTTPStatus: Int?
    private(set) var player: AVPlayer?

    /// Fired ~every few seconds with (position, duration) while playing — the screen forwards it to
    /// the next-episode engine.
    var onTick: ((Double, Double) -> Void)?
    /// Fired every tick with (previous, current) position, before `onTick`: the system transport's
    /// scrubs are invisible to us otherwise. The screen's `SkipSegmentPlanner.observeTick` decides
    /// whether a jump was a user scrub (and marks it deliberate); returns true when it was one — the
    /// stall budget resets on those. Unset: any jump > 10 s counts (the stall budget's old rule).
    var onPositionTick: ((Double, Double) -> Bool)?
    /// Fired with the target right BEFORE a resume seek is issued (either path below).
    var onResumeSeekBegin: ((Double) -> Void)?
    /// Fired with the actual position once AVPlayer confirms a resume seek finished.
    var onResumeSeekCompleted: ((Double) -> Void)?
    /// True once a resume seek has been issued (mpv's `didResumeSeek` equivalent).
    private(set) var didResumeSeek = false

    /// P5 B22: the current item played to its end (`AVPlayerItemDidPlayToEndTime`). The screen
    /// shows the post-play cover while this is true and no Up Next hand-off is pending.
    @Published private(set) var didPlayToEnd = false
    private var endObserver: NSObjectProtocol?

    /// Last observed position/duration, used when falling back to mpv.
    private(set) var lastPositionSec: Double = 0
    private var lastDurationSec: Double = 0 {
        didSet { if durationSec != lastDurationSec { durationSec = lastDurationSec } }
    }
    /// The item's duration once known (0 before), updated on the playback tick. Published for the
    /// screen (pause card remaining time, P4).
    @Published private(set) var durationSec: Double = 0

    /// Live detection (`LivePlaybackPolicy`, NuvioTV b4e47d6d6): AVPlayer's indefinite item duration
    /// (live HLS), or a duration that keeps growing across ticks. A live stream saves no progress.
    private var reportsLive = false
    private var durationGrowth = LivePlaybackPolicy.DurationGrowth()
    private var isLiveStream: Bool { LivePlaybackPolicy.isLive(reportsLive: reportsLive, growth: durationGrowth) }

    /// `ProcessInfo.systemUptime` when the item FIRST became ready to play; nil until then (a
    /// signaling retry or a later item never moves it).
    private(set) var readyUptime: TimeInterval?
    /// Accumulates play time only while `timeControlStatus == .playing`, sampled on the ~3 s
    /// observation tick once the item is ready. Paused, buffering and stalled time does not count.
    private var playClock = PlaybackHealthClock()
    /// Seconds the stream actually played (0 before the item was ready) — the "how long did this
    /// stream play" number the failover policy reads when the native path gives up, and the
    /// 300 s healthy mark. Not a wall clock: a paused or stalled stretch is left out.
    var secondsPlayed: Double { playClock.seconds }
    /// Fired once per session, from the playback tick, when `secondsPlayed` first reaches 300 and the
    /// player is playing — the stream has proven itself. Set by the screen (host: `PlayerScreen`).
    var onPlaybackHealthy: ((Double) -> Void)?
    private var healthyReported = false

    private let context: PlaybackContext
    private let recorder: PlaybackProgressRecorder
    private var remux: RemuxSession?
    private var server: LocalHLSServer?
    private var playerItem: AVPlayerItem?
    private var pollTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var servedURL: URL?
    /// 0 = full signaling (RFC 6381 + DV supplemental + range); 1 = minimal (bare sample-entry tag).
    /// A strict AVPlayer that rejects the full form at the master stage gets one retry at minimal.
    private var signalingAttempt = 0

    /// Language preferences (Settings → Playback → Preferred Audio/Subtitle Language + the
    /// forced/only-preferred subtitle options), resolved through the shared KMP helpers so the
    /// native and mpv engines agree. Drives AVPlayer's media-selection criteria, the master's
    /// AUTOSELECT/DEFAULT flags, and the panel's `allowedSubtitleOptionLanguages`.
    struct LanguagePlan: Equatable {
        var audioTargets: [String] = []
        var subtitleTargets: [String] = []
        /// The full preferred-subtitle list (primary + secondary + device), before the shared
        /// plan narrows it for forced-only auto-selection — this is what "Show only preferred
        /// languages" filters the panel's Subtitles list by.
        var subtitleFilterLanguages: [String] = []
        /// Preferred Subtitle Language is "none": never auto-enable subtitles.
        var subtitlesOff = false
        /// Shared plan says forced-only (audio already in a preferred language + "Use forced subtitles").
        var forcedOnly = false
        /// "Use forced subtitles" is on but the audio language is unknown: the shared plan returns
        /// nil to leave player defaults untouched (mpv parity) — no DEFAULT rendition, no legible
        /// criteria; the system's own behaviour + the user decide.
        var leaveToPlayer = false
        /// "Show only preferred languages" — restrict the panel's Subtitles list.
        var onlyPreferredLanguages = false
    }
    @Published private(set) var languagePlan = LanguagePlan()
    /// Shared player settings snapshot behind the plan (also drives the "show only preferred
    /// languages" addon-subtitle filter).
    private var playerSettings: PlayerSettingsUiState?
    /// The current item's legible selection group, cached async after readyToPlay (Info tab row +
    /// the top panel's Subtitles tab).
    @Published private(set) var legibleGroup: AVMediaSelectionGroup?
    /// Bumped whenever AVPlayer's media selection may have changed (notification, tick sync, or a
    /// panel pick) so the top panel recomputes its checkmarks — the notification alone proved
    /// unreliable in the sim.
    @Published private(set) var selectionVersion = 0
    /// Subtitle renditions of the current session keyed by NAME (source, forced, SDH) — the top
    /// panel's Subtitles tab groups/labels its rows from this.
    private(set) var subtitleRenditionsByName: [String: SubtitleRendition] = [:]

    // MARK: - Subtitle delay (B3)

    // The native engine re-times subtitles by RE-SERVING the rendition's WebVTT body with every cue
    // shifted. Measured on the tvOS 26.5 simulator (see docs, B3):
    //   • AVPlayer caches a subtitle rendition's MEDIA PLAYLIST for the life of the item — a second
    //     selection of a rendition never refetches `sub-N.m3u8`, so the body URL it names is frozen.
    //   • AVPlayer DOES refetch the VTT BODY on every (re)selection of a legible option, including
    //     one it has loaded before (our responses carry `Cache-Control: no-store`).
    // So the forcing function is simply Off → same option again; the server answers the refetch with
    // the current offset. Six consecutive distinct delays landed, each visible on the very next cue.

    /// Fallback forcing function, OFF by default. If an AVFoundation build ever caches the VTT body
    /// too, publishing each rendition under N interchangeable EXT-X-MEDIA slots makes a delay change
    /// select a URI AVPlayer has never fetched. It costs duplicate entries in the SYSTEM subtitle
    /// popover and caps a session at N distinct delays (slot K is bound to the delay it first
    /// served), which is why the reselect path is preferred. >1 re-enables it.
    static let subtitleDelaySlots = 1
    /// Current subtitle delay in milliseconds (positive = subtitles appear later). Persisted per
    /// `context.videoId` through the shared `PlayerTrackPreferenceStorage`.
    @Published private(set) var subtitleDelayMs = 0
    /// Number of delay changes applied this session — the slot cursor for the fallback path.
    private var subtitleDelayChanges = 0
    /// Coalesces a burst of ±0.1 s presses into one reselect (each one costs AVPlayer a VTT reparse
    /// and blinks the caption off for a frame).
    private var subtitleDelayApplyTask: Task<Void, Never>?
    /// The deferred "same option again" half of a delay refetch; cancelled by any explicit
    /// subtitle selection so a viewer's pick during the window is never overwritten.
    private var subtitleRefetchRestoreTask: Task<Void, Never>?
    /// True for the ~60 ms Off→restore hop of a delay refetch, so the panel keeps the Timing row
    /// mounted (unmounting the focused chip would throw tvOS focus — Codex review).
    @Published private(set) var isRefetchingSubtitles = false
    /// Paused per `timeControlStatus` (drives the swipe-down hint re-show).
    @Published private(set) var isPaused = false
    private var hasStartedPlaying = false
    private var timeControlObserver: NSKeyValueObservation?
    /// The audio track (stream index) AVPlayer's audible media selection currently names — the
    /// server honours rendition-file requests only for THIS track (info-panel W3), so an in-flight
    /// request for the previous rendition can't switch the worker back. Written on the media-
    /// selection notification, read from the server's connection queue.
    private let selectedAudioBox = SelectedAudioBox()
    private var mediaSelectionObserver: NSObjectProtocol?
    /// The current item's audible selection group, cached once loaded so every playback tick can
    /// read the selected option synchronously (the notification alone proved unreliable in the sim).
    @Published private(set) var audibleGroup: AVMediaSelectionGroup?
    /// Master audio renditions of the current session (option display name → stream index).
    private var audioRenditionsByName: [String: Int] = [:]
    /// Trakt scrobble session — start once, stop once.
    private var traktStarted = false
    /// Subtitles fetched from installed subtitle addons (OpenSubtitles etc.) — the same source the
    /// mpv player side-loads. Fetched at start(); playback start is gated (briefly, capped) on the
    /// fetch completing, because the VOD master is rendered exactly once — renditions that arrive
    /// after it are invisible to AVPlayer. Streams rarely attach their own subtitles.
    private var addonSubtitles: [SubtitleFile] = []
    private var addonSubsWatcher: FlowWatcher?
    /// Fetch lifecycle: done ONLY when the repo's `completedRequest` state matches this content's
    /// request key (state, not an edge — a fetch that finished before we looked, or was
    /// deduplicated against the stream picker's prefetch, still reads as complete). Addon results
    /// now arrive incrementally (per addon, as each finishes), so a non-empty `addonSubtitles`
    /// list is NOT a completion signal by itself — only `subsFetchCompleted()`'s poll sets this.
    private var subsFetchDone = false
    private var subsRequestKey = ""
    /// Embedded text tracks offered as renditions this session (Info tab row).
    private var embeddedSubtitleCount = 0

    // MARK: - Item decoration (P4)

    /// The app subtitle style snapshot (A9), read once in `resolveLanguagePlan`; a Settings change
    /// applies from the next playback, like `stripSdh`.
    private var subtitleStyleInput = NativeSubtitleStyle.Input.default
    /// `externalMetadata` for every item (A8): the text items, plus the artwork once it lands.
    private lazy var metadataTextItems = NativeNowPlayingMetadata.textItems(context: context)
    private var artworkMetadata: AVMetadataItem?
    private var artworkTask: Task<Void, Never>?
    /// Container chapters on the served timeline (A6-native), trimmed at the duration; feeds the
    /// panel's Chapters tab and the system bar's navigation markers.
    @Published private(set) var chapters: [TransportChapter] = []
    private var chapterGroups: [AVNavigationMarkersGroup] = []

    // MARK: Late add-on subtitles (P4, B17)

    /// Subtitle renditions/flags the server publishes right now (existing first, late appended).
    private var currentSubtitleRenditions: [SubtitleRendition] = []
    private var currentSubtitleFlags: [SubtitleRenditionFlags] = []
    /// Add-on subtitle URLs already in the master (initial or late).
    private var servedAddonURLs: Set<String> = []
    private var lateDebounce: Task<Void, Never>?
    private var lateRebuildsUsed = 0
    /// True once the viewer changed the subtitle selection since the item became ready.
    private var legibleTouched = false
    /// Canonical name of the legible selection last seen (nil = Off); `.none` until the group loads.
    private var legibleSnapshot: String??
    /// The late rendition a lazy pick (or the auto decision) wants showing after the rebuild.
    private var pendingLateSelection: String?
    /// Uptime of the last user seek the tick saw (auto rebuilds wait 10 s after one).
    private var lastUserSeekUptime: TimeInterval = 0
    /// Late renditions not yet in the current item (the panel lists them; a pick rebuilds).
    @Published private(set) var lateSubtitleRows: [SubtitleRendition] = []
    @Published private(set) var isRebuildingItem = false
    /// r1 P3: the last app-issued user seek (chapter pick, skip chip / auto-skip) while a B17
    /// rebuild is in flight. The rebuild's corrective seek goes there instead of back to the
    /// captured playhead, so the viewer's seek wins.
    private var rebuildUserSeekSec: Double?
    /// `none` / `published` / `rebuilt` (the DEBUG probe's `late=` field).
    @Published private(set) var lateState = "none"
    #if DEBUG
    /// `-debug.nativeLateSubtitleURL`: a file injected after `-debug.nativeLateSubtitleDelaySec`,
    /// kept apart from `addonSubtitles` (the watcher reassigns that list on every emission). [C-14]
    private var debugLateSubtitles: [SubtitleFile] = []
    #endif

    /// What a B17 rebuild restores once the new item is ready.
    private struct RebuildTarget {
        let positionSec: Double
        let wasPlaying: Bool
        let audioName: String?
        let subtitleName: String?
        let reason: String
        let startedUptime: TimeInterval
    }

    init(context: PlaybackContext) {
        self.context = context
        self.recorder = PlaybackProgressRecorder(context: context)
    }

    // MARK: - Lifecycle

    func start() {
        guard remux == nil else { return }
        logLoadingStage(loadingStage)
        // Addon-subtitle results. The completion signal is polled from `completedRequest` in
        // pollForFirstSegment — no watcher races; this watcher only mirrors the list (its
        // StateFlow replay also delivers results prefetched before this coordinator existed).
        // Settings first: the addon-subtitle watcher below filters by them.
        resolveLanguagePlan(selectedAudioTrack: nil)
        // Persisted subtitle delay for this title/episode (profile-scoped, shared with mobile).
        // Loaded before the server exists, so the very first VTT body is already re-timed.
        subtitleDelayMs = Self.clampSubtitleDelay(
            PlayerTrackPreferenceStorage.shared.loadSubtitleDelayMs(videoId: context.videoId)?.intValue ?? 0)
        if subtitleDelayMs != 0 { print("[NativePlayer] subtitle delay restored: \(subtitleDelayMs)ms") }
        subsRequestKey = SubtitleRepository.shared.requestKey(type: context.contentType, videoId: context.videoId)
        addonSubsWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.addonSubtitles) { [weak self] emitted in
            guard let subs = emitted as? [AddonSubtitle] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // "Show only preferred languages" (shared subtitle-style setting, cloud-synced from
                // mobile): drop non-preferred renditions at the source with the same shared filter
                // the mobile runtime and the mpv screen apply.
                let kept = self.playerSettings.map {
                    PlayerTrackSelectionKt.filterAddonSubtitlesForSettings(subtitles: subs, settings: $0)
                } ?? subs
                self.addonSubtitles = kept.map {
                    SubtitleFile(url: $0.url, language: $0.language, name: $0.display)
                }
                if !subs.isEmpty {
                    // Incremental emission: this may be just one addon's results, not the whole
                    // fetch — completion is decided solely by `subsFetchCompleted()` polling
                    // `completedRequest` against `subsRequestKey`, not by this arriving non-empty.
                    print("[NativePlayer] addon subtitles updated: \(subs.count)\(self.server == nil ? "" : " (after master — late path)")")
                }
                self.checkLateSubtitles()
            }
        }
        SubtitleRepository.shared.fetchAddonSubtitles(type: context.contentType, videoId: context.videoId)
        startArtworkFetch()
        #if DEBUG
        scheduleDebugLateSubtitle()
        #endif
        launchRemux()
    }

    /// Resolve the language plan from the shared player settings (same helpers + semantics as the
    /// mpv screen's `autoSelectPreferredTracks`). Called at start (audio unknown) and again once
    /// the remux has picked the audio track, because the forced-only decision depends on it.
    private func resolveLanguagePlan(selectedAudioTrack: AudioTrack?) {
        PlayerSettingsRepository.shared.ensureLoaded()
        guard let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState else { return }
        playerSettings = settings
        subtitleStyleInput = NativeSubtitleStyle.input(from: settings.subtitleStyle)
        let deviceLanguages = DeviceLanguagePreferences.shared.preferredLanguageCodes()
        let audioTargets = PlayerLanguagePreferencesKt.resolvePreferredAudioLanguageTargets(
            preferredAudioLanguage: settings.preferredAudioLanguage,
            secondaryPreferredAudioLanguage: settings.secondaryPreferredAudioLanguage,
            deviceLanguages: deviceLanguages,
            // Title's original language for the "Original" audio preference (was nil = inert).
            contentOriginalLanguage: PlayerAudioLanguagePlan.originalLanguage(for: context)
        )
        // FEAT-84 Off stays Off: no fallback subtitle language while Subtitles is Off (the shared
        // resolver would return it), so the plan below is `subtitlesOff`. See
        // `SubtitleFallbackGuard`.
        let subTargets = PlayerLanguagePreferencesKt.resolvePreferredSubtitleLanguageTargets(
            preferredSubtitleLanguage: settings.preferredSubtitleLanguage,
            secondaryPreferredSubtitleLanguage: SubtitleFallbackGuard.effectiveSecondary(
                primary: settings.preferredSubtitleLanguage,
                secondary: settings.secondaryPreferredSubtitleLanguage
            ),
            deviceLanguages: deviceLanguages
        )
        var plan = LanguagePlan()
        plan.audioTargets = audioTargets
        plan.subtitleFilterLanguages = subTargets
        plan.onlyPreferredLanguages = settings.subtitleStyle.showOnlyPreferredLanguages
        // Always consult the shared plan: even with no subtitle targets (primary "none", no
        // secondary) it can yield a forced-only plan in the audio's language when "Use forced
        // subtitles" is on and the audio matches a preferred audio language (mpv parity).
        if let shared = PlayerTrackSelectionKt.resolveSubtitleAutoSelectionPlan(
            selectedAudioTrack: selectedAudioTrack,
            preferredAudioTargets: audioTargets,
            preferredSubtitleTargets: subTargets,
            useForcedSubtitles: settings.subtitleStyle.useForcedSubtitles
        ) {
            plan.subtitleTargets = shared.targets
            plan.forcedOnly = shared.mode == .forcedOnly
            plan.subtitlesOff = shared.targets.isEmpty   // nothing to auto-select → never auto-enable
        } else {
            // Forced on but audio language unknown: leave player defaults untouched (mpv parity).
            plan.leaveToPlayer = true
            plan.subtitleTargets = subTargets
        }
        if plan != languagePlan {
            languagePlan = plan
            print("[NativePlayer] language plan: audio=\(plan.audioTargets) subs=\(plan.subtitlesOff ? "off" : plan.subtitleTargets.description)"
                  + (plan.forcedOnly ? " forced-only" : "") + (plan.leaveToPlayer ? " player-default" : "")
                  + (plan.onlyPreferredLanguages ? " only-preferred" : ""))
        }
    }

    /// Install the plan on a player: AVPlayer applies these when the item's selection groups load
    /// (and again after an audio-switch rebuild). Empty preferred languages fall back to the
    /// system's own behaviour, so "subtitles off" is additionally enforced by the master's
    /// AUTOSELECT=NO flags (see `subtitleAutoselect`).
    private func applyLanguagePlan(to player: AVPlayer) {
        let plan = languagePlan
        // Applied once per item, at setup: re-applying after a MANUAL audio/subtitle pick would let
        // AVPlayer snap back to the preferences.
        if !plan.audioTargets.isEmpty {
            player.setMediaSelectionCriteria(
                AVPlayerMediaSelectionCriteria(preferredLanguages: plan.audioTargets, preferredMediaCharacteristics: nil),
                forMediaCharacteristic: .audible)
        }
        if plan.subtitlesOff || plan.leaveToPlayer {
            player.setMediaSelectionCriteria(nil, forMediaCharacteristic: .legible)
        } else {
            player.setMediaSelectionCriteria(
                AVPlayerMediaSelectionCriteria(
                    preferredLanguages: plan.subtitleTargets,
                    preferredMediaCharacteristics: plan.forcedOnly ? [.containsOnlyForcedSubtitles] : nil),
                forMediaCharacteristic: .legible)
        }
    }

    /// AUTOSELECT/DEFAULT decision for one subtitle rendition (master playlist flags).
    /// - subtitles off → nothing auto-selectable, so neither the system's accessibility prefs nor
    ///   AVPlayer's defaults can switch captions on;
    /// - otherwise renditions in a preferred language are AUTOSELECT=YES and the first match is
    ///   DEFAULT=YES (mpv parity: preferred subtitles start on), the rest AUTOSELECT=NO.
    private func subtitleFlags(for renditions: [SubtitleRendition], defaultTaken seeded: Bool = false) -> [SubtitleRenditionFlags] {
        let plan = languagePlan
        // No DEFAULT when forced-only (addon subs carry no forced flag) or when the shared plan
        // deferred to player defaults; matches stay AUTOSELECT so the system may still pick them.
        // `seeded`: late renditions (B17) never take DEFAULT when an existing one already has it.
        var defaultTaken = plan.leaveToPlayer || seeded
        return renditions.map { rendition in
            // FORCED renditions are always auto-selectable: HLS requires AUTOSELECT=YES with
            // FORCED=YES (an invalid master is an admission failure), and forced tracks — foreign
            // dialogue / signs — are meant to show per the player's own rules even when the viewer
            // has no subtitle language preference (standard forced-subtitle behaviour). Never DEFAULT
            // outside a forced-only plan.
            guard !plan.subtitlesOff else { return SubtitleRenditionFlags(autoselect: rendition.forced, isDefault: false) }
            // Deferred to player defaults: every rendition stays auto-selectable, none is DEFAULT.
            guard !plan.leaveToPlayer else { return .legacy }
            let matches = plan.subtitleTargets.contains { target in
                PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: rendition.language ?? "", targetLanguage: target)
            }
            // Forced-only plan: only a FORCED rendition in the target language may start on
            // (embedded tracks carry the flag; addon files never do). Normal plan: only FULL
            // renditions — a forced (signs/foreign-dialogue-only) track must not win DEFAULT just
            // because it's listed first.
            let eligible = plan.forcedOnly ? rendition.forced : !rendition.forced
            let isDefault = matches && eligible && !defaultTaken
            if isDefault { defaultTaken = true }
            // Forced renditions stay auto-selectable (the player applies them per its own rules)
            // whenever subtitles aren't off outright.
            return SubtitleRenditionFlags(autoselect: matches || rendition.forced, isDefault: isDefault)
        }
    }

    /// True once the repo has completed the fetch for THIS content (deduplicated prefetches
    /// included). Read on the poll cadence; sticky via `subsFetchDone`.
    private func subsFetchCompleted() -> Bool {
        if subsFetchDone { return true }
        if (SubtitleRepository.shared.completedRequest.value_ as? String) == subsRequestKey {
            subsFetchDone = true
            print("[NativePlayer] addon subtitle fetch finished (\(addonSubtitles.count) found)")
            return true
        }
        return false
    }

    /// First playable track whose language matches the highest-priority target with any hit
    /// (same rule as `PlayerAudioLanguagePlan.trackToForce(targets:tracks:)`). Pure — runs on the remux worker.
    nonisolated private static func preferredAudioStream(in tracks: [RemuxAudioTrack], targets: [String]) -> Int? {
        for target in targets {
            for track in tracks where track.playable {
                if PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: track.language ?? "",
                                                                          targetLanguage: target) {
                    return track.streamIndex
                }
            }
        }
        return nil
    }

    /// Spin up the remux session and the first-segment poll.
    private func launchRemux() {
        // Initial track: let the worker start on the first playable track in a preferred language
        // (Settings → Playback → Preferred Audio Language). Only the active track's rendition is
        // produced, so starting on the right one avoids an immediate switch (the master marks it
        // DEFAULT and the audible criteria agree).
        let audioTargets = languagePlan.audioTargets
        var config = RemuxSession.Config(url: context.url, segmentDurationSec: 6,
                                         requestHeaders: context.requestHeaders)
        // SDH stripping, native path — the mpv path sets `sub-filter-sdh` and reapplies it live in
        // applySubtitleStyle; here the flag is sampled once (embedded cues filter at VTT-segment
        // write, addon files at VTT conversion), so a mid-playback toggle flip deliberately applies
        // from the next playback session — no invalidation machinery.
        config.stripSdh = playerSettings?.subtitleStyle.stripSdh ?? false
        if !audioTargets.isEmpty {
            config.preferredAudioPicker = { tracks in Self.preferredAudioStream(in: tracks, targets: audioTargets) }
        }
        let remux = RemuxSession(config: config)
        self.remux = remux
        remux.start { state in
            guard case .failed(let stage) = state else { return }
            Task { @MainActor [weak self] in self?.failIfPreplayback(stage) }
        }
        pollForFirstSegment(remux: remux)
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        lateDebounce?.cancel(); lateDebounce = nil
        artworkTask?.cancel(); artworkTask = nil
        observeTask?.cancel(); observeTask = nil
        subtitleDelayApplyTask?.cancel(); subtitleDelayApplyTask = nil
        subtitleRefetchRestoreTask?.cancel(); subtitleRefetchRestoreTask = nil
        if let o = mediaSelectionObserver { NotificationCenter.default.removeObserver(o); mediaSelectionObserver = nil }
        removeEndObserver()
        timeControlObserver?.invalidate(); timeControlObserver = nil
        addonSubsWatcher?.cancel(); addonSubsWatcher = nil
        if lastDurationSec > 0 {
            recorder.record(positionSec: lastPositionSec, durationSec: lastDurationSec, isPaused: true, speed: 1,
                            flush: true, isLive: isLiveStream)
        }
        recorder.stopTrakt(positionSec: lastPositionSec, durationSec: lastDurationSec)
        recorder.stopTrackers(positionSec: lastPositionSec, durationSec: lastDurationSec)
        player?.pause()
        server?.stop(); server = nil
        remux?.stop()
        // debug.keepRemuxOutput=1 preserves the emitted files so they can be pulled off the device
        // (devicectl copy from the app container) and inspected with ffprobe on a Mac. Cleanup is
        // scheduled on the remux worker's own queue so it runs strictly AFTER the worker exits —
        // a direct removal here can race a final in-flight segment write.
        if let remux {
            if UserDefaults.standard.bool(forKey: "debug.keepRemuxOutput") {
                print("[NativePlayer] kept remux output at \(remux.outputDir.path)")
            } else {
                remux.scheduleCleanup()
            }
        }
        remux = nil
        player = nil
        playerItem = nil
    }

    // MARK: - Progressive startup

    /// Poll the remux output until playback can start: the segment map exists (else the source has no
    /// usable keyframe index → mpv), the init segment is written, and the first media segment is ready
    /// so AVPlayer's opening requests are instant. The playlist is a COMPLETE VOD list from the first
    /// fetch (the JIT server synthesizes it from the map), so there is no EVENT ≥3-segment join rule
    /// anymore; later segments simply block briefly on the JIT server until the remux produces them.
    private func pollForFirstSegment(remux: RemuxSession) {
        pollTask = Task { @MainActor [weak self] in
            let dir = remux.outputDir
            // The VOD master is rendered exactly once — subtitle renditions must exist by then. Give
            // the addon fetch a bounded head start beyond remux readiness; never hold startup longer.
            // P4 (B17): with a late path in place, hold at most `gate` (3 s, DEBUG
            // -debug.nativeSubsGateSec) past remux readiness, and never past 8 s from poll start.
            let pollStart = Date()
            let hardDeadline = pollStart.addingTimeInterval(8)
            var gate: TimeInterval = 3
            #if DEBUG
            if UserDefaults.standard.object(forKey: "debug.nativeSubsGateSec") != nil {
                gate = max(0, UserDefaults.standard.double(forKey: "debug.nativeSubsGateSec"))
            }
            #endif
            var readyAt: Date?
            for _ in 0..<240 {                          // ~60s ceiling
                if Task.isCancelled { return }
                if case .failed(let stage) = remux.state { self?.failIfPreplayback(stage); return }
                // The worker publishes the video signaling when it inspects the streams, before the
                // segment map exists; a Dolby Vision file flips the caption once, in the first few
                // hundred milliseconds. (P, BUG-139)
                self?.updatePreparingLabel(remux.videoSignaling)
                if let signaling = remux.videoSignaling {
                    self?.advanceLoadingStage(.preparing(dolbyVision: NativePreparingLabel.isDolbyVision(signaling)))
                }
                let hasMap = remux.segmentMap != nil
                let hasInit = Self.fileSize(dir, "init.mp4") > 0
                // A finished remux (short clip that is a single segment) finalizes seg-00001 only at EOF.
                let hasFirst = Self.fileSize(dir, RemuxSession.segmentName(1)) > 0 || remux.state == .ready
                if hasMap && hasInit && hasFirst {
                    let ready = readyAt ?? Date()
                    readyAt = ready
                    let subsDeadline = min(ready.addingTimeInterval(gate), hardDeadline)
                    if let self, !self.subsFetchCompleted(), Date() < subsDeadline {
                        self.advanceLoadingStage(.subtitles)
                        try? await Task.sleep(nanoseconds: 250_000_000)   // waiting only on subtitles now
                        continue
                    }
                    if let self, !self.subsFetchDone {
                        print("[NativePlayer] subs gate lapsed after \(String(format: "%.1f", Date().timeIntervalSince(pollStart)))s gate=\(String(format: "%.1f", gate))s — starting without addon subtitles (late path armed)")
                    }
                    self?.beginPlayback(remux: remux)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.failIfPreplayback("no segments produced")
        }
    }

    /// Moves `loadingStage` forward (never back) and logs the transition once. A same-rank change
    /// (the Dolby Vision flag of `.preparing`, a `.buffering` percentage) is applied too.
    private func advanceLoadingStage(_ next: PlayerLoadingStage) {
        guard next != loadingStage, Self.loadingRank(next) >= Self.loadingRank(loadingStage) else { return }
        loadingStage = next
        logLoadingStage(next)
    }

    private func logLoadingStage(_ stage: PlayerLoadingStage) {
        let t = ProcessInfo.processInfo.systemUptime - loadingStartUptime
        print("[Loading] engine=native stage=\(stage.logToken) t=+\(String(format: "%.2f", t))s")
    }

    private static func loadingRank(_ stage: PlayerLoadingStage) -> Int {
        switch stage {
        case .checking: 0
        case .connecting: 1
        case .preparing: 2
        case .subtitles: 3
        case .buffering: 4
        case .started: 5
        }
    }

    /// Assigns only on change, so the `@Published` caption does not re-render every poll tick.
    private func updatePreparingLabel(_ signaling: VideoSignaling?) {
        let text = NativePreparingLabel.text(for: signaling)
        if text != preparingLabel { preparingLabel = text }
    }

    // MARK: - Late add-on subtitles (P4, B17)

    #if DEBUG
    private func scheduleDebugLateSubtitle() {
        guard let url = UserDefaults.standard.string(forKey: "debug.nativeLateSubtitleURL"), !url.isEmpty else { return }
        let delay = max(0, UserDefaults.standard.double(forKey: "debug.nativeLateSubtitleDelaySec"))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            print("[Subs] DEBUG late subtitle injected after \(String(format: "%.1f", delay))s: \(url)")
            self.debugLateSubtitles = [SubtitleFile(url: url, language: "en", name: "Late Test")]
            self.checkLateSubtitles()
        }
    }
    #endif

    /// Add-on files the served master does not carry yet.
    private var pendingLateFiles: [SubtitleFile] {
        var files: [SubtitleFile] = []
        if subsFetchDone || subsFetchCompleted() { files += addonSubtitles }
        #if DEBUG
        files += debugLateSubtitles
        #endif
        return files.filter { !servedAddonURLs.contains($0.url) }
    }

    /// Called from the add-on watcher and the playback tick: once the fetch has completed and some
    /// file is not in the master, (re)start the 1 s debounce. At most one rebuild per session.
    ///
    /// r3 P2: both this and `applyLateSubtitles` wait for `playIssued`. `phase` turns `.playing`
    /// before the first item is ready, so a slow add-on fetch landing while the first item loads
    /// or during its resume seek could rebuild it then. `rebuildItem` captured
    /// `wasPlaying = false` (no `play()` yet) and cancelled the observe task before its `play()`,
    /// so `finishRebuild` never played: a frozen frame on "Buffering…", no tracker start. The
    /// playback tick re-calls this every 200 ms, so a gated apply is deferred to the first tick
    /// after `play()`, not lost (nothing is recorded in `servedAddonURLs` until the apply runs).
    private func checkLateSubtitles() {
        guard server != nil, phase == .playing, playIssued, !isRebuildingItem, lateRebuildsUsed == 0,
              !pendingLateFiles.isEmpty else { return }
        lateDebounce?.cancel()
        lateDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.lateDebounce = nil
            self.applyLateSubtitles()
        }
    }

    private func applyLateSubtitles() {
        guard let server, phase == .playing, playIssued, !isRebuildingItem, lateRebuildsUsed == 0 else { return }
        let files = pendingLateFiles
        guard !files.isEmpty else { return }
        files.forEach { servedAddonURLs.insert($0.url) }
        let merged = LateSubtitlePlan.merge(existing: currentSubtitleRenditions, late: files)
        let late = Array(merged.dropFirst(currentSubtitleRenditions.count))
        guard !late.isEmpty else { return }
        // C-14: existing flags verbatim, flags computed for the late ones only.
        let lateFlags = subtitleFlags(for: late, defaultTaken: currentSubtitleFlags.contains(where: \.isDefault))
        currentSubtitleRenditions = merged
        currentSubtitleFlags += lateFlags
        server.setSubtitles(merged, flags: currentSubtitleFlags)
        for r in late { subtitleRenditionsByName[r.name] = r }
        lateSubtitleRows += late
        lateState = "published"
        print("[Subs] late renditions +\(late.count) (\(late.map(\.name).joined(separator: ", ")))")
        var action = LateSubtitlePlan.decide(late: late, flags: lateFlags, selectionShowing: currentSubtitleOption != nil,
                                             legibleTouched: legibleTouched, rebuildsUsed: lateRebuildsUsed)
        if case .autoRebuild = action, let deferral = autoRebuildDeferral() {
            print("[Subs] late auto rebuild deferred (\(deferral))")
            action = .publishOnly
        }
        switch action {
        case .autoRebuild(let name):
            print("[Subs] late mode=auto (\(name))")
            pendingLateSelection = name
            rebuildItem(reason: "auto")
        case .publishOnly:
            print("[Subs] late mode=lazy")
        case .none:
            break
        }
        selectionVersion &+= 1
    }

    /// C-14: moments the up-next card and skip seeks own — paused, the last 5 minutes, or within
    /// 10 s of a seek. Nil = an auto rebuild may run now.
    private func autoRebuildDeferral() -> String? {
        if isPaused { return "paused" }
        if durationSec > 0, durationSec - lastPositionSec < 300 { return "last 5 minutes" }
        if ProcessInfo.processInfo.systemUptime - lastUserSeekUptime < 10 { return "recent seek" }
        return nil
    }

    /// The panel picked a late row that is not in the current item yet: rebuild with it showing.
    func selectLateSubtitle(name: String) {
        guard lateSubtitleRows.contains(where: { $0.name == name }) else { return }
        legibleTouched = true
        pendingLateSelection = name
        rebuildItem(reason: "pick")
    }

    /// How the rebuilt item is kept off t=0 ([C-1]): `tag` = `EXT-X-START` in the master (default),
    /// `seek` = a pre-ready exact seek, `none` = neither (DEBUG A/B for the rig proof only).
    private var rebuildStartMode: String {
        #if DEBUG
        if let mode = UserDefaults.standard.string(forKey: "debug.nativeRebuildStartMode"), ["tag", "seek", "none"].contains(mode) {
            return mode
        }
        #endif
        return "tag"
    }

    /// B17: the first mid-play item swap. At most once per session; restores position, play state,
    /// audio and subtitles once the new item is ready (`finishRebuild`).
    private func rebuildItem(reason: String) {
        guard lateRebuildsUsed == 0, phase == .playing, !isRebuildingItem,
              let player, let server, let servedURL else { return }
        let pos = CMTimeGetSeconds(player.currentTime())
        guard pos.isFinite else { return }
        let target = RebuildTarget(
            positionSec: pos, wasPlaying: player.timeControlStatus != .paused,
            audioName: currentAudioOption.map(Self.renditionName(of:)),
            subtitleName: pendingLateSelection ?? currentLegibleName,
            reason: reason, startedUptime: ProcessInfo.processInfo.systemUptime)
        isRebuildingItem = true
        rebuildUserSeekSec = nil
        observeTask?.cancel()
        subtitleDelayApplyTask?.cancel(); subtitleDelayApplyTask = nil
        subtitleRefetchRestoreTask?.cancel(); subtitleRefetchRestoreTask = nil
        isRefetchingSubtitles = false
        // C-2: the new item must not pick its own audio/subtitles (criteria are once per item).
        player.setMediaSelectionCriteria(nil, forMediaCharacteristic: .audible)
        player.setMediaSelectionCriteria(nil, forMediaCharacteristic: .legible)
        let mode = rebuildStartMode
        server.setStartOffset(mode == "tag" ? pos : nil)     // C-1: start AT the playhead
        let url = URL(string: servedURL.absoluteString + "?late=1") ?? servedURL
        let item = AVPlayerItem(url: url)
        decorate(item)
        playerItem = item
        legibleGroup = nil
        audibleGroup = nil
        print("[Subs] late rebuild begin reason=\(reason) at \(String(format: "%.1f", pos))s start=\(mode)"
              + " audio=\(target.audioName ?? "-") sub=\(target.subtitleName ?? "off")")
        player.replaceCurrentItem(with: item)
        if mode == "seek" {
            item.seek(to: CMTime(seconds: pos, preferredTimescale: 600), toleranceBefore: .zero,
                      toleranceAfter: .zero, completionHandler: nil)
        }
        observeMediaSelection(item: item, player: player)
        observePlayback(player: player, item: item, rebuild: target)
    }

    private func finishRebuild(_ target: RebuildTarget, player: AVPlayer, item: AVPlayerItem) async {
        server?.setStartOffset(nil)
        lastPositionSec = target.positionSec                 // the skip planner sees no jump
        let landed = CMTimeGetSeconds(player.currentTime())
        print("[Subs] late rebuild item ready at \(String(format: "%.2f", landed))s (target \(String(format: "%.2f", target.positionSec))s)")
        // r1 P2: every await below can be overtaken by `stop()` or a mid-play fallback to mpv
        // (both cancel this task and hand the screen over). Without these guards the corrective
        // seek could complete and `play()` restart a player that was already paused and released:
        // up to the 24 s forward buffer of ghost audio over mpv's start, or after the viewer left.
        // A user seek issued during the rebuild wins over the captured playhead (r1 P3).
        let wanted = rebuildUserSeekSec ?? target.positionSec
        if let user = rebuildUserSeekSec {
            print("[Subs] late rebuild: user seek to \(String(format: "%.1f", user))s during the rebuild wins")
        }
        rebuildUserSeekSec = nil
        if !landed.isFinite || abs(landed - wanted) > 0.5 {
            await player.seek(to: CMTime(seconds: wanted, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            guard rebuildStillOwns(player: player, item: item) else { return abandonRebuild("after seek") }
        }
        guard rebuildStillOwns(player: player, item: item) else { return abandonRebuild("before play") }
        if target.wasPlaying { player.play() }
        let audible = (try? await item.asset.loadMediaSelectionGroup(for: .audible)) ?? nil
        guard rebuildStillOwns(player: player, item: item) else { return abandonRebuild("after audible") }
        let legible = (try? await item.asset.loadMediaSelectionGroup(for: .legible)) ?? nil
        guard rebuildStillOwns(player: player, item: item) else { return abandonRebuild("after legible") }
        if let audible, let name = target.audioName,
           let option = audible.options.first(where: { Self.renditionName(of: $0) == name }) {
            item.select(option, in: audible)
        }
        audibleGroup = audible
        if let legible {
            let option = target.subtitleName.flatMap { name in
                legible.options.first {
                    let n = Self.renditionName(of: $0)
                    return Self.subtitleSlot(ofName: n) == 0 && Self.canonicalSubtitleName(n) == name
                }
            }
            item.select(option, in: legible)
        }
        legibleGroup = legible
        legibleSnapshot = .some(currentLegibleName)
        isRebuildingItem = false
        lateRebuildsUsed += 1
        lateSubtitleRows = []
        pendingLateSelection = nil
        lateState = "rebuilt"
        selectionVersion &+= 1
        let took = ProcessInfo.processInfo.systemUptime - target.startedUptime
        print("[Subs] late rebuild reason=\(target.reason) at \(String(format: "%.1f", target.positionSec))s"
              + " took=\(String(format: "%.2f", took))s audio=\(currentAudioOption.map(Self.renditionName(of:)) ?? "-")"
              + " sub=\(currentLegibleName ?? "off")")
    }

    /// r1 P2: the rebuild may only touch the player while this coordinator still owns it and the
    /// rebuilt item is current: not cancelled, not stopped (`player` nil), not swapped, still
    /// `.playing` (a fallback sets `.failed`).
    private func rebuildStillOwns(player: AVPlayer, item: AVPlayerItem) -> Bool {
        !Task.isCancelled && self.player === player && playerItem === item && phase == .playing
    }

    /// An abandoned rebuild never leaves `syncAudioSelection` / `checkLateSubtitles` gated.
    private func abandonRebuild(_ at: String) {
        isRebuildingItem = false
        rebuildUserSeekSec = nil
        print("[Subs] late rebuild abandoned \(at) (stopped, swapped or handed to mpv)")
    }

    /// Every `AVPlayerItem` this coordinator creates (first item, signaling retry, B17 rebuild)
    /// goes through here; nothing else sets these properties.
    private func decorate(_ item: AVPlayerItem) {
        // Bound how far ahead AVPlayer prefetches: over the infinite-bandwidth loopback origin it
        // would otherwise race minutes past the ~realtime remux frontier and block on segments that
        // don't exist yet, tripping CFNetwork's request timeout.
        item.preferredForwardBufferDuration = 24
        item.textStyleRules = NativeSubtitleStyle.rules(subtitleStyleInput)
        item.externalMetadata = metadataTextItems + (artworkMetadata.map { [$0] } ?? [])
        item.navigationMarkerGroups = chapterGroups
    }

    /// Chapters tab pick: an exact seek to the chapter start, kept inside the file. The screen's
    /// skip planner reads the next tick's jump as a user scrub, so it is never auto-skipped back.
    func seek(toChapter sec: Double) {
        guard let player else { return }
        let target = PlayerChapters.clampedSeek(sec, durationSec: lastDurationSec > 0 ? lastDurationSec : durationSec)
        print("[Chapters] native seek → \(String(format: "%.1f", target))s")
        noteUserSeek(to: target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Every app-issued user seek reports its target here (chapter pick, the screen's skip seeks).
    /// Outside a B17 rebuild it does nothing.
    func noteUserSeek(to sec: Double) {
        if didPlayToEnd { didPlayToEnd = false }
        guard isRebuildingItem, sec.isFinite else { return }
        rebuildUserSeekSec = sec
    }

    /// Fetches the Now Playing artwork once per coordinator (poster first, 400×600) and encodes it
    /// off the main actor. When it lands after the item exists, the current item's metadata is
    /// replaced once; later items pick it up in `decorate`.
    private func startArtworkFetch() {
        guard artworkTask == nil, let url = NativeNowPlayingMetadata.artworkURL(context: context) else { return }
        artworkTask = Task { @MainActor [weak self] in
            let request = ArtworkDecodeRequest(size: .points(width: 400, height: 600), fill: true, scale: 1)
            guard let image = await ImageFallbackPlan.load(candidates: [url], request: request) else { return }
            let jpeg = await Task.detached(priority: .utility) { image.jpegData(compressionQuality: 0.8) }.value
            guard let self, !Task.isCancelled, let jpeg else { return }
            self.artworkMetadata = NativeNowPlayingMetadata.artworkItem(jpeg: jpeg)
            if let item = self.playerItem {
                item.externalMetadata = self.metadataTextItems + [self.artworkMetadata!]
            }
            print("[NativePlayer] artwork attached (\(jpeg.count / 1024) KB)")
        }
    }

    private static func fileSize(_ dir: URL, _ name: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? Int) ?? 0
    }

    private func beginPlayback(remux: RemuxSession) {
        guard phase == .preparing, player == nil else { return }
        guard let map = remux.segmentMap else { failIfPreplayback("no segment map"); return }
        // Chapters (A6-native): libavformat's list, already on the playlist timeline; sorted,
        // deduped and clamped like mpv's, then trimmed at the duration.
        let raw = remux.chapters
        chapters = PlayerChapters.trimmed(
            PlayerChapters.parseIndexed(count: raw.count, title: { raw[$0].title }, time: { raw[$0].sec }),
            durationSec: map.totalDurationSec)
        chapterGroups = NativeChapterMarkers.groups(chapters, durationSec: map.totalDurationSec)
        // Audio menu data (D4): the worker published the full track list with its selection when it
        // inspected the streams — always before the map exists, so it's complete here.
        audioTracks = remux.audioTracks.map {
            NativeAudioTrack(streamIndex: $0.streamIndex, name: Self.audioTrackDisplayName($0),
                             playable: $0.playable, selected: $0.selected)
        }
        // External subtitles (D5): stream-attached files plus the addon-fetched list (the same
        // source the mpv player side-loads — streams rarely attach their own), offered as WebVTT
        // renditions in the synthesized master. The server downloads/converts on first selection.
        // Embedded text tracks (info-panel W2) come first — they're the file's own — then addon files.
        let embeddedRenditions = SubtitleVTT.embeddedRenditions(tracks: remux.subtitleTracks,
                                                                availableSinks: remux.subtitleSinkIndices, after: [])
        let addonRenditions = SubtitleVTT.renditions(from: context.externalSubtitles + addonSubtitles)
            .map { r in SubtitleRendition(index: r.index + embeddedRenditions.count, name: r.name,
                                          language: r.language, source: r.source) }
        var subtitleRenditions = embeddedRenditions + addonRenditions
        // Names must be unique within the group (AVPlayer keys options by name) — addon names are
        // deduped among themselves; dedupe them against the embedded ones too.
        var seen = Set<String>()
        subtitleRenditions = subtitleRenditions.map { r in
            var name = r.name, n = 2
            while !seen.insert(name).inserted { name = "\(r.name) \(n)"; n += 1 }
            return name == r.name ? r : SubtitleRendition(index: r.index, name: name, language: r.language,
                                                          source: r.source, forced: r.forced, hearingImpaired: r.hearingImpaired)
        }
        embeddedSubtitleCount = embeddedRenditions.count
        subtitleRenditionsByName = Dictionary(subtitleRenditions.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        print("[NativePlayer] subtitle renditions: \(subtitleRenditions.count) (\(embeddedRenditions.count) embedded)"
              + (subtitleRenditions.isEmpty ? "" : " — \(subtitleRenditions.prefix(6).map(\.name).joined(separator: ", "))\(subtitleRenditions.count > 6 ? ", …" : "")"))
        // A device that already fell back to the reduced master form keeps it across an
        // audio-switch rebuild (same video stream — the full form would just fail again).
        var signaling = remux.videoSignaling ?? VideoSignaling(codecs: "")
        if signalingAttempt > 0 { signaling.supplementalCodecs = nil }
        let selectedAudio = remux.audioTracks.first(where: \.selected)
        // Audio renditions (info-panel W3): every playable track, the initially produced one DEFAULT.
        var audioNames = Set<String>()
        let audioRenditions = remux.audioTracks.filter(\.playable).map { track -> AudioRendition in
            // NAME must be unique within the group (two untitled tracks with the same language,
            // codec and layout otherwise collide) — suffix duplicates.
            let base = Self.audioTrackDisplayName(track)
            var name = base, n = 2
            while !audioNames.insert(name).inserted { name = "\(base) \(n)"; n += 1 }
            return AudioRendition(streamIndex: track.streamIndex, name: name,
                                  language: track.language, channels: track.channels,
                                  codecToken: track.codecToken, isDefault: track.selected)
        }
        audioRenditionsByName = Dictionary(uniqueKeysWithValues: audioRenditions.map { ($0.name, $0.streamIndex) })
        selectedAudioBox.value = selectedAudio?.streamIndex
        // The forced-only decision needs the audio the viewer will hear (shared plan semantics).
        resolveLanguagePlan(selectedAudioTrack: selectedAudio.map { track in
            AudioTrack(
                index: 0, id: String(track.streamIndex),
                label: track.title ?? track.language ?? "",
                language: track.language, isSelected: true)
        })
        let initialFlags = subtitleFlags(for: subtitleRenditions)
        currentSubtitleRenditions = subtitleRenditions
        currentSubtitleFlags = initialFlags
        servedAddonURLs = Set((context.externalSubtitles + addonSubtitles).map(\.url))
        let server = LocalHLSServer(rootDir: remux.outputDir, map: map,
                                    signaling: signaling,
                                    audioRenditions: audioRenditions,
                                    activeAudio: { remux.activeAudioStream },
                                    selectedAudio: { [box = selectedAudioBox] in box.value },
                                    requestAudioTrack: { remux.selectAudio(streamIndex: $0, atSegment: $1) },
                                    bandwidth: remux.estimatedBandwidth,
                                    subtitles: subtitleRenditions,
                                    subtitleFlags: initialFlags,
                                    // SDH stripping, native path (mpv sets sub-filter-sdh instead) —
                                    // applies to the addon-VTT conversions this server performs.
                                    stripSdh: playerSettings?.subtitleStyle.stripSdh ?? false,
                                    // Player P3: the I-frame rendition (FF/RW scan) follows Developer ›
                                    // Seek Preview Frames; Off = the pre-P3 master. Read per playback.
                                    // BUG-168: and only with Developer › Native I-frame Scan (A/B) on
                                    // (off by default), because AVKit's scrub preview never asks for
                                    // an I-frame on tvOS 27 and shows an empty box instead.
                                    iFrames: SeekPreviewMode.currentAllowsNativeIFrames(),
                                    producingInfo: { remux.producingInfo },
                                    requestReposition: { remux.reposition(toSegment: $0) })
        self.server = server
        // Subtitle delay (B3): publish each addon rendition under N interchangeable slots so a delay
        // change can be forced past AVPlayer's per-item playlist cache, and bake the restored delay
        // into generation 0 — the first body AVPlayer ever fetches is already re-timed.
        if subtitleRenditions.contains(where: { !$0.isEmbedded }) {
            server.setSubtitleSlots(Self.subtitleDelaySlots)
        }
        if subtitleDelayMs != 0 { server.setSubtitleDelay(ms: subtitleDelayMs) }
        server.start(masterName: remux.masterPlaylistName) { [weak self] url in
            guard let self else { return }
            guard let url else { self.failIfPreplayback("server bind failed"); return }
            print("[NativePlayer] serving \(url.absoluteString)")
            self.servedURL = url
            let item = AVPlayerItem(url: url)
            self.decorate(item)
            print(NativeSubtitleStyle.logLine(self.subtitleStyleInput))
            let player = AVPlayer(playerItem: item)
            self.applyLanguagePlan(to: player)
            self.playerItem = item
            self.player = player
            self.audibleGroup = nil
            // `isPaused` means a pause DURING playback: the pre-playback `.paused` state a fresh
            // player reports before it ever plays is ignored (it would masquerade as a user pause).
            self.hasStartedPlaying = false
            self.timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if status == .playing { self.hasStartedPlaying = true }
                    if status == .playing || (status == .paused && self.playIssued) {
                        self.advanceLoadingStage(.started)
                    }
                    guard self.hasStartedPlaying else { return }
                    let paused = status == .paused
                    if self.isPaused != paused { self.isPaused = paused }
                }
            }
            self.observeMediaSelection(item: item, player: player)
            self.phase = .playing
            self.advanceLoadingStage(.buffering(percent: nil))
            self.observePlayback(player: player, item: item)
            #if DEBUG
            self.startSubtitleDelaySpike()
            #endif
        }
    }

    /// Item failed before playback ever started. Attempt 0 → retry once with minimal signaling
    /// (some AVPlayer builds reject the full CODECS/SUPPLEMENTAL form at the master stage);
    /// attempt 1 → give up and hand the context to mpv.
    /// P5 Wave 3 (2026-10-20, from the S2 spike): the one signaling retry exists to drop
    /// SUPPLEMENTAL-CODECS for AVPlayer builds that reject the DV supplemental form. When the
    /// master never carried one (P5, HDR10, SDR, H.264) the retry replays the same playlist and
    /// costs a second ~20 s item failure before the mpv failover (console-s1b: ~50 s in all).
    nonisolated static func signalingRetryAllowed(attempt: Int, supplementalCodecs: String?) -> Bool {
        attempt == 0 && !(supplementalCodecs ?? "").isEmpty
    }

    private func handlePrePlaybackItemFailure(player: AVPlayer) {
        // iframe.m3u8 renders nil (skipped) when the I-frame rendition is off.
        for name in ["master.m3u8", "media.m3u8", SegmentMap.iFramePlaylistName] {
            guard let playlist = server?.renderedPlaylist(named: name) else { continue }
            // Prefix every line so console filters on "NativePlayer" keep the playlist content. The
            // media playlist can be long (one line per segment) — cap the dump.
            let prefixed = playlist.components(separatedBy: "\n").prefix(40)
                .map { "[NativePlayer] | \($0)" }.joined(separator: "\n")
            print("[NativePlayer] served \(name) (\(playlist.count) chars):\n\(prefixed)")
        }
        if let dir = remux?.outputDir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let listing = names.sorted().prefix(24).map { "\($0)=\(Self.fileSize(dir, $0))b" }.joined(separator: " ")
            print("[NativePlayer] output dir: \(listing)")
        }
        // P5 spike (2026-10-20): the CoreMedia code alone told the story (-12927 admission, -4 no
        // parameter sets, -16041 mangled samples); print the chain so the next one does too.
        if let err = player.currentItem?.error as NSError? {
            var chain: [String] = []
            var cur: NSError? = err
            while let e = cur {
                chain.append("\(e.domain) \(e.code) \(e.userInfo.filter { $0.key != NSUnderlyingErrorKey })")
                cur = e.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            print("[NativePlayer] item error chain: " + chain.joined(separator: " ← "))
        }
        let retryAllowed = Self.signalingRetryAllowed(attempt: signalingAttempt,
                                                      supplementalCodecs: remux?.videoSignaling?.supplementalCodecs)
        guard retryAllowed, let servedURL else {
            if signalingAttempt == 0 { print("[NativePlayer] no SUPPLEMENTAL-CODECS to drop — skipping the signaling retry") }
            print("[NativePlayer] failing over to mpv (item failed before playback started)")
            // C-7: AVPlayer's errors here are about our loopback origin.
            classifyFailure(PlaybackFailureClassifier.fromNSError(player.currentItem?.error, origin: .loopback))
            phase = .failed("item failed before start")
            return
        }
        signalingAttempt = 1
        // Retry once with reduced signaling: drop only SUPPLEMENTAL-CODECS (some AVPlayer builds
        // reject the DV supplemental form at the master stage). The full RFC 6381 CODECS token and
        // VIDEO-RANGE MUST stay — bare tags are non-compliant, and PQ media without a declared
        // VIDEO-RANGE is itself rejected on tvOS 27 (the retry would fail for the wrong reason).
        var reduced = remux?.videoSignaling ?? VideoSignaling(codecs: "hvc1")
        reduced.supplementalCodecs = nil
        server?.setSignaling(reduced)
        print("[NativePlayer] retrying without SUPPLEMENTAL-CODECS (CODECS=\(reduced.codecs) RANGE=\(reduced.videoRange ?? "-"))")
        observeTask?.cancel()
        // Cache-bust so AVPlayer refetches the master (the server ignores query strings).
        let retryURL = URL(string: servedURL.absoluteString + "?r=1") ?? servedURL
        let item = AVPlayerItem(url: retryURL)
        decorate(item)
        playerItem = item
        legibleGroup = nil
        audibleGroup = nil            // per-item groups; the retry item gets its own observer too
        player.replaceCurrentItem(with: item)
        observeMediaSelection(item: item, player: player)
        observePlayback(player: player, item: item)
    }

    // MARK: - End of item (P5 B22)

    /// Observes `AVPlayerItemDidPlayToEndTime` for the CURRENT item only: every item swap calls
    /// `observePlayback`, which replaces the observer. The served playlist carries
    /// `EXT-X-ENDLIST`, so the notification fires at the real end.
    private func installEndObserver(for item: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playerItem === item else { return }
                print("[NativePlayer] item played to end")
                self.didPlayToEnd = true
            }
        }
    }

    private func removeEndObserver() {
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
    }

    /// Post-play "Play Again": back to the start, playing.
    func replayFromStart() {
        didPlayToEnd = false
        guard let player else { return }
        noteUserSeek(to: 0)
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in player.play() }
        }
    }

    /// The post-play cover went away without a replay.
    func clearEnded() {
        didPlayToEnd = false
    }

    // MARK: - AVPlayer observation (resume + progress + Trakt)

    private func observePlayback(player: AVPlayer, item: AVPlayerItem, rebuild: RebuildTarget? = nil) {
        installEndObserver(for: item)
        observeTask = Task { @MainActor [weak self] in
            var readied = false
            var waitingTicks = 0
            var notReadyTicks = 0
            var lastProducingSeg = 0
            var pendingResumePercent: Double?
            while !Task.isCancelled {
                guard let self, self.player === player else { return }

                if !readied, item.status == .readyToPlay, let rebuild {
                    readied = true
                    await self.finishRebuild(rebuild, player: player, item: item)
                    guard !Task.isCancelled, self.player === player else { return }
                } else if !readied, item.status == .readyToPlay {
                    readied = true
                    print("[NativePlayer] item readyToPlay")
                    if self.readyUptime == nil { self.readyUptime = ProcessInfo.processInfo.systemUptime }
                    let duration = CMTimeGetSeconds(item.duration)
                    // Publish the duration as soon as the item knows it (the tick keeps it current);
                    // `lastDurationSec` stays tick-driven so `stop()`'s final record is unchanged.
                    if duration.isFinite, duration > 0, self.durationSec != duration { self.durationSec = duration }
                    // A failure-alert retry resumes where the failed attempt stopped, Start Over
                    // included (mpv's `computeResumePosition` rule). Otherwise Start Over ignores saved
                    // progress (gated here: `PlaybackProgressRecorder` is untouched).
                    let retryResume = self.context.resumeAtSec.flatMap { $0 > 10 ? $0 : nil }
                    let startOver = retryResume == nil && self.context.startFromBeginning
                    if startOver { print("[Failover] start over: ignoring saved progress") }
                    let resume: Double? = startOver
                        ? nil
                        : (retryResume ?? self.recorder.resumePositionSec(actualDurationSec: duration.isFinite ? duration : 0))
                    // Percentage-only row and no finite duration yet: apply on the first tick that has one.
                    if resume == nil, !startOver, !(duration.isFinite && duration > 0) {
                        pendingResumePercent = self.recorder.pendingResumePercent()
                    }
                    if let resume {
                        // The resume seek (user-initiated for skip logic).
                        self.didResumeSeek = true
                        self.onResumeSeekBegin?(resume)
                        await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                        // r2 P3: `stop()` (Menu during the resume seek) or a mid-play fallback can
                        // overtake the await. Without this, `play()` restarted a released player
                        // and a tracker "start" went out after `stop()`'s "stop".
                        guard !Task.isCancelled, self.player === player, self.playerItem === item,
                              self.phase == .playing else {
                            print("[NativePlayer] resume seek overtaken (stopped, swapped or handed to mpv)")
                            return
                        }
                        self.lastPositionSec = resume
                        // Where it really landed (default tolerance: can be past the target).
                        self.onResumeSeekCompleted?(CMTimeGetSeconds(player.currentTime()))
                    }
                    player.play()
                    self.playIssued = true
                    if !self.traktStarted {
                        self.traktStarted = true
                        self.recorder.startTrakt(positionSec: self.lastPositionSec, durationSec: duration.isFinite ? duration : 0)
                        self.recorder.startTrackers(positionSec: self.lastPositionSec, durationSec: duration.isFinite ? duration : 0)
                    }
                    self.loadLegibleSelection(item: item)
                } else if item.status == .failed {
                    print("[NativePlayer] item FAILED — \(item.error?.localizedDescription ?? "unknown")")
                    Self.dumpItemLogs(item)
                    // THIS item never became ready → retry with minimal signaling, then hand to mpv.
                    // (Keyed on the item, not lifetime state: after an audio-switch rebuild the
                    // coordinator has a duration from the previous item, but a pre-ready failure of
                    // the new one still belongs to the signaling retry path.)
                    if !readied, rebuild != nil {
                        // A B17 rebuild that failed is our swap, not the link (C3): never the
                        // signaling retry, never remembered.
                        self.classifyFailure(.init(.local))
                        self.fallbackMidPlay("late subtitle rebuild failed")
                    } else if !readied {
                        self.handlePrePlaybackItemFailure(player: player)
                    } else {
                        // Failed AFTER playback started — e.g. a forward seek past the linear remux
                        // frontier that the JIT server fast-503'd until AVPlayer gave up. Hand to mpv
                        // (which seeks anywhere via its own demuxer) at the current/target position.
                        self.classifyFailure(PlaybackFailureClassifier.fromNSError(item.error, origin: .loopback, midPlay: true))
                        self.fallbackMidPlay("item failed mid-play")
                    }
                    return
                } else if !readied {
                    // Blind-spot coverage: the item can sit in .unknown forever (bad playlist, codec
                    // rejection) with no state change to observe. Surface why every ~10s.
                    notReadyTicks += 1
                    if rebuild != nil, notReadyTicks >= 60 {   // 12 s without ready: the picture is frozen
                        self.classifyFailure(.init(.local))
                        self.fallbackMidPlay("late subtitle rebuild failed")
                        return
                    }
                    if notReadyTicks % 50 == 0 {          // 50 ticks × 200ms ≈ 10s
                        print("[NativePlayer] item still not ready after ~\(notReadyTicks / 5)s (status=\(item.status.rawValue))")
                        Self.dumpItemLogs(item)
                    }
                }

                if readied {
                    // Sampled before anything below can await (the resume seek): `secondsPlayed`
                    // counts only ticks that both begin and end with the player actually playing.
                    self.playClock.note(playing: player.timeControlStatus == .playing,
                                        at: ProcessInfo.processInfo.systemUptime)
                    var pos = CMTimeGetSeconds(player.currentTime())
                    let dur = CMTimeGetSeconds(item.duration)
                    // Live detection, sampled once per tick of the ready item (see `isLiveStream`).
                    if item.duration.isIndefinite { self.reportsLive = true }
                    self.durationGrowth = LivePlaybackPolicy.nextDurationGrowth(
                        self.durationGrowth, mediaKey: self.context.url.absoluteString, durationSec: dur,
                        fromRequestedMedia: true)
                    // A position jump that is not the app's own seek = a user seek. Reset the stall
                    // budget so back-to-back scrubs (each costing a ~10s reposition) can't
                    // accumulate into a false mpv fallback.
                    if pos.isFinite {
                        let userSeek = self.onPositionTick?(self.lastPositionSec, pos)
                            ?? (abs(pos - self.lastPositionSec) > SkipSegmentPlanner.userJumpThresholdSec)
                        if userSeek { waitingTicks = 0; self.lastUserSeekUptime = ProcessInfo.processInfo.systemUptime }
                    }
                    if let pct = pendingResumePercent, pos.isFinite, dur.isFinite, dur > 0 {
                        pendingResumePercent = nil
                        // Only while still near the start, so a user scrub is never overridden.
                        if pos < 30 {
                            let target = dur * pct / 100
                            if target > 10 {
                                // The pending-percentage resume seek (user-initiated for skip logic).
                                self.didResumeSeek = true
                                self.onResumeSeekBegin?(target)
                                await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                                self.lastPositionSec = target
                                // `pos` was read before the seek: use the real landing, not a stale
                                // pre-seek position the skip planner could auto-skip from.
                                let landed = CMTimeGetSeconds(player.currentTime())
                                pos = landed.isFinite ? landed : target
                                self.onResumeSeekCompleted?(pos)
                            }
                        }
                    }
                    if pos.isFinite, dur.isFinite, dur > 0 {
                        let paused = player.timeControlStatus != .playing
                        self.lastPositionSec = pos
                        self.lastDurationSec = dur
                        if self.didPlayToEnd, pos < dur - 2, player.timeControlStatus == .playing { self.didPlayToEnd = false }
                        self.recorder.record(positionSec: pos, durationSec: dur, isPaused: paused, speed: 1, flush: false,
                                             isLive: self.isLiveStream)
                        self.refreshActiveAudioTrack()
                        if self.audibleGroup == nil { self.handleMediaSelectionChange(item: item, player: player) }
                        else { self.syncAudioSelection(item: item, player: player) }
                        self.onTick?(pos, dur)
                    }
                    self.checkLateSubtitles()

                    // The stream has now played for 5 minutes: tell the host once (failover policy).
                    if !self.healthyReported, let onPlaybackHealthy = self.onPlaybackHealthy,
                       player.timeControlStatus == .playing,
                       self.secondsPlayed >= PlaybackFailoverPolicy.healthySeconds {
                        self.healthyReported = true
                        print("[Failover] native healthy after \(Int(self.secondsPlayed)) s")
                        onPlaybackHealthy(self.secondsPlayed)
                    }

                    // Stall diagnostics: if the player sits in a waiting state across several ticks,
                    // dump why — the item's error log carries segment/format errors (decode
                    // rejections, 404s) that are otherwise invisible outside Xcode.
                    if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        waitingTicks += 1
                        // A stall with the remux still ADVANCING is a seek being refilled at source
                        // speed, not a dead session — reset the budget on every producing-segment
                        // advance. Only a frozen remux (dead source) runs the clock out.
                        let producing = self.remux?.producingInfo.producing ?? 0
                        if producing != lastProducingSeg {
                            lastProducingSeg = producing
                            waitingTicks = 1
                        }
                        if waitingTicks == 3 || waitingTicks % 10 == 3 {
                            let reason = player.reasonForWaitingToPlay?.rawValue ?? "?"
                            print("[NativePlayer] waiting (\(reason)) at \(String(format: "%.1f", CMTimeGetSeconds(player.currentTime())))s")
                            Self.dumpItemLogs(item)
                        }
                        // Sustained stall (~30s at 3s/tick) with NO remux progress: dead/stalled
                        // source. Hand to mpv at the current position rather than spin forever.
                        if waitingTicks >= 10 {
                            self.classifyFailure(.init(.network))
                            self.fallbackMidPlay("stalled ~30s with no remux progress")
                            return
                        }
                    } else {
                        waitingTicks = 0
                    }
                }
                try? await Task.sleep(nanoseconds: readied ? 3_000_000_000 : 200_000_000)
            }
        }
    }

    /// Follow AVPlayer's audible selection (system Audio tab): remember the selected track for the
    /// server (only its rendition-file requests may switch the worker) and kick the worker's switch
    /// proactively. The subtitle selection is deliberately left alone — like the mpv screen (which
    /// auto-selects once) and the old rebuild path (which restored the previous choice), an audio
    /// switch must not override an explicit subtitle pick or Off.
    private func observeMediaSelection(item: AVPlayerItem, player: AVPlayer) {
        if let old = mediaSelectionObserver { NotificationCenter.default.removeObserver(old) }
        mediaSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMediaSelectionChange(item: item, player: player) }
        }
    }

    private func handleMediaSelectionChange(item: AVPlayerItem, player: AVPlayer) {
        guard playerItem === item else { return }
        selectionVersion &+= 1
        noteLegibleSelection()
        if audibleGroup == nil {
            Task { @MainActor [weak self] in
                let group = (try? await item.asset.loadMediaSelectionGroup(for: .audible)) ?? nil
                guard let self, self.playerItem === item, let group else { return }
                self.audibleGroup = group
                self.syncAudioSelection(item: item, player: player)
            }
        } else {
            syncAudioSelection(item: item, player: player)
        }
    }

    /// Compare AVPlayer's audible selection with what we last relayed; on a change, relay it to the
    /// server/worker. Cheap — called on every tick and on the media-selection notification.
    private func syncAudioSelection(item: AVPlayerItem, player: AVPlayer) {
        // C-2: while a B17 rebuild restores the selection, the new item's initial pick must not
        // reach the worker.
        guard !isRebuildingItem else { return }
        guard let group = audibleGroup,
              let option = item.currentMediaSelection.selectedMediaOption(in: group),
              let stream = Self.renditionStream(for: option, byName: audioRenditionsByName,
                                                tracks: remux?.audioTracks ?? []),
              selectedAudioBox.value != stream else { return }
        selectedAudioBox.value = stream
        print("[NativePlayer] audio selection → stream \(stream) (\(option.displayName))")
        remux?.selectAudio(streamIndex: stream, atSegment: nil)
    }

    /// Map an audible option back to our track. `displayName` is AVFoundation's LOCALIZED language
    /// ("French"), not the rendition NAME — the NAME is the option's common-metadata title. Fall back
    /// to the language tag when it identifies exactly one playable track.
    private static func renditionStream(for option: AVMediaSelectionOption, byName: [String: Int],
                                        tracks: [RemuxAudioTrack]) -> Int? {
        let title = AVMetadataItem.metadataItems(from: option.commonMetadata,
                                                 filteredByIdentifier: .commonIdentifierTitle).first?.stringValue
        if let title, let stream = byName[title] { return stream }
        if let stream = byName[option.displayName] { return stream }
        if let tag = option.extendedLanguageTag {
            let matches = tracks.filter { $0.playable && $0.language.map {
                PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: $0, targetLanguage: tag) } == true }
            if matches.count == 1 { return matches[0].streamIndex }
        }
        return nil
    }

    /// Cache the item's legible media-selection group (Info tab's "Subtitles" row).
    private func loadLegibleSelection(item: AVPlayerItem) {
        Task { @MainActor [weak self] in
            let group = (try? await item.asset.loadMediaSelectionGroup(for: .legible)) ?? nil
            guard let self, self.playerItem === item else { return }
            self.legibleGroup = group
            self.selectionVersion &+= 1
            if self.legibleSnapshot == nil { self.legibleSnapshot = .some(self.currentLegibleName) }
        }
    }

    private var currentLegibleName: String? {
        currentSubtitleOption.map { Self.canonicalSubtitleName(Self.renditionName(of: $0)) }
    }

    /// B17: a legible selection that differs from the last one seen (the system popover included)
    /// marks the selection as touched. Our own rebuild restore is excluded.
    private func noteLegibleSelection() {
        guard !isRebuildingItem, let snapshot = legibleSnapshot, legibleGroup != nil else { return }
        let now = currentLegibleName
        if now != snapshot {
            legibleTouched = true
            legibleSnapshot = .some(now)
        }
    }

    // MARK: - Top panel: media selection API (Subtitles / Audio tabs)

    /// Select a legible option (nil = Off). AVPlayer honours manual picks over the criteria.
    func select(subtitle option: AVMediaSelectionOption?) {
        legibleTouched = true
        subtitleRefetchRestoreTask?.cancel(); subtitleRefetchRestoreTask = nil
        isRefetchingSubtitles = false
        guard let item = playerItem, let group = legibleGroup else { return }
        item.select(option, in: group)
        print("[NativePlayer] subtitle selection → \(option.map(Self.renditionName(of:)) ?? "Off")")
        selectionVersion &+= 1
    }

    // MARK: - Subtitle delay

    /// The rendition NAME without the delay-slot suffix the master's twin entries carry.
    static func canonicalSubtitleName(_ name: String) -> String {
        guard let r = name.range(of: LocalHLSServer.slotNameSuffix) else { return name }
        return String(name[..<r.lowerBound])
    }

    /// Which delay slot an option's NAME belongs to (0 = the primary entry shown in the panel).
    static func subtitleSlot(ofName name: String) -> Int {
        guard let r = name.range(of: LocalHLSServer.slotNameSuffix) else { return 0 }
        return Int(name[r.upperBound...]) ?? 0
    }

    static func clampSubtitleDelay(_ ms: Int) -> Int {
        let step = Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_STEP_MS)
        let minMs = Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MIN_MS)
        let maxMs = Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MAX_MS)
        let snapped = step > 0 ? Int((Double(ms) / Double(step)).rounded()) * step : ms
        return max(minMs, min(maxMs, snapped))
    }

    /// Apply a new subtitle delay: persist it immediately, re-time the VTT bodies the local server
    /// hands out, and — when an addon rendition is showing — nudge AVPlayer into refetching that
    /// body. Coalesced, because a viewer walks the value in 0.1 s steps.
    func setSubtitleDelay(ms: Int) {
        let clamped = Self.clampSubtitleDelay(ms)
        guard clamped != subtitleDelayMs else { return }
        subtitleDelayMs = clamped
        PlayerTrackPreferenceStorage.shared.saveSubtitleDelayMs(videoId: context.videoId, delayMs: Int32(clamped))
        server?.setSubtitleDelay(ms: clamped)
        subtitleDelayApplyTask?.cancel()
        subtitleDelayApplyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.forceSubtitleRefetch()
        }
    }

    /// Reset the delay to zero (panel's Reset chip). Writes 0 rather than deleting the key, so a
    /// deliberate reset survives a relaunch instead of falling back to a stale value.
    func resetSubtitleDelay() { setSubtitleDelay(ms: 0) }

    // MARK: - Sync Line (P5 B19)

    /// The playback position in ms, read at the moment Sync Line is pressed. `lastPositionSec` only
    /// moves on the 3 s tick, so ask the player.
    func currentPositionMs() -> Int64 {
        guard let t = player?.currentTime(), t.isValid, t.seconds.isFinite, t.seconds >= 0 else { return 0 }
        return Int64((t.seconds * 1000).rounded())
    }

    /// Cues of the selected add-on subtitle; nil when none is selected, it is embedded, or loading failed.
    func selectedAddonSubtitleCues() async -> [SubtitleSyncCue]? {
        guard let name = currentLegibleName, let r = subtitleRenditionsByName[name], !r.isEmbedded else { return nil }
        return await SyncLineCueLoader.load(vtt: server?.cachedBaseVTT(index: r.index), fallbackURL: r.sourceURL,
                                           stripSdh: playerSettings?.subtitleStyle.stripSdh ?? false)
    }

    /// Make AVPlayer re-read the selected subtitle rendition's body at the current delay.
    private func forceSubtitleRefetch() {
        guard let item = playerItem, let group = legibleGroup,
              let current = item.currentMediaSelection.selectedMediaOption(in: group) else {
            print("[NativePlayer] subtitle delay \(subtitleDelayMs)ms staged (no rendition showing)")
            return
        }
        let currentName = Self.renditionName(of: current)
        let canonical = Self.canonicalSubtitleName(currentName)
        // Embedded text tracks are per-segment VTTs written by the remux worker as it produces the
        // timeline; they are NOT re-timed by this mechanism (documented gap — B3).
        guard subtitleRenditionsByName[canonical]?.isEmbedded != true else {
            print("[NativePlayer] subtitle delay \(subtitleDelayMs)ms — embedded track, not re-timed")
            return
        }
        subtitleDelayChanges += 1
        // Fallback forcing function (off by default): hop to the next twin slot, a URI AVPlayer has
        // never fetched.
        if Self.subtitleDelaySlots > 1 {
            let nextSlot = subtitleDelayChanges % Self.subtitleDelaySlots
            let targetName = nextSlot == 0 ? canonical : canonical + LocalHLSServer.slotNameSuffix + String(nextSlot)
            if let target = group.options.first(where: { Self.renditionName(of: $0) == targetName }), target != current {
                item.select(target, in: group)
                selectionVersion &+= 1
                print("[NativePlayer] subtitle delay \(subtitleDelayMs)ms applied (slot \(nextSlot))")
                return
            }
        }
        // Off → the same option again. AVPlayer keeps the cached media playlist but refetches the
        // body, which is where the new cue times live.
        isRefetchingSubtitles = true
        item.select(nil, in: group)
        subtitleRefetchRestoreTask?.cancel()
        subtitleRefetchRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            defer { self?.isRefetchingSubtitles = false }
            guard !Task.isCancelled, let self, self.playerItem === item, self.legibleGroup === group else { return }
            // Codex review: a viewer pick during the window wins. Panel picks go through
            // `select(subtitle:)`, which cancels this task; a system-popover pick shows up as a
            // non-nil selection here. (`selectionVersion` can't be the token — our own
            // `select(nil)` bumps it asynchronously.)
            guard item.currentMediaSelection.selectedMediaOption(in: group) == nil else {
                print("[NativePlayer] subtitle delay reselect skipped — selection changed")
                return
            }
            item.select(current, in: group)
            self.selectionVersion &+= 1
            print("[NativePlayer] subtitle delay \(self.subtitleDelayMs)ms applied (reselect ‘\(currentName)’)")
        }
    }

    #if DEBUG
    /// B3 measurement harness. `debug.subDelaySpike` = "6:1500,12:-2000,18:3500" — at T seconds of
    /// wall clock after playback starts, apply a delay of N ms. The first entry is preceded by an
    /// explicit selection of the first addon rendition (the headless smoke run has no UI to pick
    /// one). Read the `[HLS]` request log to see whether AVPlayer refetched playlist + body.
    private func startSubtitleDelaySpike() {
        guard let spec = UserDefaults.standard.string(forKey: "debug.subDelaySpike"), !spec.isEmpty else { return }
        let steps: [(Double, Int)] = spec.split(separator: ",").compactMap {
            let parts = $0.split(separator: ":")
            guard parts.count == 2, let at = Double(parts[0]), let ms = Int(parts[1]) else { return nil }
            return (at, ms)
        }
        guard !steps.isEmpty else { return }
        print("[SubDelaySpike] armed: \(steps.map { "\($0.0)s→\($0.1)ms" }.joined(separator: " "))")
        Task { @MainActor [weak self] in
            // Wait for the legible group, then select the first slot-0 addon rendition.
            for _ in 0..<40 {
                if let self, let group = self.legibleGroup,
                   let first = group.options.first(where: {
                       let name = Self.renditionName(of: $0)
                       return Self.subtitleSlot(ofName: name) == 0
                           && self.subtitleRenditionsByName[Self.canonicalSubtitleName(name)]?.isEmbedded == false
                   }) {
                    self.select(subtitle: first)
                    print("[SubDelaySpike] selected ‘\(Self.renditionName(of: first))’ "
                          + "(group has \(group.options.count) options)")
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            var elapsed = 0.0
            for (at, ms) in steps.sorted(by: { $0.0 < $1.0 }) {
                let wait = max(0, at - elapsed)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                elapsed = at
                guard let self else { return }
                print("[SubDelaySpike] t=\(at)s applying \(ms)ms")
                self.setSubtitleDelay(ms: ms)
            }
            print("[SubDelaySpike] done")
        }
    }
    #endif

    /// Select an audible option; the remux worker is switched by `syncAudioSelection` on the
    /// next tick / media-selection notification, exactly as for a pick from the native popover.
    func select(audio option: AVMediaSelectionOption) {
        guard let item = playerItem, let group = audibleGroup, let player else { return }
        item.select(option, in: group)
        selectionVersion &+= 1
        syncAudioSelection(item: item, player: player)
    }

    var currentSubtitleOption: AVMediaSelectionOption? {
        guard let item = playerItem, let group = legibleGroup else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group)
    }

    var currentAudioOption: AVMediaSelectionOption? {
        guard let item = playerItem, let group = audibleGroup else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group)
    }

    /// The rendition NAME of an option (its common-metadata title); `displayName` is AVFoundation's
    /// localized language, which is not unique.
    static func renditionName(of option: AVMediaSelectionOption) -> String {
        AVMetadataItem.metadataItems(from: option.commonMetadata,
                                     filteredByIdentifier: .commonIdentifierTitle).first?.stringValue ?? option.displayName
    }

    /// Whether the top panel should list this subtitle option under "Show only preferred languages".
    func subtitleOptionAllowed(_ option: AVMediaSelectionOption) -> Bool {
        guard languagePlan.onlyPreferredLanguages else { return true }
        let allowed = languagePlan.subtitleFilterLanguages
        guard !allowed.isEmpty, let tag = option.extendedLanguageTag else { return true }
        return allowed.contains { PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: tag, targetLanguage: $0) }
    }

    /// True once the addon subtitle fetch has completed (top panel empty-state copy).
    var addonSubtitlesFetched: Bool { subsFetchDone }

    /// Metadata chips for the Info tab (the dynamic half — the screen prepends context-derived
    /// year/runtime/rating and appends genres). Bare values, Infuse-style.
    func infoChips() -> [PlayerPanelChip] {
        var chips: [PlayerPanelChip] = []
        if lastDurationSec > 0 { chips.append(PlayerPanelChip(text: Self.runtimeString(lastDurationSec), isRuntime: true)) }
        if let s = remux?.videoSignaling {
            if s.height >= 2000 { chips.append(PlayerPanelChip(text: "4K")) }
            else if s.height >= 1000 { chips.append(PlayerPanelChip(text: "1080p")) }
            else if s.height >= 700 { chips.append(PlayerPanelChip(text: "720p")) }
            else if s.height > 0 { chips.append(PlayerPanelChip(text: "SD")) }
            if s.supplementalCodecs != nil { chips.append(PlayerPanelChip(text: "Dolby Vision")) }
            else if s.videoRange == "PQ" { chips.append(PlayerPanelChip(text: "HDR10")) }
            else if s.videoRange == "HLG" { chips.append(PlayerPanelChip(text: "HLG")) }
            let codec = s.codecs.lowercased()
            if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") || codec.hasPrefix("dvh1") || codec.hasPrefix("dvhe") {
                chips.append(PlayerPanelChip(text: "HEVC"))
            } else if codec.hasPrefix("avc1") || codec.hasPrefix("avc3") {
                chips.append(PlayerPanelChip(text: "H.264"))
            }
            if s.frameRate > 0 { chips.append(PlayerPanelChip(text: String(format: "%.6g fps", s.frameRate))) }
        }
        if let audio = audioTracks.first(where: \.selected)?.name {
            // Drop the leading language ("English · ") — the chip is about the format.
            let parts = audio.components(separatedBy: " \u{00B7} ")
            chips.append(PlayerPanelChip(text: parts.count > 1 ? parts.dropFirst().joined(separator: " \u{00B7} ") : audio))
        }
        if let event = playerItem?.accessLog()?.events.last, event.indicatedBitrate > 0 {
            chips.append(PlayerPanelChip(text: String(format: "%.1f Mbps", event.indicatedBitrate / 1_000_000)))
        } else if let bandwidth = remux?.estimatedBandwidth, bandwidth > 0 {
            chips.append(PlayerPanelChip(text: String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000)))
        }
        return chips
    }

    private static func runtimeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? String(localized: "\(h) h \(m) min") : String(localized: "\(m) min")
    }

    // MARK: - Audio track display names

    /// 10-foot menu label: localized language, codec + channel layout, then the container's track
    /// title when it adds information ("Commentary", "Atmos"). E.g. "English · TrueHD 7.1 · Atmos".
    private static func audioTrackDisplayName(_ track: RemuxAudioTrack) -> String {
        var parts: [String] = []
        if let tag = track.language?.lowercased(), tag != "und",
           let language = Locale.current.localizedString(forLanguageCode: Self.iso639BtoT[tag] ?? tag) {
            parts.append(language)
        }
        let codec = Self.audioCodecDisplay[track.codec] ?? track.codec.uppercased()
        parts.append("\(codec) \(Self.channelText(track.channels))")
        if let title = track.title, !title.isEmpty, title.count <= 42 { parts.append(title) }
        return parts.isEmpty ? String(localized: "Track \(track.streamIndex)") : parts.joined(separator: " \u{00B7} ")
    }

    /// MKV language tags are usually ISO 639-2/B; Locale wants /T for the codes where they differ.
    private static let iso639BtoT: [String: String] = [
        "fre": "fra", "ger": "deu", "dut": "nld", "chi": "zho", "cze": "ces", "gre": "ell",
        "ice": "isl", "per": "fas", "rum": "ron", "slo": "slk", "arm": "hye", "geo": "kat",
        "may": "msa", "alb": "sqi", "baq": "eus", "bur": "mya", "mac": "mkd", "tib": "bod",
        "wel": "cym",
    ]

    private static let audioCodecDisplay: [String: String] = [
        "aac": "AAC", "ac3": "Dolby Digital", "eac3": "Dolby Digital+", "truehd": "TrueHD",
        "dts": "DTS", "flac": "FLAC", "alac": "ALAC", "mp3": "MP3", "opus": "Opus",
        "vorbis": "Vorbis",
    ]

    private static func channelText(_ channels: Int) -> String {
        switch channels {
        case 1: return String(localized: "Mono")
        case 2: return String(localized: "Stereo")
        case 3: return "2.1"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    // MARK: - Stream Info tab

    /// Rows for the native player's Stream Info tab: routing decision, remux signaling, segment-map
    /// shape, and live transfer stats from the item's access log. Called on playback ticks.
    /// Follow the remux's active track (the system Audio tab switches it — W3); the published list
    /// only changes when the active track does.
    private func refreshActiveAudioTrack() {
        guard let remux, remux.activeAudioStream != audioTracks.first(where: \.selected)?.streamIndex else { return }
        audioTracks = remux.audioTracks.map {
            NativeAudioTrack(streamIndex: $0.streamIndex, name: Self.audioTrackDisplayName($0),
                             playable: $0.playable, selected: $0.selected)
        }
    }

    func streamInfoRows(routingNote: String?) -> [NativeInfoRow] {
        refreshActiveAudioTrack()
        var rows: [NativeInfoRow] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append(NativeInfoRow(label: label, value: value)) }
        }
        var engine = routingNote ?? String(localized: "Native")
        if subtitleDelayMs != 0 {
            // Device-pass readout: the persisted/applied delay, mirroring the mpv Engine row.
            engine += String(format: " \u{00B7} subs %+.2f s", Double(subtitleDelayMs) / 1000)
        }
        add(String(localized: "Engine"), engine)
        if let s = remux?.videoSignaling {
            add(String(localized: "Video"), s.codecs)
            add("Dolby Vision", s.supplementalCodecs)
            add(String(localized: "Dynamic range"), s.videoRange)
            if s.width > 0, s.height > 0 {
                let fps = s.frameRate > 0 ? String(format: " · %.6g fps", s.frameRate) : ""
                add(String(localized: "Resolution"), "\(s.width)\u{00D7}\(s.height)\(fps)")
            }
        }
        // The display name already carries language · codec · layout · title; the RFC 6381 token
        // adds nothing a viewer needs and pushes the row onto a second line.
        add(String(localized: "Audio"), audioTracks.first(where: \.selected)?.name ?? remux?.audioCodecToken)
        if audioTracks.count == 1 {
            add(String(localized: "Audio tracks"), String(localized: "1 (this file has no alternate audio)"))
        } else if audioTracks.count > 1 {
            let unplayable = audioTracks.filter { !$0.playable }.count
            add(String(localized: "Audio tracks"), unplayable == 0
                ? String(localized: "\(audioTracks.count) · in the Audio tab")
                : String(localized: "\(audioTracks.count) · \(audioTracks.count - unplayable) in the Audio tab (\(unplayable) unsupported)"))
        }
        // What the viewer currently sees: the item's legible selection (system Subtitles tab).
        if let item = playerItem, let group = legibleGroup {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            add(String(localized: "Subtitles"), selected?.displayName ?? String(localized: "Off"))
        }
        // Same self-explanation for subtitles: an empty system menu should read as "the addons
        // had nothing for this title", not as a broken selector.
        if subsFetchDone {
            add(String(localized: "Addon subtitles"), addonSubtitles.isEmpty
                ? String(localized: "none found for this title")
                : String(localized: "\(addonSubtitles.count) found"))
        } else {
            add(String(localized: "Addon subtitles"), String(localized: "searching…"))
        }
        // Subtitle tracks inside the file. Text tracks are offered as renditions (Subtitles tab);
        // bitmap tracks (PGS/VobSub) can't be shown by the native player — say so rather than look
        // broken.
        if let subs = remux?.subtitleTracks, !subs.isEmpty {
            let text = subs.filter(\.isText).count, bitmap = subs.count - text
            if text > 0 {
                add(String(localized: "Embedded subtitles"), embeddedSubtitleCount == text
                    ? String(localized: "\(text) · in the Subtitles tab")
                    : String(localized: "\(embeddedSubtitleCount) of \(text) · in the Subtitles tab"))
            }
            if bitmap > 0 {
                add(String(localized: "Bitmap subtitles"),
                    String(localized: "\(bitmap) PGS/VobSub · not shown natively"))
            }
        }
        if let map = remux?.segmentMap {
            add(String(localized: "Segments"), "\(map.count) \u{00D7} \(map.targetDurationSec)s \u{00B7} \(Self.timeString(map.totalDurationSec))")
        }
        // Bandwidth + transfer stats share rows: the Info tab has a fixed panel height, and the
        // two-column grid fits ten rows, not twelve.
        let event = playerItem?.accessLog()?.events.last
        var bitrate: [String] = []
        if let event, event.indicatedBitrate > 0 {
            bitrate.append(String(format: "%.1f Mb/s", event.indicatedBitrate / 1_000_000))
        }
        if let bandwidth = remux?.estimatedBandwidth, bandwidth > 0 {
            bitrate.append(String(localized: "declared \(String(format: "%.1f", Double(bandwidth) / 1_000_000)) Mb/s"))
        }
        add(String(localized: "Bitrate"), bitrate.joined(separator: " \u{00B7} "))
        if let event, event.numberOfBytesTransferred > 0 {
            var transfer = String(format: "%.0f MB", Double(event.numberOfBytesTransferred) / 1_048_576)
            if event.numberOfStalls > 0 {
                transfer += " \u{00B7} " + String(localized: "\(event.numberOfStalls) stall(s)")
            }
            add(String(localized: "Transferred"), transfer)
        }
        return rows
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Error + access logs from the item — names the exact URI/status/comment AVPlayer choked on.
    private static func dumpItemLogs(_ item: AVPlayerItem) {
        for event in item.errorLog()?.events ?? [] {
            print("[NativePlayer] errorLog: status=\(event.errorStatusCode) \(event.errorComment ?? "") uri=\(event.uri ?? "")")
        }
        if let access = item.accessLog()?.events.last {
            print("[NativePlayer] accessLog: uri=\(access.uri ?? "?") bytes=\(access.numberOfBytesTransferred) stalls=\(access.numberOfStalls)")
        }
    }

    private func failIfPreplayback(_ stage: String) {
        guard phase != .playing else {
            // Mid-play remux failure (e.g. a truncated debrid source): the remaining segments will
            // never appear, so JIT requests would block until playback stalls. Hand to mpv now rather
            // than wait for the stall watchdog.
            print("[NativePlayer] remux failed MID-PLAY at \(stage) — handing to mpv")
            classifyFailure(PlaybackFailureClassifier.fromNativeStage(stage, errorCode: remux?.lastErrorCode, atOpen: false))
            fallbackMidPlay("remux failed mid-play: \(stage)")
            return
        }
        if case .failed = phase { return }
        print("[NativePlayer] pre-playback failure: \(stage) — falling back to mpv")
        // r1 P3: our engine's own limits (no keyframe index, no segment map, bind) are `.local`.
        classifyFailure(PlaybackFailureClassifier.fromNativeStage(
            stage, errorCode: remux?.lastErrorCode, atOpen: remux?.lastErrorAtOpen ?? false))
        phase = .failed(stage)
    }

    /// Mid-play escalation to mpv: the native path started but can no longer make progress (a seek past
    /// the linear remux frontier, or the source truncated). Flipping `phase` to `.failed` makes
    /// `NativePlayerScreen` call `onFallback(lastPositionSec, secondsPlayed)`, which re-presents mpv at the same
    /// position — mpv seeks anywhere via its own demuxer. No-op unless we are actually playing.
    /// BUG-143: records the classified kind of the failure about to set `phase = .failed` (the
    /// first classification wins), with the offline override applied.
    private func classifyFailure(_ verdict: PlaybackFailureClassifier.Verdict) {
        guard failureKind == nil else { return }
        let v = PlaybackFailureClassifier.applyingPath(verdict, pathSatisfied: NetworkPathMonitor.shared.isSatisfied)
        failureKind = v.kind
        failureHTTPStatus = v.httpStatus
        print("[Failover] native failure kind=\(v.kind.rawValue) http=\(v.httpStatus.map(String.init) ?? "-")")
    }

    private func fallbackMidPlay(_ reason: String) {
        guard phase == .playing else { return }
        observeTask?.cancel()
        print("[NativePlayer] mid-play fallback to mpv at \(String(format: "%.1f", lastPositionSec))s — \(reason)")
        phase = .failed(reason)
    }
}
