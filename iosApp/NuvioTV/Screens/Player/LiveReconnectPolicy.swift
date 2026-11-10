import Foundation

/// GitHub #26 (erdist's patch, reviewed): what an `eof-reached` on a live stream means and how
/// often the player may answer it by reopening the stream.
///
/// A live stream has no end. When mpv raises `eof-reached` on one, FFmpeg's HLS demuxer gave up
/// (a playlist refresh that failed or came back without the next segment in time, a segment that
/// would not download) and mpv parks on the last frame. Treating that like the end of a film
/// raised the post-play card in the middle of a channel. The player reopens the same URL instead,
/// which lands at the live edge again.
///
/// Capped two ways, so a channel that has really gone off air still ends:
/// - at most `limit` reconnects inside `windowSec` (a channel that fails again at once);
/// - at most `unproductiveLimit` reconnects in a row that were each followed by less than
///   `productiveSec` of playback. With the HLS retry options the demuxer can take well over a
///   minute to give up (105 s on the 2 s-segment fixture), so a channel that is off air but still
///   serves its last playlist would never fill the time window: it replays the same few seconds
///   after every reopen. The streak catches that.
/// Pure and clock-injected; the view controller owns one value per player.
nonisolated struct LiveReconnectPolicy: Equatable, Sendable {
    /// Reconnects allowed inside `windowSec` before an end-of-file ends the stream.
    static let limit = 5
    static let windowSec: Double = 120
    /// Reconnects in a row with less than `productiveSec` of playback after each.
    static let unproductiveLimit = 3
    /// Playback after a reconnect that counts as the channel being back.
    static let productiveSec: Double = 30

    /// What the player knows when `eof-reached` rises.
    struct Inputs: Equatable, Sendable {
        /// `LivePlaybackPolicy.reportsLive`: mpv reads `seekable` false. Not proof of a live
        /// stream on its own: a film served without byte ranges reads the same.
        var reportsLive: Bool
        /// `DurationGrowth.grew`: the duration latched as growing with the clock.
        var growthLatched: Bool
        /// `DurationGrowth.undecided`: growth started and is not decided yet (a channel that
        /// drops in its first half minute has not latched live).
        var growthUndecided: Bool
        /// `DurationGrowth.resumeSettled`: the duration has been quiet for the undecided hold,
        /// which is what a film looks like and a live playlist does not.
        var growthSettled: Bool
        /// `LivePlaybackPolicy.needsSettleHold`: HLS or DASH, the only formats that can be live
        /// while still reading seekable with a finite duration.
        var adaptiveFormat: Bool
        /// The stream has a finite, positive duration. A raw live transport stream has none.
        var durationKnown: Bool
        /// The title is a film or an episode (`PlaybackContext.contentType` "movie" or "series"),
        /// not a channel.
        var filmOrEpisode: Bool = false
        /// The file reached FILE_LOADED at least once.
        var fileLoaded: Bool
        /// The player is closing, or the host is swapping it for another source.
        var closingOrSwapping: Bool
        /// Seconds this player has actually played so far (the failover play clock): what a
        /// reconnect is measured against to tell whether the one before it brought the channel back.
        var secondsPlayed: Double = 0
    }

    enum Decision: Equatable, Sendable {
        /// Reopen the stream; `attempt` counts from 1 inside the current window.
        case reconnect(attempt: Int)
        /// Live, but `limit` reconnects already ran inside the window, or `unproductiveLimit` in a
        /// row brought back less than `productiveSec` of playback each: let the stream end.
        case capReached(reconnects: Int)
        /// Not a live stream (or not ours to reopen): the end-of-file takes its normal path.
        case notEligible
    }

    /// Uptimes of the reconnects still inside the window, oldest first.
    private(set) var recent: [Double] = []
    /// Reconnects in a row that were each followed by less than `productiveSec` of playback.
    private(set) var unproductiveStreak = 0
    /// `Inputs.secondsPlayed` at the last reconnect; nil before the first.
    private(set) var playedAtLastReconnect: Double?

    /// Live for the purpose of a reconnect. Reopening a film would start it again from the
    /// beginning, so "live" here needs more than `seekable` false (a film served without byte
    /// ranges reads the same, and at its real end it must end):
    /// - HLS or DASH whose duration grows with the clock, has started to, or has not yet been
    ///   quiet long enough to read as a film while mpv reports it non-seekable;
    /// - any other container that mpv reports non-seekable, that has no duration at all (a raw
    ///   live transport stream) and that is not a film or an episode. A film can lack a duration
    ///   too (a media server's progressive `.ts` transcode: chunked, no length, no byte ranges),
    ///   and reopening it at its real end would play it again from the start (review r2 F1).
    /// A film or episode outside HLS and DASH is never reopened.
    static func isEligible(_ inputs: Inputs) -> Bool {
        guard inputs.fileLoaded, !inputs.closingOrSwapping else { return false }
        if inputs.adaptiveFormat {
            return inputs.growthLatched || inputs.growthUndecided || (inputs.reportsLive && !inputs.growthSettled)
        }
        return inputs.reportsLive && !inputs.durationKnown && !inputs.filmOrEpisode
    }

    /// Decide at the rising edge of `eof-reached`, at `nowSec` (a monotonic clock). A `.reconnect`
    /// is recorded; the other decisions leave the window as it was (pruned).
    mutating func decide(_ inputs: Inputs, nowSec: Double) -> Decision {
        guard Self.isEligible(inputs), nowSec.isFinite else { return .notEligible }
        recent.removeAll { nowSec - $0 > Self.windowSec || $0 > nowSec }
        // How the reconnect before this one went: did the channel play for a while after it?
        if let last = playedAtLastReconnect {
            unproductiveStreak = inputs.secondsPlayed - last < Self.productiveSec ? unproductiveStreak + 1 : 0
        }
        guard recent.count < Self.limit else { return .capReached(reconnects: recent.count) }
        guard unproductiveStreak < Self.unproductiveLimit else { return .capReached(reconnects: unproductiveStreak) }
        recent.append(nowSec)
        playedAtLastReconnect = inputs.secondsPlayed
        return .reconnect(attempt: recent.count)
    }
}
