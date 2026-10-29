import Foundation

/// When is the stream playing live, and may its position be saved for resume. Port of NuvioTV
/// Android's `LivePlaybackUiPolicy` (b4e47d6d6, 583eae818): a live stream's position is no point
/// to come back to, because resuming there seeks past what the stream still holds and nothing
/// plays. Both engines feed it from the tick they already run and gate every progress write
/// (`PlaybackProgressRecorder.record` for the native engine, `saveProgress` in the libmpv player)
/// on `shouldSaveResume`, so a live stream writes neither a resume position nor a "completed".
///
/// How each engine knows a stream is live:
/// - AVPlayer reports an indefinite item duration for live HLS (`reportsLive`). The native remux
///   path always publishes a complete VOD playlist, so its duration never grows.
/// - mpv can seek a live HLS stream inside its cache, so it reports it seekable and gives it a
///   duration: what it has loaded so far, which keeps growing while a VOD's stays put. That growth
///   (`nextDurationGrowth`) is the signal.
///
/// Pure value types, no player: every reading is passed in, so `LivePlaybackPolicyTests` drives it.
nonisolated enum LivePlaybackPolicy {
    /// Growth past the first reading that marks a live stream (a VOD's duration only settles by a
    /// little).
    static let liveDurationGrowthSec: Double = 10

    /// First duration seen for `mediaKey` (0 = none yet) and whether it has grown since. `grew`
    /// latches: once live, a later reading (a smaller one included) never clears it for that media.
    struct DurationGrowth: Equatable, Sendable {
        var mediaKey: String?
        var firstDurationSec: Double = 0
        var grew = false

        init(mediaKey: String? = nil, firstDurationSec: Double = 0, grew: Bool = false) {
            self.mediaKey = mediaKey
            self.firstDurationSec = firstDurationSec
            self.grew = grew
        }
    }

    /// Fold one tick's duration reading into `previous`. A new `mediaKey` starts over. Readings
    /// taken before the engine reports the requested media (`fromRequestedMedia` false) are
    /// skipped: they can still be the previous file's, or the property cache's zero default.
    static func nextDurationGrowth(_ previous: DurationGrowth, mediaKey: String?, durationSec: Double,
                                   fromRequestedMedia: Bool) -> DurationGrowth {
        let current = previous.mediaKey == mediaKey ? previous : DurationGrowth(mediaKey: mediaKey)
        guard fromRequestedMedia, durationSec.isFinite, durationSec > 0, !current.grew else { return current }
        var next = current
        if next.firstDurationSec == 0 {
            next.firstDurationSec = durationSec
        } else if durationSec > next.firstDurationSec + liveDurationGrowthSec {
            next.grew = true
        }
        return next
    }

    /// Live when the engine says so outright (AVPlayer's indefinite duration) or the duration grew.
    static func isLive(reportsLive: Bool, growth: DurationGrowth) -> Bool {
        reportsLive || growth.grew
    }

    /// The common gate both engines' progress writes run: never for a live stream, otherwise the
    /// rule they already had (a known duration and more than a second in).
    static func shouldSaveResume(isLive: Bool, positionSec: Double, durationSec: Double) -> Bool {
        guard !isLive else { return false }
        return durationSec.isFinite && positionSec.isFinite && durationSec > 0 && positionSec > 1
    }
}
