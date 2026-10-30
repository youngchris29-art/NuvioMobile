import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

// Playback models (PlaybackContext, PlayerTuning, PlayerTrack, SkipSegment/SkipPrompt,
// StreamInfoSnapshot, SubtitleFile) now live in PlaybackModels.swift so every engine shares them.

/// CAMetalLayer subclass that ignores degenerate drawable sizes (mirrors the iOS player's MetalLayer).
final class TVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

/// Observable playback state the SwiftUI controls overlay binds to. The player controller polls libmpv
/// (~2x/sec) and pushes updates here on the main thread.
@MainActor
final class MPVPlaybackState: ObservableObject {
    @Published var positionSec: Double = 0
    @Published var durationSec: Double = 0
    @Published var isPaused: Bool = false
    @Published var isBuffering: Bool = true
    /// The transport bar is up. Every hidden-to-shown edge bumps `controlsSession` and resets the
    /// bar's per-raise state (focus on the track, right label back to remaining time).
    @Published var controlsVisible: Bool = false {
        didSet {
            if controlsVisible && !oldValue {
                controlsSession &+= 1
                transport.focusedPill = nil
                transport.showsEndTime = false
            }
        }
    }
    @Published private(set) var controlsSession = 0

    @Published var audioTracks: [PlayerTrack] = []
    @Published var subtitleTracks: [PlayerTrack] = []
    /// Sync Line (P5 B19): mpv's own `external-filename` for the selected subtitle track (an http(s)
    /// URL or a local temp path); nil when subtitles are Off or the selected track is embedded.
    @Published var selectedExternalSubtitleSource: String?
    /// Playback position in ms for Sync Line, read when the row is pressed.
    var captureSyncPositionMs: (() -> Int64)?
    var syncLineStripSdh: (() -> Bool)?
    /// The swipe-down top panel (Info · Subtitles · Audio · Playback) is presented.
    @Published var panelOpen: Bool = false
    /// BUG-180: the panel's selected tab while it is open (nil = closed). Read on ticks, not published.
    var panelTab: PlayerPanelTab?
    /// Addon subtitle fetch in flight — the picker shows "Searching…" instead of hiding the row.
    @Published var subtitleSearchInFlight: Bool = false

    /// Active skip prompt ("Skip Intro"/"Skip Outro") when playback is inside a known segment.
    @Published var skipPrompt: SkipPrompt?
    /// The fetched skip intervals (post-credits included) — the screen hands them to the up-next
    /// engine for its post-credits hold. Read on position ticks, so not published.
    var skipIntervals: [SkipInterval] = []

    /// Playback-settings panel state (speed, subtitle/audio delay, diagnostics).
    @Published var playbackSpeed: Double = 1.0
    @Published var subtitleDelaySec: Double = 0
    @Published var audioDelaySec: Double = 0
    @Published var showStreamInfo: Bool = false
    @Published var streamInfo: StreamInfoSnapshot?
    /// Player badges (upstream 344117e73): the playing media's facts from the track-list walk,
    /// refreshed when the audio track or the decoded video params change. nil until the first walk.
    @Published var badgeFacts: PlayerBadgeFacts?
    /// "Show Badges in Player", fed by the panel adapter's settings watcher. The controller does the
    /// badge reads only while it is on (`onBadgesInPlayerChange`).
    var badgesInPlayer = false {
        didSet { if badgesInPlayer != oldValue { onBadgesInPlayerChange?(badgesInPlayer) } }
    }
    var onBadgesInPlayerChange: ((Bool) -> Void)?
    /// Engine routing decision from `PlayerEngineRouter`, shown as the Stream Info "Engine" row.
    /// Diagnostic only in Phase 1 — playback still runs through libmpv regardless.
    @Published var routingNote: String = ""

    /// True once playback hit end-of-file (keep-open holds the last frame; drives the post-play cover).
    @Published var isEnded: Bool = false
    /// A swipe scrub is on screen (its preview card): the chips move above it.
    @Published var scrubCardUp = false
    /// P4 B24: the startup stage the loading screen shows (`MPVStartupStageReducer`), and whether
    /// playback has started. Mid-play rebuffers after the start keep the small spinner.
    @Published var startupStage: PlayerLoadingStage = .connecting
    @Published var playbackStarted = false
    /// BUG-170: the start is held paused for the TV's display-mode switch. The paused first frame
    /// already counts as "started", so the loading screen also stays up while this is true.
    @Published var displayModeHolding = false
    /// Info tab "Seek Previews" row: frames · store MB (· process RSS in debug builds); empty until
    /// a harvest lands, or the reason the harvest is off on this device.
    @Published var previewStoreSummary: String = ""

    /// The transport bar's published state (preview playhead, mode, buffered ranges, skip spans).
    let transport = TransportBarModel()
    #if DEBUG
    let seekProbe = SeekProbe()
    #endif

    /// Wired by the controller so the SwiftUI track picker can drive libmpv.
    var selectAudio: ((Int) -> Void)?
    var selectSubtitle: ((Int) -> Void)?
    var setSpeed: ((Double) -> Void)?
    var setSubtitleDelay: ((Double) -> Void)?
    var setAudioDelay: ((Double) -> Void)?
    /// P5 B20: mpv audio effects (Boost + Audio Mode), shown in the panel's Audio tab.
    @Published var audioEffects = PlayerAudioEffectsState(boostDb: 0, mode: .off)
    var setAudioBoost: ((Int) -> Void)?
    var setAudioMode: ((PlayerAudioMode) -> Void)?
    /// P5 B23: "Remember Speed for This Show" (series only). `rememberSpeedAvailable` is set once
    /// the file has loaded, before the panel can open.
    @Published var rememberSpeed = false
    @Published var rememberSpeedAvailable = false
    /// P5 N1: Reset on the Audio Delay row (returns to the stream hint when one is active).
    var resetAudioDelay: (() -> Void)?
    var setRememberSpeed: ((Bool) -> Void)?
    /// P5 N1: the Audio Delay row's limit in seconds: 60 while a stream delay hint is active, else 10.
    @Published var audioDelayLimitSec: Double = 10
    var replay: (() -> Void)?
    var reclaimFocus: (() -> Void)?
    /// Seek to a chapter start (the Chapters tab), absolute seconds.
    var seekToChapter: ((Double) -> Void)?

    /// Wired by `NextEpisodeEngine`: down-press plays the ready next episode (returns true when
    /// consumed, so the skip pill doesn't also fire); backward seek cancels the countdown.
    var upNextPlayNow: (() -> Bool)?
    var upNextCancel: (() -> Void)?
    /// Menu while the up-next chip is visible dismisses the chip instead of exiting the player;
    /// returns true when it consumed the press. The next Menu exits as before (upstream 4026ec92).
    var upNextDismiss: (() -> Bool)?
    /// Whether the up-next chip is showing (Menu precedence reads it before dismissing).
    var upNextVisible: (() -> Bool)?
    /// Main thread. Set when a context swap (next episode, stream switch) is underway, so the
    /// outgoing controller never reports a failover for a player the viewer already left.
    var playbackFailoverSuppressed = false

    let title: String
    init(title: String) { self.title = title }

    var fraction: Double {
        durationSec > 0 ? min(max(positionSec / durationSec, 0), 1) : 0
    }
    var hasTracks: Bool { !audioTracks.isEmpty || !subtitleTracks.isEmpty }
}

/// libmpv-backed player for tvOS. Siri-remote transport: select/play-pause toggles, left/right seek
/// ±10s, down (or a down swipe) opens the top panel, Menu exits. Publishes position/duration/paused/buffering and
/// track lists to `state`, and records watch progress (resume position) via `WatchProgressRepository`.
final class MPVTVPlayerViewController: UIViewController {

    private var metalLayer = TVMetalLayer()
    private var mpv: OpaquePointer?
    /// The wakeup callback's context (see `MPVWakeupRelay`). Set in `setupMpv`, never touched in
    /// `deinit`, and kept until the controller goes, which is after `destroyPlayer` unset the callback.
    private var wakeupRelay: MPVWakeupRelay?
    private var lastDrawableSize: CGSize = .zero
    private let eventQueue = DispatchQueue(label: "mpv-events", qos: .userInitiated)
    private let context: PlaybackContext
    private let state: MPVPlaybackState
    private var didLoad = false
    private var pollTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private var lastSaveUptime: TimeInterval = 0
    private var pendingResumeSec: Double?
    /// True once the resume seek has been issued (see `applyPendingResume`).
    private(set) var didResumeSeek = false
    /// P4 B24 (main thread): the startup stages behind the loading screen, and the uptime the
    /// `[Loading]` lines count from.
    private var startupStages = MPVStartupStageReducer()
    private let loadingStartUptime = ProcessInfo.processInfo.systemUptime
    /// Percentage-only entry (Simkl/Trakt rows: no stored position/duration). Resolved against
    /// mpv's real duration at file-load in `applyPendingResume`; never the show runtime.
    private var pendingResumeEntry: WatchProgressEntry?
    // Preview-then-commit transport (P1): held Left/Right move a preview, one commit on release.
    private var transport = TransportPreview()
    private var holdTimer: Timer?
    private var holdStartUptime: TimeInterval = 0       // uptime of the press that started the current hold
    private var pendingExact: (generation: Int, request: TransportPreview.CommitRequest, deadline: DispatchWorkItem)?
    private var exactWork: DispatchWorkItem?
    private var commitLandWork: DispatchWorkItem?       // 1.5 s fallback for noteCommitLanded()
    private var commitGeneration: Int?                  // generation of the last commit's first stage
    private var scanRestoreSpeed: Double?               // main: the user's speed when the scan started
    private var scanWasMuted: Bool?                     // `eventQueue` only: mute before the scan
    private var exactAwaitsSeekStart: Int?              // `eventQueue` only: keyframes gen whose SEEK the exact stage waits for
    private var bufferedReadPending = false
    private var lastPublishedModeActive = false
    private let holdTickSec: TimeInterval               // `debug.holdTickSec` (0 = Auto 0.25)
    private let commitExactDelaySec: TimeInterval       // `debug.commitExactDelayMs`; < 0 = never run the exact stage
    // Swipe scrub (P2-A1): a horizontal stroke on the touch surface moves a preview, Select commits.
    private var scrubArbiter = ScrubGestureArbiter()
    private weak var scrubPan: UIPanGestureRecognizer?
    private weak var swipeDownRecognizer: UISwipeGestureRecognizer?
    private weak var lightTapRecognizer: UITapGestureRecognizer?
    private let scrubCurve: ScrubRateCurve              // `debug.scrubCurve`: "bobsupra", else Orivio
    private let scrubRateScale: Double                  // `debug.scrubRateScale`; <= 0 = Auto 1.0
    private var scrubIdleWork: DispatchWorkItem?        // playing: cancel a scrub after 8 s without input
    private var scrubPublishWork: DispatchWorkItem?     // trailing publish of the 30 Hz scrub throttle
    private var lastScrubPublishUptime: TimeInterval = 0
    private var previewFrameThrottle = PreviewFrameThrottle()
    /// BUG-180: uptime of the last Stream Info rebuild (`refreshState` throttles it).
    private var lastStreamInfoRefresh: TimeInterval = 0
    private static let streamInfoRefreshSec: TimeInterval = 2
    private var previewFrameWork: DispatchWorkItem?     // the throttle's `.wait` timer
    private var previewFrameToken = 0                   // bumped when a scrub ends: late frames are dropped
    private var lastPublishedScrubbing = false
    /// Where the scrub card's frames come from (the seek-preview store); nil = time only.
    var seekPreviewSource: SeekPreviewSource?
    // Seek preview harvest (P2-B): frames from the playing decode, one per ~10 s of playback.
    /// Held strongly here; created in `viewDidLoad`, released in `destroyPlayer`.
    private var previewStore: SeekPreviewStore?
    /// Main only. Interval from `debug.harvestIntervalSec`, read in `viewDidLoad`.
    private var harvest = HarvestScheduler(intervalSec: 10)
    /// `eventQueue` only: nil = untried; false = this mpv rejected the format argument, call
    /// `screenshot-raw video` without it from now on.
    private var harvestFormatArgWorks: Bool?
    /// DEBUG `-debug.harvestSynthetic YES`: harvest a generated grey frame instead of calling
    /// `screenshot-raw` (the simulator cannot screenshot, see `viewDidLoad`). Set once in
    /// `viewDidLoad`, read on `eventQueue`.
    private var harvestSynthetic = false
    #if DEBUG
    /// DEBUG `-debug.harvestSyntheticSize WxH` (P3-F9 §4): the synthetic frame's size, so the
    /// Swift half can be measured at a real frame size (default 640 × 360).
    private var harvestSyntheticSize = (width: 640, height: 360)
    #endif
    /// P3-F9: Developer › Harvest Screenshot Path (`HarvestScreenshotPath`), read once in
    /// `viewDidLoad` in every build; on = `screenshot-sw` for SDR frames (off by default, P4-F3).
    private var harvestScreenshotSW = false
    /// `eventQueue` only: the `screenshot-sw` path last chosen (nil = none yet this file).
    private var harvestScreenshotSWApplied: Bool?
    /// `eventQueue` only (P4-F3): the software path returned no frame for this file, so the
    /// harvest stays on the renderer path until the controller goes (one `loadfile` per controller).
    private var harvestSoftwareFailed = false
    /// `eventQueue` only: `[MPVStats] vo=` printed for this file.
    private var statsVOLogged = false
    /// Crash guard around `screenshot-raw` (review r1 P2 #3); `eventQueue` arms and clears it.
    private let harvestSentinel = HarvestCrashSentinel(store: UserDefaults.standard)
    /// `eventQueue` only: the first real capture of this file flushes the armed flag to disk.
    private var harvestSentinelFlushed = false
    /// The crash guard turned the harvest off for this playback (the Info row says so).
    private var harvestCrashOff = false
    // Seek preview decode (P3): the keyframe thumbnailer fills unwatched ground (mode `decode`).
    /// Developer › Seek Preview Frames, read once in `viewDidLoad`.
    private var seekPreviewMode: SeekPreviewMode = .harvest
    /// Main only. Disabled unless the mode is `decode`.
    private var thumbs = ThumbScheduler(enabled: false)
    /// Main only; created lazily (`shouldOpen`), closed in `destroyPlayer` or when it stops.
    private var thumbnailer: KeyframeThumbnailer?
    private var thumbOpened = false
    /// What the first open learned; a reopen after an idle close reuses it (review r1 P1).
    private var thumbFacts: ThumbFileFacts?
    /// Bytes charged by thumbnailers already closed (idle closes); the budget counts across reopens.
    private var thumbBytesClosed: Int64 = 0
    private var thumbByteBudget: Int64 = ThumbScheduler.byteBudget(fileSize: nil)
    /// The last store snapshot (critique C1): what the scheduler reads, never the actor itself.
    private var storeMirror = SeekPreviewSnapshot.empty
    private var thumbLastDecodeMs: Double?
    /// Cache health for the pre-warm (critique C2), from the 2 s `eventQueue` read; main only.
    private var cacheHealthSec: Double = 0
    private var cacheHealthFill: Double = 0
    private var cacheHealthEofCached = false
    private var cacheTrend = ThumbCacheTrend()
    private var cacheHealthReadPending = false
    private var lastCacheHealthRead: TimeInterval = 0
    /// What `setupMpv` applied as `demuxer-max-bytes` (150 MiB when Streaming Buffer is unset).
    private var demuxerMaxBytes: Int64 = 150 * 1024 * 1024
    private var thumbScrubWork: DispatchWorkItem?       // 50 ms: a pending scrub miss becomes due
    private var thumbReleaseWork: DispatchWorkItem?     // frees the decoder 2 s after a scrub job
    #if DEBUG
    private var loggedThumbStop = false
    #endif
    /// One Left/Right click: ±10 s or a chapter jump (`player.edgeClickMode`, read in viewDidLoad).
    private var edgeClickMode: EdgeClickMode = .skip10
    /// Clears the aspect flash 2 s after the last Aspect pill press.
    private var aspectFlashWork: DispatchWorkItem?
    /// Main: the chapter list as read at FILE_LOADED, before the end trim, and the duration the
    /// published list was last trimmed for (review r2 P3 #5).
    private var rawChapters: [TransportChapter] = []
    private var chaptersTrimDuration: Double = -1
    /// How long the aspect flash stays up; DEBUG `-debug.aspectFlashSec` lengthens it for the UI
    /// leg, so a slow simulator press cannot clear a flash mid-cycle (review r2 P3 #3).
    private var aspectFlashSec: TimeInterval = 2
    /// The resize mode the profile holds and the session-start value Stretch puts back (reset at
    /// FILE_LOADED, then moved by each write and by the settings watcher), and whether the pill
    /// moved since the last write (review r1 P2 #1, r2 P2 #1).
    private var aspectWriteback = AspectWriteback(start: .fit) {
        didSet {
            #if DEBUG
            state.transport.debugAspectStored = aspectWriteback.stored
            #endif
        }
    }
    private var aspectPillDirty = false
    /// Last edge-to-edge panel opened by a gesture (the swipe recogniser and the arbiter both fire).
    private var lastGesturePanelUptime: TimeInterval = 0
    // `eventQueue` only: the one-shot DEBUG cache-state logs.
    private var cacheStateLogCount = 0
    private var subtitleWatcher: FlowWatcher?
    private var subtitleLoadingWatcher: FlowWatcher?
    private var playerSettingsWatcher: FlowWatcher?
    private var playerSettings: PlayerSettingsUiState?
    private var didAutoSelectTracks = false
    /// Preferred audio-language targets in priority order, resolved once in `setupMpv()` (before
    /// `mpv_initialize`) so mpv's own first `aid=auto` resolution already honors them.
    private var preferredAudioLanguages: [String] = []
    /// True once `alang` reached mpv — as an option pre-init, or via the property re-apply.
    private var didApplyAlang = false
    /// Set by an explicit pick in selectAudio(_:); no automatic path may override it afterwards.
    /// Insurance, not a live race: there is exactly one `loadfile` per controller (SwiftUI rebuilds
    /// the player per episode via `.id(ctx.id)`), so a user pick can only ever follow the automatic
    /// selection, never race it. The flag keeps that true if the controller is ever reused.
    private var didUserSelectAudio = false
    /// The subtitle half of the auto selection is decided (it can wait for side-loads, see
    /// `MPVSubtitleAutoSelectGate`); main only.
    private var didAutoSelectSubtitles = false
    /// A forced-only plan already turned subtitles off while side-loads run; main only.
    private var didApplyAutoSubtitleOff = false
    /// Set by an explicit pick in selectSubtitle(_:); the waiting auto selection stops. Main only.
    private var didUserSelectSubtitle = false
    /// Side-load batches handed to `eventQueue` (or downloading on the credential path) that have
    /// not reached its queue yet. A walk captured before they arrive must not read "nothing left to
    /// load" (review r1 P3-2). Main only.
    private var subtitleHandoffsInFlight = 0
    private var addedSubtitleUrls = Set<String>()
    /// `eventQueue` only: subtitle side-loads, one async `sub-add` at a time (the queue stall,
    /// Batch E device pass 2026-10-18; see `MPVSubtitleSideLoadQueue`).
    private var subtitleSideLoads = MPVSubtitleSideLoadQueue()
    /// `eventQueue` only: the log ring's subtitle attribution window is open for the load in flight.
    private var subtitleLoadWindowOpen = false
    private var fileLoaded = false
    /// Main only. Live detection (`LivePlaybackPolicy`, NuvioTV b4e47d6d6/583eae818): `seekable`
    /// false once loaded, or (a live HLS stream mpv seeks inside its cache) a duration that keeps
    /// growing with the clock. Fed once per `refreshState` tick, readings before FILE_LOADED
    /// skipped. A live stream, or one whose growth is still undecided (`holdsLiveProgress`), closes
    /// its tracker sessions at 0 %; an HLS / DASH stream's resume saves also wait for it to settle
    /// (`holdsLiveResume`), and what a save overwrote anyway is put back when it turns live
    /// (`undoSessionResumeSaves`).
    private var reportsLive = false
    private var durationGrowth = LivePlaybackPolicy.DurationGrowth()
    private var isLiveStream: Bool { LivePlaybackPolicy.isLive(reportsLive: reportsLive, growth: durationGrowth) }
    private var holdsLiveProgress: Bool { LivePlaybackPolicy.holdsProgress(reportsLive: reportsLive, growth: durationGrowth) }
    private var holdsLiveResume: Bool {
        LivePlaybackPolicy.holdsResume(reportsLive: reportsLive, growth: durationGrowth,
                                       settleHold: LivePlaybackPolicy.needsSettleHold(fileFormat: cachedProps().fileFormat,
                                                                                      url: context.url))
    }
    private var savedResumeThisSession = false
    /// The stored entry for this video when this session first saved (nil = there was none).
    private var resumeEntryBeforeSession: WatchProgressEntry?
    /// P5 N1: main only. The audio delay's saved / stream-hint / session parts for this file.
    private var audioDelayParts = AudioDelayParts(savedMs: 0, streamMs: nil, sessionAdjustMs: 0)
    /// P5 B20: `eventQueue` only. The `af` value last handed to mpv ("" = none).
    private var lastAppliedAf = ""
    /// Trakt scrobbling (no-ops while Trakt is disconnected — the shared repo checks auth).
    private var traktScrobbleItem: TraktScrobbleItem?
    private var traktScrobbleRequested = false
    /// Set once the player is going away. `buildItem` completes asynchronously — if the user backs
    /// out before it returns, the late completion must not start a scrobble that nothing will ever
    /// stop (ME-004).
    private var traktSessionClosed = false
    /// Simkl/MDBList (every connected tracker except Trakt) — same start-once/stop-once lifecycle.
    private let trackerScrobble: TrackerScrobbleSession
    /// Skip chip + auto-skip policy shared with the native engine (`SkipSegmentPlanner`).
    private var skipPlanner: SkipSegmentPlanner = {
        var planner = SkipSegmentPlanner()
        planner.autoHidesChip = true   // mpv can bring the chip back on a press (P1 §6)
        return planner
    }()
    /// Main thread: bumped for every seek the app issues (`issueSeek`); a completion is only
    /// reported to `skipPlanner` for the latest one.
    private var seekGeneration = 0
    // Engine-confirmed seek completion — `eventQueue` only (see `issueSeek` / `drainEvents`).
    /// Issued to mpv, but mpv has not reported starting it yet (MPV_EVENT_SEEK).
    private var awaitingSeekStartGeneration: Int?
    /// mpv reported starting this seek; the next MPV_EVENT_PLAYBACK_RESTART confirms it. A restart
    /// without one (start of playback, track switch) is not a seek completion.
    private var startedSeekGeneration: Int?
    /// Last raw eof-reached value (edge detection for the post-play cover).
    private var lastEofFlag = false

    // MARK: Event-driven property cache
    //
    // The main thread must NEVER call mpv_get_property: synchronous reads contend on the core
    // lock, which is busiest during the first minute of playback (demuxer cache fill, decoder
    // spin-up) — that contention was the beta-reported "player laggy at first" / "swipe-up menu
    // slow to appear" (tracker BUG-2/BUG-3). Values arrive as MPV_EVENT_PROPERTY_CHANGE payloads
    // on `eventQueue` and land in this lock-guarded snapshot; the UI timer only reads the cache.
    private struct PropSnapshot {
        var position: Double = 0
        var duration: Double = 0
        var paused = false
        var coreIdle = false
        var cacheWait = false
        var eof = false
        var videoW: Int64 = 0
        var videoH: Int64 = 0
        /// `cache-buffering-state` (0–100; −1 = not reported yet). B24's "Buffering N %".
        var cacheBufferingPct: Int64 = -1
        /// `seekable` (nil = not reported yet). False once loaded = live (`LivePlaybackPolicy`).
        var seekable: Bool?
        /// `file-format` (nil = not reported yet): HLS / DASH get the resume settle hold.
        var fileFormat: String?
    }
    private let propLock = NSLock()
    private var propSnapshot = PropSnapshot()
    /// Coalesces track-list refresh requests (many property events can arrive in a burst).
    private var trackRefreshPending = false
    /// Player badges: the selected video entry's facts and every audio entry's facts (by mpv id)
    /// from the last walk, so an `aid` change re-publishes without a second walk. `eventQueue` only.
    private var badgeVideoFacts: PlayerBadgeFacts?
    private var badgeAudioFacts: [Int: PlayerBadgeFacts] = [:]
    /// `eventQueue` copy of `MPVPlaybackState.badgesInPlayer`: off (the default) skips every badge read.
    private var badgesInPlayer = false
    #if DEBUG
    /// Elapsed playback time of the last `[Mem]` line (−1 = none yet); see `logStartupStatsIfNeeded`.
    private var lastMemLogElapsed: Double = -1
    #endif
    /// Uptime when FILE_LOADED fired — drives the first-90s `[MPVStats]` diagnostics.
    private var fileLoadedUptime: TimeInterval = 0
    /// Times playback entered paused-for-cache (buffering underruns), for diagnostics.
    private var cacheWaitCount = 0

    /// Observation ids for mpv_observe_property (arrive back as `reply_userdata`).
    private enum ObservedProp: UInt64 {
        case timePos = 1, duration, pause, coreIdle, pausedForCache, eofReached, trackCount
        case videoW, videoH, aid, cacheBuffering, seekable, fileFormat
    }

    private func cachedProps() -> PropSnapshot {
        propLock.lock(); defer { propLock.unlock() }
        return propSnapshot
    }

    private func updateProps(_ mutate: (inout PropSnapshot) -> Void) {
        propLock.lock(); defer { propLock.unlock() }
        mutate(&propSnapshot)
    }

    /// Called when the user presses Menu, so the SwiftUI cover can dismiss.
    var onExit: (() -> Void)?
    /// Set when a Menu press was consumed by the up-next dismiss so the matching release is
    /// swallowed too (same pattern as `PlayerPanelHostController`) — nothing above sees a half press.
    private var swallowMenuRelease = false
    /// A consumed Menu's action, performed when the press ends (never while it is down).
    private var pendingMenuAction: MenuPrecedence.Action?
    /// BUG-165: when the exit Menu was decided (`systemUptime`), for the `[MenuProbe]` timing lines
    /// that say where the press's later phases and the cover's teardown land relative to it.
    private var exitDecidedAt: TimeInterval?
    private func sinceExitMs() -> Int {
        exitDecidedAt.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? -1
    }

    #if DEBUG
    /// Diagnostic for the "consumed Menu still dismisses the cover" class: who sits above this
    /// controller, and which gesture recognisers on that chain could claim a Menu press.
    func dumpMenuResponderChain(tag: String) {
        var lines: [String] = ["[MenuProbe] \(tag) firstResponder=\(isFirstResponder)"]
        var responder: UIResponder? = self
        var depth = 0
        while let r = responder, depth < 40 {
            var line = "  [\(depth)] \(type(of: r))"
            if let v = r as? UIView, let grs = v.gestureRecognizers, !grs.isEmpty {
                let descs = grs.map { gr -> String in
                    let types = (gr.allowedPressTypes).map { $0.intValue }
                    return "\(type(of: gr))(state=\(gr.state.rawValue) press=\(types) enabled=\(gr.isEnabled))"
                }
                line += " grs=" + descs.joined(separator: ", ")
            }
            lines.append(line)
            responder = r.next
            depth += 1
        }
        if let w = view.window, let grs = w.gestureRecognizers {
            lines.append("  window grs=" + grs.map { "\(type(of: $0))(state=\($0.state.rawValue) press=\($0.allowedPressTypes.map { $0.intValue }))" }.joined(separator: ", "))
        }
        NSLog("%@", lines.joined(separator: "\n"))
    }
    #endif

    private func performMenuAction(_ action: MenuPrecedence.Action) {
        #if DEBUG
        NSLog("[MenuProbe] perform action=%@ mode=%@", String(describing: action), String(describing: transport.mode))
        #endif
        switch action {
        case .cancelMode:
            // Stepping / scrubbing: nothing committed. Scanning: back to where the scan started.
            stopHoldTimer()
            cancelScrub(why: "menu")
            apply(transport.cancel())
        case .dismissUpNext:
            // Back out of the transient up-next chip first; the next Menu exits (same
            // convention as the top panel: overlay first, player second).
            _ = state.upNextDismiss?()
        case .hidePill, .hideBar:
            // Menu hides the bar (hideControlsNow clears the pill focus); the next Menu exits.
            hideControlsNow()
        case .panel, .exit:
            break
        }
    }
    /// Open the top panel on a tab (D-pad Down with nothing else to do, a down swipe: `.info`; a
    /// pill's Select: that pill's tab).
    var onOpenPanel: ((PlayerPanelTab) -> Void)?
    /// `systemUptime` of the last press of any button beginning, ending or being cancelled: a click
    /// (arrows included) is also a touch, so the light-tap recogniser ignores a tap within 0.5 s of
    /// one (`LightTapGuard`).
    private var lastClickUptime: TimeInterval = 0
    /// Presses currently down (began, not yet ended or cancelled): no light tap while any is.
    private var pressesDown = Set<ObjectIdentifier>()
    private var endTimeWork: DispatchWorkItem?
    #if DEBUG
    /// Block token for the DEBUG light-tap notification; removed in `destroyPlayer`, never `deinit`.
    private var lightTapObserver: NSObjectProtocol?
    /// Block token for the DEBUG scrub-inject notification; removed in `destroyPlayer`.
    private var scrubInjectObserver: NSObjectProtocol?
    private var scrubInjectTimer: Timer?
    #endif

