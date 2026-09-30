import SwiftUI
import SharedCore

/// Episode shuffle for one series (upstream `23b048c3`/`da92f36c`/`6776ee7b`; their sheet is
/// Compose-only, so this is the tvOS-native equivalent). Presented from the Detail action row's
/// Shuffle button.
///
/// A stock `List` built from the Settings kit (`SettingsToggleRow`, `SettingsPickerRow`,
/// `SettingsActionRow`) — system focus, system platter, no custom styles (HIG hybrid contract).
/// Every phase keeps at least one focusable row: the Shuffle Episodes toggle is always present,
/// and each non-ready phase adds its own way out (BUG-47's empty-state eject class).
///
/// All state lives in `DetailViewModel` (settings via `EpisodeShuffleRepository.save`, the pick
/// via the shared `EpisodeShuffle` session), so the pick shown here is the one Detail's Play
/// button plays.
struct EpisodeShuffleSheet: View {
    @ObservedObject var model: DetailViewModel
    /// The show's name, shown under the sheet title.
    let title: String
    /// Plays the pick through Detail's own series play route. Detail dismisses the sheet first.
    let onPlay: (SeriesPrimaryAction) -> Void

    @Environment(\.dismiss) private var dismiss

    /// What the lower half of the sheet shows. Pure so it can be unit-tested.
    enum Phase: Equatable {
        /// Shuffle is off for this show: just the toggle and the mode picker.
        case off
        /// Episodes are still loading (no pick yet while Detail's metadata resolves).
        case loading
        /// The show has no released, numbered episodes to shuffle.
        case empty
        /// Unwatched mode, and every episode is watched.
        case caughtUp
        /// A pick is ready to play.
        case ready

        static func resolve(enabled: Bool, hasPick: Bool, isLoading: Bool, caughtUp: Bool) -> Phase {
            guard enabled else { return .off }
            if hasPick { return .ready }
            if isLoading { return .loading }
            return caughtUp ? .caughtUp : .empty
        }
    }

    private var phase: Phase {
        Phase.resolve(
            enabled: model.shuffleSettings.enabled,
            hasPick: model.shufflePick != nil,
            isLoading: model.isLoading,
            caughtUp: model.shuffleCaughtUp
        )
    }

    var body: some View {
        List {
            SettingsSection(
                title: String(localized: "Shuffle"),
                footer: phase == .off
                    ? String(localized: "When shuffle is on, Play picks a random episode of this show.")
                    : nil
            ) {
                SettingsToggleRow(
                    title: String(localized: "Shuffle Episodes"),
                    subtitle: title,
                    isOn: Binding(
                        get: { model.shuffleSettings.enabled },
                        set: { model.setShuffleEnabled($0) }
                    )
                )
                SettingsPickerRow(
                    title: String(localized: "Episodes"),
                    selection: Binding(
                        get: { model.shuffleSettings.includeWatched },
                        set: { model.setShuffleIncludeWatched($0) }
                    ),
                    options: [false, true],
                    label: { $0 ? String(localized: "All") : String(localized: "Unwatched") }
                )
            }

            switch phase {
            case .off:
                EmptyView()
            case .loading:
                SettingsSection(title: nil, footer: String(localized: "Loading episodes…")) {
                    closeRow
                }
            case .empty:
                SettingsSection(title: nil, footer: String(localized: "No episodes are available to shuffle.")) {
                    closeRow
                }
            case .caughtUp:
                SettingsSection(title: nil, footer: String(localized: "You have watched every episode.")) {
                    SettingsActionRow(
                        title: String(localized: "Include Watched Episodes"),
                        systemImage: "arrow.counterclockwise"
                    ) {
                        model.setShuffleIncludeWatched(true)
                    }
                    stopRow
                }
            case .ready:
                if let pick = model.shufflePick {
                    SettingsSection(String(localized: "Your Episode")) {
                        pickRow(pick)
                        SettingsActionRow(
                            title: model.shufflePickPlayable
                                ? String(localized: "Play Episode")
                                : String(localized: "Playback unavailable"),
                            systemImage: "play.fill"
                        ) {
                            if let action = model.shufflePickAction() { onPlay(action) }
                        }
                        .disabled(!model.shufflePickPlayable)
                        SettingsActionRow(title: String(localized: "Shuffle Again"), systemImage: "shuffle") {
                            model.reshuffle()
                        }
                        stopRow
                    }
                }
            }
        }
    }

    /// The current pick: episode code over its title, overview below. Static text — not
    /// focusable (the rows around it are).
    private func pickRow(_ pick: MetaVideo) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if let season = pick.season?.intValue, let episode = pick.episode?.intValue {
                // Same unlocalized "S1E2" code Detail's stream-picker title uses.
                Text(verbatim: "S\(season)E\(episode)")
                    .font(SettingsRowFont.subtitle)
                    .foregroundStyle(.secondary)
            }
            Text(pick.title)
                .font(SettingsRowFont.title)
            let overview: String? = pick.overview
            if let overview, !overview.isEmpty {
                Text(overview)
                    .font(SettingsRowFont.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Turns shuffle off for this show and closes the sheet. A failed write keeps the sheet (and
    /// the old state) up.
    private var stopRow: some View {
        SettingsActionRow(title: String(localized: "Stop Shuffle"), systemImage: "xmark") {
            let off = EpisodeShuffleSettings(enabled: false, includeWatched: model.shuffleSettings.includeWatched)
            if model.saveShuffle(off) {
                dismiss()
            }
        }
    }

    private var closeRow: some View {
        SettingsActionRow(title: String(localized: "Close")) {
            dismiss()
        }
    }
}
