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
/// On mpv, resume saves of an HLS or DASH stream wait longer (`holdsResume`, `needsSettleHold`):
/// until `liveUndecidedHoldSec` has passed since the first reading or the last growing one, since a
/// live stream's first growth can come a playlist refresh after its first save would. Everything
/// else saves as before: the native engine (AVPlayer reports live HLS outright on its first tick,
/// and its remux path serves a complete VOD playlist) and any other mpv format (a raw HTTP TS live
/// stream has no duration, so `shouldSaveResume` already refuses it). Should an HLS stream turn
/// live after a save got through, the mpv player puts back what the session overwrote.
///
/// Accepted residual: an HLS live stream paused before it latches, with mpv's cache full (a very
/// small Streaming Buffer) so the duration stops growing, and closed after the hold, saves resume
/// and stops its trackers at position / duration; it never latched, so nothing undoes it.
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
    /// its last growing reading (and resume saves after the first reading). A live stream grows
    /// every segment, well inside it; a VOD whose duration settled once is released again after it.
    static let liveUndecidedHoldSec: Double = 30
    /// The least rise over the last counted step (or the anchor) that counts as growth: a live
    /// stream grows in segment-sized steps, or smoothly adds up past it, while a VOD's duration can
    /// jitter by a fraction of a second.
    static let liveMinGrowthStepSec: Double = 1
    /// The least clock time since the anchor before growth can latch: a 6 s-segment live stream
    /// needs about 18 s anyway, while a VOD's refinements can come a few seconds apart.
    static let liveMinElapsedSec: Double = 12

    /// The anchor duration and clock time growth is measured from (anchor duration 0 = no reading
    /// yet), the last duration seen, the duration at the last counted step, the growing readings
    /// since the anchor and when the last one was, the first reading's clock time, and whether that
    /// made it live. `grew` latches: once
    /// live, a later reading (a smaller one included) never clears it for that media. `undecided`:
    /// not live yet, but a growing reading came within `liveUndecidedHoldSec`. `resumeSettled`: not
    /// live, and `liveUndecidedHoldSec` has passed since the first reading or the last growing one.
    struct DurationGrowth: Equatable, Sendable {
        var mediaKey: String?
        var anchorDurationSec: Double = 0
        var anchorAtSec: Double = 0
        var lastDurationSec: Double = 0
        var stepDurationSec: Double = 0
        var growthReadings = 0
        var lastGrowthAtSec: Double?
        var firstReadingAtSec: Double?
        var grew = false
        var undecided = false
        var resumeSettled = false

        init(mediaKey: String? = nil) {
            self.mediaKey = mediaKey
        }
    }

    /// Fold one tick's duration reading, taken at `nowSec` (a monotonic clock, e.g.
    /// `ProcessInfo.systemUptime`), into `previous`. A new `mediaKey` starts over. Readings taken
    /// before the engine reports the requested media (`fromRequestedMedia` false) are skipped: they
    /// can still be the previous file's, or the property cache's zero default. Live once
    /// `liveGrowthReadings` readings grew (each by at least `liveMinGrowthStepSec`) since the anchor
    /// with the duration keeping within `liveGrowthSlackSec` of the clock, and, at a growing reading,
    /// the duration is more than `liveDurationGrowthSec` past the anchor and at least
    /// `liveMinElapsedSec` passed since it.
    static func nextDurationGrowth(_ previous: DurationGrowth, mediaKey: String?, durationSec: Double,
                                   nowSec: Double, fromRequestedMedia: Bool) -> DurationGrowth {
        let current = previous.mediaKey == mediaKey ? previous : DurationGrowth(mediaKey: mediaKey)
        guard fromRequestedMedia, durationSec.isFinite, durationSec > 0, nowSec.isFinite, !current.grew else {
            return current
        }
        var next = current
        if next.firstReadingAtSec == nil { next.firstReadingAtSec = nowSec }
        if next.anchorDurationSec == 0
            || abs((durationSec - next.anchorDurationSec) - (nowSec - next.anchorAtSec)) > liveGrowthSlackSec {
            next.anchorDurationSec = durationSec
            next.anchorAtSec = nowSec
            next.stepDurationSec = durationSec
            next.growthReadings = 0
        } else if durationSec >= next.stepDurationSec + liveMinGrowthStepSec {
            next.stepDurationSec = durationSec
            next.growthReadings += 1
            next.lastGrowthAtSec = nowSec
            if next.growthReadings >= liveGrowthReadings,
               durationSec > next.anchorDurationSec + liveDurationGrowthSec,
               nowSec - next.anchorAtSec >= liveMinElapsedSec {
                next.grew = true
            }
        }
        next.lastDurationSec = durationSec
        next.undecided = !next.grew && next.lastGrowthAtSec.map { nowSec - $0 <= liveUndecidedHoldSec } == true
        let quietSince = next.lastGrowthAtSec ?? next.firstReadingAtSec ?? nowSec
        next.resumeSettled = !next.grew && nowSec - quietSince > liveUndecidedHoldSec
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

    /// What mpv's resume saves gate on: `holdsProgress`, and with `settleHold` (an HLS or DASH
    /// stream, `needsSettleHold`) also until the stream has been quiet for `liveUndecidedHoldSec`
    /// (`DurationGrowth.resumeSettled`), so no save lands before a live stream's first growth.
    static func holdsResume(reportsLive: Bool, growth: DurationGrowth, settleHold: Bool) -> Bool {
        holdsProgress(reportsLive: reportsLive, growth: growth) || (settleHold && !growth.resumeSettled)
    }

    /// Whether mpv is playing a format that can be live while still reading seekable with a finite
    /// duration: HLS or DASH, by mpv's `file-format` (lavf demuxer names, comma-separated aliases;
    /// nil = not reported yet) or, before that, the URL's extension.
    static func needsSettleHold(fileFormat: String?, url: URL) -> Bool {
        let adaptive: Set<String> = ["hls", "applehttp", "dash"]
        if let fileFormat, fileFormat.lowercased().split(separator: ",").contains(where: { adaptive.contains(String($0)) }) {
            return true
        }
        return ["m3u8", "mpd"].contains(url.pathExtension.lowercased())
    }

    /// The common gate both engines' progress writes run: never for a live stream, otherwise the
    /// rule they already had (a known duration and more than a second in).
    static func shouldSaveResume(isLive: Bool, positionSec: Double, durationSec: Double) -> Bool {
        guard !isLive else { return false }
        return durationSec.isFinite && positionSec.isFinite && durationSec > 0 && positionSec > 1
    }
}