    // MARK: Failover hooks (set by the host, `PlayerScreen`; all unset = today's behaviour)
    /// Fired on the main thread, at most once per player, when this engine cannot give the viewer
    /// playback: an mpv load/decode error, nothing loaded within the start budget, a placeholder
    /// clip on an auto flow, or a stream that ended long before its declared duration. Never fired
    /// after the viewer exited or a context swap began.
    var onPlaybackFailed: ((PlaybackFailure) -> Void)?
    /// Fired once, on the main thread, when `secondsPlayed` first reaches 300 — the stream has
    /// proven itself and the host can stop treating it as a failover candidate.
    var onPlaybackHealthy: ((Double) -> Void)?
    /// The native engine already failed before start, so this attempt gets the shortened budget.
    var startWatchdogShortened = false
    /// Seconds the native engine played before it fell back to this player (added to `secondsPlayed`).
    var nativeSecondsPlayedBeforeFallback: Double = 0
    /// B10 (BUG-166): the router sent a Dolby Vision profile 5 stream here, so `setupMpv` uses
    /// `gpu-next` whatever Enhanced Video Renderer says. Set by the representable right after init,
    /// before `viewDidLoad` runs `setupMpv`.
    var forcesGpuNext = false
    private var startWatchdog = MPVStartWatchdog(limitSeconds: MPVStartWatchdog.defaultLimitSeconds)
    private var startWatchdogTimer: Timer?
    /// Main thread: a failure was already reported (every path shares this one-shot).
    private var failoverReported = false
    /// P4 (BUG-143): recent mpv warn/error lines, the evidence the failure classifier reads.
    private let logRing = MPVLogRing()
    /// Main thread: the viewer is leaving (or the player is torn down) — report nothing further.
    private var failoverClosed = false
    private var healthyReported = false
    /// Main thread: `ProcessInfo.systemUptime` of this file's `MPV_EVENT_FILE_LOADED`; nil until then.
    private var failoverLoadedUptime: TimeInterval?
    /// Main thread: seconds mpv actually spent playing this file (not paused, not buffering), fed
    /// from the ~0.5 s `refreshState` tick. `secondsPlayed` for a failure report and the 300 s
    /// healthy mark read this, never a wall clock since load.
    private var playClock = PlaybackHealthClock()

