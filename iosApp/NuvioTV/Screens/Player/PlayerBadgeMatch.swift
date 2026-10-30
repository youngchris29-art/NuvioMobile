import Foundation
import SharedCore

// Player badges for what is playing (upstream 344117e73; badge-pack choice 83e528f00): each engine
// fills a `PlayerBadgeFacts` from what it knows about the playing media, and `PlayerBadgeMatch`
// hands those facts to the shared `PlaybackMatchText.build` and matches the result against the
// player's badge pack (`StreamBadgePresentation.playerBadges`). The top panel shows the chips under
// the title when "Show Badges in Player" is on.
//
// Sources: the native engine reads the remux's HLS signaling and its selected audio track
// (`NativePlaybackCoordinator.badgeFacts()`); mpv reads the selected video/audio entries of its
// track-list walk plus `video-params` (`MPVTVPlayerViewController.walkAndPublishTracks`). Both sample
// when the media is ready and again when the audio track changes, never per tick.

/// What an engine knows about the playing media, as plain values. Unknowns stay nil / empty.
nonisolated struct PlayerBadgeFacts: Equatable, Sendable {
    var videoWidth: Int?
    var videoHeight: Int?
    /// Engine codec name (`hevc`, `h264`, `av1`…); nil when only `videoCodecString` is known.
    var videoCodec: String?
    /// RFC 6381 string or an HLS comma list (`hvc1.2.4.L153.B0,dvh1.08.06`).
    var videoCodecString: String?
    /// `DV`, `PQ`, `HLG`… (any spelling `PlaybackMatchText` accepts).
    var hdr: [String] = []
    var bitDepth: Int?
    var audioCodec: String?
    /// Codec profile or track title (`Dolby Digital Plus + Dolby Atmos`, `DTS-HD MA`).
    var audioProfile: String?
    var audioChannels: Int?
    /// Language tokens of the playing audio track (code and names).
    var languages: [String] = []
    var fileName: String?
    var streamName: String?
}

