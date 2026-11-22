import Combine
import SharedCore
import SwiftUI

// P4 B24: the loading screen both engines and the router draw while a video starts — the poster,
// the title and what the player is doing — instead of a bare spinner. The stage enum lives in
// `PlaybackModels.swift` (agent B, so the native coordinator can publish it); this file holds the
// views, the status copy, the mpv stage reducer and the DEBUG history the UI legs read.
// Spec: docs/research/player-p4-spec-native-parity.md §8.1–8.3.

extension PlayerLoadingStage {
    /// The stage's status copy. D2 (Steven rc7): no longer drawn under the logo; kept for the
    /// stage tests and as the wording the native caption shares (`NativePreparingLabel`).
    var statusText: String {
        switch self {
        case .checking: String(localized: "Checking the stream\u{2026}")
        case .connecting: String(localized: "Connecting\u{2026}")
        // The two existing `NativePreparingLabel` strings, reused.
        case .preparing(let dv): dv ? String(localized: "Preparing Dolby Vision\u{2026}")
                                    : String(localized: "Preparing playback\u{2026}")
        case .subtitles: String(localized: "Loading subtitles\u{2026}")
        case .buffering(nil): String(localized: "Buffering\u{2026}")
        case .buffering(let p?): String(localized: "Buffering \(p) %")
        case .started: ""
        }
    }

    /// The overlay's accessibility value and the DEBUG history token.
    var debugName: String { logToken }

    var isStarted: Bool { if case .started = self { true } else { false } }
}

/// Settings › Playback › Loading Screen (`PlayerSettingsUiState.showLoadingOverlay`, shared and
/// synced as `show_loading_overlay`; default on). Read synchronously so a screen can seed its
/// `@State` in `init` — reading it in `onAppear` would flash the overlay for one frame when it is
/// off (critique C17).
enum PlayerLoadingOverlaySetting {
    static var enabled: Bool {
        // A cold launch straight into a player (Top Shelf, the smoke rig) can get here before
        // anything else hydrated the repository; `ensureLoaded` is a no-op once it has.
        PlayerSettingsRepository.shared.ensureLoaded()
        return (PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState)?.showLoadingOverlay != false
    }
}

struct PlayerLoadingOverlay: View {
    /// What the overlay draws. `init(context:stage:)` fills it from a playback context; the stream
    /// picker's auto-play cover (`FirstPlayAutoPlayOverlay`, BUG-183) fills it from its own inputs
    /// before any context exists, so picker → player reads as one screen.
    let title: String
    let parentMetaId: String
    /// BUG-184: the opening screen's title logo (localized); nil uses metahub's English one.
    let logoUrl: String?
    let background: String?
    /// D2 (Steven rc7): the episode line, series only ("S1 · E4 · Name"); nil for a movie.
    let episodeLine: String?
    /// BUG-182: the shared pulse clock's key (`PlayerLoadingPulseClock`), the playback's video id.
    let pulseKey: String
    /// nil for the picker's cover (no engine stage yet).
    let stage: PlayerLoadingStage?
    /// DEBUG history key (the playback context's id); nil = not a player overlay.
    let historyContextID: String?
    /// The picker's cover holds focus so Menu reaches its `onExitCommand`; the player's overlays
    /// never take focus or a hit (the remote reaches the engine underneath).
    var takesFocus: Bool = false
    var accessibilityID: String = "player.loadingOverlay"
    /// Spoken label override (the picker's "Finding the best source…", which UI tests read).
    var accessibilityText: String? = nil
    /// Stops the pulse clock's timeline (the scale holds where it is).
    var pulsePaused: Bool = false

    init(context: PlaybackContext, stage: PlayerLoadingStage) {
        self.title = context.title
        self.parentMetaId = context.parentMetaId
        self.logoUrl = context.logo
        self.background = context.background
        self.episodeLine = Self.episodeLine(season: context.season, episode: context.episode,
                                            episodes: context.episodes)
        self.pulseKey = context.videoId
        self.stage = stage
        self.historyContextID = context.id
    }

