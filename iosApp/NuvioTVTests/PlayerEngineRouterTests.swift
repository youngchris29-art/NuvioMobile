import XCTest
@testable import NuvioTV

/// B10 (BUG-166; Steven, beta.19-rc4 verdict 2026-10-16, "DV colours wrong"): a Dolby Vision
/// profile 5 stream the router sends to mpv asks for `gpu-next` (mpv's `gpu` VO has no RPU
/// processing); every other decision leaves the renderer to the setting.
final class PlayerEngineRouterTests: XCTestCase {

    private let mp4 = "mov,mp4,m4a,3gp,3g2,mj2"

    private func sample(dv: DolbyVisionInfo?, container: String = "matroska,webm",
                        videoStreams: Int = 1, audio: [String] = ["eac3"]) -> ProbeResult {
        ProbeResult(
            container: container, videoCodec: "hevc", videoProfile: 0, hdr: .sdr, dolbyVision: dv,
            audio: audio.enumerated().map { AudioStreamInfo(index: $0.offset, codec: $0.element, channels: 6, language: "eng") },
            subtitles: [], durationSec: 3600, seekable: true, videoStreamCount: videoStreams
        )
    }

    private let p5 = DolbyVisionInfo(profile: 5, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 0)
    private let p81 = DolbyVisionInfo(profile: 8, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 1)
    private let p7 = DolbyVisionInfo(profile: 7, level: 6, blPresent: true, elPresent: true, rpuPresent: true,
                                     compatId: 0, elKind: .mel)

    /// P5 spike (2026-10-20): the P3-F7 rule is gone; P5 in MP4 routes native like P5 in Matroska.
    func testP5InMP4RoutesNative() {
        let decision = PlayerEngineRouter.route(probe: sample(dv: p5, container: mp4), nativeDVEnabled: true)
        XCTAssertEqual(decision.engine, .native)
        XCTAssertFalse(decision.prefersGpuNext)
        XCTAssertFalse(decision.displayNote.contains("gpu-next"), decision.displayNote)
    }

    func testP5OnMpvForAnotherReasonStillGetsGpuNext() {
        let decision = PlayerEngineRouter.route(probe: sample(dv: p5, audio: ["opus"]), nativeDVEnabled: true)
        XCTAssertEqual(decision.engine, .mpv)
        XCTAssertTrue(decision.prefersGpuNext)
    }

    func testP5InMatroskaStaysNativeWithoutTheFlag() {
        let decision = PlayerEngineRouter.route(probe: sample(dv: p5), nativeDVEnabled: true)
        XCTAssertEqual(decision.engine, .native)
        XCTAssertFalse(decision.prefersGpuNext)
    }

    func testP8NativeAndP7TwoTrackDoNotForceGpuNext() {
        let p8 = PlayerEngineRouter.route(probe: sample(dv: p81, container: mp4), nativeDVEnabled: true)
        XCTAssertEqual(p8.engine, .native)
        XCTAssertFalse(p8.prefersGpuNext)
        let twoTrack = PlayerEngineRouter.route(probe: sample(dv: p7, videoStreams: 2), nativeDVEnabled: true)
        XCTAssertEqual(twoTrack.engine, .mpv)
        XCTAssertFalse(twoTrack.prefersGpuNext)
        XCTAssertFalse(twoTrack.displayNote.contains("gpu-next"))
    }

    // P5 spike (2026-10-20): the remux treats an hvcC with no parameter-set arrays like missing
    // extradata (the in-band `dvhe` layout of DV P5 WEB-DL MP4s: init.mp4 shipped a 31-byte hvcC,
    // numArrays=0, and AVPlayer failed the item with CoreMediaErrorDomain -4).
    func testHvccWithNoArraysLacksParameterSets() {
        var hvcc = [UInt8](repeating: 0, count: 23); hvcc[0] = 1; hvcc[21] = 0x0F; hvcc[22] = 0
        hvcc.withUnsafeBufferPointer { XCTAssertTrue(RemuxSession.hvccHasNoParameterSets($0)) }
    }

