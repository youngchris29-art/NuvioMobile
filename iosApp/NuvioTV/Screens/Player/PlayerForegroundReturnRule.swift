import Foundation

// Return from background, wave 1: the pure decision types (spec sections 4, 7).
// No UIKit, no AVFoundation, no engine. Nothing here is wired into a controller yet.

// MARK: - Inputs (4.1)

nonisolated enum PlayerReturnRoute: Sendable, Equatable { case native, aetherLoopback, aetherSoftware }

/// The transport state at didEnterBackground, as the controller saw it.
nonisolated enum PlayerReturnPhase: Sendable, Equatable {
    case starting     // Aether: the first load has not shown a frame; native: no item was ever ready
    case operation    // a fresh load (Replay, DV rebuild), a reload or a seek in flight after a frame was shown
    case playing
    case paused
    case ended
    case postPlay
    case failed
    case handedOff
}

nonisolated enum PlayerPresence: Sendable, Equatable {
    case front
    case covered
    case leaving
}

/// Native loopback health at return. Logged and tabled; it never changes the action (decision C).
nonisolated enum PlayerNativeHealth: Sendable, Equatable { case notApplicable, unknown, alive, listenerDead, remuxDead }

/// Who the playback belongs to. Taken once when playback starts; compared on every event (section 7).
/// The live `current()` reader is wired in W2 (it needs the auth and profile singletons).
nonisolated struct PlaybackIdentity: Sendable, Equatable {
    let accountKey: String
    let profileId: Int32
}

nonisolated struct PlayerBackgroundSnapshot: Sendable, Equatable {
    let route: PlayerReturnRoute
    let phase: PlayerReturnPhase
    let positionSec: Double
    let pendingSeekTargetSec: Double?
    let enteredAtUptime: TimeInterval
    let audioTrackID: Int?
    let subtitleTrackID: Int?
    let subtitleDecided: Bool
    let audioName: String?
    let subtitleName: String?
}

nonisolated struct PlayerReturnFacts: Sendable, Equatable {
    let identity: PlaybackIdentity
    let enteredBackground: Bool
    let awaySec: Double
    let presence: PlayerPresence
    let contextSwapPending: Bool
    let operationInFlight: Bool
    let aetherNeedsRestore: Bool?
    let aetherSessionFailed: Bool
    let clockSec: Double?
    let nativeHealth: PlayerNativeHealth

    func withEnteredBackground(_ value: Bool) -> PlayerReturnFacts {
        PlayerReturnFacts(identity: identity, enteredBackground: value, awaySec: awaySec, presence: presence,
                          contextSwapPending: contextSwapPending, operationInFlight: operationInFlight,
                          aetherNeedsRestore: aetherNeedsRestore, aetherSessionFailed: aetherSessionFailed,
                          clockSec: clockSec, nativeHealth: nativeHealth)
    }
}

// MARK: - Outputs (4.2)

nonisolated enum PlayerReturnAction: Sendable, Equatable {
    case nothing(PlayerReturnNoActionReason)
    case abandon
    case deferUntil(PlayerReturnSettlePoint)
    case pauseInPlace
    case aetherReload
    case aetherFreshLoad(atSec: Double)
    case nativeRestart(atSec: Double)
    case nativeRestartFromScratch
    case handOffToMpv(atSec: Double)
}
nonisolated enum PlayerReturnNoActionReason: Sendable, Equatable { case notBackgrounded, leaving, terminal, contextSwap }
nonisolated enum PlayerReturnSettlePoint: Sendable, Equatable { case operationSettles, playerFront }

nonisolated enum PlayerReturnUI: Sendable, Equatable {
    case normal
    case restoring
    case handingOff
}

nonisolated enum PlayerRestoreKind: Sendable, Equatable {
    case aetherReload, aetherFreshLoad(atSec: Double), nativeRestart(atSec: Double), nativeRestartFromScratch
}

nonisolated enum PlayerRestoreOutcome: Sendable, Equatable {
    case settled(clockSec: Double?, picture: Bool)
    case refused
    case notNeeded
    case failed(String)
    case timedOut
}

nonisolated enum PlayerRestoreGate: Sendable, Equatable { case proceed, notNeeded, dropped, preconditionTimedOut }

