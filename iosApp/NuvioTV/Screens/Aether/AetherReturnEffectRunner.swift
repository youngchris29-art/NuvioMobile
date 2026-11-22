import Foundation
import NuvioAether

// Return from background, wave 2 (spec 5.1.3): the Aether controller's effect runner. The controller
// forwards lifecycle, transport and session events here and implements `AetherReturnHost`; every
// decision is `PlayerForegroundReturnRule`'s, every restore runs through `PlayerRestoreSequence`, and
// this type only turns the rule's effects into calls. It owns the restore watchdog, the picture nudge
// timer, the restore task and the held position. Greppable prefix: `[Return]`.

/// The session calls the runner makes. `AetherPlaybackSession` conforms; tests use a fake.
@MainActor
protocol AetherReturnSession: AnyObject {
    var needsForegroundRestore: Bool { get }
    /// The façade's per-load frame latch (lowered by the restore, raised by the engine's ready-for-display).
    var firstFrameShown: Bool { get }
    func restoreAfterBackground() async throws -> AetherForegroundRestoreOutcome
    func seek(toSec target: Double, exact: Bool) async -> AetherSeekOutcome
}

extension AetherPlaybackSession: AetherReturnSession {}

/// What the runner needs from the controller: facts gathered now, and the effects that touch its state.
@MainActor
protocol AetherReturnHost: AnyObject {
    func returnSnapshot(enteredAtUptime: TimeInterval) -> PlayerBackgroundSnapshot
    func returnFacts(enteredBackground: Bool, awaySec: Double) -> PlayerReturnFacts
    func returnBackstopSample(now: TimeInterval) -> PlayerBackstopSample
    var returnIdentity: PlaybackIdentity { get }
    var returnPresence: PlayerPresence { get }
    /// The session phase is paused or playing (a restore's transport has settled).
    var returnTransportSettled: Bool { get }
    var returnClockSec: Double? { get }
    /// The restore budget (`MPVStartWatchdog.limitSeconds(shortened:startupLimitSec:)`).
    var returnRestoreBudgetSec: Double { get }
    /// Step 1 of the restore sequence: `AetherPlaybackSession.ensureAudioSessionActive()`.
    func returnActivateAudioSession() async
    /// Step 3, right before the engine call: the controller's per-load frame mirror lowered, spinner up.
    func returnRestoreWillInvoke()
    /// The fresh-load fallback: `runLoad(session, restoreRequest(at:))`, the one load caller (spec I8).
    func returnRunRestoreLoad(atSec: Double)
    func returnPlay()
    func returnPause()
    func returnHandOff(atSec: Double, reason: String)
    func returnExit()
    func returnSetUI(_ ui: PlayerReturnUI)
    /// nil = released: the mirror takes the last held value and the next finite clock sample as is.
    func returnSetHeldPosition(_ sec: Double?)
    func returnStopStartWatchdog()
    func returnRearmStartBudget()
}

/// A scheduled callback the runner can cancel (the restore watchdog, the picture nudge).
@MainActor
protocol AetherReturnTimer: AnyObject { func cancel() }

/// `(seconds, body) -> timer`, on the main actor. Tests inject a manual clock.
typealias AetherReturnSchedule = @MainActor (Double, @escaping @MainActor () -> Void) -> AetherReturnTimer

@MainActor
private final class DispatchReturnTimer: AetherReturnTimer {
    private let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

@MainActor
final class AetherReturnEffectRunner {
    static let liveSchedule: AetherReturnSchedule = { seconds, body in
        let item = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
        return DispatchReturnTimer(item)
    }

    private(set) var rule: PlayerForegroundReturnRule
    private let session: AetherReturnSession
    private weak var host: AetherReturnHost?
    private let schedule: AetherReturnSchedule
    private let now: () -> TimeInterval

    /// The controller's own lifecycle flags (never `UIApplication.applicationState`: the DEBUG cycle posts
    /// the notifications in process, spec 9.3).
    private(set) var appActive = true
    /// A didEnterBackground arrived since the last didBecomeActive.
    private var backgroundSeen = false
    private var enteredAtUptime: TimeInterval = 0
    private var lastSnapshot: PlayerBackgroundSnapshot?
    /// `refuseTransport` as the rule last set it: seeks, scan, speed and skips are dropped while true.
    private(set) var transportRefused = false
    /// `holdPosition` / `releasePosition`: the authoritative position every consumer reads (spec 4.7).
    private(set) var heldPosition: Double?