    init(title: String, parentMetaId: String, logoUrl: String?, background: String?, episodeLine: String?,
         pulseKey: String, takesFocus: Bool, accessibilityID: String, accessibilityText: String?, pulsePaused: Bool) {
        self.title = title
        self.parentMetaId = parentMetaId
        self.logoUrl = logoUrl
        self.background = background
        self.episodeLine = episodeLine
        self.pulseKey = pulseKey
        self.stage = nil
        self.historyContextID = nil
        self.takesFocus = takesFocus
        self.accessibilityID = accessibilityID
        self.accessibilityText = accessibilityText
        self.pulsePaused = pulsePaused
    }

    /// FEAT-77 (D18; Steven, rc5 + rc6 verdicts: the official apps' loading look): the title logo
    /// centred, pulsing slowly (1.0 ↔ 1.08), with the episode line under it. The title in text
    /// while the logo loads, or when the title has none. No setting.
    ///
    /// BUG-182 (Steven rc7): up to three of these replace each other while a video starts (the
    /// picker's cover, `PlayerScreen`'s `.deciding`, then the engine's own), and each restarted a
    /// per-instance `@State` pulse. The scale now comes from a clock shared per playback
    /// (`PlayerLoadingPulseClock`), so a swap is invisible. D2: the status line ("Connecting…",
    /// "Buffering…") is gone; the stage stays the accessibility value the UI legs read.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let pulseScale: CGFloat = 1.08
    static let pulseSeconds: Double = 1.6

    /// BUG-184: the opening screen's own logo first (TMDB-localized on Detail), then metahub's.
    static func logoURL(logoUrl: String?, parentMetaId: String) -> URL? {
        if let logoUrl, !logoUrl.isEmpty, let url = URL(string: logoUrl) { return url }
        return logoURL(parentMetaId: parentMetaId)
    }

    /// metahub's logo for an IMDb-backed title (the same guess Home's hero makes); nil otherwise.
    static func logoURL(parentMetaId: String) -> URL? {
        let imdbId = parentMetaId.split(separator: ":").first.map(String.init) ?? parentMetaId
        guard imdbId.hasPrefix("tt") else { return nil }
        return URL(string: "https://images.metahub.space/logo/medium/\(imdbId)/img")
    }

    /// D2 (Steven rc7, "keep only the title"): the one line kept under the logo, series only —
    /// "S1 · E4 · Episode name", or "S1 · E4" when the list has no name. Never the stream's release
    /// name (the old fallback), which the picker cannot know and which made the line jump on the swap.
    nonisolated static func episodeLine(season: Int?, episode: Int?, episodes: [MetaVideo]) -> String? {
        guard let season, let episode else { return nil }
        let name = episodes.first { $0.season?.intValue == season && $0.episode?.intValue == episode }?.title
        return episodeLine(season: season, episode: episode, episodeName: name)
    }

    nonisolated static func episodeLine(season: Int, episode: Int, episodeName: String?) -> String {
        let marker = String(localized: "S\(season) · E\(episode)")
        guard let episodeName, !episodeName.isEmpty else { return marker }
        return "\(marker) · \(episodeName)"
    }