nonisolated enum PlayerBadgeMatch {

    /// The match string for `facts`, built by the shared `PlaybackMatchText` (every argument passed:
    /// Kotlin defaults do not bridge).
    static func matchText(_ facts: PlayerBadgeFacts) -> String {
        PlaybackMatchText.shared.build(
            videoWidth: facts.videoWidth.map { KotlinInt(int: Int32(clamping: $0)) },
            videoHeight: facts.videoHeight.map { KotlinInt(int: Int32(clamping: $0)) },
            videoCodec: facts.videoCodec,
            videoCodecString: facts.videoCodecString,
            hdr: facts.hdr,
            bitDepth: facts.bitDepth.map { KotlinInt(int: Int32(clamping: $0)) },
            audioCodec: facts.audioCodec,
            audioProfile: facts.audioProfile,
            audioChannels: facts.audioChannels.map { KotlinInt(int: Int32(clamping: $0)) },
            languages: facts.languages,
            fileName: facts.fileName,
            streamName: facts.streamName
        )
    }

    /// The chips the panel shows: none while the setting is off, no pack is imported, the engine
    /// has not reported yet, or the pack matches nothing. Image-less filters are already dropped by
    /// the shared side.
    static func badges(facts: PlayerBadgeFacts?, settings: StreamBadgeSettingsUiState?) -> [StreamBadgeInfo] {
        guard let facts, let settings, settings.showInPlayer, settings.rules.hasImport else { return [] }
        let text = matchText(facts)
        guard !text.isEmpty else { return [] }
        return StreamBadgePresentation.shared
            .playerBadges(rules: settings.rules, playerBadgeSource: settings.playerBadgeSource, matchText: text)
            .map(StreamBadgeInfo.init)
    }

    // MARK: - Helpers both engines use

    /// Language tokens for a track tag: the tag itself, its name in the UI language and in English
    /// (packs are usually written in English), deduplicated. `und` and blank give nothing.
    static func languageTokens(_ tag: String?) -> [String] {
        guard let tag = tag?.trimmingCharacters(in: .whitespaces), !tag.isEmpty,
              tag.lowercased() != "und" else { return [] }
        var out = [tag]
        for locale in [Locale.current, Locale(identifier: "en")] {
            if let name = locale.localizedString(forLanguageCode: tag), !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// The source URL's last path component when it looks like a file name (`Movie.2160p.DV.mkv`),
    /// percent-decoded; nil otherwise.
    static func fileName(from url: URL) -> String? {
        let raw = url.lastPathComponent
        let name = raw.removingPercentEncoding ?? raw
        guard name.contains("."), name != "/" else { return nil }
        return name
    }

    /// The stream's display name: its title and description lines, joined.
    static func streamName(title: String?, subtitle: String?) -> String? {
        let parts = [title, subtitle].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// mpv/FFmpeg pixel formats that are 8 bits per component.
    private static let eightBitPixelFormats: Set<String> = [
        "yuv420p", "yuvj420p", "yuv422p", "yuvj422p", "yuv444p", "yuvj444p", "yuv410p", "yuv411p",
        "nv12", "nv21", "nv16", "nv24", "uyvy422", "yuyv422", "gray", "rgb24", "bgr24", "rgba", "bgra",
        "argb", "abgr", "rgb0", "bgr0", "0rgb", "0bgr",
    ]
    /// Profile names that are 8-bit in H.264 (Baseline/Main/High) and MPEG-2.
    private static let eightBitProfiles: Set<String> = ["baseline", "constrained baseline", "main", "high"]

    /// Bit depth from an mpv pixel format (`yuv420p10le`, `p010`, `nv12`) or codec profile
    /// (`Main 10`, `High`); nil when neither says. The decoded format wins over the profile. An explicit
    /// 8 matters: without it the shared match text assumes 10-bit for any HDR or Dolby Vision media,
    /// which is wrong for Dolby Vision profile 9 (AVC, 8-bit). A bare profile name implies 8 bits only
    /// for codecs whose profiles are 8-bit (see `profileImpliesEightBit`); AV1 Main is 8 or 10 bit, so
    /// its profile name alone never sets a depth.
    static func bitDepth(pixelFormat: String?, codecProfile: String?, codec: String?) -> Int? {
        let format = pixelFormat?.lowercased() ?? ""
        if format.contains("p010") || format.contains("p10") { return 10 }
        if format.contains("p012") || format.contains("p12") { return 12 }
        if eightBitPixelFormats.contains(format) { return 8 }
        let profile = codecProfile?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        if profile.contains("main 10") || profile.contains("10-bit") || profile.contains("high 10") { return 10 }
        if profile.contains("main 12") || profile.contains("12-bit") { return 12 }
        if profileImpliesEightBit(codec: codec, profile: profile) { return 8 }
        return nil
    }

    /// Whether a bare profile name means 8 bits for this codec: H.264 and MPEG-2 (Baseline/Main/High),
    /// HEVC Main only (Main 10 is handled before this). Any other codec, AV1 included, returns false.
    private static func profileImpliesEightBit(codec: String?, profile: String) -> Bool {
        let codec = codec?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        if codec == "h264" || codec.hasPrefix("avc") || codec.hasPrefix("mpeg2") {
            return eightBitProfiles.contains(profile)
        }
        if codec == "hevc" || codec == "h265" || codec.hasPrefix("hev") {
            return profile == "main"
        }
        return false
    }

    /// mpv: a codecs hint for the shared match text. Dolby Vision over AVC (profile 9) is passed as
    /// `dvav`, the AVC Dolby Vision sample entry, so the shared AVC rules see it; nil otherwise.
    static func mpvCodecString(codec: String?, dolbyVisionProfile: Int) -> String? {
        guard dolbyVisionProfile > 0, let codec = codec?.lowercased(),
              codec == "h264" || codec.hasPrefix("avc") else { return nil }
        return "dvav"
    }

    // MARK: - mpv merge (pure, so the tests can drive it)

    /// mpv: the selected video entry merged with the audio entry `aid` of the last walk. nil while
    /// the walk has found neither; the file and stream names fill in when the video entry is missing.
    static func mpvMerged(video: PlayerBadgeFacts?, audio: [Int: PlayerBadgeFacts], aid: Int?,
                          fileName: String?, streamName: String?) -> PlayerBadgeFacts? {
        guard var facts = video ?? (audio.isEmpty ? nil : PlayerBadgeFacts()) else { return nil }
        if facts.fileName == nil, facts.streamName == nil {
            facts.fileName = fileName
            facts.streamName = streamName
        }
        if let aid, let track = audio[aid] {
            facts.audioCodec = track.audioCodec
            facts.audioProfile = track.audioProfile
            facts.audioChannels = track.audioChannels
            facts.languages = track.languages
        }
        return facts
    }

    /// mpv: the video entry after the decoded `video-params` arrive. Size, HDR transfer and bit
    /// depth come from the params; the Dolby Vision flag (a track-list fact) is kept.
    static func mpvVideoParams(_ video: PlayerBadgeFacts, width: Int, height: Int,
                               gamma: String?, pixelFormat: String?) -> PlayerBadgeFacts {
        var out = video
        if width > 0, height > 0 { out.videoWidth = width; out.videoHeight = height }
        out.hdr = mpvHDR(gamma: gamma, dolbyVisionProfile: video.hdr.contains("DV") ? 1 : 0)
        if let depth = bitDepth(pixelFormat: pixelFormat, codecProfile: nil, codec: video.videoCodec) { out.bitDepth = depth }
        return out
    }

    /// HDR flags from mpv's `video-params/gamma` and the track's Dolby Vision profile.
    static func mpvHDR(gamma: String?, dolbyVisionProfile: Int) -> [String] {
        var out: [String] = []
        if dolbyVisionProfile > 0 { out.append("DV") }
        switch gamma?.lowercased() {
        case "pq": out.append("PQ")
        case "hlg": out.append("HLG")
        default: break
        }
        return out
    }
}
