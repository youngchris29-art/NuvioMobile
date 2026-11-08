import SharedCore
import XCTest
@testable import NuvioTV

/// Player badges for what is playing (upstream 344117e73, 83e528f00, a744911a): the engine-facts
/// adapter through the real SharedCore `PlaybackMatchText`, the two-phase match against the meta
/// candidates, and the top panel model's badge gate.
@MainActor
final class PlayerBadgeMatchTests: XCTestCase {

    // MARK: - Match text (real SharedCore call)

    func testDolbyVisionEAC3AtmosSample() {
        // What mpv reports for a 4K DV P8 remux with an E-AC-3 JOC track.
        let facts = PlayerBadgeFacts(
            videoWidth: 3840, videoHeight: 2160, videoCodec: "hevc", videoCodecString: nil,
            hdr: PlayerBadgeMatch.mpvHDR(gamma: "pq", dolbyVisionProfile: 8), bitDepth: nil,
            audioCodec: "eac3", audioProfiles: ["Dolby Digital Plus + Dolby Atmos"], audioChannels: 6,
            languages: ["eng", "English"])
        XCTAssertEqual(
            PlayerBadgeMatch.matchText(facts),
            "2160p 4K UHD HEVC H.265 H265 x265 DV DoVi Dolby Vision HDR HDR10 10bit DD+ DDP EAC3 Atmos 5.1 eng English")
    }

    func testNativeSignalingDolbyVisionSample() {
        // What the native remux signals: RFC 6381 codecs + DV supplemental codecs + VIDEO-RANGE.
        let facts = PlayerBadgeFacts(
            videoWidth: 3840, videoHeight: 2160, videoCodec: nil,
            videoCodecString: "hvc1.2.4.L153.B0,dvh1.08.06/db1p", hdr: ["DV", "PQ"], bitDepth: nil,
            audioCodec: "eac3", audioProfiles: [], audioChannels: 6, languages: [],
            metaCandidates: ["Movie.2160p.DV.mkv"])
        // The file name is a meta candidate, never part of the decoder's match text.
        XCTAssertEqual(
            PlayerBadgeMatch.matchText(facts),
            "2160p 4K UHD HEVC H.265 H265 x265 DV DoVi Dolby Vision HDR HDR10 10bit DD+ DDP EAC3 5.1")
    }

    func testBareSDRAACSample() {
        let facts = PlayerBadgeFacts(
            videoWidth: 1920, videoHeight: 1080, videoCodec: "h264", videoCodecString: nil,
            hdr: PlayerBadgeMatch.mpvHDR(gamma: "bt.1886", dolbyVisionProfile: 0), bitDepth: nil,
            audioCodec: "aac", audioProfiles: [], audioChannels: 2, languages: [])
        XCTAssertEqual(PlayerBadgeMatch.matchText(facts), "1080p FHD AVC H.264 H264 x264 AAC 2.0")
    }

    /// What mpv reports for Dolby Vision profile 9 (DV over AVC, 8-bit base layer).
    func testDolbyVisionOverAVCIsNotTenBit() {
        let facts = PlayerBadgeFacts(
            videoWidth: 1920, videoHeight: 1080, videoCodec: "h264",
            videoCodecString: PlayerBadgeMatch.mpvCodecString(codec: "h264", dolbyVisionProfile: 9),
            hdr: PlayerBadgeMatch.mpvHDR(gamma: "bt.1886", dolbyVisionProfile: 9),
            bitDepth: PlayerBadgeMatch.bitDepth(pixelFormat: "yuv420p", codecProfile: "High", codec: "h264"))
        let tokens = PlayerBadgeMatch.matchText(facts).split(separator: " ").map(String.init)
        XCTAssertTrue(tokens.contains("DV"))
        XCTAssertTrue(tokens.contains("AVC"))
        XCTAssertFalse(tokens.contains("10bit"))
        XCTAssertFalse(tokens.contains("HEVC"))
    }

