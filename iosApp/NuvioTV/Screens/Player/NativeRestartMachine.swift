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
    case seekLanded(clockSec: Double?, pictureReady: Bool)
    /// Mid-play: the snapshot's audio and subtitle are selected on the new item (W5 r1: the restart
    /// settles only after it, so a late selection can never overwrite one the viewer makes after the settle).
    case tracksRestored
    /// From scratch: the coordinator read the resume row (identity checked first); nil or 0 = start at the top.
    case resumeChosen(sec: Double?)
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
    case seek(Double)
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

    nonisolated struct Landing: Sendable, Equatable {
        let clockSec: Double?
        let pictureReady: Bool
    }

    /// Any state but idle, settled, failed, cancelled: every failure source of the coordinator feeds the machine.
    var isActive: Bool {
        switch state {
        case .activating, .launching, .binding, .itemPending, .seeking, .resuming: return true
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
                state = .seeking
                tracksPending = true
                pendingLanding = nil
                return [.seek(target.positionSec), .restoreTracks(audio: target.audioName, subtitle: target.subtitleName)]
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
            guard state == .seeking || state == .resuming else { return [] }
            return fail(.failed("itemFailedAfterReady"))
        case .resumeChosen(let sec):
            guard state == .resuming else { return [] }
            if let sec, sec.isFinite, sec > 0 {
                state = .seeking
                return [.seek(sec)]
            }
            return settle(clockSec: nil, pictureReady: false)
        case .seekLanded(let clock, let picture):
            guard state == .seeking, pendingLanding == nil else { return [] }
            if tracksPending {
                pendingLanding = Landing(clockSec: clock, pictureReady: picture)
                return []
            }
            return settle(clockSec: clock, pictureReady: picture)
        case .tracksRestored:
            guard state == .seeking, tracksPending else { return [] }
            tracksPending = false
            guard let landing = pendingLanding else { return [] }
            pendingLanding = nil
            return settle(clockSec: landing.clockSec, pictureReady: landing.pictureReady)
        }
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

    /// Loopback health at return: a dead remux wins, then a listener that failed after ready or a ping that
    /// went unanswered, then a answered ping; no ping reading is `unknown`. Logged only (decision C).
    static func health(pingAnswered: Bool?, listenerFailedAfterReady: Bool, remuxFailed: Bool) -> PlayerNativeHealth {
        if remuxFailed { return .remuxDead }
        if listenerFailedAfterReady || pingAnswered == false { return .listenerDead }
        if pingAnswered == true { return .alive }
        return .unknown
    }
}
