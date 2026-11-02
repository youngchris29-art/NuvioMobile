import UIKit

// Aether Phase 1, W2-B: the seam between the Siri-remote transport (presses, hold/step/scan, swipe
// scrub, preview, commit, Menu precedence, bar hide) and the engine that plays. The mpv controller
// conforms to both protocols (`MPVPlayerView.swift`, bottom); each member is a thin wrapper over
// the code that already ran there, so mpv sees the same commands, on the same queue, in the same
// order.

/// How a transport seek lands. mpv maps each to its `seek` flags; Aether to `seek(toSec:exact:)`.
nonisolated enum TransportSeekMode: Equatable, Sendable {
    /// mpv "relative" (one Left/Right click): `deltaSec` from wherever mpv is.
    case relative(deltaSec: Double)
    /// mpv "absolute" (chapter, chip, auto-skip, replay).
    case absolute
    /// mpv "absolute+keyframes": the first stage of a two-stage commit.
    case absoluteKeyframes
    /// mpv "absolute+exact": the second stage, a cached commit, a scan return.
    case absoluteExact
}

/// The playback operations the shared remote implementation needs. Main thread only; every read
/// is a cached value (never a synchronous engine query: the BUG-2/BUG-3 rule).
protocol PlayerTransportEngine: AnyObject {
    /// The engine has a live handle (mpv: `mpv != nil`).
    var canTransport: Bool { get }
    /// The media has loaded (mpv: `MPV_EVENT_FILE_LOADED` seen).
    var mediaLoaded: Bool { get }
    var transportPositionSec: Double { get }
    var transportDurationSec: Double { get }
    var transportIsPaused: Bool { get }

    /// The generation the last seek got; the next `issueSeek` returns this plus one.
    var seekGeneration: Int { get }
    /// The engine's seek funnel: tells the skip planner first (unless `planner` is false), bumps
    /// and returns the generation, runs the seek off-main, calls `onRejected` on main if refused.
    @discardableResult
    func issueSeek(kind: SkipSegmentPlanner.SeekKind, targetSec: Double?, fromSec: Double?,
                   mode: TransportSeekMode, planner: Bool, onRejected: (() -> Void)?) -> Int
    /// Runs `body` on main once seek `generation` has started (mpv: MPV_EVENT_SEEK); on the next
    /// main turn when it already has. The two-stage commit's exact stage waits on this.
    func whenSeekStarted(generation: Int, _ body: @escaping () -> Void)

    /// A seek the skip planner tracks is in flight (its target may be unknown).
    var hasSeekInFlight: Bool { get }
    /// That seek's target, nil when none is in flight or its target is unknown.
    var seekInFlightTargetSec: Double? { get }
    /// `SkipSegmentPlanner.noteInput`: true when the press revealed an auto-hidden chip.
    func noteTransportInput(now: TimeInterval) -> Bool
    /// Re-evaluates the skip chip from the cached position (a press revealed it).
    func refreshSkipPrompt()
    func refineSkipSeek(targetSec: Double, fromSec: Double, now: TimeInterval)
    func recordUserSpan(fromSec: Double, toSec: Double)

    func togglePause()
    /// Scan starts: mute, pitch correction off, `rate`x.
    func beginScan(rate: Int)
    func setScanRate(_ rate: Int)
    /// Scan ends: the user's speed back, mute and pitch correction as they were.
    func endScan(restoreSpeed: Double)
    func cycleAspect()

    var seekPreviewSource: SeekPreviewSource? { get }
    /// A scrub ended: the engine's own preview work for it stops (mpv: the keyframe thumbnailer).
    func scrubPreviewEnded(now: TimeInterval)
    /// A scrub lookup found no frame near `targetSec` (or one too far off).
    func scrubPreviewMissed(targetSec: Double, matchSec: Double?)
}

/// The UIKit side the transport needs from the controller that owns it.
protocol PlayerTransportHost: UIViewController {
    /// Settings › Pause Info Card (the paused bar-hide rule reads it).
    var pauseCardEnabled: Bool { get }
    /// For the `[MenuProbe]` lines only.
    var isLeavingPlayerForLog: Bool { get }
    /// Walk the tracks before a popover or shelf opens.
    func prepareTracksForPanel()
    /// Menu exit: close failover reporting, then leave the player.
    func exitPlayer()
}

/// One shared Siri-remote transport (presses, hold/step/scan, swipe scrub, preview, commit, Menu
/// precedence, bar hide, the text pills and their popovers/shelves). Owned strongly by the
/// controller for its whole life; the controller forwards its `presses*` overrides, lifecycle
/// points and the few reads its own ticks need. Main thread only.
final class PlayerTransportInput: NSObject, UIGestureRecognizerDelegate {
    private let state: MPVPlaybackState
    /// The controller that owns this input (both roles are the same object today). Weak: a timer
    /// that outlived the controller must find nil, never trap; nil only while that controller
    /// deinitialises, when nothing here runs but `invalidate()`.
    private weak var engine: PlayerTransportEngine?
    private weak var host: PlayerTransportHost?