    var body: some View {
        ZStack {
            Color.black
            if let background, !background.isEmpty {
                CachedAsyncImage(string: background)
                    .opacity(0.28)
                    .blur(radius: 30)
                    .clipped()
            }
            VStack(spacing: 28) {
                pulsingTitleMark
                if let episodeLine, !episodeLine.isEmpty {
                    Text(episodeLine)
                        .font(Theme.Font.body)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 1200)
        }
        .ignoresSafeArea()
        .allowsHitTesting(takesFocus)
        .focusable(takesFocus)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText ?? title))
        .accessibilityIdentifier(accessibilityID)
        .accessibilityValue(stage?.debugName ?? "")
        #if DEBUG
        // A fast start can come and go between two XCUITest snapshots; the history label keeps
        // the stage the overlay was first drawn at.
        .onAppear {
            if let stage, let historyContextID {
                PlayerLoadingHistory.shared.noteOverlayDrawn(stage, contextID: historyContextID)
            }
        }
        #endif
    }

    /// BUG-182: the scale is read off the shared clock every frame, so whichever overlay is on
    /// screen continues the same breath. Reduce Motion: no pulse at all.
    @ViewBuilder
    private var pulsingTitleMark: some View {
        if reduceMotion {
            titleMark
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: pulsePaused)) { timeline in
                let began = PlayerLoadingPulseClock.start(for: pulseKey)
                titleMark
                    .scaleEffect(PlayerLoadingPulseClock.scale(elapsed: timeline.date.timeIntervalSince(began)))
            }
        }
    }

    @ViewBuilder
    private var titleMark: some View {
        if let logo = Self.logoURL(logoUrl: logoUrl, parentMetaId: parentMetaId) {
            CachedAsyncImage(url: logo, contentMode: .fit, loading: { titleText }, failure: { titleText })
                .frame(maxWidth: 640, maxHeight: 200)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title)
            .font(Theme.Font.screenTitle)
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }
}

/// BUG-182 (Steven rc7): one pulse clock per playback, shared by every loading overlay that draws
/// it. The first overlay drawn for a video id starts the clock; a later overlay for the same id
/// within `continuityGrace` of the last frame drawn (the picker's cover handing over to
/// `PlayerScreen`'s, then to the engine's) continues it, so the logo never snaps back to 1.0 on a
/// swap. A new video id, or the same one after a pause longer than the grace (a replay, the
/// next episode), starts a fresh breath at 1.0.
@MainActor
enum PlayerLoadingPulseClock {
    static let continuityGrace: TimeInterval = 2

    /// Review r1 (P3): one clock PER key, so two overlays with different keys on screen at once
    /// (a held picker cover under a nested picker's) never reset each other every frame.
    private struct Entry { var began: Date; var lastSeen: Date }
    private static var entries: [String: Entry] = [:]

    /// The clock's start for `key`, touching it as seen at `now`.
    static func start(for key: String, now: Date = Date()) -> Date {
        if var entry = entries[key], now.timeIntervalSince(entry.lastSeen) <= continuityGrace, now >= entry.lastSeen {
            entry.lastSeen = now
            entries[key] = entry
            return entry.began
        }
        // Drop clocks nobody has drawn for a while (bounded: a handful of keys at most).
        entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) <= continuityGrace }
        entries[key] = Entry(began: now, lastSeen: now)
        return now
    }

    /// Tests only.
    static func reset() {
        entries = [:]
    }

    /// 1.0 at the start, `pulseScale` after `pulseSeconds`, back to 1.0 after twice that: an
    /// ease-in-out (cosine) breath, the curve the old `repeatForever(autoreverses:)` drew.
    static func scale(elapsed: TimeInterval) -> CGFloat {
        let half = PlayerLoadingOverlay.pulseSeconds
        guard elapsed.isFinite, elapsed > 0, half > 0 else { return 1 }
        let phase = elapsed.truncatingRemainder(dividingBy: half * 2) / (half * 2)
        let wave = (1 - cos(phase * 2 * .pi)) / 2
        return 1 + (PlayerLoadingOverlay.pulseScale - 1) * CGFloat(wave)
    }
}

/// The plain spinner each site drew before B24; the setting-off branch keeps it.
struct PlayerLoadingSpinner: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView().scaleEffect(1.5)
        }
    }
}

/// mpv's startup stages (spec §8.1). Main thread, pure, so `PlayerLoadingStageTests` drives it.
///
/// `.connecting` until `MPV_EVENT_FILE_LOADED`, then `.buffering(percent:)` until the first
/// `MPV_EVENT_PLAYBACK_RESTART` that completes the resume seek — or any restart after FILE_LOADED
/// when no resume seek was issued. A restart before the resume seek (mpv's own start of playback)
/// does not count. Backstop: the position advancing by more than 1 s while not paused. Once
/// `.started`, it never moves back: a mid-play rebuffer is the small spinner's job, not this one.
struct MPVStartupStageReducer: Equatable {
    private(set) var stage: PlayerLoadingStage = .connecting
    private var fileLoaded = false
    /// The resume seek's generation (nil = no resume seek this file).
    private var resumeGeneration: Int?
    /// First position seen once loaded and playing (the backstop's baseline).
    private var baselineSec: Double?