nonisolated enum PlayerReturnEffect: Sendable, Equatable {
    case startRestore(PlayerRestoreKind, token: Int)
    case cancelRestore(token: Int)
    case pauseTransport
    case play
    case handOff(atSec: Double)
    case exitPlayer
    case stopStartWatchdog
    case rearmStartWatchdog
    case pauseRestoreWatchdog
    case resumeRestoreWatchdog
    case setUI(PlayerReturnUI)
    case holdPosition(Double)
    case releasePosition
    case refuseTransport(Bool)
    case schedulePictureNudge(token: Int, afterSec: Double)
    case nudgePicture(atSec: Double)
    /// The backstop decided to rebuild: take a fresh snapshot now and feed it back as `backstopRebuild`.
    case captureBackstopSnapshot
    case log(String)
}

// MARK: - Events (4.5)

nonisolated enum PlayerReturnEvent: Sendable, Equatable {
    case enteredBackground(PlayerBackgroundSnapshot)
    case becameActive(PlayerReturnFacts)
    case settled(PlayerReturnFacts)
    case reappeared(PlayerReturnFacts)
    case restoreOwedInForeground(PlayerBackgroundSnapshot, PlayerReturnFacts, pressedPlay: Bool)
    case sequenceArmed(token: Int)
    case sequenceDropped(token: Int, PlayerRestoreGate)
    case restoreFinished(token: Int, PlayerRestoreOutcome, PlayerReturnFacts)
    case restoreTimedOut(token: Int, PlayerReturnFacts)
    case pictureNudgeDue(token: Int)
    case frameShown(token: Int)
    case userPlay(PlayerReturnFacts)
    case userPause
    case backstopTick(PlayerBackstopSample, PlayerReturnFacts)
    /// The answer to `captureBackstopSnapshot`: the selections as they are now (W5 r3), so a backstop
    /// rebuild restores what the viewer chose after the return, not the background snapshot's tracks.
    case backstopRebuild(PlayerBackgroundSnapshot, PlayerReturnFacts)
    case cancelled

    /// The token a tokened event was started with (nil for the others).
    var token: Int? {
        switch self {
        case .sequenceArmed(let t), .sequenceDropped(let t, _), .restoreFinished(let t, _, _),
             .restoreTimedOut(let t, _), .pictureNudgeDue(let t), .frameShown(let t):
            return t
        default:
            return nil
        }
    }

    /// The facts a fact-carrying event brings (nil for the others).
    var facts: PlayerReturnFacts? {
        switch self {
        case .becameActive(let f), .settled(let f), .reappeared(let f), .userPlay(let f),
             .restoreOwedInForeground(_, let f, _), .restoreFinished(_, _, let f),
             .restoreTimedOut(_, let f), .backstopTick(_, let f), .backstopRebuild(_, let f):
            return f
        default:
            return nil
        }
    }

    var logName: String {
        switch self {
        case .enteredBackground: return "enteredBackground"
        case .becameActive: return "becameActive"
        case .settled: return "settled"
        case .reappeared: return "reappeared"
        case .restoreOwedInForeground: return "restoreOwedInForeground"
        case .sequenceArmed: return "sequenceArmed"
        case .sequenceDropped: return "sequenceDropped"
        case .restoreFinished: return "restoreFinished"
        case .restoreTimedOut: return "restoreTimedOut"
        case .pictureNudgeDue: return "pictureNudgeDue"
        case .frameShown: return "frameShown"
        case .userPlay: return "userPlay"
        case .userPause: return "userPause"
        case .backstopTick: return "backstopTick"
        case .backstopRebuild: return "backstopRebuild"
        case .cancelled: return "cancelled"
        }
    }
}

// MARK: - Position (4.7)

/// One authoritative position, owned by the rule, read by every consumer while a return is in progress.
nonisolated struct PlayerReturnPosition: Sendable, Equatable {
    enum SettlePoint: Sendable, Equatable {
        /// A deferred operation's `settled` (a seek can land or be clamped at 0).
        case operation
        /// A restore's settle, a pause in place, a reappearance (a 0 is a reading taken before the clock reported).
        case restore
    }

    private(set) var value: Double = 0
    private(set) var isHeld = false

    /// `value = pendingSeekTarget ?? position` (a seek the user issued before Home is the user's intent).
    mutating func hold(_ snapshot: PlayerBackgroundSnapshot) {
        if let target = snapshot.pendingSeekTargetSec, target.isFinite, target >= 0 {
            value = target
        } else if snapshot.positionSec.isFinite, snapshot.positionSec >= 0 {
            value = snapshot.positionSec
        } else {
            value = 0
        }
        isHeld = true
    }

    /// Takes the engine's landed clock at a settle point. Returns whether it was accepted.
    @discardableResult
    mutating func adopt(_ clockSec: Double?, at point: SettlePoint) -> Bool {
        guard let clock = clockSec, clock.isFinite, clock >= 0 else { return false }
        switch point {
        case .operation:
            value = clock
            return true
        case .restore:
            if clock > 0 {
                value = clock
                return true
            }
            if value < 2 {
                value = 0
                return true
            }
            return false
        }
    }

    /// Consumers go back to the live clock; the value stays readable.
    mutating func release() { isHeld = false }
}

