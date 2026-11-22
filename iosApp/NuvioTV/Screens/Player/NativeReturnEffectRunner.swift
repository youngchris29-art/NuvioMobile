import Foundation

// Return from background, wave 3 (spec 5.2): the native coordinator's effect runner. The coordinator
// forwards lifecycle, transport and pipeline events here and implements `NativeReturnHost`; every
// return decision is `PlayerForegroundReturnRule`'s, every restore runs through `PlayerRestoreSequence`,
// the restart's own steps are `NativeRestartMachine`'s, and this type only turns their effects into
// host calls. It owns the rule, the machine, the restore watchdog, the picture nudge timer and the
// held position, and it is the one owner of every failure while a return is in progress. Same shape
// as the Aether route's `AetherReturnEffectRunner` (the timer seam is shared). Greppable: `[Return]`.

/// A failure the coordinator saw. While a return is in progress the runner owns it (spec 5.2.2).
nonisolated enum NativeReturnFailure: Sendable, Equatable {
    /// The remux reported `.failed`, or a pre-playback stage found nothing to serve.
    case remux(String)
    /// The loopback server could not bind.
    case bindFailed
    /// The current item failed before it was ever ready (`retryAllowed`: the master carries a Dolby
    /// Vision SUPPLEMENTAL-CODECS the one signaling retry could drop).
    case itemPreReady(retryAllowed: Bool)
    /// The current item failed after it was ready, or the stall / not-ready rules gave up on it.
    case itemAfterReady(String)

    var token: String {
        switch self {
        case .remux(let stage): return "remux:\(stage)"
        case .bindFailed: return "bindFailed"
        case .itemPreReady: return "itemFailedPreReady"
        case .itemAfterReady(let why): return "itemFailedAfterReady:\(why)"
        }
    }
}

/// What the runner needs from the native coordinator: facts read now, and the effects that touch the
/// pipeline. Tests use a fake (`NativeRestartWiringTests`).
@MainActor
protocol NativeReturnHost: AnyObject {
    // Facts
    func returnSnapshot(enteredAtUptime: TimeInterval) -> PlayerBackgroundSnapshot
    func returnFacts(enteredBackground: Bool, awaySec: Double, health: PlayerNativeHealth) -> PlayerReturnFacts
    func returnBackstopSample(now: TimeInterval) -> PlayerBackstopSample
    var returnIdentity: PlaybackIdentity { get }
    var returnPresence: PlayerPresence { get }
    var returnClockSec: Double? { get }
    /// `AVPlayerViewController.isReadyForDisplay` for the coordinator's current player (spec 4.9).
    var returnPictureReady: Bool { get }
    /// The restore budget (`MPVStartWatchdog.defaultLimitSeconds`, spec 5.2.2 step 6).
    var returnRestoreBudgetSec: Double { get }
    /// didBecomeActive: loopback ping, `listenerFailedAfterReady`, remux state. Answers on the main actor.
    func returnProbeHealth(_ done: @escaping @MainActor (PlayerNativeHealth) -> Void)
    /// Step 1 of the restore sequence: the audio-session activation.
    func returnActivateAudioSession() async

    // Rule effects
    func returnBackgrounded()
    func returnPlay()
    func returnPause()
    func returnHandOff(atSec: Double, reason: String)
    /// spec-mpv-return §3.3: the return rule's handoff carries an explicit payload for mpv.
    func returnNoteTransfer(_ transfer: PlayerReturnTransfer)
    func returnExit()
    func returnSetUI(_ ui: PlayerReturnUI)
    /// nil = released: consumers go back to the live clock.
    func returnSetHeldPosition(_ sec: Double?)
    func returnSetTransportRefused(_ refused: Bool)
    func returnNudgePicture(atSec: Double)

    // Restart effects (`NativeRestartMachine`); every one carries the machine token it belongs to.
    func restartWillBegin(token: Int, kind: NativeRestartKind, target: NativeRestartTarget)
    func restartSetPosition(_ sec: Double)
    func restartTeardown(keepPlayer: Bool)
    func restartLaunchRemux(token: Int)
    func restartMakeServer(token: Int)
    func restartMakeItem(token: Int, signalingAttempt: Int)
    func restartSeek(token: Int, toSec: Double, exact: Bool, generation: Int)
    func restartRestoreTracks(token: Int, audio: String?, subtitle: String?)
    func restartStartTrackersOnce()
    /// From scratch, item ready: check identity, read the resume row, answer `resumeChosen` (or
    /// `identityChanged`) through `machine(_:token:)`.
    func restartChooseResume(token: Int)
    /// The machine left its active states (settled, failed or cancelled).
    func restartEnded(token: Int, settled: Bool)
}

