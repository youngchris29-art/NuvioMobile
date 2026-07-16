import Foundation

// Phase 4 of the hybrid player (plan decision D2/D3): the complete, up-front VOD segment map.
//
// tvOS 27 rejects EVENT / growing HLS playlists (-12927 right after the first segment) and only plays
// a VOD playlist that carries EXT-X-ENDLIST from the very first fetch. So the native path must publish
// a COMPLETE media playlist — every segment, exact EXTINF, ENDLIST — before a single segment file
// exists, then produce/serve those segments just-in-time.
//
// This type derives that map from the source video stream's KEYFRAME index (MP4 `stss` / MKV Cues,
// read at avformat open). Crucially, the D3 segmenter (`RemuxSession`) cuts its fMP4 fragments at
// exactly THESE keyframe boundaries, so the published playlist matches the produced files by
// construction: a sparse Cue list just yields longer-but-valid segments, never a desync. When the
// index is missing or too sparse to yield reasonable segments, `build` returns nil and the coordinator
// falls back to mpv (conservative routing — there is no EVENT path to fall back to on tvOS 27).
//
// Pure Swift, no libav* types — unit-testable with canned keyframe arrays (the highest-value test
// surface: an off-by-one here is an unrecoverable mid-movie stall on device).
nonisolated struct SegmentMap: Sendable {
    struct Segment: Sendable, Equatable {
        let number: Int          // 1-based; the media file is `seg-{number:05d}.m4s`
        let startTicks: Int64    // segment start PTS in the source video stream time_base
        let durationSec: Double  // EXTINF
    }

    let segments: [Segment]
    let totalDurationSec: Double

    var count: Int { segments.count }

    /// The per-segment start PTS (source video time_base) that DRIVE fragment cutting. `boundaryTicks[i]`
    /// is where segment `i+1` begins; the segmenter flushes a fragment when a video keyframe reaches it.
    var boundaryTicks: [Int64] { segments.map(\.startTicks) }

    /// EXT-X-TARGETDURATION must be >= every EXTINF (HLS spec; tvOS rejects a stream that violates it).
    /// Computed from the real max segment duration, rounded up.
    var targetDurationSec: Int {
        max(1, Int((segments.map(\.durationSec).max() ?? 0).rounded(.up)))
    }

    /// Replay the segmenter's greedy cut rule over the source keyframe PTS list (sorted ascending, in
    /// the video stream's time_base): segment 1 starts at the first keyframe; a new segment begins at
    /// the first keyframe whose `pts - segmentStart >= segDur`. All comparison is integer/rational in
    /// the source time_base (never float) so a keyframe landing exactly on a boundary can't flip.
    ///
    /// Returns nil when the index is unusable: empty, non-positive time_base, unknown duration, or so
    /// sparse that the average segment would exceed `maxAvgSegSec` (route to mpv rather than serve a
    /// stream of enormous segments).
    static func build(keyframeTicks: [Int64],
                      timeBaseNum: Int32,
                      timeBaseDen: Int32,
                      totalDurationSec: Double,
                      segDurSec: Int,
                      maxAvgSegSec: Double = 30) -> SegmentMap? {
        guard timeBaseNum > 0, timeBaseDen > 0,
              segDurSec > 0, totalDurationSec > 0,
              !keyframeTicks.isEmpty else { return nil }

        // De-dupe + sort defensively; index entries are usually sorted but a stray duplicate boundary
        // would emit a zero-length segment.
        let ticks = Array(Set(keyframeTicks)).sorted()
        let tbSec = Double(timeBaseNum) / Double(timeBaseDen)

        // seg duration expressed in source ticks: segDurSec / tbSec = segDurSec * den / num.
        let segDurTicks = Int64(segDurSec) * Int64(timeBaseDen) / Int64(timeBaseNum)
        guard segDurTicks > 0 else { return nil }

        var starts: [Int64] = [ticks[0]]
        var segStart = ticks[0]
        for k in ticks.dropFirst() where k - segStart >= segDurTicks {
            starts.append(k)
            segStart = k
        }

        // The final segment runs to the true media end (from the probe duration), so the summed EXTINF
        // equals the real duration exactly — no early EOS, no phantom tail. If a keyframe lands at (or
        // just before, within rounding of) the media end, folding it into the previous segment keeps a
        // valid map instead of dropping the whole native path — the segmenter, driven by these same
        // boundaries, simply doesn't cut there either.
        let endTicks = ticks[0] + Int64((totalDurationSec / tbSec).rounded())
        while starts.count > 1, endTicks <= starts.last! { starts.removeLast() }
        guard endTicks > starts.last! else { return nil }

        var segments: [Segment] = []
        segments.reserveCapacity(starts.count)
        for (i, start) in starts.enumerated() {
            let end = (i + 1 < starts.count) ? starts[i + 1] : endTicks
            let durationSec = Double(end - start) * tbSec
            guard durationSec > 0 else { return nil }   // non-monotonic boundary → unusable
            segments.append(Segment(number: i + 1, startTicks: start, durationSec: durationSec))
        }

        let avgSegSec = totalDurationSec / Double(segments.count)
        guard avgSegSec <= maxAvgSegSec else { return nil }   // index too sparse to segment usefully

        return SegmentMap(segments: segments, totalDurationSec: totalDurationSec)
    }

    // MARK: - Playlist synthesis

    /// The complete VOD media playlist (single muxed-A/V representation), published up front with
    /// EXT-X-ENDLIST so tvOS 27 treats it as VOD from the first fetch.
    func mediaPlaylist(initName: String = "init.mp4", segmentPrefix: String = "seg-") -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDurationSec)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:1",
            "#EXT-X-MAP:URI=\"\(initName)\"",
        ]
        for seg in segments {
            lines.append(String(format: "#EXTINF:%.6f,", seg.durationSec))
            lines.append("\(segmentPrefix)\(String(format: "%05d", seg.number)).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The master playlist: one variant pointing at `mediaName`, carrying the full RFC 6381 CODECS and
    /// (for DV) SUPPLEMENTAL-CODECS so Dolby Vision engages. Muxed A/V, so CODECS lists video + audio
    /// and there is no separate EXT-X-MEDIA audio rendition to keep aligned.
    func masterPlaylist(signaling: VideoSignaling,
                        audioCodec: String?,
                        bandwidth: Int,
                        mediaName: String = "media.m3u8") -> String {
        var codecTokens: [String] = []
        if !signaling.codecs.isEmpty { codecTokens.append(signaling.codecs) }
        if let audioCodec, !audioCodec.isEmpty { codecTokens.append(audioCodec) }
        var streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(max(bandwidth, 1))"
        if signaling.width > 0, signaling.height > 0 {
            streamInf += ",RESOLUTION=\(signaling.width)x\(signaling.height)"
        }
        if signaling.frameRate > 0 {
            streamInf += String(format: ",FRAME-RATE=%.3f", signaling.frameRate)
        }
        streamInf += ",CODECS=\"\(codecTokens.joined(separator: ","))\""
        if let supp = signaling.supplementalCodecs {
            streamInf += ",SUPPLEMENTAL-CODECS=\"\(supp)\""
        }
        // VIDEO-RANGE is REQUIRED for HDR on tvOS 27: PQ media behind a master that doesn't declare it
        // is rejected at media admission (-12927); declared (with full CODECS + SUPPLEMENTAL-CODECS,
        // the exact shape device-validated via the probe rig), the same media plays.
        if let range = signaling.videoRange {
            streamInf += ",VIDEO-RANGE=\(range)"
        }
        return ["#EXTM3U", "#EXT-X-VERSION:7", streamInf, mediaName].joined(separator: "\n") + "\n"
    }
}