    func testHvccWithEmptyArraysLacksParameterSets() {
        var hvcc = [UInt8](repeating: 0, count: 23); hvcc[0] = 1; hvcc[22] = 2
        hvcc += [0xA0, 0, 0]            // VPS array, numNalus = 0
        hvcc += [0xA1, 0, 0]            // SPS array, numNalus = 0
        hvcc.withUnsafeBufferPointer { XCTAssertTrue(RemuxSession.hvccHasNoParameterSets($0)) }
    }

    func testHvccWithParameterSetsIsComplete() {
        var hvcc = [UInt8](repeating: 0, count: 23); hvcc[0] = 1; hvcc[22] = 1
        hvcc += [0xA1, 0, 1, 0, 2, 0x42, 0x01]   // one SPS NAL of 2 bytes
        hvcc.withUnsafeBufferPointer { XCTAssertFalse(RemuxSession.hvccHasNoParameterSets($0)) }
    }

    func testAnnexBAndShortExtradataAreNotTreatedAsEmptyHvcc() {
        let annexB: [UInt8] = [0, 0, 0, 1, 0x40, 0x01, 0x0C] + [UInt8](repeating: 0, count: 20)
        annexB.withUnsafeBufferPointer { XCTAssertFalse(RemuxSession.hvccHasNoParameterSets($0)) }
        let short: [UInt8] = [1, 2, 3]
        short.withUnsafeBufferPointer { XCTAssertFalse(RemuxSession.hvccHasNoParameterSets($0)) }
    }

    // P5 Wave 3: the native signaling retry only when there is a SUPPLEMENTAL-CODECS to drop.
    func testSignalingRetryOnlyWhenSupplementalCodecsExist() {
        XCTAssertTrue(NativePlaybackCoordinator.signalingRetryAllowed(attempt: 0, supplementalCodecs: "dvh1.08.06/db1p"))
        XCTAssertFalse(NativePlaybackCoordinator.signalingRetryAllowed(attempt: 0, supplementalCodecs: nil))
        XCTAssertFalse(NativePlaybackCoordinator.signalingRetryAllowed(attempt: 0, supplementalCodecs: ""))
        XCTAssertFalse(NativePlaybackCoordinator.signalingRetryAllowed(attempt: 1, supplementalCodecs: "dvh1.08.06/db1p"))
    }

    func testFallbackRuleReadsTheProbe() {
        XCTAssertTrue(PlayerEngineRouter.mpvNeedsGpuNext(probe: sample(dv: p5)))
        XCTAssertFalse(PlayerEngineRouter.mpvNeedsGpuNext(probe: sample(dv: p81)))
        XCTAssertFalse(PlayerEngineRouter.mpvNeedsGpuNext(probe: sample(dv: nil)))
        XCTAssertFalse(PlayerEngineRouter.mpvNeedsGpuNext(probe: nil))
    }

    // MARK: - W3-19 (wave3c review r1 P3-2 / r2 P3-2): the `[PlayerRouter]` probe lines' pure parts

    /// The probe "ran out the clock" when it finished within 50 ms of the cap; anything quicker
    /// failed early (unreachable, unreadable).
    func testProbeOutcomeSplitsACapHitFromAnEarlyFailureAtFiftyMsBelowTheCap() {
        XCTAssertEqual(PlayerRouterLog.probeOutcome(ms: 3949, capMs: 4000), "probe failed early")
        XCTAssertEqual(PlayerRouterLog.probeOutcome(ms: 3950, capMs: 4000), "probe cap hit")
        XCTAssertEqual(PlayerRouterLog.probeOutcome(ms: 4000, capMs: 4000), "probe cap hit")
        XCTAssertEqual(PlayerRouterLog.probeOutcome(ms: 4210, capMs: 4000), "probe cap hit")
        XCTAssertEqual(PlayerRouterLog.probeOutcome(ms: 0, capMs: 4000), "probe failed early")
    }