extension NativeReturnHost {
    func returnNoteTransfer(_ transfer: PlayerReturnTransfer) {}
}

@MainActor
final class NativeReturnEffectRunner {
    private(set) var rule: PlayerForegroundReturnRule
    private(set) var machine = NativeRestartMachine()
    private weak var host: NativeReturnHost?
    private let schedule: AetherReturnSchedule
    private let now: () -> TimeInterval

    /// The coordinator's own lifecycle flags (never `UIApplication.applicationState`, spec 9.3).
    private(set) var appActive = true
    private var backgroundSeen = false
    /// Bumped at every didEnterBackground: a health probe that answers after a newer background is dropped.
    private var backgroundGeneration = 0
    private var enteredAtUptime: TimeInterval = 0
    private var lastSnapshot: PlayerBackgroundSnapshot?
    private(set) var lastHealth: PlayerNativeHealth = .unknown
    private(set) var transportRefused = false
    private(set) var heldPosition: Double?

    private enum Input {
        case rule(PlayerReturnEvent, observed: Bool)
        case machine(NativeRestartEvent, token: Int, stopStale: (@MainActor () -> Void)?)
    }
    private var queue: [Input] = []
    private var draining = false
    /// An observed press (AVKit already applied it): the rule's pass-through transport effect is dropped.
    private var dropTransportEffects = false
    private var sequenceTask: Task<Void, Never>?
    private var watchdog: AetherReturnTimer?
    private var nudge: AetherReturnTimer?
    private var handOffNote = "native: foreground restore failed"
    /// The kind of the restart the machine runs (for the cancel's teardown).
    private var machineKind: NativeRestartKind?
    private(set) var trace: [String] = []
    private(set) var lastOutcome = "-" {
        didSet { if lastOutcome != oldValue { outcomeTrail = Array((outcomeTrail + [lastOutcome]).suffix(6)) } }
    }
    /// The last few outcomes in order (DEBUG probe `trail=`), so a leg can see a short-lived one such as
    /// `refused` before the fresh load replaces it.
    private(set) var outcomeTrail: [String] = []

    init(owner: PlaybackIdentity, host: NativeReturnHost,
         schedule: @escaping AetherReturnSchedule = AetherReturnEffectRunner.liveSchedule,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        rule = PlayerForegroundReturnRule(owner: owner)
        self.host = host
        self.schedule = schedule
        self.now = now
    }

    var owner: PlaybackIdentity { rule.owner }
    var nudged: Bool { rule.nudgeIssued }
    /// The machine runs: every pipeline step and failure of the coordinator feeds it.
    var restartActive: Bool { machine.isActive }

    /// DEBUG probe: `<mode>/<last outcome>`.
    var probeMode: String {
        switch rule.mode {
        case .idle: return "idle"
        case .away: return "away"
        case .deferred(.operationSettles): return "deferredOp"
        case .deferred(.playerFront): return "deferredFront"
        case .preparing: return "preparing"
        case .restoring: return "restoring"
        case .awayRestoring: return "awayRestoring"
        case .abandoned: return "abandoned"
        case .finished: return "finished"
        }
    }


    /// While true, presses are recorded as intent and the transport is held paused (I1, I5).
    private var holdsTransport: Bool { rule.holdsIntent }

    // MARK: Events from the coordinator

    func enteredBackground() {
        appActive = false
        backgroundSeen = true
        backgroundGeneration += 1
        guard let host else { return }
        // Only a return that starts now takes a snapshot; a second background during a return keeps the
        // first one (W2 ruling 12), so the names the restart restores are the ones the viewer chose.
        if rule.mode == .idle || lastSnapshot == nil {
            enteredAtUptime = now()
            lastSnapshot = host.returnSnapshot(enteredAtUptime: enteredAtUptime)
        }
        if let snapshot = lastSnapshot { feed(.rule(.enteredBackground(snapshot), observed: false)) }
        host.returnBackgrounded()
    }

    func becameActive() {
        appActive = true
        let entered = backgroundSeen
        backgroundSeen = false
        guard entered, let host else {
            feed(.rule(.becameActive(facts(entered: entered)), observed: false))
            return
        }
        let generation = backgroundGeneration
        host.returnProbeHealth { [weak self] health in
            guard let self, generation == self.backgroundGeneration, self.appActive else {
                print("[Return] health probe answered after a newer background: dropped")
                return
            }
            self.lastHealth = health
            self.feed(.rule(.becameActive(self.facts(entered: true)), observed: false))
        }
    }

