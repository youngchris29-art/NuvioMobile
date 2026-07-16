import Foundation
import Libavformat
import Libavcodec
import Libavutil

// Phase 2/4 of the hybrid player: on-device MKV→fMP4 remux with an OWNED segmenter (plan decision D3).
// Stream-copies (no re-encode) the compatible video and audio tracks of a source into fragmented-MP4
// segments, preserving Dolby Vision (RPU NALs ride along in the copied bitstream; the `dvvC` box is
// written by movenc from the DOVI side data). Runs on a background worker; the emitted directory —
// one init segment plus `seg-NNNNN.m4s` files — is served to AVPlayer by `LocalHLSServer`.
//
// WHY WE OWN THE SEGMENTER (not the `dash` muxer): tvOS 27 rejects EVENT/growing playlists and only
// plays a VOD playlist (EXT-X-ENDLIST) published complete up front — but the segment files must still
// be produced just-in-time (remux ≈ realtime for debrid sources). A complete up-front playlist and a
// third-party muxer's autonomous cut decisions can silently disagree (MKV Cues are often a sparse
// subset of real keyframes), and one mismatched boundary desyncs the whole tail unrecoverably. So we
// cut the fMP4 ourselves at the `SegmentMap`'s keyframe boundaries via the mov/mp4 muxer with
// `movflags frag_custom+empty_moov+default_base_moof` and a custom AVIO sink (`SegmentWriter`) that
// routes each fragment into its own atomically-renamed file. Published == produced by construction;
// sparse Cues just yield longer-but-valid segments. See docs/tvos-hybrid-player-plan.md.
//
// The remux still runs linearly (whole file, start to finish); true seek-anywhere (av_seek_frame to an
// arbitrary segment's keyframe and mux one independent fragment on demand) is the next increment the
// owned segmenter unlocks.

/// HLS master-playlist signaling for the remuxed video, per Apple's HLS authoring spec: a full
/// RFC 6381 CODECS token (bare "hvc1" is non-compliant and stricter tvOS builds reject it), plus
/// Dolby Vision SUPPLEMENTAL-CODECS and VIDEO-RANGE for HDR. VIDEO-RANGE is REQUIRED on tvOS 27:
/// PQ media behind a master that doesn't declare it is rejected at media admission (-12927) —
/// confirmed by device A/B (identical media plays with the declaration, fails without).
nonisolated struct VideoSignaling: Sendable {
    var codecs: String                 // e.g. "hvc1.2.4.L153.B0" or "dvh1.05.06"
    var supplementalCodecs: String?    // e.g. "dvh1.08.06/db1p" (DV P8.1 over HDR10)
    var videoRange: String?            // "PQ" / "HLG"
    var width: Int32 = 0               // RESOLUTION=WxH when known (part of the validated master shape)
    var height: Int32 = 0
    var frameRate: Double = 0          // FRAME-RATE when known
}

