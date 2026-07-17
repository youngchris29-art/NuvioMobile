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
}

nonisolated struct EngineDecision: Equatable, Sendable {
    let engine: PlaybackEngine
    let reason: String

    /// Short label for the Stream Info overlay, e.g. "Native · DV P8.1" or "mpv · audio truehd".
    var displayNote: String {
        "\(engine == .native ? "Native" : "mpv") \u{00B7} \(reason)"
    }
}

nonisolated enum PlayerEngineRouter {
    /// Decide the engine for a probed stream. `nativeDVEnabled` is the Settings > Playback beta flag.
    static func route(probe: ProbeResult?, nativeDVEnabled: Bool) -> EngineDecision {
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
        // P7 needs an RPU→8.1 conversion that lands in Phase 5, so route it to mpv until then.
        if let dv = p.dolbyVision {
            switch dv.profile {
            case 5, 8: break
            case 7: return EngineDecision(engine: .mpv, reason: "DV P7 dual-layer (native pending Phase 5)")
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

    // MARK: - Criteria

    /// avformat reports comma-joined demuxer names (e.g. "matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2").
    private static func isNativeContainer(_ container: String) -> Bool {
        let c = container.lowercased()
        return c.contains("matroska") || c.contains("webm") || c.contains("mp4") || c.contains("mov")
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
                    container: String = "matroska,webm") -> ProbeResult {
            ProbeResult(
                container: container, videoCodec: video, videoProfile: 0, hdr: hdr, dolbyVision: dv,
                audio: audio.enumerated().map { AudioStreamInfo(index: $0.offset, codec: $0.element, channels: 6, language: "eng") },
                subtitles: [], durationSec: 3600, seekable: seekable
            )
        }
        let p5 = DolbyVisionInfo(profile: 5, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 0)
        let p81 = DolbyVisionInfo(profile: 8, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 1)
        let p7 = DolbyVisionInfo(profile: 7, level: 6, blPresent: true, elPresent: true, rpuPresent: true, compatId: 0)

        expect(route(probe: sample(dv: p5), nativeDVEnabled: true).engine, .native, "DV P5 MKV → native")
        expect(route(probe: sample(dv: p81), nativeDVEnabled: true).engine, .native, "DV P8.1 MKV → native")
        expect(route(probe: sample(dv: p7), nativeDVEnabled: true).engine, .mpv, "DV P7 dual-layer → mpv pre-Phase 5")
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