    /// The player's rate changed (KVO on the coordinator's current player). While a return holds the
    /// transport, a start of playback is never read as a press (W4, measured on the sim 2026-11-21: one
    /// press can raise the rate twice, the system resumes the old player on the way back from a real
    /// background, and a press during the restart raises nothing at all because AVKit ignores an
    /// item-less player); it only pauses the held player again (I1). Presses come from
    /// `observedPress()`. In idle a start or stop is passed to the rule (the backstop's first Play) and
    /// the rule's own transport effect is dropped, since AVKit already applied it.
    func observedRate(playing: Bool) {
        if holdsTransport {
            guard playing else { return }
            record("rate rise held")
            host?.returnPause()
            return
        }
        guard rule.mode == .idle else { return }
        feed(.rule(playing ? .userPlay(facts(entered: false)) : .userPause, observed: true))
    }

    /// A Play/Pause press (the host's recogniser, which sees it whether or not AVKit acts on it). While
    /// the return holds the transport it flips the intent (last press wins, I5); otherwise the rate
    /// observer already carries it.
    func observedPress() {
        guard holdsTransport else { return }
        let toPlay = rule.pressAsksForPlay(transportPaused: true)
        record(toPlay ? "press play (held)" : "press pause (held)")
        feed(.rule(toPlay ? .userPlay(facts(entered: false)) : .userPause, observed: true))
        host?.returnPause()
    }

    /// The observe loop's tick (native: 3 s).
    func tick() {
        guard let host, appActive, rule.mode == .idle else { return }
        feed(.rule(.backstopTick(host.returnBackstopSample(now: now()), facts(entered: false)), observed: false))
    }

    /// The screen came back from a cover.
    func reappeared() {
        guard rule.mode == .deferred(.playerFront) else { return }
        feed(.rule(.reappeared(facts(entered: true)), observed: false))
    }

    /// `isReadyForDisplay` changed for the current player.
    func pictureChanged() {
        postChecks()
    }

    /// A pipeline step the machine waits on (`firstSegmentReady`, `itemReady`, `seekLanded`,
    /// `resumeChosen`, `identityChanged`, `audioActivated`).
    func machine(_ event: NativeRestartEvent, token: Int) {
        feed(.machine(event, token: token, stopStale: nil))
    }

    /// The loopback bind of a restart answered. The coordinator already dropped a completion whose server
    /// is no longer its own; `stopStale` stops this one if the machine finds it stale too.
    func bindCompleted(token: Int, url: URL?, stopStale: @escaping @MainActor () -> Void) {
        if let url {
            feed(.machine(.bindSucceeded(url: url.absoluteString), token: token, stopStale: stopStale))
        } else {
            feed(.machine(.bindFailed, token: token, stopStale: nil))
        }
    }

    /// A failure the coordinator saw. Returns true when the return owns it (the coordinator then does
    /// nothing else: no classification, no fallback).
    func failureArrived(_ failure: NativeReturnFailure) -> Bool {
        if machine.isActive {
            record("failure \(failure.token)")
            handOffNote = "native: foreground restore failed (\(failure.token))"
            let event: NativeRestartEvent
            switch failure {
            case .remux(let stage): event = .remuxFailed(stage: stage)
            case .bindFailed: event = .bindFailed
            case .itemPreReady(let retry): event = .itemFailedPreReady(signalingRetryAllowed: retry)
            case .itemAfterReady: event = .itemFailedAfterReady
            }
            feed(.machine(event, token: machine.token, stopStale: nil))
            return true
        }
        switch rule.mode {
        case .idle, .abandoned, .finished:
            return false
        case .restoring:
            // The machine settled; the rule waits for the frame: the new pipeline failed.
            record("failure \(failure.token)")
            handOffNote = "native: foreground restore failed (\(failure.token))"
            feed(.rule(.restoreFinished(token: rule.token, .failed(failure.token), facts(entered: true)), observed: false))
            return true
        case .away, .deferred, .preparing, .awayRestoring:
            // Decision C: the return restarts the whole pipeline whatever it finds, so a failure of the old
            // one while a return is pending is the return's to absorb, never a second owner's fallback.
            print("[Return] failure \(failure.token) absorbed: the return restarts the pipeline")
            return true
        }
    }