    private var queue: [PlayerReturnEvent] = []
    private var draining = false
    private var sequenceTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var watchdog: AetherReturnTimer?
    private var nudge: AetherReturnTimer?
    /// The restore op returned (`.reloaded`, or the fallback's load returned): waiting for the transport.
    private var awaitingSettleToken: Int?
    /// The fresh-load fallback was sent: its `loadReturned` belongs to this token.
    private var awaitingLoadToken: Int?
    /// The `[Return]` reason the next handoff carries.
    private var handOffNote = "foreground restore failed"
    /// Recorded effects, for the wiring tests' call order (bounded).
    private(set) var trace: [String] = []

    init(owner: PlaybackIdentity, session: AetherReturnSession, host: AetherReturnHost,
         schedule: @escaping AetherReturnSchedule = AetherReturnEffectRunner.liveSchedule,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        rule = PlayerForegroundReturnRule(owner: owner)
        self.session = session
        self.host = host
        self.schedule = schedule
        self.now = now
    }

    var owner: PlaybackIdentity { rule.owner }

    /// DEBUG probe and logs: the last restore outcome the rule was fed, the mode, the one nudge.
    private(set) var lastOutcome = "-" {
        didSet { if lastOutcome != oldValue { outcomeTrail = Array((outcomeTrail + [lastOutcome]).suffix(6)) } }
    }
    /// The last few outcomes in order (DEBUG probe `trail=`), so a leg can see a short-lived one such as
    /// `refused` before the fresh load replaces it.
    private(set) var outcomeTrail: [String] = []
    var nudged: Bool { rule.nudgeIssued }
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
    var blocksTransport: Bool { rule.blocksTransport }

    /// While true, a session failure is the restore's (or the deferred operation's), never the failover
    /// ladder's (spec 5.1.2): the controller hands it here instead of to its decider.
    var ownsFailures: Bool {
        switch rule.mode {
        case .preparing, .restoring, .deferred(.operationSettles): return true
        default: return false
        }
    }

    // MARK: Events from the controller

    func enteredBackground() {
        appActive = false
        backgroundSeen = true
        guard let host else { return }
        // Only a return that starts now takes a snapshot (the controller reads tracks and delay into it);
        // a second background during a return keeps the first one (spec 4.5), so the event carries it.
        if rule.mode == .idle || lastSnapshot == nil {
            enteredAtUptime = now()
            lastSnapshot = host.returnSnapshot(enteredAtUptime: enteredAtUptime)
        }
        guard let snapshot = lastSnapshot else { return }
        feed(.enteredBackground(snapshot))
    }

    func becameActive() {
        appActive = true
        let entered = backgroundSeen
        backgroundSeen = false
        feed(.becameActive(facts(entered: entered)))
    }

    /// A Play/Pause press. `toPlay`: the press asks for play (the transport is paused now).
    func userToggle(toPlay: Bool) {
        if toPlay {
            if rule.mode == .idle, session.needsForegroundRestore, let host {
                // 6.1: a late engine teardown seen at the press; the reload starts with Play queued.
                enteredAtUptime = now()
                let snapshot = host.returnSnapshot(enteredAtUptime: enteredAtUptime)
                lastSnapshot = snapshot
                feed(.restoreOwedInForeground(snapshot, facts(entered: true), pressedPlay: true))
            } else {
                feed(.userPlay(facts(entered: false)))
            }
        } else {
            feed(.userPause)
        }
    }

    /// The housekeeping tick (Aether 0.5 s).
    func tick() {
        guard let host, appActive else { return }
        if rule.mode == .idle, session.needsForegroundRestore {
            enteredAtUptime = now()
            let snapshot = host.returnSnapshot(enteredAtUptime: enteredAtUptime)
            lastSnapshot = snapshot
            feed(.restoreOwedInForeground(snapshot, facts(entered: true), pressedPlay: false))
            return
        }
        if rule.mode == .idle {
            feed(.backstopTick(host.returnBackstopSample(now: now()), facts(entered: false)))
        }
    }

