import SwiftUI
import SharedCore

// MARK: - Perf review 2026-10-17 (#1): Home's rows region, split out of `HomeView`
//
// `HomeView` observed five objects, and every hero focus commit (0.2 s after a card takes focus)
// re-ran its 600-line body and every visible row, card and trailer card: each row was handed fresh
// closures, so SwiftUI could never skip one. The rows now live in `HomeRowsList`, which observes
// `HomeViewModel` only and takes stable inputs: `HomeRowActions` (one reference for the life of
// Home), the pinned flags and the floors as plain values. Catalog and collection rows are further
// wrapped in `Equatable` cells, so a model publish that does not touch a row (Continue Watching
// progress, the hero list) does not re-render it either.
//
// Everything below is `HomeView.rowsScroll`'s former row content, moved verbatim apart from the
// callbacks, which now go through `HomeRowActions`. Order, modifiers and environment values are
// unchanged, and the view sits in the same `LazyVStack` slot (a custom view's content is flattened
// into the lazy stack, so laziness and spacing are as before).

/// The rows' callbacks into `HomeView`. One instance per Home lifetime (`@State` in `HomeView`), so
/// the reference the rows hold never changes. `HomeView` re-points the closures at its current
/// `self` on every body evaluation (`installRowActions`); a row calls them at event time, never
/// while rendering. Every closure only touches `@State` storage, the model and singletons, which a
/// copy of `HomeView` reaches exactly as the original does.
@MainActor
final class HomeRowActions {
    /// Continue Watching card actions that open the stream picker (`HomeView.resume`).
    var resume: (ResumeTarget) -> Void = { _ in }
    /// Continue Watching › Go to Details.
    var goToDetails: (WatchProgressEntry) -> Void = { _ in }
    /// UX-7 focus reports, one per row kind (`HomeView.reportRowFocus` underneath).
    var continueWatchingFocus: (WatchProgressEntry?) -> Void = { _ in }
    var upcomingFocus: (UpcomingEpisodeItem?) -> Void = { _ in }
    var catalogFocus: (MetaPreview?, HomeCatalogSection) -> Void = { _, _ in }
    /// BUG-38 round three / FEAT-33: a collection row's folder focus (`HomeView.handleFolderFocus`).
    var folderFocus: (NuvioCollection, CollectionFolder?) -> Void = { _, _ in }
    /// BUG-35: a catalog row mounted (`HomeViewModel.rowAppeared`).
    var catalogRowAppeared: (String) -> Void = { _ in }
    /// Wave H: a collection row mounted (`HomeView.prefetchCollectionHeroArt`).
    var collectionRowAppeared: (NuvioCollection) -> Void = { _ in }


    /// Continue Watching › Remove. An Up Next card is dismissed (synced with the phone); a
    /// progress card clears its progress and dismisses the Up Next its removal would uncover, so
    /// the series leaves the row (`ContinueWatchingNextUp.removeFromContinueWatching`).
    func removeProgress(_ entry: WatchProgressEntry) {
        ContinueWatchingNextUp.shared.removeFromContinueWatching(entry: entry)
    }

    /// Continue Watching › Mark Episode Watched / Mark as Watched.
    func markWatched(_ entry: WatchProgressEntry) {
        ContinueWatchingMark.perform(entry)
    }
}

