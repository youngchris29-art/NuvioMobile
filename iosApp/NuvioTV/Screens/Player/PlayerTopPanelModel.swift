import Combine
import SharedCore
import SwiftUI

// Engine-agnostic backing model for the swipe-down top panel (Info · Subtitles · Audio). The native
// AVPlayer screen fills it through `NativePlayerPanelAdapter`; the mpv screen can plug in the same
// way later (its `MPVPlaybackState` already exposes track lists + select closures). Closures rather
// than a protocol keep it a plain ObservableObject the SwiftUI panel can observe directly.

/// One selectable row in the Subtitles or Audio tab.
struct PlayerPanelOption: Identifiable, Equatable {
    enum Group: Equatable { case off, embedded, addon, audio, chapter }
    /// Stable id: the rendition NAME on the native path (AVPlayer keys options by name), the mpv
    /// track id on the mpv path. `"off"` for the Off row.
    let id: String
    let title: String
    /// Secondary line ("Forced", "SDH", addon name…); nil = none.
    var detail: String? = nil
    let group: Group
    var isSelected: Bool
}

/// One capsule in the Info tab's metadata row ("53 min", "4K", "Dolby Vision"…).
struct PlayerPanelChip: Identifiable, Hashable {
    let text: String
    var symbol: String? = nil
    /// Marks the runtime chip so the catalog runtime can stand in until playback reports one.
    var isRuntime = false
    var id: String { text }
}

/// One row of the Chapters tab (both engines). `id` is the chapter's index in the list.
struct PlayerPanelChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let sec: Double
    var isCurrent: Bool
}

/// Info tab content: what's-playing header, metadata chips, live stream rows.
struct PlayerPanelInfo: Equatable {
    var header: NativeInfoHeader
    var chips: [PlayerPanelChip] = []
    var rows: [NativeInfoRow] = []
    /// Badge-pack chips for what is playing (upstream 344117e73), under the title; empty hides the
    /// row. Fed by `PlayerTopPanelModel.setBadgeFacts` / `setBadgeSettings`.
    var badges: [StreamBadgeInfo] = []
}

@MainActor
final class PlayerTopPanelModel: ObservableObject {
    @Published var info: PlayerPanelInfo
    /// Subtitles tab rows in display order: Off first (like the system panel), then the file's own
    /// tracks, then addon-fetched ones. Empty while nothing is known yet.
    @Published var subtitles: [PlayerPanelOption] = []
    /// True until the addon subtitle fetch has finished — drives the "Searching…" empty state.
    @Published var subtitlesSearching = true
    @Published var audio: [PlayerPanelOption] = []
    /// Human name of the current audio output route ("Living Room", "AirPods Pro", "Apple TV").
    @Published var outputRouteName = ""
    /// Whether the Audio tab offers the system route picker (AirPlay/Bluetooth). False on engines
    /// that don't drive AVAudioSession routing.
    @Published var canPickRoute = true
    /// mpv audio effects (P5 B20). nil hides the rows (the native engine).
    @Published var audioEffects: PlayerAudioEffectsState?
    var onAudioBoostChange: ((Int) -> Void)?
    var onAudioModeChange: ((PlayerAudioMode) -> Void)?

    /// Current subtitle delay in milliseconds (0 = none, positive = subtitles later). Meaningless
    /// while `supportsSubtitleDelay` is false.
    @Published var subtitleDelayMs: Int = 0
    /// Whether the current engine can re-time subtitles at all — false hides the Subtitles tab's
    /// "Timing" row entirely. mpv sets this true (`MPVPlayerPanelAdapter`); the native AVPlayer
    /// adapter leaves it false until the delay mechanism lands (beta.15 §B3).
    @Published var supportsSubtitleDelay: Bool = false
    /// Sync Line (P5 B19): an external subtitle is selected and its cues can be loaded.
    @Published var syncLineAvailable = false
    /// Chapters tab rows; empty hides the tab. mpv fills it from `chapter-list`, the native engine
    /// from the remux's libavformat chapters (`NativePlayerPanelAdapter`, P4).
    @Published var chapters: [PlayerPanelChapter] = []

    /// nil = Off.
    var onSelectSubtitle: ((PlayerPanelOption?) -> Void)?
    var onSelectAudio: ((PlayerPanelOption) -> Void)?
    /// New delay in milliseconds, already clamped to ±`SUBTITLE_DELAY_MAX_MS`.
    var onSubtitleDelayChange: ((Int) -> Void)?
    /// Sync Line: the playback position in ms, read when the viewer presses the row.
    var syncLineCapturePositionMs: (() -> Int64)?
    /// Sync Line: loads the selected external subtitle's cues; nil = unavailable (fetch or parse failed).
    var syncLineCues: (() async -> [SubtitleSyncCue]?)?
    var onSelectChapter: ((PlayerPanelChapter) -> Void)?
    var onClose: (() -> Void)?
    /// BUG-180 (Steven rc7): the panel's selected tab, on open and on every switch. The mpv screen
    /// refreshes its Stream Info rows only while Info is on screen; unset on the native engine.
    var onTabChange: ((PlayerPanelTab) -> Void)?

    init(info: PlayerPanelInfo) {
        self.info = info
    }

    // MARK: - Player badges (upstream 344117e73, 83e528f00)

    /// Last media facts the engine reported; nil until it has sampled the playing media.
    private var badgeFacts: PlayerBadgeFacts?
    /// The badge settings (Show Badges in Player, Player Badge Pack, the imported packs).
    private var badgeSettings: StreamBadgeSettingsUiState?
    private var badgeWatcher: FlowWatcher?
    /// "Show Badges in Player" as last emitted. The mpv adapter hands changes to its controller, so
    /// the track-list walk skips the badge reads while it is off.
    private(set) var badgesShowInPlayer = false
    var onBadgesShowInPlayerChange: ((Bool) -> Void)?

    /// Called by the engine adapter when the media is ready and when the audio track changes.
    func setBadgeFacts(_ facts: PlayerBadgeFacts?) {
        guard facts != badgeFacts else { return }
        badgeFacts = facts
        rebuildBadges()
    }

    func setBadgeSettings(_ settings: StreamBadgeSettingsUiState?) {
        badgeSettings = settings
        let on = settings?.showInPlayer == true
        if on != badgesShowInPlayer {
            badgesShowInPlayer = on
            onBadgesShowInPlayerChange?(on)
        }
        rebuildBadges()
    }

    /// Follows the shared badge settings for the life of the model (both engine adapters call it).
    func watchBadgeSettings() {
        guard badgeWatcher == nil else { return }
        StreamBadgeSettingsRepository.shared.ensureLoaded()
        // Seeded synchronously so a panel opened right away does not draw the row a frame late.
        setBadgeSettings(StreamBadgeSettingsRepository.shared.uiState.value_ as? StreamBadgeSettingsUiState)
        badgeWatcher = FlowWatcherKt.watch(StreamBadgeSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? StreamBadgeSettingsUiState else { return }
            self.setBadgeSettings(value)
        }
    }

    private func rebuildBadges() {
        let badges = PlayerBadgeMatch.badges(facts: badgeFacts, settings: badgeSettings)
        if info.badges != badges { info.badges = badges }
    }

    deinit {
        badgeWatcher?.cancel()
    }
}