    /// `viewDidAppear` back from a cover.
    func reappeared() {
        guard rule.mode == .deferred(.playerFront) else { return }
        feed(.reappeared(facts(entered: true)))
    }

    /// A load returned, a seek finished or the phase left `.loading` / seeking: the deferred operation
    /// may have settled.
    func operationMayHaveSettled() {
        guard rule.mode == .deferred(.operationSettles) else { return }
        let f = facts(entered: true)
        guard !f.operationInFlight else { return }
        feed(.settled(f))
    }

    /// The session's phase or frame latch changed.
    func sessionStateChanged() {
        postChecks()
    }

    /// The controller's `loadReturned` for a load it ran (the fallback's, or any other).
    func loadReturned() {
        if let t = awaitingLoadToken, t == rule.token {
            awaitingLoadToken = nil
            awaitingSettleToken = t
        }
        operationMayHaveSettled()
        postChecks()
    }

    /// A session failure (`onFailure`, the controller's own). Returns true when the return owns it.
    func failureArrived(_ failure: AetherFailure) -> Bool {
        guard ownsFailures else { return false }
        record("failure \(failure.kind.token)")
        switch rule.mode {
        case .restoring:
            handOffNote = "aether: foregroundRestoreFailed (\(failure.kind.token))"
            feed(.restoreFinished(token: rule.token, .failed(failure.kind.token), facts(entered: true)))
        case .deferred(.operationSettles):
            // The operation the return waited on ended in a failure: row 8 decides (a fresh load).
            let f = facts(entered: true)
            feed(.settled(PlayerReturnFacts(identity: f.identity, enteredBackground: true, awaySec: f.awaySec,
                                            presence: f.presence, contextSwapPending: f.contextSwapPending,
                                            operationInFlight: false, aetherNeedsRestore: f.aetherNeedsRestore,
                                            aetherSessionFailed: true, clockSec: f.clockSec,
                                            nativeHealth: f.nativeHealth)))
        default:
            // Preparing: the sequence has not invoked the engine; the restore starts a new generation.
            log("[Return] failure \(failure.kind.token) absorbed while preparing")
        }
        return true
    }

    /// Exit, teardown, a handoff started elsewhere, a context swap.
    func cancelled() {
        feed(.cancelled)
        stopEverything()
    }

    // MARK: Feeding the rule

    private func facts(entered: Bool) -> PlayerReturnFacts {
        guard let host else {
            return PlayerReturnFacts(identity: rule.owner, enteredBackground: entered, awaySec: 0, presence: .leaving,
                                     contextSwapPending: false, operationInFlight: false, aetherNeedsRestore: nil,
                                     aetherSessionFailed: false, clockSec: nil, nativeHealth: .notApplicable)
        }
        return host.returnFacts(enteredBackground: entered, awaySec: max(0, now() - enteredAtUptime))
    }

    /// Serialised: an event fed while effects run (a handoff that feeds `cancelled`) waits its turn.
    private func feed(_ event: PlayerReturnEvent) {
        queue.append(event)
        guard !draining else { return }
        draining = true
        while !queue.isEmpty {
            let next = queue.removeFirst()
            noteOutcome(next)
            run(rule.handle(next))
        }
        draining = false
        postChecks()
    }

    /// After every batch: timers that no longer apply are cancelled, a settled transport and a risen
    /// frame are reported.
    private func postChecks() {
        guard !draining else { return }
        let mode = rule.mode
        if mode != .restoring { cancelWatchdog() }
        if mode != .restoring && mode != .awayRestoring {
            nudge?.cancel()
            nudge = nil
            if mode != .preparing {
                awaitingSettleToken = nil
                awaitingLoadToken = nil
            }
        }
        if let t = awaitingSettleToken, t == rule.token, mode == .restoring || mode == .awayRestoring,
           host?.returnTransportSettled == true {
            awaitingSettleToken = nil
            let picture = session.firstFrameShown
            record("settled picture=\(picture ? 1 : 0)")
            feed(.restoreFinished(token: t, .settled(clockSec: host?.returnClockSec, picture: picture),
                                  facts(entered: true)))
            return
        }
        if rule.mode == .restoring, rule.framePending, awaitingSettleToken == nil, session.firstFrameShown {
            record("frameShown")
            feed(.frameShown(token: rule.token))
        }
    }

