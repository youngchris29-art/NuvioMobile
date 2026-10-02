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

    /// True when `released` starts with a valid `yyyy-MM-dd` date that is on or before today.
    /// nil, short or malformed values are not aired.
    static func isAired(released: String?, todayIsoDate: String) -> Bool {
        guard let released else { return false }
        let trimmed = released.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return false }
        let date = String(trimmed.prefix(10))
        guard isIsoDate(date) else { return false }
        return date <= String(todayIsoDate.prefix(10))
    }

    static func hidesSpoilers(settingOn: Bool, isWatched: Bool) -> Bool {
        settingOn && !isWatched
    }

    /// Episodes with both numbers, already aired, whose "season:episode" key is not in `watchedKeys`.
    static func airedUnwatchedCount(
        _ episodes: [EpisodeFacts],
        watchedKeys: Set<String>,
        todayIsoDate: String
    ) -> Int {
        episodes.reduce(0) { total, facts in
            guard let s = facts.season, let e = facts.episode else { return total }
            guard isAired(released: facts.released, todayIsoDate: todayIsoDate) else { return total }
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
