import Foundation

// Aether Phase 1, W3-C: the once-only bookkeeping of the Aether to mpv handoff (W1-B 4.3 / 4.4), as a
// pure reducer the controller drives. It decides which effects run and in what order; the controller
// applies them (`PlaybackProgressRecorder`, `AetherPlaybackSession.stop`, `onFallback`).
//
// Rules (the native to mpv precedent, copied):
// - one resume flush per watch, at the handoff position, only when a frame was shown and the duration
//   is known (a pre-start failure and a live stream write nothing);
// - the Trakt stop and the tracker stop come after the flush and before the handoff reaches mpv, so
//   Aether's sessions are closed before mpv opens its own (never two open at once);
// - everything after the first handoff, or after tracking finished (teardown, `deinit`), emits nothing.

struct PlaybackHandoffLedger: Equatable {
    enum Effect: Equatable {
        case flushResume(positionSec: Double)
        case stopTrakt(positionSec: Double)
        case stopTrackers(positionSec: Double)
        case handOff(PlaybackHandoff)
    }

    private(set) var trackingFinished = false
    private(set) var handedOff = false

    /// Leaving the player (Menu exit, a context swap, the `deinit` backstop): one flush and the stops,
    /// once per player. A second call, or one after a handoff already closed tracking, emits nothing.
    mutating func finishTracking(positionSec: Double, durationSec: Double, everShowedFrame: Bool,
                                 isLive: Bool = false) -> [Effect] {
        guard !trackingFinished else { return [] }
        trackingFinished = true
        var effects: [Effect] = []
        if everShowedFrame, durationSec > 0, !isLive { effects.append(.flushResume(positionSec: positionSec)) }
        effects.append(.stopTrakt(positionSec: positionSec))
        effects.append(.stopTrackers(positionSec: positionSec))
        return effects
    }

    /// The fallback verdict: the tracking effects, then the handoff. Once only; a second verdict emits
    /// nothing.
    mutating func handOff(positionSec: Double, secondsPlayed: Double, durationSec: Double,
                          everShowedFrame: Bool, isLive: Bool = false) -> [Effect] {
        guard !handedOff else { return [] }
        handedOff = true
        let position = AetherFailurePlan.handoffPosition(positionSec)
        var effects = finishTracking(positionSec: position, durationSec: durationSec,
                                     everShowedFrame: everShowedFrame, isLive: isLive)
        effects.append(.handOff(PlaybackHandoff(positionSec: position, secondsPlayed: secondsPlayed,
                                                startedPlaying: everShowedFrame, kind: .local)))
        return effects
    }
}