/// The one Continue Watching "mark watched" implementation, shared by the Classic row
/// (`HomeRowActions`), the Stage Strip row and the Library resume row.
enum ContinueWatchingMark {
    static func perform(_ entry: WatchProgressEntry) {
        // FEAT-85 P2-4: under Trakt the mark seeds Up Next at once; the show's progress is refetched 5 s later.
        ContinueWatchingNextUp.shared.noteMarkedWatched(entry: entry)
        // Shared: marks watched (stamped now), clears the progress row unless the card is Up Next,
        // and reconciles series watched state for an episode, as a finished playback does.
        WatchingActions.shared.markProgressEntryWatched(
            entry: entry,
            nowEpochMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}

/// The `HomeView` state that still re-renders every row (perf review 2026-10-17, #1).
///
/// Before the split, ANY `HomeView` re-render rebuilt every row. The split keeps that for the events
/// below and drops it for the per-dwell ones (hero focus commits, resolver commits, carousel pages,
/// settle probe lines), which were the cost:
///  - `systemVideoAutoplayEnabled` — FEAT-25 (Codex beta.14 r5): the mirrored tvOS Auto-Play Video
///    Previews preference. `CatalogRowView` reads the system value itself while rendering, so a flip
///    must re-render the rows (review r1 P1).
///  - `coverDepth` / `resumeCovered` — a push over Home (`homePath`) or the Continue Watching stream
///    picker going up or down;
///  - `focusRequest` — every BUG-156 pop-restore rung and regrab, and every BUG-112 Up-fallback rung
///    (`HomeView.rowFocusRequest`);
///  - `focusedRowKey` — focus moving to another ROW (not a card hop inside one).
///
/// Device pass 2026-10-17 (Living Room ATV, Test 2, Classic, Nuvio-style hero): without the push /
/// pop / restore re-renders, Up from a collection tile right after Menu back from its folder page
/// went into the hero CTA and the rows above (Upcoming, Continue Watching) could not be reached; the
/// base reached Upcoming. The simulator does not reproduce the difference (its engine takes the CTA
/// on both builds, `testBatchC_ClassicFolderPopThenUp_Pinned`), so the fix restores the base's
/// re-renders around that path rather than a narrower guess at the mechanism.
struct HomeRowsRefresh: Equatable {
    var systemVideoAutoplayEnabled: Bool
    var coverDepth: Int
    var resumeCovered: Bool
    var focusRequest: PinnedRowFocusRequest
    var focusedRowKey: String?
}

/// Home's rows: the placeholder, Continue Watching, Upcoming, then the catalog and collection rows
/// in the user's Home Rows order. See the header above.
struct HomeRowsList: View {
    @ObservedObject var model: HomeViewModel
    let actions: HomeRowActions
    /// `HomeView.rowsScroll`'s `pinned` (the header's load boundary).
    let pinned: Bool
    let upcomingRowEnabled: Bool
    /// rc14 (BUG-122): About → "Short Row Floor (A/B)" (`debug.pinnedShortRowFloor`).
    let shortRowFloorEnabled: Bool
    /// BUG-87/89 (rc11): `PinnedRowGeometry.lastRowLinkFrameFloor` for the current plan.
    let lastRowFloor: CGFloat
    /// The `HomeView` state the rows must re-render on, as `HomeView`'s full re-render used to
    /// (see `HomeRowsRefresh`). Carried into the cells' `==` too.
    let refresh: HomeRowsRefresh
    /// Folder-return Up-skip (2026-10-17): the Continue Watching and Upcoming rows' identities,
    /// renewed after a pop (`HomeView.remountTopRowsAfterPop`). Kept out of `refresh`, which every
    /// catalog and collection cell compares, so a bump rebuilds these two rows only (review r1 P3).
    var continueWatchingToken: Int = 0
    var upcomingToken: Int = 0

    var body: some View {
        #if DEBUG
        let _ = HomeBodyCounter.tick("HomeRowsList")
        #endif
        let lastRowId = model.rows.last?.id

        if model.rows.isEmpty {
            placeholder
        }

        if !model.continueWatching.isEmpty {
            ContinueWatchingRow(
                entries: model.continueWatching,
                onSelect: { [actions] in actions.resume(ResumeTarget(entry: $0)) },
                onRemove: { [actions] in actions.removeProgress($0) },
                onGoToDetails: { [actions] in actions.goToDetails($0) },
                onPlayManually: { [actions] in actions.resume(ResumeTarget(entry: $0, forceManual: true)) },
                onStartOver: { [actions] in actions.resume(ResumeTarget(entry: $0, startFromBeginning: true)) },
                onMarkWatched: { [actions] in actions.markWatched($0) },
                shuffleParentIds: model.shuffleParentIds,
                posterPattern: model.continueWatchingPosterPattern,
                // UX-7 (see HomeView.reportRowFocus for the gating rationale).
                onItemFocusChange: { [actions] in actions.continueWatchingFocus($0) }
            )
            // rc14 (BUG-122): the short-row floor — see `shortRowLinkFrameFloor`.
            .environment(\.rowCardLinkFrameFloor, shortRowLinkFrameFloor)
            // Folder-return Up-skip: renewed after a pop (`HomeView.remountTopRowsAfterPop`).
            // A string apart from every catalog key and scroll anchor in this stack.
            .id("home-cw-row-\(continueWatchingToken)")
        }

        // Upcoming: next airing episode per followed show, directly under Continue
        // Watching and above every settings-ordered row (like CW, not part of
        // `model.rows`). Hidden while empty or toggled off.
        if upcomingRowEnabled, !model.upcoming.isEmpty {
            UpcomingRow(
                items: model.upcoming,
                onItemFocusChange: { [actions] in actions.upcomingFocus($0) }
            )
            // rc14 (BUG-122): the short-row floor — see `shortRowLinkFrameFloor`.
            .environment(\.rowCardLinkFrameFloor, shortRowLinkFrameFloor)
            // Folder-return Up-skip: as Continue Watching above.
            .id("home-upcoming-row-\(upcomingToken)")
        }

        // Catalog sections and collection folder-tile rows, interleaved per the
        // user's Home Rows settings order.
        ForEach(model.rows) { row in
            Group {
                switch row {
                case .catalog(let section):
                    HomeCatalogRowCell(section: section, actions: actions,
                                       refresh: refresh)
                        .equatable()
                        // BUG-35 (beta.12): localize this row's leading items when it scrolls
                        // into view. LazyVStack fires onAppear per row as it mounts; the shared
                        // repo dedups per item+language for the session, so re-appearing rows
                        // cost nothing (see HomeRepository.requestRowEnrichment).
                        .onAppear { actions.catalogRowAppeared(section.key) }
                case .collection(let collection):
                    HomeCollectionRowCell(collection: collection, actions: actions,
                                          refresh: refresh)
                        .equatable()
                        // Wave H: warm every folder's hero artwork when the ROW appears, not
                        // when a tile is first focused — the focus report and the artwork it
                        // needs used to fire on the same event, so the first focused folder
                        // always waited on a cold fetch (BUG-86 phenomenon D). Shares
                        // `prefetchedBackdropRows` with `reportRowFocus`, so whichever runs
                        // first pays for the row and the other is a no-op.
                        .onAppear { actions.collectionRowAppeared(collection) }
                }
            }
            // BUG-89: tells the settle tracker (BrowseComponents `PinnedRowSettleTracking`)
            // this row is the one `PinnedRowSettle` exempts from the canonical rest (no row
            // below to reveal into) — see `PinnedRowEnvironment.swift`. The bottom inset
            // (`HomeView.rowsInsets`) is the actual fix; this flag is what lets the tracker's
            // `debug_pinned` line say `last=1` instead of reading an unreachable rest as a
            // fresh failure.
            .environment(\.pinnedRowIsLast, row.id == lastRowId)
            // BUG-87/89 (rc11): the frame-shaping half of the last-row fix. Published on the
            // row `pinnedRowIsLast` marks, because that row has no content below it to force
            // the engine deeper — and only in pinned mode, where the reaches exist.
            //
            // rc14 (BUG-122): and on every COLLECTION row too — the mixed-shape row whose
            // square/landscape tiles make its label frame short. Catalog rows are uniform
            // (their label IS the plan's link frame) and stay unfloored. See
            // `shortRowLinkFrameFloor` for why a short label parks low.
            //
            // BUG-162 (Batch B): a catalog row the add-on tags as landscape (`posterShape`,
            // BUG-157) used to be floored here too, its 203 pt cards being a short label on
            // the poster regime's reaches. Its card SLOT is the poster height now (D16, rc5
            // verdict: the card rests at the folder-tile size, `PosterStyle.cardHeight`, and
            // grows to `expandedCardHeight` inside a poster-height slot), so it is a uniform
            // catalog row and takes no floor.
            .environment(\.rowCardLinkFrameFloor,
                         pinned && (row.id == lastRowId
                                    || (shortRowFloorEnabled && Self.isCollectionRow(row)))
                             ? lastRowFloor : 0)
        }
    }

    /// rc14 (BUG-122, every 2026-09-30 device walk): the SAME floor, published on the short rows
    /// above the catalogs — Continue Watching, Upcoming — and on collection rows. Their label
    /// frames are 120–200pt shorter than the plan's link frame (a 203pt landscape card or a square
    /// tile against a 403pt poster), so the engine's tolerated rest interval is wide and it parks
    /// them at the BOTTOM of it: Continue Watching +55, Upcoming +130/+160, the first folder row
    /// +128, then the corrector pulled each one up 11–117pt — the one visible jump left after the
    /// rest-law fix. With the label floored to the plan's frame the engine reveals the same frame
    /// for every row and parks them where it parks the poster rows (rest ≈ −8, in band). The
    /// layout growth the floor would cause between rows is cancelled inside each row component by a
    /// matching negative bottom padding (`PinnedRowGeometry.shortRowLayoutCompensation`), so only
    /// the focusable frame grows, never the visible spacing.
    ///
    /// Only while catalog rows exist below them: with `model.rows` empty one of these rows IS the
    /// last row, and that case keeps rc11's bottom-inset accounting (`HomeView.pinnedLastRowHeight`).
    private var shortRowLinkFrameFloor: CGFloat {
        guard pinned, shortRowFloorEnabled, !model.rows.isEmpty else { return 0 }
        return lastRowFloor
    }

    private static func isCollectionRow(_ row: HomeRow) -> Bool {
        if case .collection = row { return true }
        return false
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.isLoading {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Loading catalogs\u{2026}")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.vertical, Theme.Spacing.xl)
        } else if let message = model.errorMessage {
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.vertical, Theme.Spacing.xl)
        } else if let message = model.addonManifestError {
            // Upstream 085e8dc6: all add-on manifests failed. Retry is the focusable anchor for
            // this branch (BUG-47 rule) and the honest recovery — the add-ons are installed, their
            // manifests just didn't load.
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Couldn't load your add-ons.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.accent)
                Text(message)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
                Button {
                    AddonRepository.shared.refreshAll()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.chip)
            }
            .padding(.vertical, Theme.Spacing.xl)
        } else {
            Text("Setting up your catalogs\u{2026}")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.vertical, Theme.Spacing.xl)
        }
    }
}

