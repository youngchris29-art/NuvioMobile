import AVFoundation
import Combine
import NuvioAether
import SharedCore
import SwiftUI
import UIKit

// Aether Phase 1, W3-A: the Aether player controller behind the shared (post-Insights) chrome.
//
// It owns one `AetherPlaybackSession`, one `PlayerTransportInput` (the shared Siri-remote transport),
// the subtitle overlay and the session's surface, and it drives the same `MPVPlaybackState` the mpv
// controller drives, so the bar, pills, popovers, shelves, pause card, Up Next and the Insights cast
// pill work unchanged. mpv-only chrome is hidden through state, never by editing the chrome views
// (the Aspect pill: `MPVPlayerScreen.updateTransportPills`; speeds above `session.maxRate`: clamped).
//
// Time UI follows `session.clock` (its publishers), never a poll of the session. Failures go through
// `failureDecider` (W3-C replaces the default with `AetherFailurePolicy`); a fallback stops the session
// for a handoff and hands `PlayerScreen` a `PlaybackHandoff` through `onFallback`.
//
// Greppable log prefixes: `[AetherPlayer]`, `[Failover]`, `[Loading] engine=aether`, `[Aether]` (engine).

// MARK: - Failure decisions (the injection point W3-C fills)

/// What the controller does with one Aether failure. W3-C's `AetherFailurePolicy` conforms and replaces
/// `AetherDefaultFailureDecider` through `AetherTVPlayerViewController.failureDecider`.
protocol AetherFailureDeciding {
    func decide(_ failure: AetherFailure, startedPlaying: Bool, secondsPlayed: Double) -> AetherFailureDecision
}

enum AetherFailureDecision: Equatable {
    /// One fresh `load` at the last position (the DV-interruption rebuild). The controller allows it
    /// once per player; a second one falls back to mpv (`AetherFailurePlan.resolve`).
    case rebuildOnce
    /// Stop the session for a handoff and give the stream to mpv at the last position.
    case fallbackToMpv
    /// Terminal: report through `onPlaybackFailed` (mpv would meet the same failure).
    case fail
}

/// The default until W3-C lands `AetherFailurePolicy`: a mid-play failure of the kinds the spike's DV
/// interruption produced rebuilds once, a rate limit is terminal (mpv meets the same meter, W1-A
/// ladder), everything else falls back to mpv.
struct AetherDefaultFailureDecider: AetherFailureDeciding {
    /// The kinds an HDMI / audio-route interruption tears a DV session down with (W1-A section 7).
    static let interruptionKinds: Set<AetherFailureKind> = [.nativeItemFailed, .softwarePipelineFailed]

    func decide(_ failure: AetherFailure, startedPlaying: Bool, secondsPlayed: Double) -> AetherFailureDecision {
        if failure.kind == .sourceRateLimited { return .fail }
        if startedPlaying, Self.interruptionKinds.contains(failure.kind) { return .rebuildOnce }
        return .fallbackToMpv
    }
}

// MARK: - Controller

final class AetherTVPlayerViewController: UIViewController {

    // MARK: ChromePlayerController

    /// Menu exit: the SwiftUI cover dismisses.
    var onExit: (() -> Void)?
    /// Terminal failure (the decider said `.fail`, or nothing can take a handoff). At most once.
    var onPlaybackFailed: ((PlaybackFailure) -> Void)?
    /// Once, when the seconds played reach `PlaybackFailoverPolicy.healthySeconds`.
    var onPlaybackHealthy: ((Double) -> Void)?
    /// The engine before this one failed before start (never the case in Phase 1: Aether is first).
    var startWatchdogShortened = false
    /// Seconds the engine before this one played (0 in Phase 1).
    var secondsPlayedBeforeFallback: Double = 0

    // MARK: Aether-only hooks

    /// The handoff to mpv. Fired at most once, on main, after `session.stop(handingOff: true)`, with the
    /// last position, the seconds played, whether a frame was ever shown, and `.local`. nil = no host can
    /// take a handoff: the failure is reported through `onPlaybackFailed` instead.
    var onFallback: ((PlaybackHandoff) -> Void)?
    /// Decides every failure. Set before the view loads (W3-C: `AetherFailurePolicy`).
    var failureDecider: AetherFailureDeciding = AetherDefaultFailureDecider()

    // MARK: Owned objects

    let context: PlaybackContext
    let state: MPVPlaybackState
    /// nil only when the engine could not be created (`AetherPlaybackSession()` threw): the first
    /// appearance then hands off at once.
    private(set) var session: AetherPlaybackSession?
    private var sessionInitError: String?
    /// The shared Siri-remote transport. Made in `viewDidLoad`; this controller is its engine and host.
    private(set) var transportInput: PlayerTransportInput!
    /// The subtitle overlay (W3-B), above the surface and below the chrome.
    private(set) var subtitleOverlay: AetherSubtitleOverlayModel?
    private var surfaceHost: UIHostingController<AetherSurfaceRoot>?
    /// Replaced on Play Again after the end (review r5): the second viewing is a new watch session.
    private(set) var recorder: PlaybackProgressRecorder
    var bag = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    /// Scrub stills over `session.scrubFrame` (time-only when the session cannot serve them).
    private(set) var previewSource: AetherScrubPreviewSource?

    // MARK: Main-thread mirrors (the transport reads these; never a synchronous engine query)

    /// The playhead on the seek axis: the clock's `currentSec`, or where the last seek landed.
    private(set) var positionMirror: Double = 0
    private(set) var pausedMirror = false
    /// The last façade phase (willSet value).
    private(set) var phaseMirror: AetherPhase = .idle
    /// `firstFrameShown`, latched per load by the session; `everShowedFrame` latches for the player.
    var firstFrameMirror: Bool { viewing.firstFrameShown }
    var everShowedFrame: Bool { viewing.everShowedFrame }
    /// The per-load first frame, the per-viewing "a frame was shown" and the play clock (review r6).
    private var viewing = AetherViewingState()
    /// `load()` returned (the source opened and was probed).
    private(set) var mediaReady = false
    private(set) var probe: AetherProbeSummary?
    /// The user's speed; applied while playing (a paused engine keeps it for the next play).
    private(set) var desiredSpeed: Double = 1

    // MARK: Lifecycle state

    private var didStart = false
    private var housekeepingTimer: Timer?
    private var lastSaveUptime: TimeInterval = 0
    private var lastStreamInfoRefresh: TimeInterval = 0
    private static let streamInfoRefreshSec: TimeInterval = 2
    private let loadingStartUptime = ProcessInfo.processInfo.systemUptime
    /// A percentage-only resume row: resolved against the probed duration when `load()` returns.
    private var pendingResumePercent: Double?
    /// The resume / replay start the planner was told about, completed at the first frame.
    private var plannerStartSeekPending = false
    /// Last `.ended` was handled (the post-play cover is up or the early-end report went out).
    private var endedHandled = false

    // MARK: Transport

    /// Main: bumped for every seek issued (`issueSeek`); a completion reports only for the newest.
    private(set) var seekGeneration = 0
    var skipPlanner: SkipSegmentPlanner = {
        var planner = SkipSegmentPlanner()
        planner.autoHidesChip = true   // the chip comes back on a press, as on mpv
        return planner
    }()
    var skipSources = SkipIntervalSources()
    var chapterSkipFeed = ChapterSkipFeed()
    private var rawChapters: [TransportChapter] = []
    private var chaptersTrimDuration: Double = -1
    /// The scan in force (its requested rate), and its stepped-seek timer for 3x / 4x.
    private var scanRate: Int?
    private var scanTimer: Timer?
    private var scanStepInFlight = false

