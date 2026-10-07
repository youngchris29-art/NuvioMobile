import SwiftUI

/// The three mpv properties every aspect mode writes, so leaving any mode resets the others.
/// `keepaspect` is never touched (critique C10: a runtime VO-option write is unproven).
struct MPVAspectProps: Equatable {
    let aspectOverride: String
    let panscan: Double
    let videoZoom: Double
}

/// The mpv player's picture fit, cycled by the Aspect pill. Fit/Fill/Zoom are the synced
/// `PlayerResizeMode` (the phone shares it); Stretch is session-only (critique C9: a device-local
/// key would leak across profiles), so the next playback starts from the synced value.
enum PlayerAspectMode: String, CaseIterable {
    case fit, fill, zoom, stretch

    /// fit → fill → zoom → stretch → fit.
    var next: PlayerAspectMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var label: String {
        switch self {
        case .fit: return String(localized: "Fit")
        case .fill: return String(localized: "Fill")
        case .zoom: return String(localized: "Zoom")
        case .stretch: return String(localized: "Stretch")
        }
    }

    /// `-1` keeps the container's aspect (never `"no"`: it squashes anamorphic files). Zoom is
    /// panscan 0.5, between Fit and Fill on scope films, as on Android (C11). Stretch forces the
    /// screen's 16:9 (every Apple TV drawable).
    var mpvProps: MPVAspectProps {
        switch self {
        case .fit: return MPVAspectProps(aspectOverride: "-1", panscan: 0, videoZoom: 0)
        case .fill: return MPVAspectProps(aspectOverride: "-1", panscan: 1, videoZoom: 0)
        case .zoom: return MPVAspectProps(aspectOverride: "-1", panscan: 0.5, videoZoom: 0)
        case .stretch: return MPVAspectProps(aspectOverride: "16:9", panscan: 0, videoZoom: 0)
        }
    }

    /// The Kotlin `PlayerResizeMode` entry name (`Fit`/`Fill`/`Zoom`); nil for Stretch.
    var syncedName: String? {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .zoom: return "Zoom"
        case .stretch: return nil
        }
    }

    /// The start mode from the synced name; unknown or nil → Fit. Never Stretch.
    static func initial(syncedName: String?) -> PlayerAspectMode {
        allCases.first { $0.syncedName != nil && $0.syncedName == syncedName } ?? .fit
    }
}

/// When the Aspect pill's choice reaches the synced resize mode (review r1 P2 #1, r2 P2 #1): once,
/// when the flash clears or the player closes, so a mode the user only cycles through is never
/// written to the profile, and the phone never inherits it.
///
/// Fit/Fill/Zoom at rest persist when they differ from the stored value. Stretch is session-only,
/// so at rest it puts back the session-start value: Fit, Fill (rests, written), Zoom (rests,
/// written), Stretch leaves the profile and the phone on Fit, not on the rejected Zoom.
///
/// The session-start value is the profile's value when the file loaded, moved by an outside change
/// the settings watcher reports mid-playback (the phone, Settings): that change was deliberate, so
/// a later Stretch puts it back instead of overwriting it with the value from before. Our own
/// writes echoing back through the watcher do not move it (`pendingEchoes`).
struct AspectWriteback: Equatable {
    /// The value Stretch at rest puts back.
    private(set) var sessionStart: PlayerAspectMode
    /// What the profile holds: the session-start value, our last write, or the last outside change.
    private(set) var stored: PlayerAspectMode
    /// Our writes not yet seen on the watcher, oldest first. The watcher is a conflated StateFlow
    /// collected on main, so it can skip an older write and report only a later one.
    private var pendingEchoes: [PlayerAspectMode] = []

    init(start: PlayerAspectMode) {
        let s = start == .stretch ? .fit : start
        sessionStart = s
        stored = s
    }

    /// The mode to write for the mode the pill came to rest on, or nil when the profile already
    /// holds the right value.
    func valueToPersist(resting: PlayerAspectMode) -> PlayerAspectMode? {
        let target = resting.syncedName != nil ? resting : sessionStart
        return target != stored ? target : nil
    }

    /// Record a write we made.
    mutating func didPersist(_ mode: PlayerAspectMode) {
        stored = mode
        pendingEchoes.append(mode)
    }

    /// The settings watcher reported `mode` (any player setting change emits, so it often repeats
    /// the stored value). Our own echo is consumed; a different value is an outside change and
    /// becomes the new session-start value.
    mutating func watcherReported(_ mode: PlayerAspectMode) {
        if let i = pendingEchoes.firstIndex(of: mode) {
            pendingEchoes.removeFirst(i + 1)
            return
        }
        guard mode != stored else { return }
        stored = mode
        sessionStart = mode
        pendingEchoes.removeAll()
    }
}

/// The 2 s label after an Aspect pill press ("Fill"), centred over the video.
struct PlayerAspectFlash: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.sectionTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 40)
            .padding(.vertical, 18)
            .glassEffect(.regular.tint(PlayerChipStyle.glassTint), in: Capsule())
            .transition(.opacity)
            .accessibilityIdentifier("player.aspect.flash")
    }
}