    init(context: PlaybackContext, state: MPVPlaybackState) {
        self.context = context
        self.state = state
        self.trackerScrobble = TrackerScrobbleSession(context: context)
        let tick = UserDefaults.standard.double(forKey: "debug.holdTickSec")
        self.holdTickSec = tick > 0 ? tick : TransportPreview.defaultTickSec
        let exactMs = UserDefaults.standard.integer(forKey: "debug.commitExactDelayMs")
        self.commitExactDelaySec = exactMs == 0 ? 0.15 : (exactMs < 0 ? -1 : Double(exactMs) / 1000)
        self.scrubCurve = ScrubRateCurve.fromSetting(UserDefaults.standard.string(forKey: "debug.scrubCurve"))
        let scrubScale = UserDefaults.standard.double(forKey: "debug.scrubRateScale")
        self.scrubRateScale = scrubScale > 0 ? scrubScale : 1
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.masksToBounds = true

        metalLayer.contentsGravity = .resizeAspect
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        layoutMetalLayer()

        state.selectAudio = { [weak self] id in self?.selectAudio(id) }
        state.selectSubtitle = { [weak self] id in self?.selectSubtitle(id) }
        state.setSpeed = { [weak self] speed in self?.setSpeed(speed) }
        state.setSubtitleDelay = { [weak self] seconds in self?.setSubtitleDelay(seconds) }
        state.setAudioDelay = { [weak self] seconds in self?.setAudioDelay(seconds) }
        state.resetAudioDelay = { [weak self] in self?.resetAudioDelay() }
        state.setAudioBoost = { [weak self] db in self?.setAudioBoost(db) }
        state.setAudioMode = { [weak self] mode in self?.setAudioMode(mode) }
        state.setRememberSpeed = { [weak self] on in self?.setRememberSpeed(on) }
        state.syncLineStripSdh = { [weak self] in self?.playerSettings?.subtitleStyle.stripSdh ?? false }
        state.captureSyncPositionMs = { [weak self] in Int64(((self?.cachedProps().position) ?? 0) * 1000) }
        state.replay = { [weak self] in self?.replay() }
        state.reclaimFocus = { [weak self] in
            // Presses begun before the panel/cover took over never end here: drop them so the
            // light tap is not blocked for the rest of the session.
            self?.pressesDown.removeAll()
            self?.becomeFirstResponder()
        }
        view.accessibilityIdentifier = "player.mpv"

        transport.holdMode = TransportPreview.HoldMode(
            rawValue: UserDefaults.standard.string(forKey: PlayerTuning.holdModeKey) ?? "step") ?? .step
        let ramp = UserDefaults.standard.double(forKey: "debug.holdRampScale")
        transport.rampScale = ramp > 0 ? ramp : 1
        transport.scrubCurve = scrubCurve
        transport.scrubRateScale = scrubRateScale
        state.transport.scrubCurveCode = scrubCurve.probeCode

        // Seek preview store (P2-B): in memory, for the life of this controller.
        let previewKey = context.streamKey.isEmpty
            ? PlaybackStreamKey.make(infoHash: nil, fileIdx: nil, addonId: "local",
                                     url: context.url.absoluteString, label: context.title)
            : context.streamKey
        seekPreviewMode = SeekPreviewMode.current()
        let caps = SeekPreviewStore.caps(for: seekPreviewMode)
        let store = SeekPreviewStore(streamKey: previewKey, maxEntries: caps.maxEntries, maxBytes: caps.maxBytes)
        previewStore = store
        seekPreviewSource = store
        harvest = HarvestScheduler(intervalSec: HarvestScheduler.interval(
            fromSetting: UserDefaults.standard.integer(forKey: "debug.harvestIntervalSec")))
        harvestScreenshotSW = HarvestScreenshotPath.softwareEnabled()
        #if DEBUG
        harvestSynthetic = UserDefaults.standard.bool(forKey: "debug.harvestSynthetic")
        if let size = HarvestScreenshotPath.parseSize(UserDefaults.standard.string(forKey: "debug.harvestSyntheticSize")) {
            harvestSyntheticSize = size
        }
        let flashSec = UserDefaults.standard.double(forKey: "debug.aspectFlashSec")
        if flashSec > 0 { aspectFlashSec = flashSec }
        #endif
        // A capture that never returned in an earlier playback turns the harvest off on this
        // device until a value is picked in Settings › Developer (review r1 P2 #3).
        if harvestSentinel.checkAtLaunch() {
            print("[Harvest] disabled: previous capture did not return")
        }
        if harvestSentinel.isDisabled, !harvestSynthetic {
            harvest = HarvestScheduler(intervalSec: 0)
            harvestCrashOff = true
            state.previewStoreSummary = String(localized: "Off after a crash in an earlier playback")
        }
        #if targetEnvironment(simulator)
        // `screenshot-raw` aborts the app on the simulator: libplacebo's texture download asks
        // MoltenVK for a host-imported buffer and MTLSimDriver traps in `xpc_shmem_create`
        // (EXC_BREAKPOINT, `_xpc_api_misuse`). Harvest only with the synthetic DEBUG source here.
        if !harvestSynthetic {
            harvest = HarvestScheduler(intervalSec: 0)
            #if DEBUG
            NSLog("[Harvest] off on the simulator (screenshot-raw traps in MTLSimDriver); -debug.harvestSynthetic YES to test the plumbing")
            #endif
        }
        #endif
        // Seek Preview Frames (P3). Off beats everything above, the DEBUG synthetic harvest
        // included (critique C22). Decode adds the keyframe thumbnailer beside the harvest.
        if !seekPreviewMode.allowsHarvest { harvest = HarvestScheduler(intervalSec: 0) }
        thumbs = ThumbScheduler(enabled: seekPreviewMode.allowsDecode)
        // BUG-181: a placeholder card only when something can fill the store.
        state.transport.previewCardEnabled = harvest.intervalSec > 0 || seekPreviewMode.allowsDecode
        #if DEBUG
        rebuildPreviewSummary()   // the DEBUG row exists from the start (Off mode has no store events)
        #endif
        let bufferMB = UserDefaults.standard.integer(forKey: PlayerTuning.bufferMBKey)
        if bufferMB > 0 { demuxerMaxBytes = Int64(bufferMB) * 1024 * 1024 }

        // Chapters (P2-C): the Chapters tab seeks through here; one click on Left/Right follows
        // Settings › Playback › Left/Right Click.
        state.seekToChapter = { [weak self] sec in self?.seekToChapter(sec) }
        state.onBadgesInPlayerChange = { [weak self] on in self?.setBadgesInPlayer(on) }
        setBadgesInPlayer(state.badgesInPlayer)
        edgeClickMode = EdgeClickMode(
            rawValue: UserDefaults.standard.string(forKey: PlayerTuning.edgeClickModeKey) ?? "skip10") ?? .skip10

        // Touch-surface swipe down → top panel (presses arrive as `.downArrow`; real swipes don't).
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown))
        swipeDown.direction = .down
        swipeDown.delegate = self
        view.addGestureRecognizer(swipeDown)
        swipeDownRecognizer = swipeDown

        // Light tap on the touch surface: raise the bar, or flip the right label to the end time.
        let lightTap = UITapGestureRecognizer(target: self, action: #selector(handleLightTap))
        lightTap.allowedPressTypes = []
        lightTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(lightTap)
        lightTapRecognizer = lightTap

        // Swipe scrub (P2): every touch-surface stroke goes through `ScrubGestureArbiter`. Presses
        // never reach the pan (`allowedPressTypes = []`), so `pressesBegan/Ended/Cancelled` and the
        // Menu-on-release path are untouched. No focus suppression is needed: this controller is
        // first responder and the pills are drawn non-focusable, so the focus engine has nothing
        // to move during a pan.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrubPan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.allowedPressTypes = []
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
        scrubPan = pan
        lightTap.require(toFail: pan)        // a tap only when the pan never began
        #if DEBUG
        TransportDebugDarwinBridge.install()
        lightTapObserver = NotificationCenter.default.addObserver(
            forName: .nuvioDebugTransportLightTap, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.performLightTap(force: true) }
        }
        scrubInjectObserver = NotificationCenter.default.addObserver(
            forName: .nuvioDebugTransportScrubInject, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runScrubInject() }
        }
        #endif

        setupMpv()
    }

    @objc private func handleSwipeDown() {
        // A scrub stroke that drifts down must not open the panel.
        guard scrubArbiter.intent != .horizontal else { return }
        openPanelFromGesture()
    }

    /// The one panel opener for gestures: the swipe recogniser and the arbiter's vertical-down both
    /// land here, deduped within 0.6 s.
    private func openPanelFromGesture() {
        let now = ProcessInfo.processInfo.systemUptime
        guard presentedViewController == nil, now - lastGesturePanelUptime > 0.6 else { return }
        lastGesturePanelUptime = now
        cancelExactStage()
        stopHoldTimer()
        cancelScrub(why: "panel")
        apply(transport.cancel())
        onOpenPanel?(.info)
    }

    @objc private func handleLightTap() { performLightTap(force: false) }

    /// Light tap: ignored right after a click; hidden bar → raise it; bar up → flip the right label
    /// between remaining time and end time (4 s, then back). `force` skips the click guard (the
    /// DEBUG notification has no preceding click).
    private func performLightTap(force: Bool) {
        if isScrubbing { return }           // a tap does nothing to a scrub
        if !force, !LightTapGuard.allows(now: ProcessInfo.processInfo.systemUptime,
                                         lastPressUptime: lastClickUptime, pressesDown: pressesDown.count) { return }
        guard presentedViewController == nil else { return }
        guard state.controlsVisible else { flashControls(); return }
        let t = state.transport
        if !t.showsEndTime {
            guard t.durationSec > 0 else { flashControls(); return }
            t.showsEndTime = true
            endTimeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.state.transport.showsEndTime = false }
            endTimeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        } else {
            t.showsEndTime = false
            endTimeWork?.cancel()
        }
        flashControls()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutMetalLayer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pressesDown.removeAll()         // a press begun under a cover never ended on this controller
        becomeFirstResponder()
        gateCoverMenuTap(enabled: false)
        // BUG-165: the Menu shield lives on the window (idempotent); armed only at the exit press.
        if let window = view.window { MenuExitShield.shared.install(on: window) }
        if !didLoad {
            didLoad = true
            computeResumePosition()
            applyRequestHeaders(context.requestHeaders)
            // Re-assert the audio-language preference on the live handle right before the load —
            // the fallback for a `setupMpv()` that ran before the settings store had hydrated.
            applyAudioLanguagePreferences()
            beginDisplayModeHoldIfNeeded()
            command("loadfile", args: [context.url.absoluteString, "replace"])
            print("[Loading] engine=mpv stage=\(startupStages.stage.logToken) t=+\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - loadingStartUptime))s")
            armStartWatchdog()
            startPolling()
            flashControls()

            // Side-load subtitles fetched from installed subtitle addons (OpenSubtitles etc.).
            subtitleWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.addonSubtitles) { [weak self] emitted in
                guard let self, let subs = emitted as? [AddonSubtitle] else { return }
                self.addAddonSubtitles(subs)
            }
            subtitleLoadingWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.isLoading) { [weak self] emitted in
                guard let self, let loading = (emitted as? NSNumber)?.boolValue else { return }
                DispatchQueue.main.async {
                    let ended = self.state.subtitleSearchInFlight && !loading
                    self.state.subtitleSearchInFlight = loading
                    // A selection that waited on the search is decided on the next walk (an empty
                    // search adds no files, so no load would trigger one).
                    if ended, self.fileLoaded { self.refreshTracksAsync() }
                }
            }

            // Subtitle appearance from Settings (color/size/bold/outline/background). The watcher
            // emits the current value immediately; re-apply live if the style changes mid-playback.
            PlayerSettingsRepository.shared.ensureLoaded()
            playerSettingsWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
                guard let self, let settings = emitted as? PlayerSettingsUiState else { return }
                self.playerSettings = settings
                // The profile's stored resize mode (our own write echoing back, or the phone's):
                // the baseline the Aspect pill's write-back compares against.
                self.aspectWriteback.watcherReported(.initial(syncedName: settings.resizeMode.name))
                if self.fileLoaded { self.applySubtitleStyle() }
            }
        } else if mpv != nil, pollTimer == nil {
            // Back from a full-screen cover (the post-play card, then Replay): `viewDidDisappear`
            // stopped the poll timer when the cover went up, and the play clock, the early-end
            // rule and the healthy mark all run off that tick.
            startPolling()
            // Review r2 #2: that same teardown also ended the Trakt scrobble and released the
            // display mode. Replay plays on this controller, so restore both; a real exit keeps
            // today's teardown (deliberately not gated on `isLeavingPlayer`, unproven on hardware).
            if fileLoaded {
                applyDisplayCriteriaIfEnabled()
                startTraktScrobble()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Failure reporting stays armed while a full-screen cover (the post-play card) merely
        // covers the player: Replay comes back to this same controller.
        // Device-pass probe (review r2 #3): must read true on a Menu exit, false under the card.
        print("[Failover] viewWillDisappear isLeavingPlayer=\(isLeavingPlayer) cover=\(coverIsBeingDismissed ? 1 : 0) sinceExit=\(sinceExitMs())ms")
        if isLeavingPlayer { closeFailover() }
        // The hosting cover gets its Menu recogniser back whenever the cover itself stays: a
        // full-screen cover over the player (the post-play card) and, review r1 P1-1, an in-place
        // swap of this controller inside the same cover (Up Next / failover: `StreamPickerView`'s
        // `.id(ctx.id)` moves this controller out of its parent while the cover lives on, and the
        // next `PlayerScreen`'s probe screen and the native engine both rely on that recogniser
        // for their Menu). BUG-165: not while the cover is being dismissed; re-enabling it mid-press
        // let it see the exit press's release over a view that was already leaving.
        if !coverIsBeingDismissed { gateCoverMenuTap(enabled: true) }
        // An exit inside the Aspect flash's 2 s still stores the resting mode (review r1 P2 #1).
        if aspectPillDirty {
            aspectFlashWork?.cancel()
            state.transport.aspectFlash = nil
            persistAspectIfNeeded()
        }
    }

    /// The SwiftUI full-screen cover that hosts this controller carries its own Menu press
    /// recogniser (a `UITapGestureRecognizer` for the Menu press on the `UITransitionView`). It
    /// recognises in parallel with the responder chain and cancels the press this controller
    /// consumed, so a Menu meant to hide the bar, cancel a scan or dismiss the up-next chip closed
    /// the player instead (P1 device pass 2026-10-06, steps 4 + 9; the simulator probe below
    /// showed the recogniser at state 3 on `pressesCancelled`, and `interactiveDismissDisabled`
    /// leaves it enabled). While this controller is on screen that recogniser is switched off:
    /// every Menu is decided by `MenuPrecedence`, and `.exit` dismisses through `onExit`.
    /// `UIPress.PressType.menu` is press type 5, the only entry in the recogniser's allowed set.
    private weak var coverMenuTap: UIGestureRecognizer?

    private func gateCoverMenuTap(enabled: Bool) {
        if coverMenuTap == nil, !enabled {
            var responder: UIResponder? = self
            var depth = 0
            while let r = responder, depth < 40 {
                if let v = r as? UIView, String(describing: type(of: v)) == "UITransitionView",
                   let tap = v.gestureRecognizers?.first(where: {
                       $0 is UITapGestureRecognizer
                           && $0.allowedPressTypes.map(\.intValue) == [UIPress.PressType.menu.rawValue]
                   }) {
                    coverMenuTap = tap
                    break
                }
                responder = r.next
                depth += 1
            }
        }
        coverMenuTap?.isEnabled = enabled
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isLeavingPlayer {
            closeFailover()
            // r1 P3 #6: no job runs out its pass and no connection stays open under the next screen.
            thumbScrubWork?.cancel(); thumbScrubWork = nil
            thumbs.cancel()
            thumbs.stop(.modeOff)
            closeThumbnailer()
        }
        pollTimer?.invalidate()
        pollTimer = nil
        stopHoldTimer()
        cancelExactStage()
        apply(transport.cancel())
        saveProgress(flush: true)
        stopTraktScrobble()
        displayModeHoldStartedAt = nil
        state.displayModeHolding = false
        clearDisplayCriteria()
    }

    override var canBecomeFirstResponder: Bool { true }

    private func layoutMetalLayer() {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = UIScreen.main.nativeScale
        let drawable = CGSize(
            width: (bounds.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (bounds.height * scale).rounded(.toNearestOrAwayFromZero)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        metalLayer.contentsScale = scale
        if drawable != lastDrawableSize {
            metalLayer.drawableSize = drawable
            lastDrawableSize = drawable
        }
        CATransaction.commit()
    }

    // MARK: - MPV setup (proven option set from the iOS player)

    private func setupMpv() {
        // On REAL tvOS hardware no audio routes to HDMI unless the AVAudioSession is active
        // BEFORE the audio unit initializes — and with audio-fallback-to-null=yes a failed
        // audiounit init silently plays video with no sound (the simulator doesn't enforce
        // this, which is why audio worked there). The app-startup activation is async on a
        // background queue, so re-activate synchronously here (idempotent, cheap) and LOG
        // failures instead of swallowing them.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("[MPV] AVAudioSession activation FAILED: \(error)")
        }

        mpv = mpv_create()
        guard mpv != nil else { print("[MPV] Failed to create mpv instance"); return }

        checkError(mpv_request_log_messages(mpv, "warn"))
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer))

        // Video output: default `gpu` (stable). On REAL Apple TV hardware the user can opt into
        // `gpu-next` (libplacebo) via Settings → Playback → Enhanced Video Renderer for better HDR
        // tone-mapping (dynamic peak detection, DV/HDR10+). Never on the simulator, where
        // libplacebo's vo asserts ("vo: hit program assert").
        //
        // B10 (BUG-166; Steven's rc4 verdict, "DV colours wrong", green/magenta): `gpu` has no
        // Dolby Vision RPU processing, so a profile 5 stream (IPTPQc2, no HDR10 base layer) renders
        // as plain BT.2020 PQ. The router flags every DV P5 it sends here (`forcesGpuNext`), and
        // that forces `gpu-next` with the toggle off. Still hardware only.
        var videoOutput = "gpu"
        #if !targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: PlayerTuning.enhancedRendererKey) {
            videoOutput = "gpu-next"
        } else if forcesGpuNext {
            videoOutput = "gpu-next"
            print("[MPV] vo=gpu-next reason=dv-p5")
        }
        #endif
        usesGpuNext = videoOutput == "gpu-next"

        let options: [(String, String)] = [
            ("vo", videoOutput),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            // On REAL Apple TV hardware ao_audiounit fails to init entirely: its channel-layout
            // query returns kAudioUnitErr_InvalidProperty (-10879) → ao=null → silence (the sim
            // worked because the Mac's stereo output answers the query). ao_avfoundation
            // (AVSampleBufferAudioRenderer, Apple-native) doesn't need that query — use it first,
            // fall back to audiounit. Requires MPVKit >= 0.41.0-n8.1.2 (PR #73 enabled the
            // avfoundation ao for tvOS; PROVEN working on Apple TV 4K 3rd gen 2026-07-02).
            ("ao", "avfoundation,audiounit"),
            ("audio-channels", "auto"),
            ("audio-fallback-to-null", "yes"),
            // P5 B20: Boost goes up to +10 dB = 316 % on the `volume` property.
            ("volume-max", "\(PlayerAudioEffects.volumeMax)"),
            ("vulkan-swap-mode", "fifo"),
            ("vulkan-queue-count", "1"),
            ("vulkan-async-compute", "no"),
            ("vulkan-async-transfer", "no"),
            // `vulkan-disable-interop` was dropped 2026-09-07: it is not an mpv option and never was
            // (absent from `video/out/vulkan/context.c` in every tag from v0.34.0 through v0.41.0,
            // and from the bundled libmpv 0.41.0 / MPVKit 0.41.0-n8.1.2 binary). It came in with the
            // iOS bridge's option list (upstream 4476a3f5); libmpv rejected it on every launch, which
            // was the long-standing anonymous `[MPV] API error: option not found`. Nothing replaces
            // it: it never took effect, so the proven Apple TV vulkan/moltenvk behaviour is already
            // the behaviour without it. The four vulkan-* options above are still valid in 0.41.
            ("video-rotate", "no"),
            ("keep-open", "yes"),
            ("target-colorspace-hint", "yes"),
            ("tone-mapping", "auto"),
            ("hdr-compute-peak", "yes"),
            ("subs-fallback", "yes"),
            // Back buffer floor (P1): lets a backward step or a returned scan land inside already
            // cached media. The Streaming Buffer block below raises it, never lowers it.
            ("demuxer-max-back-bytes", "64MiB"),
        ]
        for (key, value) in options {
            let status = mpv_set_option_string(mpv, key, value)
            if status < 0 {
                print("[MPV] option rejected: \(key)=\(value) (\(String(cString: mpv_error_string(status))))")
            }
        }

        // Preferred audio language as an OPTION, before `mpv_initialize`: this is what makes mpv's
        // own first `aid=auto` resolution honor the preference, so the right track is playing from
        // the first frame instead of being switched into a beat later (the audible mid-playback
        // switch upstream 4f79bfe0 removed on mobile). The property re-apply in
        // `applyAudioLanguagePreferences()` just before `loadfile` is only the fallback for the case
        // where the settings store had not hydrated yet at this point.
        preferredAudioLanguages = resolvePreferredAudioLanguages()
        if !preferredAudioLanguages.isEmpty {
            let alangStatus = mpv_set_option_string(
                mpv, "alang", PlayerAudioLanguagePlan.alangValue(targets: preferredAudioLanguages)
            )
            if alangStatus < 0 {
                print("[MPV] option rejected: alang (\(String(cString: mpv_error_string(alangStatus))))")
            }
            didApplyAlang = true
        }
        alangTrace("targets=\(preferredAudioLanguages) applied=\(didApplyAlang)")

        // Picture fit as OPTIONS too (review r1 P3 #4): `playerSettings` was just seeded, so a
        // Fill/Zoom profile shows its first frame filled instead of snapping from Fit at
        // FILE_LOADED (where `applyAspect` publishes the mode and writes the same values again).
        let startAspect = PlayerAspectMode.initial(syncedName: playerSettings?.resizeMode.name)
        if startAspect != .fit {
            let p = startAspect.mpvProps
            for (key, value) in [("video-aspect-override", p.aspectOverride),
                                 ("panscan", String(p.panscan)), ("video-zoom", String(p.videoZoom))] {
                let status = mpv_set_option_string(mpv, key, value)
                if status < 0 {
                    print("[MPV] option rejected: \(key)=\(value) (\(String(cString: mpv_error_string(status))))")
                }
            }
        }

        // User-tunable streaming buffer (Settings > Playback > Streaming Buffer). 0 = mpv defaults.
        let bufferMB = UserDefaults.standard.integer(forKey: PlayerTuning.bufferMBKey)
        if bufferMB > 0 {
            checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "\(bufferMB)MiB"))
            checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", "\(max(bufferMB / 2, 64))MiB"))
        }
        let readaheadSec = UserDefaults.standard.integer(forKey: PlayerTuning.readaheadSecKey)
        if readaheadSec > 0 {
            checkError(mpv_set_option_string(mpv, "cache", "yes"))
            checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "\(readaheadSec)"))
            checkError(mpv_set_option_string(mpv, "cache-secs", "\(readaheadSec)"))
        }

        checkError(mpv_initialize(mpv))
        // Everything the UI needs is observed with a data payload so state flows to us on the
        // event queue — the main thread never issues a synchronous property read (see PropSnapshot).
        mpv_observe_property(mpv, ObservedProp.timePos.rawValue, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, ObservedProp.duration.rawValue, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, ObservedProp.pause.rawValue, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.coreIdle.rawValue, "core-idle", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.pausedForCache.rawValue, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.eofReached.rawValue, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.trackCount.rawValue, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, ObservedProp.videoW.rawValue, "video-params/w", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, ObservedProp.videoH.rawValue, "video-params/h", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, ObservedProp.aid.rawValue, "aid", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, ObservedProp.cacheBuffering.rawValue, "cache-buffering-state", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, ObservedProp.seekable.rawValue, "seekable", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.fileFormat.rawValue, "file-format", MPV_FORMAT_STRING)

        let relay = MPVWakeupRelay(queue: eventQueue) { [weak self] in self?.drainEvents() }
        wakeupRelay = relay
        mpv_set_wakeup_callback(mpv, MPVWakeupRelay.callback, relay.context)
    }

    // MARK: - Preferred audio language

    /// Read the player settings SYNCHRONOUSLY (the same pattern the native engine uses in
    /// `NativePlaybackCoordinator.resolveLanguagePlan`) and resolve the audio-language targets in
    /// priority order. The `playerSettingsWatcher` installed in `viewDidAppear` only starts AFTER
    /// `loadfile`, far too late to steer mpv's first track pick, so the preference has to be read
    /// here. Also seeds `playerSettings`, which closes the hole where `autoSelectPreferredTracks`
    /// used to bail out (without latching) on the first track walk because settings were still nil.
    private func resolvePreferredAudioLanguages() -> [String] {
        PlayerSettingsRepository.shared.ensureLoaded()
        guard let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState else {
            return []
        }
        playerSettings = settings
        return PlayerLanguagePreferencesKt.resolvePreferredAudioLanguageTargets(
            preferredAudioLanguage: settings.preferredAudioLanguage,
            secondaryPreferredAudioLanguage: settings.secondaryPreferredAudioLanguage,
            deviceLanguages: DeviceLanguagePreferences.shared.preferredLanguageCodes(),
            contentOriginalLanguage: PlayerAudioLanguagePlan.originalLanguage(for: context)
        )
    }

    /// Property-level re-apply of the audio-language preference, mirroring upstream's
    /// `MPVPlayerBridge.applyAudioLanguagePreferences`: set `alang`, write the current numeric `aid`
    /// straight back, then hand selection to `auto` so the core re-resolves it against the new
    /// `alang`. Called once, immediately before `loadfile`.
    ///
    /// These are synchronous property calls on the main thread, which the BUG-2/BUG-3 rule
    /// documented above `refreshTracksAsync()` otherwise forbids. They are safe HERE and only here:
    /// nothing is loaded yet, so the core lock is uncontended and cannot stall. Do not move any
    /// synchronous mpv property access onto the main thread once playback has started.
    private func applyAudioLanguagePreferences() {
        guard mpv != nil, !didUserSelectAudio else { return }
        if preferredAudioLanguages.isEmpty {
            preferredAudioLanguages = resolvePreferredAudioLanguages()
        }
        guard !preferredAudioLanguages.isEmpty else { return }
        setMpvString("alang", PlayerAudioLanguagePlan.alangValue(targets: preferredAudioLanguages))
        if let currentId = getString("aid"), Int(currentId) != nil {
            setMpvString("aid", currentId)
        }
        setMpvString("aid", "auto")
        didApplyAlang = true
    }

    /// Addon-declared stream headers (`context.requestHeaders`, already sanitized by the shared
    /// `sanitizePlaybackHeaders`) → mpv's `http-header-fields`, applied to every HTTP request this
    /// handle makes (media, HLS segments, addon subtitle side-loads — matching mobile). The
    /// serialization mirrors upstream `MPVPlayerBridge.applyRequestHeaders` exactly: sorted keys,
    /// `Key: Value` pairs comma-joined, `\` and `,` escaped in values, and an explicit "" clear
    /// when there are no headers so a header-free load can never inherit a previous stream's
    /// headers should this handle ever load more than one file. Called before `loadfile`.
    /// Credential-class header names (lowercased). When the stream carries any of these, mpv's
    /// GLOBAL `http-header-fields` would also send them to every `sub-add` URL — i.e. leak the
    /// media host's credentials to unrelated subtitle providers (Codex 2026-08-20 round 4, P1).
    /// `subAdd` checks this flag and side-loads such subtitles through its own credential-free
    /// download instead of letting the core fetch them.
    private static let credentialHeaderNames: Set<String> = ["authorization", "cookie", "proxy-authorization"]
    private var streamHeadersCarryCredentials = false

    private func applyRequestHeaders(_ headers: [String: String]) {
        guard mpv != nil else { return }
        streamHeadersCarryCredentials = headers.keys.contains {
            Self.credentialHeaderNames.contains($0.lowercased())
        }
        if headers.isEmpty {
            setMpvString("http-header-fields", "")
            return
        }

        let serialized = headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { key, value in
                let escapedValue = value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: ",", with: "\\,")
                return "\(key): \(escapedValue)"
            }
            .joined(separator: ",")
        setMpvString("http-header-fields", serialized)
    }

    // MARK: - Tracks

    private struct TrackInfo {
        let id: Int; let lang: String; let title: String; let forced: Bool; let selected: Bool
    }

    /// Schedule a track-list walk on `eventQueue`. The walk is dozens of synchronous property
    /// reads — cheap at steady state but seconds-slow while the core is starting up, so it must
    /// never run on the main thread (beta BUG-3: swipe-up menu slow to appear early in playback).
    /// Coalesced: a burst of track events settles into one walk.
    private func refreshTracksAsync() {
        eventQueue.async { [weak self] in
            guard let self, !self.trackRefreshPending, self.mpv != nil else { return }
            self.trackRefreshPending = true
            self.eventQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.trackRefreshPending = false
                self.walkAndPublishTracks()
            }
        }
    }

    /// Runs on `eventQueue`: one pass over track-list building both the UI rows and the raw
    /// infos the auto-selection logic needs, then publishes on main.
    private func walkAndPublishTracks() {
        guard mpv != nil else { return }
        let sideLoadActive = subtitleSideLoads.isActive
        let preferredLoadsPending = subtitleSideLoads.hasPreferredPending
        let count = getInt("track-list/count")
        var audio: [PlayerTrack] = []
        var subs: [PlayerTrack] = [PlayerTrack(id: -1, label: String(localized: "Off"), isSelected: getString("sid") == "no")]
        var audioInfos: [TrackInfo] = []
        var subInfos: [TrackInfo] = []
        var externalSource: String?
        var badgeVideo: PlayerBadgeFacts?
        var badgeAudio: [Int: PlayerBadgeFacts] = [:]

        for i in 0..<count {
            let type = getString("track-list/\(i)/type") ?? ""
            if badgesInPlayer, type == "video", getFlag("track-list/\(i)/selected"), !getFlag("track-list/\(i)/albumart") {
                badgeVideo = readBadgeVideo(trackIndex: i)
            }
            guard type == "audio" || type == "sub" else { continue }
            let id = getInt("track-list/\(i)/id")
            let selected = getFlag("track-list/\(i)/selected")
            let label = trackLabel(index: i, fallbackId: id)
            let info = TrackInfo(
                id: id,
                lang: getString("track-list/\(i)/lang") ?? "",
                title: getString("track-list/\(i)/title") ?? "",
                forced: getFlag("track-list/\(i)/forced"),
                selected: selected
            )
            if type == "audio" {
                audio.append(PlayerTrack(id: id, label: label, isSelected: selected))
                audioInfos.append(info)
                if badgesInPlayer { badgeAudio[id] = readBadgeAudio(trackIndex: i, lang: info.lang, selected: selected) }
            } else {
                subs.append(PlayerTrack(id: id, label: label, isSelected: selected))
                subInfos.append(info)
                if selected, getFlag("track-list/\(i)/external") {
                    externalSource = getString("track-list/\(i)/external-filename")
                }
            }
        }
        if badgesInPlayer {
            badgeVideoFacts = badgeVideo
            badgeAudioFacts = badgeAudio
            publishBadgeFacts(aid: audioInfos.first(where: \.selected)?.id)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let newSubs = subs.count > 1 ? subs : []
            // Don't rebuild the lists while the picker is open — reassigning them rebuilds the
            // SwiftUI list and snaps focus back to the top. Exception: the picker is showing its
            // empty state (first open raced the walk), where populating beats focus preservation.
            // The panel diffs its rows by stable ids, so refreshing while it is open is safe.
            if self.state.audioTracks != audio { self.state.audioTracks = audio }
            if self.state.subtitleTracks != newSubs { self.state.subtitleTracks = newSubs }
            if self.state.selectedExternalSubtitleSource != externalSource {
                self.state.selectedExternalSubtitleSource = externalSource
            }
            // Hand-offs still on their way, and an add-on subtitle search still running, count as
            // loading (review r1 P3-2): their files have not reached the queue yet.
            let arriving = self.subtitleHandoffsInFlight > 0 || self.state.subtitleSearchInFlight
            self.autoSelectPreferredTracks(audioInfos: audioInfos, subInfos: subInfos,
                                           sideLoadActive: sideLoadActive || arriving,
                                           preferredLoadsPending: preferredLoadsPending || arriving)
        }
    }

    // MARK: - Player badges (upstream 344117e73)

    /// "Show Badges in Player" changed. Turning it on walks once, so the facts arrive without
    /// waiting for the next track event.
    private func setBadgesInPlayer(_ on: Bool) {
        eventQueue.async { [weak self] in
            guard let self, self.badgesInPlayer != on else { return }
            self.badgesInPlayer = on
            if on { self.refreshTracksAsync() }
        }
    }

    /// `eventQueue`: the selected video entry of the walk. Resolution from the demuxer (known before
    /// the first frame), HDR/bit depth from `video-params` once decoded (`refreshBadgeVideoParams`).
    private func readBadgeVideo(trackIndex i: Int) -> PlayerBadgeFacts {
        var facts = PlayerBadgeFacts()
        let w = getInt("video-params/w"), h = getInt("video-params/h")
        let demuxW = getInt("track-list/\(i)/demux-w"), demuxH = getInt("track-list/\(i)/demux-h")
        if w > 0, h > 0 { facts.videoWidth = w; facts.videoHeight = h }
        else if demuxW > 0, demuxH > 0 { facts.videoWidth = demuxW; facts.videoHeight = demuxH }
        facts.videoCodec = getString("track-list/\(i)/codec")
        let profile = getString("track-list/\(i)/codec-profile")
        facts.hdr = PlayerBadgeMatch.mpvHDR(gamma: getString("video-params/gamma"),
                                            dolbyVisionProfile: getInt("track-list/\(i)/dolby-vision-profile"))
        facts.bitDepth = PlayerBadgeMatch.bitDepth(pixelFormat: getString("video-params/pixelformat"), codecProfile: profile)
        facts.fileName = PlayerBadgeMatch.fileName(from: context.url)
        facts.streamName = PlayerBadgeMatch.streamName(title: context.streamTitle, subtitle: context.streamSubtitle)
        return facts
    }

    /// `eventQueue`: one audio entry of the walk (codec, FFmpeg profile such as "Dolby Digital
    /// Plus + Dolby Atmos", channels, language). The selected one falls back to `audio-params`.
    private func readBadgeAudio(trackIndex i: Int, lang: String, selected: Bool) -> PlayerBadgeFacts {
        var facts = PlayerBadgeFacts()
        facts.audioCodec = getString("track-list/\(i)/codec")
        facts.audioProfile = getString("track-list/\(i)/codec-profile")
        var channels = getInt("track-list/\(i)/demux-channel-count")
        if channels <= 0, selected { channels = getInt("audio-params/channel-count") }
        facts.audioChannels = channels > 0 ? channels : nil
        facts.languages = PlayerBadgeMatch.languageTokens(lang)
        return facts
    }

    /// `eventQueue`: the decoded video params arrived or changed (HDR transfer, bit depth, size).
    private func refreshBadgeVideoParams() {
        guard badgesInPlayer, let video = badgeVideoFacts else { return }
        badgeVideoFacts = PlayerBadgeMatch.mpvVideoParams(
            video, width: getInt("video-params/w"), height: getInt("video-params/h"),
            gamma: getString("video-params/gamma"), pixelFormat: getString("video-params/pixelformat"))
        publishBadgeFacts(aid: Int(getString("aid") ?? ""))
    }

    /// `eventQueue`: the selected video facts merged with the audio entry `aid`, published on main.
    private func publishBadgeFacts(aid: Int?) {
        guard badgesInPlayer, let facts = PlayerBadgeMatch.mpvMerged(
            video: badgeVideoFacts, audio: badgeAudioFacts, aid: aid,
            fileName: PlayerBadgeMatch.fileName(from: context.url),
            streamName: PlayerBadgeMatch.streamName(title: context.streamTitle, subtitle: context.streamSubtitle))
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state.badgeFacts != facts else { return }
            self.state.badgeFacts = facts
        }
    }

    /// Once, on first load: reconcile the audio track against the user's preferred languages, then
    /// run the shared audio-aware subtitle auto-selection plan (upstream v0.3.0 parity).
    ///
    /// Audio is now a FALLBACK here: `alang` was already handed to mpv before init (see
    /// `setupMpv()`), so the core's own pick normally satisfies the preference and this pass does
    /// nothing. It only forces `aid` when mpv's selection does not match any target — e.g. a track
    /// whose language tag mpv reads differently than the shared matcher does.
    ///
    /// Subtitles are unchanged: with "Use forced subtitles" on and the audio already in your
    /// preferred language, only a FORCED track in that language is selected (none -> subtitles
    /// off); otherwise non-forced tracks in the preferred languages are considered. No plan (e.g.
    /// forced-subs on but audio language undeterminable) -> leave mpv's own defaults untouched.
    ///
    /// Audio is decided on the first walk. The subtitle half stays open while subtitle side-loads
    /// run and nothing matched yet (`MPVSubtitleAutoSelectGate`), and is decided on a later walk:
    /// side-loads no longer finish before the first walk (the queue stall, 2026-10-18).
    private func autoSelectPreferredTracks(audioInfos: [TrackInfo], subInfos: [TrackInfo],
                                           sideLoadActive: Bool, preferredLoadsPending: Bool) {
        // `playerSettings` is now seeded synchronously in `setupMpv()`, so this guard can no longer
        // return without latching on the first walk (which used to defer the whole selection to a
        // later track-list change, or to the panel being opened).
        guard let settings = playerSettings, mpv != nil else { return }
        guard !audioInfos.isEmpty || !subInfos.isEmpty else { return }
        let firstWalk = !didAutoSelectTracks
        didAutoSelectTracks = true
        guard firstWalk || (!didAutoSelectSubtitles && !didUserSelectSubtitle) else { return }

        let deviceLanguages = DeviceLanguagePreferences.shared.preferredLanguageCodes()
        let audioTargets = PlayerLanguagePreferencesKt.resolvePreferredAudioLanguageTargets(
            preferredAudioLanguage: settings.preferredAudioLanguage,
            secondaryPreferredAudioLanguage: settings.secondaryPreferredAudioLanguage,
            deviceLanguages: deviceLanguages,
            contentOriginalLanguage: PlayerAudioLanguagePlan.originalLanguage(for: context)
        )

        // Audio: only worth switching when there's more than one option, and only when mpv's own
        // pick misses. `alang` already steered that pick, so re-poking `aid` whenever a target
        // merely matches would switch the track after the first frame — exactly the audible switch
        // the proactive `alang` exists to eliminate. `trackToForce` returns nil when a matching
        // track is already selected.
        var pickedAudioId: Int?
        if firstWalk, !didUserSelectAudio, audioInfos.count > 1,
           let id = PlayerAudioLanguagePlan.trackToForce(
               targets: audioTargets,
               tracks: audioInfos.map { (id: $0.id, lang: $0.lang, selected: $0.selected) }
           ) {
            eventQueue.async { [weak self] in self?.setMpvInt("aid", Int64(id)) }
            pickedAudioId = id
        }

        // The audio the viewer will actually hear: picked above, else mpv's selection, else first.
        let effectiveAudio = audioInfos.first { $0.id == pickedAudioId }
            ?? audioInfos.first { $0.selected }
            ?? audioInfos.first
        let effectiveAudioTrack: AudioTrack? = effectiveAudio.map { info in
            AudioTrack(
                index: 0,
                id: String(info.id),
                label: info.title.isEmpty ? info.lang : info.title,
                language: info.lang.isEmpty ? nil : info.lang,
                isSelected: true
            )
        }

        // Subtitles: shared plan decides targets + forced/normal mode.
        guard !didAutoSelectSubtitles, !didUserSelectSubtitle else { return }
        // FEAT-84 Off stays Off: no fallback subtitle language while Subtitles is Off (the shared
        // resolver would return it). See `SubtitleFallbackGuard`.
        let subTargets = PlayerLanguagePreferencesKt.resolvePreferredSubtitleLanguageTargets(
            preferredSubtitleLanguage: settings.preferredSubtitleLanguage,
            secondaryPreferredSubtitleLanguage: SubtitleFallbackGuard.effectiveSecondary(
                primary: settings.preferredSubtitleLanguage,
                secondary: settings.secondaryPreferredSubtitleLanguage
            ),
            deviceLanguages: deviceLanguages
        )
        guard !subInfos.isEmpty else {
            if !sideLoadActive { didAutoSelectSubtitles = true }
            return
        }
        guard let plan = PlayerTrackSelectionKt.resolveSubtitleAutoSelectionPlan(
                  selectedAudioTrack: effectiveAudioTrack,
                  preferredAudioTargets: audioTargets,
                  preferredSubtitleTargets: subTargets,
                  useForcedSubtitles: settings.subtitleStyle.useForcedSubtitles
              )
        else {
            // "Use forced subtitles" on, audio language unknown (BUG-171): subtitles off, as
            // upstream's runtime does. Leaving mpv's own pick meant ANY track (`subs-fallback=yes`).
            didAutoSelectSubtitles = true
            if !didApplyAutoSubtitleOff {
                didApplyAutoSubtitleOff = true
                eventQueue.async { [weak self] in self?.setMpvString("sid", "no") }
            }
            return
        }

        let sharedSubs = subInfos.enumerated().map { index, info in
            SubtitleTrack(
                index: Int32(index),
                id: String(info.id),
                label: info.title.isEmpty ? info.lang : info.title,
                language: info.lang.isEmpty ? nil : info.lang,
                isSelected: info.selected,
                isForced: info.forced
            )
        }
        let match = PlayerTrackSelectionKt.findPreferredSubtitleTrackIndex(
            tracks: sharedSubs, targets: plan.targets, mode: plan.mode, selectedAudioTrack: effectiveAudioTrack
        )
        let matchId = match >= 0 ? Int64(subInfos[Int(match)].id) : nil
        // Final = later loads cannot change the pick (`MPVSubtitleAutoSelectGate`): the match is in
        // the top language, that language has no pt/es variant tie-break, and it is not a forced
        // track a full one arriving later would replace.
        var matchIsFinal = false
        if match >= 0, let top = plan.targets.first {
            let normalizedTop = SubtitleLanguageMatching.shared.normalizeLanguageCode(lang: top)
            let topOnly = PlayerTrackSelectionKt.findPreferredSubtitleTrackIndex(
                tracks: sharedSubs, targets: [top], mode: plan.mode, selectedAudioTrack: effectiveAudioTrack
            )
            matchIsFinal = topOnly == match
                && !["pt", "pt-br", "es", "es-419"].contains(normalizedTop)
                && (plan.mode == .forcedOnly || !subInfos[Int(match)].forced)
        }
        switch MPVSubtitleAutoSelectGate.decide(matchId: matchId, matchIsFinal: matchIsFinal,
                                                forcedOnly: plan.mode == .forcedOnly,
                                                preferredLoadsPending: preferredLoadsPending,
                                                sideLoadActive: sideLoadActive,
                                                noTargets: plan.targets.isEmpty) {
        case .select(let sid):
            didAutoSelectSubtitles = true
            eventQueue.async { [weak self] in self?.setMpvInt("sid", sid) }
        case .off(let final):
            // Forced-only plan with no forced track in that language, or no target language at
            // all ("No subtitles", BUG-171): keep subtitles off.
            if final { didAutoSelectSubtitles = true }
            guard !didApplyAutoSubtitleOff else { break }
            didApplyAutoSubtitleOff = true
            eventQueue.async { [weak self] in self?.setMpvString("sid", "no") }
        case .wait:
            break
        case .done:
            didAutoSelectSubtitles = true
        }
    }

    private func trackLabel(index: Int, fallbackId: Int) -> String {
        let lang = (getString("track-list/\(index)/lang") ?? "").trimmingCharacters(in: .whitespaces)
        let title = (getString("track-list/\(index)/title") ?? "").trimmingCharacters(in: .whitespaces)
        let codec = (getString("track-list/\(index)/codec") ?? "").trimmingCharacters(in: .whitespaces)
        var parts = [lang, title].filter { !$0.isEmpty }
        var label = parts.isEmpty ? String(localized: "Track \(fallbackId)") : parts.joined(separator: " \u{00B7} ")
        if !codec.isEmpty { label += " (\(codec))" }
        return label
    }

    private func selectAudio(_ id: Int) {
        didUserSelectAudio = true
        guard mpv != nil else { return }
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            var v = Int64(id)
            mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &v)
        }
        refreshTracksAsync()
    }

    /// Once the file is loaded: side-load stream-provided subtitles and kick off an addon subtitle fetch.
    private func onFileLoaded() {
        guard !fileLoaded else { return }
        fileLoaded = true
        // Restore any subtitle delay saved for this exact video (per title/episode, per profile —
        // beta.15 §B2). `setSubtitleDelay` re-saves the same value, which is a harmless no-op.
        if let storedMs = PlayerTrackPreferenceStorage.shared.loadSubtitleDelayMs(videoId: context.videoId) {
            setSubtitleDelay(Double(storedMs.intValue) / 1000.0)
        }
        // Audio delay persists the same way (per title/episode, per profile). P5 N1: a stream's
        // `behaviorHints.audioDelayMs` becomes the base and is applied WITHOUT saving.
        let storedAudioMs = PlayerTrackPreferenceStorage.shared.loadAudioDelayMs(videoId: context.videoId)
        audioDelayParts = AudioDelayParts(
            savedMs: Int32(storedAudioMs?.intValue ?? 0),
            streamMs: context.streamAudioDelayMs.map { KotlinInt(int: Int32($0)) },
            sessionAdjustMs: 0
        )
        if storedAudioMs != nil || context.streamAudioDelayMs != nil {
            let totalMs = Int(StreamAudioDelay.shared.totalMs(parts: audioDelayParts))
            print("[AudioDelay] base=\(context.streamAudioDelayMs != nil ? "stream" : "saved") total=\(totalMs)")
            setMpvDouble("audio-delay", Double(totalMs) / 1000.0)
            state.audioDelaySec = Double(totalMs) / 1000.0
        }
        state.audioDelayLimitSec = Double(StreamAudioDelay.shared.uiLimitMs(parts: audioDelayParts)) / 1000.0
        // P5 B20: restore Boost (the Audio Mode filter is applied on MPV_EVENT_AUDIO_RECONFIG).
        let fx = PlayerAudioEffects.storedState()
        state.audioEffects = fx
        if fx.boostDb > 0 { setMpvDouble("volume", PlayerAudioEffects.volumePercent(boostDb: fx.boostDb)) }
        // P5 B23: a remembered speed for this show (series only; movies never load or show it).
        if context.season != nil || context.episode != nil {
            state.rememberSpeedAvailable = true
            if let saved = PlayerTrackPreferenceStorage.shared.loadPlaybackSpeed(parentMetaId: context.parentMetaId)?.doubleValue {
                state.rememberSpeed = true
                setSpeed(saved)
            }
        }
        for sub in context.externalSubtitles {
            subAdd(url: sub.url, title: sub.name ?? sub.language, lang: sub.language, rank: 0)
        }
        SubtitleRepository.shared.fetchAddonSubtitles(type: context.contentType, videoId: context.videoId)
        // A stream-picker prefetch may already have completed (the fetch call above then no-ops,
        // and the flow watcher's replay fired before fileLoaded was set) — side-load what's there.
        // Key check: never side-load a lingering list that belongs to a different title.
        if (SubtitleRepository.shared.completedRequest.value_ as? String)
            == SubtitleRepository.shared.requestKey(type: context.contentType, videoId: context.videoId),
           let prefetched = SubtitleRepository.shared.addonSubtitles.value_ as? [AddonSubtitle], !prefetched.isEmpty {
            addAddonSubtitles(prefetched)
        }
        applySubtitleStyle()
        // Picture fit from the synced resize mode (the phone shares it); Stretch never persists.
        let startAspect = PlayerAspectMode.initial(syncedName: playerSettings?.resizeMode.name)
        aspectWriteback = AspectWriteback(start: startAspect)
        applyAspect(startAspect)
        if displayModeHoldStartedAt != nil {
            print("[DisplayMode] params poll start")
            awaitVideoParamsThenSwitchDisplayMode()
        } else {
            applyDisplayCriteriaIfEnabled()
        }
        fetchSkipSegments()
        #if DEBUG
        applySmokeSkipInterval()
        #endif
        startTraktScrobble()
        trackerScrobble.start(positionSec: state.positionSec, durationSec: state.durationSec)
    }

    // MARK: - Match content frame rate (AVDisplayManager)

    /// Window whose display criteria we set — cleared on teardown so the display mode reverts.
    private weak var displayCriteriaWindow: UIWindow?

    /// Ask tvOS to switch the display mode to the content's native frame rate (and dynamic range,
    /// when mpv reports BT.2020/PQ/HLG). Public-API path for non-AVAsset players: build a
    /// `CMVideoFormatDescription` from mpv's reported params and use
    /// `AVDisplayCriteria(refreshRate:formatDescription:)`. Requires the user's tvOS
    /// Settings > Video and Audio > Match Content to allow frame-rate matching.
    private func applyDisplayCriteriaIfEnabled() {
        guard UserDefaults.standard.bool(forKey: PlayerTuning.matchFrameRateKey) else { return }
        // Poll (off-main, the hold's poll without the hold) until the decoder reports its colour
        // params, then set the criteria once. A one-shot read at FILE_LOADED comes back with no
        // primaries or gamma, so an HDR title asked for an SDR mode: the queue-stall fix
        // (2026-10-18) made that read prompt on gpu-next, where nothing holds the start, and the
        // TV stayed SDR (`criteria … primaries=- gamma=-`). Before, the stalled queue had delayed
        // the read until the params happened to be there. Its 20 s are the whole window: the
        // latch stops the hold's late retry from adding 20 s more (review r2 P3).
        lateParamsPollStarted = true
        awaitVideoParamsThenSwitchDisplayMode(deadline: ProcessInfo.processInfo.systemUptime + 20)
    }

    @discardableResult
    private func applyDisplayCriteria(
        fps: Double, width: Int, height: Int, codecName: String, primaries: String, gamma: String
    ) -> Bool {
        guard fps > 10, let window = view.window else { return false }
        guard width > 0, height > 0 else { return false }

        let codecType: CMVideoCodecType =
            (codecName.contains("hevc") || codecName.contains("265")) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        var extensions: [CFString: Any] = [:]
        if primaries.contains("2020") {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        }
        if gamma.contains("pq") {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        } else if gamma.contains("hlg") {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }

        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { return false }

        displayCriteriaWindow = window
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(fps),
            formatDescription: formatDescription
        )
        print("[DisplayMode] criteria fps=\(String(format: "%.3f", fps)) \(width)x\(height) codec=\(codecName) primaries=\(primaries.isEmpty ? "-" : primaries) gamma=\(gamma.isEmpty ? "-" : gamma)")
        return true
    }

    // MARK: - BUG-170: hold the start for the display-mode switch
    //
    // Steven (rc5, mpv): films started SDR and switched to HDR ~10 s in. The criteria used to be
    // set once at FILE_LOADED, before the first frame decoded, so `video-params/primaries`/`gamma`
    // were still empty: tvOS switched to SDR at the frame rate, and HDR only arrived later through
    // mpv's own colour hint, as a second mode switch mid-playback. Now, with Match Content on, the
    // file loads PAUSED, the criteria wait for the first decoded frame's real colour params, and
    // playback starts once tvOS reports the switch finished (or a cap passes). The loading overlay
    // stays up throughout (the hold counts as buffering). `debug.displayModeHoldOff` = old behaviour.

    /// `systemUptime` the hold began; nil when not holding (never started, released, or the user
    /// took over with Play/Pause).
    private var displayModeHoldStartedAt: TimeInterval?
    /// Set in `setupMpv`. On `gpu-next` a file held paused before its first frame wedged this
    /// player's mpv queue (Batch E device pass 10-18, DV P5 MP4: no stats, criteria or harvest
    /// after the release), so there is no hold there: the criteria follow the colour params mid-play
    /// as before BUG-170.
    private var usesGpuNext = false

    private func beginDisplayModeHoldIfNeeded() {
        guard UserDefaults.standard.bool(forKey: PlayerTuning.matchFrameRateKey),
              !UserDefaults.standard.bool(forKey: "debug.displayModeHoldOff"),
              !usesGpuNext,
              let window = view.window,
              window.avDisplayManager.isDisplayCriteriaMatchingEnabled else { return }
        displayModeHoldStartedAt = ProcessInfo.processInfo.systemUptime
        state.displayModeHolding = true
        setFlag("pause", true)
        print("[DisplayMode] hold begin")
        // A hard cap on the whole hold, independent of FILE_LOADED and the params poll: a DV P5 MP4
        // on gpu-next sat paused on the loading screen indefinitely (Batch E device pass 10-18,
        // Dune WEB-DL "Dolby Vision TV"; no release line, no file-loaded work). Params (3 s) +
        // switch (6 s) fit inside it.
        let started = displayModeHoldStartedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayModeHoldCapSeconds) { [weak self] in
            guard let self, let started, self.displayModeHoldStartedAt == started else { return }
            self.releaseDisplayModeHold(reason: "hold-cap fileLoaded=\(self.fileLoaded ? 1 : 0)")
        }
    }

    static let displayModeHoldCapSeconds: TimeInterval = 10

    /// Bumped by `clearDisplayCriteria` (teardown, a cover): a params poll started before it must
    /// not set the window's criteria again afterwards (review r1 P3).
    private var displayCriteriaEpoch = 0

    /// After FILE_LOADED: wait (off-main) for the decoder's colour params, then set the criteria
    /// once with everything known. Holding: up to 3 s, then the start is released and the poll
    /// keeps going WITHOUT the hold (up to 20 s more), so a slow first frame (a remote 4K remux with
    /// a resume seek) still gets its mode, just mid-play like before (review r1 P2).
    private func awaitVideoParamsThenSwitchDisplayMode(deadline: TimeInterval? = nil, epoch: Int? = nil) {
        let deadline = deadline ?? ProcessInfo.processInfo.systemUptime + 3
        let epoch = epoch ?? displayCriteriaEpoch
        eventQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.mpv != nil else { return }
            let width = self.getInt("video-params/w")
            let gamma = (self.getString("video-params/gamma") ?? "").lowercased()
            let ready = width > 0 && !gamma.isEmpty
            #if DEBUG
            // Only the outcome: a tick line every 100 ms drowned the log (review r2 P3).
            if ready || ProcessInfo.processInfo.systemUptime >= deadline {
                NSLog("[MPVQueue] params poll read w=%d gamma=%@ ready=%d", width, gamma, ready ? 1 : 0)
            }
            #endif
            if !ready && ProcessInfo.processInfo.systemUptime < deadline {
                self.awaitVideoParamsThenSwitchDisplayMode(deadline: deadline, epoch: epoch)
                return
            }
            let fps = self.getDouble("container-fps")
            let height = self.getInt("video-params/h")
            let codecName = (self.getString("video-codec") ?? "").lowercased()
            let primaries = (self.getString("video-params/primaries") ?? "").lowercased()
            DispatchQueue.main.async {
                guard epoch == self.displayCriteriaEpoch, self.fileLoaded, self.mpv != nil else {
                    print("[DisplayMode] params poll dropped epoch=\(epoch == self.displayCriteriaEpoch ? 1 : 0) fileLoaded=\(self.fileLoaded ? 1 : 0)")
                    return
                }
                guard ready else {
                    // Params missed the hold's window: play now, keep polling for the mode.
                    self.releaseDisplayModeHold(reason: "no-params")
                    if !self.lateParamsPollStarted {
                        self.lateParamsPollStarted = true
                        self.awaitVideoParamsThenSwitchDisplayMode(
                            deadline: ProcessInfo.processInfo.systemUptime + 20, epoch: epoch)
                    }
                    return
                }
                let applied = self.applyDisplayCriteria(fps: fps, width: width, height: height,
                                                        codecName: codecName, primaries: primaries, gamma: gamma)
                guard self.displayModeHoldStartedAt != nil else { return }   // user took over, or late poll
                guard applied else { self.releaseDisplayModeHold(reason: "no-criteria"); return }
                self.waitForDisplayModeSwitch(appliedAt: ProcessInfo.processInfo.systemUptime, sawSwitch: false)
            }
        }
    }

    /// One late (non-holding) params poll per controller.
    private var lateParamsPollStarted = false

    /// Main thread. A switch may take a moment to start; give it 0.6 s to show up, then hold until
    /// it ends. Capped at 6 s so a TV that never reports can't stall playback.
    private func waitForDisplayModeSwitch(appliedAt: TimeInterval, sawSwitch: Bool) {
        guard displayModeHoldStartedAt != nil else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - appliedAt
        let switching = displayCriteriaWindow?.avDisplayManager.isDisplayModeSwitchInProgress ?? false
        if elapsed >= 6 { releaseDisplayModeHold(reason: "cap"); return }
        if !switching && (sawSwitch || elapsed >= 0.6) {
            releaseDisplayModeHold(reason: sawSwitch ? "switched" : "no-switch")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForDisplayModeSwitch(appliedAt: appliedAt, sawSwitch: sawSwitch || switching)
        }
    }

    private func releaseDisplayModeHold(reason: String) {
        guard let started = displayModeHoldStartedAt else { return }
        displayModeHoldStartedAt = nil
        state.displayModeHolding = false
        print("[DisplayMode] release reason=\(reason) held=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))ms")
        guard mpv != nil else { return }
        updateProps { $0.paused = false }
        eventQueue.async { [weak self] in self?.setFlag("pause", false) }
        refreshState()
    }

    private func clearDisplayCriteria() {
        displayCriteriaEpoch &+= 1
        displayCriteriaWindow?.avDisplayManager.preferredDisplayCriteria = nil
        displayCriteriaWindow = nil
    }

    // MARK: - Trakt scrobbling
    //
    // Simplified vs. mobile: scrobble "start" once when the file loads, "stop" once with the final
    // progress when the player goes away (Trakt marks the item watched at >= 80%). The shared repo
    // resolves IMDB/TMDB ids itself and silently no-ops when Trakt isn't connected.

    private func startTraktScrobble() {
        guard !traktScrobbleRequested else { return }
        // Error/placeholder clips (debrid cache-sync stubs, error videos) must not
        // open a Trakt session — mirrors the shared short-placeholder guard.
        if WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(state.durationSec * 1000)) { return }
        traktScrobbleRequested = true
        TraktScrobbleRepository.shared.buildItem(
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            title: context.title,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: nil,
            releaseInfo: nil
        ) { [weak self] item, _ in
            // Suspend completions can land off-main; hop before touching controller state.
            DispatchQueue.main.async {
                guard let self, let item, !self.traktSessionClosed else { return }
                self.traktScrobbleItem = item
                TraktScrobbleRepository.shared.scrobbleStart(
                    profileId: ActiveProfileProvider.shared.activeProfileId,
                    item: item,
                    progressPercent: self.currentProgressPercent()
                ) { _ in }
            }
        }
    }

    private func stopTraktScrobble() {
        // The other trackers close on the same two teardown paths (viewDidDisappear + deinit);
        // idempotent, and independent of whether a Trakt item was ever built.
        trackerScrobble.stop(positionSec: state.positionSec, durationSec: state.durationSec, isLive: holdsLiveProgress)
        traktSessionClosed = true
        guard let item = traktScrobbleItem else { return }
        traktScrobbleItem = nil
        // A session can open before a placeholder's short duration is known, or before the stream
        // reads live: close it at 0% so Trakt never marks the stub or the live stream watched.
        TraktScrobbleRepository.shared.scrobbleStop(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            item: item,
            progressPercent: Float(TrackerScrobblePolicy.stopPercent(positionSec: state.positionSec,
                                                                     durationSec: state.durationSec,
                                                                     isLive: holdsLiveProgress))
        ) { _ in }
    }

    private func currentProgressPercent() -> Float {
        let duration = state.durationSec
        guard duration > 0 else { return 0 }
        return Float(min(100, max(0, state.positionSec / duration * 100)))
    }

    // MARK: - Subtitle appearance (mirrors the mobile libmpv mapping)

    /// Push the user's subtitle style into libmpv. Colors are `SubtitleColor` argb longs (0xAARRGGBB);
    /// the size/outline/border-style formulas match `PlayerEngine.android`'s `applySubtitleStyle`.
    private func applySubtitleStyle() {
        guard mpv != nil, let style = playerSettings?.subtitleStyle else { return }
        setMpvString("sub-ass-override", "no")
        setMpvString("sub-color", mpvColorString(style.textColor))
        setMpvString("sub-back-color", mpvColorString(style.backgroundColor))
        setMpvString("sub-outline-color", mpvColorString(style.outlineColor))
        setMpvString("sub-border-color", mpvColorString(style.outlineColor))
        setMpvString("sub-border-style", subtitleBorderStyle(style))
        setMpvString("sub-bold", style.bold ? "yes" : "no")
        setMpvInt("sub-font-size", subtitleFontSize(style))
        let outline = subtitleOutlineSize(style)
        setMpvInt("sub-outline-size", outline)
        setMpvInt("sub-border-size", outline)
        setMpvInt("sub-pos", Int64(max(0, min(100, 100 - Int(style.bottomOffset) / 10))))
        setMpvString("sub-filter-sdh", style.stripSdh ? "yes" : "no")
        setMpvString("sub-filter-sdh-harder", style.stripSdh ? "yes" : "no")
    }

    private func mpvColorString(_ argb: Int64) -> String {
        let a = (argb >> 24) & 0xFF, r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF
        return String(format: "#%02X%02X%02X%02X", a, r, g, b)
    }

    private func subtitleFontSize(_ s: SubtitleStyleState) -> Int64 {
        let scaled = Int(Double(s.fontSizeSp) * (55.0 / 18.0))
        return Int64(max(36, min(122, scaled)))
    }

    private func subtitleOutlineSize(_ s: SubtitleStyleState) -> Int64 {
        guard s.outlineEnabled else { return 0 }
        return Int64(max(1, Int(Double(s.outlineWidth) * 1.5)))
    }

    private func subtitleBorderStyle(_ s: SubtitleStyleState) -> String {
        if s.outlineEnabled { return "outline-and-shadow" }
        let backgroundAlpha = (s.backgroundColor >> 24) & 0xFF
        return backgroundAlpha > 0 ? "opaque-box" : "outline-and-shadow"
    }

    #if DEBUG
    /// Sim-harness trace for the proactive `alang` audio preference (`debug.mpvAlangTrace`).
    private func alangTrace(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: "debug.mpvAlangTrace") else { return }
        print("[MPVAlang] \(message())")
    }
    #else
    private func alangTrace(_ message: @autoclosure () -> String) {}
    #endif

    private func setMpvString(_ name: String, _ value: String) {
        guard let mpv else { return }
        checkError(mpv_set_property_string(mpv, name, value))
    }

    private func setMpvInt(_ name: String, _ value: Int64) {
        guard let mpv else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_INT64, &v)
    }

    /// Fetch intro/recap/outro segments for a series episode, or IntroDB credits/post-credits
    /// segments for a movie (upstream cbe4dc0a). Works for anime out of the box (AniSkip/AnimeSkip);
    /// other content needs an `INTRO_DB_URL` configured. `requireSkipIntroEnabled: false` bypasses
    /// the mobile settings gate. The full list is kept — `post-credits` intervals never get a chip
    /// but are skip targets and drive the up-next hold.
    private func fetchSkipSegments() {
        if let season = context.season, let episode = context.episode {
            SkipIntroRepository.shared.getSkipIntervalsForContentId(
                // Routes kitsu:/mal: anime ids to the anime providers; everything else keeps the
                // IMDB path. parentMetaId carries the prefix for addon-sourced anime.
                contentId: context.parentMetaId,
                season: Int32(season),
                episode: Int32(episode),
                // Respect the Settings > Playback "Skip Intro" toggle (skipIntroEnabled).
                requireSkipIntroEnabled: true
            ) { [weak self] intervals, _ in
                guard let intervals else { return }
                DispatchQueue.main.async { self?.applySkipIntervals(intervals) }
            }
        } else if context.contentType.lowercased() == "movie" {
            SkipIntroRepository.shared.getMovieSkipIntervals(
                contentId: context.parentMetaId,
                videoId: context.videoId,
                requireSkipIntroEnabled: true
            ) { [weak self] intervals, _ in
                guard let intervals else { return }
                DispatchQueue.main.async { self?.applySkipIntervals(intervals) }
            }
        }
    }

    #if DEBUG
    /// `debug.mpvSmokeSkipInterval` = "start,end,type" (smoke harness only): one synthetic interval.
    private var smokeSkipActive = false
    private func applySmokeSkipInterval() {
        guard UserDefaults.standard.string(forKey: "debug.mpvSmokeURL") != nil,
              let raw = UserDefaults.standard.string(forKey: "debug.mpvSmokeSkipInterval") else { return }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, let start = Double(parts[0]), let end = Double(parts[1]) else { return }
        smokeSkipActive = true
        applySkipIntervals([SkipInterval(startTime: start, endTime: end, type: parts[2], provider: "smoke")], isSmoke: true)
    }
    #endif

    private func applySkipIntervals(_ intervals: [SkipInterval], isSmoke: Bool = false) {
        #if DEBUG
        // The smoke interval stands: the real fetch's (empty) answer must not replace it.
        if smokeSkipActive, !isSmoke { return }
        #endif
        skipPlanner.setIntervals(intervals)
        state.skipIntervals = intervals
        state.transport.skipSpans = intervals.compactMap { interval in
            // Post-credits intervals are skip targets only, never drawn on the bar.
            guard interval.type.trimmingCharacters(in: .whitespaces).lowercased() != "post-credits" else { return nil }
            return TransportSpan(start: interval.startTime, end: interval.endTime, kind: interval.type)
        }
    }

    private func addAddonSubtitles(_ subs: [AddonSubtitle]) {
        guard fileLoaded else { return }
        // "Show only preferred languages": same shared filter the native path and the mobile
        // runtime apply, so the setting isn't engine-dependent.
        let kept = playerSettings.map {
            PlayerTrackSelectionKt.filterAddonSubtitlesForSettings(subtitles: subs, settings: $0)
        } ?? subs
        // Preferred-language files load first: they are what the auto selection looks for, and
        // it waits for them while they load (`MPVSubtitleAutoSelectGate`).
        let targets = playerSettings.map { PlayerTrackSelectionKt.preferredSubtitleTargetsForSettings(settings: $0) } ?? []
        subAdd(kept.map { sub in
            MPVSubtitleSideLoadQueue.Job(
                source: sub.url, title: sub.display, lang: sub.language,
                rank: targets.firstIndex { SubtitleLanguageMatching.shared.matchesLanguageCode(language: sub.language, target: $0) }
            )
        })
    }

    private func subAdd(url: String, title: String, lang: String, rank: Int?) {
        subAdd([MPVSubtitleSideLoadQueue.Job(source: url, title: title, lang: lang, rank: rank)])
    }

    /// Main. Hands the new files to the side-load queue on `eventQueue`, which runs `sub-add`
    /// asynchronously, one file at a time (`MPVSubtitleSideLoadQueue`): a synchronous `sub-add`
    /// downloads the file before it returns and held the queue for minutes on a long add-on list.
    private func subAdd(_ jobs: [MPVSubtitleSideLoadQueue.Job]) {
        guard mpv != nil else { return }
        var direct: [MPVSubtitleSideLoadQueue.Job] = []
        for job in jobs where !addedSubtitleUrls.contains(job.source) {
            addedSubtitleUrls.insert(job.source)
            let url = job.source
            // Credential leak guard (Codex round 4, P1): with credential-class stream headers set
            // globally on this handle, an in-core `sub-add <http url>` would send them to the
            // subtitle host. Download the file ourselves WITHOUT those headers and hand mpv a local
            // path instead. Only this rare credential case takes the new path — header-free and
            // benign-header (Referer/UA) streams keep the exact in-core behavior below.
            if streamHeadersCarryCredentials,
               let remote = URL(string: url), remote.scheme == "http" || remote.scheme == "https" {
                subtitleHandoffsInFlight += 1
                URLSession.shared.dataTask(with: remote) { [weak self] data, _, error in
                    guard let self else { return }
                    guard let data, error == nil, !data.isEmpty else {
                        NSLog("[MPVPlayer] credential-scoped subtitle fetch failed for %@ — skipping side-load", url)
                        DispatchQueue.main.async { self.subtitleHandoffArrived() }
                        return
                    }
                    let ext = remote.pathExtension.isEmpty ? "srt" : remote.pathExtension
                    let local = FileManager.default.temporaryDirectory
                        .appendingPathComponent("mpv-sub-\(UUID().uuidString).\(ext)")
                    do {
                        try data.write(to: local)
                    } catch {
                        NSLog("[MPVPlayer] credential-scoped subtitle write failed — skipping side-load")
                        DispatchQueue.main.async { self.subtitleHandoffArrived() }
                        return
                    }
                    let localJob = MPVSubtitleSideLoadQueue.Job(source: local.path, title: job.title,
                                                                 lang: job.lang, rank: job.rank)
                    self.handOffSubtitleSideLoads([localJob], counted: true)
                }.resume()
                continue
            }
            direct.append(job)
        }
        guard !direct.isEmpty else { return }
        subtitleHandoffsInFlight += 1
        handOffSubtitleSideLoads(direct, counted: true)
    }

    /// Any thread. Queues the jobs on `eventQueue`, then (when `counted`) settles the hand-off
    /// counter on main once they are in the queue, where the next walk sees them.
    private func handOffSubtitleSideLoads(_ jobs: [MPVSubtitleSideLoadQueue.Job], counted: Bool) {
        eventQueue.async { [weak self] in
            guard let self else { return }
            if self.mpv != nil {
                for job in jobs { self.subtitleSideLoads.enqueue(job) }
                self.pumpSubtitleSideLoads()
            }
            // Strong hop to main (critique C13): `deinit` can never run on `eventQueue`.
            if counted { DispatchQueue.main.async { self.subtitleHandoffArrived() } }
        }
    }

    /// Main. A hand-off reached the queue (or was dropped): when it was the last one, walk once so
    /// a selection that waited on it can be decided.
    private func subtitleHandoffArrived() {
        subtitleHandoffsInFlight = max(0, subtitleHandoffsInFlight - 1)
        if subtitleHandoffsInFlight == 0, fileLoaded { refreshTracksAsync() }
    }

    /// `eventQueue` only, never from inside `drainEvents` (it drains). Closes the finished load's
    /// attribution window and issues the next `sub-add`, unless one is still in flight.
    private func pumpSubtitleSideLoads() {
        guard mpv != nil else { return }
        // r2 P3: the fetch's FFmpeg lines (URL-less `tcp:` / `tls:` lines) are buffered while
        // the command runs; drain them before closing its window, so a timed-out subtitle fetch
        // never reads as main-stream network evidence. r3 P3: the same drain also runs BEFORE the
        // next window opens, so lines queued before the command are judged as the main stream's;
        // the window then holds only what that `sub-add` produced. (Same windows as the old
        // synchronous chain: drain, open, command, drain, close.)
        drainEvents()
        guard subtitleSideLoads.inFlight == nil else { return }
        if subtitleLoadWindowOpen {
            subtitleLoadWindowOpen = false
            logRing.subtitleLoadDrained()
        }
        guard let next = subtitleSideLoads.start(now: ProcessInfo.processInfo.systemUptime) else { return }
        subtitleLoadWindowOpen = true
        logRing.subtitleLoadBegan()
        let status = commandAsync(replyId: next.id, "sub-add", args: [next.job.source, "auto", next.job.title, next.job.lang])
        #if DEBUG
        let n = subtitleSideLoads.finished + 1
        if n <= 3 || next.job.preferred || n % MPVSubtitleSideLoadQueue.walkEvery == 0 {
            NSLog("[SubLoad] start n=%ld pref=%d pending=%ld status=%d", n, next.job.preferred ? 1 : 0,
                  subtitleSideLoads.pending.count, status)
        }
        #endif
        if status < 0 {
            // Refused outright (already logged): no reply will come, so move on. The last job
            // still gets its final walk (review r1 P3-1).
            subtitleSideLoads.abandonInFlight()
            if !subtitleSideLoads.isActive { refreshTracksAsync() }
            eventQueue.async { [weak self] in self?.pumpSubtitleSideLoads() }
        }
    }

    /// `eventQueue` only, from `drainEvents`: the side-load in flight finished (or failed).
    private func finishSubtitleSideLoad(replyId: UInt64, error: CInt) {
        guard let finish = subtitleSideLoads.finish(replyId: replyId, now: ProcessInfo.processInfo.systemUptime) else { return }
        checkError(error)
        #if DEBUG
        let n = subtitleSideLoads.finished
        if n <= 3 || finish.job.preferred || n % MPVSubtitleSideLoadQueue.walkEvery == 0 || !subtitleSideLoads.isActive {
            NSLog("[SubLoad] done n=%ld pref=%d took=%ldms err=%d pending=%ld", n, finish.job.preferred ? 1 : 0,
                  Int(finish.tookSec * 1000), error, subtitleSideLoads.pending.count)
        }
        #endif
        if finish.walkTracks { refreshTracksAsync() }
        eventQueue.async { [weak self] in self?.pumpSubtitleSideLoads() }
    }

    private func selectSubtitle(_ id: Int) {
        didUserSelectSubtitle = true
        guard mpv != nil else { return }
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            if id < 0 {
                self.checkError(mpv_set_property_string(mpv, "sid", "no"))
            } else {
                var v = Int64(id)
                mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &v)
            }
        }
        refreshTracksAsync()
    }

    // MARK: - Playback speed & A/V-subtitle timing

    private func setSpeed(_ speed: Double) {
        guard mpv != nil else { return }
        if case .scanning = transport.mode { return }
        setMpvDouble("speed", speed)
        state.playbackSpeed = speed
        if state.rememberSpeed {
            PlayerTrackPreferenceStorage.shared.savePlaybackSpeed(parentMetaId: context.parentMetaId, speed: speed)
        }
    }

    /// P5 B23: toggles "Remember Speed for This Show". On saves the current speed; off forgets it.
    private func setRememberSpeed(_ on: Bool) {
        guard context.season != nil || context.episode != nil else { return }
        state.rememberSpeed = on
        if on {
            PlayerTrackPreferenceStorage.shared.savePlaybackSpeed(parentMetaId: context.parentMetaId, speed: state.playbackSpeed)
        } else {
            PlayerTrackPreferenceStorage.shared.clearPlaybackSpeed(parentMetaId: context.parentMetaId)
        }
    }

    /// Single source of truth for subtitle re-timing on the mpv path: applies to the running core,
    /// updates the UI state, and persists per title/profile (beta.15 §B1/B2). Called both for user
    /// chip presses and for the persisted-value replay in `onFileLoaded()` — the redundant save on
    /// replay is a same-value no-op.
    private func setSubtitleDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        setMpvDouble("sub-delay", seconds)
        state.subtitleDelaySec = seconds
        let delayMs = Int32((seconds * 1000).rounded())
        PlayerTrackPreferenceStorage.shared.saveSubtitleDelayMs(videoId: context.videoId, delayMs: delayMs)
    }

    /// P5 N1: the user's new total delay. With a stream hint active the change is a session tweak
    /// on top of the hint and is never saved; without one it persists per episode as before.
    private func setAudioDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        audioDelayParts = StreamAudioDelay.shared.applyUserTotal(parts: audioDelayParts, newTotalMs: Int32((seconds * 1000).rounded()))
        let totalSec = Double(StreamAudioDelay.shared.totalMs(parts: audioDelayParts)) / 1000.0
        setMpvDouble("audio-delay", totalSec)
        state.audioDelaySec = totalSec
        state.audioDelayLimitSec = Double(StreamAudioDelay.shared.uiLimitMs(parts: audioDelayParts)) / 1000.0
        if let persist = StreamAudioDelay.shared.persistableMs(parts: audioDelayParts) {
            PlayerTrackPreferenceStorage.shared.saveAudioDelayMs(videoId: context.videoId, delayMs: persist.int32Value)
        }
    }

    /// P5 N1 (product call): with a stream hint active, Reset returns to the hint (drops only the
    /// session tweak), not to 0 s. Without a hint it is the old "set 0" and persists as before.
    private func resetAudioDelay() {
        guard mpv != nil else { return }
        guard let hint = audioDelayParts.streamMs else {
            if StreamAudioDelay.shared.totalMs(parts: audioDelayParts) != 0 { setAudioDelay(0) }
            return
        }
        audioDelayParts = AudioDelayParts(savedMs: audioDelayParts.savedMs, streamMs: hint, sessionAdjustMs: 0)
        let totalSec = Double(StreamAudioDelay.shared.totalMs(parts: audioDelayParts)) / 1000.0
        setMpvDouble("audio-delay", totalSec)
        state.audioDelaySec = totalSec
    }

    // MARK: - Audio effects (P5 B20)

    /// Main. Boost in dB on mpv's `volume` property (volume-max is 320). Persisted device-wide.
    private func setAudioBoost(_ db: Int) {
        guard mpv != nil else { return }
        let boost = PlayerAudioEffects.clampBoost(db)
        UserDefaults.standard.set(boost, forKey: PlayerTuning.boostDbKey)
        setMpvDouble("volume", PlayerAudioEffects.volumePercent(boostDb: boost))
        state.audioEffects.boostDb = boost
    }

    /// Main. Persists the mode, publishes it, and re-applies the `af` filter on `eventQueue`.
    private func setAudioMode(_ mode: PlayerAudioMode) {
        guard mpv != nil else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: PlayerTuning.audioModeKey)
        state.audioEffects.mode = mode
        eventQueue.async { [weak self] in self?.applyAudioFilter() }
    }

    /// `eventQueue` only. Builds the `af` value from the stored mode and the live output layout and
    /// sets it when it differs from the last one applied (the gate also stops an AUDIO_RECONFIG loop).
    private func applyAudioFilter() {
        guard let mpv else { return }
        let mode = PlayerAudioEffects.storedState().mode
        let value = PlayerAudioEffects.afValue(
            mode: mode,
            channels: getString("audio-params/channels"),
            channelCount: getInt("audio-params/channel-count")
        )
        guard value != lastAppliedAf else { return }
        let rc = mpv_set_property_string(mpv, "af", value)
        if rc >= 0 { lastAppliedAf = value }
        print("[AudioFx] af=\(value) rc=\(rc)")
    }

    private func setMpvDouble(_ name: String, _ value: Double) {
        guard mpv != nil else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
    }

    // MARK: - Stream info (diagnostics overlay)

    /// Runs on `eventQueue` (many synchronous property reads). `engine` is passed in because
    /// `state` is main-actor.
    private func buildStreamInfo(engine: String, subtitleDelaySec: Double) -> StreamInfoSnapshot {
        var info = StreamInfoSnapshot()
        // Append the active subtitle delay to the Engine row so a device pass can read it without
        // opening the panel (beta.15 §B2) — e.g. "mpv · subs +1.50 s".
        if subtitleDelaySec != 0 {
            let suffix = String(format: "subs %+.2f s", subtitleDelaySec)
            info.engine = engine.isEmpty ? suffix : "\(engine) \u{00B7} \(suffix)"
        } else {
            info.engine = engine
        }
        let w = getInt("video-params/w"), h = getInt("video-params/h")
        if w > 0, h > 0 { info.resolution = "\(w)\u{00D7}\(h)" }
        info.videoCodec = getString("video-codec") ?? ""
        let fps = getDouble("container-fps")
        if fps > 0 { info.fps = String(format: "%.3f fps", fps) }
        info.hwdec = getString("hwdec-current") ?? ""
        let vbr = getDouble("video-bitrate")
        if vbr > 0 { info.videoBitrate = Self.streamInfoRate(vbr / 1_000_000, unit: "Mbps") }
        let audioCodec = getString("audio-codec-name") ?? ""
        let channels = getInt("audio-params/channel-count")
        let sampleRate = getInt("audio-params/samplerate")
        var audioParts = [audioCodec]
        if channels > 0 { audioParts.append("\(channels)ch") }
        if sampleRate > 0 { audioParts.append("\(sampleRate / 1000) kHz") }
        info.audio = audioParts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        var cacheParts: [String] = []
        let cacheSec = getDouble("demuxer-cache-duration")
        if cacheSec > 0 { cacheParts.append(String(format: "%.0fs buffered", cacheSec.rounded())) }
        let cacheSpeed = getDouble("cache-speed")
        if cacheSpeed > 0 { cacheParts.append(Self.streamInfoRate(cacheSpeed / 1_000_000, unit: "MB/s")) }
        info.cache = cacheParts.joined(separator: " \u{00B7} ")
        return info
    }

    /// BUG-180: rates are rounded before they reach the snapshot, so the equality gate in
    /// `refreshStreamInfoAsync` holds on small wobble: one decimal below 10, whole numbers above.
    nonisolated static func streamInfoRate(_ value: Double, unit: String) -> String {
        value >= 10 ? String(format: "%.0f %@", value.rounded(), unit) : String(format: "%.1f %@", value, unit)
    }

    // MARK: - Watch progress (resume + save)

    private func computeResumePosition() {
        // A failure-alert retry resumes where the failed attempt stopped.
        if let s = context.resumeAtSec, s > 10 { pendingResumeSec = s; return }
        // Start Over: play from 0 whatever progress is saved. Not after a native fallback that
        // already played: that session's own saved progress is the point to continue from.
        if context.startFromBeginning, nativeSecondsPlayedBeforeFallback <= 0 {
            print("[Failover] start over: ignoring saved progress")
            return
        }
        guard let entry = WatchProgressRepository.shared.progressForVideo(
            videoId: context.videoId,
            parentMetaId: context.parentMetaId,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) }
        ), !entry.isCompleted else { return }
        if entry.lastPositionMs > 0 {
            let seconds = Double(entry.lastPositionMs) / 1000.0
            if seconds > 10 { pendingResumeSec = seconds }
        } else if entry.progressFraction > 0 {
            pendingResumeEntry = entry
        }
    }

    private lazy var session = WatchProgressPlaybackSession(
        profileId: ActiveProfileProvider.shared.activeProfileId,
        contentType: context.contentType,
        parentMetaId: context.parentMetaId,
        parentMetaType: context.contentType,
        videoId: context.videoId,
        title: context.title,
        logo: nil,
        poster: context.poster,
        background: context.background,
        seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
        episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
        episodeTitle: nil,
        episodeThumbnail: nil,
        providerName: context.providerName,
        providerAddonId: context.providerAddonId,
        lastStreamTitle: context.streamTitle,
        lastStreamSubtitle: context.streamSubtitle,
        pauseDescription: nil,
        lastSourceUrl: context.persistedSourceUrl
    )

    private func saveProgress(flush: Bool = false) {
        guard mpv != nil else { return }
        let duration = state.durationSec
        let position = state.positionSec
        guard LivePlaybackPolicy.shouldSaveResume(isLive: holdsLiveResume, positionSec: position, durationSec: duration) else { return }
        if !savedResumeThisSession {
            savedResumeThisSession = true
            resumeEntryBeforeSession = WatchProgressRepository.shared.progressForVideo(
                videoId: context.videoId, parentMetaId: context.parentMetaId,
                seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
                episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) })
        }

        let snapshot = PlayerPlaybackSnapshot(
            isLoading: false,
            isPlaying: !state.isPaused,
            isEnded: false,
            durationMs: Int64(duration * 1000),
            positionMs: Int64(position * 1000),
            bufferedPositionMs: Int64(position * 1000),
            playbackSpeed: Float(state.playbackSpeed),
            videoWidth: Int32(truncatingIfNeeded: cachedProps().videoW),
            videoHeight: Int32(truncatingIfNeeded: cachedProps().videoH)
        )
        if flush {
            WatchProgressRepository.shared.flushPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        } else {
            WatchProgressRepository.shared.upsertPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        }
    }

    /// The stream turned live after this session saved resume (a stall or pause outlasted the
    /// settle hold): no Continue Watching row for it. Puts back the entry from before the session,
    /// or clears the one it wrote when there was none. `parentMetaId: nil`: the save stored the
    /// provider-normalised parent id, which need not match `context.parentMetaId`.
    private func undoSessionResumeSaves() {
        savedResumeThisSession = false
        guard let prior = resumeEntryBeforeSession else {
            WatchProgressRepository.shared.clearProgress(videoId: context.videoId, parentMetaId: nil)
            return
        }
        // A percentage-only (tracker) entry cannot be written back: left as the session wrote it.
        guard let restore = PlaybackProgressRecorder.restoration(of: prior,
                                                                 profileId: ActiveProfileProvider.shared.activeProfileId) else { return }
        WatchProgressRepository.shared.flushPlaybackProgress(session: restore.session, snapshot: restore.snapshot,
                                                             syncRemote: false)
    }

    // MARK: - State polling

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refreshState() {
        guard mpv != nil else { return }
        // Cached values only — the mpv core is never touched from the main thread (BUG-2/BUG-3:
        // synchronous reads stall for seconds while the core fills its cache early in playback).
        let snap = cachedProps()

        // Equality-gated: `@Published` fires on equal writes, and this runs every tick, so a
        // paused player would otherwise re-render the overlay and transport bar twice a second.
        let position = max(snap.position, 0)
        if state.durationSec != snap.duration { state.durationSec = snap.duration }
        let wasLive = isLiveStream
        if LivePlaybackPolicy.reportsLive(seekable: fileLoaded ? snap.seekable : nil) {
            reportsLive = true
        }
        durationGrowth = LivePlaybackPolicy.nextDurationGrowth(durationGrowth, mediaKey: context.url.absoluteString,
                                                               durationSec: snap.duration,
                                                               nowSec: ProcessInfo.processInfo.systemUptime,
                                                               fromRequestedMedia: fileLoaded)
        if !wasLive, isLiveStream {
            print("[Live] mpv: live (reported=\(reportsLive) grew=\(durationGrowth.grew)): no resume or tracker progress")
            if savedResumeThisSession { undoSessionResumeSaves() }
        }
        if state.positionSec != position { state.positionSec = position }
        // Paused → playing without input (the pause-card-off rule left no hide timer armed):
        // re-arm the hide so the bar does not stay up until the next press.
        if state.isPaused && !snap.paused && state.controlsVisible { scheduleHide() }
        if state.isPaused != snap.paused { state.isPaused = snap.paused }
        // BUG-170: the display-mode hold reads as buffering, so the loading overlay stays up and
        // the paused start never shows the pause card.
        let buffering = snap.cacheWait || (snap.coreIdle && !snap.paused) || displayModeHoldStartedAt != nil
        if state.isBuffering != buffering { state.isBuffering = buffering }
        samplePlayClock(snap)
        if !startupStages.started {
            // B24: a percentage only while mpv is really waiting on its cache; the position
            // advancing > 1 s while playing is the start backstop (spec §8.1).
            var changed = startupStages.bufferingPercent(
                snap.cacheWait && snap.cacheBufferingPct >= 0 ? Int(snap.cacheBufferingPct) : nil)
            changed = startupStages.tick(positionSec: snap.position, paused: snap.paused) || changed
            if changed { publishStartupStage() }
        }

        // Seek preview harvest (P2-B): playback time only, never while the transport moves.
        let harvestNow = ProcessInfo.processInfo.systemUptime
        if harvest.tick(now: harvestNow,
                        playing: fileLoaded && !snap.paused && !snap.cacheWait && !snap.coreIdle && !snap.eof && snap.videoW > 0,
                        transportIdle: !transport.mode.isActive,
                        seekInFlight: skipPlanner.seekInFlight != nil,
                        recentInput: harvestNow - lastClickUptime < HarvestScheduler.recentInputSec,
                        overlayUp: playerOverlayUp),
           thumbs.inFlight == nil {
            // One heavy thing at a time: the tick stays due until a decode is not in flight.
            startHarvest()
        }
        if seekPreviewMode.allowsDecode {
            if harvestNow - lastCacheHealthRead >= 2 { refreshCacheHealthAsync() }
            driveThumbs()
        }

        // Transport bar mirror + preview model inputs (P1).
        if transport.durationSec != snap.duration { transport.durationSec = snap.duration }
        if state.transport.durationSec != snap.duration { state.transport.durationSec = snap.duration }
        // The published chapter list is re-derived from the untrimmed one whenever the duration
        // moves: end markers drop once the duration is known (review r1 P2 #2), and come back if a
        // growing duration passes them (review r2 P3 #5).
        if snap.duration != chaptersTrimDuration {
            chaptersTrimDuration = snap.duration
            if let next = PlayerChapters.republished(raw: rawChapters, published: state.transport.chapters,
                                                     durationSec: snap.duration) {
                state.transport.chapters = next
            }
        }
        if state.transport.positionSec != position { state.transport.positionSec = position }
        if state.transport.isPaused != snap.paused { state.transport.isPaused = snap.paused }
        if state.transport.playbackSpeed != state.playbackSpeed { state.transport.playbackSpeed = state.playbackSpeed }
        if case .scanning = transport.mode {
            if snap.eof { apply(transport.endScanInPlace()) }
            else {
                transport.noteLivePosition(snap.position)
                state.transport.previewSec = transport.previewSec
            }
        }
        if state.controlsVisible || transport.mode.isActive { refreshBufferedAsync() }
        #if DEBUG
        updateSeekProbe(paused: snap.paused)
        #endif

        // Rising-edge detection: eof-reached STAYS true while keep-open holds the last frame, so
        // only propagate transitions — otherwise a dismissed post-play cover re-presents each tick.
        if snap.eof != lastEofFlag {
            lastEofFlag = snap.eof
            if !(snap.eof && handleEarlyEndOfFile(snap)) {
                state.isEnded = snap.eof
            }
        }

        // BUG-180 (Steven rc7): only while someone can see the rows — the Stream Info overlay, or
        // the panel's Info tab (its rows and chips). Every other tab skipped a dozen mpv reads and a
        // publish twice a second. At most once every 2 s: diagnostics, not a meter.
        if state.showStreamInfo || (state.panelOpen && state.panelTab == .info),
           harvestNow - lastStreamInfoRefresh >= Self.streamInfoRefreshSec {
            lastStreamInfoRefresh = harvestNow
            refreshStreamInfoAsync()
        }

        let now = ProcessInfo.processInfo.systemUptime
        if !snap.paused, now - lastSaveUptime > 5 {
            lastSaveUptime = now
            saveProgress()
            logStartupStatsIfNeeded()
            reportHealthyIfNeeded()
        }

        updateSkipPrompt(position: snap.position, duration: snap.duration, paused: snap.paused)
    }

    /// First-90s diagnostics for the beta "laggy at first" report: one `[MPVStats]` line per
    /// progress-save tick (~5s) covering cache fill, network draw, and dropped frames. Reads run
    /// on `eventQueue`; grep the sysdiagnose/console output for `[MPVStats]`.
    private func logStartupStatsIfNeeded() {
        guard fileLoadedUptime > 0 else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - fileLoadedUptime
        #if DEBUG
        // One `[Mem]` line a minute for the whole playback (device rig 2026-10-15: the Info row's RSS
        // is unreadable by the rig on HDR titles and hidden in Off mode, so the comparison between
        // Seek Preview modes needs a logged number).
        // The first line comes from the `< 0` arm (first tick, ~+5 s), then one every 60 s.
        if lastMemLogElapsed < 0 || elapsed - lastMemLogElapsed >= 60 {
            lastMemLogElapsed = elapsed
            let snap = storeMirror
            print(String(format: "[Mem] +%.0fs rss=%ld MB mode=%@ store=%ld harvest=%ld decode=%ld",
                         elapsed, ProcessMemory.footprintMB(), seekPreviewMode.rawValue,
                         snap.count, snap.harvest, snap.decode))
            // Review P2: nothing else rebuilds the Info row in Off mode (no harvest, no decode), and
            // its RSS would otherwise only refresh on store events; rebuild it on the same cadence.
            rebuildPreviewSummary()
        }
        #endif
        guard elapsed < 90 else { return }
        let underruns = cacheWaitCount
        #if DEBUG
        let queuedAt = ProcessInfo.processInfo.systemUptime
        NSLog("[MPVQueue] stats queued +%.0fs", elapsed)
        #endif
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            #if DEBUG
            NSLog("[MPVQueue] stats ran lag=%dms", Int((ProcessInfo.processInfo.systemUptime - queuedAt) * 1000))
            #endif
            if !self.statsVOLogged {
                // P3-F9 step 0: which VO this file runs on (`gpu` or `gpu-next`); the two take the
                // screenshot readback through different code.
                self.statsVOLogged = true
                print("[MPVStats] vo=\(self.getString("current-vo") ?? "-")")
            }
            let cacheSec = self.getDouble("demuxer-cache-duration")
            let cacheSpeed = self.getDouble("cache-speed")
            #if DEBUG
            NSLog("[MPVQueue] stats read cache done")
            #endif
            let voDropped = self.getInt("frame-drop-count")
            let decDropped = self.getInt("decoder-frame-drop-count")
            #if DEBUG
            NSLog("[MPVQueue] stats read drops done")
            #endif
            print(String(
                format: "[MPVStats] +%.0fs cache=%.1fs net=%.1f MB/s dropped=vo:%d dec:%d underruns=%d",
                elapsed, cacheSec, cacheSpeed / 1_000_000, voDropped, decDropped, underruns
            ))
        }
    }

    /// Rebuilds the Stream Info panel rows off-main (it reads a dozen mpv properties).
    private func refreshStreamInfoAsync() {
        let engine = state.routingNote
        let subtitleDelaySec = state.subtitleDelaySec
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            let info = self.buildStreamInfo(engine: engine, subtitleDelaySec: subtitleDelaySec)
            DispatchQueue.main.async {
                if info != self.state.streamInfo { self.state.streamInfo = info }
            }
        }
    }

    /// Show a skip prompt while the playhead is inside a segment (leaving a 1s tail so the button
    /// disappears cleanly at the end), and auto-skip the segment types chosen in Settings. Cached
    /// values only (called from `refreshState`).
    private func updateSkipPrompt(position: Double, duration: Double, paused: Bool) {
        // Auto-skip also requires Skip Intro (the fetch already returns nothing without it).
        var autoSkipTypes: [AutoSkipSegmentType]? = playerSettings.flatMap { $0.skipIntroEnabled ? Array($0.autoSkipSegmentTypes) : nil }
        // No auto-skip mid-scan: the user is deliberately moving through the file.
        if case .scanning = transport.mode { autoSkipTypes = nil }
        let decision = skipPlanner.evaluate(positionSec: position, durationSec: duration,
                                            isPlaying: fileLoaded && !paused, autoSkipTypes: autoSkipTypes,
                                            now: ProcessInfo.processInfo.systemUptime)
        if let target = decision.autoSkipTargetSec { seekAbsolute(target, kind: .auto) }
        if decision.prompt != state.skipPrompt { state.skipPrompt = decision.prompt }
        #if DEBUG
        state.seekProbe.chip = state.skipPrompt != nil
        #endif
    }

    // MARK: - Buffered ranges (P1)

    /// One coalesced `demuxer-cache-state` read on `eventQueue` (never the main thread). mpv prints
    /// node properties as JSON when read as a string; when that yields nothing, falls back to one
    /// span `[time-pos, demuxer-cache-time]`.
    private func refreshBufferedAsync() {
        guard !bufferedReadPending, fileLoaded else { return }
        bufferedReadPending = true
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            let raw = self.getString("demuxer-cache-state")
            var ranges = raw.map { TransportPreview.parseSeekableRanges($0) } ?? []
            var fallback = false
            if ranges.isEmpty {
                fallback = true
                let pos = self.getDouble("time-pos")
                let cacheTime = self.getDouble("demuxer-cache-time")
                if cacheTime > pos { ranges = [BufferedRange(start: pos, end: cacheTime)] }
            }
            #if DEBUG
            let sinceLoad = ProcessInfo.processInfo.systemUptime - self.fileLoadedUptime
            if self.cacheStateLogCount == 0 || (self.cacheStateLogCount == 1 && sinceLoad >= 10) {
                self.cacheStateLogCount += 1
                print("[Transport] cache-state raw=\(raw.map { String($0.prefix(300)) } ?? "nil") ranges=\(ranges.count) fallback=\(fallback ? 1 : 0) +\(Int(sinceLoad))s")
            }
            #endif
            DispatchQueue.main.async {
                self.bufferedReadPending = false
                self.publishBuffered(ranges)
            }
        }
    }

    private func publishBuffered(_ raw: [BufferedRange]) {
        let merged = BufferedRange.merge(raw, gapSec: 5, durationSec: cachedProps().duration)
        transport.seekableRanges = merged
        let old = state.transport.bufferedRanges
        var changed = old.count != merged.count
        if !changed {
            for (a, b) in zip(old, merged) where abs(a.start - b.start) > 0.5 || abs(a.end - b.end) > 0.5 {
                changed = true
                break
            }
        }
        if changed { state.transport.bufferedRanges = merged }
    }

    // MARK: - Seek preview harvest (P2)

    /// Main. Grabs the current decoded frame on `eventQueue` (`screenshot-raw`, the heaviest mpv
    /// call in this file), then scales, encodes and stores it on a utility queue.
    private func startHarvest() {
        guard previewStore != nil else { return }
        harvest.noteStarted()
        eventQueue.async { [weak self] in
            guard let self else { return }
            guard self.mpv != nil else {
                // Strong hop to main (critique C13): this block's release is never the last one.
                DispatchQueue.main.async { self.harvestCaptured(nil, at: .nan, tookMs: 0) }
                return
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let sec = self.getDouble("time-pos")
            // P3-F9 hygiene: capture AND scale here, inside one autorelease pool, so only the
            // ~171 KB thumbnail leaves `eventQueue` (no 11 MB frame copy per capture). `took=`
            // now includes the scale (a few ms).
            let capture = autoreleasepool { self.captureHarvestFrame() }
            let tookMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            #if DEBUG
            NSLog("%@", String(format: "[Harvest] took=%.1fms size=%dx%d fmt=%@ at=%.1f src=%@", tookMs,
                               capture?.width ?? 0, capture?.height ?? 0, capture?.format ?? "-", sec,
                               self.harvestSynthetic ? "synthetic" : "mpv"))
            #endif
            // Strong hop to main (critique C13, the `refreshBufferedAsync` shape): `deinit` can
            // never run on `eventQueue`.
            DispatchQueue.main.async { self.harvestCaptured(capture, at: sec, tookMs: tookMs) }
        }
    }

    /// `eventQueue` only. `screenshot-raw video bgr0`; if this mpv rejects the format argument,
    /// retries once without it (the default is `bgr0`) and keeps that form for the session.
    /// Returns the scaled thumbnail (P3-F9 hygiene), never the full frame.
    private func captureHarvestFrame() -> MPVHarvestCapture? {
        if harvestSynthetic {
            #if DEBUG
            let size = harvestSyntheticSize
            #else
            let size = (width: 640, height: 360)
            #endif
            let frame = Self.syntheticHarvestFrame(at: getDouble("time-pos"), width: size.width, height: size.height)
            return MPVHarvestCapture(width: frame.width, height: frame.height, format: frame.format,
                                     thumb: PreviewFrameScaler.makeThumbnail(frame))
        }
        #if targetEnvironment(simulator)
        return nil
        #else
        applyHarvestScreenshotPath()
        // Armed for the length of the native call: if it takes the process down, the next player
        // open finds the flag still set and turns the harvest off (review r1 P2 #3).
        harvestSentinel.arm()
        if !harvestSentinelFlushed {
            harvestSentinelFlushed = true
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        }
        defer { harvestSentinel.clear() }
        if harvestScreenshotSWApplied == true {
            // Software path: a failure here says nothing about the format argument (P4-F3), so
            // `harvestFormatArgWorks` is left alone.
            let frame = screenshotRaw(withFormat: harvestFormatArgWorks != false)
            guard HarvestScreenshotPath.fallsBackToRenderer(onSoftware: true, frame: frame) else { return frame }
            // On the Apple TV (VideoToolbox frames) `screenshot-sw` returns no usable node: move
            // this file to the renderer and take the capture there now, so it is not lost.
            harvestSoftwareFailed = true
            harvestFormatArgWorks = nil
            applyHarvestScreenshotPath()
            print("[Harvest] sw returned no frame → vo for this file")
        }
        return captureHarvestFrameOnRenderer()
        #endif
    }

    /// `eventQueue` only, real captures on the renderer path (`screenshot-sw=no`). Only a failure
    /// here may flip `harvestFormatArgWorks`.
    private func captureHarvestFrameOnRenderer() -> MPVHarvestCapture? {
        if harvestFormatArgWorks != false {
            if let frame = screenshotRaw(withFormat: true) {
                harvestFormatArgWorks = true
                return frame
            }
            guard harvestFormatArgWorks == nil else { return nil }
            harvestFormatArgWorks = false
            #if DEBUG
            NSLog("[Harvest] screenshot-raw video bgr0 failed; retrying without the format argument")
            #endif
        }
        let frame = screenshotRaw(withFormat: false)
        if frame == nil, harvestFormatArgWorks == false {
            // Neither form worked yet: try the format argument again next time.
            harvestFormatArgWorks = nil
        }
        return frame
    }

    /// `eventQueue` only, real captures. P3-F9 fix candidate (i): `screenshot-sw=yes` for SDR
    /// frames, the video renderer's readback otherwise (`HarvestScreenshotPath`). Written only on
    /// change; logged once per change.
    private func applyHarvestScreenshotPath() {
        let gamma = getString("video-params/gamma")
        let matrix = getString("video-params/colormatrix")
        let software = HarvestScreenshotPath.useSoftware(enabled: harvestScreenshotSW && !harvestSoftwareFailed,
                                                         gamma: gamma, colormatrix: matrix)
        guard software != harvestScreenshotSWApplied else { return }
        // mpv's default is `no`: only write it once `yes` has been written.
        if software || harvestScreenshotSWApplied == true { setMpvString("screenshot-sw", software ? "yes" : "no") }
        harvestScreenshotSWApplied = software
        print("[Harvest] path=\(software ? "sw" : "vo") gamma=\(gamma ?? "-") matrix=\(matrix ?? "-") switch=\(harvestScreenshotSW ? "sw" : "vo")\(harvestSoftwareFailed ? " swFailed=1" : "")")
    }

    /// A `bgr0` frame (640 × 360 unless `debug.harvestSyntheticSize`) whose grey level follows
    /// `sec` (DEBUG plumbing tests only).
    private static func syntheticHarvestFrame(at sec: Double, width w: Int = 640, height h: Int = 360) -> MPVRawFrame {
        let stride = w * 4
        let level = UInt8(truncatingIfNeeded: Int(sec.isFinite ? sec : 0) * 4)
        return MPVRawFrame(width: w, height: h, stride: stride, format: "bgr0",
                           bytes: Data(repeating: level, count: stride * h))
    }

    /// Main. The mpv side is done: free the scheduler, then scale + encode + insert on a utility
    /// queue that carries only the frame bytes, the store and the (main-actor) state object.
    private func harvestCaptured(_ capture: MPVHarvestCapture?, at sec: Double, tookMs: Double) {
        if harvest.noteFinished(tookMs: capture == nil ? nil : tookMs) {
            #if DEBUG
            NSLog("%@", String(format: "[Harvest] slow (%.1fms > %.0fms): interval now %.0fs for this file",
                               tookMs, HarvestScheduler.slowHarvestMs, harvest.intervalSec))
            #endif
        }
        guard let capture, sec.isFinite, let store = previewStore else { return }
        // Built on main (the controller is alive here); the utility work holds this closure.
        let publish: @MainActor @Sendable (SeekPreviewInsertResult) -> Void = { [weak self] result in
            guard let self else { return }
            self.applyStoreSnapshot(result.snapshot)
            #if DEBUG
            NSLog("%@", "[Harvest] stored n=\(result.snapshot.count) bytes=\(result.snapshot.bytes) outcome=\(result.outcome.rawValue) rss=\(ProcessMemory.footprintMB())")
            #endif
        }
        guard let thumb = capture.thumb else {
            #if DEBUG
            NSLog("%@", "[Harvest] unsupported frame format \(capture.format)")
            #endif
            return
        }
        // The thumbnail was scaled on `eventQueue`; this queue only encodes (inside the store's
        // insert) and inserts.
        DispatchQueue.global(qos: .utility).async {
            // BUG-181 device pass (2026-10-18): a near-black frame (a film's opening, a fade) is
            // no preview; it was the only frame stored and the fallback showed it as a black card.
            if HarvestFrameFilter.isNearlyBlack(thumb) {
                #if DEBUG
                NSLog("%@", String(format: "[Harvest] skipped dark frame at=%.1f", sec))
                #endif
                return
            }
            Task {
                let result = await store.insert(thumb, at: sec, origin: .harvest)
                await publish(result)
            }
        }
    }

    // MARK: - Seek preview decode (P3)

    /// Main. The one place store state reaches the controller (critique C1): the scheduler's
    /// mirror, the probe's `thumbs=`, and the Info row, for harvest and decode inserts alike.
    private func applyStoreSnapshot(_ snapshot: SeekPreviewSnapshot) {
        // Review r1 P2 #4: an older snapshot landing after a newer one would drop a stamp from the
        // mirror (the scheduler would re-decode that slot); keep the newest only.
        guard snapshot.supersedes(storeMirror) else { return }
        storeMirror = snapshot
        state.transport.previewFrames = snapshot.count
        rebuildPreviewSummary()
    }

    /// The Info tab's "Seek Previews" row (one builder, critique C26).
    private func rebuildPreviewSummary() {
        let snap = storeMirror
        var parts: [String] = []
        if snap.count == 0, harvestCrashOff {
            parts.append(String(localized: "Off after a crash in an earlier playback"))
        } else if snap.count > 0 {
            parts.append("\(snap.count) · \(String(format: "%.1f", Double(snap.bytes) / 1_048_576)) MB")
        }
        if seekPreviewMode.allowsDecode {
            if let ms = thumbLastDecodeMs {
                parts.append(String(format: String(localized: "last decode %ld ms"), Int(ms.rounded())))
            }
            if thumbBytesCharged > 0 {
                // r2 P3 #3: the budget's charge (an upper bound on the wire), not what a proxy counts.
                parts.append(String(format: String(localized: "%@ MB used"),
                                    String(format: "%.1f", Double(thumbBytesCharged) / 1_048_576)))
            }
            if let reason = thumbs.stopped ?? thumbs.prewarmStopped, let words = Self.thumbStopWords(reason) {
                parts.append(String(format: String(localized: "decode off: %@"), words))
            }
        }
        #if DEBUG
        // Debug builds keep the row in Off mode (and before the first harvest) so the RSS stays
        // readable; release builds hide an empty row as before.
        if parts.isEmpty { parts.append(seekPreviewMode.allowsHarvest ? "—" : String(localized: "off")) }
        #else
        guard !parts.isEmpty else { return }
        #endif
        var text = parts.joined(separator: " · ")
        #if DEBUG
        // Jargon: debug builds only (review r1 P3 #9).
        text += " · RSS \(ProcessMemory.footprintMB()) MB · h \(snap.harvest) / d \(snap.decode)"
        #endif
        state.previewStoreSummary = text
    }

    /// Plain words for the Info row; nil for reasons the viewer does not need to see.
    private static func thumbStopWords(_ reason: ThumbStopReason) -> String? {
        switch reason {
        case .noIndex: return String(localized: "no seek index")
        case .httpRefused: return String(localized: "the server refused")
        case .byteBudget: return String(localized: "budget used")
        case .storeFull, .frameCap: return String(localized: "store full")
        case .dvProfile5: return String(localized: "Dolby Vision profile 5")
        case .container, .openFailed, .stalled: return String(localized: "not supported for this file")
        case .modeOff: return nil
        }
    }

    /// Main. Opens the thumbnailer when the scheduler asks, starts the next job, and frees the
    /// decoder when a pre-warm pass ends. Called every UI tick, after each finished job (passes run
    /// back to back), after the open, and 50 ms after a scrub miss.
    private func driveThumbs() {
        guard seekPreviewMode.allowsDecode, mpv != nil, fileLoaded, previewStore != nil else { return }
        let inputs = thumbInputs()
        if thumbs.shouldOpen(inputs) { openThumbnailer() }
        if let job = thumbs.next(inputs) {
            startThumbJob(job)
        } else if thumbs.inFlight == nil, thumbs.takePassEnded() {       // r1 P3 #5: in flight first
            thumbnailer?.releaseDecoder()
        }
        if thumbs.stopped != nil, thumbnailer != nil {
            closeThumbnailer()
        } else if let t = thumbnailer, thumbOpened, thumbReleaseWork == nil,
                  thumbs.idleCloseWanted(now: inputs.now, scrubbing: isScrubbing,
                                         requestLeftOpen: t.lastRequestLeftOpen) {
            // Review r1 P1, r2 P2 #1: the pre-warm stopped and nothing is pending: drop the
            // connection now if the host may still be sending, else after a minute with no scrub.
            #if DEBUG
            NSLog("%@", String(format: "[Thumbs] idle close reason=%@ leftOpen=%ld charged=%.1fMB",
                               thumbs.prewarmStopped?.rawValue ?? "-", t.lastRequestLeftOpen ? 1 : 0,
                               Double(thumbBytesCharged) / 1_048_576))
            #endif
            closeThumbnailer()
            thumbs.noteIdleClosed()
        }
    }

    /// BUG-180 (Steven rc7): the transport bar or the top panel is on screen. Seek-preview harvest
    /// and decode pre-warm wait while it is (both compete with the overlay over a 4K/HDR frame);
    /// a scrub's own decode is not gated. `presentedViewController` covers a stale `panelOpen`.
    private var playerOverlayUp: Bool {
        state.controlsVisible || state.panelOpen || presentedViewController != nil
    }

    /// What the byte budget has charged across every thumbnailer of this file (review r1 P1).
    private var thumbBytesCharged: Int64 { thumbBytesClosed + (thumbnailer?.bytesCharged ?? 0) }

    private func thumbInputs() -> ThumbScheduler.Inputs {
        let snap = cachedProps()
        let now = ProcessInfo.processInfo.systemUptime
        let position = max(snap.position, 0)
        return ThumbScheduler.Inputs(
            now: now, positionSec: position, durationSec: snap.duration, paused: snap.paused,
            cacheWait: snap.cacheWait, cacheSec: cacheHealthSec, cacheTrendSec: cacheTrend.trendSec(now: now),
            cacheReachesEnd: cacheHealthEofCached
                || ThumbScheduler.cacheReachesEnd(positionSec: position, cacheSec: cacheHealthSec, durationSec: snap.duration),
            cacheFill: cacheHealthFill, seekInFlight: skipPlanner.seekInFlight != nil, scrubbing: isScrubbing,
            recentInput: now - lastClickUptime < HarvestScheduler.recentInputSec, harvestInFlight: harvest.inFlight,
            store: storeMirror, bytesRead: thumbBytesCharged, byteBudget: thumbByteBudget,
            scrubCeiling: ThumbScheduler.scrubCeiling(budget: thumbByteBudget), opened: thumbOpened,
            overlayUp: playerOverlayUp)
    }

    /// A scrub lookup missed (or landed more than 5 s off): ask for the keyframe at `target`
    /// after the 50 ms debounce, and start the open now if this is the first ask.
    private func noteThumbScrubMiss(target: Double) {
        guard seekPreviewMode.allowsDecode else { return }
        thumbs.noteScrubMiss(target: target, now: ProcessInfo.processInfo.systemUptime)
        driveThumbs()
        thumbScrubWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.thumbScrubWork = nil
            self.driveThumbs()
        }
        thumbScrubWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ThumbScheduler.Config().scrubDebounceSec + 0.005, execute: work)
    }

    /// Same URL and headers mpv uses (`context.requestHeaders`, sanitized): the thumbnailer talks
    /// to the media host itself, so the credentials go too (spec §5, not the `subAdd` path).
    private func openThumbnailer() {
        guard thumbnailer == nil, let scheme = context.url.scheme?.lowercased() else { return }
        // r1 P3 #7: a playlist (HLS, DASH) is refused before avformat fetches it and probes a
        // segment; anything else still goes through the open's container check.
        let ext = context.url.pathExtension.lowercased()
        guard ["http", "https", "file"].contains(scheme), !["m3u8", "m3u", "mpd"].contains(ext) else {
            thumbs.stop(.container)
            rebuildPreviewSummary()
            return
        }
        let t = KeyframeThumbnailer(url: context.url, headers: context.requestHeaders, knownFacts: thumbFacts)
        thumbnailer = t
        Task { @MainActor [weak self] in
            let result = await t.open()
            guard let self, self.thumbnailer === t else { return }
            switch result {
            case .ready(let facts):
                self.thumbOpened = true
                guard self.thumbFacts == nil else {             // a reopen: budget and index are set
                    self.driveThumbs()
                    return
                }
                self.thumbFacts = facts
                self.thumbByteBudget = ThumbScheduler.byteBudget(fileSize: facts.sizeBytes)
                #if DEBUG
                let overrideMB = UserDefaults.standard.integer(forKey: "debug.thumbBudgetMB")
                if overrideMB > 0 { self.thumbByteBudget = Int64(overrideMB) * ThumbScheduler.mib }
                #endif
                self.thumbs.setKeyframeIndex(facts.keyframeIndex)
                if let store = self.previewStore {
                    let gap = ThumbScheduler.medianGap(facts.keyframeIndex)
                    Task { @MainActor [weak self] in
                        let snapshot = await store.setKeyframeSpacing(gap)
                        self?.applyStoreSnapshot(snapshot)
                    }
                }
                self.rebuildPreviewSummary()
                self.driveThumbs()          // a pending scrub runs now, not at the next tick (C14)
            case .refused(let reason):
                self.thumbs.stop(reason)
                self.closeThumbnailer()
                self.rebuildPreviewSummary()
            }
        }
    }

    private func closeThumbnailer() {
        thumbReleaseWork?.cancel(); thumbReleaseWork = nil
        if let t = thumbnailer { thumbBytesClosed += t.bytesCharged }
        thumbnailer?.close()
        thumbnailer = nil
        thumbOpened = false
    }

    private func startThumbJob(_ job: ThumbScheduler.Job) {
        guard let t = thumbnailer, let store = previewStore else { return }
        thumbs.noteStarted(job, now: ProcessInfo.processInfo.systemUptime)
        if job.isScrub { thumbReleaseWork?.cancel(); thumbReleaseWork = nil }
        Task { @MainActor [weak self] in
            let result = await t.frame(at: job.sec, urgent: job.isScrub)
            guard let self, self.thumbnailer === t else { return }    // a closed thumbnailer's late result
            var outcome = ThumbScheduler.Outcome.failed
            switch result {
            case .frame(let image, let kf, let took, let dec, let tm, let bytes):
                let inserted = await store.insert(image, at: kf, origin: .decode)
                guard self.thumbnailer === t else { return }
                self.applyStoreSnapshot(inserted.snapshot)
                outcome = ThumbScheduler.Outcome(insert: inserted.outcome, keyframeSec: kf)
                self.thumbLastDecodeMs = took
                #if DEBUG
                NSLog("%@", String(format: "[Thumbs] decode at=%.1f kf=%.1f took=%.0fms dec=%.0fms tm=%.1fms charged=%lldKB job=%@ outcome=%@",
                                   job.sec, kf, took, dec, tm, bytes / 1024, job.name, inserted.outcome.rawValue))
                #endif
                // The viewer is still scrubbing near this keyframe: refresh the card.
                if job.isScrub, case .scrubbing(let target) = self.transport.mode,
                   abs(target - kf) <= inserted.snapshot.tolerance {
                    self.requestPreviewFrame()
                }
            case .failed(let reason):
                if let reason { self.thumbs.stop(reason) }
                #if DEBUG
                NSLog("%@", "[Thumbs] decode at=\(String(format: "%.1f", job.sec)) failed job=\(job.name) stop=\(reason?.rawValue ?? "-")")
                #endif
            case .aborted:
                outcome = .aborted
            }
            self.thumbs.noteFinished(job, result: outcome, now: ProcessInfo.processInfo.systemUptime)
            self.state.transport.decodedFrames = self.thumbs.decoded
            #if DEBUG
            if let reason = self.thumbs.stopped ?? self.thumbs.prewarmStopped, !self.loggedThumbStop {
                self.loggedThumbStop = true
                NSLog("%@", String(format: "[Thumbs] stop reason=%@ decoded=%ld read=%.1fMB charged=%.1fMB", reason.rawValue,
                                   self.thumbs.decoded, Double(t.bytesRead) / 1_048_576,
                                   Double(self.thumbBytesCharged) / 1_048_576))
            }
            #endif
            self.rebuildPreviewSummary()
            if job.isScrub { self.scheduleThumbRelease() }
            self.driveThumbs()
        }
    }

    /// Frees a 4K decoder's frame pools 2 s after the last scrub job (pre-warm passes release
    /// theirs when they end, `driveThumbs`).
    private func scheduleThumbRelease() {
        thumbReleaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.thumbReleaseWork = nil
            if self.thumbs.inFlight == nil { self.thumbnailer?.releaseDecoder() }
            self.driveThumbs()                  // r1 P1: an idle close waits for this release
        }
        thumbReleaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// One coalesced cache-health read on `eventQueue` every 2 s in decode mode (critique C2,
    /// C15): `demuxer-cache-state`'s `fw-bytes` / `eof-cached` and `demuxer-cache-duration`. Both
    /// paths end with a strong hop to main (`deinit` can never run on `eventQueue`).
    private func refreshCacheHealthAsync() {
        guard !cacheHealthReadPending, fileLoaded else { return }
        cacheHealthReadPending = true
        lastCacheHealthRead = ProcessInfo.processInfo.systemUptime
        eventQueue.async { [weak self] in
            guard let self else { return }
            guard self.mpv != nil else {
                DispatchQueue.main.async { self.cacheHealthReadPending = false }
                return
            }
            let raw = self.getString("demuxer-cache-state")
            let cacheSec = self.getDouble("demuxer-cache-duration")
            var fwBytes: Int64 = 0
            var eofCached = false
            if let raw, let data = raw.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                fwBytes = (obj["fw-bytes"] as? NSNumber)?.int64Value ?? 0
                eofCached = (obj["eof-cached"] as? Bool) ?? false
            }
            DispatchQueue.main.async {
                self.cacheHealthReadPending = false
                self.applyCacheHealth(sec: cacheSec, forwardBytes: fwBytes, eofCached: eofCached)
            }
        }
    }

    private func applyCacheHealth(sec: Double, forwardBytes: Int64, eofCached: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        cacheHealthSec = sec.isFinite ? max(sec, 0) : 0
        cacheHealthFill = ThumbScheduler.cacheFill(forwardBytes: forwardBytes, maxBytes: demuxerMaxBytes)
        cacheHealthEofCached = eofCached
        cacheTrend.record(now: now, cacheSec: cacheHealthSec)
    }

    #if DEBUG
    private func updateSeekProbe(paused: Bool? = nil) {
        state.seekProbe.modeName = transport.mode.probeName
        state.seekProbe.pos = state.positionSec
        if let paused { state.seekProbe.paused = paused }
    }
    #endif

    // MARK: - Siri-remote transport

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        lastClickUptime = ProcessInfo.processInfo.systemUptime
        for press in presses { pressesDown.insert(ObjectIdentifier(press)) }
        scrubArbiter.pressBegan()
        // A press brings an auto-hidden skip chip back for another 10 s (the press still acts,
        // except a Down that revealed the chip: that one only reveals it, the next Down skips).
        // Left/Right seek: the chip comes back on the tick after the seek lands, not now (an
        // immediate publish would flash it for one tick while the seek is in flight).
        let chipRevealed = skipPlanner.noteInput(now: ProcessInfo.processInfo.systemUptime)
        let arrowSeekPress = presses.contains { $0.type == .leftArrow || $0.type == .rightArrow }
        if chipRevealed && !arrowSeekPress {
            let snap = cachedProps()
            updateSkipPrompt(position: snap.position, duration: snap.duration, paused: snap.paused)
        }
        for press in presses {
            // A new press between a commit's two stages cancels the exact stage; the new gesture
            // starts from the keyframes landing.
            switch press.type {
            case .playPause, .select, .leftArrow, .rightArrow, .upArrow, .downArrow, .menu:
                cancelExactStage()
            default:
                break
            }
            switch press.type {
            case .playPause, .select:
                if isScrubbing {
                    // Commit the scrub (two-stage unless cached); Play also resumes a paused file.
                    commitScrub()
                    if press.type == .playPause, cachedProps().paused { togglePause() }
                    flashControls()
                } else if case .scanning = transport.mode {
                    // Ends the scan where it is; playback continues at the user's speed.
                    apply(transport.endScanInPlace())
                } else {
                    if case .stepping = transport.mode { stopHoldTimer(); apply(transport.cancel()) }
                    if press.type == .select, let pill = state.transport.focusedPill {
                        activatePill(pill)
                    } else {
                        togglePause(); flashControls()
                    }
                }
                handled = true
            case .leftArrow:
                if isScrubbing {
                    nudgeScrub(-1)              // ±10 s on the preview; never a hold, never a seek
                } else if case .scanning = transport.mode {
                    apply(transport.endScanInPlace())
                } else if state.transport.focusedPill != nil {
                    movePill(by: -1)        // a focused pill row never seeks
                } else {
                    beginHold(-1)
                }
                handled = true
            case .rightArrow:
                if isScrubbing {
                    nudgeScrub(1)
                } else if case .scanning = transport.mode {
                    apply(transport.pressBegan(direction: 1, positionSec: 0))   // next rate
                } else if state.transport.focusedPill != nil {
                    movePill(by: 1)
                } else {
                    beginHold(1)
                }
                handled = true
            case .upArrow:
                switch transport.mode {
                case .scrubbing:
                    cancelScrub(why: "up"); handled = true      // the idle edge keeps the bar up
                case .scanning:
                    apply(transport.endScanInPlace()); handled = true
                case .stepping:
                    stopHoldTimer(); apply(transport.cancel()); handled = true
                default:
                    // Hidden bar: raise it (focus on the track). Bar up: focus the first pill; with
                    // a pill already focused Up does nothing but keep the bar up.
                    if state.controlsVisible, state.transport.focusedPill == nil {
                        state.transport.focusedPill = state.transport.pills.first
                    }
                    flashControls()
                    handled = true
                }
            case .downArrow:
                var consumed = chipRevealed
                switch transport.mode {
                case .scrubbing:
                    // Cancel, then the panel: no chip, no up-next, no pill.
                    cancelScrub(why: "down")
                    if presentedViewController == nil {
                        refreshTracksAsync()
                        onOpenPanel?(.info)
                    }
                    consumed = true
                case .scanning:
                    apply(transport.endScanInPlace()); consumed = true   // no chip, no panel
                case .stepping:
                    stopHoldTimer(); apply(transport.cancel())
                default:
                    break
                }
                if consumed {
                    handled = true
                } else if state.transport.focusedPill != nil {
                    // Back to the track; the next Down fires the chip or opens the panel.
                    state.transport.focusedPill = nil
                    flashControls()
                    handled = true
                } else if state.upNextPlayNow?() == true {
                    handled = true
                } else if let prompt = state.skipPrompt {
                    // Already clamped against duration by `SkipSegmentPlanner` (a target past EOF
                    // wedges mpv; unclamped while the duration is still unknown). The planner
                    // shows no chip until mpv confirms this seek, so a second press can't re-seek.
                    seekAbsolute(prompt.targetSec, kind: .chip)
                    state.skipPrompt = nil
                    flashControls()
                    handled = true
                } else if presentedViewController == nil {
                    // Same gesture as the native player: Down opens the top panel. Track lists
                    // are refreshed on open (the async walk fills them if this raced the events).
                    refreshTracksAsync()
                    onOpenPanel?(.info)
                    handled = true
                }
            case .menu:
                let action = MenuPrecedence.resolve(
                    // A presented panel takes its own presses; `state.panelOpen` could go stale.
                    panelOpen: presentedViewController != nil,
                    modeActive: transport.mode.isActive,
                    upNextShowing: state.upNextVisible?() ?? false,
                    pillFocused: state.transport.focusedPill != nil,
                    barUp: state.controlsVisible)
                NSLog("[MenuProbe] menu began action=%@ leaving=%d window=%d", String(describing: action),
                      isLeavingPlayer ? 1 : 0, view.window == nil ? 0 : 1)
                switch action {
                case .panel:
                    break           // the panel host closes itself; never reaches here in practice
                case .exit:
                    // BUG-165: arm the window shield BEFORE the cover starts going away, so this
                    // press's release and any Menu that lands during the dismissal are claimed
                    // instead of running up a chain that ends in "leave the app". Disarmed by
                    // `MPVPlayerScreen.onDisappear` once the cover is gone.
                    exitDecidedAt = ProcessInfo.processInfo.systemUptime
                    MenuExitShield.shared.arm(reason: "mpv-exit")
                    #if DEBUG
                    dumpMenuResponderChain(tag: "exit")
                    #endif
                    closeFailover()
                    onExit?()
                case .cancelMode, .dismissUpNext, .hidePill, .hideBar:
                    // Consumed, but PERFORMED ON RELEASE (`pressesEnded`). Acting here changed the
                    // view tree while the press was still down (the bar leaving, the chip leaving),
                    // and the system then treated the half-finished Menu as unhandled and dismissed
                    // the cover (P1 device pass 2026-10-06, steps 4 + 9; the simulator shows the
                    // same `pressesCancelled` → cover gone). Nothing moves until the key is up.
                    pendingMenuAction = action
                }
                if MenuPrecedence.swallowsRelease(action) { swallowMenuRelease = true }
                if action != .panel { handled = true }
            default:
                break
            }
        }
        if handled {
            // Any remote interaction proves someone's watching — reset the Still Watching counter.
            NextEpisodeEngine.consecutiveAutoPlays = 0
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        // The light tap recognises at touch-up: the release restarts the click window.
        lastClickUptime = ProcessInfo.processInfo.systemUptime
        for press in presses { pressesDown.remove(ObjectIdentifier(press)) }
        if presses.contains(where: { $0.type == .menu }) {
            NSLog("[MenuProbe] menu ended swallow=%d sinceExit=%dms window=%d", swallowMenuRelease ? 1 : 0,
                  sinceExitMs(), view.window == nil ? 0 : 1)
        }
        if swallowMenuRelease, presses.contains(where: { $0.type == .menu }) {
            swallowMenuRelease = false
            handled = true
            if let action = pendingMenuAction {
                pendingMenuAction = nil
                performMenuAction(action)
            }
        }
        for press in presses where press.type == .leftArrow || press.type == .rightArrow {
            let direction = press.type == .leftArrow ? -1 : 1
            // The release of a key the user already replaced (other key pressed mid-hold) must not
            // stop the hold of the key still down.
            if case .stepping(let current, _, _) = transport.mode, current != direction {
                handled = true
                continue
            }
            stopHoldTimer()
            apply(transport.pressEnded(direction: direction))
            handled = true
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    /// A press cancelled mid-hold (Home / TV button, Siri, a recogniser claiming it) never ends:
    /// a held arrow stops its timer and drops the preview without committing, and a Menu whose
    /// begin was consumed is swallowed here too (UIKit would otherwise act on the half press).
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        lastClickUptime = ProcessInfo.processInfo.systemUptime
        for press in presses { pressesDown.remove(ObjectIdentifier(press)) }
        if presses.contains(where: { $0.type == .menu }) {
            NSLog("[MenuProbe] menu cancelled swallow=%d sinceExit=%dms window=%d", swallowMenuRelease ? 1 : 0,
                  sinceExitMs(), view.window == nil ? 0 : 1)
        }
        if swallowMenuRelease, presses.contains(where: { $0.type == .menu }) {
            swallowMenuRelease = false
            handled = true
            pendingMenuAction = nil     // a cancelled Menu performs nothing
            #if DEBUG
            dumpMenuResponderChain(tag: "pressesCancelled(menu)")
            #endif
        }
        for press in presses where press.type == .leftArrow || press.type == .rightArrow {
            let direction = press.type == .leftArrow ? -1 : 1
            // A latched scan outlives its press (it needs no hold timer); a stepping hold of this
            // key is dropped without committing. The hold of the other key, if one replaced this
            // press, keeps its timer.
            if case .stepping(let current, _, _) = transport.mode {
                if current == direction {
                    stopHoldTimer()
                    apply(transport.cancel())
                }
            } else {
                stopHoldTimer()
            }
            handled = true
        }
        if !handled { super.pressesCancelled(presses, with: event) }
    }

    // MARK: - Chapters and aspect (P2-C)

    /// `eventQueue` (from `drainEvents`' FILE_LOADED): mpv's `chapter-list` as JSON through the
    /// string path (the one `demuxer-cache-state` proved), else the indexed sub-properties; then
    /// published on main.
    private func readChapters() {
        guard mpv != nil else { return }
        let raw = getString("chapter-list")
        var chapters = raw.map { PlayerChapters.parse(json: $0) } ?? []
        var source = "json"
        if chapters.isEmpty {
            let n = getInt("chapters")
            if n > 0 {
                chapters = PlayerChapters.parseIndexed(count: n,
                                                       title: { self.getString("chapter-list/\($0)/title") },
                                                       time: { self.getDouble("chapter-list/\($0)/time") })
                source = "indexed"
            }
        }
        // A marker at or past the end would make a chapter click seek to EOF (review r1 P2 #2).
        // The untrimmed list is kept so a growing duration can bring late chapters back (r2 P3 #5).
        let duration = getDouble("duration")
        let rawList = chapters
        chapters = PlayerChapters.trimmed(chapters, durationSec: duration)
        #if DEBUG
        NSLog("[Chapters] n=%ld dropped=%ld dur=%.1f src=%@ raw=%@", chapters.count, rawList.count - chapters.count,
              duration, source, String((raw ?? "nil").prefix(200)))
        #endif
        DispatchQueue.main.async {
            self.rawChapters = rawList
            self.chaptersTrimDuration = duration
            self.state.transport.chapters = chapters
        }
    }

    /// Main: publish the mode, then write all three mpv properties on `eventQueue`.
    private func applyAspect(_ mode: PlayerAspectMode) {
        state.transport.aspectMode = mode
        let p = mode.mpvProps
        eventQueue.async { [weak self] in
            guard let self else { return }
            if self.mpv != nil {
                self.setMpvString("video-aspect-override", p.aspectOverride)
                self.setMpvDouble("panscan", p.panscan)
                self.setMpvDouble("video-zoom", p.videoZoom)
            }
            #if DEBUG
            let read = self.mpv != nil ? (self.getString("video-aspect-override") ?? "nil") : "nil"
            #endif
            // Strong hop to main (critique C13, review r1 P3 #5): this block's release is never
            // the last one, so `deinit` cannot run on `eventQueue`.
            DispatchQueue.main.async {
                _ = self
                #if DEBUG
                NSLog("[Aspect] %@ override=%@ panscan=%.2f zoom=%.2f read=%@", mode.rawValue, p.aspectOverride,
                      p.panscan, p.videoZoom, read)
                #endif
            }
        }
    }

    /// The Aspect pill: next mode and flash its name for 2 s. The synced resize mode (the phone
    /// follows, C23) is written once, when the flash clears or the player closes: Fit/Fill/Zoom
    /// write themselves, Stretch (session-only, C9) puts the session-start value back, and a mode
    /// only cycled through is never stored (review r1 P2 #1, r2 P2 #1).
    private func cycleAspect() {
        let mode = state.transport.aspectMode.next
        applyAspect(mode)
        aspectPillDirty = true
        state.transport.aspectFlash = mode.label
        aspectFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.transport.aspectFlash = nil
            self.persistAspectIfNeeded()
        }
        aspectFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + aspectFlashSec, execute: work)
    }

    /// Main. Writes the resting Aspect mode to the synced resize mode when the pill moved and the
    /// result differs from what the profile holds (`AspectWriteback`).
    private func persistAspectIfNeeded() {
        guard aspectPillDirty else { return }
        aspectPillDirty = false
        let resting = state.transport.aspectMode
        guard let mode = aspectWriteback.valueToPersist(resting: resting) else {
            #if DEBUG
            NSLog("[Aspect] persist none resting=%@ stored=%@ start=%@", resting.rawValue,
                  aspectWriteback.stored.rawValue, aspectWriteback.sessionStart.rawValue)
            #endif
            return
        }
        let synced: PlayerResizeMode
        switch mode {
        case .fit, .stretch: synced = .fit
        case .fill: synced = .fill
        case .zoom: synced = .zoom
        }
        aspectWriteback.didPersist(mode)
        PlayerSettingsRepository.shared.setResizeMode(mode: synced)
        #if DEBUG
        state.transport.debugAspectWrites += 1
        NSLog("[Aspect] persist %@ resting=%@", mode.rawValue, resting.rawValue)
        #endif
    }

    // MARK: - Hold / preview / commit (P1)

    /// Start a Left/Right gesture in `dir` (±1). The first press is a plain ±10 s seek (Step mode);
    /// holding moves only the preview, and one commit seeks on release (`TransportPreview`).
    private func beginHold(_ dir: Double) {
        // Seeking backward means the user is still watching — abandon next-episode autoplay.
        // Once per hold (idle → hold), never per tick or per direction change.
        if dir < 0, case .idle = transport.mode { state.upNextCancel?() }
        let base = skipPlanner.seekInFlight?.targetSec ?? cachedProps().position   // seekBy's rule
        holdStartUptime = ProcessInfo.processInfo.systemUptime
        transport.paused = cachedProps().paused        // a paused hold steps, never scans
        // Chapter mode (C8): the click acts on release, so a hold steps from the origin, no jump first.
        transport.clickOnRelease = edgeClickMode == .chapter && state.transport.chapters.count >= 2
        apply(transport.pressBegan(direction: Int(dir), positionSec: base))
        restartHoldTimer()
        flashControls()
    }

    private func restartHoldTimer() {
        holdTimer?.invalidate()
        let first = Timer(timeInterval: TransportPreview.holdStartSec, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.tick()
            let repeating = Timer(timeInterval: self.holdTickSec, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(repeating, forMode: .common)
            self.holdTimer = repeating
        }
        RunLoop.main.add(first, forMode: .common)
        holdTimer = first
    }

    private func tick() {
        apply(transport.holdTick(heldSec: ProcessInfo.processInfo.systemUptime - holdStartUptime))
        flashControls()
    }

    private func stopHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    /// Main thread: perform what the preview model asked for, then publish its state.
    private func apply(_ output: TransportPreview.Output) {
        switch output {
        case .none: break
        case .immediateSeek(let d): edgeClick(d)
        case .commit(let r): issueCommit(r)
        case .startScan(let rate): startScan(rate)
        case .setScanRate(let r):
            #if DEBUG
            state.seekProbe.speed = Double(r)
            #endif
            eventQueue.async { [weak self] in self?.setMpvDouble("speed", Double(r)) }
        case .endScan(let from, let returnTo): endScan(from: from, returnTo: returnTo)
        case .cancelUpNext: state.upNextCancel?()
        }
        publishTransport()
    }

    private func publishTransport() {
        state.transport.previewSec = transport.previewSec
        state.transport.mode = transport.mode
        let active = transport.mode.isActive
        let wasActive = lastPublishedModeActive
        lastPublishedModeActive = active
        let scrubbing = isScrubbing
        if scrubbing != lastPublishedScrubbing {
            lastPublishedScrubbing = scrubbing
            if scrubbing {
                state.scrubCardUp = true
            } else {
                // Every way out of a scrub (commit, cancel, Menu, idle timeout, panel) cleans up here.
                scrubIdleWork?.cancel(); scrubIdleWork = nil
                scrubPublishWork?.cancel(); scrubPublishWork = nil
                previewFrameWork?.cancel(); previewFrameWork = nil
                previewFrameThrottle.reset()
                previewFrameToken += 1
                state.transport.previewFrame = nil
                state.transport.previewFrameSec = nil
                thumbScrubWork?.cancel(); thumbScrubWork = nil
                thumbs.noteScrubEnded(now: ProcessInfo.processInfo.systemUptime)
                scrubArbiter.abandon()
                #if DEBUG
                state.transport.debugArbiter = scrubArbiter.probeCode
                #endif
                state.scrubCardUp = false
            }
        }
        #if DEBUG
        updateSeekProbe()
        #endif
        if wasActive && !active { flashControls() }
    }

    // MARK: - Swipe scrub (P2)

    private var isScrubbing: Bool {
        if case .scrubbing = transport.mode { return true }
        return false
    }

    private func scrubContext() -> ScrubContext {
        let snap = cachedProps()
        return ScrubContext(
            barVisible: state.controlsVisible,
            paused: snap.paused,
            pillFocused: state.transport.focusedPill != nil,
            scrubbing: isScrubbing,
            canScrub: fileLoaded && snap.duration > 0 && presentedViewController == nil && !state.isEnded,
            pressesDown: pressesDown.count,
            lastPressUptime: lastClickUptime)
    }

    @objc private func handleScrubPan(_ gr: UIPanGestureRecognizer) {
        let t = gr.translation(in: view)
        let now = ProcessInfo.processInfo.systemUptime
        switch gr.state {
        case .began:
            scrubArbiter.touchBegan()
            routeScrub(scrubArbiter.moved(tx: t.x, ty: t.y, now: now, context: scrubContext()))
        case .changed:
            routeScrub(scrubArbiter.moved(tx: t.x, ty: t.y, now: now, context: scrubContext()))
        case .ended, .cancelled, .failed:
            #if DEBUG
            NSLog("[Scrub] stroke end intent=%@ travel=%.0f vx=%.0f", scrubArbiter.probeCode,
                  scrubArbiter.travel, gr.velocity(in: view).x)
            #endif
            routeScrub(scrubArbiter.touchEnded(context: scrubContext()))
        default:
            break
        }
        #if DEBUG
        state.transport.debugArbiter = scrubArbiter.probeCode
        #endif
    }

    private func routeScrub(_ event: ScrubGestureArbiter.Event) {
        switch event {
        case .none:
            break
        case .beginScrub:
            switch transport.mode {
            case .scanning:
                apply(transport.endScanInPlace())
            case .stepping:
                stopHoldTimer()
                apply(transport.cancel())
            case .idle, .scrubbing:
                break
            }
            // A new stroke while already scrubbing just keeps moving the same preview.
            guard case .idle = transport.mode else { restartScrubIdle(); return }
            cancelExactStage()
            state.transport.focusedPill = nil
            let base = skipPlanner.seekInFlight?.targetSec ?? cachedProps().position   // beginHold's rule
            #if DEBUG
            NSLog("[Scrub] begin base=%.2f thr=%.0f curve=%@", base,
                  ScrubGestureArbiter.horizontalThreshold(scrubContext()), scrubCurve.rawValue)
            #endif
            apply(transport.scrubBegan(positionSec: base))
            flashControls()
            restartScrubIdle()
            requestPreviewFrame()
        case .scrubDelta(let points):
            performScrubOutput(transport.scrubMoved(deltaPoints: points))
        case .openPanel:
            cancelScrub(why: "panel")
            openPanelFromGesture()
        case .swipeUp:
            if isScrubbing {
                cancelScrub(why: "up")
            } else if !state.controlsVisible {
                flashControls()
            }
        case .lightTap:
            if !isScrubbing { performLightTap(force: false) }
        }
    }

    /// The throttled sibling of `apply` for scrub samples: the bar publishes at most 30 times a
    /// second, and a trailing publish makes sure the last sample always lands.
    private func performScrubOutput(_ out: TransportPreview.Output) {
        if out == .cancelUpNext { state.upNextCancel?() }
        let now = ProcessInfo.processInfo.systemUptime
        let interval: TimeInterval = 1.0 / 30
        let since = now - lastScrubPublishUptime
        if since >= interval {
            scrubPublishWork?.cancel(); scrubPublishWork = nil
            lastScrubPublishUptime = now
            publishTransport()
        } else if scrubPublishWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.scrubPublishWork = nil
                self.lastScrubPublishUptime = ProcessInfo.processInfo.systemUptime
                self.publishTransport()
            }
            scrubPublishWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (interval - since), execute: work)
        }
        requestPreviewFrame()
        restartScrubIdle()
    }

    private func nudgeScrub(_ direction: Int) {
        restartScrubIdle()
        apply(transport.scrubNudge(direction: direction))
        requestPreviewFrame()
        flashControls()
    }

    private func commitScrub() {
        let out = transport.scrubCommit()
        if case .commit(let r) = out {
            #if DEBUG
            state.seekProbe.scrubs += 1
            NSLog("[Scrub] commit target=%.2f from=%.2f stages=%@", r.targetSec, r.fromSec,
                  r.stages.map { $0 == .keyframes ? "k" : "e" }.joined())
            #endif
            _ = r
        }
        apply(out)
    }

    private func cancelScrub(why: String) {
        guard isScrubbing else { return }
        #if DEBUG
        NSLog("[Scrub] cancel why=%@", why)
        #endif
        apply(transport.scrubCancel())
    }

    /// Playing: a scrub with no input for 8 s is cancelled (no seek), so a stray swipe cannot pin
    /// the bar up. Paused: no timeout.
    private func restartScrubIdle() {
        scrubIdleWork?.cancel()
        scrubIdleWork = nil
        guard isScrubbing, !cachedProps().paused else { return }
        let work = DispatchWorkItem { [weak self] in self?.cancelScrub(why: "idle") }
        scrubIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportPreview.scrubIdleCancelSec, execute: work)
    }

    /// Ask for a frame near the scrub target, throttled (critique C17): at most one lookup in
    /// flight, a new one at most every 66 ms, and always a trailing one after the last sample.
    private func requestPreviewFrame() {
        handlePreviewFrameDecision(previewFrameThrottle.sample(now: ProcessInfo.processInfo.systemUptime))
    }

    private func handlePreviewFrameDecision(_ decision: PreviewFrameThrottle.Decision) {
        switch decision {
        case .none:
            break
        case .wait(let seconds):
            guard previewFrameWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.previewFrameWork = nil
                self.handlePreviewFrameDecision(
                    self.previewFrameThrottle.timerFired(now: ProcessInfo.processInfo.systemUptime))
            }
            previewFrameWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        case .start:
            guard case .scrubbing(let target) = transport.mode else {
                previewFrameThrottle.reset()
                return
            }
            guard let source = seekPreviewSource else {
                // No store: the card shows time only. Nothing runs, so the lookup is done at once.
                state.transport.previewFrame = nil
                _ = previewFrameThrottle.finished(now: ProcessInfo.processInfo.systemUptime)
                return
            }
            let token = previewFrameToken
            Task { @MainActor [weak self] in
                let match = await source.match(near: target)
                // BUG-181 (Steven rc7): a miss shows the nearest stored frame within two minutes
                // (DV P5 never decodes, so its store holds only harvested frames). The previous
                // frame stays only while a lookup runs; a finished lookup with nothing near clears
                // it, so the dark placeholder card shows (device pass 2026-10-18: scrubbing far
                // ahead kept showing the last real thumbnail).
                let shown: SeekPreviewMatch?
                if let match { shown = match } else { shown = await source.nearest(to: target) }
                // A scrub that ended (or a newer one) bumped the token: drop the late frame, and
                // do not touch the reset throttle.
                guard let self, self.previewFrameToken == token else { return }
                self.state.transport.previewFrame = shown?.image
                self.state.transport.previewFrameSec = shown?.sec
                // P3: no frame, or one more than 5 s off: ask the thumbnailer for the keyframe there.
                // Reads the tolerance-bounded match (BUG-181 leaves the refine rule as it was).
                if self.thumbs.lookupWantsRefine(target: target, matchSec: match?.sec) {
                    self.noteThumbScrubMiss(target: target)
                }
                self.handlePreviewFrameDecision(
                    self.previewFrameThrottle.finished(now: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    #if DEBUG
    /// `-debug.scrubInject`: replays a scripted stroke through the arbiter (the simulator cannot
    /// swipe). Same path as the real recogniser below `handleScrubPan`.
    private func runScrubInject() {
        guard let script = UserDefaults.standard.string(forKey: "debug.scrubInject") else { return }
        let samples = ScrubInjectScript.parse(script)
        guard !samples.isEmpty else { return }
        scrubInjectTimer?.invalidate()
        scrubArbiter.touchBegan()
        state.transport.debugArbiter = scrubArbiter.probeCode
        NSLog("[Scrub] inject samples=%ld", samples.count)
        injectScrubSample(samples, at: 0, tx: 0, ty: 0)
    }

    private func injectScrubSample(_ samples: [ScrubInjectScript.Sample], at index: Int, tx: Double, ty: Double) {
        guard index < samples.count else {
            scrubInjectTimer = nil
            NSLog("[Scrub] stroke end intent=%@ travel=%.0f vx=inject", scrubArbiter.probeCode, scrubArbiter.travel)
            routeScrub(scrubArbiter.touchEnded(context: scrubContext()))
            state.transport.debugArbiter = scrubArbiter.probeCode
            return
        }
        let sample = samples[index]
        let timer = Timer(timeInterval: sample.dt, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let nx = tx + sample.dx, ny = ty + sample.dy
                self.routeScrub(self.scrubArbiter.moved(tx: nx, ty: ny, now: ProcessInfo.processInfo.systemUptime,
                                                        context: self.scrubContext()))
                self.state.transport.debugArbiter = self.scrubArbiter.probeCode
                self.injectScrubSample(samples, at: index + 1, tx: nx, ty: ny)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrubInjectTimer = timer
    }
    #endif

    private func issueCommit(_ r: TransportPreview.CommitRequest) {
        let t = String(format: "%.3f", r.targetSec)
        let gen: Int
        if r.stages.first == .keyframes {
            let expected = seekGeneration + 1           // issueSeek's generation for this seek
            gen = issueSeek(kind: .user, targetSec: r.targetSec, fromSec: r.fromSec,
                            args: [t, "absolute+keyframes"], onRejected: { [weak self] in
                                // A late rejection must not drop a newer commit's exact stage.
                                if self?.pendingExact?.generation == expected { self?.pendingExact = nil }
                            })
            if commitExactDelaySec >= 0 {
                let deadline = DispatchWorkItem { [weak self] in self?.exactDeadlineFired(generation: expected) }
                pendingExact = (gen, r, deadline)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: deadline)
            }
            #if DEBUG
            state.seekProbe.note(commit: r.targetSec, stages: "k")
            #endif
        } else {
            gen = issueSeek(kind: .user, targetSec: r.targetSec, fromSec: r.fromSec, args: [t, "absolute+exact"])
            #if DEBUG
            state.seekProbe.note(commit: r.targetSec, stages: "e")
            #endif
        }
        armCommitLanding(generation: gen, fallbackSec: 1.5, yieldsToExact: r.stages.first == .keyframes)
    }

    /// The preview playhead hands back to the real position when this generation lands, or after
    /// `fallbackSec` if it never reports.
    /// `yieldsToExact`: the first (1.5 s) fallback of a keyframes-first commit must not clear the
    /// preview while that commit's exact stage is still pending; the deadline re-arms a longer
    /// fallback that does not yield (review r3 P3-2 hardening; libdispatch orders the two timers
    /// today, this makes the order irrelevant).
    private func armCommitLanding(generation: Int, fallbackSec: TimeInterval, yieldsToExact: Bool = false) {
        commitGeneration = generation
        commitLandWork?.cancel()
        let landWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if yieldsToExact, self.pendingExact?.generation == generation { return }
            self.transport.noteCommitLanded()
            self.state.transport.previewSec = self.transport.previewSec
        }
        commitLandWork = landWork
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackSec, execute: landWork)
    }

    /// The keyframes stage has not landed within 1.5 s (slow uncached seek). Stacking the exact
    /// seek before mpv has even started the keyframes one would misattribute that SEEK event to
    /// the exact stage, so wait for it: the exact stage runs as soon as mpv reports it.
    private func exactDeadlineFired(generation: Int) {
        guard pendingExact?.generation == generation else { return }
        // The 1.5 s landing fallback is due now too: firing it would clear the preview while mpv
        // still sits at the origin (the fill snaps back). Hold the preview until the exact stage
        // re-arms its own 3 s handback, or 4 s if mpv never even starts the keyframes seek.
        if commitGeneration == generation {
            armCommitLanding(generation: generation, fallbackSec: 4)
        }
        eventQueue.async { [weak self] in
            guard let self else { return }
            if self.awaitingSeekStartGeneration == generation {
                self.exactAwaitsSeekStart = generation
            } else {
                DispatchQueue.main.async { self.runExactStage(ifGeneration: generation) }
            }
        }
    }

    private func scheduleExact(after delay: TimeInterval) {
        guard let p = pendingExact else { return }
        p.deadline.cancel()
        exactWork?.cancel()
        // Generation-bound: a leftover item must never run a NEWER commit's exact stage before mpv
        // has reported that commit's keyframes seek (review r3 P3-1).
        let gen = p.generation
        let work = DispatchWorkItem { [weak self] in self?.runExactStage(ifGeneration: gen) }
        exactWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runExactStage(ifGeneration expected: Int? = nil) {
        guard let p = pendingExact else { return }
        if let expected, p.generation != expected { return }
        p.deadline.cancel()
        pendingExact = nil
        exactWork?.cancel()   // the 0.15 s item may still be queued when the deadline hop ran us first
        exactWork = nil
        let now = ProcessInfo.processInfo.systemUptime
        skipPlanner.refineSeek(targetSec: p.request.targetSec, fromSec: p.request.fromSec, now: now)
        // The planner already knows about this seek (`refineSeek`): no second `beginSeek`.
        let gen = issueSeek(kind: .user, targetSec: p.request.targetSec, fromSec: p.request.fromSec,
                            args: [String(format: "%.3f", p.request.targetSec), "absolute+exact"], planner: false)
        // The keyframes landing may never report now (`issueSeek` drops its restart): the preview
        // hands back on the exact stage's landing instead, so the fill never snaps to the origin.
        if commitGeneration == p.generation {
            armCommitLanding(generation: gen, fallbackSec: 3)
        }
        #if DEBUG
        state.seekProbe.stages = "ke"
        #endif
    }

    private func cancelExactStage() {
        exactWork?.cancel()
        exactWork = nil
        pendingExact?.deadline.cancel()
        pendingExact = nil
    }

    // MARK: Scan

    private func startScan(_ rate: Int) {
        scanRestoreSpeed = state.playbackSpeed      // captured on main before any hop
        #if DEBUG
        state.seekProbe.speed = Double(rate)
        #endif
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            // eventQueue read and store, never main: `endScan`'s block runs after this one.
            self.scanWasMuted = self.getFlag("mute")
            self.setFlag("mute", true)
            _ = self.command("set", args: ["audio-pitch-correction", "no"])
            self.setMpvDouble("speed", Double(rate))
        }
    }

    private func endScan(from: Double, returnTo: Double?) {
        let restoreSpeed = scanRestoreSpeed ?? state.playbackSpeed
        #if DEBUG
        NSLog("[MenuProbe] endScan from=%.2f returnTo=%@ live=%.2f", from,
              returnTo.map { String(format: "%.2f", $0) } ?? "nil", cachedProps().position ?? -1)
        #endif
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            self.setMpvDouble("speed", restoreSpeed)
            self.setFlag("mute", self.scanWasMuted ?? false)
            self.scanWasMuted = nil
            _ = self.command("set", args: ["audio-pitch-correction", "yes"])
        }
        #if DEBUG
        state.seekProbe.speed = restoreSpeed
        #endif
        if let target = returnTo {
            // Menu: the scanned stretch was not watched, so no span is recorded (its intervals must
            // still auto-skip when played). Exact only: the origin sits in the back buffer.
            // `fromSec: target`: the span scan-end → origin must not mark the interval at the scan
            // end as deliberate.
            issueSeek(kind: .user, targetSec: target, fromSec: target,
                      args: [String(format: "%.3f", target), "absolute+exact"])
            #if DEBUG
            state.seekProbe.note(commit: target, stages: "r")   // "r" = scan return (Menu)
            #endif
        } else {
            skipPlanner.recordUserSpan(fromSec: from, toSec: cachedProps().position)
        }
        scanRestoreSpeed = nil
        state.transport.previewSec = nil
        flashControls()
    }

    private func togglePause() {
        guard mpv != nil else { return }
        // BUG-170: Play/Pause during the display-mode hold takes over from it.
        if displayModeHoldStartedAt != nil {
            displayModeHoldStartedAt = nil
            state.displayModeHolding = false
            print("[DisplayMode] release reason=user")
        }
        let target = !cachedProps().paused
        // Optimistic UI: reflect the new state immediately; the pause property event confirms it.
        updateProps { $0.paused = target }
        eventQueue.async { [weak self] in self?.setFlag("pause", target) }
        refreshState()
    }

    /// Post-play "Play Again": back to the start and resume playing.
    private func replay() {
        guard mpv != nil else { return }
        cancelExactStage()
        seekAbsolute(0, kind: .replay)   // intro/outro auto-skip arms again for the second viewing
        setFlag("pause", false)
        state.isEnded = false
        flashControls()
        becomeFirstResponder()
    }

    private func seekBy(_ seconds: Double) {
        guard mpv != nil else { return }
        // Arrow seeks are deliberate: a segment they start or land in is never auto-skipped. The
        // cached position is stale while another seek is in flight — mpv's relative seek then
        // starts from that seek's target, so the estimate does too (nil = unknown). The planner
        // marks the position mpv actually lands on, reported by `drainEvents`.
        let base: Double?
        if let inFlight = skipPlanner.seekInFlight {
            base = inFlight.targetSec
        } else {
            base = cachedProps().position
        }
        issueSeek(kind: .user, targetSec: base.map { $0 + seconds }, fromSec: base,
                  args: [String(format: "%.3f", seconds), "relative"])
    }

    /// One Left/Right click (P1's `.immediateSeek`): ±10 s, or in chapter mode a chapter jump.
    private func edgeClick(_ d: Double) {
        let base = skipPlanner.seekInFlight?.targetSec ?? cachedProps().position   // seekBy's rule
        switch PlayerChapters.edgeClick(mode: edgeClickMode, direction: d < 0 ? -1 : 1, baseSec: base,
                                        chapters: state.transport.chapters, skipSec: abs(d)) {
        case .relative(let r): seekBy(r)
        case .absolute(let t): seekToChapter(t)
        }
    }

    /// Absolute seek to a chapter start (the Chapters tab, a chapter-mode click). A backward jump
    /// cancels the up-next countdown, like any backward seek.
    private func seekToChapter(_ chapterSec: Double) {
        guard mpv != nil else { return }
        // Backstop for a list read before the duration was known (review r1 P2 #2).
        let sec = PlayerChapters.clampedSeek(chapterSec, durationSec: cachedProps().duration)
        let base = skipPlanner.seekInFlight?.targetSec ?? cachedProps().position
        if sec < base { state.upNextCancel?() }
        // A chapter seek supersedes a held commit (review r1 P3 #7): its pending exact stage must
        // not pull the playhead back to the old target, and its preview hands back now, not when
        // the old landing fires.
        cancelExactStage()
        commitLandWork?.cancel()
        commitLandWork = nil
        commitGeneration = nil
        transport.noteCommitLanded()
        state.transport.previewSec = transport.previewSec
        issueSeek(kind: .user, targetSec: sec, fromSec: base, args: [String(format: "%.3f", sec), "absolute"])
        #if DEBUG
        state.seekProbe.note(commit: sec, stages: "ch")
        #endif
        flashControls()
    }

    @discardableResult
    private func seekAbsolute(_ seconds: Double, kind: SkipSegmentPlanner.SeekKind) -> Int {
        issueSeek(kind: kind, targetSec: seconds, args: [String(format: "%.3f", seconds), "absolute"])
    }

    /// Every seek the app issues goes through here. Main thread: the skip planner is told first,
    /// so no tick can act on the pre-seek position. `eventQueue`: the command runs off-main (held-
    /// arrow timers must not park the main thread on the core lock) and the seek is tracked for its
    /// engine-confirmed completion (MPV_EVENT_SEEK, then MPV_EVENT_PLAYBACK_RESTART — `drainEvents`).
    @discardableResult
    private func issueSeek(kind: SkipSegmentPlanner.SeekKind, targetSec: Double?, fromSec: Double? = nil,
                           args: [String?], planner: Bool = true, onRejected: (() -> Void)? = nil) -> Int {
        guard mpv != nil else { return seekGeneration }
        if planner {
            skipPlanner.beginSeek(kind: kind, targetSec: targetSec, fromSec: fromSec,
                                  now: ProcessInfo.processInfo.systemUptime)
        }
        seekGeneration += 1
        let generation = seekGeneration
        eventQueue.async { [weak self] in
            guard let self else { return }
            self.awaitingSeekStartGeneration = generation
            // An older seek's restart is not this one's completion.
            self.startedSeekGeneration = nil
            let status = self.command("seek", args: args)
            #if DEBUG
            NSLog("[SeekProbe] seek gen=%ld args=%@ status=%d", generation,
                  args.compactMap { $0 }.joined(separator: " "), status)
            #endif
            guard status < 0 else { return }
            // Rejected: no SEEK/PLAYBACK_RESTART will follow, and a later mpv-internal seek (e.g.
            // an audio-track switch refresh) must not pass for this one's completion.
            self.awaitingSeekStartGeneration = nil
            DispatchQueue.main.async {
                onRejected?()
                guard generation == self.seekGeneration else { return }
                self.skipPlanner.seekInterrupted()
            }
        }
        return generation
    }

    /// Raise the bar (or keep it up) and re-arm its hide timer: every input comes through here.
    private func flashControls() {
        state.controlsVisible = true
        scheduleHide()
    }

    /// Hide rule: 4 s after the last input while playing; paused, 5 s when the pause card is on and
    /// never when it is off. A timer that fires with a pill focused or a seek mode active does
    /// nothing (the next input re-arms it).
    private func scheduleHide() {
        hideWork?.cancel()
        hideWork = nil
        guard let delay = currentHideDelay() else { return }
        armHide(after: delay, elapsed: delay)
    }

    private func currentHideDelay() -> TimeInterval? {
        TransportHideRule.delay(isPaused: cachedProps().paused,
                                pauseCardEnabled: playerSettings?.pauseOverlayEnabled != false)
    }

    /// `elapsed`: seconds since the last input once this fires. The pause state can change without
    /// input (programmatic pause), so the rule is re-read when the timer fires: paused with the card
    /// off never hides, paused with the card on waits out the longer delay.
    private func armHide(after seconds: TimeInterval, elapsed: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard TransportHideRule.mayHide(pillFocused: self.state.transport.focusedPill != nil,
                                            modeActive: self.transport.mode.isActive) else { return }
            guard let due = self.currentHideDelay() else { return }
            if due > elapsed {
                self.armHide(after: due - elapsed, elapsed: due)
                return
            }
            self.state.transport.focusedPill = nil
            self.state.controlsVisible = false
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hideControlsNow() {
        hideWork?.cancel()
        hideWork = nil
        state.transport.focusedPill = nil
        state.controlsVisible = false
    }

    private func movePill(by delta: Int) {
        let t = state.transport
        if let current = t.focusedPill, let next = PillKind.move(from: current, by: delta, in: t.pills) {
            t.focusedPill = next
        }
        flashControls()
    }

    private func activatePill(_ pill: PillKind) {
        // Aspect cycles in place: focus stays on the pill so repeated Select keeps cycling.
        if pill == .aspect { cycleAspect(); flashControls(); return }
        state.transport.focusedPill = nil
        flashControls()
        guard presentedViewController == nil else { return }
        refreshTracksAsync()
        onOpenPanel?(pill.panelTab)
    }

    // MARK: - Failover signals
    //
    // Everything here runs on the main thread and is inert while `onPlaybackFailed` is nil, so a
    // host that wires nothing sees exactly the player it always had. Every failure path funnels
    // through `reportPlaybackFailure`, which is one-shot per player. Greppable: `[Failover]`.

    /// Seconds of real playback for a failure report: what `playClock` accumulated while mpv was
    /// actually playing (paused and buffering time does not count) plus whatever the native engine
    /// played before falling back to this player. 0 until a file has loaded (nothing played yet,
    /// whatever the other engine did).
    private var failoverSecondsPlayed: Double {
        guard failoverLoadedUptime != nil else { return 0 }
        return playClock.seconds + nativeSecondsPlayedBeforeFallback
    }

    /// One `refreshState` tick into the play clock. Nothing counts before `MPV_EVENT_FILE_LOADED`
    /// (the property cache's defaults read as "playing"). "Playing" is the same definition the
    /// buffering spinner uses: not paused, not waiting on the cache, core not idle (a seek or a
    /// stall), and not parked at the end of the file by keep-open.
    private func samplePlayClock(_ snap: PropSnapshot) {
        guard failoverLoadedUptime != nil else { return }
        let playing = !snap.paused && !snap.cacheWait && !snap.coreIdle && !snap.eof
        playClock.note(playing: playing, at: ProcessInfo.processInfo.systemUptime)
    }

    /// (d) `eof-reached` just rose (keep-open holds the last frame). A stream that ran dry well
    /// before its declared end is a failure for the failover to handle, not a finished movie
    /// (`PlaybackEndPolicy`). Returns true when the caller must NOT raise the post-play card: the
    /// host was told now, or was told before and is already swapping or closing this player (a
    /// card on top of that would fight the dismissal). False means a normal end — also when the
    /// report was refused because the viewer is leaving or a context swap is underway, so the
    /// player never sits at the end of the file with nothing on screen to act on.
    private func handleEarlyEndOfFile(_ snap: PropSnapshot) -> Bool {
        guard onPlaybackFailed != nil else { return false }
        let played = failoverSecondsPlayed
        guard PlaybackEndPolicy.isEarlyEndFailure(
            position: snap.position, duration: snap.duration,
            secondsPlayed: played, launchSource: context.launchSource) else { return false }
        // A dropped connection also ends a stream early: network evidence in the ring wins.
        let ringVerdict = PlaybackFailureClassifier.fromMpvLog(logRing.snapshot, endFileError: nil, watchdogFired: false)
        let earlyVerdict = ringVerdict.kind == .network || ringVerdict.kind == .http
            ? ringVerdict : PlaybackFailureClassifier.Verdict(.endedEarly)
        if reportPlaybackFailure(
            reason: "stream ended early at \(Int(snap.position))/\(Int(snap.duration)) s",
            startedPlaying: true, secondsPlayed: played, positionSec: snap.position, verdict: earlyVerdict) {
            return true
        }
        return failoverReported
    }

    /// The single exit for every failover signal. Returns true when the host was told.
    @discardableResult
    private func reportPlaybackFailure(reason: String, startedPlaying: Bool, secondsPlayed: Double,
                                       positionSec: Double? = nil,
                                       verdict: PlaybackFailureClassifier.Verdict) -> Bool {
        guard let onPlaybackFailed else { return false }
        guard !failoverReported, !failoverClosed, !state.playbackFailoverSuppressed else {
            print("[Failover] mpv failure suppressed (\(reason)) reported=\(failoverReported) closed=\(failoverClosed) swapped=\(state.playbackFailoverSuppressed)")
            return false
        }
        failoverReported = true
        startWatchdog.noteCancelled()
        stopStartWatchdogTimer()
        var position = positionSec ?? cachedProps().position
        if !position.isFinite || position < 0 { position = max(0, state.positionSec) }
        // BUG-143: no usable network path at the moment of failure → offline, whatever was seen.
        let v = PlaybackFailureClassifier.applyingPath(verdict, pathSatisfied: NetworkPathMonitor.shared.isSatisfied)
        print("[Failover] mpv failure: \(reason) pos=\(Int(position)) played=\(Int(secondsPlayed)) started=\(startedPlaying)"
              + " kind=\(v.kind.rawValue) http=\(v.httpStatus.map(String.init) ?? "-")")
        onPlaybackFailed(PlaybackFailure(reason: reason, positionSec: position,
                                         secondsPlayed: secondsPlayed, startedPlaying: startedPlaying,
                                         kind: v.kind, httpStatus: v.httpStatus))
        return true
    }

    /// (a) `MPV_END_FILE_REASON_ERROR`: mpv could not open or keep decoding the stream.
    private func reportEndFileError(_ message: String, logs: [String]) {
        reportPlaybackFailure(reason: "mpv: \(message)", startedPlaying: failoverLoadedUptime != nil,
                              secondsPlayed: failoverSecondsPlayed,
                              verdict: PlaybackFailureClassifier.fromMpvLog(logs, endFileError: message, watchdogFired: false))
    }

    /// (b) Arm the start watchdog when `loadfile` is issued: nothing loading within the budget is a
    /// failure (a dead host or stalled handshake makes mpv go quiet, not report an error).
    private func armStartWatchdog() {
        guard onPlaybackFailed != nil else { return }
        startWatchdog = MPVStartWatchdog(limitSeconds: MPVStartWatchdog.limitSeconds(shortened: startWatchdogShortened))
        startWatchdog.noteLoadStarted(at: ProcessInfo.processInfo.systemUptime)
        print("[Failover] mpv start watchdog armed: \(Int(startWatchdog.limitSeconds)) s")
        startWatchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickStartWatchdog()
        }
        RunLoop.main.add(timer, forMode: .common)
        startWatchdogTimer = timer
    }

    private func tickStartWatchdog() {
        switch startWatchdog.poll(now: ProcessInfo.processInfo.systemUptime) {
        case .waiting:
            break
        case .inactive:
            stopStartWatchdogTimer()
        case .fired:
            stopStartWatchdogTimer()
            reportPlaybackFailure(reason: "no media within \(Int(startWatchdog.limitSeconds)) s",
                                  startedPlaying: false, secondsPlayed: 0,
                                  verdict: PlaybackFailureClassifier.fromMpvLog(logRing.snapshot, endFileError: nil,
                                                                                watchdogFired: true))
        }
    }

    private func stopStartWatchdogTimer() {
        startWatchdogTimer?.invalidate()
        startWatchdogTimer = nil
    }

    /// `MPV_EVENT_FILE_LOADED` (main thread): media is flowing, the watchdog stands down.
    private func noteMediaLoaded(at uptime: TimeInterval) {
        if failoverLoadedUptime == nil { failoverLoadedUptime = uptime }
        startWatchdog.noteFileLoaded()
        stopStartWatchdogTimer()
    }

    /// (c) A stub clip (debrid cache-sync placeholder, "service unavailable" video) on an auto flow:
    /// report it and stop playback. Manual picks never take this path — the viewer chose that
    /// stream. Returns true when the clip was rejected, so the caller skips the normal file-loaded
    /// work (resume seek, scrobble start, addon-subtitle fetch).
    private func rejectPlaceholderClip(durationSec: Double) -> Bool {
        guard onPlaybackFailed != nil, context.launchSource != .manual, durationSec.isFinite else { return false }
        guard WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000)) else { return false }
        let seconds = Int(durationSec.rounded())
        print("[Failover] mpv placeholder clip rejected: \(seconds) s on an auto flow")
        reportPlaybackFailure(reason: "placeholder clip (\(seconds)s)", startedPlaying: true, secondsPlayed: 0,
                              verdict: .init(.placeholder))
        eventQueue.async { [weak self] in self?.command("stop") }
        return true
    }

    /// Fire `onPlaybackHealthy` once, when the play clock first reaches 300 s
    /// (`PlaybackFailoverPolicy.healthySeconds`). Called from the ~5 s progress-save tick in
    /// `refreshState`.
    private func reportHealthyIfNeeded() {
        guard !healthyReported, let onPlaybackHealthy, failoverLoadedUptime != nil else { return }
        let played = failoverSecondsPlayed
        guard played >= PlaybackFailoverPolicy.healthySeconds else { return }
        healthyReported = true
        print("[Failover] mpv healthy after \(Int(played)) s")
        onPlaybackHealthy(played)
    }

    /// True while this controller is actually going away: it, or anything above it in the
    /// containment chain, is being dismissed or removed from its parent. A full-screen cover
    /// presented over the player (the post-play card) also fires `viewWillDisappear`, but none of
    /// these flags are set then. Only meaningful from inside `viewWillDisappear`/`viewDidDisappear`.
    private var isLeavingPlayer: Bool {
        var node: UIViewController? = self
        while let current = node {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            node = current.parent
        }
        return false
    }

    /// BUG-165 / review r1 P1-1: the presentation this controller sits in is going away (an
    /// ancestor `isBeingDismissed`), as opposed to this controller being swapped out of a parent
    /// that stays (`isMovingFromParent` alone, the Up Next / failover `.id` swap).
    private var coverIsBeingDismissed: Bool {
        var node: UIViewController? = self
        while let current = node {
            if current.isBeingDismissed { return true }
            node = current.parent
        }
        return false
    }

    /// The viewer is leaving or the player is going away: no failure may be reported from here on.
    private func closeFailover() {
        failoverClosed = true
        startWatchdog.noteCancelled()
        stopStartWatchdogTimer()
    }

    // MARK: - Teardown

    deinit {
        pollTimer?.invalidate()
        startWatchdogTimer?.invalidate()
        holdTimer?.invalidate()
        subtitleWatcher?.cancel()
        subtitleLoadingWatcher?.cancel()
        playerSettingsWatcher?.cancel()
        // Idempotent final scrobble stop — normally a no-op after viewDidDisappear, but covers
        // teardown paths where the disappearance callback never ran (ME-004).
        stopTraktScrobble()
        SubtitleRepository.shared.clear()
        destroyPlayer()
    }

    private func destroyPlayer() {
        #if DEBUG
        if let token = lightTapObserver {
            NotificationCenter.default.removeObserver(token)
            lightTapObserver = nil
        }
        if let token = scrubInjectObserver {
            NotificationCenter.default.removeObserver(token)
            scrubInjectObserver = nil
        }
        scrubInjectTimer?.invalidate()
        scrubInjectTimer = nil
        #endif
        endTimeWork?.cancel()
        hideWork?.cancel()
        scrubIdleWork?.cancel()
        scrubPublishWork?.cancel()
        previewFrameWork?.cancel()
        previewFrameToken += 1
        // P3: the thumbnailer never touches mpv; closing first starts its abort while mpv shuts
        // down. Plain property writes (no weak reference formed in deinit).
        thumbScrubWork?.cancel()
        thumbReleaseWork?.cancel()
        thumbs.cancel()
        thumbnailer?.close()
        thumbnailer = nil
        guard let ctx = mpv else { return }
        mpv = nil
        // mpv invokes the wakeup callback under the lock this call takes, so once it returns no
        // callback is running and none can start: shutdown's last wakeup never reaches the relay
        // (and the relay already turns one that slips in earlier into a no-op).
        mpv_set_wakeup_callback(ctx, nil, nil)
        // BUG-165 (rc4 verdict): `mpv_terminate_destroy` tears the Vulkan/Metal VO down and waits
        // for mpv's threads. It used to run on the main thread in this controller's deinit; the
        // device pass measured it at 76–132 ms there (Steven's ~6 s of black on exit is NOT this
        // call), but a main-thread stall of any length between the exit press and the picker is a
        // window in which remote presses queue up and land on whatever is under the cover. The
        // destroy now runs on `eventQueue` (serial: every queued mpv call drains first, and nothing
        // enqueues after `mpv` went nil above). The Metal layer is mpv's `wid`, so the block keeps it
        // alive until the VO has let go of it, and hands its last reference back to main (review r1
        // P3-2: a CALayer should not deallocate on a background queue).
        let layerRef = Unmanaged.passRetained(metalLayer)   // +1 held across the destroy, released on main
        let started = ProcessInfo.processInfo.systemUptime
        eventQueue.async {
            mpv_terminate_destroy(ctx)
            NSLog("[MPV] terminate_destroy took=%dms", Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
            DispatchQueue.main.async { layerRef.release() }
        }
        // Plain property writes (no weak reference formed): the store goes with the controller.
        seekPreviewSource = nil
        previewStore = nil
    }

    // MARK: - Event loop

    /// Runs on `eventQueue`: `MPVWakeupRelay` hops here for every mpv wakeup, so the controller is
    /// only ever loaded off mpv's own threads (see the relay). Drains every queued event.
    private func drainEvents() {
        guard let mpv = self.mpv else { return }
        while true {
            guard let ev = mpv_wait_event(mpv, 0) else { break }
            let id = ev.pointee.event_id
            if id == MPV_EVENT_NONE { break }
            if id == MPV_EVENT_SHUTDOWN { return }
            if id == MPV_EVENT_FILE_LOADED {
                self.fileLoadedUptime = ProcessInfo.processInfo.systemUptime
                let loadedAt = self.fileLoadedUptime
                self.alangTrace("file-loaded alang=\(self.getString("alang") ?? "-") aid=\(self.getString("aid") ?? "-")")
                // Read on eventQueue (never the main thread — see the property-cache note).
                let loadedDuration = self.getDouble("duration")
                DispatchQueue.main.async {
                    self.noteMediaLoaded(at: loadedAt)
                    // Auto flows: a stub clip is a failed source, not an episode — no resume,
                    // no scrobble, no subtitle fetch.
                    if self.rejectPlaceholderClip(durationSec: loadedDuration) { return }
                    let resumeGeneration = self.applyPendingResume(actualDurationSec: loadedDuration)
                    // B24: buffering until the restart that completes this resume seek (or any
                    // restart when there is none). Before `onFileLoaded`, so the stage leads.
                    if self.startupStages.fileLoaded(resumeGeneration: resumeGeneration) { self.publishStartupStage() }
                    self.onFileLoaded()
                }
                self.refreshTracksAsync()
                self.readChapters()
            }
            // Engine-confirmed seek completion for `skipPlanner` (see `issueSeek`): our seek
            // started (SEEK), then playback restarted after it (PLAYBACK_RESTART). A restart
            // with no seek of ours started — start of playback, a track switch — is ignored.
            if id == MPV_EVENT_SEEK, let generation = self.awaitingSeekStartGeneration {
                self.awaitingSeekStartGeneration = nil
                self.startedSeekGeneration = generation
                if self.exactAwaitsSeekStart == generation {
                    self.exactAwaitsSeekStart = nil
                    DispatchQueue.main.async { self.runExactStage(ifGeneration: generation) }
                }
            }
            if id == MPV_EVENT_PLAYBACK_RESTART {
                // B24: which of our seeks (if any) this restart completes, read before the block
                // below clears it. Strong hop (the BUG-141 rule); a few per file, never per frame.
                let completes = self.startedSeekGeneration
                DispatchQueue.main.async {
                    if self.startupStages.playbackRestart(completesSeek: completes) { self.publishStartupStage() }
                }
            }
            if id == MPV_EVENT_PLAYBACK_RESTART, let generation = self.startedSeekGeneration {
                self.startedSeekGeneration = nil
                // Read on eventQueue (never the main thread — see the property-cache note).
                var timePos = Double.nan
                let ok = mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &timePos) >= 0
                let landed = ok ? timePos : .nan
                #if DEBUG
                NSLog("[SeekProbe] restart gen=%ld landed=%.3f", generation, landed)
                #endif
                DispatchQueue.main.async {
                    // The preview playhead hands back to the real position on a commit's first
                    // landing, whether or not the planner guard below passes.
                    if generation == self.commitGeneration {
                        self.commitGeneration = nil
                        self.commitLandWork?.cancel()
                        self.transport.noteCommitLanded()
                        self.state.transport.previewSec = self.transport.previewSec
                    }
                    // A newer seek was issued meanwhile: this is not its completion.
                    guard generation == self.seekGeneration else { return }
                    self.harvest.noteSeekLanded(now: ProcessInfo.processInfo.systemUptime)
                    self.thumbs.noteSeekLanded(now: ProcessInfo.processInfo.systemUptime)
                    self.skipPlanner.seekCompleted(atSec: landed, now: ProcessInfo.processInfo.systemUptime)
                    // Keyframes landed: show that picture first, then run the exact stage.
                    if let p = self.pendingExact, p.generation == generation {
                        self.scheduleExact(after: self.commitExactDelaySec)
                    }
                    // The cache may still hold the pre-seek position (its property-change event
                    // can trail this one): the next UI tick must see where the seek landed.
                    // Written HERE, after the planner heard the completion (a lock-guarded cache
                    // write, no mpv call): a UI tick between an earlier eventQueue write and
                    // this block would evaluate the landing before it is marked deliberate.
                    if landed.isFinite { self.updateProps { $0.position = landed } }
                }
            }
            if id == MPV_EVENT_PROPERTY_CHANGE, let data = ev.pointee.data {
                let prop = UnsafePointer<mpv_event_property>(OpaquePointer(data)).pointee
                self.handlePropertyChange(userdata: ev.pointee.reply_userdata, prop: prop)
            }
            if id == MPV_EVENT_COMMAND_REPLY, MPVSubtitleSideLoadQueue.isReply(ev.pointee.reply_userdata) {
                self.finishSubtitleSideLoad(replyId: ev.pointee.reply_userdata, error: ev.pointee.error)
            }
            if id == MPV_EVENT_AUDIO_RECONFIG {
                // P5 B20: the output layout is known (or changed): rebuild the Dialogue filter.
                self.applyAudioFilter()
            }
            if id == MPV_EVENT_START_FILE {
                // r1 P3: the ring is evidence about the file being loaded now (event order).
                self.logRing.clear()
            }
            if id == MPV_EVENT_END_FILE, let data = ev.pointee.data {
                let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                if endFile.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(endFile.error))
                    print("[MPV] End file error: \(message)")
                    // This block runs on `eventQueue`; the report is a main-thread affair. The log
                    // ring is copied here, in event order, so later lines cannot blur the evidence.
                    let logs = self.logRing.snapshot
                    DispatchQueue.main.async { [weak self] in
                        self?.reportEndFileError(message, logs: logs)
                    }
                }
            }
            if id == MPV_EVENT_LOG_MESSAGE,
               let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(ev.pointee.data)) {
                let level = String(cString: msg.pointee.level!)
                let text = String(cString: msg.pointee.text!)
                print("[MPV] \(level): \(text)", terminator: "")
                if level == "warn" || level == "error" || level == "fatal" {
                    let prefix = msg.pointee.prefix.map { String(cString: $0) } ?? "mpv"
                    self.logRing.append(prefix: prefix, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                #if DEBUG
                NSLog("[MPV] %@: %@", level, text.trimmingCharacters(in: .newlines))   // reaches `log stream`
                #endif
            }
        }
    }

    /// Runs on `eventQueue`. Folds a property-change payload into the snapshot; only a
    /// track-count change escalates to the (also off-main) track-list walk.
    private func handlePropertyChange(userdata: UInt64, prop: mpv_event_property) {
        guard let observed = ObservedProp(rawValue: userdata) else { return }

        func asDouble() -> Double? {
            guard prop.format == MPV_FORMAT_DOUBLE, let d = prop.data else { return nil }
            return d.assumingMemoryBound(to: Double.self).pointee
        }
        func asFlag() -> Bool? {
            guard prop.format == MPV_FORMAT_FLAG, let d = prop.data else { return nil }
            return d.assumingMemoryBound(to: Int32.self).pointee != 0
        }
        func asInt() -> Int64? {
            guard prop.format == MPV_FORMAT_INT64, let d = prop.data else { return nil }
            return d.assumingMemoryBound(to: Int64.self).pointee
        }

        switch observed {
        case .timePos:
            if let v = asDouble() { updateProps { $0.position = v } }
        case .duration:
            if let v = asDouble() { updateProps { $0.duration = v } }
        case .pause:
            if let v = asFlag() { updateProps { $0.paused = v } }
        case .coreIdle:
            if let v = asFlag() { updateProps { $0.coreIdle = v } }
        case .pausedForCache:
            if let v = asFlag() {
                var rising = false
                updateProps { rising = v && !$0.cacheWait; $0.cacheWait = v }
                if rising { cacheWaitCount += 1 }
            }
        case .eofReached:
            if let v = asFlag() { updateProps { $0.eof = v } }
        case .trackCount:
            // While side-loads run, each one adds a track: `finishSubtitleSideLoad` decides which
            // of those walks are worth it (a 100-track walk per load is not).
            if !subtitleSideLoads.isActive { refreshTracksAsync() }
        case .videoW:
            if let v = asInt() { updateProps { $0.videoW = v } }
        case .videoH:
            if let v = asInt() {
                updateProps { $0.videoH = v }
                if v > 0 { refreshBadgeVideoParams() }
            }
        case .aid:
            if let v = asInt() {
                alangTrace("aid changed -> \(v)")
                publishBadgeFacts(aid: Int(v))
            }
        case .cacheBuffering:
            if let v = asInt() { updateProps { $0.cacheBufferingPct = v } }
        case .seekable:
            if let v = asFlag() { updateProps { $0.seekable = v } }
        case .fileFormat:
            if prop.format == MPV_FORMAT_STRING, let d = prop.data,
               let c = d.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                let v = String(cString: c)
                updateProps { $0.fileFormat = v }
            }
        }
    }

    /// THE resume seek (user-initiated for skip logic: an intro interval this lands inside must
    /// not be auto-skipped). Sets `didResumeSeek` so later code can identify it.
    /// Returns the resume seek's generation (nil = no resume seek), for the B24 startup stages.
    @discardableResult
    private func applyPendingResume(actualDurationSec: Double) -> Int? {
        if let seconds = pendingResumeSec {
            pendingResumeSec = nil
            didResumeSeek = true
            return seekAbsolute(seconds, kind: .resume)
        }
        guard let entry = pendingResumeEntry else { return nil }
        pendingResumeEntry = nil
        if actualDurationSec > 0 {
            let seconds = Double(entry.resolveResumePosition(actualDurationMs: Int64(actualDurationSec * 1000))) / 1000.0
            guard seconds > 10 else { return nil }
            didResumeSeek = true
            return seekAbsolute(seconds, kind: .resume)
        } else {
            // Duration unknown (some HLS): let mpv resolve the percentage itself.
            let pct = Double(entry.progressFraction) * 100
            guard pct > 0 else { return nil }
            didResumeSeek = true
            return issueSeek(kind: .resume, targetSec: nil, args: [String(format: "%.3f", pct), "absolute-percent"])
        }
    }

    /// B24 (main thread): mirror the reducer's stage into the screen state and log the change.
    private func publishStartupStage() {
        let stage = startupStages.stage
        state.startupStage = stage
        if stage.isStarted { state.playbackStarted = true }
        let t = ProcessInfo.processInfo.systemUptime - loadingStartUptime
        print("[Loading] engine=mpv stage=\(stage.logToken) t=+\(String(format: "%.2f", t))s")
    }

    // MARK: - libmpv C-interop helpers

    /// Returns mpv's status (< 0 = error, already logged; also < 0 when there is no player).
    @discardableResult
    private func command(_ command: String, args: [String?] = []) -> CInt {
        guard mpv != nil else { return -1 }
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        var cargs = strArgs.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
        let status = mpv_command(mpv, &cargs)
        checkError(status)
        return status
    }

    /// `mpv_command_async`: returns at once (< 0 = refused, already logged); the result arrives as
    /// MPV_EVENT_COMMAND_REPLY carrying `replyId`.
    @discardableResult
    private func commandAsync(replyId: UInt64, _ command: String, args: [String?] = []) -> CInt {
        guard mpv != nil else { return -1 }
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        var cargs = strArgs.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
        let status = mpv_command_async(mpv, replyId, &cargs)
        checkError(status)
        return status
    }

    /// `eventQueue` only. Runs `args` through `mpv_command_ret`, hands the result node to `read`
    /// while it is valid, then frees it. `read` must copy out anything it keeps.
    private func withCommandResult<T>(_ args: [String], _ read: (mpv_node) -> T?) -> T? {
        guard let mpv else { return nil }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p!)) } }
        var result = mpv_node()
        let status = mpv_command_ret(mpv, &cargs, &result)
        guard status >= 0 else { checkError(status); return nil }
        defer { mpv_free_node_contents(&result) }
        return read(result)
    }

    /// `eventQueue` only. `screenshot-raw video [bgr0]`: the decoded frame without subtitles or
    /// OSD, scaled to the store's thumbnail straight from the node's bytes before the node is
    /// freed (P3-F9 hygiene: no 11 MB copy per capture).
    private func screenshotRaw(withFormat: Bool) -> MPVHarvestCapture? {
        let args = withFormat ? ["screenshot-raw", "video", "bgr0"] : ["screenshot-raw", "video"]
        return withCommandResult(args) { node in
            guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list else { return nil }
            var w = 0, h = 0, stride = 0, fmt = "", bytes: UnsafeRawBufferPointer?
            for i in 0..<Int(list.pointee.num) {
                guard let k = list.pointee.keys?[i] else { continue }
                let v = list.pointee.values[i]
                switch String(cString: k) {
                case "w": w = Int(v.u.int64)
                case "h": h = Int(v.u.int64)
                case "stride": stride = Int(v.u.int64)
                case "format": if v.format == MPV_FORMAT_STRING, let s = v.u.string { fmt = String(cString: s) }
                case "data":
                    if v.format == MPV_FORMAT_BYTE_ARRAY, let ba = v.u.ba, let p = ba.pointee.data {
                        // Borrowed: valid only inside this closure (the node is freed after it).
                        bytes = UnsafeRawBufferPointer(start: p, count: ba.pointee.size)
                    }
                default: break
                }
            }
            guard w > 0, h > 0, stride >= w * 4, let bytes, bytes.count >= stride * h else { return nil }
            let thumb = PreviewFrameScaler.makeThumbnail(width: w, height: h, stride: stride, format: fmt, bytes: bytes)
            return MPVHarvestCapture(width: w, height: h, format: fmt, thumb: thumb)
        }
    }

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    private func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
        let str = String(cString: cstr)
        mpv_free(cstr)
        return str
    }

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            print("[MPV] API error: \(String(cString: mpv_error_string(status)))")
        }
    }
}