    // MARK: Failover

    private var startWatchdog = MPVStartWatchdog(limitSeconds: MPVStartWatchdog.defaultLimitSeconds)
    private var startWatchdogTimer: Timer?
    private var failoverReported = false
    private var failoverClosed = false
    private var healthyReported = false
    private(set) var handedOff = false
    private var rebuiltOnce = false
    private var trackingStarted = false
    /// Once-only flush / tracker stops and the handoff (`PlaybackHandoffLedger`).
    private var handoffLedger = PlaybackHandoffLedger()
    private var trackingFinished: Bool { handoffLedger.trackingFinished }
    private var teardownDone = false

    // MARK: Settings

    var playerSettings: PlayerSettingsUiState?
    private var playerSettingsWatcher: FlowWatcher?
    /// Subtitle selection and add-on side-load bookkeeping (`AetherTVPlayerViewController+Panels`).
    let panel = AetherPanelState()
    /// P5 N1: the audio delay's saved / stream-hint / session parts for this file.
    var audioDelayParts = AudioDelayParts(savedMs: 0, streamMs: nil, sessionAdjustMs: 0)

    init(context: PlaybackContext, state: MPVPlaybackState) {
        self.context = context
        self.state = state
        self.recorder = PlaybackProgressRecorder(context: context)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Engine log (once per process)

    private static let logInstalled: Bool = {
        AetherPlaybackSession.installLog { line in print("[Aether] \(line)") }
    }()

    /// The engine's log sink is process-wide and installed once (W2-A: never per session).
    static func installLogOnce() { _ = logInstalled }

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.masksToBounds = true
        view.accessibilityIdentifier = "player.aether"
        Self.installLogOnce()

        do {
            session = try AetherPlaybackSession()
        } catch {
            sessionInitError = "\(error)"
            print("[AetherPlayer] AetherPlaybackSession() threw: \(error)")
        }

        PlayerSettingsRepository.shared.ensureLoaded()
        playerSettings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState

        if let session {
            let overlay = AetherSubtitleOverlayModel(
                clock: session.clock,
                cues: session.$cues.eraseToAnyPublisher(),
                activeTrackID: session.$activeSubtitleID.eraseToAnyPublisher(),
                style: playerSettings.map { AetherSubtitleStyle.input(from: $0.subtitleStyle) } ?? .default,
                aspectMode: .fit)
            subtitleOverlay = overlay
            let host = UIHostingController(rootView: AetherSurfaceRoot(surface: session.surface, subtitles: overlay))
            host.view.backgroundColor = .black
            // The remote stays with this controller (`pressesBegan`): the surface never takes focus.
            host.view.isUserInteractionEnabled = false
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
            surfaceHost = host
            let source = AetherScrubPreviewSource(session: session)
            previewSource = source
        }

        state.replay = { [weak self] in self?.replay() }
        state.reclaimFocus = { [weak self] in
            // Presses begun before the panel/cover took over never end here: drop them so the
            // light tap is not blocked for the rest of the session.
            self?.transportInput.resetPressesDown()
            self?.becomeFirstResponder()
        }
        state.setSpeed = { [weak self] speed in self?.setSpeed(speed) }
        state.setRememberSpeed = { [weak self] on in self?.setRememberSpeed(on) }
        state.captureSyncPositionMs = { [weak self] in Int64(((self?.positionMirror) ?? 0) * 1000) }
        state.syncLineStripSdh = { [weak self] in self?.playerSettings?.subtitleStyle.stripSdh ?? false }
        // The overlay closures (Menu, close, focus, Play/Pause), the hold / scrub tuning, the
        // chapter seek and the Left/Right Click mode (`PlayerTransportInput.init`).
        transportInput = PlayerTransportInput(state: state, engine: self, host: self)
        // No preview card until the session says it can serve stills (`loadReturned`).
        state.transport.previewCardEnabled = false
        state.transport.aspectMode = .fit
        state.isBuffering = true
        transportInput.installGestures(on: view)

        wirePanels()
        if let session { wireSession(session) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        transportInput.resetPressesDown()   // a press begun under a cover never ended on this controller
        becomeFirstResponder()
        gateCoverMenuTap(enabled: false)
        // BUG-165: the Menu shield lives on the window (idempotent); armed only at the exit press.
        if let window = view.window { MenuExitShield.shared.install(on: window) }
        if !didStart {
            didStart = true
            startHousekeeping()
            transportInput.flashControls()
            playerSettingsWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
                guard let self, let settings = emitted as? PlayerSettingsUiState else { return }
                DispatchQueue.main.async { self.settingsChanged(settings) }
            }
            startPlayback()
        } else if housekeepingTimer == nil, !teardownDone {
            // Back from a full-screen cover (the post-play card, then Replay): `viewDidDisappear`
            // stopped the tick when the cover went up.
            startHousekeeping()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        print("[Failover] aether viewWillDisappear isLeavingPlayer=\(isLeavingPlayer) cover=\(coverIsBeingDismissed ? 1 : 0) sinceExit=\(transportInput.sinceExitMs())ms")
        if isLeavingPlayer { closeFailover() }
        // The hosting cover gets its Menu recogniser back whenever the cover itself stays (see the
        // mpv controller's `gateCoverMenuTap`, BUG-165 / review r1 P1-1).
        if !coverIsBeingDismissed { gateCoverMenuTap(enabled: true) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        housekeepingTimer?.invalidate()
        housekeepingTimer = nil
        transportInput.viewDidDisappear()
        stopScanTimer()
        if isLeavingPlayer {
            teardown(reason: "leaving")
        } else {
            // A cover over the player (the post-play card): Replay comes back here. Progress is
            // flushed (a no-op once the end closed the tracker sessions, `handleEnded`).
            recordProgress(flush: true)
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Remote (forwarded to the shared transport)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !transportInput.pressesBegan(presses) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !transportInput.pressesEnded(presses) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !transportInput.pressesCancelled(presses) { super.pressesCancelled(presses, with: event) }
    }

    // MARK: - Cover Menu recogniser (BUG-165; same rule as the mpv controller)

    /// The SwiftUI full-screen cover's own Menu tap recogniser, switched off while this controller is
    /// on screen so every Menu is decided by `MenuPrecedence` (see `MPVTVPlayerViewController`).
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

    /// This controller, or anything above it, is being dismissed or removed from its parent (a
    /// cover over the player sets none of these). Only meaningful inside the disappear callbacks.
    private var isLeavingPlayer: Bool {
        var node: UIViewController? = self
        while let current = node {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            node = current.parent
        }
        return false
    }

    private var coverIsBeingDismissed: Bool {
        var node: UIViewController? = self
        while let current = node {
            if current.isBeingDismissed { return true }
            node = current.parent
        }
        return false
    }

    // MARK: - Load

    private func startPlayback() {
        guard let session else {
            // The engine could not even be created: give the stream to mpv at once.
            let failure = AetherFailure(kind: .unknown("sessionInit"), message: sessionInitError ?? "init failed",
                                        atSec: 0, beforeFirstFrame: true)
            handleFailure(failure)
            return
        }
        let resume = resumeStartSec()
        if let resume {
            // THE resume seek, as the planner sees it (an intro it lands inside is not auto-skipped).
            skipPlanner.beginSeek(kind: .resume, targetSec: resume, fromSec: nil, now: ProcessInfo.processInfo.systemUptime)
            plannerStartSeekPending = true
        }
        let request = makeLoadRequest(startSec: resume)
        logRequest(request)
        publishStartupStage(.connecting)
        armStartWatchdog()
        runLoad(session, request)
    }

    /// The load request (W2-A "Request" notes): the fork's settings, the stream's headers and sidecars,
    /// the subtitle targets, the audio delay seed and the shaping, all set before `load()`.
    func makeLoadRequest(startSec: Double?) -> AetherLoadRequest {
        var r = AetherLoadRequest(url: context.url)
        r.startSec = startSec
        r.headers = context.requestHeaders
        if let settings = playerSettings {
            let device = DeviceLanguagePreferences.shared.preferredLanguageCodes()
            r.preferredAudioLanguages = PlayerLanguagePreferencesKt.resolvePreferredAudioLanguageTargets(
                preferredAudioLanguage: settings.preferredAudioLanguage,
                secondaryPreferredAudioLanguage: settings.secondaryPreferredAudioLanguage,
                deviceLanguages: device,
                contentOriginalLanguage: PlayerAudioLanguagePlan.originalLanguage(for: context))
            let targets = AetherSubtitleRouting.preferredTargets(primary: settings.preferredSubtitleLanguage,
                                                                 secondary: settings.secondaryPreferredSubtitleLanguage,
                                                                 deviceLanguages: device)
            r.initialSubtitle = AetherSubtitleStartGate.initialSubtitle(
                targets: targets, useForcedSubtitles: settings.subtitleStyle.useForcedSubtitles)
        }
        r.externalSubtitles = context.externalSubtitles.compactMap { sub in
            URL(string: sub.url).map { AetherExternalSubtitle(url: $0, name: sub.name ?? sub.language, language: sub.language) }
        }
        if AetherTuning.isObjectAudioEnabled() {
            r.objectAudio = .render(AetherSpeakerLayout(rawValue: AetherTuning.layout()) ?? .l714)
        }
        r.audioBridge = AetherTuning.isLosslessBridgeEnabled() ? .lossless : .surroundCompat
        r.dualLayerDV = AetherTuning.isDualLayerDVEnabled()
        r.displayCriteriaOwner = .forMatchContent(UserDefaults.standard.bool(forKey: PlayerTuning.matchFrameRateKey))
        r.systemMatchingEnabled = AetherPlaybackSession.systemMatchingEnabled(in: view.window)
        r.audioDelaySec = seedAudioDelay()
        let effects = PlayerAudioEffects.storedState()
        state.audioEffects = effects
        r.audioShaping = AetherShapingPlan.shaping(boostDb: effects.boostDb, mode: effects.mode)
        r.logTag = "player"
        return r
    }

    private func logRequest(_ r: AetherLoadRequest) {
        let start = r.startSec.map { String(format: "%.1f", $0) } ?? "-"
        let shaping = "\(r.audioShaping.dialogueLiftDB)/\(r.audioShaping.boostDB)"
        var line = "[AetherPlayer] load start=\(start) bridge=\(r.audioBridge.rawValue) objectAudio=\(r.objectAudio)"
        line += " dualLayer=\(r.dualLayerDV) owner=\(r.displayCriteriaOwner) systemMatching=\(r.systemMatchingEnabled)"
        line += " audioDelay=\(r.audioDelaySec) shaping=\(shaping) subs=\(r.initialSubtitle)"
        line += " external=\(r.externalSubtitles.count) headers=\(r.headers.count)"
        print(line)
    }

    /// P5 N1 on Aether: the saved delay and the stream hint as on mpv, clamped to the engine's +/-2 s.
    private func seedAudioDelay() -> Double {
        let storedMs = PlayerTrackPreferenceStorage.shared.loadAudioDelayMs(videoId: context.videoId)
        audioDelayParts = AudioDelayParts(
            savedMs: Int32(storedMs?.intValue ?? 0),
            streamMs: context.streamAudioDelayMs.map { KotlinInt(int: Int32($0)) },
            sessionAdjustMs: 0)
        let total = Double(StreamAudioDelay.shared.totalMs(parts: audioDelayParts)) / 1000.0
        let clamped = AetherAudioDelayPlan.clamped(total)
        if clamped != total {
            print("[AudioDelay] aether: \(total) s clamped to \(clamped) s (engine limit)")
        }
        state.audioDelaySec = clamped
        state.audioDelayLimitSec = AetherAudioDelayPlan.uiLimitSec(
            sharedLimitSec: Double(StreamAudioDelay.shared.uiLimitMs(parts: audioDelayParts)) / 1000.0)
        return clamped
    }

    /// One `load` (start, the DV rebuild, Replay). A failure arrives through `onFailure` (the façade
    /// reports the throw and the published failure once); a cancellation is never a failure.
    private func runLoad(_ session: AetherPlaybackSession, _ request: AetherLoadRequest) {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            do {
                let probe = try await session.load(request)
                self?.loadReturned(probe)
            } catch is CancellationError {
                print("[AetherPlayer] load cancelled")
            } catch let failure as AetherFailure {
                print("[AetherPlayer] load threw \(failure.kind.token)")
            } catch {
                print("[AetherPlayer] load threw \(error)")
            }
        }
    }

    /// Where the first load starts: a failure-alert retry's position, then the saved progress
    /// (`PlaybackProgressRecorder`'s rule: > 10 s, not completed, never on Start Over).
    private func resumeStartSec() -> Double? {
        if let s = context.resumeAtSec, s > 10 { return s }
        if let sec = recorder.resumePositionSec() { return sec }
        pendingResumePercent = recorder.pendingResumePercent()
        return nil
    }

    /// `load()` returned: the source opened and was probed (playback may not have started yet).
    private func loadReturned(_ probe: AetherProbeSummary?) {
        guard let session, !handedOff, !teardownDone else { return }
        let firstReturn = !mediaReady
        mediaReady = true
        if let probe { self.probe = probe }
        let duration = probe?.durationSec ?? session.clock.durationSec
        print("[AetherPlayer] load returned \(probe.map { "\($0.width)x\($0.height) \($0.videoCodec ?? "-") \($0.sourceFormat.rawValue) dur=\(Int($0.durationSec))" } ?? "no probe")")
        // Auto flows: a stub clip is a failed source, not an episode (no resume, no trackers).
        if firstReturn, rejectPlaceholderClip(durationSec: duration) { return }
        if !(state.startupStage == .started) { publishStartupStage(.buffering(percent: nil)) }
        state.transport.previewCardEnabled = session.supportsScrubStills
        if firstReturn {
            if let pct = pendingResumePercent, duration > 0 {
                pendingResumePercent = nil
                let target = duration * pct / 100
                if target > 10 { issueSeek(kind: .resume, targetSec: target, fromSec: nil, mode: .absolute, planner: true, onRejected: nil) }
            }
            mediaOpened()
            fetchSkipSegments()
        } else {
            freshLoadReturned()
        }
    }

    // MARK: - Session wiring

    private func wireSession(_ s: AetherPlaybackSession) {
        s.onFailure = { [weak self] failure in self?.handleFailure(failure) }
        s.onEnded = { [weak self] in self?.handleEnded() }
        s.onEscalatedToSoftware = { e in
            // Report-only: the same `load()` keeps going (W2-A).
            print("[AetherPlayer] software escalation at=\(String(format: "%.1f", e.atSec)) startup=\(e.duringStartup) absorbed=\(e.absorbed.token)")
        }
        s.onAuthorizationRefused = { status in
            print("[AetherPlayer] authorization refused \(status) (a terminal sourceRefused follows if nothing renews)")
        }
        s.onAudioDropped = { [weak self] in
            // Video without its audio is never acceptable on a VOD: mpv takes it (W1-A ladder).
            print("[AetherPlayer] audio dropped (no pipeline)")
            self?.handleFailure(AetherFailure(kind: .unknown("audioDropped"), message: "audio delivery dropped",
                                              atSec: self?.positionMirror ?? 0,
                                              beforeFirstFrame: !(self?.firstFrameMirror ?? false)),
                                forceFallback: true)
        }

        s.clock.$currentSec
            .removeDuplicates()
            .sink { [weak self] sec in self?.clockMoved(sec) }
            .store(in: &bag)
        s.clock.$durationSec
            .removeDuplicates()
            .sink { [weak self] sec in self?.durationChanged(sec) }
            .store(in: &bag)
        s.clock.$residentRanges
            .removeDuplicates()
            .sink { [weak self] ranges in self?.publishBuffered(ranges) }
            .store(in: &bag)
        s.$phase
            .removeDuplicates()
            .sink { [weak self] phase in self?.phaseChanged(phase) }
            .store(in: &bag)
        s.$isPaused
            .removeDuplicates()
            .sink { [weak self] paused in self?.pausedChanged(paused) }
            .store(in: &bag)
        s.$firstFrameShown
            .removeDuplicates()
            .sink { [weak self] shown in self?.firstFrameChanged(shown) }
            .store(in: &bag)
        s.$chapters
            .removeDuplicates()
            .sink { [weak self] list in self?.chaptersChanged(list) }
            .store(in: &bag)
        wireSessionPanels(s)
    }

    // MARK: - Clock and phase

    private func clockMoved(_ sec: Double) {
        guard sec.isFinite, !handedOff else { return }
        let position = max(0, sec)
        positionMirror = position
        if state.transport.positionSec != position { state.transport.positionSec = position }
        // The screen (and Up Next) observe `positionSec`: twice a second is the mpv cadence.
        if abs(state.positionSec - position) >= 0.5 || position == 0 {
            if state.positionSec != position { state.positionSec = position }
        }
    }

    private func durationChanged(_ sec: Double) {
        guard sec.isFinite else { return }
        if state.durationSec != sec { state.durationSec = sec }
        if state.transport.durationSec != sec { state.transport.durationSec = sec }
        transportInput.noteDuration(sec)
        if sec != chaptersTrimDuration {
            chaptersTrimDuration = sec
            if let next = PlayerChapters.republished(raw: rawChapters, published: state.transport.chapters, durationSec: sec) {
                state.transport.chapters = next
            }
            updateChapterSkipIntervals(durationSec: sec)
        }
    }

    private func phaseChanged(_ phase: AetherPhase) {
        phaseMirror = phase
        updateBuffering()
        #if DEBUG
        NSLog("[AetherPlayer] phase %@", phase.label)
        #endif
    }

    private func pausedChanged(_ paused: Bool) {
        // Paused → playing without input (the pause-card-off rule left no hide timer armed): re-arm
        // the hide so the bar does not stay up until the next press.
        if state.isPaused && !paused && state.controlsVisible { transportInput.scheduleHide() }
        pausedMirror = paused
        if state.isPaused != paused { state.isPaused = paused }
        if state.transport.isPaused != paused { state.transport.isPaused = paused }
        updateBuffering()
        #if DEBUG
        transportInput.updateSeekProbe(paused: paused)
        #endif
    }

    private func firstFrameChanged(_ shown: Bool) {
        viewing.firstFrameChanged(shown)
        updateBuffering()
        guard shown else { return }
        stopStartWatchdogTimer()
        startWatchdog.noteFileLoaded()
        if state.startupStage != .started { publishStartupStage(.started) }
        if plannerStartSeekPending {
            plannerStartSeekPending = false
            skipPlanner.seekCompleted(atSec: positionMirror, now: ProcessInfo.processInfo.systemUptime)
        }
        if desiredSpeed != 1, !pausedMirror { session?.setRate(Float(desiredSpeed)) }
        startTrackingIfNeeded()
    }

    private func updateBuffering() {
        let buffering: Bool
        switch phaseMirror {
        case .loading, .buffering: buffering = true
        case .ended, .failed: buffering = false
        case .idle: buffering = !everShowedFrame && !handedOff
        case .playing, .paused: buffering = !firstFrameMirror
        @unknown default: buffering = false
        }
        if state.isBuffering != buffering { state.isBuffering = buffering }
    }

    private func publishStartupStage(_ stage: PlayerLoadingStage) {
        state.startupStage = stage
        if stage.isStarted { state.playbackStarted = true }
        let t = ProcessInfo.processInfo.systemUptime - loadingStartUptime
        print("[Loading] engine=aether stage=\(stage.logToken) t=+\(String(format: "%.2f", t))s")
    }

    // MARK: - Buffered ranges and chapters

    private func publishBuffered(_ resident: [ClosedRange<Double>]) {
        let raw = resident.map { BufferedRange(start: $0.lowerBound, end: $0.upperBound) }
        let merged = BufferedRange.merge(raw, gapSec: 5, durationSec: transportDurationSec)
        transportInput.setSeekableRanges(merged)
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

    private func chaptersChanged(_ list: [AetherChapter]) {
        let duration = transportDurationSec
        let mapped = AetherChapterMapping.transportChapters(list, durationSec: duration)
        rawChapters = mapped.raw
        chaptersTrimDuration = duration
        if state.transport.chapters != mapped.published { state.transport.chapters = mapped.published }
        updateChapterSkipIntervals(durationSec: duration)
        #if DEBUG
        NSLog("[Chapters] aether n=%ld dropped=%ld dur=%.1f", mapped.published.count,
              mapped.raw.count - mapped.published.count, duration)
        #endif
    }

    // MARK: - Housekeeping tick (0.5 s; reads the mirrors, never the engine)

    private func startHousekeeping() {
        housekeepingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.housekeepingTick() }
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer
    }

    private func housekeepingTick() {
        guard session != nil, !handedOff, !teardownDone else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let playing = firstFrameMirror && phaseMirror == .playing && !pausedMirror
        viewing.note(playing: playing, at: now)
        // The screen reads `positionSec` for Up Next and the pause card: the exact value once a tick.
        if state.positionSec != positionMirror { state.positionSec = positionMirror }
        transportInput.noteScanTick(positionSec: positionMirror, eof: phaseMirror == .ended)
        if state.transport.playbackSpeed != state.playbackSpeed { state.transport.playbackSpeed = state.playbackSpeed }
        #if DEBUG
        transportInput.updateSeekProbe(paused: pausedMirror)
        #endif
        // Info rows only while someone can see them (BUG-180's rule), at most every 2 s.
        if state.showStreamInfo || state.transport.openInfoPill == .info,
           now - lastStreamInfoRefresh >= Self.streamInfoRefreshSec {
            lastStreamInfoRefresh = now
            refreshStreamInfo()
        }
        if playing, now - lastSaveUptime > 5 {
            lastSaveUptime = now
            recordProgress(flush: false)
            reportHealthyIfNeeded()
        }
        updateSkipPrompt(position: positionMirror, duration: transportDurationSec, paused: pausedMirror)
        #if DEBUG
        debugInjectFailureIfDue(now: now)
        #endif
    }

    #if DEBUG
    // Harness only (W3-C): `debug.mpvSmokeAetherFailAtSec` <sec> raises a `softwarePipelineFailed`
    // failure once playback passes that position (`debug.mpvSmokeAetherFailCount` times, default 1, at
    // least 3 s apart), so the policy, the rebuild-once rule and the handoff position run mid-play.
    // `debug.mpvSmokeAetherInterrupt` YES posts an `AVAudioSession` route change just before each, so
    // the failure lands inside the policy's 10 s window (rebuild) rather than outside it (mpv).
    private var debugInjected = 0
    private var debugLastInjectUptime = 0.0
    private func debugInjectFailureIfDue(now: Double) {
        let defaults = UserDefaults.standard
        guard everShowedFrame, let at = defaults.object(forKey: "debug.mpvSmokeAetherFailAtSec") as? Double,
              positionMirror >= at, now - debugLastInjectUptime >= 3 else { return }
        let limit = max(defaults.integer(forKey: "debug.mpvSmokeAetherFailCount"), 1)
        guard debugInjected < limit else { return }
        debugInjected += 1
        debugLastInjectUptime = now
        let interrupt = defaults.bool(forKey: "debug.mpvSmokeAetherInterrupt")
        print("[AetherPlayer] DEBUG injecting softwarePipelineFailed #\(debugInjected) at \(String(format: "%.1f", positionMirror))"
              + " interrupt=\(interrupt)")
        if interrupt {
            NotificationCenter.default.post(
                name: AVAudioSession.routeChangeNotification, object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        }
        let failure = AetherFailure(kind: .softwarePipelineFailed, message: "debug injected", atSec: positionMirror,
                                    beforeFirstFrame: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + (interrupt ? 0.3 : 0)) { [weak self] in
            self?.handleFailure(failure)
        }
    }
    #endif

    // MARK: - Speed and pause

    func togglePause() {
        guard let session, canTransport, phaseMirror != .ended else { return }
        let target = !pausedMirror
        // Optimistic UI: the session's `isPaused` confirms it.
        pausedChanged(target)
        if target {
            session.pause()
        } else {
            session.play()
            if desiredSpeed != 1 { session.setRate(Float(desiredSpeed)) }
        }
    }

    func setSpeed(_ speed: Double) {
        guard let session else { return }
        if scanRate != nil { return }
        let clamped = AetherRatePlan.clampedSpeed(speed, maxRate: session.maxRate)
        if clamped != speed { print("[AetherPlayer] speed \(speed) clamped to \(clamped) (maxRate \(session.maxRate))") }
        desiredSpeed = clamped
        if !pausedMirror, firstFrameMirror { session.setRate(Float(clamped)) }
        state.playbackSpeed = clamped
        if state.rememberSpeed {
            PlayerTrackPreferenceStorage.shared.savePlaybackSpeed(parentMetaId: context.parentMetaId, speed: clamped)
        }
    }

    /// P5 B23: "Remember Speed for This Show". On saves the current speed; off forgets it.
    private func setRememberSpeed(_ on: Bool) {
        guard context.season != nil || context.episode != nil else { return }
        state.rememberSpeed = on
        if on {
            PlayerTrackPreferenceStorage.shared.savePlaybackSpeed(parentMetaId: context.parentMetaId, speed: state.playbackSpeed)
        } else {
            PlayerTrackPreferenceStorage.shared.clearPlaybackSpeed(parentMetaId: context.parentMetaId)
        }
    }

    // MARK: - Scan (2x engine rate; 3x / 4x stepped seeks at the cap)

    private func applyScan(_ rate: Int) {
        guard let session else { return }
        scanRate = rate
        let engineRate = AetherScanPlan.engineRate(scanRate: rate, maxRate: session.maxRate)
        session.setRate(engineRate)
        if AetherScanPlan.isStepped(scanRate: rate, maxRate: session.maxRate) {
            if scanTimer == nil {
                let timer = Timer(timeInterval: AetherScanPlan.stepIntervalSec, repeats: true) { [weak self] _ in
                    self?.scanStepTick()
                }
                RunLoop.main.add(timer, forMode: .common)
                scanTimer = timer
            }
        } else {
            stopScanTimer()
        }
        print("[AetherPlayer] scan \(rate)x engineRate=\(engineRate) stepped=\(scanTimer != nil)")
    }

    private func scanStepTick() {
        guard let session, let rate = scanRate, !scanStepInFlight,
              let target = AetherScanPlan.stepTarget(positionSec: positionMirror, scanRate: rate,
                                                     maxRate: session.maxRate, durationSec: transportDurationSec)
        else { return }
        scanStepInFlight = true
        Task { @MainActor [weak self] in
            _ = await session.seek(toSec: target, exact: false)
            self?.scanStepInFlight = false
        }
    }

    private func stopScanTimer() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    // MARK: - Seek funnel

    /// Every seek the app issues: the skip planner hears it first, the generation moves, and the
    /// façade's outcome reports back on main (landed → the transport's two hand-backs, the planner;
    /// rejected → `onRejected`, the planner's seek interrupted).
    @discardableResult
    func issueSeek(kind: SkipSegmentPlanner.SeekKind, targetSec: Double?, fromSec: Double?,
                   mode: TransportSeekMode, planner: Bool, onRejected: (() -> Void)?) -> Int {
        guard let session, canTransport else { return seekGeneration }
        guard let target = AetherSeekPlan.target(mode: mode, targetSec: targetSec, positionSec: positionMirror,
                                                 inFlightTargetSec: skipPlanner.seekInFlight?.targetSec,
                                                 durationSec: transportDurationSec)
        else { return seekGeneration }
        let now = ProcessInfo.processInfo.systemUptime
        if planner { skipPlanner.beginSeek(kind: kind, targetSec: targetSec ?? target, fromSec: fromSec, now: now) }
        seekGeneration += 1
        let generation = seekGeneration
        let exact = AetherSeekPlan.isExact(mode)
        #if DEBUG
        NSLog("[SeekProbe] aether seek gen=%ld target=%.3f exact=%d", generation, target, exact ? 1 : 0)
        #endif
        Task { @MainActor [weak self] in
            let outcome = await session.seek(toSec: target, exact: exact)
            self?.seekFinished(generation: generation, targetSec: target, outcome: outcome, onRejected: onRejected)
        }
        return generation
    }

    private func seekFinished(generation: Int, targetSec: Double, outcome: AetherSeekOutcome, onRejected: (() -> Void)?) {
        #if DEBUG
        NSLog("[SeekProbe] aether outcome gen=%ld %@", generation, String(describing: outcome))
        #endif
        switch AetherSeekPlan.landing(for: outcome, targetSec: targetSec) {
        case .landed(let at):
            // The preview playhead hands back on a commit's first landing, newest or not.
            transportInput.seekLandedForCommit(generation: generation)
            guard generation == seekGeneration else { return }
            skipPlanner.seekCompleted(atSec: at, now: ProcessInfo.processInfo.systemUptime)
            // Keyframes landed: that picture first, then the exact stage.
            transportInput.seekLandedForExact(generation: generation)
            positionMirror = at
            if state.transport.positionSec != at { state.transport.positionSec = at }
        case .superseded:
            break
        case .rejected:
            onRejected?()
            guard generation == seekGeneration else { return }
            skipPlanner.seekInterrupted()
        }
    }

    // MARK: - Skip chip, chapters → skip intervals

    func updateSkipPrompt(position: Double, duration: Double, paused: Bool) {
        var autoSkipTypes: [AutoSkipSegmentType]? = playerSettings.flatMap { $0.skipIntroEnabled ? Array($0.autoSkipSegmentTypes) : nil }
        // No auto-skip mid-scan: the user is deliberately moving through the file.
        if case .scanning = transportInput.mode { autoSkipTypes = nil }
        let decision = skipPlanner.evaluate(positionSec: position, durationSec: duration,
                                            isPlaying: firstFrameMirror && !paused, autoSkipTypes: autoSkipTypes,
                                            now: ProcessInfo.processInfo.systemUptime)
        if let target = decision.autoSkipTargetSec {
            issueSeek(kind: .auto, targetSec: target, fromSec: nil, mode: .absolute, planner: true, onRejected: nil)
        }
        if decision.prompt != state.skipPrompt { state.skipPrompt = decision.prompt }
        #if DEBUG
        state.seekProbe.chip = state.skipPrompt != nil
        #endif
    }

    /// Intro / recap / outro segments for an episode, IntroDB credits for a movie (the mpv fetch).
    private func fetchSkipSegments() {
        if let season = context.season, let episode = context.episode {
            SkipIntroRepository.shared.getSkipIntervalsForContentId(
                contentId: context.parentMetaId,
                season: Int32(season),
                episode: Int32(episode),
                requireSkipIntroEnabled: true
            ) { [weak self] intervals, _ in
                guard let intervals else { return }
                DispatchQueue.main.async { self?.applyApiSkipIntervals(intervals) }
            }
        } else if context.contentType.lowercased() == "movie" {
            SkipIntroRepository.shared.getMovieSkipIntervals(
                contentId: context.parentMetaId,
                videoId: context.videoId,
                requireSkipIntroEnabled: true
            ) { [weak self] intervals, _ in
                guard let intervals else { return }
                DispatchQueue.main.async { self?.applyApiSkipIntervals(intervals) }
            }
        }
    }

    private func applyApiSkipIntervals(_ intervals: [SkipInterval]) {
        skipSources.api = intervals
        applyMergedSkipIntervals()
    }

    func updateChapterSkipIntervals(durationSec: Double) {
        let settings = playerSettings ?? PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState
        guard let next = chapterSkipFeed.update(chapters: state.transport.chapters, durationSec: durationSec,
                                                skipIntroEnabled: settings?.skipIntroEnabled ?? false) else { return }
        skipSources.chapters = next
        applyMergedSkipIntervals()
    }

    private func applyMergedSkipIntervals() {
        let intervals = skipSources.merged(isMovie: SkipIntervalSources.isMovie(contentType: context.contentType))
        skipPlanner.setIntervals(intervals)
        if state.skipPrompt != nil {
            updateSkipPrompt(position: positionMirror, duration: transportDurationSec, paused: pausedMirror)
        }
        state.skipIntervals = intervals
        state.transport.skipSpans = intervals.compactMap { interval in
            guard interval.type.trimmingCharacters(in: .whitespaces).lowercased() != "post-credits" else { return nil }
            return TransportSpan(start: interval.startTime, end: interval.endTime, kind: interval.type)
        }
    }

    // MARK: - Settings

    private func settingsChanged(_ settings: PlayerSettingsUiState) {
        let skipIntroFlipped = playerSettings.map { $0.skipIntroEnabled != settings.skipIntroEnabled } ?? false
        playerSettings = settings
        if skipIntroFlipped { updateChapterSkipIntervals(durationSec: transportDurationSec) }
        settingsChangedPanels(settings)
    }

    // MARK: - End of file and Replay

    private func handleEnded() {
        guard !endedHandled, !handedOff else { return }
        endedHandled = true
        updateBuffering()
        transportInput.noteScanTick(positionSec: positionMirror, eof: true)
        stopScanTimer()
        let position = AetherFailurePlan.endPosition(positionSec: positionMirror, durationSec: transportDurationSec)
        // A stream that ran dry well before its declared end is a failure for the failover, not a
        // finished movie (`PlaybackEndPolicy`, the mpv rule).
        if onPlaybackFailed != nil,
           PlaybackEndPolicy.isEarlyEndFailure(position: positionMirror, duration: transportDurationSec,
                                               secondsPlayed: secondsPlayed, launchSource: context.launchSource) {
            if reportPlaybackFailure(reason: "stream ended early at \(Int(positionMirror))/\(Int(transportDurationSec)) s",
                                     startedPlaying: true, kind: .endedEarly, httpStatus: nil) { return }
            if failoverReported { return }
        }
        print("[AetherPlayer] ended at \(String(format: "%.1f", position))")
        recorder.record(positionSec: position, durationSec: transportDurationSec, isPaused: true, speed: 1,
                        flush: true, isLive: false)
        // Review r3: the watch is complete here, so the Trakt and tracker sessions close at the end
        // position (mpv closes them when the post-play cover goes up). Play Again reopens them.
        finishTracking(positionSec: position)
        state.isEnded = true
    }

    /// Post-play "Play Again": `.ended` is terminal on Aether, so this is a fresh `load` at 0 on the
    /// same request with the live tracks (`reloadRequest`; the clock keeps its axis). The tracker
    /// sessions closed at the end (`handleEnded`); the second viewing is tracked as a new watch.
    private func replay() {
        guard let session, let request = session.currentRequest, !handedOff else { return }
        transportInput.cancelExactStage()
        skipPlanner.beginSeek(kind: .replay, targetSec: 0, fromSec: nil, now: ProcessInfo.processInfo.systemUptime)
        plannerStartSeekPending = true
        endedHandled = false
        state.isEnded = false
        positionMirror = 0
        // Review r5: the end closed tracking; the second viewing records progress and scrobbles as a
        // new watch (fresh recorder, sessions reopened at its first frame by `startTrackingIfNeeded`).
        if handoffLedger.beginReplay() {
            recorder = PlaybackProgressRecorder(context: context)
            trackingStarted = false
            // Review r6: a new viewing, so its early end or pre-frame failure is judged on its own.
            viewing.replayStarting()
        }
        viewing.loadStarting()   // review r6 F2: the new watchdog never sees the old load's frame
        updateBuffering()
        print("[AetherPlayer] replay: load at 0")
        armStartWatchdog()
        runLoad(session, reloadRequest(request, startSec: 0))
        transportInput.flashControls()
        becomeFirstResponder()
    }

    // MARK: - Progress and trackers (`PlaybackProgressRecorder`, the native engine's precedent)

    private var secondsPlayed: Double {
        viewing.secondsPlayed(beforeFallback: secondsPlayedBeforeFallback)
    }

    func recordProgress(flush: Bool) {
        guard everShowedFrame, !trackingFinished else { return }
        recorder.record(positionSec: positionMirror, durationSec: transportDurationSec, isPaused: pausedMirror,
                        speed: state.playbackSpeed, flush: flush, isLive: false)
    }

    private func startTrackingIfNeeded() {
        guard !trackingStarted, !trackingFinished else { return }
        trackingStarted = true
        recorder.startTrakt(positionSec: positionMirror, durationSec: transportDurationSec)
        recorder.startTrackers(positionSec: positionMirror, durationSec: transportDurationSec)
    }

    /// Once per player: one resume flush, then the Trakt and tracker stops (W1-B 4.3 order).
    private func finishTracking(positionSec: Double) {
        apply(handoffLedger.finishTracking(positionSec: positionSec, durationSec: transportDurationSec,
                                           everShowedFrame: everShowedFrame))
    }

    /// Runs the ledger's tracking effects. `.handOff` is the caller's (it stops the session first).
    private func apply(_ effects: [PlaybackHandoffLedger.Effect]) {
        let duration = transportDurationSec
        for effect in effects {
            switch effect {
            case .flushResume(let sec):
                recorder.record(positionSec: sec, durationSec: duration, isPaused: true, speed: 1,
                                flush: true, isLive: false)
            case .stopTrakt(let sec):
                recorder.stopTrakt(positionSec: sec, durationSec: duration, isLive: false)
            case .stopTrackers(let sec):
                recorder.stopTrackers(positionSec: sec, durationSec: duration, isLive: false)
            case .handOff:
                break
            }
        }
    }

    // MARK: - Start watchdog

    private func armStartWatchdog() {
        guard onPlaybackFailed != nil || onFallback != nil, !handedOff else { return }
        startWatchdog = MPVStartWatchdog(limitSeconds: MPVStartWatchdog.limitSeconds(shortened: startWatchdogShortened))
        startWatchdog.noteLoadStarted(at: ProcessInfo.processInfo.systemUptime)
        print("[Failover] aether start watchdog armed: \(Int(startWatchdog.limitSeconds)) s")
        startWatchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tickStartWatchdog() }
        RunLoop.main.add(timer, forMode: .common)
        startWatchdogTimer = timer
    }

    private func tickStartWatchdog() {
        let verdict = startWatchdog.poll(now: ProcessInfo.processInfo.systemUptime)
        switch AetherStartWatchdogRule.action(verdict: verdict, firstFrameShown: firstFrameMirror) {
        case .wait:
            break
        case .standDown:
            stopStartWatchdogTimer()
        case .reportTimeout:
            stopStartWatchdogTimer()
            print("[Failover] aether start watchdog fired: no first frame within \(Int(startWatchdog.limitSeconds)) s")
            if let session {
                session.reportFirstFrameTimeout()
            } else {
                handleFailure(AetherFailure(kind: .firstFrameTimeout, message: "no session", atSec: 0, beforeFirstFrame: true))
            }
        }
    }

    private func stopStartWatchdogTimer() {
        startWatchdogTimer?.invalidate()
        startWatchdogTimer = nil
    }

    // MARK: - Failures, rebuild, handoff

    /// Every façade failure (and the controller's own: audio dropped, no session) lands here once.
    private func handleFailure(_ failure: AetherFailure, forceFallback: Bool = false) {
        guard !handedOff, !failoverReported, !failoverClosed, !teardownDone else {
            print("[Failover] aether failure ignored (\(failure.kind.token)) handedOff=\(handedOff) reported=\(failoverReported) closed=\(failoverClosed)")
            return
        }
        guard !state.playbackFailoverSuppressed else {
            print("[Failover] aether failure suppressed (\(failure.kind.token)): a context swap is underway")
            return
        }
        let started = everShowedFrame
        let played = secondsPlayed
        let decided = forceFallback ? .fallbackToMpv
            : failureDecider.decide(failure, startedPlaying: started, secondsPlayed: played)
        let decision = AetherFailurePlan.resolve(decided, alreadyRebuilt: rebuiltOnce)
        print("[Failover] aether failure kind=\(failure.kind.token) http=\(failure.httpStatus.map(String.init) ?? "-")"
              + " beforeFirstFrame=\(failure.beforeFirstFrame) at=\(Int(failure.atSec)) played=\(Int(played))"
              + " started=\(started) decision=\(decision)")
        switch decision {
        case .rebuildOnce:
            rebuild(after: failure)
        case .fallbackToMpv:
            handOff(reason: "aether: \(failure.kind.token)")
        case .fail:
            reportPlaybackFailure(reason: "aether: \(failure.kind.token)", startedPlaying: started,
                                  kind: AetherFailurePlan.failureKind(failure.kind), httpStatus: failure.httpStatus)
        }
    }

    /// The DV-interruption rebuild: a fresh `load` of the same request with the live tracks
    /// (`reloadRequest`) at the last position (plan section 14: not `reloadAtCurrentPosition`). Its
    /// failure reports again (new generation).
    private func rebuild(after failure: AetherFailure) {
        rebuiltOnce = true
        guard let session, let request = session.currentRequest else {
            handOff(reason: "aether: \(failure.kind.token) (no request to rebuild)")
            return
        }
        let at = AetherFailurePlan.handoffPosition(positionMirror)
        print("[Failover] aether rebuild at \(String(format: "%.1f", at)) after \(failure.kind.token)")
        endedHandled = false
        viewing.loadStarting()   // review r6 F2: the new watchdog never sees the old load's frame
        updateBuffering()
        armStartWatchdog()
        runLoad(session, reloadRequest(request, startSec: at > 1 ? at : nil))
    }

    /// Fallback: stop for a handoff, flush once, then `onFallback`. With no host for a handoff the
    /// failure is reported instead (the stream never sits on a dead screen).
    private func handOff(reason: String) {
        guard !handedOff else { return }
        guard let onFallback else {
            reportPlaybackFailure(reason: reason, startedPlaying: everShowedFrame, kind: .local, httpStatus: nil)
            return
        }
        handedOff = true
        failoverClosed = true
        startWatchdog.noteCancelled()
        stopStartWatchdogTimer()
        stopScanTimer()
        loadTask?.cancel()
        let effects = handoffLedger.handOff(positionSec: positionMirror, secondsPlayed: secondsPlayed,
                                            durationSec: transportDurationSec, everShowedFrame: everShowedFrame)
        apply(effects)
        session?.stop(handingOff: true)
        guard let handoff = effects.compactMap({ effect -> PlaybackHandoff? in
            if case .handOff(let h) = effect { return h }
            return nil
        }).first else { return }
        print("[Failover] aether → mpv handoff (\(reason)) pos=\(String(format: "%.1f", handoff.positionSec))"
              + " played=\(Int(handoff.secondsPlayed)) started=\(handoff.startedPlaying)")
        onFallback(handoff)
    }

    /// Terminal failure report (one-shot, the mpv guards).
    @discardableResult
    private func reportPlaybackFailure(reason: String, startedPlaying: Bool, kind: PlaybackFailureKind,
                                       httpStatus: Int?) -> Bool {
        guard let onPlaybackFailed else { return false }
        guard !failoverReported, !failoverClosed, !state.playbackFailoverSuppressed else {
            print("[Failover] aether failure suppressed (\(reason)) reported=\(failoverReported) closed=\(failoverClosed) swapped=\(state.playbackFailoverSuppressed)")
            return false
        }
        failoverReported = true
        startWatchdog.noteCancelled()
        stopStartWatchdogTimer()
        let position = AetherFailurePlan.handoffPosition(positionMirror)
        let v = PlaybackFailureClassifier.applyingPath(PlaybackFailureClassifier.Verdict(kind, http: httpStatus),
                                                       pathSatisfied: NetworkPathMonitor.shared.isSatisfied)
        print("[Failover] aether failure: \(reason) pos=\(Int(position)) played=\(Int(secondsPlayed)) started=\(startedPlaying)"
              + " kind=\(v.kind.rawValue) http=\(v.httpStatus.map(String.init) ?? "-")")
        onPlaybackFailed(PlaybackFailure(reason: reason, positionSec: position, secondsPlayed: secondsPlayed,
                                         startedPlaying: startedPlaying, kind: v.kind, httpStatus: v.httpStatus))
        return true
    }

    /// Auto flows: a stub clip (debrid cache-sync placeholder) is reported and stopped.
    private func rejectPlaceholderClip(durationSec: Double) -> Bool {
        guard onPlaybackFailed != nil, context.launchSource != .manual, durationSec.isFinite else { return false }
        guard WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000)) else { return false }
        let seconds = Int(durationSec.rounded())
        print("[Failover] aether placeholder clip rejected: \(seconds) s on an auto flow")
        reportPlaybackFailure(reason: "placeholder clip (\(seconds)s)", startedPlaying: true, kind: .placeholder, httpStatus: nil)
        session?.stop()
        return true
    }