// MARK: - Write guard (section 7)

nonisolated enum PlaybackWriteGuard {
    /// A nil owner (mpv-compatible default) always allows; otherwise the identity must be unchanged.
    static func allows(owner: PlaybackIdentity?, current: PlaybackIdentity) -> Bool {
        guard let owner else { return true }
        return owner == current
    }
}

// MARK: - Restore progress (W5 r5)

/// When a restore op counts as settled, and when its watchdog may stand down. Pure; the runners only
/// feed it. A transport phase or a frame latch left over from before the op never counts: the op must
/// have returned (nothing outstanding for this token) and the frame must have risen since it started.
nonisolated enum PlayerRestoreProgress {
    static func transportSettled(opOutstanding: Bool, phaseSettled: Bool) -> Bool {
        !opOutstanding && phaseSettled
    }

    static func watchdogStandsDown(opOutstanding: Bool, phaseSettled: Bool, frameSinceOp: Bool) -> Bool {
        transportSettled(opOutstanding: opOutstanding, phaseSettled: phaseSettled) && frameSinceOp
    }
}

// MARK: - Restore sequence (4.8)

nonisolated enum PlayerRestoreSequence {
    /// The bound on the precondition wait, in active time.
    static let preconditionLimitSec: Double = 5

    /// The only order a restore runs in, for every kind:
    /// 1. await preconditions, cancellable and bounded by `preconditionLimitSec`;
    /// 2. `stillCurrent()`;
    /// 3. `armWatchdog()`;
    /// 4. `report(.sequenceArmed)` then `invoke()`.
    /// It always ends in exactly one tokened report: `sequenceArmed` right after step 3, or
    /// `sequenceDropped` from step 1 or 2.
    @MainActor
    static func run(token: Int,
                    preconditionLimitSec: Double = PlayerRestoreSequence.preconditionLimitSec,
                    sleep: @escaping (Double) async throws -> Void = { seconds in
                        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    },
                    preconditions: @escaping () async -> Void,
                    stillCurrent: () -> PlayerRestoreGate,
                    armWatchdog: () -> Void,
                    report: (PlayerReturnEvent) -> Void,
                    invoke: () -> Void) async {
        let gate = PreconditionGate()
        let work = Task { @MainActor in
            await preconditions()
            gate.resolve(.done)
        }
        let timer = Task { @MainActor in
            do {
                try await sleep(preconditionLimitSec)
                gate.resolve(.timedOut)
            } catch {
                // Cancelled with the sequence: time away never counts.
            }
        }
        let outcome: PreconditionGate.Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PreconditionGate.Outcome, Never>) in
                gate.install(continuation)
            }
        } onCancel: {
            Task { @MainActor in gate.resolve(.cancelled) }
        }
        timer.cancel()
        work.cancel()

        switch outcome {
        case .cancelled:
            report(.sequenceDropped(token: token, .dropped))
        case .timedOut:
            report(.sequenceDropped(token: token, .preconditionTimedOut))
        case .done:
            if Task.isCancelled {
                report(.sequenceDropped(token: token, .dropped))
                return
            }
            switch stillCurrent() {
            case .proceed:
                armWatchdog()
                report(.sequenceArmed(token: token))
                invoke()
            case .notNeeded:
                report(.sequenceDropped(token: token, .notNeeded))
            case .dropped, .preconditionTimedOut:
                report(.sequenceDropped(token: token, .dropped))
            }
        }
    }

    /// Resolves once, from whichever of the precondition work, the bound or the cancellation comes first.
    @MainActor
    private final class PreconditionGate {
        enum Outcome: Sendable { case done, timedOut, cancelled }
        private var resolved: Outcome?
        private var continuation: CheckedContinuation<Outcome, Never>?

        func install(_ c: CheckedContinuation<Outcome, Never>) {
            if let resolved {
                c.resume(returning: resolved)
            } else {
                continuation = c
            }
        }

        func resolve(_ outcome: Outcome) {
            guard resolved == nil else { return }
            resolved = outcome
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }
}

