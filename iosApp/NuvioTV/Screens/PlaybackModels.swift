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
    /// Who started this playback (orivio batch item 2): a viewer's own pick, the picker's
    /// first-play auto-start, or the Up Next engine. Decides what a playback failure does next
    /// (`PlaybackFailoverPolicy.response(for:)`), and the engines treat a placeholder clip as a
    /// failure only outside `.manual`.
    var launchSource: PlaybackLaunchSource = .manual
    /// `StreamItem.playbackStreamKey` of the stream as LISTED (before any debrid resolve), so a
    /// failure can be remembered against the link the pickers will see again. Empty for the test
    /// stream and launch paths without a stream (Library, smoke tests): those are never remembered.
    var streamKey: String = ""
    /// "Start Over": both engines ignore saved progress for this playback.
    var startFromBeginning: Bool = false
    /// Failover attempt index for this visit (0 = first try). Joins `id` only when > 0, so two
    /// candidates that resolve to the same URL still rebuild the player (and re-key the cover).
    var attempt: Int = 0
    /// The stream as listed (pre-resolve), so a failed debrid link's 15-minute resolve cache entry
    /// can be dropped (`DirectDebridPlaybackResolver.invalidate` is keyed on the listed stream).
    /// nil on launch paths without a stream.
    var listedStream: StreamItem? = nil

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
        let attemptSuffix = attempt > 0 ? "|a\(attempt)" : ""
        return "\(videoId)|\(url.absoluteString)\(headerFingerprint)\(attemptSuffix)"
    }
}

/// Who started a playback (see `PlaybackContext.launchSource`).
enum PlaybackLaunchSource: Equatable {
    /// The viewer picked the stream (a picker row, "Try Next Source", the in-player source list).
    case manual
    /// The stream picker's first-play auto-start (`FirstPlayAutoPlayController`).
    case autoPlay
    /// The Up Next engine's next episode (`NextEpisodeEngine.makeNextContext`).
    case nextEpisode
}

/// A playback that failed, as reported by either engine through `PlayerScreen.onPlaybackFailed`:
/// the media never started, mpv hit a load error, a placeholder clip played in an automatic flow,
/// or the stream ended well before its duration.
struct PlaybackFailure: Equatable {
    /// Engine-side diagnostic, shown verbatim in the manual-pick alert.
    let reason: String
    let positionSec: Double
    /// Seconds actually played (native seconds before a fallback included).
    let secondsPlayed: Double
    let startedPlaying: Bool
}

/// The pure decisions behind next-link failover (orivio batch item 2). The picker and the Up Next
/// engine act on these; `PlaybackFailoverPolicyTests` pins them.
enum PlaybackFailoverPolicy {
    /// A link that played this long is healthy: its failure is not remembered, and reaching it
    /// clears an earlier rejection (`RejectedStreamLinks.keep`).
    static let healthySeconds: Double = 300
    /// Candidates an automatic flow may try per picker visit (first start + failovers).
    static let maxAutoAttempts = 4

    /// What the picker does when a playback it presented fails.
    enum Response: Equatable {
        /// Swap the next auto-play candidate into the open player.
        case autoFailover
        /// Close the player and open a stream picker for the episode that failed.
        case nextEpisodePicker
        /// Close the player and offer "Try Next Source" / "Back to Sources".
        case manualAlert
    }

    static func response(for source: PlaybackLaunchSource) -> Response {
        switch source {
        case .autoPlay: return .autoFailover
        case .nextEpisode: return .nextEpisodePicker
        case .manual: return .manualAlert
        }
    }

    /// Remember the failed link only when it never got going: a source that played for five
    /// minutes and then died is not a bad link.
    static func shouldReject(_ failure: PlaybackFailure) -> Bool {
        failure.secondsPlayed < healthySeconds
    }

    static func shouldKeep(secondsPlayed: Double) -> Bool {
        secondsPlayed >= healthySeconds
    }

    /// A short placeholder clip (debrid "caching" stubs, error videos) counts as a failure only in
    /// an automatic flow; a viewer who picked that link gets what they picked.
    static func treatsPlaceholderClipAsFailure(_ source: PlaybackLaunchSource) -> Bool {
        source != .manual
    }

    /// One listed stream, reduced to what the manual "Try Next Source" choice needs.
    struct Entry: Equatable {
        let key: String
        let addonId: String
    }

    /// Index in `entries` (the list in display order) of the stream "Try Next Source" plays after
    /// `failedKey`: only streams AFTER the failed one, the same add-on's first, then the rest in
    /// list order; rejected keys and the failed key itself are skipped. A failed key that is no
    /// longer in the list (it reloaded) considers the whole list. nil = nothing left to try.
    static func nextManualIndex(entries: [Entry], failedKey: String, failedAddonId: String?,
                                rejected: Set<String>) -> Int? {
        let start = entries.firstIndex { $0.key == failedKey }.map { $0 + 1 } ?? 0
        guard start < entries.count else { return nil }
        let eligible = (start..<entries.count).filter { index in
            let key = entries[index].key
            return !key.isEmpty && key != failedKey && !rejected.contains(key)
        }
        if let failedAddonId, let sameAddon = eligible.first(where: { entries[$0].addonId == failedAddonId }) {
            return sameAddon
        }
        return eligible.first
    }
}