/// The touch-surface recognisers (scrub pan, swipe down, light tap) see the same strokes together;
/// `ScrubGestureArbiter` decides what each stroke is. Anything else recognises on its own.
extension MPVTVPlayerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let mine: [UIGestureRecognizer?] = [scrubPan, swipeDownRecognizer, lightTapRecognizer]
        return mine.contains { $0 === gestureRecognizer } && mine.contains { $0 === other }
    }
}

private struct MPVPlayerRepresentable: UIViewControllerRepresentable {
    let context: PlaybackContext
    let state: MPVPlaybackState
    let panelModel: PlayerTopPanelModel
    /// Builds the engine-specific fourth tab at open time (its views observe live state).
    let makeExtraTab: () -> PlayerPanelExtraTab
    let onExit: () -> Void
    /// Failover hooks, handed straight to the controller (see its doc comments).
    let onPlaybackFailed: ((PlaybackFailure) -> Void)?
    let onPlaybackHealthy: ((Double) -> Void)?
    let startWatchdogShortened: Bool
    let nativeSecondsPlayedBeforeFallback: Double
    /// B10 (BUG-166): see `MPVTVPlayerViewController.forcesGpuNext`.
    let forcesGpuNext: Bool

    func makeUIViewController(context ctx: Context) -> MPVTVPlayerViewController {
        let controller = MPVTVPlayerViewController(context: context, state: state)
        // Before anything touches `controller.view`: `viewDidLoad` runs `setupMpv`, which reads it.
        controller.forcesGpuNext = forcesGpuNext
        controller.onExit = onExit
        controller.onPlaybackFailed = onPlaybackFailed
        controller.onPlaybackHealthy = onPlaybackHealthy
        controller.startWatchdogShortened = startWatchdogShortened
        controller.nativeSecondsPlayedBeforeFallback = nativeSecondsPlayedBeforeFallback
        let state = state, model = panelModel, makeExtraTab = makeExtraTab
        controller.onOpenPanel = { [weak controller] tab in
            guard let controller, controller.presentedViewController == nil else { return }
            let panel = PlayerPanelHostController(rootView: PlayerTopPanel(model: model, extraTab: makeExtraTab(), initialTab: tab))
            panel.modalPresentationStyle = .overFullScreen
            panel.modalTransitionStyle = .crossDissolve
            model.onClose = { [weak panel] in panel?.close(animated: true) }
            model.onTabChange = { [weak state] in state?.panelTab = $0 }
            panel.onClosed = { [weak state] in
                state?.panelOpen = false
                state?.panelTab = nil
                state?.reclaimFocus?()     // libmpv's controller must be first responder again
            }
            state.panelOpen = true
            state.panelTab = tab
            controller.present(panel, animated: !UIAccessibility.isReduceMotionEnabled)
        }
        return controller
    }