    /// Dolby Vision profile 8 (HEVC Main 10 base) keeps its 10-bit chip.
    func testDolbyVisionProfile8StaysTenBit() {
        let facts = PlayerBadgeFacts(
            videoWidth: 3840, videoHeight: 2160, videoCodec: "hevc",
            videoCodecString: PlayerBadgeMatch.mpvCodecString(codec: "hevc", dolbyVisionProfile: 8),
            hdr: PlayerBadgeMatch.mpvHDR(gamma: "pq", dolbyVisionProfile: 8),
            bitDepth: PlayerBadgeMatch.bitDepth(pixelFormat: "yuv420p10le", codecProfile: "Main 10", codec: "hevc"))
        let tokens = PlayerBadgeMatch.matchText(facts).split(separator: " ").map(String.init)
        XCTAssertTrue(tokens.contains("DV"))
        XCTAssertTrue(tokens.contains("HDR10"))
        XCTAssertTrue(tokens.contains("10bit"))
    }

    /// AV1 Main is 8 or 10 bit: with no pixel format the profile name sets no depth, so the shared
    /// default (10-bit for HDR10) stays in the match text.
    func testAV1MainProfileDoesNotImplyEightBit() {
        XCTAssertNil(PlayerBadgeMatch.bitDepth(pixelFormat: nil, codecProfile: "Main", codec: "av1"))
        let facts = PlayerBadgeFacts(
            videoWidth: 3840, videoHeight: 2160, videoCodec: "av1",
            hdr: ["HDR10"], bitDepth: PlayerBadgeMatch.bitDepth(pixelFormat: nil, codecProfile: "Main", codec: "av1"))
        let tokens = PlayerBadgeMatch.matchText(facts).split(separator: " ").map(String.init)
        XCTAssertTrue(tokens.contains("10bit"))
    }

