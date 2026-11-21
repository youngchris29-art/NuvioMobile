import Foundation

/// One housekeeping sample fed to the frozen-clock backstop (Aether 0.5 s tick, native 3 s observe tick).
nonisolated struct PlayerBackstopSample: Sendable, Equatable {
    let now: TimeInterval
    let clockSec: Double?
    let userPaused: Bool
    let reportsPlaying: Bool
    let reportsBuffering: Bool
}

nonisolated enum PlayerBackstopVerdict: Sendable, Equatable { case wait, disarm, rebuild, handOff }

/// Return from background, decision G (best-effort): after the first Play that follows a return, if the
/// clock does not move, one more restore, then mpv. Pure value type; every timestamp is passed in.
/// Owned by `PlayerForegroundReturnRule` (only the rule arms it and reads its verdict).
nonisolated struct PlayerFrozenClockBackstop: Sendable, Equatable {
    /// Reports playing, clock still.
    static let playingLimitSec: Double = 8
    /// Reports buffering, clock still.
    static let bufferingLimitSec: Double = 20
    /// The clock counts as moving once it is this far from where it was armed.
    static let movedThresholdSec: Double = 0.5

    private(set) var armedAt: TimeInterval?
    private(set) var armedClock: Double?
    private(set) var rebuilds = 0

    var isArmed: Bool { armedAt != nil }

    /// Arms (or re-arms, keeping the rebuild count) the backstop at `now` with the clock as it stands.
    mutating func arm(now: TimeInterval, clockSec: Double?) {
        armedAt = now
        armedClock = Self.finite(clockSec)
    }

    mutating func disarm() {
        armedAt = nil
        armedClock = nil
    }

    mutating func note(_ s: PlayerBackstopSample) -> PlayerBackstopVerdict {
        guard let armedAt else { return .wait }
        if s.userPaused {
            disarm()
            return .disarm
        }
        // Non-finite clock samples are ignored.
        guard let clock = Self.finite(s.clockSec) else { return .wait }
        guard let baseline = armedClock else {
            // Armed without a clock: the first finite sample becomes the baseline.
            armedClock = clock
            return .wait
        }
        if abs(clock - baseline) >= Self.movedThresholdSec {
            disarm()
            return .disarm
        }
        let limit: Double
        if s.reportsBuffering {
            limit = Self.bufferingLimitSec
        } else if s.reportsPlaying {
            limit = Self.playingLimitSec
        } else {
            return .wait
        }
        guard s.now - armedAt >= limit else { return .wait }
        rebuilds += 1
        // Disarmed until the rebuild's settle re-arms it.
        disarm()
        return rebuilds == 1 ? .rebuild : .handOff
    }

    private static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }
}
