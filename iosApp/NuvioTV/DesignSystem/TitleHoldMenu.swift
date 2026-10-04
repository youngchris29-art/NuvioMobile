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
/// - Library grid (Library L1, 2026-10-04): `libraryHoldMenu(preview:extra:)`, the watched action
///   followed by the grid's own list-aware remove. The library toggle is left out there: on a
///   Trakt / Simkl / MDBList list `toggleSaved` flips the provider's watchlist, not that list.
///
/// Deliberately NOT attached to Detail rails, Person rails, the Upcoming row, or episode cards.
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

    // MARK: - Explicit actions (fix round 1)

    /// What the library button does. Decided from the state its LABEL was built from, never from
    /// whatever the repository says at tap time: a button that reads "Add to Library" adds.
    enum LibraryAction: Equatable {
        case save
        case remove
    }

    /// What the watched button does, on the same rule as `LibraryAction`.
    enum WatchedAction: Equatable {
        case mark
        case unmark
    }

    /// The action a library button labelled with `libraryLabel(isSaved:)` performs.
    static func libraryAction(isSaved: Bool) -> LibraryAction {
        isSaved ? .remove : .save
    }

    /// The action a watched button labelled with `watchedLabel(isWatched:isSeries:)` performs.
    static func watchedAction(isWatched: Bool) -> WatchedAction {
        isWatched ? .unmark : .mark
    }

    /// Guard for the repository entry points that only exist as TOGGLES (`toggleSaved`, which also
    /// routes to the active Trakt / Simkl library provider, and `togglePosterWatchedAsync`, which
    /// marks or unmarks a whole series depending on what it finds when it runs). A toggle flips
    /// whatever the live state is, so it may only run while the live state still equals the state
    /// the label was built from; when something else changed the title in between (Detail,
    /// finished playback, a sync pull) the label is stale and the tap does nothing.
    static func labelStillMatchesLiveState(labelState: Bool, liveState: Bool) -> Bool {
        labelState == liveState
    }

    // MARK: - Detail Play button (hold Play → Choose Source…)

    /// Whether the Detail Play button carries its "Choose Source…" menu. Only while Auto-Play Best
    /// Source is on (with it off a plain press already opens the source list, so the menu would
    /// duplicate it) and only while Play itself is enabled (a disabled Play never carries a menu).
    /// The modifier is attached regardless and renders an empty menu when this is false, so the
    /// Play button's view identity never depends on a setting.
    static func holdPlayMenuAvailable(autoPlayFirstStreamOn: Bool, isPlayEnabled: Bool) -> Bool {
        autoPlayFirstStreamOn && isPlayEnabled
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

    /// Library L1: the Library grid's hold menu. The watched action first, then `extra` (the
    /// grid's remove, which knows which list is open). Place it AFTER `.posterButtonShape()`.
    func libraryHoldMenu<Extra: View>(
        preview: MetaPreview,
        @ViewBuilder extra: @escaping () -> Extra
    ) -> some View {
        modifier(LibraryHoldMenuModifier(preview: preview, extra: extra))
    }
}

/// `TitleHoldMenuModifier` without the library toggle, plus the caller's items. Same revision
/// bump, so the next hold re-reads the watched state after an action.
private struct LibraryHoldMenuModifier<Extra: View>: ViewModifier {
    let preview: MetaPreview
    let extra: () -> Extra
    @State private var revision = 0

    func body(content: Content) -> some View {
        content.contextMenu {
            TitleHoldMenuItems(preview: preview, revision: revision, includesLibraryAction: false) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    revision &+= 1
                }
            }
            extra()
        }
    }
}

private struct TitleHoldMenuModifier: ViewModifier {
    let preview: MetaPreview
    /// Bumped shortly after every menu action. The card never observes the library / watched
    /// stores (a store write would re-render every card and flicker an open menu), so this is what
    /// makes the NEXT hold re-read the state: the menu items take it as an input, so a bump
    /// re-resolves them even if the menu content was built ahead of presentation. It is bumped
    /// from a short `Task` AFTER the action, not before: the series toggle finishes on a
    /// background dispatcher, so an immediate bump would re-read the state it is about to change.
    ///
    /// There is deliberately no `.onAppear` bump. That would be one `@State` write per card mount
    /// on every Home row (a re-render per card at scroll-in), and the buttons no longer depend on
    /// freshness for correctness: each performs the action its own label names and declines to run
    /// when the live state has moved on (`labelStillMatchesLiveState`).
    @State private var revision = 0

    func body(content: Content) -> some View {
        content.contextMenu {
            TitleHoldMenuItems(preview: preview, revision: revision) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    revision &+= 1
                }
            }
        }
    }
}

