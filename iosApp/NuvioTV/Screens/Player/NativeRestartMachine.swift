import Foundation

// Return from background, wave 1: the native restart's own steps as a pure reducer (spec 5.2.2).
// The coordinator runs the effects and guards every await and callback with the machine token.

nonisolated enum NativeRestartKind: Sendable, Equatable {
    /// Something had played: restart at the authoritative position, paused, trackers untouched.
    case midPlay
    /// Nothing had played: the normal start path, paused, trackers started once at readiness.
    case fromScratch
}

nonisolated struct NativeRestartTarget: Sendable, Equatable {
    let positionSec: Double
    let audioName: String?
    let subtitleName: String?
}

nonisolated enum NativeRestartState: Sendable, Equatable {
    case idle
    case activating     // teardown issued, waiting for the audio-session activation
    case launching      // remux launched, waiting for the first segment
    case binding        // loopback server created, waiting for its bind
    case itemPending    // item and player created, waiting for ready
    case seeking        // mid-play: the corrective seek (or from scratch: the resume seek) is in flight
    case resuming       // from scratch: item ready, waiting for the resume position to be chosen
    /// From scratch: a percentage-only row and no finite duration yet. Unsettled until the percentage
    /// resolves (W5 r3: the restart settles only at its final position).
    case awaitingDuration
    case settled
    case failed
    case cancelled
}

nonisolated enum NativeRestartEvent: Sendable, Equatable {
    case begin(NativeRestartKind, NativeRestartTarget)
    case audioActivated
    case firstSegmentReady
    case bindSucceeded(url: String)
    case bindFailed
    case itemReady
    case itemFailedPreReady(signalingRetryAllowed: Bool)
    case itemFailedAfterReady
    case remuxFailed(stage: String)
    /// The seek of `generation` finished (`AVPlayer.seek` returned true). spec-mpv-return §6.2: the
    /// landing is checked against the target (`PlayerLandingCheck`) before it is stored; the durations
    /// are the item's at the issue and after the await. A stale generation is ignored.
    case seekLanded(clockSec: Double?, durationAtIssueSec: Double?, durationNowSec: Double?, pictureReady: Bool,
                    generation: Int)
    /// The seek of `generation` returned false (interrupted or failed): never a landing. Retried once,
    /// then the failure.
    case seekFailed(generation: Int)
    /// From scratch, awaiting a duration: the restart's item sampled (W5 r3).
    case durationKnown(positionSec: Double, durationSec: Double, pictureReady: Bool)
    /// Mid-play: the snapshot's audio and subtitle are selected on the new item (W5 r1: the restart
    /// settles only after it, so a late selection can never overwrite one the viewer makes after the settle).
    case tracksRestored
    /// From scratch: the coordinator ran the start plan (identity checked first).
    case resumeChosen(PlayerResumePosition.Plan)
    case identityChanged
    case deadline
    case stop
    case cancel
}

nonisolated enum NativeRestartEffect: Sendable, Equatable {
    case setPosition(Double)
    case teardownPipeline(keepPlayer: Bool)
    case activateAudio
    case launchRemux
    case makeServer
    case stopServer(stale: Bool)
    case makeItem(signalingAttempt: Int)
    /// spec-mpv-return §6.2: every restart seek is exact (both kinds and the percentage seek), and
    /// carries its generation back in `seekLanded` / `seekFailed`.
    case seek(Double, exact: Bool, generation: Int)
    case restoreTracks(audio: String?, subtitle: String?)
    case startTrackersOnce
    case report(PlayerRestoreOutcome)
    case reportAbandon
}

