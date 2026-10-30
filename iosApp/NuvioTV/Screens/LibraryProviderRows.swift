import Combine
import SwiftUI
import SharedCore

/// FEAT-89 (Reddit, u/dclimaxb; decision C0 (a), 2026-10-30): the Library tab's two rows for a
/// connected Trakt or Simkl account, "Resume Watching" and "Watchlist", above the grid.
///
/// The data is the shared `LibraryProviderRowsRepository.observeRows()`: Home's Continue Watching
/// entries (in-progress plus the FEAT-85 Up Next cards, most recent first) and the connected
/// providers' watchlists merged and de-duplicated, most recently added first. With no Trakt or
/// Simkl account both lists are empty and the rows are not drawn. No setting, no stored state.
@MainActor
final class LibraryProviderRowsModel: ObservableObject {
    @Published private(set) var resumeWatching: [WatchProgressEntry] = []
    /// The Watchlist row in the shape `CatalogRowView` takes; nil while the merged list is empty.
    @Published private(set) var watchlistSection: HomeCatalogSection?
    /// Parent ids of series with Episode Shuffle on (the Continue Watching cards' badge, as Home).
    @Published private(set) var shuffleParentIds: Set<String> = []
    /// The Continue Watching screen's custom poster pattern (blank = none), as Home reads it.
    @Published private(set) var posterPattern = ""

    private var watcher: FlowWatcher?
    /// The last rows applied; the watchlist is compared through it. (`LibraryItem` is not named in
    /// this file: SwiftUI's import makes the bare name ambiguous here.)
    private var lastRows: LibraryProviderRows?

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watchFlow(LibraryProviderRowsRepository.shared.observeRows()) { [weak self] emitted in
            guard let self, let rows = emitted as? LibraryProviderRows else { return }
            self.apply(rows)
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    /// Assigned only on change: Kotlin data classes bridge `==` as a structural compare, and an
    /// unchanged row must not re-render (and disturb focus in) its shelf.
    private func apply(_ rows: LibraryProviderRows) {
        if rows.resumeWatching != resumeWatching { resumeWatching = rows.resumeWatching }
        if rows.watchlist != lastRows?.watchlist {
            watchlistSection = rows.watchlist.isEmpty ? nil : LibraryProviderRowsKt.libraryWatchlistRowSection(
                title: String(localized: "Watchlist"),
                items: rows.watchlist
            )
        }
        lastRows = rows
        let shuffled = Set(resumeWatching.compactMap { entry -> String? in
            ShuffleNextEpisode.shared.isEnabled(contentId: entry.parentMetaId, contentType: entry.parentMetaType)
                && entry.parentMetaType != "movie" ? entry.parentMetaId : nil
        })
        if shuffled != shuffleParentIds { shuffleParentIds = shuffled }
        let repo = CustomPosterUrlRepository.shared
        let pattern = repo.isScreenEnabled(screen: .continueWatching)
            ? repo.patternForScreen(screen: .continueWatching) : ""
        if pattern != posterPattern { posterPattern = pattern }
    }
}

/// The two rows, each hidden while empty. Each row is its own full-width focus section (the rows'
/// own `.focusSection()`), so Up and Down move between them and the Library controls below.
struct LibraryProviderRowsView: View {
    @ObservedObject var model: LibraryProviderRowsModel
    /// Opens the stream picker for a Continue Watching card (`LibraryView.resume`).
    let onResume: (ResumeTarget) -> Void
    /// Continue Watching › Go to Details.
    let onGoToDetails: (WatchProgressEntry) -> Void
    /// Home's Remove / Mark Episode Watched, which touch no Home state.
    let cardActions: HomeRowActions

    var body: some View {
        if !model.resumeWatching.isEmpty {
            ContinueWatchingRow(
                entries: model.resumeWatching,
                onSelect: { onResume(ResumeTarget(entry: $0)) },
                onRemove: { [cardActions] in cardActions.removeProgress($0) },
                onGoToDetails: onGoToDetails,
                onPlayManually: { onResume(ResumeTarget(entry: $0, forceManual: true)) },
                onStartOver: { onResume(ResumeTarget(entry: $0, startFromBeginning: true)) },
                onMarkWatched: { [cardActions] in cardActions.markWatched($0) },
                shuffleParentIds: model.shuffleParentIds,
                posterPattern: model.posterPattern,
                title: "Resume Watching"
            )
            .id("library-resume-watching-row")
        }

        if let section = model.watchlistSection {
            CatalogRowView(section: section)
                .id("library-watchlist-row")
        }
    }
}