    /// H.264 Main is 8-bit: the profile name alone is enough.
    func testH264MainProfileIsEightBit() {
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: nil, codecProfile: "Main", codec: "h264"), 8)
    }

    // MARK: - Helpers

    func testHelpers() {
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: "yuv420p10", codecProfile: nil, codec: "hevc"), 10)
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: "p010", codecProfile: nil, codec: "hevc"), 10)
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: nil, codecProfile: "Main 10", codec: "hevc"), 10)
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: "nv12", codecProfile: "Main 10", codec: "hevc"), 8,
                       "decoded format wins")
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: "yuvj420p", codecProfile: nil, codec: nil), 8)
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: "videotoolbox", codecProfile: "High", codec: "h264"), 8)
        XCTAssertNil(PlayerBadgeMatch.bitDepth(pixelFormat: "videotoolbox", codecProfile: nil, codec: "h264"))
        XCTAssertNil(PlayerBadgeMatch.bitDepth(pixelFormat: "videotoolbox", codecProfile: "High", codec: nil))
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: nil, codecProfile: "Main", codec: "hevc"), 8)
        XCTAssertEqual(PlayerBadgeMatch.mpvCodecString(codec: "h264", dolbyVisionProfile: 9), "dvav")
        XCTAssertNil(PlayerBadgeMatch.mpvCodecString(codec: "hevc", dolbyVisionProfile: 8))
        XCTAssertNil(PlayerBadgeMatch.mpvCodecString(codec: "h264", dolbyVisionProfile: 0))
        XCTAssertEqual(PlayerBadgeMatch.mpvHDR(gamma: "hlg", dolbyVisionProfile: 0), ["HLG"])
        XCTAssertEqual(PlayerBadgeMatch.languageTokens("und"), [])
        XCTAssertEqual(PlayerBadgeMatch.languageTokens("  "), [])
        XCTAssertTrue(PlayerBadgeMatch.languageTokens("eng").contains("English"))
        XCTAssertEqual(PlayerBadgeMatch.fileName(from: URL(string: "https://x.example/dl/My%20Movie.2160p.mkv")!),
                       "My Movie.2160p.mkv")
        XCTAssertNil(PlayerBadgeMatch.fileName(from: URL(string: "https://x.example/play/abc123")!))
    }

    func testMetaCandidatesKeepFileNameTitleAndSubtitleApart() {
        let url = URL(string: "https://x.example/dl/Film.2160p.Remux.mkv")!
        // The add-on's file name wins over the URL's; each line stays its own candidate.
        XCTAssertEqual(
            PlayerBadgeMatch.metaCandidates(addonFileName: "Film.2160p.WEB-DL.DDP5.1.Atmos.mkv", url: url,
                                            title: "Torrentio 4K", subtitle: " 💾 12 GB \n"),
            ["Film.2160p.WEB-DL.DDP5.1.Atmos.mkv", "Torrentio 4K", "💾 12 GB"])
        XCTAssertEqual(
            PlayerBadgeMatch.metaCandidates(addonFileName: "  ", url: url, title: nil, subtitle: ""),
            ["Film.2160p.Remux.mkv"])
        XCTAssertEqual(
            PlayerBadgeMatch.metaCandidates(addonFileName: nil, url: URL(string: "https://x.example/play/abc")!,
                                            title: "Torrentio 4K", subtitle: nil),
            ["Torrentio 4K"])
    }

    // MARK: - mpv merge

    func testMPVAudioSwitchPicksTheNewTracksFacts() {
        let video = PlayerBadgeFacts(videoWidth: 3840, videoHeight: 2160, videoCodec: "hevc", hdr: ["DV", "PQ"])
        let audio: [Int: PlayerBadgeFacts] = [
            1: PlayerBadgeFacts(audioCodec: "truehd", audioProfiles: ["Dolby TrueHD + Dolby Atmos", "English"],
                                audioChannels: 8, languages: ["eng", "English"]),
            2: PlayerBadgeFacts(audioCodec: "ac3", audioChannels: 6, languages: ["fra", "French"]),
        ]
        let first = PlayerBadgeMatch.mpvMerged(video: video, audio: audio, aid: 1, metaCandidates: ["Film.mkv"])
        XCTAssertEqual(first?.audioCodec, "truehd")
        XCTAssertEqual(first?.audioProfiles, ["Dolby TrueHD + Dolby Atmos", "English"])
        XCTAssertEqual(first?.audioChannels, 8)
        let switched = PlayerBadgeMatch.mpvMerged(video: video, audio: audio, aid: 2,
                                                  metaCandidates: ["Film.mkv", "Torrentio 4K"])
        XCTAssertEqual(switched?.audioCodec, "ac3")
        XCTAssertEqual(switched?.audioProfiles, [])
        XCTAssertEqual(switched?.audioChannels, 6)
        XCTAssertEqual(switched?.languages, ["fra", "French"])
        XCTAssertEqual(switched?.hdr, ["DV", "PQ"])
        XCTAssertEqual(switched?.metaCandidates, ["Film.mkv", "Torrentio 4K"])
        // The video entry's own candidates win over the ones passed in.
        var named = video
        named.metaCandidates = ["Walked.mkv"]
        XCTAssertEqual(PlayerBadgeMatch.mpvMerged(video: named, audio: audio, aid: 1, metaCandidates: ["Film.mkv"])?
            .metaCandidates, ["Walked.mkv"])
        // An unknown aid keeps the video facts and adds no audio; nothing walked yet gives nil.
        XCTAssertNil(PlayerBadgeMatch.mpvMerged(video: video, audio: audio, aid: 9, metaCandidates: [])?.audioCodec)
        XCTAssertNil(PlayerBadgeMatch.mpvMerged(video: nil, audio: [:], aid: 1, metaCandidates: ["Film.mkv"]))
    }

    func testMPVVideoParamsRefreshKeepsDolbyVision() {
        // The walk ran before the first frame: DV from the track entry, size from the demuxer.
        let video = PlayerBadgeFacts(videoWidth: 3840, videoHeight: 2160, videoCodec: "hevc",
                                     hdr: PlayerBadgeMatch.mpvHDR(gamma: nil, dolbyVisionProfile: 8))
        let refreshed = PlayerBadgeMatch.mpvVideoParams(video, width: 3840, height: 1600, gamma: "pq",
                                                        pixelFormat: "p010")
        XCTAssertEqual(refreshed.hdr, ["DV", "PQ"])
        XCTAssertEqual(refreshed.bitDepth, 10)
        XCTAssertEqual(refreshed.videoHeight, 1600)
        XCTAssertEqual(refreshed.videoCodec, "hevc")
        // A non-DV track gains only the transfer; zero params keep the demuxer size.
        let plain = PlayerBadgeMatch.mpvVideoParams(PlayerBadgeFacts(videoWidth: 1920, videoHeight: 1080),
                                                    width: 0, height: 0, gamma: "hlg", pixelFormat: "nv12")
        XCTAssertEqual(plain.hdr, ["HLG"])
        XCTAssertEqual(plain.videoWidth, 1920)
        XCTAssertEqual(plain.bitDepth, 8)
    }

    // MARK: - Two-phase match (real SharedCore call)

    /// A pack of (name, pattern, groupId) filters, every one with an image.
    private func groupedSettings(_ filters: [(String, String, String)]) -> StreamBadgeSettingsUiState {
        let packFilters = filters.map { name, pattern, group in
            StreamBadgeFilter(
                id: name, groupId: group, name: name, pattern: pattern, imageURL: "https://img.example/\(name).png",
                isEnabled: true, tagColor: "", tagStyle: "", textColor: "", borderColor: "")
        }
        let pack = StreamBadgeImport(sourceUrl: "https://packs.example/grouped.json", filters: packFilters, groups: [],
                                     isActive: true)
        return StreamBadgeSettingsUiState(
            rules: StreamBadgeRules(imports: [pack]), showFileSizeBadges: true, showAddonLogo: false,
            showInPlayer: true, playerBadgeSource: "", badgePlacement: .bottom,
            backgroundMode: .cinematic, groupingMode: .quality, listOpensWith: .bestPick,
            sourceLayout: .twoPane, rowText: .nuvio)
    }

    private func names(_ facts: PlayerBadgeFacts, _ settings: StreamBadgeSettingsUiState) -> [String] {
        PlayerBadgeMatch.badges(facts: facts, settings: settings).map(\.name)
    }

    /// The file name's Atmos refines an E-AC-3 decode (the decoder covers the audio group, so the
    /// file name alone could not add it), but never an AAC one.
    func testFileNameAtmosRefinesAnEAC3Decode() {
        let settings = groupedSettings([
            ("DD+", #"(?i)\b(DD\+|DDP|EAC3)"#, "audio"),
            ("AAC", #"(?i)\bAAC\b"#, "audio"),
            ("Atmos", #"(?i)\batmos\b"#, "audio"),
        ])
        let meta = ["Film.2160p.WEB-DL.DDP5.1.Atmos.mkv"]
        let eac3 = PlayerBadgeFacts(audioCodec: "eac3", audioChannels: 6, metaCandidates: meta)
        XCTAssertEqual(names(eac3, settings), ["DD+", "Atmos"])
        let aac = PlayerBadgeFacts(audioCodec: "aac", audioChannels: 2, metaCandidates: meta)
        XCTAssertEqual(names(aac, settings), ["AAC"], "a decoder-covered group ignores the file name")
    }

    /// The decoder's DTS and German cover their groups, so the file name's TrueHD and English are
    /// dropped; WEB-DL is in a group the decoder never covers and still comes from the file name.
    func testDecoderGroupsExcludeTheFileNameButOtherGroupsStillMatch() {
        let settings = groupedSettings([
            ("WEB-DL", #"(?i)\bweb[-. ]?dl\b"#, "source"),
            ("TrueHD", #"(?i)\btrue[-. ]?hd\b"#, "audio"),
            ("DTS", #"(?i)\bdts\b"#, "audio"),
            ("DTS-HD MA", #"(?i)\bdts-hd[ .]?ma\b"#, "audio"),
            ("English", #"(?i)\b(eng|english)\b"#, "language"),
            ("German", #"(?i)\b(ger|german)\b"#, "language"),
        ])
        let facts = PlayerBadgeFacts(
            audioCodec: "dts", audioProfiles: ["DTS-HD HRA", "German"], audioChannels: 8,
            languages: ["ger", "German"], metaCandidates: ["Film.2160p.WEB-DL.TrueHD.ENG.mkv", "Torrentio"])
        XCTAssertEqual(names(facts, settings), ["WEB-DL", "DTS", "German"])
        // The remux's profile (or a title) saying Master Audio gives the MA chip.
        var ma = facts
        ma.audioProfiles = ["DTS-HD MA", "German"]
        XCTAssertEqual(names(ma, settings), ["WEB-DL", "DTS", "DTS-HD MA", "German"])
        // A release named for its English MA track never puts MA on the German HRA dub: the decoder
        // named the variant.
        var named = facts
        named.metaCandidates = ["Film.German.DL.2160p.WEB-DL.DTS-HD.MA.7.1.mkv"]
        XCTAssertEqual(names(named, settings), ["WEB-DL", "DTS", "German"])
        // A title that says DTS-HD without naming the variant leaves it to the file name.
        var untitled = named
        untitled.audioProfiles = ["German DTS-HD 7.1"]
        XCTAssertEqual(names(untitled, settings), ["WEB-DL", "DTS", "DTS-HD MA", "German"])
    }

    // MARK: - Panel model gate

    private let atmosFacts = PlayerBadgeFacts(
        videoWidth: 1920, videoHeight: 1080, videoCodec: "h264", audioCodec: "eac3",
        audioProfiles: ["Dolby Digital Plus + Dolby Atmos"], audioChannels: 6)

    private func settings(showInPlayer: Bool, pattern: String, playerSource: String = "") -> StreamBadgeSettingsUiState {
        let filter = StreamBadgeFilter(
            id: "atmos", groupId: "", name: "Atmos", pattern: pattern, imageURL: "https://img.example/atmos.png",
            isEnabled: true, tagColor: "", tagStyle: "", textColor: "", borderColor: "")
        let pack = StreamBadgeImport(sourceUrl: "https://packs.example/fusion.json", filters: [filter], groups: [],
                                     isActive: true)
        return StreamBadgeSettingsUiState(
            rules: StreamBadgeRules(imports: [pack]), showFileSizeBadges: true, showAddonLogo: false,
            showInPlayer: showInPlayer, playerBadgeSource: playerSource, badgePlacement: .bottom,
            backgroundMode: .cinematic, groupingMode: .quality, listOpensWith: .bestPick,
            sourceLayout: .twoPane, rowText: .nuvio)
    }

    private func model() -> PlayerTopPanelModel {
        let context = PlaybackContext(
            url: URL(string: "https://cdn.example.com/a.mkv")!, title: "Film", contentType: "movie",
            parentMetaId: "tt1", videoId: "tt1", season: nil, episode: nil, poster: nil,
            background: nil, providerName: nil, providerAddonId: nil,
            streamTitle: nil, streamSubtitle: nil, externalSubtitles: [])
        return PlayerTopPanelModel(info: PlayerPanelInfo(header: NativeInfoHeader(context: context)))
    }

    func testPanelShowsMatchedBadgesWhenOn() {
        let m = model()
        m.setBadgeSettings(settings(showInPlayer: true, pattern: "Atmos"))
        XCTAssertEqual(m.info.badges, [], "no badges before the engine reports")
        m.setBadgeFacts(atmosFacts)
        XCTAssertEqual(m.info.badges.map(\.name), ["Atmos"])
        XCTAssertEqual(m.info.badges.first?.imageURL, "https://img.example/atmos.png")
    }

    func testPanelHasNoBadgesWhenSettingOff() {
        let m = model()
        m.setBadgeFacts(atmosFacts)
        m.setBadgeSettings(settings(showInPlayer: false, pattern: "Atmos"))
        XCTAssertEqual(m.info.badges, [])
        // Turning it on shows them; off again hides them.
        m.setBadgeSettings(settings(showInPlayer: true, pattern: "Atmos"))
        XCTAssertEqual(m.info.badges.count, 1)
        m.setBadgeSettings(settings(showInPlayer: false, pattern: "Atmos"))
        XCTAssertEqual(m.info.badges, [])
    }

    func testPanelHasNoBadgesWhenRulesMatchNothing() {
        let m = model()
        m.setBadgeSettings(settings(showInPlayer: true, pattern: "TrueHD"))
        m.setBadgeFacts(atmosFacts)
        XCTAssertEqual(m.info.badges, [])
    }

    func testUnknownPlayerSourceFallsBackToStreamPack() {
        let m = model()
        m.setBadgeSettings(settings(showInPlayer: true, pattern: "Atmos", playerSource: "https://gone.example/old.json"))
        m.setBadgeFacts(atmosFacts)
        XCTAssertEqual(m.info.badges.map(\.name), ["Atmos"])
    }
}
