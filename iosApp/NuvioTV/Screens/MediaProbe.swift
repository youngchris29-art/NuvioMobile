import Foundation
import Libavformat
import Libavcodec
import Libavutil

// Phase 1 of the hybrid player: a thin, synchronous FFmpeg (avformat) probe that inspects a stream
// URL *before* playback and reports the facts the router needs to choose an engine — container,
// video codec, Dolby Vision configuration, HDR transfer, audio/subtitle tracks, duration, and
// whether the source is seekable. See docs/tvos-hybrid-player-plan.md.
//
// The FFmpeg C types stay inside this file: `probe(...)` returns a pure-Swift `ProbeResult`, so the
// router (and its tests) never touch libav* headers. The keyframe/Cues index that Phase 2's remux
// needs is intentionally NOT collected here yet.

/// HDR transfer characteristic inferred from the video stream's color transfer function.
nonisolated enum HDRFormat: String, Sendable {
    case sdr, hdr10, hlg, other
}

/// The three colour code points FFmpeg keeps on `AVCodecParameters` (ITU-T H.273: colour
/// primaries, transfer characteristics, matrix coefficients), as plain integers so the router, the
/// remux and the tests share one value without libav* types. 2 is "unspecified" in every family;
/// 0 and 3 are reserved and count as unset too.
nonisolated struct ColourTags: Equatable, Sendable {
    var primaries: Int = ColourTags.unspecifiedCode
    var transfer: Int = ColourTags.unspecifiedCode
    var matrix: Int = ColourTags.unspecifiedCode

    static let unspecifiedCode = 2
    static let unspecified = ColourTags()

    // Transfer characteristics (H.273 table 3) the player cares about.
    static let transferBT709 = 1
    static let transferBT2020_10 = 14
    static let transferBT2020_12 = 15
    static let transferPQ = 16
    static let transferHLG = 18
    // Primaries / matrix (tables 2 and 4) for the BT.2020 container the HDR fixtures carry.
    static let primariesBT2020 = 9
    static let matrixBT2020NCL = 9

    static func isSet(_ code: Int) -> Bool { code != 0 && code != 2 && code != 3 }

    var isEmpty: Bool { !Self.isSet(primaries) && !Self.isSet(transfer) && !Self.isSet(matrix) }

    /// Field-by-field merge: keep this value's set fields, fill the rest from `fallback`.
    func merged(over fallback: ColourTags) -> ColourTags {
        ColourTags(primaries: Self.isSet(primaries) ? primaries : fallback.primaries,
                   transfer: Self.isSet(transfer) ? transfer : fallback.transfer,
                   matrix: Self.isSet(matrix) ? matrix : fallback.matrix)
    }
}

/// Which layer supplied the transfer characteristic the probe acted on (logged, shown in evidence).
nonisolated enum ColourSource: String, Sendable {
    case container       // the Matroska Colour element / MP4 `colr` box, read before FFmpeg's stream inspection
    case sps             // the HEVC SPS VUI, read from the stream's extradata by a scratch decoder
    case decoder         // whatever `avformat_find_stream_info` left on codecpar (in-band SPS, other codecs)
    case dolbyVision     // implied by the Dolby Vision configuration record (P5/P7 → PQ, P8 by compat id)
    case staticMetadata  // implied by HDR10 static metadata (mastering display / content light level)
    case none
}

/// The colour verdict for one video stream.
nonisolated struct ResolvedColour: Equatable, Sendable {
    /// Explicit tags, merged per field: container → SPS → FFmpeg's inspected codecpar. These are the
    /// values the remux writes into the output `colr` box.
    var tags: ColourTags
    /// Effective transfer: `tags.transfer` when set, else what the Dolby Vision record or HDR10 static
    /// metadata imply (those two never go into `tags`: they are not container/bitstream colour tags).
    var transfer: Int
    var transferSource: ColourSource

    var hdr: HDRFormat { MediaProbe.hdrFormat(transfer: transfer) }
}