    private var hideWork: DispatchWorkItem?
    // Preview-then-commit transport (P1): held Left/Right move a preview, one commit on release.
    private var transport = TransportPreview()
    private var holdTimer: Timer?
    private var holdStartUptime: TimeInterval = 0       // uptime of the press that started the current hold
    private var pendingExact: (generation: Int, request: TransportPreview.CommitRequest, deadline: DispatchWorkItem)?
    private var exactWork: DispatchWorkItem?
    private var commitLandWork: DispatchWorkItem?       // 1.5 s fallback for noteCommitLanded()
    private var commitGeneration: Int?                  // generation of the last commit's first stage
    private var scanRestoreSpeed: Double?               // main: the user's speed when the scan started
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
    /// One Left/Right click: ±10 s or a chapter jump (`player.edgeClickMode`, read in viewDidLoad).
    private var edgeClickMode: EdgeClickMode = .skip10
    /// Last edge-to-edge panel opened by a gesture (the swipe recogniser and the arbiter both fire).
    private var lastGesturePanelUptime: TimeInterval = 0
    /// Set when a Menu press was consumed by the up-next dismiss so the matching release is
    /// swallowed too — nothing above sees a half press.
    private var swallowMenuRelease = false
    /// A consumed Menu's action, performed when the press ends (never while it is down).
    private var pendingMenuAction: MenuPrecedence.Action?
    /// Bumped by every overlay focus request; a retry chain from an older request stops.
    private var overlayFocusGeneration = 0
    /// BUG-165: when the exit Menu was decided (`systemUptime`), for the `[MenuProbe]` timing lines
    /// that say where the press's later phases and the cover's teardown land relative to it.
    private var exitDecidedAt: TimeInterval?
    func sinceExitMs() -> Int {
        exitDecidedAt.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? -1
    }
    /// `systemUptime` of the last press of any button beginning, ending or being cancelled: a click
    /// (arrows included) is also a touch, so the light-tap recogniser ignores a tap within 0.5 s of
    /// one (`LightTapGuard`).
    private(set) var lastClickUptime: TimeInterval = 0
    /// Presses currently down (began, not yet ended or cancelled): no light tap while any is.
    private var pressesDown = Set<ObjectIdentifier>()
    private var endTimeWork: DispatchWorkItem?
    #if DEBUG
    /// Block token for the DEBUG light-tap notification; removed in `invalidate()` (the controller's
    /// `destroyPlayer`), never a `deinit`.
    private var lightTapObserver: NSObjectProtocol?
    /// Block token for the DEBUG scrub-inject notification; removed in `invalidate()`.
    private var scrubInjectObserver: NSObjectProtocol?
    private var scrubInjectTimer: Timer?
    #endif

    /// Created in the controller's `viewDidLoad`, where the state wiring and the transport tuning
    /// below always ran. Reads the DEBUG tuning keys and the hold / Left-Right Click settings.
    init(state: MPVPlaybackState, engine: PlayerTransportEngine, host: PlayerTransportHost) {
        self.state = state
        self.engine = engine
        self.host = host
        let tick = UserDefaults.standard.double(forKey: "debug.holdTickSec")
        self.holdTickSec = tick > 0 ? tick : TransportPreview.defaultTickSec
        let exactMs = UserDefaults.standard.integer(forKey: "debug.commitExactDelayMs")
        self.commitExactDelaySec = exactMs == 0 ? 0.15 : (exactMs < 0 ? -1 : Double(exactMs) / 1000)
        self.scrubCurve = ScrubRateCurve.fromSetting(UserDefaults.standard.string(forKey: "debug.scrubCurve"))
        let scrubScale = UserDefaults.standard.double(forKey: "debug.scrubRateScale")
        self.scrubRateScale = scrubScale > 0 ? scrubScale : 1
        super.init()

        state.overlayMenu = { [weak self] in self?.handleOverlayMenu() }
        // Every `state.closeOverlay` caller closes because of a pick inside the overlay (or its
        // pill leaving the row): back to the track.
        state.closeOverlay = { [weak self] in self?.closeOverlay(.selection) }
        state.requestOverlayFocus = { [weak self] in self?.requestOverlayFocus() }
        state.togglePause = { [weak self] in self?.engine?.togglePause(); self?.flashControls() }

        transport.holdMode = TransportPreview.HoldMode(
            rawValue: UserDefaults.standard.string(forKey: PlayerTuning.holdModeKey) ?? "step") ?? .step
        let ramp = UserDefaults.standard.double(forKey: "debug.holdRampScale")
        transport.rampScale = ramp > 0 ? ramp : 1
        transport.scrubCurve = scrubCurve
        transport.scrubRateScale = scrubRateScale
        state.transport.scrubCurveCode = scrubCurve.probeCode

        // Chapters (P2-C): the Chapters tab seeks through here; one click on Left/Right follows
        // Settings › Playback › Left/Right Click.
        state.seekToChapter = { [weak self] sec in self?.seekToChapter(sec) }
        edgeClickMode = EdgeClickMode(
            rawValue: UserDefaults.standard.string(forKey: PlayerTuning.edgeClickModeKey) ?? "skip10") ?? .skip10
    }

    // MARK: - Reads and calls for the owning controller

    var mode: TransportPreview.Mode { transport.mode }