    func updateUIViewController(_ controller: MPVTVPlayerViewController, context: Context) {}
}

/// SwiftUI host for the libmpv player + transport overlay; presented full-screen over the stream
/// picker. When `onPlayNext` is provided and the context carries the series episode list, a
/// next-episode autoplay card appears near the end of playback (`NextEpisodeEngine`).
///
/// NOTE for presenters: when swapping contexts for autoplay, apply `.id(context.id)` so SwiftUI
/// rebuilds this screen (and the libmpv controller) for the new episode.
struct MPVPlayerScreen: View {
    let context: PlaybackContext
    var onPlayNext: ((PlaybackContext) -> Void)? = nil
    /// Phase 1 routing diagnostic (from `PlayerEngineRouter`) surfaced in Stream Info; playback is
    /// unaffected — this screen always renders via libmpv.
    var routingNote: String? = nil
    /// Failover hooks, set by `PlayerScreen` (all unset = today's behaviour). See
    /// `MPVTVPlayerViewController` for when each fires.
    var onPlaybackFailed: ((PlaybackFailure) -> Void)? = nil
    var onPlaybackHealthy: ((Double) -> Void)? = nil
    /// The native engine already failed before start: give this attempt the shortened start budget.
    var startWatchdogShortened = false
    /// Seconds the native engine played before falling back to this screen.
    var nativeSecondsPlayedBeforeFallback: Double = 0
    /// B10 (BUG-166): a Dolby Vision profile 5 stream routed to mpv renders with `gpu-next`
    /// (`EngineDecision.prefersGpuNext`). Read once, when the controller is made.
    var forcesGpuNext = false
    /// P5 B22: set by presenters that can push a Detail page after the player closes; enables the
    /// post-play More Like This row.
    var onOpenTitle: ((MetaPreview) -> Void)? = nil