// MARK: - The rule (4.3 to 4.5)

nonisolated struct PlayerForegroundReturnRule: Sendable {
    enum Mode: Sendable, Equatable {
        case idle
        case away
        case deferred(PlayerReturnSettlePoint)
        case preparing
        case restoring
        case awayRestoring
        case abandoned
        case finished
    }
    enum Intent: Sendable, Equatable { case play, pause }

    /// How long after a transport settle without a frame the one exact-seek nudge waits.
    static let pictureNudgeDelaySec: Double = 3

    let owner: PlaybackIdentity
    private(set) var mode: Mode = .idle
    private(set) var snapshot: PlayerBackgroundSnapshot?
    private(set) var intent: Intent = .pause
    private(set) var failedAttempts = 0
    private(set) var token = 0
    private(set) var position = PlayerReturnPosition()
    private(set) var backstop = PlayerFrozenClockBackstop()
    private(set) var backstopOwed = false
    private(set) var pictureOwed = false
    private(set) var nudgeIssued = false
    /// A restore settled its transport and the rule waits for the frame (4.9 rows 2 to 4).
    private(set) var framePending = false
    /// The first Play after a return armed the backstop; it takes `now` from the first tick that follows.
    private(set) var backstopArmPending = false
    /// The backstop's verdict was a rebuild and its fresh snapshot is owed (`backstopRebuild`).
    private(set) var backstopRebuildDue = false
    private var backstopArmClock: Double?
    private var currentKind: PlayerRestoreKind?

    var blocksTransport: Bool {
        switch mode {
        case .preparing, .restoring, .deferred: return true
        default: return false
        }
    }
    var allowsPlay: Bool { mode == .idle }

    /// The modes in which a Play/Pause press only records the intent (the transport is held, I1, I5).
    var holdsIntent: Bool {
        switch mode {
        case .away, .deferred, .preparing, .restoring, .awayRestoring: return true
        case .idle, .abandoned, .finished: return false
        }
    }

    /// What a Play/Pause press asks for (W5 r1). While the return holds the intent, a press toggles the
    /// queued intent: the held transport stays paused, so its state says nothing about the last press,
    /// and two presses must cancel out (last press wins, I5). Otherwise the live transport decides.
    func pressAsksForPlay(transportPaused: Bool) -> Bool {
        holdsIntent ? intent == .pause : transportPaused
    }

    /// Who owns an Aether session failure now (W2 ruling 10, W5 r1).
    enum FailureOwner: Sendable, Equatable {
        /// The controller's failover ladder (normal playback, terminal modes, a plain absence).
        case ladder
        /// Preparing: the engine was not called yet and the restore starts a new generation; logged only.
        case absorbed
        /// A restore op was invoked: `restoreFinished(.failed)`. Active: one attempt, then mpv. Away
        /// (`awayRestoring`): not an attempt, no handoff while backgrounded; the next return decides.
        case restore
        /// The operation the return waits on failed: its `settled` with a failed session (row 8).
        case operation
    }

    var aetherFailureOwner: FailureOwner {
        switch mode {
        case .preparing: return .absorbed
        case .restoring, .awayRestoring: return .restore
        case .deferred(.operationSettles): return .operation
        case .idle, .away, .deferred(.playerFront), .abandoned, .finished: return .ladder
        }
    }

    init(owner: PlaybackIdentity) {
        self.owner = owner
    }

    // MARK: decide (4.3)

    /// The pure table of 4.3. Total; first match wins. `positionSec` is the authoritative position (4.7).
    static func decide(owner: PlaybackIdentity,
                       snapshot: PlayerBackgroundSnapshot,
                       facts: PlayerReturnFacts,
                       failedAttempts: Int,
                       positionSec: Double) -> PlayerReturnAction {
        if !facts.enteredBackground { return .nothing(.notBackgrounded) }                       // 1
        if facts.identity != owner { return .abandon }                                          // 2
        if facts.presence == .leaving { return .nothing(.leaving) }                             // 3
        switch snapshot.phase {                                                                 // 4
        case .ended, .postPlay, .failed, .handedOff: return .nothing(.terminal)
        case .starting, .operation, .playing, .paused: break
        }
        if facts.contextSwapPending { return .nothing(.contextSwap) }                           // 5
        if facts.presence == .covered { return .deferUntil(.playerFront) }                      // 6
        if failedAttempts >= 1 { return .handOffToMpv(atSec: positionSec) }                     // 7
        switch snapshot.route {
        case .aetherLoopback, .aetherSoftware:
            if facts.aetherSessionFailed { return .aetherFreshLoad(atSec: positionSec) }        // 8
            if facts.operationInFlight { return .deferUntil(.operationSettles) }                // 9
            if facts.aetherNeedsRestore == true { return .aetherReload }                        // 10
            return .pauseInPlace                                                                // 11
        case .native:
            switch snapshot.phase {
            case .starting: return .nativeRestartFromScratch                                    // 12
            case .operation, .playing, .paused: return .nativeRestart(atSec: positionSec)       // 13
            case .ended, .postPlay, .failed, .handedOff: return .nothing(.terminal)
            }
        }
    }

    // MARK: handle (4.5)

    /// Feeds one event; returns the effects to run, in order. The last effect is always one `[Return]`
    /// log line, except for a quiet backstop tick that changed nothing.
    mutating func handle(_ event: PlayerReturnEvent) -> [PlayerReturnEffect] {
        let before = mode
        guard var effects = step(event) else {
            return [.log("[Return] \(event.logName) ignored in \(before)")]
        }
        if case .backstopTick = event, effects.isEmpty, mode == before { return effects }
        effects.append(.log("[Return] \(event.logName) \(before) -> \(mode)"))
        return effects
    }

    /// nil = ignored (unlisted pair, terminal mode, stale token).
    private mutating func step(_ event: PlayerReturnEvent) -> [PlayerReturnEffect]? {
        if mode == .abandoned || mode == .finished { return nil }
        if let t = event.token, t != token { return nil }
        if let f = event.facts, f.identity != owner { return abandonRow() }
        if case .cancelled = event { return cancelRow() }
        switch mode {
        case .idle: return idleStep(event)
        case .away: return awayStep(event)
        case .deferred(let point): return deferredStep(event, point: point)
        case .preparing: return preparingStep(event)
        case .restoring: return restoringStep(event)
        case .awayRestoring: return awayRestoringStep(event)
        case .abandoned, .finished: return nil
        }
    }

    // MARK: shared transitions

    private var restoreInFlightMode: Bool {
        mode == .preparing || mode == .restoring || mode == .awayRestoring
    }

    private mutating func abandonRow() -> [PlayerReturnEffect] {
        var fx: [PlayerReturnEffect] = []
        if restoreInFlightMode { fx.append(.cancelRestore(token: token)) }
        mode = .abandoned
        position.release()
        fx += [.releasePosition, .refuseTransport(false), .setUI(.normal), .exitPlayer]
        return fx
    }

    private mutating func cancelRow() -> [PlayerReturnEffect] {
        var fx: [PlayerReturnEffect] = []
        if restoreInFlightMode { fx.append(.cancelRestore(token: token)) }
        mode = .finished
        position.release()
        fx += [.releasePosition, .refuseTransport(false)]
        return fx
    }

    private mutating func beginRestore(_ kind: PlayerRestoreKind) -> [PlayerReturnEffect] {
        token += 1
        mode = .preparing
        currentKind = kind
        framePending = false
        return [.startRestore(kind, token: token), .refuseTransport(true), .setUI(.restoring)]
    }

    private mutating func failToMpv() -> [PlayerReturnEffect] {
        failedAttempts += 1
        return handOffRow(atSec: position.value)
    }

    private mutating func handOffRow(atSec: Double) -> [PlayerReturnEffect] {
        mode = .finished
        position.release()
        return [.handOff(atSec: atSec), .setUI(.handingOff), .releasePosition]
    }

    private mutating func armBackstopAtNextTick(clock: Double?) {
        backstopArmPending = true
        backstopArmClock = clock
    }

    /// The 4.9 rule: a return that still owes its picture goes back to `restoring` with a fresh budget.
    private mutating func resumeForPicture() -> [PlayerReturnEffect] {
        token += 1
        mode = .restoring
        framePending = true
        var fx: [PlayerReturnEffect] = [.resumeRestoreWatchdog]
        if !nudgeIssued { fx.append(.schedulePictureNudge(token: token, afterSec: Self.pictureNudgeDelaySec)) }
        return fx
    }

    /// Adopts a landed clock (4.7). While the position is held, a changed value is emitted again, so the
    /// runner's held value, the bar and the mirror the release writes follow it (W5 r1: a seek that
    /// landed short of its target must never be flushed or handed off at the target).
    private mutating func adoptPosition(_ clock: Double?, at point: PlayerReturnPosition.SettlePoint) -> [PlayerReturnEffect] {
        let before = position.value
        guard position.adopt(clock, at: point), position.isHeld, position.value != before else { return [] }
        return [.holdPosition(position.value)]
    }

    private mutating func pauseInPlaceRow(clock: Double?) -> [PlayerReturnEffect] {
        let adopted = adoptPosition(clock, at: .restore)
        if pictureOwed { return adopted + resumeForPicture() }
        mode = .idle
        var fx: [PlayerReturnEffect] = adopted
        // W2 ruling 9: a return that pauses in place before the first frame (or during an operation
        // after one) still owes the start budget it stopped at background, from now (I3: never a
        // spinner without a watchdog).
        if let phase = snapshot?.phase, phase == .starting || phase == .operation {
            fx.append(.rearmStartWatchdog)
        }
        if intent == .play {
            fx.append(.play)
            armBackstopAtNextTick(clock: clock)
        } else {
            fx.append(.pauseTransport)
            backstopOwed = true
        }
        position.release()
        fx += [.releasePosition, .refuseTransport(false), .setUI(.normal)]
        return fx
    }

    /// How a restore's settle clock is adopted. The native restart machine settles only with the player
    /// confirmed at its final position (W5 r3), so its clock is a landing (0 included: a start at the top);
    /// an Aether reload's clock can be a transient 0 read before the rebuilt clock reported.
    private var restoreLandingPoint: PlayerReturnPosition.SettlePoint {
        snapshot?.route == .native ? .operation : .restore
    }

    private mutating func settleSuccess(clock: Double?) -> [PlayerReturnEffect] {
        let adopted = adoptPosition(clock, at: restoreLandingPoint)
        mode = .idle
        pictureOwed = false
        framePending = false
        failedAttempts = 0
        position.release()
        var fx: [PlayerReturnEffect] = adopted + [.releasePosition, .refuseTransport(false), .setUI(.normal)]
        if intent == .play {
            fx.append(.play)
            armBackstopAtNextTick(clock: clock)
        } else {
            fx.append(.pauseTransport)
            backstopOwed = true
        }
        return fx
    }

    private mutating func applyDecide(_ action: PlayerReturnAction, facts: PlayerReturnFacts) -> [PlayerReturnEffect] {
        switch action {
        case .nothing:
            mode = .idle
            position.release()
            return [.releasePosition, .refuseTransport(false), .setUI(.normal)]
        case .deferUntil(let point):
            mode = .deferred(point)
            var fx: [PlayerReturnEffect] = [.refuseTransport(true), .setUI(.restoring)]
            if let phase = snapshot?.phase, phase == .starting || phase == .operation {
                fx.append(.rearmStartWatchdog)
            }
            return fx
        case .pauseInPlace:
            return pauseInPlaceRow(clock: facts.clockSec)
        case .aetherReload:
            return beginRestore(.aetherReload)
        case .aetherFreshLoad(let at):
            return beginRestore(.aetherFreshLoad(atSec: at))
        case .nativeRestart(let at):
            return beginRestore(.nativeRestart(atSec: at))
        case .nativeRestartFromScratch:
            return beginRestore(.nativeRestartFromScratch)
        case .handOffToMpv(let at):
            return handOffRow(atSec: at)
        case .abandon:
            return abandonRow()
        }
    }

    private func decideNow(facts: PlayerReturnFacts) -> PlayerReturnAction {
        guard let snapshot else { return .nothing(.notBackgrounded) }
        return Self.decide(owner: owner, snapshot: snapshot, facts: facts,
                           failedAttempts: failedAttempts, positionSec: position.value)
    }

    private mutating func startNewReturn() {
        backstop = PlayerFrozenClockBackstop()
        backstopOwed = false
        backstopArmPending = false
        backstopArmClock = nil
        backstopRebuildDue = false
        pictureOwed = false
        framePending = false
        nudgeIssued = false
    }

    // MARK: idle

    private mutating func idleStep(_ event: PlayerReturnEvent) -> [PlayerReturnEffect]? {
        switch event {
        case .enteredBackground(let s):
            snapshot = s
            position.hold(s)
            startNewReturn()
            intent = .pause
            mode = .away
            return [.holdPosition(position.value), .stopStartWatchdog]

        case .restoreOwedInForeground(let s, let f, let pressed):
            snapshot = s
            position.hold(s)
            startNewReturn()
            intent = pressed ? .play : .pause
            var fx: [PlayerReturnEffect] = [.holdPosition(position.value)]
            switch s.phase {
            case .ended, .postPlay, .failed, .handedOff:
                mode = .idle
                position.release()
                return fx + [.releasePosition]
            case .starting, .operation, .playing, .paused:
                break
            }
            if f.presence == .leaving || f.contextSwapPending {
                mode = .idle
                position.release()
                return fx + [.releasePosition]
            }
            if f.presence == .covered {
                return fx + applyDecide(.deferUntil(.playerFront), facts: f)
            }
            if failedAttempts >= 1 {
                return fx + handOffRow(atSec: position.value)
            }
            if f.operationInFlight {
                return fx + applyDecide(.deferUntil(.operationSettles), facts: f)
            }
            fx += beginRestore(.aetherReload)
            return fx

        case .userPlay(let f):
            if backstopOwed {
                armBackstopAtNextTick(clock: f.clockSec)
                backstopOwed = false
            }
            return [.play]

        case .userPause:
            backstop.disarm()
            backstopArmPending = false
            return [.pauseTransport]

        case .backstopTick(let sample, let f):
            if backstopArmPending {
                backstop.arm(now: sample.now, clockSec: backstopArmClock ?? sample.clockSec)
                backstopArmPending = false
                backstopArmClock = nil
            }
            switch backstop.note(sample) {
            case .wait, .disarm:
                return []
            case .rebuild:
                guard snapshot != nil else { return nil }
                backstopRebuildDue = true
                return [.captureBackstopSnapshot]
            case .handOff:
                return handOffRow(atSec: f.clockSec ?? position.value)
            }

        case .backstopRebuild(let base, let f):
            // W5 r3: tracks, names (and on Aether the delay and shaping the host read with it) are the
            // ones of this instant; the clock is the frozen one the backstop saw.
            guard backstopRebuildDue else { return nil }
            backstopRebuildDue = false
            let clock: Double
            if let c = f.clockSec, c.isFinite, c >= 0 { clock = c } else { clock = position.value }
            let s = PlayerBackgroundSnapshot(route: base.route, phase: .playing, positionSec: clock,
                                             pendingSeekTargetSec: nil, enteredAtUptime: base.enteredAtUptime,
                                             audioTrackID: base.audioTrackID, subtitleTrackID: base.subtitleTrackID,
                                             subtitleDecided: base.subtitleDecided, audioName: base.audioName,
                                             subtitleName: base.subtitleName)
            snapshot = s
            position.hold(s)
            nudgeIssued = false
            intent = .play
            let kind: PlayerRestoreKind
            switch base.route {
            case .native:
                kind = .nativeRestart(atSec: clock)
            case .aetherLoopback, .aetherSoftware:
                kind = f.aetherNeedsRestore == true ? .aetherReload : .aetherFreshLoad(atSec: clock)
            }
            return [.holdPosition(position.value)] + beginRestore(kind)

        default:
            return nil
        }
    }

    // MARK: away

    private mutating func awayStep(_ event: PlayerReturnEvent) -> [PlayerReturnEffect]? {
        switch event {
        case .becameActive(let f):
            return applyDecide(decideNow(facts: f), facts: f)
        case .userPlay:
            intent = .play
            return []
        case .userPause:
            intent = .pause
            return []
        default:
            return nil
        }
    }

    // MARK: deferred

    private mutating func deferredStep(_ event: PlayerReturnEvent, point: PlayerReturnSettlePoint) -> [PlayerReturnEffect]? {
        switch event {
        case .settled(let f) where point == .operationSettles:
            let adopted = adoptPosition(f.clockSec, at: .operation)
            let action = decideNow(facts: f.withEnteredBackground(true))
            if case .deferUntil(.operationSettles) = action {
                // Impossible by construction (operationInFlight is false at a settle): treated as pauseInPlace.
                return adopted + [.log("[Return] re-defer at settled treated as pauseInPlace")]
                    + applyDecide(.pauseInPlace, facts: f)
            }
            return adopted + applyDecide(action, facts: f)
        case .reappeared(let f) where point == .playerFront:
            // W1 ruling 5: the restore rule (a transient 0 is not a landing). An operation still in
            // flight keeps the held target; its own settle adopts the landing (operation rule).
            let adopted: [PlayerReturnEffect] = f.operationInFlight ? [] : adoptPosition(f.clockSec, at: .restore)
            return adopted + applyDecide(decideNow(facts: f.withEnteredBackground(true)), facts: f)
        case .userPlay:
            intent = .play
            return []
        case .userPause:
            intent = .pause
            return []
        case .enteredBackground:
            mode = .away
            return [.stopStartWatchdog]
        default:
            return nil
        }
    }

    // MARK: preparing

    private mutating func preparingStep(_ event: PlayerReturnEvent) -> [PlayerReturnEffect]? {
        switch event {
        case .sequenceArmed:
            mode = .restoring
            pictureOwed = true
            return []
        case .sequenceDropped(_, let gate):
            switch gate {
            case .notNeeded:
                return pauseInPlaceRow(clock: nil)
            case .dropped:
                // The sequence reports no facts, so "backgrounded or not" is not known here: the return stays
                // pending and the next becameActive decides.
                mode = .away
                return []
            case .preconditionTimedOut:
                return failToMpv()
            case .proceed:
                return nil
            }
        case .enteredBackground:
            let fx: [PlayerReturnEffect] = [.cancelRestore(token: token)]
            token += 1
            mode = .away
            return fx
        case .userPlay:
            intent = .play
            return []
        case .userPause:
            intent = .pause
            return []
        default:
            return nil
        }
    }

    // MARK: restoring

    private mutating func restoringStep(_ event: PlayerReturnEvent) -> [PlayerReturnEffect]? {
        switch event {
        case .userPlay:
            intent = .play
            return []
        case .userPause:
            intent = .pause
            return []
        case .enteredBackground:
            if snapshot?.route == .native {
                let fx: [PlayerReturnEffect] = [.cancelRestore(token: token)]
                token += 1
                mode = .away
                return fx
            }
            mode = .awayRestoring
            return [.pauseRestoreWatchdog]
        case .restoreFinished(_, let outcome, let f):
            switch outcome {
            case .settled(let clock, let picture):
                if picture { return settleSuccess(clock: clock) }
                let adopted = adoptPosition(clock, at: restoreLandingPoint)
                framePending = true
                return adopted + [.schedulePictureNudge(token: token, afterSec: Self.pictureNudgeDelaySec)]
            case .notNeeded:
                return settleSuccess(clock: f.clockSec)
            case .refused:
                if currentKind == .aetherReload {
                    return beginRestore(.aetherFreshLoad(atSec: position.value))
                }
                return failToMpv()
            case .failed, .timedOut:
                return failToMpv()
            }
        case .restoreTimedOut:
            return failToMpv()
        case .pictureNudgeDue:
            guard !nudgeIssued else { return nil }
            nudgeIssued = true
            return [.nudgePicture(atSec: position.value)]
        case .frameShown:
            guard framePending else { return nil }
            return settleSuccess(clock: nil)
        default:
            return nil
        }
    }

    // MARK: awayRestoring

    private mutating func awayRestoringStep(_ event: PlayerReturnEvent) -> [PlayerReturnEffect]? {
        switch event {
        case .restoreFinished(_, let outcome, _):
            var adopted: [PlayerReturnEffect] = []
            if case .settled(let clock, let picture) = outcome {
                adopted = adoptPosition(clock, at: restoreLandingPoint)
                pictureOwed = !picture
            }
            framePending = false
            mode = .away
            return adopted
        case .restoreTimedOut:
            framePending = false
            mode = .away
            return []
        case .becameActive:
            mode = .restoring
            var fx: [PlayerReturnEffect] = [.resumeRestoreWatchdog]
            if framePending && !nudgeIssued {
                fx.append(.schedulePictureNudge(token: token, afterSec: Self.pictureNudgeDelaySec))
            }
            return fx
        case .userPlay:
            intent = .play
            return []
        case .userPause:
            intent = .pause
            return []
        default:
            return nil
        }
    }
}