    /// Exit, a context swap, a handoff started elsewhere.
    func cancelled() {
        feed(.rule(.cancelled, observed: false))
        if machine.isActive {
            feed(.machine(.stop, token: machine.token, stopStale: nil))
        }
        stopTimers()
    }

    // MARK: Feeding

    private func facts(entered: Bool) -> PlayerReturnFacts {
        guard let host else {
            return PlayerReturnFacts(identity: rule.owner, enteredBackground: entered, awaySec: 0, presence: .leaving,
                                     contextSwapPending: false, operationInFlight: false, aetherNeedsRestore: nil,
                                     aetherSessionFailed: false, clockSec: nil, nativeHealth: lastHealth)
        }
        return host.returnFacts(enteredBackground: entered, awaySec: max(0, now() - enteredAtUptime), health: lastHealth)
    }

    /// Serialised: an event fed while effects run waits its turn.
    private func feed(_ input: Input) {
        queue.append(input)
        guard !draining else { return }
        draining = true
        while !queue.isEmpty {
            let next = queue.removeFirst()
            switch next {
            case .rule(let event, let observed):
                noteOutcome(event)
                dropTransportEffects = observed
                runRule(rule.handle(event))
                dropTransportEffects = false
            case .machine(let event, let token, let stopStale):
                let wasActive = machine.isActive
                let activeToken = machine.token
                let fx = machine.handle(event, token: token)
                runMachine(fx, token: token, stopStale: stopStale)
                if wasActive, !machine.isActive, activeToken == machine.token {
                    host?.restartEnded(token: machine.token, settled: machine.state == .settled)
                }
                if case .itemReady = event, machine.state == .resuming, machine.token == token {
                    host?.restartChooseResume(token: token)
                }
            }
        }
        draining = false
        postChecks()
    }

    /// After every batch: timers that no longer apply are cancelled; a frame that rose after the machine
    /// settled is reported (spec 4.9; the machine is no longer active then).
    private func postChecks() {
        guard !draining else { return }
        if rule.mode != .restoring {
            cancelWatchdog()
            nudge?.cancel()
            nudge = nil
        }
        if rule.mode == .restoring, rule.framePending, !machine.isActive, host?.returnPictureReady == true {
            record("frameShown")
            feed(.rule(.frameShown(token: rule.token), observed: false))
        }
    }

    private func runRule(_ effects: [PlayerReturnEffect]) {
        for effect in effects {
            switch effect {
            case .startRestore(let kind, let token):
                record("startRestore \(kind)")
                startSequence(kind, token: token)
            case .cancelRestore:
                record("cancelRestore")
                sequenceTask?.cancel()
                sequenceTask = nil
                cancelWatchdog()
                nudge?.cancel()
                nudge = nil
                if machine.isActive {
                    // Spec 6.2: the half-built pipeline is torn down; `lastPositionSec` (set by the
                    // machine's first effect) is kept, and the next return restarts again.
                    let keep = machineKind == .midPlay
                    queue.append(.machine(.cancel, token: machine.token, stopStale: nil))
                    host?.restartTeardown(keepPlayer: keep)
                }
            case .pauseTransport:
                if dropTransportEffects { continue }
                record("pause")
                host?.returnPause()
            case .play:
                if dropTransportEffects { continue }
                guard let host, PlaybackWriteGuard.allows(owner: rule.owner, current: host.returnIdentity) else {
                    print("[Return] play refused: identity changed")
                    host?.returnExit()
                    continue
                }
                record("play")
                host.returnPlay()
            case .handOff(let atSec):
                guard let host, PlaybackWriteGuard.allows(owner: rule.owner, current: host.returnIdentity) else {
                    print("[Return] handoff refused: identity changed")
                    host?.returnExit()
                    continue
                }
                record("handOff \(String(format: "%.1f", atSec))")
                stopTimers()
                host.returnNoteTransfer(PlayerReturnTransfer(owner: rule.owner, intent: rule.intent == .play ? .play : .pause,
                                                             atSec: atSec, generation: backgroundGeneration))
                host.returnHandOff(atSec: atSec, reason: handOffNote)
            case .exitPlayer:
                record("exit")
                stopTimers()
                host?.returnExit()
            case .stopStartWatchdog, .rearmStartWatchdog:
                // The native start has no watchdog of its own; a restart from scratch runs under the
                // restore budget the sequence arms.
                break
            case .pauseRestoreWatchdog:
                cancelWatchdog()
            case .resumeRestoreWatchdog:
                armWatchdog(token: rule.token)
            case .setUI(let ui):
                host?.returnSetUI(ui)
            case .holdPosition(let sec):
                heldPosition = sec
                host?.returnSetHeldPosition(sec)
            case .releasePosition:
                heldPosition = nil
                host?.returnSetHeldPosition(nil)
            case .refuseTransport(let refused):
                transportRefused = refused
                host?.returnSetTransportRefused(refused)
            case .schedulePictureNudge(let token, let afterSec):
                nudge?.cancel()
                nudge = schedule(afterSec) { [weak self] in
                    self?.nudge = nil
                    self?.feed(.rule(.pictureNudgeDue(token: token), observed: false))
                }
            case .nudgePicture(let atSec):
                record("nudge \(String(format: "%.1f", atSec))")
                host?.returnNudgePicture(atSec: atSec)
            case .captureBackstopSnapshot:
                // W5 r3: the rebuild restores the selections of this instant, not the background's.
                guard let host else { continue }
                let fresh = host.returnSnapshot(enteredAtUptime: now())
                lastSnapshot = fresh
                record("backstop snapshot")
                feed(.rule(.backstopRebuild(fresh, facts(entered: false)), observed: false))
            case .log(let line):
                print(line)
            }
        }
    }

