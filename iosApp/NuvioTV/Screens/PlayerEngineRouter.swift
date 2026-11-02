import Foundation

// Phase 1 of the hybrid player: the pure routing decision. Given a `ProbeResult` (or nil) and the
// user's native-DV setting, decide which engine should render the stream. Deliberately dependency-
// free (no libav*, no SwiftUI) so it is trivially testable — see `selfCheckFailures()` below.
// See docs/tvos-hybrid-player-plan.md.
//
// Routing is conservative: the native AVPlayer path is chosen only when every check passes;
// anything ambiguous falls through to mpv, which plays everything today.

nonisolated enum PlaybackEngine: String, Sendable {
    case native   // AVPlayer, fed by the on-device MKV→fMP4 remux (true Dolby Vision, hardware decode)
    case mpv      // libmpv, the universal fallback
    case aether   // Aether (experimental, Settings > Playback): AVPlayer HLS + libavcodec software host
}

nonisolated struct EngineDecision: Equatable, Sendable {
    let engine: PlaybackEngine
    let reason: String
    /// B10 (BUG-166; Steven's rc4 verdict, "DV colours wrong"): mpv must render this stream with
    /// `gpu-next` (libplacebo), whatever Enhanced Video Renderer says. Set by `route` for a Dolby
    /// Vision profile 5 stream sent to mpv: the default `gpu` VO has no RPU processing and paints
    /// P5's IPTPQc2 picture green and magenta.
    var prefersGpuNext: Bool = false

    /// Short label for the Stream Info overlay, e.g. "Native · DV P8.1" or "mpv · audio truehd";
    /// "· gpu-next" is appended when `prefersGpuNext` (B10).
    var displayNote: String {
        let label: String
        switch engine {
        case .native: label = String(localized: "Native")
        case .mpv: label = "mpv"
        case .aether: label = "Aether"
        }
        let base = "\(label) \u{00B7} \(reason)"
        return prefersGpuNext ? "\(base) \u{00B7} gpu-next" : base
    }
}

/// Everything the Aether routing rows need beyond the probe (plan section 4). Plain values so the
/// router stays pure; the player screen builds it from the settings and the subtitle preferences.
nonisolated struct AetherRoutingOptions: Equatable, Sendable {
    /// `player.aetherEngine`. When false the router is today's, unchanged.
    var enabled: Bool
    /// `player.aetherDualLayerDV` (the engine reads it; routing only labels the FEL row).
    var dualLayerDV: Bool = false
    /// `player.aetherStyledSubsToMpv` (row 10).
    var styledSubsToMpv: Bool = true
    /// The source URL, for the `.m3u8` / `.mpd` live check (row 4).
    var sourceURL: URL? = nil
    /// Resolved subtitle language targets (`AetherSubtitleRouting.preferredTargets`).
    var preferredSubtitleTargets: [String] = []
    /// Subtitles set to Off (`SubtitleFallbackGuard.isOff`).
    var subtitlesOff: Bool = false
    /// "Use forced subtitles" (the shared auto-select plan then picks forced tracks only).
    var useForcedSubtitles: Bool = false
}

