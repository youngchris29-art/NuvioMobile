import Foundation
import SharedCore

// Engine-agnostic playback models shared by every player engine (libmpv today; the native
// AVPlayer path added in later phases). Extracted from MPVPlayerView.swift in Phase 0 of the
// hybrid-player work so both engines — and the router/prober — depend on one set of types.
// See docs/tvos-hybrid-player-plan.md.

/// UserDefaults keys for device-local player tuning (Settings > Playback). Device-specific
/// hardware knobs, deliberately NOT synced.
enum PlayerTuning {
    static let bufferMBKey = "player.bufferMB"
    static let readaheadSecKey = "player.readaheadSec"
    static let matchFrameRateKey = "player.matchFrameRate"
    /// Opt into mpv's `gpu-next` (libplacebo) video output for better HDR tone-mapping. Device-only
    /// (never applied on the simulator, where libplacebo's vo asserts). Applies to the next playback.
    static let enhancedRendererKey = "player.enhancedRenderer"
    /// Route Dolby Vision / native-friendly files to the AVPlayer engine for true DV output.
    /// ON by default since beta.13 (registered in NuvioTVApp.init; docs/tvos-native-player-info-panel-plan.md);
    /// gates all engine routing.
    static let nativeDVKey = "player.nativeDolbyVision"
    /// Sub-setting of the native-DV beta: keep DV Profile 7 FEL files on mpv instead of converting
    /// them to 8.1 (the conversion discards FEL enhancement data; MEL converts losslessly and is
    /// unaffected by this preference).
    static let dvP7FelMpvKey = "player.dvP7FelPreferMpv"
}

/// Everything the player needs to render a stream and record watch progress for it.
struct PlaybackContext: Identifiable {
    let url: URL
    let title: String
    let contentType: String      // "movie" / "series"
    let parentMetaId: String
    let videoId: String
    let season: Int?
    let episode: Int?
    let poster: String?
    let background: String?
    let providerName: String?
    let providerAddonId: String?
    let streamTitle: String?
    let streamSubtitle: String?
    let externalSubtitles: [SubtitleFile]
    /// Binge group of the playing stream (steers next-episode auto-select toward the same release).
    var bingeGroup: String? = nil
    /// All episodes of the parent series (empty for movies) — enables next-episode autoplay.
    var episodes: [MetaVideo] = []
    /// Title/episode synopsis for the native player's Info tab header (nil when the launch path
    /// has no meta at hand — the header simply omits it).
    var synopsis: String? = nil
    /// 16:9 episode still for the native player's Info tab header. Kept apart from `poster`,
    /// which stays the catalog/series poster (the progress recorder persists `poster` as the
    /// parent artwork — a still must never leak into it). nil → the header shows `poster`.
    var episodeStill: String? = nil
    /// Catalog metadata for the player's Info tab chip row (year · runtime · rating · genres). nil
    /// when the launch path has no meta at hand — the chips simply omit them.
    var meta: PlaybackMeta? = nil
    /// Declared file size of the playing stream (addon `behaviorHints.videoSize`), for the Info chips.
    var fileSizeBytes: Int64? = nil
    /// Sanitized HTTP request headers the addon declared for this stream
    /// (`behaviorHints.proxyHeaders.request` via shared `sanitizePlaybackHeaders` — Referer /
    /// User-Agent a scraper CDN requires; GitHub issue #2 "Some video no stream"). Empty for the
    /// overwhelming majority of streams. Consumed by BOTH engines: mpv (`http-header-fields`)
    /// and the native path's FFmpeg source opens (MediaProbe + RemuxSession `headers` option).
    var requestHeaders: [String: String] = [:]

    // Headers join the identity (Codex 2026-08-20 round 3): two sources for the same episode can
    // share a URL but require different headers; StreamPickerView rebuilds the player and
    // PlayerScreen re-keys its probe on this id, so header changes must re-key too or a stale
    // controller keeps the old headers and an auth-gated stream 403s. The joins use ASCII unit /
    // record separators, which `sanitizePlaybackHeaders` guarantees can never appear in a key or
    // value (it rejects all control characters), so the fingerprint is unambiguous — a plain
    // "&"/"=" join could collide on values containing those characters (Codex round 4).
    var id: String {
        let headerFingerprint = requestHeaders.isEmpty
            ? ""
            : "|" + requestHeaders
                .sorted { $0.key < $1.key }
                .map { "\($0.key)\u{1F}\($0.value)" }
                .joined(separator: "\u{1E}")
        return "\(videoId)|\(url.absoluteString)\(headerFingerprint)"
    }
}

/// Title-level catalog facts shown as chips in the player's Info tab.
struct PlaybackMeta: Equatable {
    var year: String? = nil
    var runtime: String? = nil
    var imdbRating: String? = nil
    var ageRating: String? = nil
    var genres: [String] = []

    /// From a full catalog record (Detail / episode shelf launch paths).
    init(details: MetaDetails) {
        func nonEmpty(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }
        year = nonEmpty(details.releaseInfo)
        runtime = nonEmpty(details.runtime)
        imdbRating = nonEmpty(details.imdbRating)
        ageRating = nonEmpty(details.ageRating)
        genres = details.genres
    }

    init(year: String? = nil, runtime: String? = nil, imdbRating: String? = nil,
         ageRating: String? = nil, genres: [String] = []) {
        self.year = year; self.runtime = runtime; self.imdbRating = imdbRating
        self.ageRating = ageRating; self.genres = genres
    }
}

/// An external subtitle file to side-load into the player.
struct SubtitleFile {
    let url: String
    let language: String
    let name: String?
}

/// One selectable audio or subtitle track.
struct PlayerTrack: Identifiable, Equatable {
    let id: Int          // mpv track id; -1 means "off" (subtitles)
    let label: String
    let isSelected: Bool
}

/// A skippable segment (intro/recap/outro) resolved from `SkipIntroRepository`.
struct SkipSegment {
    let start: Double
    let end: Double
    let type: String
}

/// The currently-offered skip action (shown while playback is inside a `SkipSegment`).
struct SkipPrompt: Equatable {
    let label: String      // e.g. "Skip Intro"
    let targetSec: Double   // absolute seek target (segment end)
}

/// Live stream diagnostics read from libmpv properties (shown by the Stream Info overlay).
struct StreamInfoSnapshot: Equatable {
    /// Router decision label ("Native · DV P8.1" / "mpv · audio truehd"). Diagnostic only in Phase 1.
    var engine = ""
    var videoCodec = ""
    var resolution = ""
    var fps = ""
    var hwdec = ""
    var videoBitrate = ""
    var audio = ""
    var cache = ""

    var rows: [(String, String)] {
        [(String(localized: "Engine"), engine), (String(localized: "Video"), videoCodec),
         (String(localized: "Resolution"), resolution), (String(localized: "Frame rate"), fps),
         (String(localized: "Hardware decode"), hwdec), (String(localized: "Video bitrate"), videoBitrate),
         (String(localized: "Audio"), audio), (String(localized: "Cache"), cache)].filter { !$0.1.isEmpty }
    }
}