    private func runMachine(_ effects: [NativeRestartEffect], token: Int, stopStale: (@MainActor () -> Void)?) {
        for effect in effects {
            switch effect {
            case .setPosition(let sec):
                record("setPosition \(String(format: "%.1f", sec))")
                host?.restartSetPosition(sec)
            case .teardownPipeline(let keep):
                record("teardown keepPlayer=\(keep ? 1 : 0)")
                host?.restartTeardown(keepPlayer: keep)
            case .activateAudio:
                // Step 1 of the sequence activated the session (bounded); the machine moves on.
                record("audioActivated")
                queue.append(.machine(.audioActivated, token: token, stopStale: nil))
            case .launchRemux:
                record("launchRemux")
                host?.restartLaunchRemux(token: token)
            case .makeServer:
                record("makeServer")
                host?.restartMakeServer(token: token)
            case .stopServer:
                record("stopServer stale")
                stopStale?()
            case .makeItem(let attempt):
                record("makeItem \(attempt)")
                host?.restartMakeItem(token: token, signalingAttempt: attempt)
            case .seek(let sec, let exact, let generation):
                record("seek \(String(format: "%.1f", sec))")
                host?.restartSeek(token: token, toSec: sec, exact: exact, generation: generation)
            case .restoreTracks(let audio, let subtitle):
                host?.restartRestoreTracks(token: token, audio: audio, subtitle: subtitle)
            case .startTrackersOnce:
                record("startTrackersOnce")
                host?.restartStartTrackersOnce()
            case .report(let outcome):
                record("report \(outcome)")
                if case .failed(let why) = outcome { handOffNote = "native: foreground restore failed (\(why))" }
                if case .timedOut = outcome { handOffNote = "native: foreground restore failed (timedOut)" }
                queue.append(.rule(.restoreFinished(token: token, outcome, facts(entered: true)), observed: false))
            case .reportAbandon:
                record("reportAbandon")
                // A fact-carrying event under the changed identity: the rule's abandon row (I7).
                queue.append(.rule(.restoreFinished(token: token, .failed("identityChanged"), facts(entered: true)),
                                   observed: false))
            }
        }
    }

    // MARK: The restore

    private func startSequence(_ kind: PlayerRestoreKind, token: Int) {
        sequenceTask?.cancel()
        sequenceTask = Task { @MainActor [weak self] in
            await PlayerRestoreSequence.run(
                token: token,
                preconditions: { [weak self] in
                    self?.record("audio")
                    await self?.host?.returnActivateAudioSession()
                },
                stillCurrent: { [weak self] in self?.gate(token: token) ?? .dropped },
                armWatchdog: { [weak self] in self?.armWatchdog(token: token) },
                report: { [weak self] event in self?.sequenceReported(event) },
                invoke: { [weak self] in self?.invoke(kind, token: token) })
        }
    }

    private func gate(token: Int) -> PlayerRestoreGate {
        guard let host, token == rule.token, appActive,
              host.returnIdentity == rule.owner, host.returnPresence != .leaving else { return .dropped }
        return .proceed
    }