nonisolated enum PlayerEngineRouter {
    /// Decide the engine for a probed stream. `nativeDVEnabled` is the Settings > Playback beta flag;
    /// `dvP7FelToMpv` is its FEL-fidelity sub-setting (send Profile 7 FEL files to mpv instead of
    /// discarding their enhancement layer in the 8.1 conversion).
    ///
    /// Aether (Phase 1): `forcedEngine` (routing row 1) and `aether` (rows 2 to 11) are additive. With
    /// `aether` nil or disabled the decision is today's router, byte for byte.
    static func route(probe: ProbeResult?, nativeDVEnabled: Bool, dvP7FelToMpv: Bool = false,
                      aether: AetherRoutingOptions? = nil, forcedEngine: PlaybackEngine? = nil) -> EngineDecision {
        if let forced = forcedEngine { return EngineDecision(engine: forced, reason: "forced") }
        var decision: EngineDecision
        if let aether, aether.enabled {
            decision = decideAether(probe: probe, options: aether)
        } else {
            decision = decide(probe: probe, nativeDVEnabled: nativeDVEnabled, dvP7FelToMpv: dvP7FelToMpv)
        }
        if decision.engine == .mpv, mpvNeedsGpuNext(probe: probe) { decision.prefersGpuNext = true }
        return decision
    }

    /// B10 (BUG-166): a Dolby Vision profile 5 stream that plays on mpv needs `gpu-next`: whatever
    /// sent it there (P5 in MP4 today, or a native failure falling over). `PlayerScreen` asks this
    /// for the native → mpv fallback too.
    static func mpvNeedsGpuNext(probe: ProbeResult?) -> Bool {
        probe?.dolbyVision?.profile == 5
    }

    private static func decide(probe: ProbeResult?, nativeDVEnabled: Bool, dvP7FelToMpv: Bool) -> EngineDecision {
        guard nativeDVEnabled else { return EngineDecision(engine: .mpv, reason: "native engine off") }
        guard let p = probe else { return EngineDecision(engine: .mpv, reason: "probe unavailable") }
        guard p.seekable else { return EngineDecision(engine: .mpv, reason: "source not seekable") }
        guard isNativeContainer(p.container) else {
            return EngineDecision(engine: .mpv, reason: "container \(p.container)")
        }
        guard p.videoCodec == "hevc" || p.videoCodec == "h264" else {
            return EngineDecision(engine: .mpv, reason: p.videoCodec.isEmpty ? "no video stream" : "video \(p.videoCodec)")
        }

        // Dolby Vision profile gating. P5 and single-layer P8 play natively on tvOS 17.2+. Dual-layer
        // P7 converts to 8.1 during the remux (Phase 5: EL NALs dropped, RPUs rewritten via libdovi) —
        // but only the single-track layout whose RPUs the probe could actually parse; anything else
        // (two-track BL+EL, no RPU found, unparseable RPU) stays on mpv.
        if let dv = p.dolbyVision {
            switch dv.profile {
            case 5:
                // P3-F7 (2026-10-15): a DV profile 5 MP4 (Rutracker "Dolby Vision TV" WEB-DL, dvh1.05.06)
                // remuxed to fMP4 failed AVPlayer twice with CoreMediaErrorDomain -12927, and P5 in an
                // MP4/MOV container was routed to mpv from Batch B until the cause was found. The P5
                // spike (2026-10-20) traced it to the master playlist carrying no VIDEO-RANGE (the P5
                // VUI is unspecified); `MediaProbe.resolveColour` (shared with the remux's
                // `videoSignaling`) takes the range from the DOVI record, so P5 routes native in every
                // container. A native failure still falls over
                // to mpv on gpu-next (`mpvNeedsGpuNext`).
                break
            case 8: break
            case 7:
                guard p.videoStreamCount == 1 else {
                    return EngineDecision(engine: .mpv, reason: "DV P7 two-track")
                }
                switch dv.elKind {
                case .mel:
                    break
                case .fel:
                    if dvP7FelToMpv {
                        return EngineDecision(engine: .mpv, reason: "DV P7 FEL (fidelity preference)")
                    }
                case .missing, .unsupported, nil:
                    return EngineDecision(engine: .mpv, reason: "DV P7 (no convertible RPU)")
                }
            default: return EngineDecision(engine: .mpv, reason: "DV P\(dv.profile)")
            }
        }

        // At least one audio track must be AVPlayer-compatible (stream-copied) or TrueHD/DTS (the
        // remux transcodes those to AAC — Phase 4 v2). Video-only files are fine.
        let hasCompatibleAudio = p.audio.isEmpty
            || p.audio.contains { isNativeAudio($0.codec) || isTranscodableAudio($0.codec) }
        guard hasCompatibleAudio else {
            return EngineDecision(engine: .mpv, reason: "audio \(p.audio.first?.codec ?? "none")")
        }

        return EngineDecision(engine: .native, reason: nativeReason(p))
    }

    // MARK: - Aether (Phase 1)

    /// Video codecs the Aether route accepts (plan section 4 row 6; the engine's software host decodes
    /// every one of them, AV1 through dav1d).
    static let aetherVideoCodecs: Set<String> = ["hevc", "h264", "av1", "vp9", "mpeg2video", "vc1", "mpeg4"]

    /// Audio codecs the Aether route accepts (row 9, plan section 14): stream-copied or bridged by the
    /// engine. `pcm_bluray` and `mlp` are deliberately absent and stay on mpv.
    static let aetherAudioCodecs: Set<String> = [
        "aac", "ac3", "eac3", "flac", "alac", "mp3", "mp2", "truehd", "dts", "opus", "vorbis",
        "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_s16be", "pcm_u8",
        "pcm_alaw", "pcm_mulaw", "pcm_dvd",
    ]

    /// Plan section 4 rows 3 to 11 (rows 1 and 2 are handled by `route`). Independent of the native
    /// Dolby Vision setting; the caller runs the probe whenever Aether is On.
    private static func decideAether(probe: ProbeResult?, options: AetherRoutingOptions) -> EngineDecision {
        func mpv(_ reason: String) -> EngineDecision { EngineDecision(engine: .mpv, reason: reason) }

        // Row 3
        guard let p = probe else { return mpv("probe unavailable") }
        // Row 4
        let ext = options.sourceURL?.pathExtension.lowercased()
        if !p.seekable || p.durationSec <= 0 || ext == "m3u8" || ext == "mpd" {
            return mpv("live or non-seekable")
        }
        // Row 5
        guard isNativeContainer(p.container) else { return mpv("container \(p.container)") }
        // Row 6
        guard aetherVideoCodecs.contains(p.videoCodec) else {
            return mpv(p.videoCodec.isEmpty ? "no video stream" : "video \(p.videoCodec)")
        }
        // Rows 7 and 8: two-track P7 stays on mpv; a single-track FEL file is labelled (the dual-layer
        // setting only changes how the engine renders it, read by the Aether controller).
        var reason: String? = nil
        if let dv = p.dolbyVision, dv.profile == 7 {
            if p.videoStreamCount >= 2 { return mpv("DV P7 two-track") }
            if dv.elKind == .fel { reason = "DV P7 FEL" }
        }
        // Row 9: an audio-less file is fine; otherwise at least one track must be in the set.
        if !p.audio.isEmpty, !p.audio.contains(where: { aetherAudioCodecs.contains($0.codec) }) {
            return mpv("audio \(p.audio.first?.codec ?? "none")")
        }
        // Row 10
        if options.styledSubsToMpv,
           AetherSubtitleRouting.initialTrackIsStyledASS(
               probe: p, preferredLanguages: options.preferredSubtitleTargets,
               subtitlesOff: options.subtitlesOff, useForcedSubtitles: options.useForcedSubtitles) {
            return mpv("styled ASS")
        }
        // Row 11
        return EngineDecision(engine: .aether, reason: reason ?? aetherReason(p))
    }

    private static func aetherReason(_ p: ProbeResult) -> String {
        if let dv = p.dolbyVision {
            if dv.profile == 7 { return "DV P7 \u{2192} 8.1" }
            return dv.profile == 8 && dv.compatId == 1 ? "DV P8.1" : "DV P\(dv.profile)"
        }
        if p.videoCodec == "av1" { return "AV1" }
        switch p.hdr {
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .other: return "HDR"
        case .sdr: return "SDR"
        }
    }

    // MARK: - Criteria

    /// The MP4/MOV family of avformat's comma-joined demuxer names ("mov,mp4,m4a,3gp,3g2,mj2").
    private static func isMP4Container(_ container: String) -> Bool {
        let c = container.lowercased()
        return c.contains("mp4") || c.contains("mov")
    }

    /// avformat reports comma-joined demuxer names (e.g. "matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2").
    private static func isNativeContainer(_ container: String) -> Bool {
        let c = container.lowercased()
        return c.contains("matroska") || c.contains("webm") || isMP4Container(c)
    }

    /// Audio codecs AVPlayer can play directly (the remux stream-copies these).
    private static func isNativeAudio(_ codec: String) -> Bool {
        switch codec {
        case "aac", "ac3", "eac3", "flac", "alac", "mp3": return true
        default: return false
        }
    }

    /// Codecs the remux transcodes to AAC when no copyable track exists (AudioTranscoder — decoders
    /// verified present in the MPVKit FFmpeg build). Canonical descriptor names as MediaProbe reports
    /// them: FFmpeg calls DTS (incl. DTS-HD, decoded via its core/extensions) "dts".
    private static func isTranscodableAudio(_ codec: String) -> Bool {
        codec == "truehd" || codec == "dts"
    }

    private static func nativeReason(_ p: ProbeResult) -> String {
        if let dv = p.dolbyVision {
            if dv.profile == 7 {
                return "DV P7 \(dv.elKind == .fel ? "FEL" : "MEL") \u{2192} 8.1"
            }
            // compatId 1 == HDR10-compatible base layer, i.e. Profile 8.1.
            return dv.profile == 8 && dv.compatId == 1 ? "DV P8.1" : "DV P\(dv.profile)"
        }
        switch p.hdr {
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .other: return "HDR"
        case .sdr: return "SDR"
        }
    }
}