    var started: Bool { stage.isStarted }

    /// FILE_LOADED, with the generation of the resume seek it just issued (nil = none).
    @discardableResult
    mutating func fileLoaded(resumeGeneration: Int?) -> Bool {
        guard !started, !fileLoaded else { return false }
        fileLoaded = true
        self.resumeGeneration = resumeGeneration
        return set(.buffering(percent: nil))
    }

    /// A PLAYBACK_RESTART. `completesSeek` is the app seek generation it confirms (nil when it is
    /// not the completion of one of our seeks).
    @discardableResult
    mutating func playbackRestart(completesSeek: Int?) -> Bool {
        guard fileLoaded, !started else { return false }
        if let resumeGeneration {
            guard let completesSeek, completesSeek >= resumeGeneration else { return false }
        }
        return set(.started)
    }

    /// The resume seek was rejected (code review W7 r1-2): no PLAYBACK_RESTART will complete it, and
    /// a paused start never trips the position backstop, so the start completes now.
    @discardableResult
    mutating func resumeSeekRejected() -> Bool {
        guard fileLoaded, !started, resumeGeneration != nil else { return false }
        return set(.started)
    }

    /// `cache-buffering-state` (0–100) while buffering before start.
    @discardableResult
    mutating func bufferingPercent(_ percent: Int?) -> Bool {
        guard fileLoaded, !started else { return false }
        return set(.buffering(percent: percent.map { min(max($0, 0), 100) }))
    }

    /// The UI tick: the position-advance backstop.
    @discardableResult
    mutating func tick(positionSec: Double, paused: Bool) -> Bool {
        guard fileLoaded, !started, positionSec.isFinite else { return false }
        if paused { baselineSec = nil; return false }
        guard let base = baselineSec else { baselineSec = positionSec; return false }
        return positionSec - base > 1 ? set(.started) : false
    }

    private mutating func set(_ next: PlayerLoadingStage) -> Bool {
        guard next != stage else { return false }
        stage = next
        return true
    }
}

#if DEBUG
/// The DEBUG oracle for the B24 legs (critique C9): each screen appends every stage it shows, so
/// `checking>connecting>…>started` survives stages too short for XCUITest polling. Keyed on the
/// context id: the first note for a new context starts a new history.
@MainActor
final class PlayerLoadingHistory: ObservableObject {
    static let shared = PlayerLoadingHistory()
    @Published private(set) var text = ""
    /// The stage the loading overlay was first drawn at for this context (nil = never drawn).
    @Published private(set) var overlayDrawnAt: String?
    private var contextID: String?
    private var last: String?

    private func begin(_ id: String) {
        guard id != contextID else { return }
        contextID = id; text = ""; last = nil; overlayDrawnAt = nil
    }

    func noteOverlayDrawn(_ stage: PlayerLoadingStage, contextID id: String) {
        begin(id)
        if overlayDrawnAt == nil { overlayDrawnAt = stage.logToken }
    }

    func note(_ stage: PlayerLoadingStage, contextID id: String) {
        begin(id)
        // `buffering(42)` and `buffering` are one stage for the history.
        let token = stage.logToken.split(separator: "(").first.map(String.init) ?? stage.logToken
        guard token != last else { return }
        last = token
        text = text.isEmpty ? token : text + ">" + token
    }
}

struct PlayerLoadingHistoryLabel: View {
    @ObservedObject private var history = PlayerLoadingHistory.shared

    var body: some View {
        // `<stage>>…>started overlay=<first drawn stage | none>`
        Text(verbatim: (history.text.isEmpty ? "none" : history.text) + " overlay=" + (history.overlayDrawnAt ?? "none"))
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("debug_loadingHistory")
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}
#endif