    @StateObject private var state: MPVPlaybackState
    @StateObject private var upNext: NextEpisodeEngine
    @StateObject private var moreLikeThisLoader = PostPlayMoreLikeThisLoader()
    @Environment(\.dismiss) private var dismiss
    /// `pauseOverlayEnabled` (the shared Pause Info Card setting), read once in `onAppear`.
    @State private var pauseCardEnabled = true
    @StateObject private var panelModel: PlayerTopPanelModel
    @State private var panelAdapter: MPVPlayerPanelAdapter?
    /// P4 B24: Settings › Playback › Loading Screen, read in `init` (critique C17).
    @State private var loadingOverlayOn: Bool

    /// Up-next chip label (the native screen's `UpNextAction` for the same phase); nil = no chip.
    /// The offline card offers Play Next too: D-pad Down starts the deferred search (`playNow`).
    private var upNextChipAction: String? { UpNextAction(phase: upNext.phase)?.title }

    init(context: PlaybackContext, onPlayNext: ((PlaybackContext) -> Void)? = nil, routingNote: String? = nil,
         onPlaybackFailed: ((PlaybackFailure) -> Void)? = nil,
         onPlaybackHealthy: ((Double) -> Void)? = nil,
         startWatchdogShortened: Bool = false,
         nativeSecondsPlayedBeforeFallback: Double = 0,
         forcesGpuNext: Bool = false,
         onOpenTitle: ((MetaPreview) -> Void)? = nil) {
        self.context = context
        self.onOpenTitle = onOpenTitle
        self.onPlayNext = onPlayNext
        self.routingNote = routingNote
        self.forcesGpuNext = forcesGpuNext
        self.onPlaybackFailed = onPlaybackFailed
        self.onPlaybackHealthy = onPlaybackHealthy
        self.startWatchdogShortened = startWatchdogShortened
        self.nativeSecondsPlayedBeforeFallback = nativeSecondsPlayedBeforeFallback
        _loadingOverlayOn = State(initialValue: PlayerLoadingOverlaySetting.enabled)
        let playbackState = MPVPlaybackState(title: context.title)
        _state = StateObject(wrappedValue: playbackState)
        _upNext = StateObject(wrappedValue: NextEpisodeEngine(
            context: context,
            onPlayNext: { [weak playbackState] next in
                // A context swap is underway: the outgoing player must not report a failover.
                guard let onPlayNext else { return }
                playbackState?.playbackFailoverSuppressed = true
                onPlayNext(next)
            }
        ))
        _panelModel = StateObject(wrappedValue: PlayerTopPanelModel(
            info: PlayerPanelInfo(header: NativeInfoHeader(context: context))))
    }