    /// The privacy guard: Release prints the top-level domain only, so a self-hosted add-on, proxy
    /// or home-server host never reaches a rig console log (the rig logs fall under the staging rule).
    func testHostIsRedactedToItsTopLevelDomain() throws {
        func redacted(_ string: String) throws -> String {
            PlayerRouterLog.host(try XCTUnwrap(URL(string: string), string), reveal: false)
        }
        XCTAssertEqual(try redacted("https://a.b.example.com/x"), "<redacted>.com")
        XCTAssertEqual(try redacted("https://example.org:8443/stream.mkv?token=abc"), "<redacted>.org")
        XCTAssertEqual(try redacted("https://media.home-server.example.co.uk/v"), "<redacted>.uk")
    }

    /// An IP literal or a dotless name says nothing a log should keep, and has no top-level domain
    /// to show; a trailing dot has none either.
    func testHostIsFullyRedactedForAnIPLiteralADotlessNameAndATrailingDot() throws {
        func redacted(_ string: String) throws -> String {
            PlayerRouterLog.host(try XCTUnwrap(URL(string: string), string), reveal: false)
        }
        XCTAssertEqual(try redacted("http://192.168.1.10:8080/"), "<redacted>")
        XCTAssertEqual(try redacted("http://10.0.0.2/x.mkv"), "<redacted>")
        XCTAssertEqual(try redacted("http://[fe80::1]/"), "<redacted>")
        XCTAssertEqual(try redacted("http://[2001:db8::7]:8096/"), "<redacted>")
        XCTAssertEqual(try redacted("http://nas/"), "<redacted>")
        XCTAssertEqual(try redacted("http://localhost:32400/"), "<redacted>")
        XCTAssertEqual(try redacted("http://example.com./"), "<redacted>")
    }

    /// The reveal path (DEBUG builds, or `-debug.playerRouterHosts YES` in Release) prints the host
    /// whole, IP literals and dotless names included.
    func testHostIsFullWhenRevealed() throws {
        func revealed(_ string: String) throws -> String {
            PlayerRouterLog.host(try XCTUnwrap(URL(string: string), string), reveal: true)
        }
        XCTAssertEqual(try revealed("https://a.b.example.com/x"), "a.b.example.com")
        XCTAssertEqual(try revealed("http://192.168.1.10:8080/"), "192.168.1.10")
        XCTAssertEqual(try revealed("http://nas/"), "nas")
        XCTAssertEqual(PlayerRouterLog.revealHostsKey, "debug.playerRouterHosts")
        #if DEBUG
        XCTAssertTrue(PlayerRouterLog.revealsHosts, "DEBUG builds always print the host")
        XCTAssertEqual(PlayerRouterLog.host(try XCTUnwrap(URL(string: "https://a.b.example.com/x"))),
                       "a.b.example.com", "the default argument is the latched reveal setting")
        #endif
    }

    /// A URL with no host prints `-`, revealed or not.
    func testHostIsADashWhenTheURLHasNone() throws {
        let file = try XCTUnwrap(URL(string: "file:///tmp/x.mkv"))
        XCTAssertEqual(PlayerRouterLog.host(file, reveal: false), "-")
        XCTAssertEqual(PlayerRouterLog.host(file, reveal: true), "-")
    }
}

// MARK: - Aether (Phase 1)

/// Plan section 4 (rows 1 to 11) with the section 14 overrides.
final class AetherRoutingTests: XCTestCase {

    private let mp4 = "mov,mp4,m4a,3gp,3g2,mj2"
    private let on = AetherRoutingOptions(enabled: true)

