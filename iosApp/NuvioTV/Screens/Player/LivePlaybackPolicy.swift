import Foundation

/// When is the stream playing live, and may its position be saved for resume. Port of NuvioTV
/// Android's `LivePlaybackUiPolicy` (b4e47d6d6, 583eae818): a live stream's position is no point
/// to come back to, because resuming there seeks past what the stream still holds and nothing
/// plays. Both engines feed it from the tick they already run and gate every progress write
/// (`PlaybackProgressRecorder.record` for the native engine, `saveProgress` in the libmpv player)
/// on `shouldSaveResume`, so a live stream writes neither a resume position nor a "completed".
///
/// How each engine knows a stream is live (`reportsLive` OR duration growth, as upstream's
/// `isLivePlayback`):
/// - Either engine: the content type is "channel" (a live channel from an add-on catalogue).
/// - AVPlayer reports an indefinite item duration for live HLS. The native remux path always
///   publishes a complete VOD playlist, so its duration never grows.
/// - mpv reports `seekable` false once the file is loaded. A live HLS stream it can still seek
///   inside its cache reads seekable instead, with a duration that is what it has loaded so far:
///   that keeps growing while a VOD's stays put. That growth (`nextDurationGrowth`) is the signal.
///
/// A live stream also closes its Trakt / Simkl / MDBList sessions at 0 % (`TrackerScrobblePolicy.
/// stopPercent`), so no tracker marks it watched and history sync brings no "completed" back.
///
/// Pure value types, no player: every reading is passed in, so `LivePlaybackPolicyTests` drives it.
nonisolated enum LivePlaybackPolicy {
    /// Growth past the first reading that marks a live stream (a VOD's duration only settles by a
    /// little).
    static let liveDurationGrowthSec: Double = 10
    /// Growing readings needed, each taken with the position near the duration edge. A VOD whose
    /// duration mpv refines after FILE_LOADED (MPEG-TS, fragmented MP4 without sidx/mehd, unindexed
    /// AVI) jumps once or twice, mostly while the viewer is nowhere near the end; a live stream keeps
    /// growing under a position that follows it.
    static let liveGrowthReadings = 3
    /// How close to the duration edge the position must be for a growing reading to count: a live
    /// player sits a few segments behind what it has loaded.
    static let liveEdgeWindowSec: Double = 60

    /// First and last duration seen for `mediaKey` (0 = none yet), how many readings grew at the
    /// edge, and whether that made it live. `grew` latches: once live, a later reading (a smaller
    /// one included) never clears it for that media.
    struct DurationGrowth: Equatable, Sendable {
        var mediaKey: String?
        var firstDurationSec: Double = 0
        var lastDurationSec: Double = 0
        var edgeGrowthReadings = 0
        var grew = false

        init(mediaKey: String? = nil, firstDurationSec: Double = 0, lastDurationSec: Double = 0,
             edgeGrowthReadings: Int = 0, grew: Bool = false) {
            self.mediaKey = mediaKey
            self.firstDurationSec = firstDurationSec
            self.lastDurationSec = lastDurationSec
            self.edgeGrowthReadings = edgeGrowthReadings
            self.grew = grew
        }
    }

    /// Fold one tick's duration and position readings into `previous`. A new `mediaKey` starts
    /// over. Readings taken before the engine reports the requested media (`fromRequestedMedia`
    /// false) are skipped: they can still be the previous file's, or the property cache's zero
    /// default. Live once `liveGrowthReadings` readings grew with the position within
    /// `liveEdgeWindowSec` of the edge and the duration is more than `liveDurationGrowthSec` past
    /// the first reading.
    static func nextDurationGrowth(_ previous: DurationGrowth, mediaKey: String?, durationSec: Double,
                                   positionSec: Double, fromRequestedMedia: Bool) -> DurationGrowth {
        let current = previous.mediaKey == mediaKey ? previous : DurationGrowth(mediaKey: mediaKey)
        guard fromRequestedMedia, durationSec.isFinite, durationSec > 0, !current.grew else { return current }
        var next = current
        if next.firstDurationSec == 0 {
            next.firstDurationSec = durationSec
        } else if durationSec > next.lastDurationSec, positionSec.isFinite,
                  positionSec >= durationSec - liveEdgeWindowSec {
            next.edgeGrowthReadings += 1
        }
        next.lastDurationSec = durationSec
        if next.edgeGrowthReadings >= liveGrowthReadings,
           durationSec > next.firstDurationSec + liveDurationGrowthSec {
            next.grew = true
        }
        return next
    }

    /// What the engine says outright, before any growth: a "channel" item, AVPlayer's indefinite
    /// duration (`indefiniteDuration`), or mpv's `seekable` false (nil = not reported yet, or
    /// before FILE_LOADED: the caller passes nil then).
    static func reportsLive(contentType: String, indefiniteDuration: Bool = false, seekable: Bool? = nil) -> Bool {
        contentType.caseInsensitiveCompare("channel") == .orderedSame || indefiniteDuration || seekable == false
    }

    /// Live when the engine says so outright (`reportsLive`) or the duration grew.
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