#if DEBUG
extension PlayerEngineRouter {
    /// Router assertions with canned probe results — stands in for a unit-test target (this project
    /// has none). Returns human-readable failures; run once at first playback (see PlayerScreen).
    static func selfCheckFailures() -> [String] {
        var fails: [String] = []
        func expect(_ actual: PlaybackEngine, _ expected: PlaybackEngine, _ msg: String) {
            if actual != expected { fails.append("router self-check: \(msg) (got \(actual.rawValue))") }
        }
        func sample(video: String = "hevc", dv: DolbyVisionInfo? = nil, hdr: HDRFormat = .sdr,
                    audio: [String] = ["eac3"], seekable: Bool = true,
                    container: String = "matroska,webm", videoStreams: Int = 1) -> ProbeResult {
            ProbeResult(
                container: container, videoCodec: video, videoProfile: 0, hdr: hdr, dolbyVision: dv,
                audio: audio.enumerated().map { AudioStreamInfo(index: $0.offset, codec: $0.element, channels: 6, language: "eng") },
                subtitles: [], durationSec: 3600, seekable: seekable, videoStreamCount: videoStreams
            )
        }
        let p5 = DolbyVisionInfo(profile: 5, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 0)
        let p81 = DolbyVisionInfo(profile: 8, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 1)
        func p7(_ kind: DVELKind?) -> DolbyVisionInfo {
            DolbyVisionInfo(profile: 7, level: 6, blPresent: true, elPresent: true, rpuPresent: true,
                            compatId: 0, elKind: kind)
        }

        expect(route(probe: sample(dv: p5), nativeDVEnabled: true).engine, .native, "DV P5 MKV → native")
        expect(route(probe: sample(dv: p5, container: "mov,mp4,m4a,3gp,3g2,mj2"), nativeDVEnabled: true).engine, .native, "DV P5 MP4 → native (P5 spike, VIDEO-RANGE from the DOVI record)")
        expect(route(probe: sample(dv: p81, container: "mov,mp4,m4a,3gp,3g2,mj2"), nativeDVEnabled: true).engine, .native, "DV P8.1 MP4 unaffected by the P5 rule")
        expect(route(probe: sample(dv: p81), nativeDVEnabled: true).engine, .native, "DV P8.1 MKV → native")
        expect(route(probe: sample(dv: p7(.mel)), nativeDVEnabled: true).engine, .native, "DV P7 MEL → native (8.1 conversion)")
        expect(route(probe: sample(dv: p7(.fel)), nativeDVEnabled: true).engine, .native, "DV P7 FEL → native by default")
        expect(route(probe: sample(dv: p7(.fel)), nativeDVEnabled: true, dvP7FelToMpv: true).engine, .mpv, "DV P7 FEL + fidelity pref → mpv")
        expect(route(probe: sample(dv: p7(.mel)), nativeDVEnabled: true, dvP7FelToMpv: true).engine, .native, "DV P7 MEL unaffected by FEL pref")
        expect(route(probe: sample(dv: p7(.mel), videoStreams: 2), nativeDVEnabled: true).engine, .mpv, "DV P7 two-track → mpv")
        expect(route(probe: sample(dv: p7(.missing)), nativeDVEnabled: true).engine, .mpv, "DV P7 without RPUs → mpv")
        expect(route(probe: sample(dv: p7(.unsupported)), nativeDVEnabled: true).engine, .mpv, "DV P7 unparseable RPU → mpv")
        expect(route(probe: sample(dv: p7(nil)), nativeDVEnabled: true).engine, .mpv, "DV P7 unclassified → mpv")
        expect(route(probe: sample(hdr: .hdr10), nativeDVEnabled: true).engine, .native, "HDR10 HEVC → native")
        expect(route(probe: sample(video: "h264"), nativeDVEnabled: true).engine, .native, "H.264 → native")
        expect(route(probe: sample(video: "av1"), nativeDVEnabled: true).engine, .mpv, "AV1 → mpv")
        expect(route(probe: sample(audio: ["truehd"]), nativeDVEnabled: true).engine, .native, "TrueHD-only → native (transcode)")
        expect(route(probe: sample(audio: ["dts"]), nativeDVEnabled: true).engine, .native, "DTS-only → native (transcode)")
        expect(route(probe: sample(audio: ["opus"]), nativeDVEnabled: true).engine, .mpv, "Opus-only → mpv")
        expect(route(probe: sample(audio: ["truehd", "ac3"]), nativeDVEnabled: true).engine, .native, "TrueHD+AC3 → native")
        expect(route(probe: sample(seekable: false), nativeDVEnabled: true).engine, .mpv, "non-seekable → mpv")
        expect(route(probe: sample(container: "avi"), nativeDVEnabled: true).engine, .mpv, "AVI → mpv")
        expect(route(probe: sample(dv: p5), nativeDVEnabled: false).engine, .mpv, "flag off → mpv")
        expect(route(probe: nil, nativeDVEnabled: true).engine, .mpv, "nil probe → mpv")
        return fails
    }
}
#endif