    private func run(_ effects: [PlayerReturnEffect]) {
        for effect in effects {
            switch effect {
            case .startRestore(let kind, let token):
                record("startRestore \(kind)")
                startSequence(kind, token: token)
            case .cancelRestore:
                record("cancelRestore")
                sequenceTask?.cancel()
                sequenceTask = nil
                operationTask?.cancel()
                operationTask = nil
                cancelWatchdog()
                nudge?.cancel()
                nudge = nil
                awaitingSettleToken = nil
                awaitingLoadToken = nil
            case .pauseTransport:
                record("pause")
                host?.returnPause()
            case .play:
                guard let host, PlaybackWriteGuard.allows(owner: rule.owner, current: host.returnIdentity) else {
                    log("[Return] play refused: identity changed")
                    host?.returnExit()
                    continue
                }
                record("play")
                host.returnPlay()
            case .handOff(let atSec):
                guard let host, PlaybackWriteGuard.allows(owner: rule.owner, current: host.returnIdentity) else {
                    log("[Return] handoff refused: identity changed")
                    host?.returnExit()
                    continue
                }
                record("handOff \(String(format: "%.1f", atSec))")
                stopEverything()
                host.returnHandOff(atSec: atSec, reason: handOffNote)
            case .exitPlayer:
                record("exit")
                stopEverything()
                host?.returnExit()
            case .stopStartWatchdog:
                host?.returnStopStartWatchdog()
            case .rearmStartWatchdog:
                host?.returnRearmStartBudget()
            case .pauseRestoreWatchdog:
                record("watchdog paused")
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
            case .schedulePictureNudge(let token, let afterSec):
                nudge?.cancel()
                nudge = schedule(afterSec) { [weak self] in
                    self?.nudge = nil
                    self?.feed(.pictureNudgeDue(token: token))
                }
            case .nudgePicture(let atSec):
                record("nudge \(String(format: "%.1f", atSec))")
                let session = self.session
                Task { @MainActor [weak self] in
                    let outcome = await session.seek(toSec: atSec, exact: true)
                    self?.log("[Return] picture nudge \(outcome)")
                    self?.postChecks()
                }
            case .log(let line):
                log(line)
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
                stillCurrent: { [weak self] in self?.gate(kind, token: token) ?? .dropped },
                armWatchdog: { [weak self] in
                    guard let self else { return }
                    self.host?.returnRestoreWillInvoke()
                    self.armWatchdog(token: token)
                },
                report: { [weak self] event in self?.sequenceReported(event) },
                invoke: { [weak self] in self?.invoke(kind, token: token) })
        }
    }

    /// Step 2 of the sequence.
    private func gate(_ kind: PlayerRestoreKind, token: Int) -> PlayerRestoreGate {
        guard let host, token == rule.token, appActive,
              host.returnIdentity == rule.owner, host.returnPresence != .leaving else { return .dropped }
        if case .aetherReload = kind, !session.needsForegroundRestore { return .notNeeded }
        return .proceed
    }

    private func sequenceReported(_ event: PlayerReturnEvent) {
        if case .sequenceDropped(_, .preconditionTimedOut) = event {
            handOffNote = "aether: foregroundRestoreFailed (audio session not ready)"
        }
        feed(event)
        // Spec 4.5 "preparing + sequenceDropped(.dropped)": the rule parks in `away`; when the app is
        // active (an identity change or a leaving player made the re-check fail) it decides at once with
        // fresh facts, so it never waits for a becameActive that is not coming.
        if case .sequenceDropped(_, .dropped) = event, appActive, rule.mode == .away {
            feed(.becameActive(facts(entered: true)))
        }
    }