/// The key a stream link is remembered under (`RejectedStreamLinks`, `PlaybackContext.streamKey`).
/// Shared by the stream picker, its auto-play controller and the Up Next engine so all three agree.
enum PlaybackStreamKey {
    /// `infoHash#fileIdx` for torrent / debrid candidates (the same torrent from two add-ons is the
    /// same file), else `addonId|host+path` of the stream URL — never the full URL, whose query
    /// usually carries a session token — else `addonId|label` for a stream with neither. Built
    /// from the stream as listed: a debrid resolve's per-session link must not be the identity.
    static func make(infoHash: String?, fileIdx: Int?, addonId: String, url: String?, label: String) -> String {
        if let hash = infoHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !hash.isEmpty {
            return "\(hash)#\(fileIdx.map(String.init) ?? "")"
        }
        if let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let components = URLComponents(string: raw), let host = components.host, !host.isEmpty {
                return "\(addonId)|\(host.lowercased())\(components.path)"
            }
            let bare = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? raw
            let noFragment = bare.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? bare
            return "\(addonId)|\(noFragment)"
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { return "" }
        return "\(addonId)|\(trimmedLabel)"
    }
}

extension StreamItem {
    /// See `PlaybackStreamKey.make`. Uses the shared `p2pInfoHash` (top-level hash, the
    /// `clientResolve` hash, a magnet or a `torrent://` URL, normalised) and the matching file index.
    var playbackStreamKey: String {
        let hash: String? = p2pInfoHash
        let index: Int? = p2pFileIdx?.intValue ?? clientResolve?.fileIdx?.intValue
        let rawUrl: String? = url
        let rawExternal: String? = externalUrl
        let rawName: String? = name
        return PlaybackStreamKey.make(
            infoHash: hash,
            fileIdx: index,
            addonId: addonId,
            url: rawUrl ?? rawExternal,
            label: rawName ?? ""
        )
    }
}

/// Title-level catalog facts shown as chips in the player's Info tab.
struct PlaybackMeta: Equatable {
    var year: String? = nil
    var runtime: String? = nil
    var imdbRating: String? = nil
    var ageRating: String? = nil
    var genres: [String] = []
    /// The title's original language (ISO 639-1) for the "Original" audio preference, resolved the
    /// same way upstream's `resolveLaunchContentLanguage` does (TMDB `original_language`, with the
    /// production country as a tie-break for pt/es/zh variants). nil when the launch path has no
    /// catalog record — the players then fall back to `MetaDetailsRepository.peek`.
    var originalLanguage: String? = nil

    /// From a full catalog record (Detail / episode shelf launch paths).
    init(details: MetaDetails) {
        func nonEmpty(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }
        year = nonEmpty(details.releaseInfo)
        runtime = nonEmpty(details.runtime)
        imdbRating = nonEmpty(details.imdbRating)
        ageRating = nonEmpty(details.ageRating)
        genres = details.genres
        originalLanguage = PlayerLanguagePreferencesKt.resolveContentLanguage(
            language: details.language, country: details.country
        )
    }

    init(year: String? = nil, runtime: String? = nil, imdbRating: String? = nil,
         ageRating: String? = nil, genres: [String] = [], originalLanguage: String? = nil) {
        self.year = year; self.runtime = runtime; self.imdbRating = imdbRating
        self.ageRating = ageRating; self.genres = genres; self.originalLanguage = originalLanguage
    }

    /// Minutes in a catalog runtime string ("1h 30m", "90 min", "1:30", "90"); nil when it has
    /// none. A Swift copy of the shared `parseRuntimeMinutes` (internal to SharedCore), used for
    /// the external-player return's duration when no progress entry knows it yet.
    static func runtimeMinutes(_ raw: String?) -> Int? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        func firstInt(_ pattern: String, group: Int = 1) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: group), in: value) else { return nil }
            return Int(value[range])
        }
        if let hours = firstInt(#"^\s*(\d+)\s*:\s*(\d{1,2})\s*$"#),
           let minutes = firstInt(#"^\s*(\d+)\s*:\s*(\d{1,2})\s*$"#, group: 2) {
            return hours * 60 + minutes
        }
        let hoursToken = firstInt(#"(\d+)\s*h(?:ours?)?"#)
        let minutesToken = firstInt(#"(\d+)\s*m(?:in(?:ute)?s?)?"#)
        if hoursToken != nil || minutesToken != nil {
            return max(hoursToken ?? 0, 0) * 60 + max(minutesToken ?? 0, 0)
        }
        return firstInt(#"^\s*(\d+)\s*$"#).map { max($0, 0) }
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
