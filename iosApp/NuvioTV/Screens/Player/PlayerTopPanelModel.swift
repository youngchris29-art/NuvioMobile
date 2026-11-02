import Combine
import SharedCore
import SwiftUI

// Engine-agnostic backing model for the player's pills (Info · Cast · Chapters · Up Next) and tool
// popovers (Subtitles · Audio · Playback). The native screen fills it through
// `NativePlayerPanelAdapter`, the mpv screen through `MPVPlayerPanelAdapter`; Cast comes from
// `PlayerInsightsLoader`. Closures rather than a protocol keep it a plain ObservableObject the
// SwiftUI views observe directly. (The swipe-down top panel it was built for is gone, 2026-11-01.)

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

// MARK: - Insights contracts (2026-11-01)

/// The text pills under the timeline (Rivulet / AVKit tvOS 26 layout), in display order. Native
/// hosts them as `customInfoViewControllers`; mpv draws its own row and content shelf. Both show
/// the same content views (`PlayerInfoTab`, `PlayerCastContent`, `PlayerChaptersTab`,
/// `PlayerUpNextContent`).
enum PlayerInfoPill: String, CaseIterable, Identifiable {
    case info, cast, chapters, upNext
    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return String(localized: "Info")
        case .cast: return String(localized: "Cast")
        case .chapters: return String(localized: "Chapters")
        case .upNext: return String(localized: "Up Next")
        }
    }

    /// Info always; Cast when the setting is on and someone is known; Chapters when the file has
    /// any; Up Next when there is a next episode.
    @MainActor
    static func visible(for model: PlayerTopPanelModel) -> [PlayerInfoPill] {
        var out: [PlayerInfoPill] = [.info]
        if model.castEnabled, !model.people.isEmpty { out.append(.cast) }
        if !model.chapters.isEmpty { out.append(.chapters) }
        if model.upNext != nil { out.append(.upNext) }
        return out
    }
}

/// One card in the Cast pill. `id` is the TMDB person id.
struct PlayerPanelPerson: Identifiable, Equatable {
    let id: Int
    let name: String
    /// Character (cast) or job(s) (crew); nil = unknown.
    let role: String?
    let photo: URL?
    let isCrew: Bool
    var isGuest = false

    /// Unique per card: the credits builder emits a person twice when they are both cast and key crew.
    var cardKey: String { isCrew ? "\(id)-crew" : "\(id)" }
}

/// One display-only poster in the compact actor view.
struct PlayerPanelKnownFor: Identifiable, Equatable {
    let id: String
    let title: String
    let poster: URL?
}

/// The compact actor view's content (`PlayerPanelPerson` + the TMDB person summary).
struct PlayerPanelPersonDetail: Equatable {
    let id: Int
    let name: String
    let photo: URL?
    let knownForDepartment: String?
    /// "1956 – 2024" / "Born 1974"; nil when unknown.
    let lifeDates: String?
    let biography: String?
    let knownFor: [PlayerPanelKnownFor]
}

/// The Up Next pill's card.
struct PlayerPanelUpNext: Equatable {
    let title: String
    /// "S1 · E5"
    let subtitle: String?
    let still: URL?
}

@MainActor
final class PlayerTopPanelModel: ObservableObject {
    @Published var info: PlayerPanelInfo

    // MARK: Insights (Cast pill)

    /// Cast first, then key crew. Empty hides the Cast pill. Filled by `PlayerInsightsLoader`.
    @Published var people: [PlayerPanelPerson] = []
    /// "Show cast in player" (`PlayerTuning.showCastInPlayer`), read when the model is built.
    @Published var castEnabled: Bool = PlayerTuning.showCastInPlayer
    /// The person whose compact actor view is open; nil = the card row.
    @Published var actorView: PlayerPanelPerson?
    /// The open actor view's detail; nil while it loads (the view draws from `actorView` meanwhile).
    @Published var actorDetail: PlayerPanelPersonDetail?
    /// True when the open actor view's detail fetch finished without a result.
    @Published var actorDetailFailed = false
    /// The card last opened, so focus returns to it when the actor view closes.
    @Published var lastOpenedCardKey: String?
    /// Asked to load the actor view's detail (set by the loader).
    var onOpenPerson: ((PlayerPanelPerson) -> Void)?

    /// Opens the compact actor view for a card.
    func openPerson(_ person: PlayerPanelPerson) {
        lastOpenedCardKey = person.cardKey
        actorDetail = nil
        actorDetailFailed = false
        actorView = person
        onOpenPerson?(person)
    }

    /// Menu, one level at a time: closes the actor view and returns true (press consumed), or
    /// returns false when there is nothing inside the pill to back out of.
    @discardableResult
    func menuBack() -> Bool {
        guard actorView != nil else { return false }
        actorView = nil
        actorDetail = nil
        actorDetailFailed = false
        return true
    }

    // MARK: Up Next pill

    /// nil hides the Up Next pill. Filled by each engine from its `NextEpisodeEngine`.
    @Published var upNext: PlayerPanelUpNext?
    var onPlayUpNext: (() -> Void)?
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
    /// Aether: Boost and Dialogue shape the audio as PCM, which turns Dolby Atmos passthrough off
    /// (the Audio tab says so while either is on). Set from `MPVPlaybackState.engine`.
    var audioShapingEndsAtmos = false
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
