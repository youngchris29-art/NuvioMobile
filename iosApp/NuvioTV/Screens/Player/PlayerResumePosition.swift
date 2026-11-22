import Foundation

// Where a start or a return restart must land (W5 r2, shared by both routes at W5 r4). The native
// coordinator and the Aether controller both own one `PlayerStartResume`; only this file decides it.

/// Where the start's resume stands. Owned by the native coordinator and the Aether controller, decided
/// only by `PlayerResumePosition`.
nonisolated enum PlayerStartResume: Sendable, Equatable {
    /// No item has been ready yet, or a restart from scratch is choosing again.
    case unresolved
    /// The start resume seek (or the pending-percent seek) to this target has not landed yet.
    case seeking(Double)
    /// A percentage-only resume row and no finite duration yet: applied on the first tick that has one.
    case awaitingDuration(percent: Double)
    /// Resolved: the start position is reached (or there was none).
    case done
}

/// The one decision about the position a start or a native restart must reach (W5 r2; Aether's start at W5 r4). The normal start
/// and the restart from scratch take the same `plan`; the first finite-duration tick takes
/// `percentStep`; the background snapshot takes `restart`, so a start whose resume has not landed is
/// still a start (it reruns `plan`), and a user seek still in flight is the target a mid-play restart
/// holds. Pure and exhaustively tested (`PlayerResumePositionTests`).
nonisolated enum PlayerResumePosition {
    enum Plan: Sendable, Equatable {
        case seek(Double)
        case atStart
        case awaitDuration(percent: Double)
    }

    /// The start resume. A failure-alert retry position over 10 s wins (Start Over included, mpv's
    /// `computeResumePosition` rule); then Start Over; then the saved row read with the item's duration
    /// when it is known (0 = unknown); a row that only has a percentage waits for a finite duration.
    static func plan(retryResumeSec: Double?, startFromBeginning: Bool, durationSec: Double,
                     savedResumeSec: (Double) -> Double?, pendingPercent: () -> Double?) -> Plan {
        if let retry = retryResumeSec, retry.isFinite, retry > 10 { return .seek(retry) }
        if startFromBeginning { return .atStart }
        let known = durationSec.isFinite && durationSec > 0
        if let saved = savedResumeSec(known ? durationSec : 0), saved.isFinite, saved > 0 { return .seek(saved) }
        if !known, let pct = pendingPercent(), pct.isFinite, pct > 0 { return .awaitDuration(percent: pct) }
        return .atStart
    }

    /// The state a plan leaves the start in before its seek is issued.
    static func state(after plan: Plan) -> PlayerStartResume {
        switch plan {
        case .seek(let sec): return .seeking(sec)
        case .atStart: return .done
        case .awaitDuration(let pct): return .awaitingDuration(percent: pct)
        }
    }

    enum PercentStep: Sendable, Equatable {
        /// No finite position or duration yet: keep waiting.
        case wait
        /// The viewer is past the start (a scrub, 30 s in) or the target is under 10 s: dropped.
        case drop
        case seek(Double)
    }

    static func percentStep(percent: Double, positionSec: Double, durationSec: Double) -> PercentStep {
        guard positionSec.isFinite, durationSec.isFinite, durationSec > 0 else { return .wait }
        guard positionSec < 30 else { return .drop }
        let target = durationSec * percent / 100
        return target.isFinite && target > 10 ? .seek(target) : .drop
    }

    enum Restart: Sendable, Equatable {
        /// The start has not reached its position: rerun the start path (`plan`) from scratch.
        /// `positionSec` is what a failed restart hands to mpv: the start target when one was in flight.
        case fromScratch(positionSec: Double)
        /// Restart at `positionSec`; `pendingSeekSec` is a user seek that has not landed (held instead).
        case midPlay(positionSec: Double, pendingSeekSec: Double?)
    }

    /// What a background snapshot records. `itemEverReady` false or a start that is not `.done` is a
    /// start; otherwise mid-play at the ready clock (else the last position), with the newest user
    /// seek still in flight (chapter, skip, replay, or one aimed at a B17 rebuild) as the target.
    static func restart(itemEverReady: Bool, startup: PlayerStartResume, clockSec: Double?,
                        lastPositionSec: Double, userSeekInFlightSec: Double?) -> Restart {
        let position = NativeReturnMath.snapshotPositionSec(playerTimeSec: clockSec, lastPositionSec: lastPositionSec)
        guard itemEverReady, startup == .done else {
            if case .seeking(let target) = startup, target.isFinite, target >= 0 {
                return .fromScratch(positionSec: target)
            }
            return .fromScratch(positionSec: position)
        }
        let pending = userSeekInFlightSec.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return .midPlay(positionSec: position, pendingSeekSec: pending)
    }
}

extension PlayerResumePosition {
    enum OwedStep: Sendable, Equatable {
        /// Nothing to do now (no percentage owed, no duration yet, or a return holds the transport).
        case keep
        /// The percentage resolved to nothing (past the start, or under 10 s).
        case done
        /// Issue the start's percentage seek to this target now.
        case seek(Double)
    }

    /// Aether's start (W5 r4): a percentage-only row waits for the first load's duration, and while a
    /// return holds the transport (away, deferred, restoring) the resume stays owned instead of being
    /// dropped by the transport gate. It is applied when the load returns with nothing holding it, or
    /// when the return releases the transport.
    static func owedStep(_ state: PlayerStartResume, mediaReady: Bool, transportHeld: Bool,
                         positionSec: Double, durationSec: Double) -> OwedStep {
        guard case .awaitingDuration(let pct) = state, mediaReady, !transportHeld else { return .keep }
        switch percentStep(percent: pct, positionSec: positionSec, durationSec: durationSec) {
        case .wait: return .keep
        case .drop: return .done
        case .seek(let target): return .seek(target)
        }
    }
}