    /// Chip insets: above the pill row while the bar shows, the plain edge padding otherwise.
    private var chipBottomInset: CGFloat {
        if state.scrubCardUp { return PlayerChipStyle.scrubCardBottomInset }   // above the scrub card
        return state.controlsVisible ? PlayerChipStyle.barUpBottomInset : PlayerChipStyle.edgePadding
    }
    private var chipTrailingInset: CGFloat {
        state.controlsVisible ? PlayerChipStyle.barUpTrailingInset : PlayerChipStyle.edgePadding
    }
    private var pauseCardVisible: Bool {
        state.isPaused && !state.controlsVisible && !state.isBuffering && pauseCardEnabled
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MPVPlayerRepresentable(
                context: context, state: state, panelModel: panelModel,
                makeExtraTab: { [state, upNext, onPlayNext, panelModel] in
                    PlayerPanelExtraTab {
                        MPVPlaybackTab(state: state, engine: upNext, canSwitchStreams: onPlayNext != nil,
                                       onClose: { panelModel.onClose?() })
                    }
                },
                onExit: { dismiss() },
                onPlaybackFailed: onPlaybackFailed,
                onPlaybackHealthy: onPlaybackHealthy,
                startWatchdogShortened: startWatchdogShortened,
                nativeSecondsPlayedBeforeFallback: nativeSecondsPlayedBeforeFallback,
                forcesGpuNext: forcesGpuNext
            )
            .ignoresSafeArea()

            // B24: before the start the loading screen says what is happening; this spinner is
            // the mid-play rebuffer only (and the whole startup again with the screen off).
            if state.isBuffering && (state.playbackStarted || !loadingOverlayOn)
                && !(loadingOverlayOn && state.displayModeHolding) {
                ProgressView()
                    .scaleEffect(1.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            PlayerTransportBar(model: state.transport, state: state)

            #if DEBUG
            SeekProbeLabel(probe: state.seekProbe)
            #endif

            PlayerAspectFlashHost(model: state.transport)

            // B24: the loading screen until the first PLAYBACK_RESTART after the resume seek. Above
            // the transport bar, which `viewDidAppear` raises at load: the startup frame is the
            // overlay, not the bar over a black picture. Never on a mid-play rebuffer.
            if loadingOverlayOn && (!state.playbackStarted || state.displayModeHolding) {
                PlayerLoadingOverlay(context: context, stage: state.startupStage)
                    .transition(.opacity)
            }

            // Metadata card after a sustained pause (Android TV PauseOverlay parity).
            // It waits for the bar's fade (0.25 s) before fading in; any press raises the bar,
            // which removes it.
            if pauseCardVisible {
                PauseInfoCard(context: context, positionSec: state.positionSec, durationSec: state.durationSec)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(60)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25).delay(0.25)))
            }

