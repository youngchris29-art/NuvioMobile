import Foundation

/// FEAT-35 (Detail revamp, 2026-10-02): the device-local `@AppStorage` keys behind the Detail
/// page's layout picker, its section toggles and the spoiler setting. Device-local on purpose, like
/// the older `detail_*` keys: the phone's Detail choices never reshape the TV (plan, "Storage").
///
/// These literals are canonical (plan OUTCOME, Wave 0): the Settings → Detail Page pane binds to
/// these constants, never to its own copies.
nonisolated enum DetailSettingsKeys {
    /// `DetailLayout.rawValue`; unknown or missing → `.cinematic` (D2).
    static let layout = "detail_layout"
    static let sectionStudioLogos = "detail_section_studio_logos"
    static let sectionParentalGuide = "detail_section_parental_guide"
    static let sectionRatings = "detail_section_ratings"
    static let sectionCast = "detail_section_cast"
    static let sectionCollection = "detail_section_collection"
    static let sectionTrailers = "detail_section_trailers"
    static let sectionMoreLikeThis = "detail_section_more_like_this"
    static let sectionComments = "detail_section_comments"
    static let sectionAbout = "detail_section_about"
    /// Must equal `EpisodeSpoilerRules.defaultsKey` (pinned by `EpisodeSpoilerRulesTests`).
    static let hideEpisodeSpoilers = "detail_hide_episode_spoilers"
    /// FEAT-87: `DetailTrailerStartDelay.rawValue`; unknown or missing → `.standard`.
    static let trailerStartDelay = "detail_trailer_start_delay"
}

/// FEAT-87 (GitHub #13): Settings › Detail Page › Trailers › Start Delay. Device-local like the
/// other `detail_trailer_*` keys; `-detail_trailer_start_delay 10` works as a launch argument.
/// Not Home's `TrailerStartDelay` (FEAT-52): different options, and that one counts from focus.
///
/// Both clocks apply only to the page's first appearance (after a pushed page returns, Detail
/// uses Default timing, so it never waits again), and the page latches the value when it opens:
/// - the background trailer is held until this long after the page opens;
/// - the full-screen auto-play fires Default's 4 s after the background trailer could first
///   appear (the hold's end, or the URL resolving if later), so the two never land together;
///   with the background trailer off it fires this long after the URL resolves.
nonisolated enum DetailTrailerStartDelay: String, CaseIterable, Sendable {
    case standard = "default"
    case threeSeconds = "3"
    case fiveSeconds = "5"
    case tenSeconds = "10"
    case fifteenSeconds = "15"
    case thirtySeconds = "30"

    /// Detail's auto-play wait before this setting existed, counted from the URL resolving.
    static let defaultAutoPlaySeconds: TimeInterval = 4

    static func resolve(_ raw: String) -> DetailTrailerStartDelay {
        DetailTrailerStartDelay(rawValue: raw) ?? .standard
    }

    /// The chosen delay; nil for Default (the background trailer starts when it resolves).
    var seconds: TimeInterval? {
        switch self {
        case .standard: return nil
        case .threeSeconds: return 3
        case .fiveSeconds: return 5
        case .tenSeconds: return 10
        case .fifteenSeconds: return 15
        case .thirtySeconds: return 30
        }
    }

    /// Whether the background trailer is still held. `elapsed`: the delay timer fired on this
    /// page. `returned`: a pushed page has returned to this one.
    func holdsBackground(elapsed: Bool, returned: Bool) -> Bool {
        seconds != nil && !elapsed && !returned
    }

    /// Seconds from the trailer URL resolving to the full-screen auto-play. `sinceOpen`: how long
    /// the page had been open when the URL resolved. With the background trailer on, the deadline
    /// from page open is `max(delay, sinceOpen) + 4`: one origin with the background clock.
    func autoPlaySeconds(returned: Bool, backgroundEnabled: Bool, sinceOpen: TimeInterval) -> TimeInterval {
        guard !returned, let seconds else { return Self.defaultAutoPlaySeconds }
        guard backgroundEnabled else { return seconds }
        return max(0, seconds - sinceOpen) + Self.defaultAutoPlaySeconds
    }

    /// Picker label. Same "N s" spelling as Home's Trailer Start Delay ("3 s").
    var label: String {
        switch self {
        case .standard: return String(localized: "Default")
        case .threeSeconds: return String(localized: "3 s")
        case .fiveSeconds: return String(localized: "5 s")
        case .tenSeconds: return String(localized: "10 s")
        case .fifteenSeconds: return String(localized: "15 s")
        case .thirtySeconds: return String(localized: "30 s")
        }
    }
}

/// D2: Cinematic is the default; Classic keeps today's page for one or two betas, then goes.
nonisolated enum DetailLayout: String, CaseIterable {
    case cinematic
    case classic

    /// Anything that is not a known raw value (an empty string, a typo from a launch argument)
    /// resolves to the default rather than to a blank page.
    static func resolve(_ raw: String) -> DetailLayout {
        DetailLayout(rawValue: raw) ?? .cinematic
    }
}