/// The two menu buttons. Repository state is read in THIS body, i.e. when the menu content is
/// built, not by the card.
private struct TitleHoldMenuItems: View {
    let preview: MetaPreview
    /// Only here so a bump from `TitleHoldMenuModifier` changes this view's inputs.
    let revision: Int
    /// False on the Library grid, which brings its own list-aware remove (Library L1).
    var includesLibraryAction = true
    let didAct: () -> Void

    var body: some View {
        let isSeries = TitleHoldMenuPolicy.isSeries(type: preview.type)
        // Captured once per build: the labels below and the actions the buttons perform both come
        // from these two values, so they cannot disagree.
        let isSaved = Self.liveSaved(preview)
        let isWatched = Self.liveWatched(preview, isSeries: isSeries)
        // BUG-125 probe: tvOS evaluates this body when it is about to PRESENT the menu, so this line
        // proves the hold was recognised as a long press; its absence on a hold means the press
        // never became one (Orivio's split). Log-only, keys nothing but the title id.
        let _ = NSLog("[HoldMenu] menu built id=%@", preview.id)

        if includesLibraryAction {
            Button {
                performLibraryAction(labelIsSaved: isSaved)
                didAct()
            } label: {
                Label(TitleHoldMenuPolicy.libraryLabel(isSaved: isSaved),
                      systemImage: TitleHoldMenuPolicy.libraryIcon(isSaved: isSaved))
            }
        }

        Button {
            performWatchedAction(labelIsWatched: isWatched, isSeries: isSeries)
            didAct()
        } label: {
            Label(TitleHoldMenuPolicy.watchedLabel(isWatched: isWatched, isSeries: isSeries),
                  systemImage: TitleHoldMenuPolicy.watchedIcon(isWatched: isWatched))
        }
    }

    // MARK: - Live state

    private static func liveSaved(_ preview: MetaPreview) -> Bool {
        LibraryRepository.shared.isSaved(id: preview.id, type: preview.type)
    }

    private static func liveWatched(_ preview: MetaPreview, isSeries: Bool) -> Bool {
        TitleHoldMenuPolicy.effectiveWatched(
            titleMarked: WatchedRepository.shared.isWatched(id: preview.id, type: preview.type, season: nil, episode: nil),
            fullyWatchedSeries: isSeries
                ? WatchedRepository.shared.isFullyWatchedSeries(id: preview.id, type: preview.type)
                : false,
            isSeries: isSeries
        )
    }

    // MARK: - Actions

    /// "Add to Library" / "Remove from Library". `LibraryRepository.save(item:)` and `remove(id:)`
    /// only touch the LOCAL library; `toggleSaved(item:)` is the one entry that also routes to the
    /// active Trakt / Simkl library provider (and `isSaved` already reads the provider's state), so
    /// it stays the call here. It flips the live state, hence the guard: it runs only while the
    /// live state still equals what the label said, which makes it exactly `libraryAction(isSaved:)`.
    private func performLibraryAction(labelIsSaved: Bool) {
        let liveIsSaved = Self.liveSaved(preview)
        guard TitleHoldMenuPolicy.labelStillMatchesLiveState(labelState: labelIsSaved, liveState: liveIsSaved) else {
            print("[HoldMenu] library action skipped for \(preview.type):\(preview.id): label offered \(TitleHoldMenuPolicy.libraryAction(isSaved: labelIsSaved)), saved is now \(liveIsSaved)")
            return
        }
        // The repo stamps `savedAtEpochMs` itself, so 0 (same as Detail's toggleLibrary).
        LibraryRepository.shared.toggleSaved(item: preview.toLibraryItem(savedAtEpochMs: 0))
    }

    /// "Mark as Watched" / "Mark as Unwatched".
    private func performWatchedAction(labelIsWatched: Bool, isSeries: Bool) {
        if isSeries {
            // Mark-all / unmark-all across the released episodes. The shared side only has the
            // toggle (it fetches the series' meta first, so it is fire-and-forget), and it decides
            // mark vs unmark from the live state when it starts: guard it like the library toggle.
            let liveIsWatched = Self.liveWatched(preview, isSeries: true)
            guard TitleHoldMenuPolicy.labelStillMatchesLiveState(labelState: labelIsWatched, liveState: liveIsWatched) else {
                print("[HoldMenu] watched action skipped for \(preview.type):\(preview.id): label offered \(TitleHoldMenuPolicy.watchedAction(isWatched: labelIsWatched)), watched is now \(liveIsWatched)")
                return
            }
            WatchingActions.shared.togglePosterWatchedAsync(preview: preview)
            return
        }
        // Movies have explicit entry points, so no live read is needed. The repo stamps
        // `markedAtEpochMs` itself, so 0 (same as Detail's toggleWatched).
        let item = preview.toWatchedItem(markedAtEpochMs: 0)
        switch TitleHoldMenuPolicy.watchedAction(isWatched: labelIsWatched) {
        case .mark: WatchedRepository.shared.markWatched(item: item)
        case .unmark: WatchedRepository.shared.unmarkWatched(item: item)
        }
    }
}
