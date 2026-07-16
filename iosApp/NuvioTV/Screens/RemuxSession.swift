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
    private var onStateChange: (@Sendable (State) -> Void)?
    private let queue = DispatchQueue(label: "media.nuvio.remux", qos: .userInitiated)

    var state: State { lock.lock(); defer { lock.unlock() }; return _state }

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

        // --- Open + inspect the source ------------------------------------------------------------
        var inCtx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&inCtx, config.url.absoluteString, nil, nil) == 0, let input = inCtx else {
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
                if av_interleaved_write_frame(output, pkt) < 0 { writeError = true; av_packet_unref(pkt); break }
            }
            av_packet_unref(pkt)
        }

        if isCancelled() { return fail("cancelled") }
        if writeError { return fail("write_frame") }
        guard av_write_trailer(output) >= 0 else { return fail("write_trailer") }

        // This FFmpeg build's dash muxer can emit an empty video token in the master playlist's
        // CODECS attribute (its detailed HEVC codec-string parse doesn't fire on 8.1.2), which
        // breaks AVPlayer variant selection. Rewrite CODECS from what we actually copied. This is
        // also where DV `CODECS`/`SUPPLEMENTAL-CODECS` signaling will be filled in (Phase 3/5).
        fixupMasterPlaylistCodecs(videoToken: videoCodecToken(videoPar))
        setState(.ready)
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

    /// RFC 6381-ish sample-entry token for the master playlist's CODECS attribute. Short forms
    /// (`hvc1`/`dvh1`/`avc1`) are what Infuse-style output uses and AVPlayer accepts; Phase 3/5 will
    /// extend this to the detailed DV strings + a SUPPLEMENTAL-CODECS attribute for Profile 8.1.
    private func videoCodecToken(_ par: UnsafeMutablePointer<AVCodecParameters>) -> String {
        switch par.pointee.codec_id {
        case AV_CODEC_ID_HEVC: return dolbyProfile(par) == 5 ? "dvh1" : "hvc1"
        case AV_CODEC_ID_H264: return "avc1"
        default: return ""
        }
    }

    /// Rewrite the first (video) token of every `CODECS="…"` in the master playlist to `videoToken`,
    /// working around the muxer emitting an empty/wrong video token on this FFmpeg build.
    private func fixupMasterPlaylistCodecs(videoToken: String) {
        guard !videoToken.isEmpty else { return }
        let master = outputDir.appendingPathComponent(masterPlaylistName)
        guard let text = try? String(contentsOf: master, encoding: .utf8) else { return }
        let rewritten = text.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("#EXT-X-STREAM-INF:"),
                  let open = line.range(of: "CODECS=\""),
                  let close = line[open.upperBound...].firstIndex(of: "\"") else { return line }
            var tokens = line[open.upperBound..<close].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if tokens.isEmpty { tokens = [videoToken] } else { tokens[0] = videoToken }
            return line.replacingCharacters(in: open.upperBound..<close, with: tokens.joined(separator: ","))
        }.joined(separator: "\n")
        try? rewritten.write(to: master, atomically: true, encoding: .utf8)
    }

    private func dolbyProfile(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Int? {
        guard let sd = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
              let data = sd.pointee.data else { return nil }
        return Int(data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee.dv_profile })
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