    /// Step 4: the engine call. Its watchdog is already armed (I2).
    private func invoke(_ kind: PlayerRestoreKind, token: Int) {
        switch kind {
        case .aetherReload:
            record("restoreAfterBackground")
            let session = self.session
            operationTask = Task { @MainActor [weak self] in
                do {
                    let outcome = try await session.restoreAfterBackground()
                    self?.reloadReturned(outcome, token: token)
                } catch is CancellationError {
                    self?.log("[Return] restore cancelled")
                } catch let failure as AetherFailure {
                    self?.opFailed(failure.kind.token, token: token)
                } catch {
                    self?.opFailed("\(error)", token: token)
                }
            }
        case .aetherFreshLoad(let atSec):
            record("freshLoad \(String(format: "%.1f", atSec))")
            awaitingLoadToken = token
            host?.returnRunRestoreLoad(atSec: atSec)
        case .nativeRestart, .nativeRestartFromScratch:
            opFailed("native restore on the Aether route", token: token)
        }
    }

    private func reloadReturned(_ outcome: AetherForegroundRestoreOutcome, token: Int) {
        switch outcome {
        case .reloaded:
            guard token == rule.token else { return }
            awaitingSettleToken = token
            postChecks()
        case .notNeeded:
            feed(.restoreFinished(token: token, .notNeeded, facts(entered: true)))
        case .refused(let why):
            log("[Return] reload refused (\(why.rawValue)): fresh load at the position")
            feed(.restoreFinished(token: token, .refused, facts(entered: true)))
        }
    }

    private func opFailed(_ reason: String, token: Int) {
        guard token == rule.token else { return }
        handOffNote = "aether: foregroundRestoreFailed (\(reason))"
        feed(.restoreFinished(token: token, .failed(reason), facts(entered: true)))
    }

    // MARK: Restore watchdog (paused while away; a fresh budget from every arm)

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
        guard token == rule.token, rule.mode == .restoring else { return }
        let settled = awaitingSettleToken == nil && host?.returnTransportSettled == true
        switch AetherStartWatchdogRule.action(verdict: .fired(elapsed: budget), firstFrameShown: session.firstFrameShown,
                                              restoreSettled: settled) {
        case .standDown:
            postChecks()
        case .wait, .reportTimeout:
            handOffNote = "aether: foregroundRestoreFailed (timedOut)"
            log("[Return] restore watchdog fired after \(Int(budget)) s (settled=\(settled), picture=\(session.firstFrameShown))")
            feed(.restoreTimedOut(token: token, facts(entered: true)))
        }
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func stopEverything() {
        sequenceTask?.cancel()
        sequenceTask = nil
        operationTask?.cancel()
        operationTask = nil
        cancelWatchdog()
        nudge?.cancel()
        nudge = nil
        awaitingSettleToken = nil
        awaitingLoadToken = nil
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
        if trace.count > 200 { trace.removeFirst(trace.count - 200) }
    }

    private func log(_ line: String) { print(line) }
}

#if DEBUG
/// `-debug.aetherRestoreFault refuse|throw|delay3s` (T-UI-A3 to A5, R6): read once per player.
enum DebugAetherRestoreFault: String {
    case refuse, `throw`, delay3s

    static func current(defaults: UserDefaults = .standard) -> DebugAetherRestoreFault? {
        defaults.string(forKey: "debug.aetherRestoreFault").flatMap(DebugAetherRestoreFault.init(rawValue:))
    }
}

/// The façade with the DEBUG fault applied to `restoreAfterBackground`; everything else passes through.
@MainActor
final class DebugFaultingReturnSession: AetherReturnSession {
    private let base: AetherReturnSession
    private let fault: DebugAetherRestoreFault

    init(base: AetherReturnSession, fault: DebugAetherRestoreFault) {
        self.base = base
        self.fault = fault
    }

    var needsForegroundRestore: Bool { base.needsForegroundRestore }
    var firstFrameShown: Bool { base.firstFrameShown }

    func restoreAfterBackground() async throws -> AetherForegroundRestoreOutcome {
        switch fault {
        case .refuse:
            print("[Return] DEBUG fault: reload refused")
            return .refused(.other)
        case .throw:
            print("[Return] DEBUG fault: reload throws")
            throw AetherFailure(kind: .foregroundRestoreFailed, message: "debug fault", atSec: 0, beforeFirstFrame: true)
        case .delay3s:
            print("[Return] DEBUG fault: reload delayed 3 s")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return try await base.restoreAfterBackground()
        }
    }

    func seek(toSec target: Double, exact: Bool) async -> AetherSeekOutcome {
        await base.seek(toSec: target, exact: exact)
    }
}
#endif