nonisolated final class RemuxSession: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case idle
        case running
        case ready              // remux finished; complete VOD playlist available
        case failed(String)
    }

    struct Config: Sendable {
        let url: URL
        var segmentDurationSec: Int = 4
    }

    let config: Config
    let outputDir: URL
    /// Synthesized HLS master playlist name within `outputDir` (what AVPlayer loads). Served by
    /// `LocalHLSServer` from the `SegmentMap`; no file of this name is written to disk.
    let masterPlaylistName = "master.m3u8"

    private let lock = NSLock()
    private var _state: State = .idle
    private var _cancelled = false
    private var _signaling: VideoSignaling?
    private var _segmentMap: SegmentMap?
    private var _hasAudio = false
    private var _audioCodecToken: String?
    private var _estimatedBandwidth = 20_000_000
    private var onStateChange: (@Sendable (State) -> Void)?
    private let queue = DispatchQueue(label: "media.nuvio.remux", qos: .userInitiated)

    var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    /// Master-playlist signaling for the copied video, set once the video stream is inspected.
    /// `LocalHLSServer` bakes it into the synthesized master playlist (full RFC 6381 CODECS + DV
    /// SUPPLEMENTAL-CODECS; DV won't engage without it).
    var videoSignaling: VideoSignaling? { lock.lock(); defer { lock.unlock() }; return _signaling }

    /// The complete VOD segment map, derived from the source keyframe index at remux start (before any
    /// segment is produced). nil once the source is inspected means the index is unusable → the
    /// coordinator must fall back to mpv. `LocalHLSServer` synthesizes the VOD playlists from this and
    /// the remux cuts its fragments at the map's boundaries, so published == produced.
    var segmentMap: SegmentMap? { lock.lock(); defer { lock.unlock() }; return _segmentMap }

    /// Whether an audio track is muxed alongside video (single A/V representation).
    var hasAudio: Bool { lock.lock(); defer { lock.unlock() }; return _hasAudio }

    /// RFC 6381 audio codec token for the master CODECS list (e.g. "mp4a.40.2", "ac-3", "ec-3"), or nil.
    var audioCodecToken: String? { lock.lock(); defer { lock.unlock() }; return _audioCodecToken }

    /// Rough peak bandwidth for the master EXT-X-STREAM-INF (single variant — advisory, no ABR).
    var estimatedBandwidth: Int { lock.lock(); defer { lock.unlock() }; return _estimatedBandwidth }

    init(config: Config, outputDir: URL? = nil) {
        self.config = config
        self.outputDir = outputDir ?? RemuxSession.makeSessionDir()
    }

    /// Begin remuxing on a background queue. `onStateChange` fires on every transition (off-main).
    func start(onStateChange: @Sendable @escaping (State) -> Void) {
        lock.lock(); self.onStateChange = onStateChange; lock.unlock()
        queue.async { [weak self] in self?.runRemux() }
    }

    /// Request cancellation; the remux loop stops at the next packet boundary.
    func stop() { lock.lock(); _cancelled = true; lock.unlock() }

    /// Remove the emitted directory. Call once the session is finished with.
    func cleanup() { try? FileManager.default.removeItem(at: outputDir) }

    // MARK: - Remux worker

    private func runRemux() {
        setState(.running)
        // Errors/warnings only — the muxer otherwise logs two "Opening … for writing" info lines per
        // segment, which floods the Xcode console on long content.
        av_log_set_level(AV_LOG_WARNING)

        // --- Open + inspect the source ------------------------------------------------------------
        // +genpts: some sources (sloppy MKV muxes) emit packets with missing PTS/DTS, which poisons
        // the output fMP4 timeline (AVPlayer rejects it with CoreMediaErrorDomain -12927).
        var inOpts: OpaquePointer?
        av_dict_set(&inOpts, "fflags", "+genpts", 0)
        defer { av_dict_free(&inOpts) }
        var inCtx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&inCtx, config.url.absoluteString, nil, &inOpts) == 0, let input = inCtx else {
            return fail("avformat_open_input")
        }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = input; avformat_close_input(&p) }
        guard avformat_find_stream_info(input, nil) >= 0 else { return fail("find_stream_info") }

        var videoIn = -1, audioIn = -1
        for i in 0..<Int(input.pointee.nb_streams) {
            guard let s = input.pointee.streams[i], let par = s.pointee.codecpar else { continue }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO where videoIn < 0: videoIn = i
            case AVMEDIA_TYPE_AUDIO where audioIn < 0 && isCopyableAudio(par.pointee.codec_id): audioIn = i
            default: break
            }
        }
        guard videoIn >= 0, let videoPar = input.pointee.streams[videoIn]?.pointee.codecpar else {
            return fail("no video stream")
        }
        // Some sources carry the video with EMPTY extradata (parameter sets only inband). The init
        // segment then has no valid hvcC/avcC decoder configuration and AVPlayer rejects the stream
        // with CoreMediaErrorDomain -12927. Recover the parameter sets from the bitstream, then
        // rewind so the copy loop starts from the beginning.
        if videoPar.pointee.extradata_size == 0 {
            print("[Remux] video extradata missing — extracting parameter sets from bitstream")
            guard extractVideoExtradata(input: input, videoIndex: videoIn) else {
                return fail("extract extradata")
            }
            guard av_seek_frame(input, Int32(videoIn), 0, AVSEEK_FLAG_BACKWARD) >= 0 else {
                return fail("rewind after extradata extraction")
            }
        }

        // AVPlayer admission control rejects High-tier HEVC declarations (master stage when declared
        // in CODECS: "unsupported URL"; media stage from the init segment's hvcC: -12927) even though
        // VideoToolbox decodes such streams fine — the declared tier is advisory. Patch the hvcC
        // record to Main tier; the bitstream itself is untouched.
        if videoPar.pointee.codec_id == AV_CODEC_ID_HEVC,
           videoPar.pointee.extradata_size >= 13,
           let ed = videoPar.pointee.extradata, ed[0] == 1, (ed[1] & 0x20) != 0 {
            ed[1] &= 0xDF
            print("[Remux] hvcC declares High tier — patched to Main tier for AVPlayer admission")
        }

        var signaling = Self.videoSignaling(videoPar)
        signaling.width = videoPar.pointee.width
        signaling.height = videoPar.pointee.height
        if let vs = input.pointee.streams[videoIn] {
            let fr = vs.pointee.avg_frame_rate
            if fr.num > 0, fr.den > 0 { signaling.frameRate = Double(fr.num) / Double(fr.den) }
        }
        let audioPar = audioIn >= 0 ? input.pointee.streams[audioIn]?.pointee.codecpar : nil
        let audioToken = audioPar.flatMap { Self.audioCodecString($0) }
        // Rough peak bandwidth for the (single, non-ABR) master variant: sum of track bitrates + 10%,
        // or a generous default when the container doesn't declare them.
        let declaredBitrate = Int(videoPar.pointee.bit_rate) + (audioPar.map { Int($0.pointee.bit_rate) } ?? 0)
        let bandwidth = declaredBitrate > 0 ? Int(Double(declaredBitrate) * 1.1) : 20_000_000
        lock.lock()
        _signaling = signaling
        _hasAudio = audioIn >= 0
        _audioCodecToken = audioToken
        _estimatedBandwidth = bandwidth
        lock.unlock()
        print("[Remux] signaling CODECS=\(signaling.codecs)"
              + (signaling.supplementalCodecs.map { " SUPPLEMENTAL=\($0)" } ?? "")
              + (audioToken.map { " AUDIO=\($0)" } ?? ""))

        // --- Build the up-front VOD segment map from the source keyframe index --------------------
        // The owned segmenter cuts fragments at exactly these keyframe boundaries, so the synthesized
        // VOD playlist matches the produced files. nil ⇒ unusable index (empty / too sparse) ⇒ mpv.
        guard let map = buildSegmentMap(input: input, videoIndex: videoIn) else {
            return fail("no usable keyframe index")
        }
        lock.lock(); _segmentMap = map; lock.unlock()
        print("[Remux] segment map: \(map.count) segments, \(String(format: "%.1f", map.totalDurationSec))s, target=\(map.targetDurationSec)s")

        // --- Allocate the mov/mp4 output with our own segment-splitting AVIO sink -----------------
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outCtx, nil, "mp4", nil) >= 0, let output = outCtx else {
            return fail("alloc_output_context2")
        }
        defer { avformat_free_context(output) }
        output.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL   // allow the DV (dvvC) box

        var indexMap = [Int: Int]()
        func addStream(_ inIdx: Int, tag: UInt32) -> Bool {
            guard let inS = input.pointee.streams[inIdx], let inPar = inS.pointee.codecpar,
                  let outS = avformat_new_stream(output, nil), let outPar = outS.pointee.codecpar,
                  avcodec_parameters_copy(outPar, inPar) >= 0 else { return false }
            if tag != 0 { outPar.pointee.codec_tag = tag }   // hvc1/dvh1/avc1; let movenc pick for audio
            outS.pointee.time_base = inS.pointee.time_base
            indexMap[inIdx] = Int(outS.pointee.index)
            return true
        }
        guard addStream(videoIn, tag: videoOutputTag(videoPar)) else { return fail("add video stream") }
        if audioIn >= 0 { _ = addStream(audioIn, tag: 0) }

        // Stream fingerprint for device debugging: extradata_size==0 on video means the init segment
        // will lack a valid hvcC/avcC decoder config and AVPlayer rejects the stream (-12927).
        for (inIdx, outIdx) in indexMap.sorted(by: { $0.value < $1.value }) {
            if let par = input.pointee.streams[inIdx]?.pointee.codecpar?.pointee {
                let codec = avcodec_get_name(par.codec_id).map { String(cString: $0) } ?? "?"
                print("[Remux] out#\(outIdx) \(codec) \(par.width)x\(par.height) extradata=\(par.extradata_size)b bitrate=\(par.bit_rate)")
            }
        }

        // Custom AVIO sink: routes movenc's byte stream into init.mp4 + seg-NNNNN.m4s, each written
        // atomically (.part → rename) so the loopback server never serves a torn file. The sink is
        // APPEND-ONLY (no seek callback → movenc takes its streaming paths, as when writing to a pipe)
        // and splits files by parsing top-level MP4 box headers: ftyp+moov → init.mp4, everything
        // after → the current segment window. The AVIO context holds a RETAINED reference
        // (`passRetained`) for its whole lifetime — the write callback reaches the object only through
        // the opaque pointer, so a plain local `let` would let the ARC optimizer free it before the
        // last callback (movenc's trailer). The retain is balanced by `release()` in the defer.
        let writer = SegmentWriter(outputDir: outputDir)
        let ioBufSize = 1 << 16
        guard let ioBuf = av_malloc(ioBufSize) else { return fail("avio buffer") }
        let opaque = Unmanaged.passRetained(writer).toOpaque()
        guard let avio = avio_alloc_context(ioBuf.assumingMemoryBound(to: UInt8.self), Int32(ioBufSize),
                                            1, opaque, nil, segmentWriterWrite, nil) else {
            av_free(ioBuf)
            Unmanaged<SegmentWriter>.fromOpaque(opaque).release()
            return fail("avio_alloc_context")
        }
        output.pointee.pb = avio
        defer {   // free the AVIO context (and its possibly-reallocated buffer) before the format ctx,
                  // then release the sink's retain — after this no callback can fire.
            if let pb = output.pointee.pb {
                av_free(pb.pointee.buffer)
                var p: UnsafeMutablePointer<AVIOContext>? = pb
                avio_context_free(&p)
                output.pointee.pb = nil
            }
            Unmanaged<SegmentWriter>.fromOpaque(opaque).release()
        }

        // frag_custom: WE cut fragments via av_write_frame(ctx, NULL). empty_moov + default_base_moof
        // make each fragment self-contained. delay_moov is REQUIRED for EAC3 (and friends): movenc
        // builds the ec-3 sample entry (dec3 box) from a PARSED audio frame, so writing the moov at
        // write_header — before any packet — fails; with delay_moov the moov is emitted at the first
        // fragment flush instead, and the sink's box parser routes it into init.mp4 whenever it
        // arrives. skip_trailer drops the useless mfra.
        var opts: OpaquePointer?
        av_dict_set(&opts, "movflags", "frag_custom+empty_moov+default_base_moof+delay_moov+skip_trailer", 0)
        defer { av_dict_free(&opts) }

        // Only the ftyp is emitted here (moov is delayed); the sink accumulates it for init.mp4.
        guard avformat_write_header(output, &opts) >= 0 else { return fail("write_header") }
        avio_flush(output.pointee.pb)

        // --- Stream-copy loop with owned fragment cutting -----------------------------------------
        guard let pkt = av_packet_alloc() else { return fail("packet_alloc") }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        // Timestamp hygiene (unchanged from the dash path). Sloppy real-world muxes carry missing or
        // NON-MONOTONIC video DTS; the mp4 muxer writes them through and AVPlayer rejects the timeline
        // (-12927). Video DTS is REGENERATED wholesale on a uniform grid anchored at the first PTS and
        // offset back a few frames for B-frame reorder. Audio keeps source timestamps, gap-filled only
        // when a packet arrives without them.
        let noTS = Int64.min                                     // AV_NOPTS_VALUE
        let reorderSlack: Int64 = 6                              // frames of pts>=dts headroom
        let videoOutIdx = indexMap[videoIn] ?? 0
        var vIndex: Int64 = 0
        var vAnchor: Int64? = nil
        var vDur: Int64 = 0
        var vPrevDTS: Int64? = nil
        let nStreams = Int(output.pointee.nb_streams)
        var nextDTS = [Int64](repeating: 0, count: nStreams)

        // Fragment cutting: flush at the first VIDEO KEYFRAME whose SOURCE pts reaches the next map
        // boundary. boundaries[0] is segment 1's start (the first packet), so the first flush is at
        // boundaries[1]. Compared in the source video time_base — the same domain the keyframe index
        // gave us — so each produced segment matches its published EXTINF exactly.
        let boundaries = map.boundaryTicks
        var nextBoundary = 1
        var currentSeg = 1
        writer.beginFile(named: Self.segmentName(currentSeg))

        // Flush the pending fragment out of the muxer. Under delay_moov the FIRST flush emits only the
        // moov (movenc keeps the fragment's samples buffered for the next flush) — detect that via the
        // sink and force one extra flush so every boundary yields exactly one fragment, in its own file,
        // aligned with the published playlist. Adaptive: a movenc that emits moov+fragment together
        // skips the extra flush.
        func flushFragment() -> Bool {
            if av_write_frame(output, nil) < 0 { return false }
            avio_flush(output.pointee.pb)
            if writer.awaitingFirstFragment {
                if av_write_frame(output, nil) < 0 { return false }
                avio_flush(output.pointee.pb)
            }
            return true
        }

        var writeError = false
        while !isCancelled() {
            if av_read_frame(input, pkt) < 0 { break }      // EOF or read error
            let inIdx = Int(pkt.pointee.stream_index)
            if let outIdx = indexMap[inIdx],
               let inS = input.pointee.streams[inIdx],
               let outS = output.pointee.streams[outIdx] {
                let isVideo = outIdx == videoOutIdx

                // Cut BEFORE writing the keyframe that opens the next segment, so the boundary keyframe
                // becomes the first sample of the new fragment (independently decodable). Uses the
                // packet's SOURCE pts — still in the input time_base at this point.
                if isVideo, nextBoundary < boundaries.count,
                   pkt.pointee.pts != noTS, pkt.pointee.pts >= boundaries[nextBoundary],
                   (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
                    if !flushFragment() { writeError = true; av_packet_unref(pkt); break }
                    if !writer.finalizeCurrent() { writeError = true; av_packet_unref(pkt); break }
                    currentSeg += 1
                    nextBoundary += 1
                    writer.beginFile(named: Self.segmentName(currentSeg))
                }

                av_packet_rescale_ts(pkt, inS.pointee.time_base, outS.pointee.time_base)
                pkt.pointee.stream_index = Int32(outIdx)
                pkt.pointee.pos = -1

                if isVideo {
                    if vAnchor == nil { vAnchor = pkt.pointee.pts != noTS ? pkt.pointee.pts : 0 }
                    if pkt.pointee.duration > 0 {
                        vDur = pkt.pointee.duration
                    } else if vDur == 0, pkt.pointee.pts != noTS, let anchor = vAnchor, pkt.pointee.pts > anchor {
                        vDur = pkt.pointee.pts - anchor
                    }
                    var dts = vAnchor! + (vIndex - reorderSlack) * max(vDur, 1)
                    if pkt.pointee.pts != noTS, dts > pkt.pointee.pts { dts = pkt.pointee.pts }
                    if let prev = vPrevDTS, dts <= prev { dts = prev + 1 }
                    vPrevDTS = dts
                    pkt.pointee.dts = dts
                    if pkt.pointee.pts == noTS { pkt.pointee.pts = vAnchor! + vIndex * max(vDur, 1) }
                    vIndex += 1
                } else {
                    if pkt.pointee.dts == noTS {
                        pkt.pointee.dts = pkt.pointee.pts == noTS ? nextDTS[outIdx] : pkt.pointee.pts
                    }
                    if pkt.pointee.dts < nextDTS[outIdx] { pkt.pointee.dts = nextDTS[outIdx] }
                    if pkt.pointee.pts == noTS || pkt.pointee.pts < pkt.pointee.dts { pkt.pointee.pts = pkt.pointee.dts }
                    nextDTS[outIdx] = pkt.pointee.dts + max(pkt.pointee.duration, 1)
                }

                if av_write_frame(output, pkt) < 0 { writeError = true; av_packet_unref(pkt); break }
            }
            av_packet_unref(pkt)
        }

        if isCancelled() { return fail("cancelled") }
        if writeError { return fail("write_frame") }

        // Completeness gate. The VOD playlist was published up front promising `map.count` segments.
        // av_read_frame returns a negative for a mid-stream read error just as it does for a clean EOF,
        // and debrid/HTTP sources (the target) truncate; the source's real keyframes can also diverge
        // from the index. Any of these leaves us short of the map, and serving `.ready` would strand
        // AVPlayer waiting for segments that will never be written. On a full remux both counters equal
        // `map.count` (N-1 mid-loop flushes + the final one). Short ⇒ fail so the coordinator uses mpv.
        guard nextBoundary == boundaries.count, currentSeg == map.count else {
            return fail("truncated remux (\(currentSeg)/\(map.count) segments)")
        }

        // Flush the final fragment into the last segment file (the adaptive double-flush also covers a
        // single-segment file whose delayed moov is still pending here), then write the trailer into a
        // discard sink so any residual trailer bytes can't land in a segment file.
        if !flushFragment() { return fail("flush final fragment") }
        guard writer.finalizeCurrent() else { return fail("empty final segment") }
        writer.beginDiscard()
        guard av_write_trailer(output) >= 0 else { return fail("write_trailer") }
        setState(.ready)
    }

    // MARK: - Segment map / naming

    /// Build the complete VOD segment map from the video stream's keyframe index. mov's `stss` index
    /// is complete at open, but matroskadec only exposes Cues as index entries once a seek forces it to
    /// parse them — so when the index looks empty we PRIME it with a seek to the end (which loads the
    /// full Cues), then rewind to the start so the copy loop reads from the beginning. Returns nil when
    /// the index is still empty or too sparse — the caller then falls back to mpv.
    private func buildSegmentMap(input: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int) -> SegmentMap? {
        guard let vs = input.pointee.streams[videoIndex] else { return nil }

        var ticks = keyframeTicks(vs)
        if ticks.count < 2, input.pointee.duration > 0 {
            // stream_index -1 ⇒ timestamp is in AV_TIME_BASE (µs), matching input.duration.
            av_seek_frame(input, -1, input.pointee.duration, AVSEEK_FLAG_BACKWARD)
            ticks = keyframeTicks(vs)
            av_seek_frame(input, -1, 0, AVSEEK_FLAG_BACKWARD)     // rewind for the copy loop
        }

        let tb = vs.pointee.time_base
        // Prefer the video stream's own duration; fall back to the container's (µs).
        let durationSec: Double = vs.pointee.duration > 0
            ? Double(vs.pointee.duration) * Double(tb.num) / Double(tb.den)
            : (input.pointee.duration > 0 ? Double(input.pointee.duration) / 1_000_000.0 : 0)
        print("[Remux] keyframe index: \(ticks.count) keyframes tb=\(tb.num)/\(tb.den) dur=\(String(format: "%.1f", durationSec))s")
        return SegmentMap.build(keyframeTicks: ticks, timeBaseNum: tb.num, timeBaseDen: tb.den,
                                totalDurationSec: durationSec, segDurSec: config.segmentDurationSec)
    }

    /// Snapshot the video stream's current keyframe index entries as PTS in the stream time_base.
    private func keyframeTicks(_ vs: UnsafeMutablePointer<AVStream>) -> [Int64] {
        let count = avformat_index_get_entries_count(vs)
        var ticks: [Int64] = []
        ticks.reserveCapacity(Int(max(count, 0)))
        for i in 0..<count {
            guard let e = avformat_index_get_entry(vs, i) else { continue }
            let entry = e.pointee
            guard entry.timestamp != Int64.min else { continue }
            if (entry.flags & AVINDEX_KEYFRAME) != 0 { ticks.append(entry.timestamp) }
        }
        return ticks
    }

    static func segmentName(_ number: Int) -> String { String(format: "seg-%05d.m4s", number) }

    /// RFC 6381 audio token for the master CODECS list, for the audio codecs `isCopyableAudio` accepts.
    private static func audioCodecString(_ par: UnsafeMutablePointer<AVCodecParameters>) -> String? {
        switch par.pointee.codec_id {
        case AV_CODEC_ID_AAC:
            // mp4a.40.<AOT>; AAC-LC (profile FF_PROFILE_AAC_LOW == 1) → AOT 2.
            let aot = par.pointee.profile >= 0 ? Int(par.pointee.profile) + 1 : 2
            return "mp4a.40.\(aot)"
        case AV_CODEC_ID_AC3:  return "ac-3"
        case AV_CODEC_ID_EAC3: return "ec-3"
        case AV_CODEC_ID_ALAC: return "alac"
        case AV_CODEC_ID_FLAC: return "fLaC"
        case AV_CODEC_ID_MP3:  return "mp4a.40.34"
        default: return nil
        }
    }

    /// Run the video stream's first packets through FFmpeg's `extract_extradata` bitstream filter
    /// and install the recovered parameter sets on the stream's codecpar. Returns false if none were
    /// found within a bounded scan.
    private func extractVideoExtradata(input: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int) -> Bool {
        guard let stream = input.pointee.streams[videoIndex], let par = stream.pointee.codecpar,
              let filter = av_bsf_get_by_name("extract_extradata") else { return false }
        var bsfOpt: UnsafeMutablePointer<AVBSFContext>?
        guard av_bsf_alloc(filter, &bsfOpt) >= 0, let bsf = bsfOpt else { return false }
        defer { var b: UnsafeMutablePointer<AVBSFContext>? = bsf; av_bsf_free(&b) }
        guard avcodec_parameters_copy(bsf.pointee.par_in, par) >= 0 else { return false }
        bsf.pointee.time_base_in = stream.pointee.time_base
        guard av_bsf_init(bsf) >= 0 else { return false }

        guard let pkt = av_packet_alloc() else { return false }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        for _ in 0..<200 {                                   // bounded scan of the leading packets
            guard av_read_frame(input, pkt) >= 0 else { return false }
            if Int(pkt.pointee.stream_index) != videoIndex { av_packet_unref(pkt); continue }
            guard av_bsf_send_packet(bsf, pkt) >= 0 else { av_packet_unref(pkt); return false }
            while av_bsf_receive_packet(bsf, pkt) >= 0 {
                var size = 0
                if let data = av_packet_get_side_data(pkt, AV_PKT_DATA_NEW_EXTRADATA, &size), size > 0,
                   let buf = av_mallocz(size + Int(AV_INPUT_BUFFER_PADDING_SIZE)) {
                    memcpy(buf, data, size)
                    par.pointee.extradata = buf.assumingMemoryBound(to: UInt8.self)
                    par.pointee.extradata_size = Int32(size)
                    print("[Remux] recovered \(size)b of video extradata")
                    av_packet_unref(pkt)
                    return true
                }
                av_packet_unref(pkt)
            }
        }
        return false
    }

    // MARK: - Stream selection / tagging

    private func isCopyableAudio(_ id: AVCodecID) -> Bool {
        switch id {
        case AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC, AV_CODEC_ID_MP3:
            return true
        default:
            return false
        }
    }

    /// Sample-entry fourcc for the copied video. HEVC → `hvc1` (or `dvh1` for Dolby Vision Profile 5,
    /// which has no HDR10 base layer); H.264 → `avc1`; otherwise keep the muxer default.
    private func videoOutputTag(_ par: UnsafeMutablePointer<AVCodecParameters>) -> UInt32 {
        switch par.pointee.codec_id {
        case AV_CODEC_ID_HEVC:
            return dolbyProfile(par) == 5 ? fourcc("dvh1") : fourcc("hvc1")
        case AV_CODEC_ID_H264:
            return fourcc("avc1")
        default:
            return 0
        }
    }

    /// Full master-playlist signaling for the video track, per Apple's HLS authoring spec, INCLUDING
    /// `VIDEO-RANGE` — REQUIRED on tvOS 27. (An earlier finding that tvOS 27 rejects VIDEO-RANGE=PQ
    /// was drawn in the confounded EVENT-playlist era and is backwards: device A/B on the fixed VOD
    /// pipeline shows PQ media is REJECTED at media admission (-12927) when the master does NOT
    /// declare it, and ACCEPTED when declared alongside full CODECS + SUPPLEMENTAL-CODECS.)
    private static func videoSignaling(_ par: UnsafeMutablePointer<AVCodecParameters>) -> VideoSignaling {
        let range: String?
        switch par.pointee.color_trc {
        case AVCOL_TRC_SMPTE2084: range = "PQ"
        case AVCOL_TRC_ARIB_STD_B67: range = "HLG"
        default: range = nil
        }
        let dovi = doviRecord(par)

        switch par.pointee.codec_id {
        case AV_CODEC_ID_HEVC:
            if let dovi, dovi.dv_profile == 5 {
                // P5 has no cross-compatible base layer — the DV string IS the codec string.
                return VideoSignaling(codecs: String(format: "dvh1.05.%02d", dovi.dv_level),
                                      supplementalCodecs: nil, videoRange: range)
            }
            let base = hevcCodecString(par)
            if let dovi, dovi.dv_profile == 8 {
                // The compatibility brand must match the base layer or DV silently fails to engage:
                // compat 1 = HDR10/PQ base (P8.1) → db1p; 2 = SDR base (P8.2) → db2g; 4 = HLG (P8.4) → db4h.
                let brand: String
                switch Int(dovi.dv_bl_signal_compatibility_id) {
                case 2: brand = "db2g"
                case 4: brand = "db4h"
                default: brand = "db1p"
                }
                return VideoSignaling(codecs: base,
                                      supplementalCodecs: String(format: "dvh1.08.%02d/%@", dovi.dv_level, brand),
                                      videoRange: range)
            }
            return VideoSignaling(codecs: base, supplementalCodecs: nil, videoRange: range)
        case AV_CODEC_ID_H264:
            return VideoSignaling(codecs: avcCodecString(par), supplementalCodecs: nil, videoRange: range)
        default:
            return VideoSignaling(codecs: "", supplementalCodecs: nil, videoRange: nil)
        }
    }

    /// RFC 6381 HEVC token from the hvcC decoder configuration (ISO 14496-15 Annex E), e.g.
    /// `hvc1.2.4.L153.B0`. Falls back to the bare tag if the extradata isn't hvcC-shaped.
    private static func hevcCodecString(_ par: UnsafeMutablePointer<AVCodecParameters>) -> String {
        let size = Int(par.pointee.extradata_size)
        guard size >= 13, let ed = par.pointee.extradata else { return "hvc1" }
        let b = UnsafeBufferPointer(start: ed, count: size)
        guard b[0] == 1 else { return "hvc1" }                       // hvcC configurationVersion
        let profileSpace = Int((b[1] >> 6) & 0x3)
        let tier = (b[1] >> 5) & 0x1
        let profileIdc = b[1] & 0x1F
        var compat: UInt32 = 0
        for i in 2...5 { compat = (compat << 8) | UInt32(b[i]) }
        var reversed: UInt32 = 0                                     // bit-reversed per Annex E
        for i in 0..<32 where compat & (1 << UInt32(i)) != 0 { reversed |= 1 << UInt32(31 - i) }
        var s = "hvc1.\(["", "A", "B", "C"][profileSpace])\(profileIdc)"
            + ".\(String(reversed, radix: 16, uppercase: true))"
            + ".\(tier == 0 ? "L" : "H")\(b[12])"
        var constraints = Array(b[6...11])
        while constraints.count > 1, constraints.last == 0 { constraints.removeLast() }
        if !(constraints.count == 1 && constraints[0] == 0) {
            for c in constraints { s += "." + String(format: "%02X", c) }
        }
        return s
    }

    /// RFC 6381 AVC token from avcC (profile/constraints/level), e.g. `avc1.640028`.
    private static func avcCodecString(_ par: UnsafeMutablePointer<AVCodecParameters>) -> String {
        let size = Int(par.pointee.extradata_size)
        guard size >= 4, let ed = par.pointee.extradata, ed[0] == 1 else { return "avc1" }
        return String(format: "avc1.%02X%02X%02X", ed[1], ed[2], ed[3])
    }

    private static func doviRecord(_ par: UnsafeMutablePointer<AVCodecParameters>) -> AVDOVIDecoderConfigurationRecord? {
        guard let sd = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
              let data = sd.pointee.data else { return nil }
        return data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
    }

    private func dolbyProfile(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Int? {
        Self.doviRecord(par).map { Int($0.dv_profile) }
    }

    private func fourcc(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        guard b.count == 4 else { return 0 }
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    // MARK: - State plumbing

    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    private func setState(_ s: State) {
        lock.lock(); _state = s; let cb = onStateChange; lock.unlock()
        cb?(s)
    }

    private func fail(_ stage: String) {
        print("[Remux] failed at \(stage) — \(config.url.lastPathComponent)")
        setState(.failed(stage))
    }

    private static func makeSessionDir() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nuvio-remux", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

// MARK: - Segment-splitting AVIO sink

/// Custom AVIO sink for the owned segmenter: routes movenc's APPEND-ONLY byte stream (the AVIO context
/// has no seek callback, so movenc takes its streaming paths, exactly as when writing to a pipe) into
/// discrete files. The stream is a sequence of top-level MP4 boxes: `ftyp` + `moov` (the init segment —
/// with `delay_moov` the moov arrives at the FIRST fragment flush, not at write_header, because EAC3's
/// dec3 sample entry needs a parsed frame) followed by `moof`+`mdat` pairs (the fragments). The sink
/// parses top-level box headers until the `moov` completes — everything up to its end is written
/// atomically as `init.mp4` — then switches to raw routing into the current segment window, which
/// `runRemux` rotates at its own fragment-flush boundaries (flushes are box-aligned by construction).
/// Every file is written atomically (`.part` → rename) so the loopback server keys "complete" on the
/// final name and never serves a torn file.
///
/// All methods run synchronously on the remux worker thread (the muxer calls the AVIO callback inline
/// during write_header / av_write_frame on that same thread), so no locking is needed.
private nonisolated final class SegmentWriter {
    private let outputDir: URL
    private var initData = Data()          // accumulates ftyp…moov until the moov box completes
    private var initDone = false
    private var segData = Data()
    private var segName: String?
    private var discarding = false

    init(outputDir: URL) { self.outputDir = outputDir }

    /// Whether init.mp4 has been written (the moov box has been seen and routed).
    var initFinalized: Bool { initDone }

    /// True when the init segment is complete but no fragment bytes have arrived in the current
    /// window. Detects delay_moov's moov-only first flush (movenc keeps the first fragment's samples
    /// buffered and emits them on the NEXT flush) so the caller can force an extra flush.
    var awaitingFirstFragment: Bool { initDone && segData.isEmpty }

    /// Start accumulating the next segment file. Any current segment buffer is dropped.
    func beginFile(named name: String) {
        segData.removeAll(keepingCapacity: true)
        segName = name
        discarding = false
    }

    /// Route subsequent non-init bytes nowhere (used for the trailer, so any residual bytes movenc
    /// emits after the last fragment can't land in a segment file).
    func beginDiscard() {
        segData.removeAll(keepingCapacity: false)
        segName = nil
        discarding = true
    }

    /// Flush the buffered segment to disk atomically (`.part` then rename within the same directory).
    /// Returns false when the window is EMPTY — a broken invariant (the published playlist promises
    /// media in every segment), so the caller must fail the session rather than ship a 0-byte file.
    @discardableResult
    func finalizeCurrent() -> Bool {
        guard !discarding, let segName else { return true }
        self.segName = nil
        guard !segData.isEmpty else {
            print("[Remux] segment \(segName) finalized EMPTY — muxer emitted no fragment bytes")
            return false
        }
        writeAtomic(segData, name: segName)
        segData.removeAll(keepingCapacity: true)
        return true
    }

    // MARK: AVIO write callback
    func write(_ buf: UnsafePointer<UInt8>?, count size: Int32) -> Int32 {
        let n = Int(size)
        guard n > 0, let buf else { return size }
        if initDone {
            if !discarding, segName != nil { segData.append(buf, count: n) }
            return size
        }
        initData.append(buf, count: n)
        routeInitIfComplete()
        return size
    }

    /// Scan complete top-level boxes in the init accumulator. Once the `moov` box is complete,
    /// [start, end-of-moov] is the init segment; any residue already received belongs to the first
    /// fragment and moves to the segment buffer.
    private func routeInitIfComplete() {
        var off = 0
        while initData.count - off >= 8 {
            let size = Int(initData[off]) << 24 | Int(initData[off + 1]) << 16
                     | Int(initData[off + 2]) << 8 | Int(initData[off + 3])
            guard size >= 8 else {
                // 64-bit/degenerate box sizes don't occur before moov — bail; init never finalizes,
                // the coordinator's start gate times out, and the session falls back to mpv.
                print("[Remux] unexpected box size \(size) before moov — init routing aborted")
                return
            }
            if initData.count - off < size { return }      // box incomplete — wait for more bytes
            let isMoov = initData[off + 4] == 0x6D && initData[off + 5] == 0x6F
                      && initData[off + 6] == 0x6F && initData[off + 7] == 0x76
            if isMoov {
                let end = off + size
                writeAtomic(initData.subdata(in: 0..<end), name: "init.mp4")
                initDone = true
                if end < initData.count, !discarding, segName != nil {
                    segData.append(initData.subdata(in: end..<initData.count))
                }
                initData.removeAll(keepingCapacity: false)
                return
            }
            off += size
        }
    }

    private func writeAtomic(_ data: Data, name: String) {
        let finalURL = outputDir.appendingPathComponent(name)
        let partURL = finalURL.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partURL)
        do {
            try data.write(to: partURL, options: .atomic)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: partURL, to: finalURL)
        } catch {
            print("[Remux] segment write failed: \(name) — \(error.localizedDescription)")
        }
    }
}

private nonisolated func segmentWriterWrite(_ opaque: UnsafeMutableRawPointer?,
                                            _ buf: UnsafePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<SegmentWriter>.fromOpaque(opaque).takeUnretainedValue().write(buf, count: size)
}
