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
    /// The swipe-down top panel (Info · Subtitles · Audio · Playback) is presented.
    @Published var panelOpen: Bool = false
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
    /// Engine routing decision from `PlayerEngineRouter`, shown as the Stream Info "Engine" row.
    /// Diagnostic only in Phase 1 — playback still runs through libmpv regardless.
    @Published var routingNote: String = ""

    /// True once playback hit end-of-file (keep-open holds the last frame; drives the post-play cover).
    @Published var isEnded: Bool = false
    /// A swipe scrub is on screen (its preview card): the chips move above it.
    @Published var scrubCardUp = false
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
    /// Crash guard around `screenshot-raw` (review r1 P2 #3); `eventQueue` arms and clears it.
    private let harvestSentinel = HarvestCrashSentinel(store: UserDefaults.standard)
    /// `eventQueue` only: the first real capture of this file flushes the armed flag to disk.
    private var harvestSentinelFlushed = false
    /// One Left/Right click: ±10 s or a chapter jump (`player.edgeClickMode`, read in viewDidLoad).
    private var edgeClickMode: EdgeClickMode = .skip10
    /// Clears the aspect flash 2 s after the last Aspect pill press.
    private var aspectFlashWork: DispatchWorkItem?
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
    private var addedSubtitleUrls = Set<String>()
    private var fileLoaded = false
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
    }
    private let propLock = NSLock()
    private var propSnapshot = PropSnapshot()
    /// Coalesces track-list refresh requests (many property events can arrive in a burst).
    private var trackRefreshPending = false
    /// Uptime when FILE_LOADED fired — drives the first-90s `[MPVStats]` diagnostics.
    private var fileLoadedUptime: TimeInterval = 0
    /// Times playback entered paused-for-cache (buffering underruns), for diagnostics.
    private var cacheWaitCount = 0

    /// Observation ids for mpv_observe_property (arrive back as `reply_userdata`).
    private enum ObservedProp: UInt64 {
        case timePos = 1, duration, pause, coreIdle, pausedForCache, eofReached, trackCount
        case videoW, videoH, aid
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
    private var startWatchdog = MPVStartWatchdog(limitSeconds: MPVStartWatchdog.defaultLimitSeconds)
    private var startWatchdogTimer: Timer?
    /// Main thread: a failure was already reported (every path shares this one-shot).
    private var failoverReported = false
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
        let store = SeekPreviewStore(streamKey: previewKey)
        previewStore = store
        seekPreviewSource = store
        harvest = HarvestScheduler(intervalSec: HarvestScheduler.interval(
            fromSetting: UserDefaults.standard.integer(forKey: "debug.harvestIntervalSec")))
        #if DEBUG
        harvestSynthetic = UserDefaults.standard.bool(forKey: "debug.harvestSynthetic")
        #endif
        // A capture that never returned in an earlier playback turns the harvest off on this
        // device until a value is picked in Settings › Developer (review r1 P2 #3).
        if harvestSentinel.checkAtLaunch() {
            print("[Harvest] disabled: previous capture did not return")
        }
        if harvestSentinel.isDisabled, !harvestSynthetic {
            harvest = HarvestScheduler(intervalSec: 0)
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

        // Chapters (P2-C): the Chapters tab seeks through here; one click on Left/Right follows
        // Settings › Playback › Left/Right Click.
        state.seekToChapter = { [weak self] sec in self?.seekToChapter(sec) }
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
        if !didLoad {
            didLoad = true
            computeResumePosition()
            applyRequestHeaders(context.requestHeaders)
            // Re-assert the audio-language preference on the live handle right before the load —
            // the fallback for a `setupMpv()` that ran before the settings store had hydrated.
            applyAudioLanguagePreferences()
            command("loadfile", args: [context.url.absoluteString, "replace"])
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
                DispatchQueue.main.async { self.state.subtitleSearchInFlight = loading }
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
        print("[Failover] viewWillDisappear isLeavingPlayer=\(isLeavingPlayer)")
        if isLeavingPlayer { closeFailover() }
        gateCoverMenuTap(enabled: true)
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
        if isLeavingPlayer { closeFailover() }
        pollTimer?.invalidate()
        pollTimer = nil
        stopHoldTimer()
        cancelExactStage()
        apply(transport.cancel())
        saveProgress(flush: true)
        stopTraktScrobble()
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
        var videoOutput = "gpu"
        #if !targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: PlayerTuning.enhancedRendererKey) {
            videoOutput = "gpu-next"
        }
        #endif

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
        let count = getInt("track-list/count")
        var audio: [PlayerTrack] = []
        var subs: [PlayerTrack] = [PlayerTrack(id: -1, label: String(localized: "Off"), isSelected: getString("sid") == "no")]
        var audioInfos: [TrackInfo] = []
        var subInfos: [TrackInfo] = []

        for i in 0..<count {
            let type = getString("track-list/\(i)/type") ?? ""
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
            } else {
                subs.append(PlayerTrack(id: id, label: label, isSelected: selected))
                subInfos.append(info)
            }
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
            self.autoSelectPreferredTracks(audioInfos: audioInfos, subInfos: subInfos)
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
    private func autoSelectPreferredTracks(audioInfos: [TrackInfo], subInfos: [TrackInfo]) {
        // `playerSettings` is now seeded synchronously in `setupMpv()`, so this guard can no longer
        // return without latching on the first walk (which used to defer the whole selection to a
        // later track-list change, or to the panel being opened).
        guard !didAutoSelectTracks, let settings = playerSettings, mpv != nil else { return }
        guard !audioInfos.isEmpty || !subInfos.isEmpty else { return }
        didAutoSelectTracks = true

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
        if !didUserSelectAudio, audioInfos.count > 1,
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
        let subTargets = PlayerLanguagePreferencesKt.resolvePreferredSubtitleLanguageTargets(
            preferredSubtitleLanguage: settings.preferredSubtitleLanguage,
            secondaryPreferredSubtitleLanguage: settings.secondaryPreferredSubtitleLanguage,
            deviceLanguages: deviceLanguages
        )
        guard !subInfos.isEmpty,
              let plan = PlayerTrackSelectionKt.resolveSubtitleAutoSelectionPlan(
                  selectedAudioTrack: effectiveAudioTrack,
                  preferredAudioTargets: audioTargets,
                  preferredSubtitleTargets: subTargets,
                  useForcedSubtitles: settings.subtitleStyle.useForcedSubtitles
              )
        else { return }

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
        if match >= 0 {
            let sid = Int64(subInfos[Int(match)].id)
            eventQueue.async { [weak self] in self?.setMpvInt("sid", sid) }
        } else if plan.mode == .forcedOnly {
            // Forced-only plan with no forced track in that language: keep subtitles off.
            eventQueue.async { [weak self] in self?.setMpvString("sid", "no") }
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
        // Audio delay persists the same way (per title/episode, per profile).
        if let storedMs = PlayerTrackPreferenceStorage.shared.loadAudioDelayMs(videoId: context.videoId) {
            setAudioDelay(Double(storedMs.intValue) / 1000.0)
        }
        for sub in context.externalSubtitles {
            subAdd(url: sub.url, title: sub.name ?? sub.language, lang: sub.language)
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
        applyDisplayCriteriaIfEnabled()
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
        // Property reads off-main (this runs at file-load, when the core is busiest), then back
        // to main for the UIWindow / AVDisplayManager application.
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            let fps = self.getDouble("container-fps")
            let width = self.getInt("video-params/w")
            let height = self.getInt("video-params/h")
            let codecName = (self.getString("video-codec") ?? "").lowercased()
            let primaries = (self.getString("video-params/primaries") ?? "").lowercased()
            let gamma = (self.getString("video-params/gamma") ?? "").lowercased()
            DispatchQueue.main.async {
                self.applyDisplayCriteria(
                    fps: fps, width: width, height: height,
                    codecName: codecName, primaries: primaries, gamma: gamma
                )
            }
        }
    }

    private func applyDisplayCriteria(
        fps: Double, width: Int, height: Int, codecName: String, primaries: String, gamma: String
    ) {
        guard fps > 10, let window = view.window else { return }
        guard width > 0, height > 0 else { return }

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
        guard status == noErr, let formatDescription else { return }

        displayCriteriaWindow = window
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(fps),
            formatDescription: formatDescription
        )
    }

    private func clearDisplayCriteria() {
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
        trackerScrobble.stop(positionSec: state.positionSec, durationSec: state.durationSec)
        traktSessionClosed = true
        guard let item = traktScrobbleItem else { return }
        traktScrobbleItem = nil
        // A session can open before a placeholder's short duration is known; close
        // it at 0% so Trakt never marks the stub watched.
        let short = WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(state.durationSec * 1000))
        TraktScrobbleRepository.shared.scrobbleStop(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            item: item,
            progressPercent: short ? 0 : currentProgressPercent()
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
        var added = false
        for sub in kept where !addedSubtitleUrls.contains(sub.url) {
            subAdd(url: sub.url, title: sub.display, lang: sub.language)
            added = true
        }
        if added { refreshTracksAsync() }
    }

    private func subAdd(url: String, title: String, lang: String) {
        guard mpv != nil, !addedSubtitleUrls.contains(url) else { return }
        addedSubtitleUrls.insert(url)
        // Credential leak guard (Codex round 4, P1): with credential-class stream headers set
        // globally on this handle, an in-core `sub-add <http url>` would send them to the
        // subtitle host. Download the file ourselves WITHOUT those headers and hand mpv a local
        // path instead. Only this rare credential case takes the new path — header-free and
        // benign-header (Referer/UA) streams keep the exact in-core behavior below.
        if streamHeadersCarryCredentials,
           let remote = URL(string: url), remote.scheme == "http" || remote.scheme == "https" {
            URLSession.shared.dataTask(with: remote) { [weak self] data, _, error in
                guard let self, let data, error == nil, !data.isEmpty else {
                    NSLog("[MPVPlayer] credential-scoped subtitle fetch failed for %@ — skipping side-load", url)
                    return
                }
                let ext = remote.pathExtension.isEmpty ? "srt" : remote.pathExtension
                let local = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mpv-sub-\(UUID().uuidString).\(ext)")
                do {
                    try data.write(to: local)
                } catch {
                    NSLog("[MPVPlayer] credential-scoped subtitle write failed — skipping side-load")
                    return
                }
                self.eventQueue.async { [weak self] in
                    self?.command("sub-add", args: [local.path, "auto", title, lang])
                }
            }.resume()
            return
        }
        // sub-add downloads/probes the file synchronously inside the core — never on main.
        eventQueue.async { [weak self] in
            self?.command("sub-add", args: [url, "auto", title, lang])
        }
    }

    private func selectSubtitle(_ id: Int) {
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

    private func setAudioDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        setMpvDouble("audio-delay", seconds)
        state.audioDelaySec = seconds
        PlayerTrackPreferenceStorage.shared.saveAudioDelayMs(videoId: context.videoId, delayMs: Int32((seconds * 1000).rounded()))
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
        if vbr > 0 { info.videoBitrate = String(format: "%.1f Mbps", vbr / 1_000_000) }
        let audioCodec = getString("audio-codec-name") ?? ""
        let channels = getInt("audio-params/channel-count")
        let sampleRate = getInt("audio-params/samplerate")
        var audioParts = [audioCodec]
        if channels > 0 { audioParts.append("\(channels)ch") }
        if sampleRate > 0 { audioParts.append("\(sampleRate / 1000) kHz") }
        info.audio = audioParts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        var cacheParts: [String] = []
        let cacheSec = getDouble("demuxer-cache-duration")
        if cacheSec > 0 { cacheParts.append(String(format: "%.0fs buffered", cacheSec)) }
        let cacheSpeed = getDouble("cache-speed")
        if cacheSpeed > 0 { cacheParts.append(String(format: "%.1f MB/s", cacheSpeed / 1_000_000)) }
        info.cache = cacheParts.joined(separator: " \u{00B7} ")
        return info
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
        lastSourceUrl: context.url.absoluteString
    )

    private func saveProgress(flush: Bool = false) {
        guard mpv != nil else { return }
        let duration = state.durationSec
        let position = state.positionSec
        guard duration > 0, position > 1 else { return }

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

        state.durationSec = snap.duration
        state.positionSec = max(snap.position, 0)
        // Paused → playing without input (the pause-card-off rule left no hide timer armed):
        // re-arm the hide so the bar does not stay up until the next press.
        if state.isPaused && !snap.paused && state.controlsVisible { scheduleHide() }
        state.isPaused = snap.paused
        state.isBuffering = snap.cacheWait || (snap.coreIdle && !snap.paused)
        samplePlayClock(snap)

        // Seek preview harvest (P2-B): playback time only, never while the transport moves.
        let harvestNow = ProcessInfo.processInfo.systemUptime
        if harvest.tick(now: harvestNow,
                        playing: fileLoaded && !snap.paused && !snap.cacheWait && !snap.coreIdle && !snap.eof && snap.videoW > 0,
                        transportIdle: !transport.mode.isActive,
                        seekInFlight: skipPlanner.seekInFlight != nil,
                        recentInput: harvestNow - lastClickUptime < HarvestScheduler.recentInputSec) {
            startHarvest()
        }

        // Transport bar mirror + preview model inputs (P1).
        transport.durationSec = snap.duration
        state.transport.durationSec = snap.duration
        // A chapter list read before the duration was known drops its end markers once it is
        // (review r1 P2 #2); a no-op whenever nothing is past the end.
        if snap.duration > 0, let last = state.transport.chapters.last,
           last.sec >= snap.duration - PlayerChapters.endSlackSec {
            state.transport.chapters = PlayerChapters.trimmed(state.transport.chapters, durationSec: snap.duration)
        }
        state.transport.positionSec = max(snap.position, 0)
        state.transport.isPaused = snap.paused
        state.transport.playbackSpeed = state.playbackSpeed
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

        if state.showStreamInfo || state.panelOpen {
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
        guard elapsed < 90 else { return }
        let underruns = cacheWaitCount
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            let cacheSec = self.getDouble("demuxer-cache-duration")
            let cacheSpeed = self.getDouble("cache-speed")
            let voDropped = self.getInt("frame-drop-count")
            let decDropped = self.getInt("decoder-frame-drop-count")
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
            let frame = self.captureHarvestFrame()
            let tookMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            #if DEBUG
            NSLog("%@", String(format: "[Harvest] took=%.1fms size=%dx%d fmt=%@ at=%.1f src=%@", tookMs,
                               frame?.width ?? 0, frame?.height ?? 0, frame?.format ?? "-", sec,
                               self.harvestSynthetic ? "synthetic" : "mpv"))
            #endif
            // Strong hop to main (critique C13, the `refreshBufferedAsync` shape): `deinit` can
            // never run on `eventQueue`.
            DispatchQueue.main.async { self.harvestCaptured(frame, at: sec, tookMs: tookMs) }
        }
    }

    /// `eventQueue` only. `screenshot-raw video bgr0`; if this mpv rejects the format argument,
    /// retries once without it (the default is `bgr0`) and keeps that form for the session.
    private func captureHarvestFrame() -> MPVRawFrame? {
        if harvestSynthetic { return Self.syntheticHarvestFrame(at: getDouble("time-pos")) }
        #if targetEnvironment(simulator)
        return nil
        #else
        // Armed for the length of the native call: if it takes the process down, the next player
        // open finds the flag still set and turns the harvest off (review r1 P2 #3).
        harvestSentinel.arm()
        if !harvestSentinelFlushed {
            harvestSentinelFlushed = true
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        }
        defer { harvestSentinel.clear() }
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
        #endif
    }

    /// A 640 × 360 `bgr0` frame whose grey level follows `sec` (DEBUG plumbing tests only).
    private static func syntheticHarvestFrame(at sec: Double) -> MPVRawFrame {
        let w = 640, h = 360, stride = w * 4
        let level = UInt8(truncatingIfNeeded: Int(sec.isFinite ? sec : 0) * 4)
        return MPVRawFrame(width: w, height: h, stride: stride, format: "bgr0",
                           bytes: Data(repeating: level, count: stride * h))
    }

    /// Main. The mpv side is done: free the scheduler, then scale + encode + insert on a utility
    /// queue that carries only the frame bytes, the store and the (main-actor) state object.
    private func harvestCaptured(_ frame: MPVRawFrame?, at sec: Double, tookMs: Double) {
        if harvest.noteFinished(tookMs: frame == nil ? nil : tookMs) {
            #if DEBUG
            NSLog("%@", String(format: "[Harvest] slow (%.1fms > %.0fms): interval now %.0fs for this file",
                               tookMs, HarvestScheduler.slowHarvestMs, harvest.intervalSec))
            #endif
        }
        guard let frame, sec.isFinite, let store = previewStore else { return }
        // Built on main; the utility work holds this closure, never the controller.
        let publish: @MainActor @Sendable (Int, Int, Int) -> Void = { [weak state = self.state] n, bytes, rss in
            guard let state else { return }
            state.transport.previewFrames = n
            let mb = "\(n) · \(String(format: "%.1f", Double(bytes) / 1_048_576)) MB"
            #if DEBUG
            state.previewStoreSummary = mb + " · RSS \(rss) MB"   // jargon: debug builds only (review r1 P3 #9)
            #else
            state.previewStoreSummary = mb
            #endif
            #if DEBUG
            NSLog("%@", "[Harvest] stored n=\(n) bytes=\(bytes) rss=\(rss)MB")
            #endif
        }
        DispatchQueue.global(qos: .utility).async {
            guard let thumb = PreviewFrameScaler.makeThumbnail(frame) else {
                #if DEBUG
                NSLog("%@", "[Harvest] unsupported frame format \(frame.format)")
                #endif
                return
            }
            Task {
                await store.insert(thumb, at: sec)
                let n = await store.count
                let bytes = await store.byteCount
                await publish(n, bytes, ProcessMemory.footprintMB())
            }
        }
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
                switch action {
                case .panel:
                    break           // the panel host closes itself; never reaches here in practice
                case .exit:
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
        let duration = getDouble("duration")
        let parsed = chapters.count
        chapters = PlayerChapters.trimmed(chapters, durationSec: duration)
        #if DEBUG
        NSLog("[Chapters] n=%ld dropped=%ld dur=%.1f src=%@ raw=%@", chapters.count, parsed - chapters.count,
              duration, source, String((raw ?? "nil").prefix(200)))
        #else
        _ = parsed
        #endif
        DispatchQueue.main.async { self.state.transport.chapters = chapters }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
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
                let image = await source.thumbnail(near: target)
                // A scrub that ended (or a newer one) bumped the token: drop the late frame, and
                // do not touch the reset throttle.
                guard let self, self.previewFrameToken == token else { return }
                self.state.transport.previewFrame = image
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

    private func seekAbsolute(_ seconds: Double, kind: SkipSegmentPlanner.SeekKind) {
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
        if reportPlaybackFailure(
            reason: "stream ended early at \(Int(snap.position))/\(Int(snap.duration)) s",
            startedPlaying: true, secondsPlayed: played, positionSec: snap.position) {
            return true
        }
        return failoverReported
    }

    /// The single exit for every failover signal. Returns true when the host was told.
    @discardableResult
    private func reportPlaybackFailure(reason: String, startedPlaying: Bool, secondsPlayed: Double,
                                       positionSec: Double? = nil) -> Bool {
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
        print("[Failover] mpv failure: \(reason) pos=\(Int(position)) played=\(Int(secondsPlayed)) started=\(startedPlaying)")
        onPlaybackFailed(PlaybackFailure(reason: reason, positionSec: position,
                                         secondsPlayed: secondsPlayed, startedPlaying: startedPlaying))
        return true
    }

    /// (a) `MPV_END_FILE_REASON_ERROR`: mpv could not open or keep decoding the stream.
    private func reportEndFileError(_ message: String) {
        reportPlaybackFailure(reason: "mpv: \(message)", startedPlaying: failoverLoadedUptime != nil,
                              secondsPlayed: failoverSecondsPlayed)
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
                                  startedPlaying: false, secondsPlayed: 0)
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
        reportPlaybackFailure(reason: "placeholder clip (\(seconds)s)", startedPlaying: true, secondsPlayed: 0)
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
        guard let ctx = mpv else { return }
        mpv = nil
        // mpv invokes the wakeup callback under the lock this call takes, so once it returns no
        // callback is running and none can start: shutdown's last wakeup never reaches the relay
        // (and the relay already turns one that slips in earlier into a no-op).
        mpv_set_wakeup_callback(ctx, nil, nil)
        mpv_terminate_destroy(ctx)
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
                    self.applyPendingResume(actualDurationSec: loadedDuration)
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
            if id == MPV_EVENT_END_FILE, let data = ev.pointee.data {
                let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                if endFile.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(endFile.error))
                    print("[MPV] End file error: \(message)")
                    // This block runs on `eventQueue`; the report is a main-thread affair.
                    DispatchQueue.main.async { [weak self] in
                        self?.reportEndFileError(message)
                    }
                }
            }
            if id == MPV_EVENT_LOG_MESSAGE,
               let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(ev.pointee.data)) {
                let level = String(cString: msg.pointee.level!)
                let text = String(cString: msg.pointee.text!)
                print("[MPV] \(level): \(text)", terminator: "")
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
            refreshTracksAsync()
        case .videoW:
            if let v = asInt() { updateProps { $0.videoW = v } }
        case .videoH:
            if let v = asInt() { updateProps { $0.videoH = v } }
        case .aid:
            if let v = asInt() { alangTrace("aid changed -> \(v)") }
        }
    }

    /// THE resume seek (user-initiated for skip logic: an intro interval this lands inside must
    /// not be auto-skipped). Sets `didResumeSeek` so later code can identify it.
    private func applyPendingResume(actualDurationSec: Double) {
        if let seconds = pendingResumeSec {
            pendingResumeSec = nil
            didResumeSeek = true
            seekAbsolute(seconds, kind: .resume)
            return
        }
        guard let entry = pendingResumeEntry else { return }
        pendingResumeEntry = nil
        if actualDurationSec > 0 {
            let seconds = Double(entry.resolveResumePosition(actualDurationMs: Int64(actualDurationSec * 1000))) / 1000.0
            guard seconds > 10 else { return }
            didResumeSeek = true
            seekAbsolute(seconds, kind: .resume)
        } else {
            // Duration unknown (some HLS): let mpv resolve the percentage itself.
            let pct = Double(entry.progressFraction) * 100
            guard pct > 0 else { return }
            didResumeSeek = true
            issueSeek(kind: .resume, targetSec: nil, args: [String(format: "%.3f", pct), "absolute-percent"])
        }
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
    /// OSD, copied out of the node.
    private func screenshotRaw(withFormat: Bool) -> MPVRawFrame? {
        let args = withFormat ? ["screenshot-raw", "video", "bgr0"] : ["screenshot-raw", "video"]
        return withCommandResult(args) { node in
            guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list else { return nil }
            var w = 0, h = 0, stride = 0, fmt = "", bytes: Data?
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
                        bytes = Data(bytes: p, count: ba.pointee.size)
                    }
                default: break
                }
            }
            guard w > 0, h > 0, stride >= w * 4, let bytes, bytes.count >= stride * h else { return nil }
            return MPVRawFrame(width: w, height: h, stride: stride, format: fmt, bytes: bytes)
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

    func makeUIViewController(context ctx: Context) -> MPVTVPlayerViewController {
        let controller = MPVTVPlayerViewController(context: context, state: state)
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
            panel.onClosed = { [weak state] in
                state?.panelOpen = false
                state?.reclaimFocus?()     // libmpv's controller must be first responder again
            }
            state.panelOpen = true
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

    @StateObject private var state: MPVPlaybackState
    @StateObject private var upNext: NextEpisodeEngine
    @Environment(\.dismiss) private var dismiss
    /// `pauseOverlayEnabled` (the shared Pause Info Card setting), read once in `onAppear`.
    @State private var pauseCardEnabled = true
    @StateObject private var panelModel: PlayerTopPanelModel
    @State private var panelAdapter: MPVPlayerPanelAdapter?

    /// Up-next chip label (mirrors the native screen's `UpNextAction` titles); nil = no chip.
    private var upNextChipAction: String? {
        switch upNext.phase {
        case .counting: return UpNextAction.playNext.title
        case .stillWatching: return UpNextAction.continueWatching.title
        default: return nil
        }
    }

    init(context: PlaybackContext, onPlayNext: ((PlaybackContext) -> Void)? = nil, routingNote: String? = nil,
         onPlaybackFailed: ((PlaybackFailure) -> Void)? = nil,
         onPlaybackHealthy: ((Double) -> Void)? = nil,
         startWatchdogShortened: Bool = false,
         nativeSecondsPlayedBeforeFallback: Double = 0) {
        self.context = context
        self.onPlayNext = onPlayNext
        self.routingNote = routingNote
        self.onPlaybackFailed = onPlaybackFailed
        self.onPlaybackHealthy = onPlaybackHealthy
        self.startWatchdogShortened = startWatchdogShortened
        self.nativeSecondsPlayedBeforeFallback = nativeSecondsPlayedBeforeFallback
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
                nativeSecondsPlayedBeforeFallback: nativeSecondsPlayedBeforeFallback
            )
            .ignoresSafeArea()

            if state.isBuffering {
                ProgressView()
                    .scaleEffect(1.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            PlayerTransportBar(model: state.transport, state: state)

            #if DEBUG
            SeekProbeLabel(probe: state.seekProbe)
            #endif

            PlayerAspectFlashHost(model: state.transport)

            // Metadata card after a sustained pause (Android TV PauseOverlay parity).
            // It waits for the bar's fade (0.25 s) before fading in; any press raises the bar,
            // which removes it.
            if pauseCardVisible {
                PauseInfoCard(context: context, state: state)
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
            }
        }
        .animation(PlayerChipStyle.animation, value: state.skipPrompt)
        .animation(PlayerChipStyle.animation, value: upNext.phase)
        .animation(PlayerChipStyle.animation, value: state.controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: state.showStreamInfo)
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
                onExit: { dismiss() }
            )
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
        }
        .onChange(of: state.positionSec) { _, position in
            upNext.skipIntervals = state.skipIntervals
            upNext.onProgress(positionSec: position, durationSec: state.durationSec)
        }
        .onChange(of: state.isPaused) { _, paused in
            // Paused → let the idle timer run again (a long-paused frame should be allowed to
            // hand off to the screensaver, same as the native player); playing → hold it.
            UIApplication.shared.isIdleTimerDisabled = !paused
        }
    }
}

