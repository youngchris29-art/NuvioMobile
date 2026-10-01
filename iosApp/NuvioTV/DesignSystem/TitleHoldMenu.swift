import SwiftUI
import SharedCore

/// Orivio batch, item 3: the long-press ("hold") menu on poster cards.
///
/// - Catalog posters (Home / Search rows, See All, Discover, folder grids, studio and network
///   rails): **Add to Library / Remove from Library** and **Mark as Watched / Mark as Unwatched**
///   via `titleHoldMenu(preview:)`.
/// - Continue Watching cards: the action list in `TitleHoldMenuPolicy.continueWatchingActions`,
///   rendered by `ContinueWatchingRow`.
///
/// Deliberately NOT attached to the Library tab (it already ships its own Remove menu), Detail
/// rails, Person rails, the Upcoming row, or episode cards.
///
/// Every wording / ordering / state decision lives in `TitleHoldMenuPolicy` as pure functions so
/// `TitleHoldMenuPolicyTests` can pin them; the views below only render what the policy says.
enum TitleHoldMenuPolicy {
    // MARK: - Catalog poster menu

    /// Menu label for the library action. A saved title offers removal, an unsaved one an add.
    static func libraryLabel(isSaved: Bool) -> String {
        isSaved ? String(localized: "Remove from Library") : String(localized: "Add to Library")
    }

    /// SF Symbol for the library action. "Remove" reuses the `trash` glyph the Library tab's own
    /// hold menu already shows for "Remove from Library"; "Add" reuses the Detail action row's
    /// `plus`.
    static func libraryIcon(isSaved: Bool) -> String {
        isSaved ? "trash" : "plus"
    }

    /// Menu label for the watched action. Movies and series share the wording; what differs is the
    /// STATE the caller feeds in, see `effectiveWatched` — a series reads as watched only through
    /// its fully-watched marker (or a title-level mark), never because one episode was seen.
    /// `isSeries` is part of the signature so a future wording split stays a one-line change.
    static func watchedLabel(isWatched: Bool, isSeries: Bool) -> String {
        isWatched ? String(localized: "Mark as Unwatched") : String(localized: "Mark as Watched")
    }

    /// SF Symbol for the watched action: the Detail action row's glyphs (filled once watched).
    static func watchedIcon(isWatched: Bool) -> String {
        isWatched ? "checkmark.circle.fill" : "checkmark.circle"
    }

    /// The watched state the menu label reflects. A movie: its own marker. A series: fully
    /// watched, OR a title-level marker — exactly the "currently watched" test the shared
    /// `WatchingActions.togglePosterWatched` runs before it decides to unmark instead of marking
    /// every released episode, so the label always names what the tap will do.
    static func effectiveWatched(titleMarked: Bool, fullyWatchedSeries: Bool, isSeries: Bool) -> Bool {
        isSeries ? (fullyWatchedSeries || titleMarked) : titleMarked
    }