    private func reportHealthyIfNeeded() {
        guard !healthyReported, let onPlaybackHealthy, everShowedFrame else { return }
        let played = secondsPlayed
        guard played >= PlaybackFailoverPolicy.healthySeconds else { return }
        healthyReported = true
        print("[Failover] aether healthy after \(Int(played)) s")
        onPlaybackHealthy(played)
    }

    private func closeFailover() {
        failoverClosed = true
        startWatchdog.noteCancelled()
        stopStartWatchdogTimer()
    }

    // MARK: - Teardown

    /// Leaving the player (Menu exit, a context swap, the mpv handoff's swap): one flush and the
    /// tracker stops, then the session stops (idempotent; a handed-off session already stopped).
    private func teardown(reason: String) {
        guard !teardownDone else { return }
        teardownDone = true
        closeFailover()
        stopScanTimer()
        loadTask?.cancel()
        finishTracking(positionSec: positionMirror)
        session?.stop()
        transportInput.invalidate()
        playerSettingsWatcher?.cancel()
        playerSettingsWatcher = nil
        teardownPanels()
        print("[AetherPlayer] teardown (\(reason))")
    }

    isolated deinit {
        housekeepingTimer?.invalidate()
        startWatchdogTimer?.invalidate()
        scanTimer?.invalidate()
        loadTask?.cancel()
        transportInput?.invalidate()
        playerSettingsWatcher?.cancel()
        // Backstop for a teardown path where `viewDidDisappear` never ran: idempotent.
        finishTracking(positionSec: positionMirror)
        session?.stop()
        deinitPanels()
    }
}