/// Post-play screen shown when playback reaches the end without an autoplay hand-off
/// (Android TV `PostPlayOverlay` parity, simplified): replay or exit.
private struct PostPlayView: View {
    let title: String
    let poster: String?
    let onReplay: () -> Void
    let onExit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(alignment: .center, spacing: 48) {
                if let poster, !poster.isEmpty {
                    CachedAsyncImage(string: poster)
                        .frame(width: 260, height: 390)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 24) {
                    Text("That's the end of")
                        .font(Theme.Font.screenTitle.weight(.regular))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(title)
                        .font(Theme.Font.hero)
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .frame(maxWidth: 800, alignment: .leading)

                    Button {
                        dismiss()
                        onReplay()
                    } label: {
                        Label("Play Again", systemImage: "arrow.counterclockwise")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        // Dismissing the player screen tears the cover down with it —
                        // don't also dismiss the cover (competing transitions).
                        onExit()
                    } label: {
                        Label("Back to Details", systemImage: "chevron.backward")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(80)
        }
    }
}

/// Metadata card shown top-leading after playback has been paused for a moment: artwork, title,
/// episode line, stream/source info, and time remaining (Android TV `PauseOverlay` parity).
private struct PauseInfoCard: View {
    let context: PlaybackContext
    @ObservedObject var state: MPVPlaybackState

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            if let poster = context.poster, !poster.isEmpty {
                CachedAsyncImage(string: poster)
                    .frame(width: 140, height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Paused")
                    .font(Theme.Font.meta)
                    .foregroundStyle(.white.opacity(0.7))
                Text(context.title)
                    .font(Theme.Font.screenTitle)
                    .lineLimit(2)
                if let season = context.season, let episode = context.episode {
                    Text("Season \(season) \u{00B7} Episode \(episode)")
                        .font(Theme.Font.body)
                        .foregroundStyle(.white.opacity(0.85))
                }
                if state.durationSec > 0 {
                    Text("\(remainingString) remaining")
                        .font(Theme.Font.body).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }
                if let provider = context.providerName, !provider.isEmpty {
                    Text(provider)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: 860, alignment: .leading)
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private var remainingString: String {
        let total = Int(max(state.durationSec - state.positionSec, 0))
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
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
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
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
