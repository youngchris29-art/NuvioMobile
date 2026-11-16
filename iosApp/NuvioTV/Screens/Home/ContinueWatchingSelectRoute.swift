import Foundation
import SharedCore

/// W3 (upstream 37e8a5c0e): what selecting a Continue Watching card opens, per Settings › Home
/// Screen › Continue Watching On Select (`ContinueWatchingPreferencesUiState.clickAction`, synced
/// with the phone). `ContinueWatchingRow` asks it on every select, so Classic, Stage and the
/// Library's Resume Watching row follow the same setting. The hold menu's Play Manually and Start
/// Over never come here: they always open the stream.
///
/// Details for Upcoming behaves exactly like Play on tvOS (unaired Up Next cards are dropped), and
/// nothing here ever writes the stored value: only the Settings picker calls `setClickAction`.
enum ContinueWatchingSelectRoute {
    /// The Settings picker's keys (pickers bind strings, not bridged Kotlin enums).
    static let keys = ["stream", "details", "detailsForUpcoming"]

    static func key(_ action: ContinueWatchingClickAction) -> String {
        if action == ContinueWatchingClickAction.details { return "details" }
        if action == ContinueWatchingClickAction.detailsForUpcoming { return "detailsForUpcoming" }
        return "stream"
    }

    static func action(forKey key: String) -> ContinueWatchingClickAction {
        switch key {
        case "details": return ContinueWatchingClickAction.details
        case "detailsForUpcoming": return ContinueWatchingClickAction.detailsForUpcoming
        default: return ContinueWatchingClickAction.stream
        }
    }

    static func label(forKey key: String) -> String {
        switch key {
        case "details": return String(localized: "Details")
        case "detailsForUpcoming": return String(localized: "Details for Upcoming")
        default: return String(localized: "Play")
        }
    }

    /// Live: the stored preference and the shared rule.
    @MainActor static func opensDetails(_ entry: WatchProgressEntry) -> Bool {
        ContinueWatchingPreferencesRepository.shared.ensureLoaded()
        let state = ContinueWatchingPreferencesRepository.shared.uiState.value_ as? ContinueWatchingPreferencesUiState
        return opensDetails(entry, action: state?.clickAction ?? ContinueWatchingClickAction.stream, now: Date())
    }

    /// The release instant is unknown on a tvOS card (nil): unaired Up Next cards are dropped
    /// (`ContinueWatchingUnairedNextUpPolicy`), so Details for Upcoming plays every card today.
    static func opensDetails(_ entry: WatchProgressEntry, action: ContinueWatchingClickAction, now: Date) -> Bool {
        ContinueWatchingSelect.shared.opensDetails(
            action: action,
            entry: entry,
            releaseAtEpochMs: nil,
            nowEpochMs: Int64(now.timeIntervalSince1970 * 1000)
        )
    }
}
