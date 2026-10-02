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
