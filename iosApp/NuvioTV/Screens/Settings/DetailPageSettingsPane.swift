import SwiftUI
import SharedCore

/// "Detail Page" category rows (detail-settings-revamp W2-B): layout, trailers, episodes and the
/// per-section show/hide toggles. Rows only: `SettingsPaneScaffold` supplies the `List`.
///
/// Storage: the layout / section / spoiler keys come from `DetailSettingsKeys` (device-local, the
/// Detail page reads the same constants); the older `detail_*` trailer and button keys are the
/// same literals the Appearance pane used to own, so existing user choices carry over. Episode
/// Ratings is the synced `MetaScreenSettingsRepository` value through `SettingsViewModel`.
struct DetailPageSettingsPane: View {
    @ObservedObject var model: SettingsViewModel

    @AppStorage(DetailSettingsKeys.layout) private var layoutRaw = DetailLayout.cinematic.rawValue
    @AppStorage("detail_action_icons_only") private var iconOnlyButtons = false
    @AppStorage("detail_poster_backdrop") private var posterBackdrop = true
    @AppStorage("detail_trailer_autoplay") private var trailerAutoplay = true
    @AppStorage("detail_trailer_background") private var trailerBackground = true
    /// 0 = play forever.
    @AppStorage("detail_trailer_duration") private var trailerDuration = 0
    /// FEAT-11: whether a full-screen trailer starts with sound. DetailView reads this key to seed
    /// `HeroTrailerAudioState` at launch and after a full-screen trailer dismisses; the row also
    /// flips the shared state at once. (Moved here from the Playback pane; same key.)
    @AppStorage("trailer_audio_default_on") private var trailerSoundDefaultOn = false
    @AppStorage(DetailSettingsKeys.hideEpisodeSpoilers) private var hideEpisodeSpoilers = false

    @AppStorage(DetailSettingsKeys.sectionStudioLogos) private var sectionStudioLogos = true
    @AppStorage(DetailSettingsKeys.sectionParentalGuide) private var sectionParentalGuide = true
    @AppStorage(DetailSettingsKeys.sectionRatings) private var sectionRatings = true
    @AppStorage(DetailSettingsKeys.sectionCast) private var sectionCast = true
    @AppStorage(DetailSettingsKeys.sectionCollection) private var sectionCollection = true
    @AppStorage(DetailSettingsKeys.sectionTrailers) private var sectionTrailers = true
    @AppStorage(DetailSettingsKeys.sectionMoreLikeThis) private var sectionMoreLikeThis = true
    @AppStorage(DetailSettingsKeys.sectionComments) private var sectionComments = true
    @AppStorage(DetailSettingsKeys.sectionAbout) private var sectionAbout = true

    private static let trailerDurationOptions: [(value: Int, label: String)] = [
        (30, String(localized: "30s")),
        (60, String(localized: "1 min")),
        (90, String(localized: "90s")),
        (0, String(localized: "Always")),
    ]

    /// Options in the order show-all / watched-only / hide. Computed (not a stored `static let`)
    /// because the Kotlin enum bridge types are not `Sendable`.
    private static var episodeRatingsOptions: [(value: EpisodeRatingsVisibility, label: String)] {
        [
            (.showAll, String(localized: "Show")),
            (.hideUnwatchedEpisodes, String(localized: "Watched Only")),
            (.hideEpisodes, String(localized: "Hide")),
        ]
    }

    private static func layoutLabel(_ layout: DetailLayout) -> String {
        switch layout {
        case .cinematic: return String(localized: "Cinematic")
        case .classic: return String(localized: "Classic")
        }
    }