/// A catalog row behind an `Equatable` gate (perf review 2026-10-17, #1): re-rendered only when its
/// section changes. The comparison is identity first, then the Kotlin data class's structural
/// `equals` (bridged as `isEqual`), so a republished but unchanged section is skipped too.
/// `CatalogRowView`'s environment reads (reaches, floors, trailer location) still update it on
/// their own.
struct HomeCatalogRowCell: View, Equatable {
    let section: HomeCatalogSection
    let actions: HomeRowActions
    /// Not read here: a change re-renders the row (see `HomeRowsRefresh`).
    let refresh: HomeRowsRefresh

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.actions === rhs.actions
            && lhs.refresh == rhs.refresh
            && (lhs.section === rhs.section || lhs.section == rhs.section)
    }

    var body: some View {
        CatalogRowView(
            section: section,
            previewLimit: CatalogRowView.homePreviewLimit,
            // UX-7 (see HomeView.reportRowFocus for the gating rationale).
            onItemFocusChange: { [actions, section] item in actions.catalogFocus(item, section) }
        )
    }
}

/// A collection row behind the same gate as `HomeCatalogRowCell`.
struct HomeCollectionRowCell: View, Equatable {
    let collection: NuvioCollection
    let actions: HomeRowActions
    /// See `HomeCatalogRowCell.refresh`.
    let refresh: HomeRowsRefresh

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.actions === rhs.actions
            && lhs.refresh == rhs.refresh
            && (lhs.collection === rhs.collection || lhs.collection == rhs.collection)
    }

    var body: some View {
        CollectionRowView(collection: collection, onFolderFocusChange: { [actions, collection] folder in
            actions.folderFocus(collection, folder)
        })
    }
}
