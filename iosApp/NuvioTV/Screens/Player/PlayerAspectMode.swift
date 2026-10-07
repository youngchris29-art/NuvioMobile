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

/// When the Aspect pill's choice reaches the synced resize mode (review r1 P2 #1): once, when the
/// 2 s flash clears or the player closes, so a mode the user only cycles through (Fill and Zoom on
/// the way to Stretch) is never written to the profile, and the phone never inherits it.
enum AspectWriteback {
    /// The mode to persist, given where the pill came to rest and the value the profile already
    /// holds (the session-start value, or the last write). Stretch never persists, so the profile
    /// keeps what it had; a resting mode equal to the stored one writes nothing.
    static func valueToPersist(resting: PlayerAspectMode, persisted: PlayerAspectMode) -> PlayerAspectMode? {
        guard resting.syncedName != nil, resting != persisted else { return nil }
        return resting
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