    private func sample(video: String = "hevc", dv: DolbyVisionInfo? = nil, hdr: HDRFormat = .sdr,
                        audio: [String] = ["eac3"], container: String = "matroska,webm",
                        seekable: Bool = true, duration: Double = 3600, videoStreams: Int = 1,
                        subtitles: [SubtitleStreamInfo] = [], fonts: Int = 0) -> ProbeResult {
        ProbeResult(
            container: container, videoCodec: video, videoProfile: 0, hdr: hdr, dolbyVision: dv,
            audio: audio.enumerated().map { AudioStreamInfo(index: $0.offset, codec: $0.element, channels: 6, language: "eng") },
            subtitles: subtitles, durationSec: duration, seekable: seekable, videoStreamCount: videoStreams,
            fontAttachmentCount: fonts
        )
    }

    private func p7(_ kind: DVELKind?) -> DolbyVisionInfo {
        DolbyVisionInfo(profile: 7, level: 6, blPresent: true, elPresent: true, rpuPresent: true, compatId: 0, elKind: kind)
    }
    private let p81 = DolbyVisionInfo(profile: 8, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 1)
    private let p5 = DolbyVisionInfo(profile: 5, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 0)

    private func route(_ probe: ProbeResult?, _ options: AetherRoutingOptions? = nil,
                       native: Bool = true, felToMpv: Bool = false,
                       forced: PlaybackEngine? = nil) -> EngineDecision {
        PlayerEngineRouter.route(probe: probe, nativeDVEnabled: native, dvP7FelToMpv: felToMpv,
                                 aether: options ?? on, forcedEngine: forced)
    }

    private func ass(_ lang: String = "eng", isDefault: Bool = false) -> SubtitleStreamInfo {
        SubtitleStreamInfo(index: 3, codec: "ass", isBitmap: false, language: lang, isDefault: isDefault)
    }

    // Row 1
    func testForcedEngineWinsInEveryConfiguration() {
        XCTAssertEqual(route(sample(), forced: .aether).engine, .aether)
        XCTAssertEqual(route(sample(), forced: .mpv).engine, .mpv)
        XCTAssertEqual(route(sample(), AetherRoutingOptions(enabled: false), forced: .native).engine, .native)
        XCTAssertEqual(route(nil, forced: .aether).reason, "forced")
        XCTAssertEqual(route(sample(), forced: .aether).displayNote, "Aether \u{00B7} forced")
    }

    // Row 2: flag Off is today's router (the existing table, unchanged)
    func testFlagOffMatchesTodaysRouterForEveryProbe() {
        let off = AetherRoutingOptions(enabled: false)
        let probes: [ProbeResult?] = [
            nil, sample(), sample(video: "av1"), sample(video: "h264", hdr: .hdr10), sample(dv: p5),
            sample(dv: p5, container: mp4), sample(dv: p81), sample(dv: p7(.mel)), sample(dv: p7(.fel)),
            sample(dv: p7(.mel), videoStreams: 2), sample(dv: p7(.missing)), sample(audio: ["opus"]),
            sample(audio: ["truehd"]), sample(audio: ["dts"]), sample(seekable: false), sample(container: "avi"),
        ]
        for probe in probes {
            for native in [true, false] {
                for fel in [true, false] {
                    let today = PlayerEngineRouter.route(probe: probe, nativeDVEnabled: native, dvP7FelToMpv: fel)
                    let viaOff = PlayerEngineRouter.route(probe: probe, nativeDVEnabled: native, dvP7FelToMpv: fel, aether: off)
                    XCTAssertEqual(today, viaOff)
                    XCTAssertNotEqual(viaOff.engine, .aether)
                }
            }
        }
        XCTAssertEqual(PlayerEngineRouter.route(probe: sample(dv: p5), nativeDVEnabled: true, aether: off).engine, .native)
        XCTAssertEqual(PlayerEngineRouter.route(probe: sample(audio: ["opus"]), nativeDVEnabled: true, aether: off).engine, .mpv)
    }

    func testAetherIsIndependentOfTheNativeDolbyVisionSetting() {
        XCTAssertEqual(route(sample(), native: false).engine, .aether)
        XCTAssertEqual(route(sample(), native: true).engine, .aether)
    }