nonisolated struct NativeRestartMachine: Sendable, Equatable {
    private(set) var state: NativeRestartState = .idle
    private(set) var token = 0
    private(set) var kind: NativeRestartKind?
    private(set) var target: NativeRestartTarget?
    private(set) var signalingAttempt = 0
    private(set) var trackersStarted = false
    /// Mid-play: `restoreTracks` was issued and has not answered yet.
    private(set) var tracksPending = false
    /// The corrective seek landed while the tracks were still pending: the settle waits for them.
    private(set) var pendingLanding: Landing?
    /// The final position the restart seeks to (W5 r3): settled only once the player is confirmed there.
    private(set) var seekTarget: Double?
    /// The one retry of a seek that returned false has been used.
    private(set) var seekRetried = false
    /// From scratch, awaiting a duration: the row's percentage.
    private(set) var awaitPercent: Double?
    /// spec-mpv-return §6.2: the generation of the restart seek in flight (a landing of an older one is
    /// ignored), and whether the one corrective seek was used.
    private(set) var seekGeneration = 0
    private(set) var correctionUsed = false
    /// The verdict of the last current-generation landing (tests' oracle: settled ⇒ `.confirmed`).
    private(set) var lastVerdict: PlayerLandingCheck.Verdict?

    nonisolated struct Landing: Sendable, Equatable {
        let clockSec: Double?
        let pictureReady: Bool
    }

    /// Any state but idle, settled, failed, cancelled: every failure source of the coordinator feeds the machine.
    var isActive: Bool {
        switch state {
        case .activating, .launching, .binding, .itemPending, .seeking, .resuming, .awaitingDuration: return true
        case .idle, .settled, .failed, .cancelled: return false
        }
    }

    /// Feeds one event carrying the machine token. A stale token is ignored in every state; the one
    /// exception is a stale `bindSucceeded`, whose server must still be stopped.
    mutating func handle(_ event: NativeRestartEvent, token eventToken: Int) -> [NativeRestartEffect] {
        if case .begin(let kind, let target) = event {
            guard eventToken > token else { return [] }
            token = eventToken
            self.kind = kind
            self.target = target
            signalingAttempt = 0
            trackersStarted = false
            tracksPending = false
            pendingLanding = nil
            seekTarget = nil
            seekRetried = false
            awaitPercent = nil
            correctionUsed = false
            lastVerdict = nil
            state = .activating
            switch kind {
            case .midPlay:
                // The authoritative position is written before anything is torn down.
                return [.setPosition(target.positionSec), .teardownPipeline(keepPlayer: true), .activateAudio]
            case .fromScratch:
                return [.teardownPipeline(keepPlayer: false), .activateAudio]
            }
        }

        guard eventToken == token, isActive else {
            if case .bindSucceeded = event { return [.stopServer(stale: true)] }
            return []
        }

        switch event {
        case .begin:
            return []
        case .stop, .cancel:
            state = .cancelled
            return []
        case .identityChanged:
            state = .cancelled
            return [.reportAbandon]
        case .deadline:
            return fail(.timedOut)
        case .remuxFailed(let stage):
            return fail(.failed("remuxFailed:\(stage)"))
        case .audioActivated:
            guard state == .activating else { return [] }
            state = .launching
            return [.launchRemux]
        case .firstSegmentReady:
            guard state == .launching else { return [] }
            state = .binding
            return [.makeServer]
        case .bindSucceeded:
            guard state == .binding else { return [.stopServer(stale: true)] }
            state = .itemPending
            return [.makeItem(signalingAttempt: 0)]
        case .bindFailed:
            guard state == .binding else { return [] }
            return fail(.failed("bindFailed"))
        case .itemReady:
            guard state == .itemPending, let kind, let target else { return [] }
            switch kind {
            case .midPlay:
                tracksPending = true
                pendingLanding = nil
                return startSeek(target.positionSec) + [.restoreTracks(audio: target.audioName, subtitle: target.subtitleName)]
            case .fromScratch:
                state = .resuming
                return []
            }
        case .itemFailedPreReady(let retryAllowed):
            guard state == .itemPending else { return [] }
            if retryAllowed && signalingAttempt == 0 {
                signalingAttempt = 1
                return [.makeItem(signalingAttempt: 1)]
            }
            return fail(.failed("itemFailedPreReady"))
        case .itemFailedAfterReady:
            guard state == .seeking || state == .resuming || state == .awaitingDuration else { return [] }
            return fail(.failed("itemFailedAfterReady"))
        case .resumeChosen(let plan):
            guard state == .resuming else { return [] }
            switch plan {
            case .seek(let sec) where sec.isFinite && sec > 0:
                return startSeek(sec)
            case .awaitDuration(let pct):
                state = .awaitingDuration
                awaitPercent = pct
                return []
            case .seek, .atStart:
                // At the top: the item is ready there, confirmed by readiness itself.
                return settle(clockSec: 0, pictureReady: false)
            }
        case .durationKnown(let pos, let dur, let picture):
            guard state == .awaitingDuration, let pct = awaitPercent else { return [] }
            switch PlayerResumePosition.percentStep(percent: pct, positionSec: pos, durationSec: dur) {
            case .wait: return []
            case .drop: return settle(clockSec: pos, pictureReady: picture)
            case .seek(let t): return startSeek(t)
            }
        case .seekFailed(let generation):
            guard state == .seeking, pendingLanding == nil, generation == seekGeneration, let t = seekTarget else { return [] }
            guard !seekRetried else { return fail(.failed("seekFailed")) }
            seekRetried = true
            return [issueSeek(t)]
        case .seekLanded(let clock, let atIssue, let now, let picture, let generation):
            guard state == .seeking, pendingLanding == nil, generation == seekGeneration, let t = seekTarget else { return [] }
            // spec-mpv-return §6.2: checked before anything is stored.
            let verdict = PlayerLandingCheck.verdict(target: t, landed: clock, durationAtIssue: atIssue,
                                                     durationNow: now, correctionUsed: correctionUsed)
            lastVerdict = verdict
            switch verdict {
            case .confirmed:
                if tracksPending {
                    pendingLanding = Landing(clockSec: clock, pictureReady: picture)
                    return []
                }
                return settle(clockSec: clock, pictureReady: picture)
            case .correct:
                // One corrective exact seek to the same target; the tracks state is kept, nothing stored.
                correctionUsed = true
                return [issueSeek(t)]
            case .offTarget, .invalidTarget:
                return fail(.failed("offTarget"))
            }
        case .tracksRestored:
            guard state == .seeking, tracksPending else { return [] }
            tracksPending = false
            guard let landing = pendingLanding else { return [] }
            pendingLanding = nil
            return settle(clockSec: landing.clockSec, pictureReady: landing.pictureReady)
        }
    }

    private mutating func startSeek(_ sec: Double) -> [NativeRestartEffect] {
        // An unusable target is never sought (spec-mpv-return §6.2 step 1): the restart fails.
        guard sec.isFinite, sec >= 0 else {
            lastVerdict = .invalidTarget
            return fail(.failed("offTarget"))
        }
        state = .seeking
        seekTarget = sec
        return [issueSeek(sec)]
    }

    private mutating func issueSeek(_ sec: Double) -> NativeRestartEffect {
        seekGeneration += 1
        return .seek(sec, exact: true, generation: seekGeneration)
    }

    private mutating func fail(_ outcome: PlayerRestoreOutcome) -> [NativeRestartEffect] {
        state = .failed
        return [.report(outcome)]
    }

    private mutating func settle(clockSec: Double?, pictureReady: Bool) -> [NativeRestartEffect] {
        state = .settled
        var fx: [NativeRestartEffect] = []
        // Only a restart from scratch starts trackers, once, after the identity check at the seek.
        if kind == .fromScratch, !trackersStarted {
            trackersStarted = true
            fx.append(.startTrackersOnce)
        }
        fx.append(.report(.settled(clockSec: clockSec, picture: pictureReady)))
        return fx
    }
}