    /// Presses begun before a panel or cover took over never end here: dropped so the light tap is
    /// not blocked for the rest of the session.
    func resetPressesDown() {
        pressesDown.removeAll()
    }

    /// The controller's poll tick: the preview model's duration.
    func noteDuration(_ sec: Double) {
        if transport.durationSec != sec { transport.durationSec = sec }
    }

    /// The controller's poll tick while a scan runs: the end of the file ends it in place; else
    /// the preview follows the live position.
    func noteScanTick(positionSec: Double, eof: Bool) {
        if case .scanning = transport.mode {
            if eof { apply(transport.endScanInPlace()) }
            else {
                transport.noteLivePosition(positionSec)
                state.transport.previewSec = transport.previewSec
            }
        }
    }

    /// The engine's merged seekable ranges (the commit's single-stage "cached" rule reads them).
    func setSeekableRanges(_ ranges: [BufferedRange]) {
        transport.seekableRanges = ranges
    }

    /// A seek landed (mpv: its PLAYBACK_RESTART, before the newest-seek guard). The preview
    /// playhead hands back to the real position on a commit's first landing, whether or not the
    /// planner guard after this passes.
    func seekLandedForCommit(generation: Int) {
        if generation == commitGeneration {
            commitGeneration = nil
            commitLandWork?.cancel()
            transport.noteCommitLanded()
            state.transport.previewSec = transport.previewSec
        }
    }

    /// The newest seek landed (after the skip planner heard it): keyframes landed, so that picture
    /// shows first, then the exact stage runs.
    func seekLandedForExact(generation: Int) {
        if let p = pendingExact, p.generation == generation {
            scheduleExact(after: commitExactDelaySec)
        }
    }

    /// The controller's `viewDidDisappear`: no hold, no exact stage, no preview left running.
    func viewDidDisappear() {
        stopHoldTimer()
        cancelExactStage()
        apply(transport.cancel())
    }

