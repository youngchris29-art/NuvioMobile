import Foundation

/// When is the stream playing live, and may its position be saved for resume. Port of NuvioTV
/// Android's `LivePlaybackUiPolicy` (b4e47d6d6, 583eae818): a live stream's position is no point
/// to come back to, because resuming there seeks past what the stream still holds and nothing
/// plays. Both engines feed it from the tick they already run and gate every progress write
/// (`PlaybackProgressRecorder.record` for the native engine, `saveProgress` in the libmpv player)
/// on `shouldSaveResume`, so a live stream writes neither a resume position nor a "completed".
///
/// How each engine knows a stream is live (`reportsLive` OR duration growth):
/// - AVPlayer reports an indefinite item duration for live HLS. The native remux path always
///   publishes a complete VOD playlist, so its duration never grows.
/// - mpv reports `seekable` false once the file is loaded. A live HLS stream it can still seek
///   inside its cache reads seekable instead, with a duration that is what it has loaded so far:
///   that keeps growing at the pace of the clock while a VOD's stays put. That growth
///   (`nextDurationGrowth`) is the signal.
///
/// Not a signal on its own: the content type "channel". Upstream's `isLiveContentType` treats it as
/// live, but Stremio "channel" catalogues (YouTube-channel add-ons) list on-demand videos, which
/// would then keep no resume and close their trackers at 0 %. A real live channel still shows one
/// of the player signals above, so dropping it costs at most the few seconds growth takes.
///
/// A live stream also closes its Trakt / Simkl / MDBList sessions at 0 % (`TrackerScrobblePolicy.
/// stopPercent`), so no tracker marks it watched and history sync brings no "completed" back. While
/// growth has started but not yet decided (`DurationGrowth.undecided`), `holdsProgress` already
/// holds both back, so an open-and-close in the first seconds of a live stream sends no 80 % stop.
///
/// Pure value types, no player: every reading is passed in, so `LivePlaybackPolicyTests` drives it.
nonisolated enum LivePlaybackPolicy {
    /// Growth past the anchor reading that marks a live stream (a VOD's duration only settles by a
    /// little).
    static let liveDurationGrowthSec: Double = 10
    /// Growing readings needed after the anchor. A VOD whose duration mpv refines after
    /// FILE_LOADED (MPEG-TS, fragmented MP4 without sidx/mehd, unindexed AVI) jumps once or twice;
    /// a live stream keeps growing.
    static let liveGrowthReadings = 3
    /// How far the duration may run ahead of, or fall behind, the clock since the anchor: a live
    /// stream's duration grows by about one second a second, in segment-sized steps (a playlist
    /// refresh can add one or two at once). Past it the count starts over from that reading: a jump
    /// ahead is a VOD's duration being refined, and a duration lagging the clock is a VOD's fixed
    /// one (or a stalled stream), so growth only adds up while it keeps pace with the clock.
    /// Position plays no part, so a paused stream (mpv keeps loading the live window) or one
    /// rewound far behind the edge latches all the same.
    static let liveGrowthSlackSec: Double = 15
    /// How long a started but undecided growth holds resume saves and tracker progress back after
    /// its last growing reading. A live stream grows every segment, well inside it; a VOD whose
    /// duration settled once is released again after it.
    static let liveUndecidedHoldSec: Double = 30

    /// The anchor duration and clock time growth is measured from (anchor duration 0 = no reading
    /// yet), the last duration seen, the growing readings since the anchor and when the last one
    /// was, and whether that made it live. `grew` latches: once live, a later reading (a smaller one
    /// included) never clears it for that media. `undecided`: not live yet, but a growing reading
    /// came within `liveUndecidedHoldSec`.
    struct DurationGrowth: Equatable, Sendable {
        var mediaKey: String?
        var anchorDurationSec: Double = 0
        var anchorAtSec: Double = 0
        var lastDurationSec: Double = 0
        var growthReadings = 0
        var lastGrowthAtSec: Double?
        var grew = false
        var undecided = false

        init(mediaKey: String? = nil) {
            self.mediaKey = mediaKey
        }
    }

    /// Fold one tick's duration reading, taken at `nowSec` (a monotonic clock, e.g.
    /// `ProcessInfo.systemUptime`), into `previous`. A new `mediaKey` starts over. Readings taken
    /// before the engine reports the requested media (`fromRequestedMedia` false) are skipped: they
    /// can still be the previous file's, or the property cache's zero default. Live once
    /// `liveGrowthReadings` readings grew since the anchor with the duration keeping within
    /// `liveGrowthSlackSec` of the clock, and the duration is more than `liveDurationGrowthSec` past
    /// the anchor.
    static func nextDurationGrowth(_ previous: DurationGrowth, mediaKey: String?, durationSec: Double,
                                   nowSec: Double, fromRequestedMedia: Bool) -> DurationGrowth {
        let current = previous.mediaKey == mediaKey ? previous : DurationGrowth(mediaKey: mediaKey)
        guard fromRequestedMedia, durationSec.isFinite, durationSec > 0, nowSec.isFinite, !current.grew else {
            return current
        }
        var next = current
        if next.anchorDurationSec == 0
            || abs((durationSec - next.anchorDurationSec) - (nowSec - next.anchorAtSec)) > liveGrowthSlackSec {
            next.anchorDurationSec = durationSec
            next.anchorAtSec = nowSec
            next.growthReadings = 0
        } else if durationSec > next.lastDurationSec {
            next.growthReadings += 1
            next.lastGrowthAtSec = nowSec
        }
        next.lastDurationSec = durationSec
        if next.growthReadings >= liveGrowthReadings,
           durationSec > next.anchorDurationSec + liveDurationGrowthSec {
            next.grew = true
        }
        next.undecided = !next.grew && next.lastGrowthAtSec.map { nowSec - $0 <= liveUndecidedHoldSec } == true
        return next
    }

    /// What the engine says outright, before any growth: AVPlayer's indefinite duration
    /// (`indefiniteDuration`), or mpv's `seekable` false (nil = not reported yet, or before
    /// FILE_LOADED: the caller passes nil then).
    static func reportsLive(indefiniteDuration: Bool = false, seekable: Bool? = nil) -> Bool {
        indefiniteDuration || seekable == false
    }

    /// Live when the engine says so outright (`reportsLive`) or the duration grew.
    static func isLive(reportsLive: Bool, growth: DurationGrowth) -> Bool {
        reportsLive || growth.grew
    }

    /// Live, or growth started and not decided yet: what the progress writes and tracker stops
    /// gate on, so nothing is saved or sent while a stream may still turn out live.
    static func holdsProgress(reportsLive: Bool, growth: DurationGrowth) -> Bool {
        isLive(reportsLive: reportsLive, growth: growth) || growth.undecided
    }

    /// The common gate both engines' progress writes run: never for a live stream, otherwise the
    /// rule they already had (a known duration and more than a second in).
    static func shouldSaveResume(isLive: Bool, positionSec: Double, durationSec: Double) -> Bool {
        guard !isLive else { return false }
        return durationSec.isFinite && positionSec.isFinite && durationSec > 0 && positionSec > 1
    }
}