    // Row 3
    func testNilProbeRoutesToMpv() {
        let d = route(nil)
        XCTAssertEqual(d.engine, .mpv)
        XCTAssertEqual(d.reason, "probe unavailable")
    }

    // Row 4
    func testLiveAndNonSeekableRouteToMpv() {
        XCTAssertEqual(route(sample(seekable: false)).reason, "live or non-seekable")
        XCTAssertEqual(route(sample(duration: 0)).reason, "live or non-seekable")
        var hls = on; hls.sourceURL = URL(string: "https://example.com/master.m3u8")
        var dash = on; dash.sourceURL = URL(string: "https://example.com/stream.MPD?x=1")
        var plain = on; plain.sourceURL = URL(string: "https://example.com/movie.mkv")
        XCTAssertEqual(route(sample(), hls).engine, .mpv)
        XCTAssertEqual(route(sample(), dash).reason, "live or non-seekable")
        XCTAssertEqual(route(sample(), plain).engine, .aether)
    }

    // Row 5
    func testContainerGate() {
        XCTAssertEqual(route(sample(container: "avi")).reason, "container avi")
        XCTAssertEqual(route(sample(container: "mpegts")).engine, .mpv)
        XCTAssertEqual(route(sample(container: mp4)).engine, .aether)
        XCTAssertEqual(route(sample(container: "matroska,webm")).engine, .aether)
    }

    // Row 6
    func testVideoCodecSet() {
        for codec in ["hevc", "h264", "av1", "vp9", "mpeg2video", "vc1", "mpeg4"] {
            XCTAssertEqual(route(sample(video: codec)).engine, .aether, codec)
        }
        XCTAssertEqual(route(sample(video: "prores")).reason, "video prores")
        XCTAssertEqual(route(sample(video: "")).reason, "no video stream")
    }

    // Row 7 (section 14: stays mpv)
    func testTwoTrackP7StaysOnMpv() {
        let d = route(sample(dv: p7(.missing), videoStreams: 2))
        XCTAssertEqual(d.engine, .mpv)
        XCTAssertEqual(d.reason, "DV P7 two-track")
        XCTAssertEqual(route(sample(dv: p7(.fel), videoStreams: 2)).engine, .mpv)
    }

    // Row 8
    func testP7FelRoutesToAetherWhateverTheFelSetting() {
        var dual = on; dual.dualLayerDV = true
        for options in [on, dual] {
            for felToMpv in [true, false] {
                let d = route(sample(dv: p7(.fel)), options, felToMpv: felToMpv)
                XCTAssertEqual(d.engine, .aether)
                XCTAssertEqual(d.reason, "DV P7 FEL")
                XCTAssertEqual(d.displayNote, "Aether \u{00B7} DV P7 FEL")
            }
        }
        XCTAssertEqual(route(sample(dv: p7(.mel))).engine, .aether)
    }

    func testP7FelStillGatedByLaterRows() {
        XCTAssertEqual(route(sample(dv: p7(.fel), audio: ["pcm_bluray"])).engine, .mpv)
    }

    // Row 9 (section 14)
    func testAudioSet() {
        let accepted = ["aac", "ac3", "eac3", "flac", "alac", "mp3", "mp2", "truehd", "dts", "opus", "vorbis",
                        "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_s16be", "pcm_u8",
                        "pcm_alaw", "pcm_mulaw", "pcm_dvd"]
        for codec in accepted {
            XCTAssertEqual(route(sample(audio: [codec])).engine, .aether, codec)
        }
        for codec in ["pcm_bluray", "mlp", "pcm_s24be", "wmav2", "cook"] {
            let d = route(sample(audio: [codec]))
            XCTAssertEqual(d.engine, .mpv, codec)
            XCTAssertEqual(d.reason, "audio \(codec)")
        }
        XCTAssertEqual(route(sample(audio: ["mlp", "ac3"])).engine, .aether, "one supported track is enough")
        XCTAssertEqual(route(sample(audio: [])).engine, .aether, "video-only files are fine")
    }

