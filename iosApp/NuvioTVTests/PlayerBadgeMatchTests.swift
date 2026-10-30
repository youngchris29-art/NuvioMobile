import SharedCore
import XCTest
@testable import NuvioTV

/// Player badges for what is playing (upstream 344117e73, 83e528f00): the engine-facts adapter
/// through the real SharedCore `PlaybackMatchText`, and the top panel model's badge gate.
@MainActor
final class PlayerBadgeMatchTests: XCTestCase {

    // MARK: - Match text (real SharedCore call)

    func testDolbyVisionEAC3AtmosSample() {
        // What mpv reports for a 4K DV P8 remux with an E-AC-3 JOC track.
        let facts = PlayerBadgeFacts(
            videoWidth: 3840, videoHeight: 2160, videoCodec: "hevc", videoCodecString: nil,
            hdr: PlayerBadgeMatch.mpvHDR(gamma: "pq", dolbyVisionProfile: 8), bitDepth: nil,
            audioCodec: "eac3", audioProfile: "Dolby Digital Plus + Dolby Atmos", audioChannels: 6,
            languages: ["eng", "English"], fileName: nil, streamName: nil)
        XCTAssertEqual(
            PlayerBadgeMatch.matchText(facts),
            "2160p 4K UHD HEVC H.265 H265 x265 DV DoVi Dolby Vision HDR HDR10 10bit DD+ DDP EAC3 Atmos 5.1 eng English")
    }

    func testNativeSignalingDolbyVisionSample() {
        // What the native remux signals: RFC 6381 codecs + DV supplemental codecs + VIDEO-RANGE.
        let facts = PlayerBadgeFacts(
            videoWidth: 3840, videoHeight: 2160, videoCodec: nil,
            videoCodecString: "hvc1.2.4.L153.B0,dvh1.08.06/db1p", hdr: ["DV", "PQ"], bitDepth: nil,
            audioCodec: "eac3", audioProfile: nil, audioChannels: 6, languages: [],
            fileName: "Movie.2160p.DV.mkv", streamName: nil)
        XCTAssertEqual(
            PlayerBadgeMatch.matchText(facts),
            "2160p 4K UHD HEVC H.265 H265 x265 DV DoVi Dolby Vision HDR HDR10 10bit DD+ DDP EAC3 5.1 Movie.2160p.DV.mkv")
    }

    func testBareSDRAACSample() {
        let facts = PlayerBadgeFacts(
            videoWidth: 1920, videoHeight: 1080, videoCodec: "h264", videoCodecString: nil,
            hdr: PlayerBadgeMatch.mpvHDR(gamma: "bt.1886", dolbyVisionProfile: 0), bitDepth: nil,
            audioCodec: "aac", audioProfile: nil, audioChannels: 2, languages: [],
            fileName: nil, streamName: nil)
        XCTAssertEqual(PlayerBadgeMatch.matchText(facts), "1080p FHD AVC H.264 H264 x264 AAC 2.0")
    }

    // MARK: - Helpers

    func testHelpers() {
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: "yuv420p10", codecProfile: nil), 10)
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: "p010", codecProfile: nil), 10)
        XCTAssertEqual(PlayerBadgeMatch.bitDepth(pixelFormat: nil, codecProfile: "Main 10"), 10)
        XCTAssertNil(PlayerBadgeMatch.bitDepth(pixelFormat: "nv12", codecProfile: "Main"))
        XCTAssertEqual(PlayerBadgeMatch.mpvHDR(gamma: "hlg", dolbyVisionProfile: 0), ["HLG"])
        XCTAssertEqual(PlayerBadgeMatch.languageTokens("und"), [])
        XCTAssertEqual(PlayerBadgeMatch.languageTokens("  "), [])
        XCTAssertTrue(PlayerBadgeMatch.languageTokens("eng").contains("English"))
        XCTAssertEqual(PlayerBadgeMatch.fileName(from: URL(string: "https://x.example/dl/My%20Movie.2160p.mkv")!),
                       "My Movie.2160p.mkv")
        XCTAssertNil(PlayerBadgeMatch.fileName(from: URL(string: "https://x.example/play/abc123")!))
        XCTAssertEqual(PlayerBadgeMatch.streamName(title: "Torrentio 4K", subtitle: " "), "Torrentio 4K")
        XCTAssertNil(PlayerBadgeMatch.streamName(title: nil, subtitle: ""))
    }

    // MARK: - mpv merge

    func testMPVAudioSwitchPicksTheNewTracksFacts() {
        let video = PlayerBadgeFacts(videoWidth: 3840, videoHeight: 2160, videoCodec: "hevc", hdr: ["DV", "PQ"])
        let audio: [Int: PlayerBadgeFacts] = [
            1: PlayerBadgeFacts(audioCodec: "truehd", audioProfile: "Dolby TrueHD + Dolby Atmos", audioChannels: 8,
                                languages: ["eng", "English"]),
            2: PlayerBadgeFacts(audioCodec: "ac3", audioChannels: 6, languages: ["fra", "French"]),
        ]
        let first = PlayerBadgeMatch.mpvMerged(video: video, audio: audio, aid: 1, fileName: "Film.mkv", streamName: nil)
        XCTAssertEqual(first?.audioCodec, "truehd")
        XCTAssertEqual(first?.audioChannels, 8)
        let switched = PlayerBadgeMatch.mpvMerged(video: video, audio: audio, aid: 2, fileName: "Film.mkv", streamName: nil)
        XCTAssertEqual(switched?.audioCodec, "ac3")
        XCTAssertNil(switched?.audioProfile)
        XCTAssertEqual(switched?.audioChannels, 6)
        XCTAssertEqual(switched?.languages, ["fra", "French"])
        XCTAssertEqual(switched?.hdr, ["DV", "PQ"])
        XCTAssertEqual(switched?.fileName, "Film.mkv")
        // An unknown aid keeps the video facts and adds no audio; nothing walked yet gives nil.
        XCTAssertNil(PlayerBadgeMatch.mpvMerged(video: video, audio: audio, aid: 9, fileName: nil, streamName: nil)?.audioCodec)
        XCTAssertNil(PlayerBadgeMatch.mpvMerged(video: nil, audio: [:], aid: 1, fileName: "Film.mkv", streamName: nil))
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
        XCTAssertNil(plain.bitDepth)
    }

    // MARK: - Panel model gate

    private let atmosFacts = PlayerBadgeFacts(
        videoWidth: 1920, videoHeight: 1080, videoCodec: "h264", audioCodec: "eac3",
        audioProfile: "Dolby Digital Plus + Dolby Atmos", audioChannels: 6)

    private func settings(showInPlayer: Bool, pattern: String, playerSource: String = "") -> StreamBadgeSettingsUiState {
        let filter = StreamBadgeFilter(
            id: "atmos", groupId: "", name: "Atmos", pattern: pattern, imageURL: "https://img.example/atmos.png",
            isEnabled: true, tagColor: "", tagStyle: "", textColor: "", borderColor: "")
        let pack = StreamBadgeImport(sourceUrl: "https://packs.example/fusion.json", filters: [filter], groups: [],
                                     isActive: true)
        return StreamBadgeSettingsUiState(
            rules: StreamBadgeRules(imports: [pack]), showFileSizeBadges: true, showAddonLogo: false,
            showInPlayer: showInPlayer, playerBadgeSource: playerSource, badgePlacement: .bottom,
            backgroundMode: .cinematic, groupingMode: .quality, listOpensWith: .bestPick)
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