/// Dolby Vision configuration record (from the HEVC `dvvC`/`dvcC` box), when present.
nonisolated struct DolbyVisionInfo: Equatable, Sendable {
    var profile: Int          // 5, 7, 8, ...
    var level: Int
    var blPresent: Bool       // base layer
    var elPresent: Bool       // enhancement layer (dual-layer P7)
    var rpuPresent: Bool      // reference processing unit (dynamic metadata)
    var compatId: Int         // dv_bl_signal_compatibility_id (1 = HDR10-compatible P8.1, etc.)
    /// Profile 7 only: MEL/FEL flavor classified by parsing the first RPU out of the initial video
    /// packets (Phase 5 — decides native-vs-mpv routing and what the 8.1 conversion costs). nil for
    /// other profiles (no scan performed).
    var elKind: DVELKind? = nil
}

nonisolated struct AudioStreamInfo: Sendable {
    var index: Int
    var codec: String         // canonical FFmpeg name: "aac", "ac3", "eac3", "truehd", "dts", ...
    var channels: Int
    var language: String?
}

nonisolated struct SubtitleStreamInfo: Sendable {
    var index: Int
    var codec: String         // "subrip", "ass", "hdmv_pgs_subtitle", "dvd_subtitle", ...
    var isBitmap: Bool         // PGS/VobSub/DVB → must burn-in or route to mpv
    var language: String?
}

/// Everything the router needs, as plain Swift values (no libav* types leak out).
nonisolated struct ProbeResult: Sendable {
    var container: String          // avformat demuxer name, e.g. "matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2"
    var videoCodec: String         // "hevc", "h264", "av1", "vp9", ... ("" if no video)
    var videoProfile: Int32        // raw AVCodecParameters.profile (FF_PROFILE_*), -99 if unknown
    var hdr: HDRFormat
    var dolbyVision: DolbyVisionInfo?
    var audio: [AudioStreamInfo]
    var subtitles: [SubtitleStreamInfo]
    var durationSec: Double
    var seekable: Bool
    /// Real video tracks in the container (attached-picture/cover-art streams excluded). A Profile 7
    /// source with a SECOND video stream is the two-track BL+EL layout — the RPUs live in the EL
    /// track, which the remux never reads, so those files stay on mpv.
    var videoStreamCount: Int = 0
    /// Where `hdr` came from (see `ColourSource`). `.none` for SDR and for files with no video.
    var hdrSource: ColourSource = .none
}