/// The two small pure readings the coordinator takes at didEnterBackground and didBecomeActive.
nonisolated enum NativeReturnMath {
    /// `player.currentTime()` when finite and not negative, else `lastPositionSec`, else 0.
    static func snapshotPositionSec(playerTimeSec: Double?, lastPositionSec: Double) -> Double {
        if let t = playerTimeSec, t.isFinite, t >= 0 { return t }
        if lastPositionSec.isFinite, lastPositionSec >= 0 { return lastPositionSec }
        return 0
    }

    /// The subtitle renditions a pipeline serves (W5 r5): a mid-play return restart keeps exactly what
    /// this playback served; any other start builds them fresh.
    static func servedSubtitles<T>(midPlayRestart: Bool, served: [T], fresh: [T]) -> [T] {
        midPlayRestart ? served : fresh
    }

    /// The subtitle a snapshot records (W5 r4): a late-subtitle pick wins only while its B17 rebuild is in
    /// flight (the pick is not on screen yet). Once the rebuild is done, abandoned or replaced by a return
    /// restart, the live selection wins, so a leftover pending pick can never override a later choice.
    static func snapshotSubtitleName(rebuilding: Bool, pendingLate: String?, current: String?) -> String? {
        if rebuilding, let pendingLate { return pendingLate }
        return current
    }

    /// Loopback health at return: a dead remux wins, then a listener that failed after ready or a ping that
    /// went unanswered, then a answered ping; no ping reading is `unknown`. Logged only (decision C).
    static func health(pingAnswered: Bool?, listenerFailedAfterReady: Bool, remuxFailed: Bool) -> PlayerNativeHealth {
        if remuxFailed { return .remuxDead }
        if listenerFailedAfterReady || pingAnswered == false { return .listenerDead }
        if pingAnswered == true { return .alive }
        return .unknown
    }
}
