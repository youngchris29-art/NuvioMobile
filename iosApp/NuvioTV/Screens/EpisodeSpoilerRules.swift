import CoreGraphics
import Foundation

/// Pure rules for the "Hide Episode Spoilers" Detail setting: which episodes get a blurred still and
/// a hidden synopsis, and the "N aired unwatched" count. No SharedCore or Theme references so the
/// helpers stay `nonisolated` (project default actor isolation is MainActor) and unit-testable.
nonisolated enum EpisodeSpoilerRules {
    /// Must equal `DetailSettingsKeys.hideEpisodeSpoilers` (pinned by a unit test). Default OFF.
    static let defaultsKey = "detail_hide_episode_spoilers"
    static let stillBlurRadius: CGFloat = 28

    struct EpisodeFacts: Equatable {
        let season: Int?
        let episode: Int?
        let released: String?
    }

    /// True when `released` is on or before now. A full ISO-8601 timestamp (`2024-05-01T01:00:00Z`,
    /// with or without fractional seconds, any offset) is compared as an instant against `now`
    /// (review r1 #5: an evening-UTC air date is still tomorrow's date locally for some users and
    /// vice versa). A bare `yyyy-MM-dd` — or anything else starting with one that does not parse as
    /// a timestamp — compares its date against `todayIsoDate`. nil, short or malformed: not aired.
    static func isAired(released: String?, todayIsoDate: String, now: Date = Date()) -> Bool {
        guard let released else { return false }
        let trimmed = released.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return false }
        if trimmed.count > 10, let instant = parseTimestamp(trimmed) {
            return instant <= now
        }
        let date = String(trimmed.prefix(10))
        guard isIsoDate(date) else { return false }
        return date <= String(todayIsoDate.prefix(10))
    }

    /// ISO-8601 date-time with a zone designator (`Z`, `+hh:mm` or `+hhmm`), with or without
    /// fractional seconds. No designator → nil (the caller falls back to the date prefix).
    static func parseTimestamp(_ value: String) -> Date? {
        for style in timestampStyles {
            if let date = try? Date(value, strategy: style) { return date }
        }
        return nil
    }

    private static let timestampStyles: [Date.ISO8601FormatStyle] = [false, true].flatMap { fractional in
        [Date.ISO8601FormatStyle.TimeZoneSeparator.omitted, .colon].map { separator in
            Date.ISO8601FormatStyle(timeZoneSeparator: separator, includingFractionalSeconds: fractional)
        }
    }

    static func hidesSpoilers(settingOn: Bool, isWatched: Bool) -> Bool {
        settingOn && !isWatched
    }

    /// Episodes with both numbers, already aired, whose "season:episode" key is not in `watchedKeys`.
    static func airedUnwatchedCount(
        _ episodes: [EpisodeFacts],
        watchedKeys: Set<String>,
        todayIsoDate: String,
        now: Date = Date()
    ) -> Int {
        episodes.reduce(0) { total, facts in
            guard let s = facts.season, let e = facts.episode else { return total }
            guard isAired(released: facts.released, todayIsoDate: todayIsoDate, now: now) else { return total }
            return watchedKeys.contains("\(s):\(e)") ? total : total + 1
        }
    }

    /// "N aired unwatched"; nil when the setting is off or nothing qualifies.
    static func airedUnwatchedLabel(count: Int, settingOn: Bool) -> String? {
        guard settingOn, count > 0 else { return nil }
        return String(localized: "\(count) aired unwatched")
    }

    private static func isIsoDate(_ s: String) -> Bool {
        let chars = Array(s.utf8)
        guard chars.count == 10 else { return false }
        for (i, c) in chars.enumerated() {
            if i == 4 || i == 7 {
                if c != UInt8(ascii: "-") { return false }
            } else if c < UInt8(ascii: "0") || c > UInt8(ascii: "9") {
                return false
            }
        }
        return true
    }
}