// MARK: - Transport seam

extension AetherTVPlayerViewController: PlayerTransportEngine {
    var canTransport: Bool { session != nil && !handedOff && !teardownDone }
    var mediaLoaded: Bool { mediaReady }
    var transportPositionSec: Double { positionMirror }
    var transportDurationSec: Double { session?.clock.durationSec ?? probe?.durationSec ?? 0 }
    var transportIsPaused: Bool { pausedMirror }

    /// The façade has no seek-start event: a seek starts when it is issued.
    func whenSeekStarted(generation: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.async { body() }
    }

    var hasSeekInFlight: Bool { skipPlanner.seekInFlight != nil }
    var seekInFlightTargetSec: Double? { skipPlanner.seekInFlight?.targetSec }

    func noteTransportInput(now: TimeInterval) -> Bool {
        skipPlanner.noteInput(now: now)
    }

    func refreshSkipPrompt() {
        updateSkipPrompt(position: positionMirror, duration: transportDurationSec, paused: pausedMirror)
    }

    func refineSkipSeek(targetSec: Double, fromSec: Double, now: TimeInterval) {
        skipPlanner.refineSeek(targetSec: targetSec, fromSec: fromSec, now: now)
    }

    func recordUserSpan(fromSec: Double, toSec: Double) {
        skipPlanner.recordUserSpan(fromSec: fromSec, toSec: toSec)
    }