    /// Series-like type test. Mirrors the shared `isSeriesLikeType()` that
    /// `WatchingActions.togglePosterWatched` branches on, so the menu and the action can never
    /// disagree about which path a title takes.
    static func isSeries(type: String) -> Bool {
        ["series", "show", "tv", "tvshow"].contains(type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    // MARK: - Continue Watching menu

    /// One entry of a Continue Watching card's hold menu.
    enum CWAction: String, CaseIterable, Hashable {
        case playManually
        case goToDetails
        case markEpisodeWatched
        case startOver
        case remove

        var title: String {
            switch self {
            case .playManually: return String(localized: "Play Manually")
            case .goToDetails: return String(localized: "Go to Details")
            case .markEpisodeWatched: return String(localized: "Mark Episode Watched")
            case .startOver: return String(localized: "Start Over")
            case .remove: return String(localized: "Remove from Continue Watching")
            }
        }

        var systemImage: String {
            switch self {
            case .playManually: return "list.bullet"
            case .goToDetails: return "info.circle"
            case .markEpisodeWatched: return "checkmark.circle"
            case .startOver: return "arrow.counterclockwise"
            case .remove: return "trash"
            }
        }

        var isDestructive: Bool { self == .remove }
    }

    /// The menu's items, in display order. "Mark Episode Watched" only exists for an episode
    /// entry; a movie's card has nothing episode-shaped to mark.
    static func continueWatchingActions(isEpisode: Bool) -> [CWAction] {
        var actions: [CWAction] = [.playManually, .goToDetails]
        if isEpisode { actions.append(.markEpisodeWatched) }
        actions.append(contentsOf: [.startOver, .remove])
        return actions
    }

    /// An entry is an episode when it carries both a season and an episode number — the same
    /// test the card's `S02E05` badge uses.
    static func isEpisode(season: Int?, episode: Int?) -> Bool {
        season != nil && episode != nil
    }
}

extension View {
    /// Attaches the catalog poster hold menu (Library + Watched). Place it AFTER
    /// `.posterButtonShape()`, the same order the Library tab's menu uses.
    func titleHoldMenu(preview: MetaPreview) -> some View {
        modifier(TitleHoldMenuModifier(preview: preview))
    }
}

private struct TitleHoldMenuModifier: ViewModifier {
    let preview: MetaPreview
    /// Bumped after every menu action. The card never observes the library / watched stores (a
    /// store write would re-render every card and flicker an open menu), so this is what makes
    /// the NEXT hold re-read the state: the menu items take it as an input, so a bump re-resolves
    /// them even if the menu content was built ahead of presentation.
    @State private var revision = 0

    func body(content: Content) -> some View {
        content.contextMenu {
            TitleHoldMenuItems(preview: preview, revision: revision) { revision &+= 1 }
        }
    }
}

/// The two menu buttons. Repository state is read in THIS body, i.e. when the menu content is
/// built, not by the card.
private struct TitleHoldMenuItems: View {
    let preview: MetaPreview
    /// Only here so a bump from `TitleHoldMenuModifier` changes this view's inputs.
    let revision: Int
    let didAct: () -> Void

    var body: some View {
        let isSeries = TitleHoldMenuPolicy.isSeries(type: preview.type)
        let isSaved = LibraryRepository.shared.isSaved(id: preview.id, type: preview.type)
        let isWatched = TitleHoldMenuPolicy.effectiveWatched(
            titleMarked: WatchedRepository.shared.isWatched(id: preview.id, type: preview.type, season: nil, episode: nil),
            fullyWatchedSeries: isSeries
                ? WatchedRepository.shared.isFullyWatchedSeries(id: preview.id, type: preview.type)
                : false,
            isSeries: isSeries
        )

        Button {
            // The repo stamps `savedAtEpochMs` itself, so 0 (same as Detail's toggleLibrary).
            LibraryRepository.shared.toggleSaved(item: preview.toLibraryItem(savedAtEpochMs: 0))
            didAct()
        } label: {
            Label(TitleHoldMenuPolicy.libraryLabel(isSaved: isSaved),
                  systemImage: TitleHoldMenuPolicy.libraryIcon(isSaved: isSaved))
        }

        Button {
            if isSeries {
                // Mark-all / unmark-all across the released episodes: fetches the series' meta,
                // so it is fire-and-forget on the shared side.
                WatchingActions.shared.togglePosterWatchedAsync(preview: preview)
            } else {
                // The repo stamps `markedAtEpochMs` itself, so 0 (same as Detail's toggleWatched).
                WatchedRepository.shared.toggleWatched(item: preview.toWatchedItem(markedAtEpochMs: 0))
            }
            didAct()
        } label: {
            Label(TitleHoldMenuPolicy.watchedLabel(isWatched: isWatched, isSeries: isSeries),
                  systemImage: TitleHoldMenuPolicy.watchedIcon(isWatched: isWatched))
        }
    }
}