    var body: some View {
        Group {
            SettingsSection(String(localized: "Layout")) {
                SettingsPickerRow(
                    title: String(localized: "Detail Layout"),
                    subtitle: String(localized: "Cinematic puts the title over a full-bleed backdrop. Classic keeps the earlier page."),
                    selection: Binding(
                        get: { DetailLayout.resolve(layoutRaw) },
                        set: { layoutRaw = $0.rawValue }
                    ),
                    options: DetailLayout.allCases,
                    descriptionID: .detailLayout,
                    label: Self.layoutLabel
                )
                SettingsToggleRow(
                    title: String(localized: "Icon-Only Detail Buttons"),
                    subtitle: String(localized: "Buttons show icons only"),
                    isOn: $iconOnlyButtons,
                    descriptionID: .detailIconOnlyButtons
                )
                SettingsToggleRow(
                    title: String(localized: "Poster in Detail Background"),
                    subtitle: String(localized: "Show the title's poster on the right side of detail pages"),
                    isOn: $posterBackdrop,
                    descriptionID: .detailPosterBackdrop
                )
            }

            SettingsSection(String(localized: "Trailers")) {
                SettingsToggleRow(
                    title: String(localized: "Auto-Play Trailer on Detail"),
                    subtitle: String(localized: "Play the trailer full screen shortly after opening a title"),
                    isOn: $trailerAutoplay,
                    descriptionID: .detailTrailerAutoplay
                )
                SettingsToggleRow(
                    title: String(localized: "Background Trailer on Detail"),
                    subtitle: String(localized: "A muted trailer plays behind the description on detail pages"),
                    isOn: $trailerBackground,
                    descriptionID: .detailTrailerBackground
                )
                // FEAT-8: only meaningful while the background trailer itself is on.
                if trailerBackground {
                    SettingsPickerRow(
                        title: String(localized: "Trailer Duration"),
                        selection: $trailerDuration,
                        options: Self.trailerDurationOptions.map(\.value),
                        descriptionID: .detailTrailerDuration,
                        label: { value in Self.trailerDurationOptions.first { $0.value == value }?.label ?? "\(value)" }
                    )
                }
                SettingsToggleRow(
                    title: String(localized: "Trailer Sound by Default"),
                    subtitle: String(localized: "Trailers start with sound; play/pause mutes"),
                    isOn: Binding(
                        get: { trailerSoundDefaultOn },
                        set: { newValue in
                            trailerSoundDefaultOn = newValue
                            // Applies immediately, without relaunch: DetailView otherwise only
                            // reads this default at app launch and after a full-screen trailer
                            // dismisses.
                            HeroTrailerAudioState.shared.setMuted(value: !newValue)
                        }
                    ),
                    descriptionID: .detailTrailerSound
                )
            }

            SettingsSection(String(localized: "Episodes")) {
                SettingsPickerRow(
                    title: String(localized: "Episode Ratings"),
                    subtitle: String(localized: "Rating badges on episode cards"),
                    selection: Binding(
                        get: { model.episodeRatingsVisibility },
                        set: { model.setEpisodeRatingsVisibility($0) }
                    ),
                    options: Self.episodeRatingsOptions.map(\.value),
                    descriptionID: .detailEpisodeRatings,
                    label: { value in Self.episodeRatingsOptions.first { $0.value == value }?.label ?? "" }
                )
                SettingsToggleRow(
                    title: String(localized: "Hide Spoilers in Unwatched Episodes"),
                    subtitle: String(localized: "Blur thumbnails and hide descriptions of episodes you haven't watched"),
                    isOn: $hideEpisodeSpoilers,
                    descriptionID: .detailHideEpisodeSpoilers
                )
            }

            SettingsSection(String(localized: "Sections"), footer: String(localized: "Episodes always shows.")) {
                SettingsToggleRow(
                    title: String(localized: "Studio Logos"),
                    isOn: $sectionStudioLogos,
                    descriptionID: .detailSectionStudioLogos
                )
                SettingsToggleRow(
                    title: String(localized: "Parental Guide"),
                    isOn: $sectionParentalGuide,
                    descriptionID: .detailSectionParentalGuide
                )
                SettingsToggleRow(
                    title: String(localized: "Ratings"),
                    isOn: $sectionRatings,
                    descriptionID: .detailSectionRatings
                )
                SettingsToggleRow(
                    title: String(localized: "Cast"),
                    isOn: $sectionCast,
                    descriptionID: .detailSectionCast
                )
                SettingsToggleRow(
                    title: String(localized: "Collection"),
                    isOn: $sectionCollection,
                    descriptionID: .detailSectionCollection
                )
                SettingsToggleRow(
                    title: String(localized: "Trailers & Extras"),
                    isOn: $sectionTrailers,
                    descriptionID: .detailSectionTrailers
                )
                SettingsToggleRow(
                    title: String(localized: "More Like This"),
                    isOn: $sectionMoreLikeThis,
                    descriptionID: .detailSectionMoreLikeThis
                )
                SettingsToggleRow(
                    title: String(localized: "Comments"),
                    isOn: $sectionComments,
                    descriptionID: .detailSectionComments
                )
                SettingsToggleRow(
                    title: String(localized: "About"),
                    isOn: $sectionAbout,
                    descriptionID: .detailSectionAbout
                )
            }
        }
    }
}