            // Clock (Settings → player.showClock) above the live diagnostics, one trailing stack;
            // the clock fades with the bar.
            let showsClock = state.transport.showsClock
            if showsClock || (state.showStreamInfo && state.streamInfo != nil) {
                VStack(alignment: .trailing, spacing: Theme.Spacing.md) {
                    if showsClock {
                        PlayerTransportClock()
                            .opacity(state.controlsVisible ? 1 : 0)
                            .animation(.easeInOut(duration: 0.25), value: state.controlsVisible)
                    }
                    // Live diagnostics, toggled from the playback-settings panel.
                    if state.showStreamInfo, let info = state.streamInfo {
                        StreamInfoOverlayView(info: info)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(60)
            }

            // Transient prompts, bottom-trailing — same chip family as the native screen's
            // contextual actions (PlayerChipStyle). libmpv owns the remote, so these are drawn
            // non-focusable and fire on D-pad Down (see `pressesBegan`); up-next wins over a skip.
            if let caption = upNext.phase.chipCaption(nextTitle: upNext.nextEpisodeTitle) {
                VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                    PlayerChipCaption(text: caption.text, symbol: caption.symbol, showsProgress: caption.progress)
                    if let action = upNextChipAction {
                        PlayerActionChip(label: action, symbol: PlayerChipStyle.nextSymbol, showsPressHint: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.bottom, chipBottomInset)
                .padding(.trailing, chipTrailingInset)
                .transition(.opacity)
            } else if let prompt = state.skipPrompt {
                PlayerActionChip(label: prompt.label, symbol: PlayerChipStyle.skipSymbol, showsPressHint: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.bottom, chipBottomInset)
                    .padding(.trailing, chipTrailingInset)
                    .transition(.opacity)
            } else if let failure = upNext.sourceSwitchFailure {
                // Batch D review r1: a source switch from the Sources tab that could not start (a
                // ytId source whose resolve failed). One-shot; the engine clears it. Review r2
                // P3-1: anything that carries the D-pad Down action (up-next, then the skip
                // prompt) draws over this caption, which carries none — `pressesBegan` performs
                // the skip whether or not its chip is visible, so the chip must be.
                PlayerChipCaption(text: failure, symbol: "exclamationmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.bottom, chipBottomInset)
                    .padding(.trailing, chipTrailingInset)
                    .transition(.opacity)
            }
        }
        .animation(PlayerChipStyle.animation, value: state.skipPrompt)
        .animation(PlayerChipStyle.animation, value: upNext.phase)
        .animation(PlayerChipStyle.animation, value: upNext.sourceSwitchFailure)
        .animation(PlayerChipStyle.animation, value: state.controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: state.showStreamInfo)
        .animation(.easeInOut(duration: 0.25), value: state.playbackStarted)
        #if DEBUG
        // Every published value (not `onChange`: FILE_LOADED and the first restart often land in
        // one main-thread turn, and `onChange` would only see `started`).
        .onReceive(state.$startupStage) { stage in
            PlayerLoadingHistory.shared.note(stage, contextID: context.id)
        }
        #endif
        .fullScreenCover(
            isPresented: Binding(
                get: { state.isEnded && upNext.phase == .hidden },
                set: { if !$0 { state.isEnded = false } }
            ),
            onDismiss: { state.reclaimFocus?() }
        ) {
            PostPlayView(
                title: context.title,
                poster: context.poster,
                onReplay: { state.replay?() },
                onExit: { dismiss() },
                moreLikeThis: moreLikeThisLoader.items,
                onOpenTitle: onOpenTitle
            )
        }
        .onChange(of: state.playbackStarted) { _, started in
            // P5 B22 review r1 (P3-2): load once playback runs, not while the stream opens.
            if started, onOpenTitle != nil {
                moreLikeThisLoader.load(type: context.contentType, id: context.parentMetaId)
            }
        }
        .onAppear {
            if let routingNote { state.routingNote = routingNote }
            // Transport bar feeds (P1): lockup text, pill row, clock, pause-card setting.
            let header = NativeInfoHeader(context: context)
            state.transport.title = context.title
            state.transport.metaLine = [header.subtitle, context.providerName]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            state.transport.pills = PillKind.visible(
                isSeries: context.contentType == "series", canSwitchStreams: onPlayNext != nil,
                hasEpisodes: !context.episodes.isEmpty)
            state.transport.showsClock = UserDefaults.standard.bool(forKey: PlayerTuning.showClockKey)
            pauseCardEnabled = (PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState)?
                .pauseOverlayEnabled != false
            if panelAdapter == nil {
                panelAdapter = MPVPlayerPanelAdapter(state: state, model: panelModel, context: context)
            }
            // Start the orchestration whenever a presenter can swap contexts — autoplay needs
            // episodes, but source switching works for movies too (the engine no-ops the rest).
            if onPlayNext != nil {
                upNext.start(state: state)
            }
            // libmpv renders into a bare Metal layer, so tvOS doesn't know video is playing and
            // its idle timer fires the screensaver mid-movie (device report). Hold the idle timer
            // while playback is active — mirroring AVPlayerViewController, which does this
            // automatically — and release it on pause (screen protection) and on dismiss.
            UIApplication.shared.isIdleTimerDisabled = !state.isPaused
        }
        .onChange(of: routingNote) { _, note in state.routingNote = note ?? "" }
        .onDisappear {
            upNext.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            // BUG-165: the cover is gone; Menu presses go back to whatever is under it.
            MenuExitShield.shared.disarm(reason: "player screen gone")
        }
        .onChange(of: state.positionSec) { _, position in
            upNext.skipIntervals = state.skipIntervals
            upNext.onProgress(positionSec: position, durationSec: state.durationSec)
        }
        // An offline Up Next card drops to `.hidden` at EOF, so the post-play cover (gated on
        // `.hidden`) can come up even when no tick landed inside the end-of-file slack.
        .onChange(of: state.isEnded) { _, ended in
            if ended { upNext.playbackEnded() }
        }
        .onChange(of: state.isPaused) { _, paused in
            // Paused → let the idle timer run again (a long-paused frame should be allowed to
            // hand off to the screensaver, same as the native player); playing → hold it.
            UIApplication.shared.isIdleTimerDisabled = !paused
        }
    }
}

/// Top-trailing live diagnostics card (codec, resolution, fps, hwdec, bitrate, audio, cache).
private struct StreamInfoOverlayView: View {
    let info: StreamInfoSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stream Info")
                .font(Theme.Font.meta)
                .foregroundStyle(.white.opacity(0.7))
            ForEach(info.rows, id: \.0) { row in
                HStack(alignment: .top, spacing: 12) {
                    Text(row.0)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 190, alignment: .leading)
                    Text(row.1)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                .font(Theme.Font.caption.monospacedDigit())
            }
        }
        .padding(24)
        .frame(maxWidth: 560, alignment: .leading)
        // BUG-180 (Steven rc7): solid player surface, not glass + shadow (see PlayerSurfaceStyle).
        .playerSurface(in: RoundedRectangle(cornerRadius: 14))
    }
}


/// Observes the transport model directly (the screen observes only `MPVPlaybackState`), so the
/// aspect flash appears and fades on its own publishes.
private struct PlayerAspectFlashHost: View {
    @ObservedObject var model: TransportBarModel

    var body: some View {
        ZStack {
            if let text = model.aspectFlash {
                PlayerAspectFlash(text: text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: model.aspectFlash)
    }
}