    func beginScan(rate: Int) { applyScan(rate) }
    func setScanRate(_ rate: Int) { applyScan(rate) }

    func endScan(restoreSpeed: Double) {
        scanRate = nil
        stopScanTimer()
        guard let session else { return }
        let speed = AetherRatePlan.clampedSpeed(restoreSpeed, maxRate: session.maxRate)
        session.setRate(Float(speed))
        print("[AetherPlayer] scan end, rate \(speed)")
    }

    /// The Aspect pill is hidden on Aether in Phase 1 (plan section 14).
    func cycleAspect() {}

    var seekPreviewSource: SeekPreviewSource? { previewSource }
    func scrubPreviewEnded(now: TimeInterval) {}
    func scrubPreviewMissed(targetSec: Double, matchSec: Double?) {}
}

extension AetherTVPlayerViewController: PlayerTransportHost {
    var pauseCardEnabled: Bool { playerSettings?.pauseOverlayEnabled != false }
    var isLeavingPlayerForLog: Bool { isLeavingPlayer }
    /// The façade pushes its track lists: nothing to walk before a popover opens.
    func prepareTracksForPanel() {}
    func exitPlayer() {
        closeFailover()
        onExit?()
    }
}

extension AetherTVPlayerViewController: ChromePlayerController {}