    /// The controller's `deinit` and `destroyPlayer`: every timer and work item this input armed.
    /// Plain property writes (no weak reference formed while the controller deinitialises).
    func invalidate() {
        holdTimer?.invalidate()
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
    }

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
        case .unfocusInfoPill:
            // Insights device pass (2026-11-01): a focused text pill only lets go of the focus;
            // the bar stays (back on the track), the next Menu hides it, the one after exits.
            state.transport.focusedInfoPill = nil
            flashControls()
        case .actorBack:
            // Insights: the Cast actor view backs out to the card row; the shelf stays.
            _ = state.panelModel?.menuBack()
        case .closeOverlay:
            closeOverlay()
        case .panel, .exit:
            break
        }
    }

    /// The Menu decision for the player as it stands (both the controller's press path and the
    /// SwiftUI overlay's `onExitCommand` ask here).
    private func currentMenuAction() -> MenuPrecedence.Action {
        let t = state.transport
        return MenuPrecedence.resolve(
            // A presented controller takes its own presses.
            panelOpen: host?.presentedViewController != nil,
            actorViewOpen: t.openInfoPill == .cast && state.panelModel?.actorView != nil,
            overlayOpen: t.overlayOpen,
            modeActive: transport.mode.isActive,
            upNextShowing: state.upNextVisible?() ?? false,
            pillFocused: t.focusedPill != nil,
            infoPillFocused: t.focusedInfoPill != nil,
            barUp: state.controlsVisible)
    }

    /// Menu with focus inside a popover or shelf (SwiftUI `onExitCommand`). Only the overlay levels
    /// act here; anything else means the overlay was already gone, and the press is dropped.
    private func handleOverlayMenu() {
        let action = currentMenuAction()
        NSLog("[MenuProbe] overlay menu action=%@", String(describing: action))
        switch action {
        case .actorBack:
            _ = state.panelModel?.menuBack()
        case .closeOverlay:
            closeOverlay()
            // Focus is back with this controller now: if the press's release lands here, it is
            // swallowed like every consumed Menu (a stale flag only swallows a release whose press
            // began elsewhere; every Menu press sets it afresh).
            swallowMenuRelease = true
        default:
            break
        }
    }

    // MARK: - Touch surface

    /// The controller's `viewDidLoad`, at the point the recognisers were always added: swipe down,
    /// light tap and the scrub pan, this input their target and delegate.
    func installGestures(on view: UIView) {
        // Touch-surface swipe down → the text pill row (presses arrive as `.downArrow`; real swipes don't).
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
    }

    @objc private func handleSwipeDown() {
        // A scrub stroke that drifts down must not move the focus.
        guard scrubArbiter.intent != .horizontal else { return }
        focusInfoPillsFromGesture()
    }

    /// The one down-gesture handler: the swipe recogniser and the arbiter's vertical-down both
    /// land here, deduped within 0.6 s. Same as Down with nothing else to do: the bar comes up with
    /// the text pill row focused (Insights; it opened the top panel before).
    private func focusInfoPillsFromGesture() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let host, host.presentedViewController == nil, !state.transport.overlayOpen,
              now - lastGesturePanelUptime > 0.6 else { return }
        lastGesturePanelUptime = now
        cancelExactStage()
        stopHoldTimer()
        cancelScrub(why: "pills")
        apply(transport.cancel())
        focusInfoPills()
    }

    @objc private func handleLightTap() { performLightTap(force: false) }

    /// Light tap: ignored right after a click; hidden bar → raise it; bar up → flip the right label
    /// between remaining time and end time (4 s, then back). `force` skips the click guard (the
    /// DEBUG notification has no preceding click).
    private func performLightTap(force: Bool) {
        if isScrubbing { return }           // a tap does nothing to a scrub
        if !force, !LightTapGuard.allows(now: ProcessInfo.processInfo.systemUptime,
                                         lastPressUptime: lastClickUptime, pressesDown: pressesDown.count) { return }
        guard let host, host.presentedViewController == nil else { return }
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

    #if DEBUG
    func updateSeekProbe(paused: Bool? = nil) {
        state.seekProbe.modeName = transport.mode.probeName
        state.seekProbe.pos = state.positionSec
        if let paused { state.seekProbe.paused = paused }
    }
    #endif

    // MARK: - Siri-remote transport

    /// The controller's `pressesBegan`: true when the press was handled; false = the controller
    /// passes it to `super`.
    func pressesBegan(_ presses: Set<UIPress>) -> Bool {
        guard let engine, let host else { return false }
        var handled = false
        lastClickUptime = ProcessInfo.processInfo.systemUptime
        for press in presses { pressesDown.insert(ObjectIdentifier(press)) }
        scrubArbiter.pressBegan()
        // A press brings an auto-hidden skip chip back for another 10 s (the press still acts,
        // except a Down that revealed the chip: that one only reveals it, the next Down skips).
        // Left/Right seek: the chip comes back on the tick after the seek lands, not now (an
        // immediate publish would flash it for one tick while the seek is in flight).
        let chipRevealed = engine.noteTransportInput(now: ProcessInfo.processInfo.systemUptime)
        let arrowSeekPress = presses.contains { $0.type == .leftArrow || $0.type == .rightArrow }
        if chipRevealed && !arrowSeekPress {
            engine.refreshSkipPrompt()
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
            // Insights: a popover or shelf is open and the remote is still here (nothing in it
            // took the focus). Everything but Menu stays inside it; no press seeks.
            if state.transport.overlayOpen, press.type != .menu {
                switch press.type {
                case .playPause, .select, .leftArrow, .rightArrow, .upArrow, .downArrow:
                    handleOverlayPress(press.type)
                    handled = true
                default:
                    break
                }
                continue
            }
            switch press.type {
            case .playPause, .select:
                if isScrubbing {
                    // Commit the scrub (two-stage unless cached); Play also resumes a paused file.
                    commitScrub()
                    if press.type == .playPause, engine.transportIsPaused { engine.togglePause() }
                    flashControls()
                } else if case .scanning = transport.mode {
                    // Ends the scan where it is; playback continues at the user's speed.
                    apply(transport.endScanInPlace())
                } else {
                    if case .stepping = transport.mode { stopHoldTimer(); apply(transport.cancel()) }
                    if press.type == .select, let pill = state.transport.focusedPill {
                        activatePill(pill)
                    } else if press.type == .select, let pill = state.transport.focusedInfoPill {
                        state.transport.focusedPill = nil
                        openOverlay(popover: nil, shelf: pill)
                    } else {
                        engine.togglePause(); flashControls()
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
                } else if state.transport.focusedInfoPill != nil {
                    moveInfoPill(by: -1)
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
                } else if state.transport.focusedInfoPill != nil {
                    moveInfoPill(by: 1)
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
                    // Hidden bar: raise it (focus on the track). Text pill row: back to the track.
                    // Track: focus the first disc; with a disc already focused Up does nothing but
                    // keep the bar up.
                    if state.transport.focusedInfoPill != nil {
                        state.transport.focusedInfoPill = nil
                    } else if state.controlsVisible, state.transport.focusedPill == nil {
                        state.transport.focusedPill = state.transport.pills.first
                    }
                    flashControls()
                    handled = true
                }
            case .downArrow:
                var consumed = chipRevealed
                switch transport.mode {
                case .scrubbing:
                    // Cancel, then the text pill row: no chip, no up-next.
                    cancelScrub(why: "down")
                    focusInfoPills()
                    consumed = true
                case .scanning:
                    apply(transport.endScanInPlace()); consumed = true   // no chip, no pill row
                case .stepping:
                    stopHoldTimer(); apply(transport.cancel())
                default:
                    break
                }
                if consumed {
                    handled = true
                } else {
                    // `DownPressRule`: disc → track; text pills keep the focus; then the up-next
                    // chip, the skip chip, and with nothing else the bar with the text pill row.
                    let action = DownPressRule.resolve(
                        overlayOpen: false,              // handled above
                        discFocused: state.transport.focusedPill != nil,
                        infoPillFocused: state.transport.focusedInfoPill != nil,
                        skipChip: state.skipPrompt != nil,
                        playUpNext: { state.upNextPlayNow?() == true })
                    switch action {
                    case .ignore:
                        flashControls()
                    case .discToTrack:
                        state.transport.focusedPill = nil
                        flashControls()
                    case .playedUpNext:
                        break
                    case .skip:
                        // Already clamped against duration by `SkipSegmentPlanner` (a target past
                        // EOF wedges mpv; unclamped while the duration is still unknown). The
                        // planner shows no chip until mpv confirms this seek, so a second press
                        // can't re-seek.
                        if let prompt = state.skipPrompt {
                            engine.issueSeek(kind: .chip, targetSec: prompt.targetSec, fromSec: nil, mode: .absolute,
                                             planner: true, onRejected: nil)
                            state.skipPrompt = nil
                        }
                        flashControls()
                    case .focusInfoPills:
                        focusInfoPills()
                    }
                    handled = true
                }
            case .menu:
                let action = currentMenuAction()
                NSLog("[MenuProbe] menu began action=%@ leaving=%d window=%d", String(describing: action),
                      host.isLeavingPlayerForLog ? 1 : 0, host.view.window == nil ? 0 : 1)
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
                    MenuProbe.dumpResponderChain(from: host, tag: "exit")
                    #endif
                    host.exitPlayer()
                case .actorBack, .closeOverlay, .cancelMode, .dismissUpNext, .hidePill, .unfocusInfoPill, .hideBar:
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
        }
        return handled
    }

    /// The controller's `pressesEnded`: true when handled (false = `super`).
    func pressesEnded(_ presses: Set<UIPress>) -> Bool {
        guard let host else { return false }
        var handled = false
        // The light tap recognises at touch-up: the release restarts the click window.
        lastClickUptime = ProcessInfo.processInfo.systemUptime
        for press in presses { pressesDown.remove(ObjectIdentifier(press)) }
        if presses.contains(where: { $0.type == .menu }) {
            NSLog("[MenuProbe] menu ended swallow=%d sinceExit=%dms window=%d", swallowMenuRelease ? 1 : 0,
                  sinceExitMs(), host.view.window == nil ? 0 : 1)
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
        return handled
    }

    /// A press cancelled mid-hold (Home / TV button, Siri, a recogniser claiming it) never ends:
    /// a held arrow stops its timer and drops the preview without committing, and a Menu whose
    /// begin was consumed is swallowed here too (UIKit would otherwise act on the half press).
    /// The controller's `pressesCancelled`: true when handled (false = `super`).
    func pressesCancelled(_ presses: Set<UIPress>) -> Bool {
        guard let host else { return false }
        var handled = false
        lastClickUptime = ProcessInfo.processInfo.systemUptime
        for press in presses { pressesDown.remove(ObjectIdentifier(press)) }
        if presses.contains(where: { $0.type == .menu }) {
            NSLog("[MenuProbe] menu cancelled swallow=%d sinceExit=%dms window=%d", swallowMenuRelease ? 1 : 0,
                  sinceExitMs(), host.view.window == nil ? 0 : 1)
        }
        if swallowMenuRelease, presses.contains(where: { $0.type == .menu }) {
            swallowMenuRelease = false
            handled = true
            pendingMenuAction = nil     // a cancelled Menu performs nothing
            #if DEBUG
            MenuProbe.dumpResponderChain(from: host, tag: "pressesCancelled(menu)")
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
        return handled
    }

    // MARK: - Hold / preview / commit (P1)

    /// Start a Left/Right gesture in `dir` (±1). The first press is a plain ±10 s seek (Step mode);
    /// holding moves only the preview, and one commit seeks on release (`TransportPreview`).
    private func beginHold(_ dir: Double) {
        // Seeking backward means the user is still watching — abandon next-episode autoplay.
        // Once per hold (idle → hold), never per tick or per direction change.
        if dir < 0, case .idle = transport.mode { state.upNextCancel?() }
        guard let engine else { return }
        let base = engine.seekInFlightTargetSec ?? engine.transportPositionSec   // seekBy's rule
        holdStartUptime = ProcessInfo.processInfo.systemUptime
        transport.paused = engine.transportIsPaused        // a paused hold steps, never scans
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
            engine?.setScanRate(r)
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
                engine?.scrubPreviewEnded(now: ProcessInfo.processInfo.systemUptime)
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

    var isScrubbing: Bool {
        if case .scrubbing = transport.mode { return true }
        return false
    }

    private func scrubContext() -> ScrubContext {
        guard let engine, let host else {
            // Only while the owning controller deinitialises: nothing may start a scrub.
            return ScrubContext(barVisible: false, paused: true, pillFocused: false, scrubbing: isScrubbing,
                                canScrub: false, pressesDown: pressesDown.count, lastPressUptime: lastClickUptime)
        }
        return ScrubContext(
            barVisible: state.controlsVisible,
            paused: engine.transportIsPaused,
            pillFocused: state.transport.focusedPill != nil || state.transport.focusedInfoPill != nil,
            scrubbing: isScrubbing,
            canScrub: engine.mediaLoaded && engine.transportDurationSec > 0 && host.presentedViewController == nil
                && !state.isEnded && !state.transport.overlayOpen,
            pressesDown: pressesDown.count,
            lastPressUptime: lastClickUptime)
    }

    @objc private func handleScrubPan(_ gr: UIPanGestureRecognizer) {
        let t = gr.translation(in: gr.view)
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
                  scrubArbiter.travel, gr.velocity(in: gr.view).x)
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
            state.transport.focusedInfoPill = nil
            guard let engine else { return }
            let base = engine.seekInFlightTargetSec ?? engine.transportPositionSec   // beginHold's rule
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
            cancelScrub(why: "pills")
            focusInfoPillsFromGesture()
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
        guard isScrubbing, let engine, !engine.transportIsPaused else { return }
        let work = DispatchWorkItem { [weak self] in self?.cancelScrub(why: "idle") }
        scrubIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportPreview.scrubIdleCancelSec, execute: work)
    }

    /// Ask for a frame near the scrub target, throttled (critique C17): at most one lookup in
    /// flight, a new one at most every 66 ms, and always a trailing one after the last sample.
    func requestPreviewFrame() {
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
            guard let source = engine?.seekPreviewSource else {
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
                self.engine?.scrubPreviewMissed(targetSec: target, matchSec: match?.sec)
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
        guard let engine else { return }
        let gen: Int
        if r.stages.first == .keyframes {
            let expected = engine.seekGeneration + 1           // issueSeek's generation for this seek
            gen = engine.issueSeek(kind: .user, targetSec: r.targetSec, fromSec: r.fromSec,
                                   mode: .absoluteKeyframes, planner: true, onRejected: { [weak self] in
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
            gen = engine.issueSeek(kind: .user, targetSec: r.targetSec, fromSec: r.fromSec, mode: .absoluteExact,
                                   planner: true, onRejected: nil)
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
        engine?.whenSeekStarted(generation: generation) { [weak self] in self?.runExactStage(ifGeneration: generation) }
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
        guard let engine, let p = pendingExact else { return }
        if let expected, p.generation != expected { return }
        p.deadline.cancel()
        pendingExact = nil
        exactWork?.cancel()   // the 0.15 s item may still be queued when the deadline hop ran us first
        exactWork = nil
        let now = ProcessInfo.processInfo.systemUptime
        engine.refineSkipSeek(targetSec: p.request.targetSec, fromSec: p.request.fromSec, now: now)
        // The planner already knows about this seek (`refineSeek`): no second `beginSeek`.
        let gen = engine.issueSeek(kind: .user, targetSec: p.request.targetSec, fromSec: p.request.fromSec,
                                   mode: .absoluteExact, planner: false, onRejected: nil)
        // The keyframes landing may never report now (`issueSeek` drops its restart): the preview
        // hands back on the exact stage's landing instead, so the fill never snaps to the origin.
        if commitGeneration == p.generation {
            armCommitLanding(generation: gen, fallbackSec: 3)
        }
        #if DEBUG
        state.seekProbe.stages = "ke"
        #endif
    }

    func cancelExactStage() {
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
        engine?.beginScan(rate: rate)
    }

    private func endScan(from: Double, returnTo: Double?) {
        guard let engine else { return }
        let restoreSpeed = scanRestoreSpeed ?? state.playbackSpeed
        #if DEBUG
        NSLog("[MenuProbe] endScan from=%.2f returnTo=%@ live=%.2f", from,
              returnTo.map { String(format: "%.2f", $0) } ?? "nil", engine.transportPositionSec)
        #endif
        engine.endScan(restoreSpeed: restoreSpeed)
        #if DEBUG
        state.seekProbe.speed = restoreSpeed
        #endif
        if let target = returnTo {
            // Menu: the scanned stretch was not watched, so no span is recorded (its intervals must
            // still auto-skip when played). Exact only: the origin sits in the back buffer.
            // `fromSec: target`: the span scan-end → origin must not mark the interval at the scan
            // end as deliberate.
            engine.issueSeek(kind: .user, targetSec: target, fromSec: target, mode: .absoluteExact,
                             planner: true, onRejected: nil)
            #if DEBUG
            state.seekProbe.note(commit: target, stages: "r")   // "r" = scan return (Menu)
            #endif
        } else {
            engine.recordUserSpan(fromSec: from, toSec: engine.transportPositionSec)
        }
        scanRestoreSpeed = nil
        state.transport.previewSec = nil
        flashControls()
    }

    private func seekBy(_ seconds: Double) {
        guard let engine, engine.canTransport else { return }
        // Arrow seeks are deliberate: a segment they start or land in is never auto-skipped. The
        // cached position is stale while another seek is in flight — mpv's relative seek then
        // starts from that seek's target, so the estimate does too (nil = unknown). The planner
        // marks the position mpv actually lands on, reported by `drainEvents`.
        let base: Double?
        if engine.hasSeekInFlight {
            base = engine.seekInFlightTargetSec
        } else {
            base = engine.transportPositionSec
        }
        engine.issueSeek(kind: .user, targetSec: base.map { $0 + seconds }, fromSec: base,
                         mode: .relative(deltaSec: seconds), planner: true, onRejected: nil)
    }

    /// One Left/Right click (P1's `.immediateSeek`): ±10 s, or in chapter mode a chapter jump.
    private func edgeClick(_ d: Double) {
        guard let engine else { return }
        let base = engine.seekInFlightTargetSec ?? engine.transportPositionSec   // seekBy's rule
        switch PlayerChapters.edgeClick(mode: edgeClickMode, direction: d < 0 ? -1 : 1, baseSec: base,
                                        chapters: state.transport.chapters, skipSec: abs(d)) {
        case .relative(let r): seekBy(r)
        case .absolute(let t): seekToChapter(t)
        }
    }

    /// Absolute seek to a chapter start (the Chapters tab, a chapter-mode click). A backward jump
    /// cancels the up-next countdown, like any backward seek.
    func seekToChapter(_ chapterSec: Double) {
        guard let engine, engine.canTransport else { return }
        // Backstop for a list read before the duration was known (review r1 P2 #2).
        let sec = PlayerChapters.clampedSeek(chapterSec, durationSec: engine.transportDurationSec)
        let base = engine.seekInFlightTargetSec ?? engine.transportPositionSec
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
        engine.issueSeek(kind: .user, targetSec: sec, fromSec: base, mode: .absolute, planner: true, onRejected: nil)
        #if DEBUG
        state.seekProbe.note(commit: sec, stages: "ch")
        #endif
        flashControls()
    }

    /// Raise the bar (or keep it up) and re-arm its hide timer: every input comes through here.
    func flashControls() {
        state.controlsVisible = true
        scheduleHide()
    }

    /// Hide rule: 4 s after the last input while playing; paused, 5 s when the pause card is on and
    /// never when it is off. A timer that fires with a pill focused or a seek mode active does
    /// nothing (the next input re-arms it).
    func scheduleHide() {
        hideWork?.cancel()
        hideWork = nil
        guard let delay = currentHideDelay() else { return }
        armHide(after: delay, elapsed: delay)
    }

    private func currentHideDelay() -> TimeInterval? {
        guard let engine, let host else { return nil }
        return TransportHideRule.delay(isPaused: engine.transportIsPaused,
                                       pauseCardEnabled: host.pauseCardEnabled)
    }

    /// `elapsed`: seconds since the last input once this fires. The pause state can change without
    /// input (programmatic pause), so the rule is re-read when the timer fires: paused with the card
    /// off never hides, paused with the card on waits out the longer delay.
    private func armHide(after seconds: TimeInterval, elapsed: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let t = self.state.transport
            // A focused disc or text pill, or an open popover or shelf, holds the bar (Insights
            // device pass 2026-11-01: a text pill that let the bar hide under it left the next
            // Menu to exit the player). Menu lets go of the pill, then hides the bar.
            guard TransportHideRule.mayHide(
                pillFocused: TransportHideRule.holdsBar(discFocused: t.focusedPill != nil,
                                                        infoPillFocused: t.focusedInfoPill != nil,
                                                        overlayOpen: t.overlayOpen),
                modeActive: self.transport.mode.isActive) else { return }
            guard let due = self.currentHideDelay() else { return }
            if due > elapsed {
                self.armHide(after: due - elapsed, elapsed: due)
                return
            }
            t.focusedPill = nil
            t.focusedInfoPill = nil
            self.state.controlsVisible = false
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hideControlsNow() {
        if state.transport.overlayOpen { closeOverlay() }
        hideWork?.cancel()
        hideWork = nil
        state.transport.focusedPill = nil
        state.transport.focusedInfoPill = nil
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
        switch pill {
        case .aspect:
            // Aspect cycles in place: focus stays on the pill so repeated Select keeps cycling.
            engine?.cycleAspect(); flashControls()
        case .more:
            // More opens the Info shelf; the text pill row takes the focus under it.
            state.transport.focusedPill = nil
            state.transport.focusedInfoPill = .info
            openOverlay(popover: nil, shelf: .info)
        default:
            // The disc keeps its focus under its popover, so Menu lands back on it.
            openOverlay(popover: pill, shelf: nil)
        }
    }

    // MARK: - Text pills, popovers and shelves (Insights, 2026-11-01)

    /// Down with nothing else to do (or a down swipe): the bar comes up with the text pill row
    /// focused. Raising the bar clears the per-raise focus, so the focus is set after it.
    private func focusInfoPills() {
        flashControls()
        let t = state.transport
        t.focusedPill = nil
        t.focusedInfoPill = t.infoPills.first
    }

    private func moveInfoPill(by delta: Int) {
        let t = state.transport
        if let current = t.focusedInfoPill,
           let next = PlayerInfoPill.move(from: current, by: delta, in: t.infoPills) {
            t.focusedInfoPill = next
        }
        flashControls()
    }

    /// Opens a disc's popover or a text pill's shelf over the playing video. The bar stays up
    /// while it is open (`TransportHideRule`); the focus engine is asked to move into it.
    private func openOverlay(popover: PillKind?, shelf: PlayerInfoPill?) {
        guard let host, host.presentedViewController == nil else { return }
        let t = state.transport
        if shelf != .cast { _ = state.panelModel?.menuBack() }   // a stale actor view never shows later
        host.prepareTracksForPanel()
        t.openPopover = popover
        t.openInfoPill = shelf
        state.panelOpen = true
        state.controlsVisible = true
        hideWork?.cancel()
        hideWork = nil
        requestOverlayFocus()
    }

    /// Asks the focus engine to look again once SwiftUI has inserted the overlay: nothing else in
    /// the player is focusable, so a popover or shelf with focusable rows takes the focus (a shelf
    /// with none, Info, leaves the remote with this controller). The request goes to the top of
    /// this controller's container chain, the SwiftUI host that draws the overlay.
    ///
    /// Device pass 2026-11-01: `setNeedsFocusUpdate` alone is ignored while nothing is focused (the
    /// environment must contain the focused item), so the focus stayed off the overlay until the
    /// next press. `UIFocusSystem.requestFocusUpdate(to:)` moves it in from nothing; it is retried a
    /// few runloop turns later while the overlay is open and still holds no focus (SwiftUI may not
    /// have laid the rows out yet; Sources and Episodes rows load late). The overlay itself also
    /// resets its focus scope on appear, which picks the preferred row (`PlayerOverlayDefaultFocus`).
    private static let overlayFocusRetryDelays: [TimeInterval] = [0, 0.08, 0.2, 0.45]

    private func requestOverlayFocus() {
        overlayFocusGeneration &+= 1
        requestOverlayFocus(attempt: 0, generation: overlayFocusGeneration)
    }

    private func requestOverlayFocus(attempt: Int, generation: Int) {
        let delays = Self.overlayFocusRetryDelays
        guard attempt < delays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self, let controller = self.host, generation == self.overlayFocusGeneration,
                  self.state.transport.overlayOpen else { return }
            var host: UIViewController = controller
            while let parent = host.parent { host = parent }
            let system = UIFocusSystem.focusSystem(for: host)
            // Nothing else in the player is focusable: any focused item is inside the overlay.
            if system?.focusedItem != nil { return }
            system?.requestFocusUpdate(to: host)
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
            self.requestOverlayFocus(attempt: attempt + 1, generation: generation)
        }
    }

    /// Closes the open popover or shelf, and this controller takes the remote back (libmpv's
    /// controller must be first responder again). Backing out (Menu, Select on the open pill) leaves
    /// the focus on its pill; a close that a pick inside caused (a chapter seek, an episode jump, a
    /// source switch, Play Now) returns to the track, so the bar hides on its timer
    /// (`OverlayCloseFocus`, review r3: a focused text pill holds the bar, and keeping it focused
    /// after a chapter pick held the bar up for good).
    private func closeOverlay(_ reason: OverlayCloseFocus.Reason = .back) {
        let t = state.transport
        guard t.overlayOpen else { return }
        let keep = OverlayCloseFocus.pillKeepsFocus(reason)
        if let pill = t.openPopover { t.focusedPill = keep ? pill : nil }
        if let pill = t.openInfoPill { t.focusedInfoPill = keep ? pill : nil }
        _ = state.panelModel?.menuBack()
        t.openPopover = nil
        t.openInfoPill = nil
        state.panelOpen = false
        state.reclaimFocus?()
        flashControls()
    }

    /// A press while a popover or shelf is open and this controller still holds the remote (the
    /// Info shelf has nothing focusable; a shelf whose rows have not loaded yet). Left/Right walk
    /// the text pills and the shelf follows; Select on the open pill closes its shelf; Play/Pause
    /// still toggles. Menu is decided by `MenuPrecedence` like every Menu.
    private func handleOverlayPress(_ type: UIPress.PressType) {
        let t = state.transport
        // A popover always has focusable rows: a press arriving here means the focus has not
        // landed in it yet (rows still loading, or the first request ran before SwiftUI drew it).
        if t.openPopover != nil, type != .playPause { requestOverlayFocus() }
        switch type {
        case .leftArrow, .rightArrow:
            guard t.openInfoPill != nil, let current = t.focusedInfoPill ?? t.openInfoPill,
                  let next = PlayerInfoPill.move(from: current, by: type == .leftArrow ? -1 : 1, in: t.infoPills),
                  next != t.openInfoPill else { return }
            t.focusedInfoPill = next
            openOverlay(popover: nil, shelf: next)
        case .select:
            if t.openInfoPill != nil { closeOverlay() }
        case .playPause:
            engine?.togglePause()
        default:
            break
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// The touch-surface recognisers (scrub pan, swipe down, light tap) see the same strokes together;
    /// `ScrubGestureArbiter` decides what each stroke is. Anything else recognises on its own.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let mine: [UIGestureRecognizer?] = [scrubPan, swipeDownRecognizer, lightTapRecognizer]
        return mine.contains { $0 === gestureRecognizer } && mine.contains { $0 === other }
    }
}

#if DEBUG
enum MenuProbe {
    /// Diagnostic for the "consumed Menu still dismisses the cover" class: who sits above this
    /// controller, and which gesture recognisers on that chain could claim a Menu press.
    static func dumpResponderChain(from controller: UIViewController, tag: String) {
        var lines: [String] = ["[MenuProbe] \(tag) firstResponder=\(controller.isFirstResponder)"]
        var responder: UIResponder? = controller
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
        if let w = controller.view.window, let grs = w.gestureRecognizers {
            lines.append("  window grs=" + grs.map { "\(type(of: $0))(state=\($0.state.rawValue) press=\($0.allowedPressTypes.map { $0.intValue }))" }.joined(separator: ", "))
        }
        NSLog("%@", lines.joined(separator: "\n"))
    }
}
#endif