nonisolated enum MediaProbe {
    /// Serialize request headers into FFmpeg's `headers` AVOption form for the http protocol:
    /// CRLF-terminated `Key: Value` lines. Sorted for determinism. Shared with `RemuxSession`
    /// (both open the remote source through avformat and need the same addon headers).
    static func ffmpegHeaderBlock(_ headers: [String: String]) -> String {
        headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)\r\n" }
            .joined()
    }

    /// Open `url` with avformat and return a `ProbeResult`, or nil on failure/timeout. Blocking
    /// (network I/O) — call off the main thread. A deadline-based interrupt callback guarantees the
    /// call cannot hang past `timeoutSec`.
    static func probe(url: URL, timeoutSec: Double, requestHeaders: [String: String] = [:]) -> ProbeResult? {
        MediaProbeNetwork.ensureInit()

        guard let ctx = avformat_alloc_context() else { return nil }

        // Deadline interrupt: FFmpeg polls this during blocking I/O; returning 1 aborts the operation.
        let deadline = ProbeDeadline(timeoutSec: timeoutSec)
        let opaque = Unmanaged.passRetained(deadline).toOpaque()
        defer { Unmanaged<ProbeDeadline>.fromOpaque(opaque).release() }
        ctx.pointee.interrupt_callback = AVIOInterruptCB(callback: mediaProbeShouldInterrupt, opaque: opaque)

        // Protocol-level open/read timeout (microseconds) for demuxers/protocols that honor it.
        var opts: OpaquePointer?
        av_dict_set(&opts, "timeout", String(Int(timeoutSec * 1_000_000)), 0)
        // Addon-declared stream headers (behaviorHints.proxyHeaders.request, pre-sanitized): a
        // header-gated CDN 403s a bare probe, which would silently route the stream to mpv even
        // when the native path could play it. Ignored by non-HTTP protocols.
        if !requestHeaders.isEmpty {
            av_dict_set(&opts, "headers", ffmpegHeaderBlock(requestHeaders), 0)
        }
        defer { av_dict_free(&opts) }

        var fmt: UnsafeMutablePointer<AVFormatContext>? = ctx
        // On failure avformat_open_input frees and nils the context it was given — no manual free.
        // A file URL goes in as a path: FFmpeg's file protocol does not percent-decode.
        let source = url.isFileURL ? url.path : url.absoluteString
        guard avformat_open_input(&fmt, source, nil, &opts) == 0, let fmt else { return nil }
        defer { var f: UnsafeMutablePointer<AVFormatContext>? = fmt; avformat_close_input(&f) }

        // Container-level colour tags, read BEFORE find_stream_info: that call decodes a few frames
        // and then puts the container's primaries/transfer/matrix back as a block whenever any one of
        // them is set (FFmpeg 8.1.2 `libavformat/demux.c`, `parameters_from_context`), so a Colour
        // element carrying only MatrixCoefficients wipes the PQ the decoder read from the SPS. The
        // snapshot keeps the container's own word separate from what inspection leaves behind.
        let containerColour = containerColourTags(fmt)

        guard avformat_find_stream_info(fmt, nil) >= 0 else { return nil }

        var result = ProbeResult(
            container: fmt.pointee.iformat.flatMap { $0.pointee.name }.map { String(cString: $0) } ?? "",
            videoCodec: "",
            videoProfile: -99,
            hdr: .sdr,
            dolbyVision: nil,
            audio: [],
            subtitles: [],
            durationSec: fmt.pointee.duration > 0 ? Double(fmt.pointee.duration) / 1_000_000.0 : 0,
            seekable: fmt.pointee.pb.map { ($0.pointee.seekable & AVIO_SEEKABLE_NORMAL) != 0 } ?? false
        )

        var videoStreamIndex = -1
        for i in 0..<Int(fmt.pointee.nb_streams) {
            guard let stream = fmt.pointee.streams[i], let parPtr = stream.pointee.codecpar else { continue }
            let par = parPtr.pointee
            let lang = dictValue(stream.pointee.metadata, "language")

            switch par.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                // Attached pictures (cover art muxed as an mjpeg/png "video" track) aren't playback
                // streams — skip them entirely so they can't skew the two-track P7 detection.
                let attachedPic: Int32 = 1 << 10                 // AV_DISPOSITION_ATTACHED_PIC
                guard stream.pointee.disposition & attachedPic == 0 else { break }
                result.videoStreamCount += 1
                guard result.videoCodec.isEmpty else { break }   // first video stream only
                videoStreamIndex = i
                result.videoCodec = codecName(par.codec_id)
                result.videoProfile = par.profile
                result.dolbyVision = dolbyVision(parPtr)
                let colour = resolveColour(parPtr, container: containerColour[i] ?? .unspecified)
                result.hdr = colour.hdr
                result.hdrSource = colour.hdr == .sdr ? .none : colour.transferSource
            case AVMEDIA_TYPE_AUDIO:
                result.audio.append(AudioStreamInfo(
                    index: i,
                    codec: codecName(par.codec_id),
                    channels: Int(par.ch_layout.nb_channels),
                    language: lang
                ))
            case AVMEDIA_TYPE_SUBTITLE:
                let props = avcodec_descriptor_get(par.codec_id)?.pointee.props ?? 0
                result.subtitles.append(SubtitleStreamInfo(
                    index: i,
                    codec: codecName(par.codec_id),
                    isBitmap: (props & AV_CODEC_PROP_BITMAP_SUB) != 0,
                    language: lang
                ))
            default:
                break
            }
        }

        // Profile 7 needs one more fact the container can't provide: the MEL/FEL flavor, read from
        // the first RPU NAL in the bitstream (Phase 5 routing + the FEL fidelity sub-setting). The
        // scan is bounded (packet counts + the same deadline interrupt) and only runs for P7 files;
        // find_stream_info has already buffered the initial packets, so it rarely touches the network.
        if let dv = result.dolbyVision, dv.profile == 7, videoStreamIndex >= 0 {
            result.dolbyVision?.elKind = scanP7ELKind(fmt, videoStreamIndex: videoStreamIndex, deadline: deadline)
        }
        return result
    }

    /// Read initial packets and classify the first RPU found on the video stream. `.missing` when the
    /// scan exhausts its budget without seeing one (two-track P7 keeps its RPUs in the EL track),
    /// `.unsupported` when the walker can't run (extradata not hvcC) or libdovi can't parse it.
    private static func scanP7ELKind(_ fmt: UnsafeMutablePointer<AVFormatContext>,
                                     videoStreamIndex: Int, deadline: ProbeDeadline) -> DVELKind {
        guard let par = fmt.pointee.streams[videoStreamIndex]?.pointee.codecpar,
              let nalLengthSize = DoviRpuConverter.hvccNalLengthSize(par),
              let pkt = av_packet_alloc() else { return .unsupported }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        var reads = 0, videoPackets = 0
        while reads < 400, videoPackets < 120, !deadline.expired, av_read_frame(fmt, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            reads += 1
            guard Int(pkt.pointee.stream_index) == videoStreamIndex, let data = pkt.pointee.data else { continue }
            videoPackets += 1
            if let kind = DoviRpuConverter.classifyFirstRpu(packetData: data,
                                                            size: Int(pkt.pointee.size),
                                                            nalLengthSize: nalLengthSize) {
                return kind
            }
        }
        // Review r1 P3-2 (W3-19): a deadline cut here still returns a probe (`.missing`, which routes
        // a P7 file to mpv), so `PlayerScreen`'s nil-probe cap line never sees it. Log it here, in
        // the same `[PlayerRouter]` voice. `ProbeResult` carries no field for it.
        if deadline.expired {
            print("[PlayerRouter] probe cap hit in the P7 RPU scan after \(reads) reads (\(videoPackets) video packets) → elKind missing → mpv")
        }
        return .missing
    }

    // MARK: - Extraction helpers

    private static func codecName(_ id: AVCodecID) -> String {
        guard let cName = avcodec_get_name(id) else { return "" }
        return String(cString: cName)
    }

    static func hdrFormat(_ trc: AVColorTransferCharacteristic) -> HDRFormat {
        hdrFormat(transfer: Int(trc.rawValue))
    }

    /// H.273 transfer code → the player's HDR family.
    static func hdrFormat(transfer: Int) -> HDRFormat {
        switch transfer {
        case ColourTags.transferPQ: return .hdr10
        case ColourTags.transferHLG: return .hlg
        case ColourTags.transferBT2020_10, ColourTags.transferBT2020_12: return .other
        default: return .sdr
        }
    }

    // MARK: - Colour resolution (container / SPS / inspected codecpar / DV / static metadata)

    /// Pure precedence rule shared by the probe and the remux. Explicit tags merge per field. When the
    /// container declared any colour, it goes first (what the muxer declared is what a `colr` box would
    /// carry, and ExoPlayer and QuickTime both let it win), then the SPS VUI, then whatever FFmpeg's
    /// inspection left. When the container declared nothing, inspection was never clobbered and is the
    /// richer source (it applies the alternative-transfer SEI: an HLG stream whose VUI says 14 reaches
    /// codecpar as 18), so it goes before the raw SPS.
    ///
    /// The transfer the player acts on then follows the Dolby Vision record whenever the tags do not
    /// already say PQ or HLG: P5 and P7 are PQ by definition, P8 follows its base-layer compatibility
    /// id (1 = HDR10/PQ, 4 = HLG). This is the pre-existing remux rule (P5 spike, 2026-10-20) and it
    /// outranks a stray BT.709 container tag, which old movenc and some MKV tools write by default.
    /// With no record, an unset transfer is implied PQ by HDR10 mastering-display metadata. Neither
    /// implication enters `tags`: they are not colour tags and never go into a `colr` box.
    static func resolveColour(container: ColourTags, sps: ColourTags?, inspected: ColourTags,
                              dolbyVision: DolbyVisionInfo?, hasHDR10StaticMetadata: Bool) -> ResolvedColour {
        let tags: ColourTags
        let transferSource: ColourSource
        if container.isEmpty {
            tags = inspected.merged(over: sps ?? .unspecified)
            if ColourTags.isSet(inspected.transfer) { transferSource = .decoder }
            else if let sps, ColourTags.isSet(sps.transfer) { transferSource = .sps }
            else { transferSource = .none }
        } else {
            tags = container.merged(over: (sps ?? .unspecified).merged(over: inspected))
            if ColourTags.isSet(container.transfer) { transferSource = .container }
            else if let sps, ColourTags.isSet(sps.transfer) { transferSource = .sps }
            else if ColourTags.isSet(inspected.transfer) { transferSource = .decoder }
            else { transferSource = .none }
        }

        let tagsSayHDR = tags.transfer == ColourTags.transferPQ || tags.transfer == ColourTags.transferHLG
        if !tagsSayHDR, let dv = dolbyVision {
            switch (dv.profile, dv.compatId) {
            case (5, _), (7, _), (8, 1):
                return ResolvedColour(tags: tags, transfer: ColourTags.transferPQ, transferSource: .dolbyVision)
            case (8, 4):
                return ResolvedColour(tags: tags, transfer: ColourTags.transferHLG, transferSource: .dolbyVision)
            default: break
            }
        }
        if !ColourTags.isSet(tags.transfer), hasHDR10StaticMetadata {
            return ResolvedColour(tags: tags, transfer: ColourTags.transferPQ, transferSource: .staticMetadata)
        }
        return ResolvedColour(tags: tags, transfer: tags.transfer, transferSource: transferSource)
    }

    /// `resolveColour` over a real stream: the SPS, inspected tags, DOVI record and static metadata
    /// come from `par`; `container` is the snapshot `containerColourTags` took before inspection.
    static func resolveColour(_ par: UnsafeMutablePointer<AVCodecParameters>, container: ColourTags) -> ResolvedColour {
        resolveColour(container: container,
                      sps: spsColourTags(par),
                      inspected: colourTags(par),
                      dolbyVision: dolbyVision(par),
                      hasHDR10StaticMetadata: hasHDR10StaticMetadata(par))
    }

    /// The three colour fields of `par` as H.273 codes.
    static func colourTags(_ par: UnsafeMutablePointer<AVCodecParameters>) -> ColourTags {
        ColourTags(primaries: Int(par.pointee.color_primaries.rawValue),
                   transfer: Int(par.pointee.color_trc.rawValue),
                   matrix: Int(par.pointee.color_space.rawValue))
    }

    /// Write `tags` onto `par` (the remux does this so movenc's `colr` box carries the resolved values).
    static func applyColourTags(_ tags: ColourTags, to par: UnsafeMutablePointer<AVCodecParameters>) {
        par.pointee.color_primaries = AVColorPrimaries(rawValue: UInt32(clamping: tags.primaries))
        par.pointee.color_trc = AVColorTransferCharacteristic(rawValue: UInt32(clamping: tags.transfer))
        par.pointee.color_space = AVColorSpace(rawValue: UInt32(clamping: tags.matrix))
    }

    /// Per-stream colour tags as the demuxer set them from the container header. Only meaningful
    /// between `avformat_open_input` and `avformat_find_stream_info` (see `probe`). Streams the
    /// inspection discovers later are simply absent.
    static func containerColourTags(_ fmt: UnsafeMutablePointer<AVFormatContext>) -> [Int: ColourTags] {
        var tags: [Int: ColourTags] = [:]
        for i in 0..<Int(fmt.pointee.nb_streams) {
            guard let stream = fmt.pointee.streams[i], let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            tags[i] = colourTags(par)
        }
        return tags
    }

    /// Colour description of the HEVC SPS VUI, parsed out of the stream's extradata (hvcC or Annex B)
    /// by a scratch decoder context that starts with every colour field unspecified: the decoder's
    /// init exports the first SPS's VUI onto the context (`export_stream_params`), with nothing from
    /// the container to shadow it. nil for other codecs or when the extradata holds no SPS; all fields
    /// unspecified when the SPS has no colour description.
    static func spsColourTags(_ par: UnsafeMutablePointer<AVCodecParameters>) -> ColourTags? {
        guard par.pointee.codec_id == AV_CODEC_ID_HEVC,
              par.pointee.extradata_size > 0, par.pointee.extradata != nil,
              let codec = avcodec_find_decoder(AV_CODEC_ID_HEVC),
              let ctx = avcodec_alloc_context3(codec) else { return nil }
        defer { var c: UnsafeMutablePointer<AVCodecContext>? = ctx; avcodec_free_context(&c) }
        guard avcodec_parameters_to_context(ctx, par) >= 0 else { return nil }
        ctx.pointee.color_primaries = AVCOL_PRI_UNSPECIFIED
        ctx.pointee.color_trc = AVCOL_TRC_UNSPECIFIED
        ctx.pointee.colorspace = AVCOL_SPC_UNSPECIFIED
        // The container's size came along with the parameters; clear it so a size after open can only
        // have come from an SPS the decoder parsed (extradata without parameter sets → nil).
        ctx.pointee.width = 0
        ctx.pointee.height = 0
        ctx.pointee.coded_width = 0
        ctx.pointee.coded_height = 0
        ctx.pointee.thread_count = 1
        guard avcodec_open2(ctx, codec, nil) >= 0 else { return nil }
        guard ctx.pointee.coded_width > 0 || ctx.pointee.width > 0 else { return nil }
        return ColourTags(primaries: Int(ctx.pointee.color_primaries.rawValue),
                          transfer: Int(ctx.pointee.color_trc.rawValue),
                          matrix: Int(ctx.pointee.colorspace.rawValue))
    }

    /// HDR10 static metadata on the stream: a mastering-display record on codecpar, which the demuxer
    /// takes from the container (Matroska Colour's mastering block, MP4 `mdcv`). Content light level
    /// alone does not count: some muxers copy a `clli` onto SDR and HLG tracks. SEI the decoder sees
    /// lands on frames, not on codecpar, so it is not visible here.
    static func hasHDR10StaticMetadata(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
        let p = par.pointee
        return av_packet_side_data_get(p.coded_side_data, p.nb_coded_side_data, AV_PKT_DATA_MASTERING_DISPLAY_METADATA) != nil
    }

    static func dolbyVision(_ parPtr: UnsafeMutablePointer<AVCodecParameters>) -> DolbyVisionInfo? {
        let par = parPtr.pointee
        guard let sd = av_packet_side_data_get(par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
              let data = sd.pointee.data,
              sd.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { return nil }
        let rec = data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
        return DolbyVisionInfo(
            profile: Int(rec.dv_profile),
            level: Int(rec.dv_level),
            blPresent: rec.bl_present_flag != 0,
            elPresent: rec.el_present_flag != 0,
            rpuPresent: rec.rpu_present_flag != 0,
            compatId: Int(rec.dv_bl_signal_compatibility_id)
        )
    }

    private static func dictValue(_ dict: OpaquePointer?, _ key: String) -> String? {
        guard let entry = av_dict_get(dict, key, nil, 0), let value = entry.pointee.value else { return nil }
        let s = String(cString: value)
        return s.isEmpty ? nil : s
    }
}

/// Absolute-time deadline shared with FFmpeg's interrupt callback (checked during blocking I/O).
private nonisolated final class ProbeDeadline: Sendable {
    private let deadline: TimeInterval
    init(timeoutSec: Double) { deadline = ProcessInfo.processInfo.systemUptime + timeoutSec }
    var expired: Bool { ProcessInfo.processInfo.systemUptime >= deadline }
}

/// C-compatible interrupt callback: returns 1 (abort) once the deadline passes.
private nonisolated func mediaProbeShouldInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<ProbeDeadline>.fromOpaque(opaque).takeUnretainedValue().expired ? 1 : 0
}

/// One-time `avformat_network_init()` so avformat can open http(s) sources.
nonisolated enum MediaProbeNetwork {
    private static let initialized: Void = {
        avformat_network_init()
        return ()
    }()
    static func ensureInit() { _ = initialized }
}
