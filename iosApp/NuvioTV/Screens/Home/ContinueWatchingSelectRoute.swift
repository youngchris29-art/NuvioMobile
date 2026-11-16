import Foundation
import SharedCore

/// W3 (upstream 37e8a5c0e): what selecting a Continue Watching card opens, per Settings › Home
/// Screen › Continue Watching On Select (`ContinueWatchingPreferencesUiState.clickAction`, synced
/// with the phone). `ContinueWatchingRow` asks it on every select, so Classic, Stage and the
/// Library's Resume Watching row follow the same setting. The hold menu's Play Manually and Start
/// Over never come here: they always open the stream.
///
/// Details for Upcoming (set from a phone) behaves exactly like Play on tvOS (unaired Up Next cards
/// are dropped) and the picker shows it as Play. Nothing here ever writes the stored value: only the
/// Settings picker calls `setClickAction`, and it writes `stream` or `details`.
enum ContinueWatchingSelectRoute {
    /// The Settings picker's keys (pickers bind strings, not bridged Kotlin enums). Two values only:
    /// a stored Details for Upcoming displays under the Play key.
    static let keys = ["stream", "details"]

    static func key(_ action: ContinueWatchingClickAction) -> String {
        if action == ContinueWatchingClickAction.details { return "details" }
        return "stream"
    }

    static func action(forKey key: String) -> ContinueWatchingClickAction {
        switch key {
        case "details": return ContinueWatchingClickAction.details
        default: return ContinueWatchingClickAction.stream
        }
    }

    static func label(forKey key: String) -> String {
        switch key {
        case "details": return String(localized: "Details")
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