// MARK: - Surface and overlay host

/// The session's surface with the subtitle overlay above it; the chrome draws over this controller.
struct AetherSurfaceRoot: View {
    let surface: AnyView
    let subtitles: AetherSubtitleOverlayModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            surface.ignoresSafeArea()
            AetherSubtitleOverlay(model: subtitles)
        }
    }
}

// MARK: - Scrub stills

/// The scrub card's frames from `session.scrubFrame` (resident segments or the software packet cache;
/// never a second connection), with a small recent-frame cache keyed on 2 s buckets and fenced by the
/// session's source generation. HDR stills are shown as the engine returns them (W1-A open point 6).
@MainActor
final class AetherScrubPreviewSource: SeekPreviewSource {
    static let maxWidth = 480
    static let capacity = 48
    private weak var session: AetherPlaybackSession?
    private var cache: [Int: SeekPreviewMatch] = [:]
    private var order: [Int] = []
    private var generation: UUID?

    init(session: AetherPlaybackSession) {
        self.session = session
    }

    func thumbnail(near sec: Double) async -> CGImage? {
        await match(near: sec)?.image
    }

    func match(near sec: Double) async -> SeekPreviewMatch? {
        guard let session, session.supportsScrubStills, sec.isFinite else { return nil }
        fence(session.scrubStillsSourceGeneration)
        let key = Int((sec / 2).rounded())
        if let hit = cache[key] { return hit }
        guard let frame = await session.scrubFrame(atSec: sec, refined: false, maxWidth: Self.maxWidth,
                                                   isCancelled: { false }) else { return nil }
        guard generation == session.scrubStillsSourceGeneration else { return nil }
        let match = SeekPreviewMatch(image: frame.image, sec: frame.actualSec, origin: .decode)
        store(match, key: key)
        return match
    }

    func nearest(to sec: Double) async -> SeekPreviewMatch? {
        guard let session else { return nil }
        fence(session.scrubStillsSourceGeneration)
        return cache.values.min { abs($0.sec - sec) < abs($1.sec - sec) }
    }

    private func fence(_ current: UUID) {
        if generation != current {
            generation = current
            cache.removeAll()
            order.removeAll()
        }
    }

    private func store(_ match: SeekPreviewMatch, key: Int) {
        if cache[key] == nil { order.append(key) }
        cache[key] = match
        while order.count > Self.capacity {
            cache[order.removeFirst()] = nil
        }
    }
}
