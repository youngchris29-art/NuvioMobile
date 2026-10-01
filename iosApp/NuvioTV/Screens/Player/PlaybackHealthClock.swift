import Foundation

/// How long a stream has really been playing, as opposed to how long ago it started. Both engines
/// feed it from the tick they already run (mpv's ~0.5 s state refresh, the native coordinator's
/// ~3 s observation loop) and read `seconds` for `PlaybackFailure.secondsPlayed` and the 300 s
/// "this link is healthy" mark (`PlaybackFailoverPolicy.healthySeconds`). A wall clock from
/// "file loaded" would let a paused or buffering stretch count toward that mark, and a link that
/// mostly sat in the spinner would clear its own rejection.
///
/// Pure value type, no timers, no AVPlayer, no mpv: every timestamp is passed in
/// (`ProcessInfo.systemUptime` in the app), so the tests drive time by hand.
///
/// Sampling rule: the span between two consecutive `note` calls counts only when the player was
/// playing at BOTH ends of it. That under-counts by at most one tick around a pause or a stall,
/// which is the safe direction for a number that clears a rejection.
struct PlaybackHealthClock: Equatable {
    /// The longest single span one `note` may add. A tick that arrives late (a stalled main
    /// thread, or an app that was suspended and resumed) must not credit minutes of playback that
    /// may never have happened; 5 s is generous for the 0.5 s and 3 s ticks that feed it.
    static let defaultMaxSpanSeconds: TimeInterval = 5

    /// Accumulated seconds of real playback.
    private(set) var seconds: TimeInterval = 0

    let maxSpanSeconds: TimeInterval
    private var lastNoteAt: TimeInterval?
    private var lastNotePlaying = false

    init(maxSpanSeconds: TimeInterval = PlaybackHealthClock.defaultMaxSpanSeconds) {
        self.maxSpanSeconds = maxSpanSeconds
    }

    /// Record one sample: whether the player is `playing` (not paused, not buffering, not seeking,
    /// not at the end) at `at`. The span since the previous sample is added when both samples were
    /// playing, capped at `maxSpanSeconds`; a clock that steps backwards adds nothing.
    mutating func note(playing: Bool, at: TimeInterval) {
        if let previous = lastNoteAt, lastNotePlaying, playing {
            let span = at - previous
            if span > 0 { seconds += min(span, maxSpanSeconds) }
        }
        lastNoteAt = at
        lastNotePlaying = playing
    }
}

/// The end-of-file rule of the libmpv player: when does an `eof-reached` mean "the stream died"
/// rather than "the movie finished". Pure, so `PlaybackHealthClockTests` pins it.
enum PlaybackEndPolicy {
    /// An end this far (or more) before the declared duration is a dead stream, not a finished one.
    static let earlyEndSlackSeconds: Double = 60

    /// True when the end of the file at `position` of `duration` is a playback failure for the
    /// failover to handle (and gets no post-play card). Declared durations are not always honest —
    /// a source that overstates its length by more than a minute would otherwise turn every
    /// finished episode into a failure — so a link the viewer picked themselves that has played
    /// for the healthy mark (`PlaybackFailoverPolicy.healthySeconds`) is a normal end. Automatic
    /// flows keep the early-end rule: they have nobody to ask, and the next candidate is cheap.
    static func isEarlyEndFailure(position: Double, duration: Double, secondsPlayed: Double,
                                  launchSource: PlaybackLaunchSource) -> Bool {
        guard duration.isFinite, duration > 0, position.isFinite else { return false }
        guard position < duration - earlyEndSlackSeconds else { return false }
        if launchSource == .manual, PlaybackFailoverPolicy.shouldKeep(secondsPlayed: secondsPlayed) {
            return false
        }
        return true
    }
}
