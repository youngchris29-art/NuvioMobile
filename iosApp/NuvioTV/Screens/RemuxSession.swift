import Foundation
import Libavformat
import Libavcodec
import Libavutil

// Phase 2 of the hybrid player: on-device MKV→fMP4 remux. Stream-copies (no re-encode) the compatible
// video and audio tracks of a source into fragmented-MP4 HLS segments via FFmpeg's `dash` muxer,
// preserving Dolby Vision (RPU NALs ride along in the copied bitstream; the `dvvC` box is written from
// the DOVI side data). Runs on a background worker; the emitted directory — init segments, media
// segments, and HLS playlists — is served to AVPlayer by `LocalHLSServer`.
//
// The muxer options here mirror a recipe validated with the FFmpeg CLI + ffprobe (see
// docs/tvos-hybrid-player-plan.md): `-c copy -tag:v hvc1 -f dash -seg_duration N -use_template 1
// -use_timeline 0 -hls_playlist 1`, which yields a VOD `master.m3u8` (video variant + audio rendition)
// with `EXT-X-MAP` init segments and `EXT-X-ENDLIST`.
//
// This phase muxes linearly (the whole file, start to finish). Because the dash muxer only lists a
// segment in the playlist *after* it has fully written it, a client that fetches from the current
// playlist never sees a half-written segment. Just-in-time seek-anywhere generation is a later
// refinement layered on the same directory/server machinery.