    // Row 10
    func testStyledAssRoutesToMpvOnlyWhenTheSettingIsOn() {
        let styled = sample(subtitles: [ass()], fonts: 2)
        var options = on
        options.preferredSubtitleTargets = ["eng"]
        let d = route(styled, options)
        XCTAssertEqual(d.engine, .mpv)
        XCTAssertEqual(d.reason, "styled ASS")
        options.styledSubsToMpv = false
        XCTAssertEqual(route(styled, options).engine, .aether)
    }

    func testAssWithoutFontsAndSubtitlesOffStayOnAether() {
        var options = on
        options.preferredSubtitleTargets = ["eng"]
        XCTAssertEqual(route(sample(subtitles: [ass()], fonts: 0), options).engine, .aether)
        options.subtitlesOff = true
        XCTAssertEqual(route(sample(subtitles: [ass()], fonts: 2), options).engine, .aether)
    }

    // Row 11
    func testReasonNotes() {
        XCTAssertEqual(route(sample(dv: p81)).displayNote, "Aether \u{00B7} DV P8.1")
        XCTAssertEqual(route(sample(hdr: .hdr10)).displayNote, "Aether \u{00B7} HDR10")
        XCTAssertEqual(route(sample(hdr: .hlg)).reason, "HLG")
        XCTAssertEqual(route(sample(video: "av1")).displayNote, "Aether \u{00B7} AV1")
        XCTAssertEqual(route(sample()).reason, "SDR")
        XCTAssertEqual(route(sample(dv: p5)).reason, "DV P5")
    }

    func testP5OnMpvViaAetherRowsStillGetsGpuNext() {
        let d = route(sample(dv: p5, audio: ["mlp"]))
        XCTAssertEqual(d.engine, .mpv)
        XCTAssertTrue(d.prefersGpuNext)
        XCTAssertFalse(route(sample(dv: p5)).prefersGpuNext)
    }

    func testFontAttachmentDetection() {
        for codec in ["ttf", "otf", "TTF"] {
            XCTAssertTrue(MediaProbe.isFontAttachment(codec: codec, mimeType: nil), codec)
        }
        for mime in ["font/ttf", "font/otf", "application/x-truetype-font", "application/vnd.ms-opentype",
                     "application/x-font-ttf", "Application/X-TrueType-Font"] {
            XCTAssertTrue(MediaProbe.isFontAttachment(codec: "none", mimeType: mime), mime)
        }
        XCTAssertFalse(MediaProbe.isFontAttachment(codec: "none", mimeType: "image/jpeg"))
        XCTAssertFalse(MediaProbe.isFontAttachment(codec: "none", mimeType: nil))
    }

    func testAetherSettingsDefaultsAndLayoutFallback() {
        let suite = UserDefaults(suiteName: "AetherRoutingTests.\(UUID().uuidString)")!
        XCTAssertFalse(AetherTuning.isEngineEnabled(defaults: suite))
        XCTAssertFalse(AetherTuning.isObjectAudioEnabled(defaults: suite))
        XCTAssertFalse(AetherTuning.isDualLayerDVEnabled(defaults: suite))
        XCTAssertTrue(AetherTuning.keepStyledSubsOnMpv(defaults: suite))
        XCTAssertTrue(AetherTuning.isLosslessBridgeEnabled(defaults: suite))
        XCTAssertEqual(AetherTuning.layout(defaults: suite), "7.1.4")
        suite.set("9.1.6", forKey: PlayerTuning.aetherObjectAudioLayoutKey)
        XCTAssertEqual(AetherTuning.layout(defaults: suite), "9.1.6")
        suite.set("bogus", forKey: PlayerTuning.aetherObjectAudioLayoutKey)
        XCTAssertEqual(AetherTuning.layout(defaults: suite), "7.1.4")
        suite.set(false, forKey: PlayerTuning.aetherStyledSubsToMpvKey)
        XCTAssertFalse(AetherTuning.keepStyledSubsOnMpv(defaults: suite))
    }
}