    private func sequenceReported(_ event: PlayerReturnEvent) {
        if case .sequenceDropped(_, .preconditionTimedOut) = event {
            handOffNote = "native: foreground restore failed (audio session not ready)"
        }
        feed(.rule(event, observed: false))
        // W2 ruling 2: a re-check that failed while active decides again at once with fresh facts.
        if case .sequenceDropped(_, .dropped) = event, appActive, rule.mode == .away {
            feed(.rule(.becameActive(facts(entered: true)), observed: false))
        }
    }

    /// Step 4: the restart. Its watchdog is armed (I2).
    private func invoke(_ kind: PlayerRestoreKind, token: Int) {
        guard let host else { return }
        let snapshot = rule.snapshot
        let restartKind: NativeRestartKind
        let target: NativeRestartTarget
        switch kind {
        case .nativeRestart(let atSec):
            restartKind = .midPlay
            target = NativeRestartTarget(positionSec: atSec, audioName: snapshot?.audioName,
                                         subtitleName: snapshot?.subtitleName)
        case .nativeRestartFromScratch:
            restartKind = .fromScratch
            target = NativeRestartTarget(positionSec: 0, audioName: nil, subtitleName: nil)
        case .aetherReload, .aetherFreshLoad:
            handOffNote = "native: an Aether restore on the native route"
            feed(.rule(.restoreFinished(token: token, .failed("wrong route"), facts(entered: true)), observed: false))
            return
        }
        machineKind = restartKind
        record("begin \(restartKind)")
        host.restartWillBegin(token: token, kind: restartKind, target: target)
        feed(.machine(.begin(restartKind, target), token: token, stopStale: nil))
    }

    // MARK: Restore watchdog

    private func armWatchdog(token: Int) {
        cancelWatchdog()
        let budget = host?.returnRestoreBudgetSec ?? MPVStartWatchdog.defaultLimitSeconds
        record("watchdog \(Int(budget))")
        watchdog = schedule(budget) { [weak self] in
            self?.watchdog = nil
            self?.watchdogFired(token: token, budget: budget)
        }
    }

    private func watchdogFired(token: Int, budget: Double) {
        guard rule.mode == .restoring else { return }
        print("[Return] restore watchdog fired after \(Int(budget)) s (machine=\(machine.state), picture=\(host?.returnPictureReady == true))")
        handOffNote = "native: foreground restore failed (timedOut)"
        if machine.isActive {
            // The machine is the one owner while it runs: its deadline reports the timeout.
            feed(.machine(.deadline, token: machine.token, stopStale: nil))
        } else {
            feed(.rule(.restoreTimedOut(token: rule.token, facts(entered: true)), observed: false))
        }
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func stopTimers() {
        sequenceTask?.cancel()
        sequenceTask = nil
        cancelWatchdog()
        nudge?.cancel()
        nudge = nil
    }

    // MARK: Logs

    private func noteOutcome(_ event: PlayerReturnEvent) {
        switch event {
        case .restoreFinished(let t, let outcome, _) where t == rule.token:
            switch outcome {
            case .settled(_, let picture): lastOutcome = picture ? "settled" : "settledNoPicture"
            case .refused: lastOutcome = "refused"
            case .notNeeded: lastOutcome = "notNeeded"
            case .failed: lastOutcome = "failed"
            case .timedOut: lastOutcome = "timedOut"
            }
        case .restoreTimedOut(let t, _) where t == rule.token: lastOutcome = "timedOut"
        case .sequenceDropped(let t, let gate) where t == rule.token: lastOutcome = "dropped.\(gate)"
        case .frameShown(let t) where t == rule.token: lastOutcome = "settled"
        default: break
        }
    }

    private func record(_ step: String) {
        trace.append(step)
        if trace.count > 300 { trace.removeFirst(trace.count - 300) }
    }
}

#if DEBUG
/// `-debug.nativeBackgroundFault killListener|failRemuxInput|failRestart` (T-UI-N2 to N4, R6), read once
/// per player. `killListener` cancels the loopback listener at didEnterBackground; `failRemuxInput` makes
/// the remux worker's next source read fail at didEnterBackground; `failRestart` makes the restart's
/// server step fail once (a bind failure inside the one attempt, so the return hands to mpv);
/// `delayRestart` holds the restart's server step 5 s once, so a press can land while it runs.
enum DebugNativeBackgroundFault: String {
    case killListener, failRemuxInput, failRestart, delayRestart

    static func current(defaults: UserDefaults = .standard) -> DebugNativeBackgroundFault? {
        defaults.string(forKey: "debug.nativeBackgroundFault").flatMap(DebugNativeBackgroundFault.init(rawValue:))
    }
}
#endif