/// HLS master-playlist signaling for the remuxed video, per Apple's HLS authoring spec: a full
/// RFC 6381 CODECS token (bare "hvc1" is non-compliant and stricter tvOS builds reject it), plus
/// Dolby Vision SUPPLEMENTAL-CODECS and VIDEO-RANGE for HDR — required for true DV to engage.
nonisolated struct VideoSignaling: Sendable {
    var codecs: String                 // e.g. "hvc1.2.4.L153.B0" or "dvh1.05.06"
    var supplementalCodecs: String?    // e.g. "dvh1.08.06/db4h" (DV P8 over HDR10)
    var videoRange: String?            // "PQ" / "HLG"
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
    /// HLS master playlist filename within `outputDir` (what AVPlayer loads).
    let masterPlaylistName = "master.m3u8"

    private let lock = NSLock()
    private var _state: State = .idle
    private var _cancelled = false
    private var _signaling: VideoSignaling?
    private var onStateChange: (@Sendable (State) -> Void)?
    private let queue = DispatchQueue(label: "media.nuvio.remux", qos: .userInitiated)

    var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    /// Master-playlist signaling for the copied video, set once the video stream is inspected.
    /// `LocalHLSServer` uses it to repair the master playlist (this FFmpeg 8.1.2 dash muxer emits an
    /// empty CODECS video token, no VIDEO-RANGE, and no DV signaling).
    var videoSignaling: VideoSignaling? { lock.lock(); defer { lock.unlock() }; return _signaling }

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

        let signaling = Self.videoSignaling(videoPar)
        lock.lock(); _signaling = signaling; lock.unlock()
        print("[Remux] signaling CODECS=\(signaling.codecs)"
              + (signaling.supplementalCodecs.map { " SUPPLEMENTAL=\($0)" } ?? "")
              + (signaling.videoRange.map { " RANGE=\($0)" } ?? ""))

        // --- Allocate the dash output -------------------------------------------------------------
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let manifestPath = outputDir.appendingPathComponent("manifest.mpd").path

        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outCtx, nil, "dash", manifestPath) >= 0, let output = outCtx else {
            return fail("alloc_output_context2")
        }
        defer { avformat_free_context(output) }
        output.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL   // allow the DV (dvvC) box

        var indexMap = [Int: Int]()
        func addStream(_ inIdx: Int, tag: UInt32) -> Bool {
            guard let inS = input.pointee.streams[inIdx], let inPar = inS.pointee.codecpar,
                  let outS = avformat_new_stream(output, nil), let outPar = outS.pointee.codecpar,
                  avcodec_parameters_copy(outPar, inPar) >= 0 else { return false }
            outPar.pointee.codec_tag = tag
            outS.pointee.time_base = inS.pointee.time_base
            indexMap[inIdx] = Int(outS.pointee.index)
            return true
        }
        guard addStream(videoIn, tag: videoOutputTag(videoPar)) else { return fail("add video stream") }
        if audioIn >= 0 { _ = addStream(audioIn, tag: 0) }   // keep the muxer's default audio tag (mp4a)

        // Stream fingerprint for device debugging: extradata_size==0 on video means the init segment
        // will lack a valid hvcC/avcC decoder config and AVPlayer rejects the stream (-12927).
        for (inIdx, outIdx) in indexMap.sorted(by: { $0.value < $1.value }) {
            if let par = input.pointee.streams[inIdx]?.pointee.codecpar?.pointee {
                let codec = avcodec_get_name(par.codec_id).map { String(cString: $0) } ?? "?"
                print("[Remux] out#\(outIdx) \(codec) \(par.width)x\(par.height) extradata=\(par.extradata_size)b bitrate=\(par.bit_rate)")
            }
        }

        // dash muxer options — the validated recipe.
        var opts: OpaquePointer?
        av_dict_set(&opts, "seg_duration", String(config.segmentDurationSec), 0)
        av_dict_set(&opts, "use_template", "1", 0)
        av_dict_set(&opts, "use_timeline", "0", 0)
        av_dict_set(&opts, "hls_playlist", "1", 0)
        av_dict_set(&opts, "dash_segment_type", "mp4", 0)
        av_dict_set(&opts, "init_seg_name", "init-$RepresentationID$.mp4", 0)
        av_dict_set(&opts, "media_seg_name", "seg-$RepresentationID$-$Number%05d$.m4s", 0)
        defer { av_dict_free(&opts) }

        // dash is AVFMT_NOFILE — it opens/manages its own segment + playlist files.
        guard avformat_write_header(output, &opts) >= 0 else { return fail("write_header") }

        // --- Stream-copy loop ---------------------------------------------------------------------
        guard let pkt = av_packet_alloc() else { return fail("packet_alloc") }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        // Timestamp hygiene. Sloppy real-world muxes carry missing or NON-MONOTONIC video DTS (seen
        // in the wild: dts zig-zagging backwards while pts is clean); the mp4 muxer writes them
        // through and AVPlayer rejects the resulting timeline (-12927). Video DTS is therefore
        // REGENERATED wholesale on a uniform grid anchored at the first PTS and offset back a few
        // frames for B-frame reorder (validated against AVPlayer on the pulled device output).
        // Audio keeps source timestamps, with gap-filling only if a packet arrives without them.
        let noTS = Int64.min                                     // AV_NOPTS_VALUE
        let reorderSlack: Int64 = 6                              // frames of pts>=dts headroom
        let videoOutIdx = indexMap[videoIn] ?? 0
        var vIndex: Int64 = 0
        var vAnchor: Int64? = nil
        var vDur: Int64 = 0
        var vPrevDTS: Int64? = nil
        let nStreams = Int(output.pointee.nb_streams)
        var nextDTS = [Int64](repeating: 0, count: nStreams)

        var writeError = false
        while !isCancelled() {
            if av_read_frame(input, pkt) < 0 { break }      // EOF or read error
            let inIdx = Int(pkt.pointee.stream_index)
            if let outIdx = indexMap[inIdx],
               let inS = input.pointee.streams[inIdx],
               let outS = output.pointee.streams[outIdx] {
                av_packet_rescale_ts(pkt, inS.pointee.time_base, outS.pointee.time_base)
                pkt.pointee.stream_index = Int32(outIdx)
                pkt.pointee.pos = -1

                if outIdx == videoOutIdx {
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

                if av_interleaved_write_frame(output, pkt) < 0 { writeError = true; av_packet_unref(pkt); break }
            }
            av_packet_unref(pkt)
        }

        if isCancelled() { return fail("cancelled") }
        if writeError { return fail("write_frame") }
        guard av_write_trailer(output) >= 0 else { return fail("write_trailer") }
        setState(.ready)
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

    /// Full master-playlist signaling for the video track, per Apple's HLS authoring spec.
    private static func videoSignaling(_ par: UnsafeMutablePointer<AVCodecParameters>) -> VideoSignaling {
        let trc = par.pointee.color_trc
        let range: String? = trc == AVCOL_TRC_SMPTE2084 ? "PQ" : (trc == AVCOL_TRC_ARIB_STD_B67 ? "HLG" : nil)
        let dovi = doviRecord(par)

        switch par.pointee.codec_id {
        case AV_CODEC_ID_HEVC:
            if let dovi, dovi.dv_profile == 5 {
                // P5 has no cross-compatible base layer — the DV string IS the codec string.
                return VideoSignaling(codecs: String(format: "dvh1.05.%02d", dovi.dv_level),
                                      supplementalCodecs: nil, videoRange: "PQ")
            }
            let base = hevcCodecString(par)
            if let dovi, dovi.dv_profile == 8 {
                return VideoSignaling(codecs: base,
                                      supplementalCodecs: String(format: "dvh1.08.%02d/db4h", dovi.dv_level),
                                      videoRange: "PQ")
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