final class AetherSubtitleRoutingTests: XCTestCase {

    private func probe(_ subs: [SubtitleStreamInfo], fonts: Int) -> ProbeResult {
        ProbeResult(
            container: "matroska,webm", videoCodec: "hevc", videoProfile: 0, hdr: .sdr, dolbyVision: nil,
            audio: [AudioStreamInfo(index: 1, codec: "eac3", channels: 6, language: "eng")],
            subtitles: subs, durationSec: 3600, seekable: true, videoStreamCount: 1, fontAttachmentCount: fonts
        )
    }

    private func sub(_ index: Int, _ codec: String, _ lang: String?, isDefault: Bool = false,
                     isForced: Bool = false) -> SubtitleStreamInfo {
        SubtitleStreamInfo(index: index, codec: codec, isBitmap: false, language: lang,
                           isDefault: isDefault, isForced: isForced)
    }

    func testAssWithFontsIsStyled() {
        let p = probe([sub(2, "ass", "eng")], fonts: 3)
        XCTAssertTrue(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["eng"], subtitlesOff: false))
        let ssa = probe([sub(2, "ssa", "eng")], fonts: 1)
        XCTAssertTrue(AetherSubtitleRouting.initialTrackIsStyledASS(probe: ssa, preferredLanguages: ["eng"], subtitlesOff: false))
    }

    func testAssWithoutFontsIsPlainText() {
        let p = probe([sub(2, "ass", "eng")], fonts: 0)
        XCTAssertFalse(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["eng"], subtitlesOff: false))
    }

    func testSrtIsNeverStyled() {
        let p = probe([sub(2, "subrip", "eng")], fonts: 4)
        XCTAssertFalse(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["eng"], subtitlesOff: false))
    }

    func testSubtitlesOffIsNeverStyled() {
        let p = probe([sub(2, "ass", "eng", isDefault: true)], fonts: 3)
        XCTAssertFalse(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["eng"], subtitlesOff: true))
    }

    func testPreferredLanguagePicksANonAssTrack() {
        let p = probe([sub(2, "ass", "jpn", isDefault: true), sub(3, "subrip", "eng")], fonts: 3)
        XCTAssertFalse(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["eng"], subtitlesOff: false))
        XCTAssertTrue(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["jpn"], subtitlesOff: false))
    }

    func testNoLanguageMatchFallsBackToTheContainerDefault() {
        let p = probe([sub(2, "ass", "jpn", isDefault: true), sub(3, "subrip", "fre")], fonts: 3)
        XCTAssertTrue(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["eng"], subtitlesOff: false))
        let noDefault = probe([sub(2, "ass", "jpn"), sub(3, "subrip", "fre")], fonts: 3)
        XCTAssertFalse(AetherSubtitleRouting.initialTrackIsStyledASS(probe: noDefault, preferredLanguages: ["eng"], subtitlesOff: false))
    }

    func testForcedTracksAreSkippedUnlessForcedSubtitlesAreOn() {
        let p = probe([sub(2, "ass", "eng", isForced: true), sub(3, "subrip", "eng")], fonts: 2)
        XCTAssertFalse(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["eng"], subtitlesOff: false))
        XCTAssertTrue(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["eng"], subtitlesOff: false,
                                                                    useForcedSubtitles: true))
    }

    // Review r1 F2: forced subtitles are matched against the audio playback selects (the preferred
    // one), not the probe's first audio track.
    private func dualAudioProbe(_ subs: [SubtitleStreamInfo], fonts: Int) -> ProbeResult {
        ProbeResult(
            container: "matroska,webm", videoCodec: "hevc", videoProfile: 0, hdr: .sdr, dolbyVision: nil,
            audio: [AudioStreamInfo(index: 1, codec: "eac3", channels: 6, language: "jpn"),
                    AudioStreamInfo(index: 2, codec: "eac3", channels: 6, language: "eng")],
            subtitles: subs, durationSec: 3600, seekable: true, videoStreamCount: 1, fontAttachmentCount: fonts
        )
    }

    func testForcedPlanFollowsThePreferredNonFirstAudioTrack() {
        let p = dualAudioProbe([sub(3, "ass", "eng", isForced: true)], fonts: 2)
        XCTAssertEqual(AetherSubtitleRouting.effectiveAudioTrack(probe: p, preferredAudioTargets: ["eng"])?.index, 2)
        XCTAssertTrue(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["eng"], subtitlesOff: false,
                                                                    useForcedSubtitles: true, preferredAudioTargets: ["eng"]),
                      "English audio is selected, so the forced English ASS track plays")
        XCTAssertFalse(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["eng"], subtitlesOff: false,
                                                                     useForcedSubtitles: true, preferredAudioTargets: ["jpn"]),
                       "Japanese audio: no forced English pick")
    }

    func testRouterSendsThePreferredAudioForcedAssToMpv() {
        let p = dualAudioProbe([sub(3, "ass", "eng", isForced: true)], fonts: 2)
        var options = AetherRoutingOptions(enabled: true)
        options.preferredSubtitleTargets = ["eng"]
        options.useForcedSubtitles = true
        options.preferredAudioTargets = ["eng"]
        XCTAssertEqual(PlayerEngineRouter.route(probe: p, nativeDVEnabled: false, aether: options).reason, "styled ASS")
    }

    func testSubtitlesOffStillRoutesTheForcedPickOnTheAudioLanguage() {
        // Off + "Use forced subtitles": the shared plan picks forced tracks in the selected audio's language.
        let p = dualAudioProbe([sub(3, "ass", "eng", isForced: true)], fonts: 2)
        XCTAssertTrue(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: [], subtitlesOff: true,
                                                                    useForcedSubtitles: true, preferredAudioTargets: ["eng"]))
        XCTAssertFalse(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: [], subtitlesOff: true,
                                                                     useForcedSubtitles: false, preferredAudioTargets: ["eng"]))
    }

    // Review r3: with no matching audio preference the engine starts its `av_find_best_stream` pick,
    // which need not be the first stream.
    func testNoAudioPreferenceFollowsTheContainerDefaultAudio() {
        var p = ProbeResult(
            container: "matroska,webm", videoCodec: "hevc", videoProfile: 0, hdr: .sdr, dolbyVision: nil,
            audio: [AudioStreamInfo(index: 1, codec: "eac3", channels: 6, language: "jpn"),
                    AudioStreamInfo(index: 2, codec: "eac3", channels: 6, language: "fre")],
            subtitles: [sub(3, "ass", "fre", isForced: true)], durationSec: 3600, seekable: true,
            videoStreamCount: 1, fontAttachmentCount: 2
        )
        p.defaultAudioIndex = 2
        XCTAssertEqual(AetherSubtitleRouting.effectiveAudioTrack(probe: p, preferredAudioTargets: ["eng"])?.index, 2)
        XCTAssertTrue(AetherSubtitleRouting.initialTrackIsStyledASS(probe: p, preferredLanguages: ["fre"], subtitlesOff: false,
                                                                    useForcedSubtitles: true, preferredAudioTargets: ["eng"]),
                      "French audio plays, so the forced French ASS track does")
        XCTAssertEqual(AetherSubtitleRouting.effectiveAudioTrack(probe: p, preferredAudioTargets: ["jpn"])?.index, 1,
                       "a matching preference still wins over the default")
    }

    func testNoSubtitleTracksIsNotStyled() {
        XCTAssertFalse(AetherSubtitleRouting.initialTrackIsStyledASS(probe: probe([], fonts: 5), preferredLanguages: ["eng"], subtitlesOff: false))
    }
}
