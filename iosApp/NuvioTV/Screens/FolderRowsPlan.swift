import Foundation
import SharedCore

// Home Stage & Strip (H5, FEAT-43; P2 spec §2, W2-B): the folder Rows page's pure half.
//
// With Home Layout set to Stage, a collection folder opens as a stage-and-strip page
// (`FolderRowsPage`): the folder (then the focused title) on the stage, and one strip row per
// source tab below it, in tab order, without the "All" tab. Everything here is a pure function of
// the shared `FolderDetailRepository` state (mapped to `FolderTabSnapshot` by the view model) and a
// few page facts, so `FolderRowsPlanTests`, `FolderLayoutStoreTests` and `FolderStageLogoTests` pin
// it without a view host.
//
// Classic Home keeps today's folder grid exactly (`FolderPageLayout.resolve`).

// MARK: - Rows or Grid (§2.1)

/// Which page a collection folder opens as.
nonisolated enum FolderPageLayout: Hashable, Sendable {
    case rows
    case grid

    /// Classic Home keeps today's grid for every folder. Stage opens the Rows page unless the viewer
    /// chose Grid for this folder (Edit › Layout, stored device-locally by `FolderLayoutStore`).
    static func resolve(homeLayout: HomeLayout, gridOverride: Bool) -> FolderPageLayout {
        homeLayout == .classic || gridOverride ? .grid : .rows
    }
}

/// The device-local per-folder Grid choice (P2-6): one `@AppStorage` string, entries joined by
/// "\n", entry = "\(collectionId)\u{1F}\(folderId)" (folder ids are unique per COLLECTION only).
/// Only Grid choices are stored; a folder with no entry follows the Home layout. The synced
/// `Collection.viewMode` stays ignored on TV: its default is `TABBED_GRID`, so it cannot tell
/// "chose grid" from "never touched".
///
/// `-folder_layout_grid ""` as a launch argument shadows every stored choice for the whole process
/// (the argument domain wins over the app domain), which is what the folder UI legs pass.
nonisolated enum FolderLayoutStore {
    static let defaultsKey = "folder_layout_grid"
    /// Oldest entries drop off past this, so the string stays bounded however many folders exist.
    static let maxEntries = 200

    static func entryKey(collectionId: String, folderId: String) -> String {
        "\(collectionId)\u{1F}\(folderId)"
    }

    /// The stored entries in order (oldest first). Blank and whitespace-only lines are ignored.
    static func entries(_ raw: String) -> [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func isGrid(_ raw: String, collectionId: String, folderId: String) -> Bool {
        entries(raw).contains(entryKey(collectionId: collectionId, folderId: folderId))
    }

    /// The new raw string. `grid == true` appends the entry (deduplicated, newest last, the oldest
    /// dropped past `maxEntries`); `grid == false` removes it.
    static func setting(_ raw: String, grid: Bool, collectionId: String, folderId: String) -> String {
        let key = entryKey(collectionId: collectionId, folderId: folderId)
        var list = entries(raw).filter { $0 != key }
        if grid {
            list.append(key)
            if list.count > maxEntries {
                list.removeFirst(list.count - maxEntries)
            }
        }
        return list.joined(separator: "\n")
    }
}

// MARK: - Per-tab snapshot (§2.3)

/// One `FolderTab` as the Rows page reads it. The view model builds it from the repository state
/// (`init(tab:tabIndex:)`); the tests build it directly.
nonisolated struct FolderTabSnapshot {
    /// Where the row's See All goes: `getCatalogSectionsForRows`'s two target kinds
    /// (`FolderDetailRepository.kt:556–576`).
    nonisolated enum Target: Equatable {
        /// TMDB and Trakt tabs: the folder source itself.
        case collectionSource(sourceKey: String, contentType: String, supportsPagination: Bool)
        /// Add-on tabs whose add-on is installed.
        case addon(manifestUrl: String, contentType: String, catalogId: String, genre: String?,
                   supportsPagination: Bool)
    }

    /// The tab's index in `FolderDetailUiState.tabs` ("All" included when the folder shows it).
    let tabIndex: Int
    let label: String
    let typeLabel: String
    let isAllTab: Bool
    let isLoading: Bool
    let items: [MetaPreview]
    let error: String?
    let canLoadMore: Bool
    /// nil when no target can be built (an add-on tab whose add-on is missing, a direct source
    /// with no route key); such a tab never shows posters.
    let target: Target?
}

extension FolderTabSnapshot {
    /// The view model's mapping, exactly `getCatalogSectionsForRows`'s target rule: TMDB and Trakt
    /// tabs need their `sourceKey`, add-on tabs their `manifestUrl`.
    init(tab: FolderTab, tabIndex: Int) {
        let direct = tab.source.map { $0.isTmdb || $0.isTrakt } ?? false
        var target: Target?
        if direct {
            if let sourceKey = tab.sourceKey {
                target = .collectionSource(sourceKey: sourceKey,
                                           contentType: tab.type,
                                           supportsPagination: tab.supportsPagination)
            }
        } else if let manifestUrl = tab.manifestUrl {
            target = .addon(manifestUrl: manifestUrl,
                            contentType: tab.type,
                            catalogId: tab.catalogId,
                            genre: tab.genre,
                            supportsPagination: tab.supportsPagination)
        }
        self.init(tabIndex: tabIndex,
                  label: tab.label,
                  typeLabel: tab.typeLabel,
                  isAllTab: tab.isAllTab,
                  isLoading: tab.isLoading,
                  items: tab.items,
                  error: tab.error,
                  canLoadMore: tab.canLoadMore,
                  target: target)
    }
}

// MARK: - Row model (§2.3)

// The row model, the visibility rule, the initial focus wait and the page states live in
// `StripRowsPlan.swift` (shared with other strip pages). The folder page keeps its old names.
typealias FolderRowStatus = StripRowStatus
/// One strip row: one source tab of the folder (`order` is the tab index). See `StripRow`.
typealias FolderStripRow = StripRow

nonisolated enum FolderRowsPlan {
    static var previewLimit: Int { StripRowsPlan.previewLimit }
    static var skeletonCount: Int { StripRowsPlan.skeletonCount }
    typealias PageState = StripRowsPlan.PageState

    /// The strip key of tab `tabIndex`, which is also its section key (see `FolderStripRow`). The
    /// tab INDEX, not the label (`getCatalogSectionsForRows` keys on the label), so two sources with
    /// the same label never collide.
    static func rowKey(folderId: String, tabIndex: Int) -> String {
        "folder_\(folderId)_\(tabIndex)"
    }

    static func itemKey(_ item: MetaPreview) -> String { StripRowsPlan.itemKey(item) }

    static func status(_ t: FolderTabSnapshot) -> FolderRowStatus {
        if !t.items.isEmpty, t.target != nil { return .loaded }
        if t.isLoading { return .loading }
        if t.error != nil { return .failed }
        return .empty
    }

    /// The row's section, mirroring `getCatalogSectionsForRows` with two differences: the key is the
    /// tab index, and the items are trimmed to `previewLimit` (`availableItemCount` keeps the full
    /// count, so See All still shows). nil unless the tab has items and a target. Every Kotlin
    /// argument is passed: Kotlin defaults do not reach Swift.
    static func section(_ t: FolderTabSnapshot, collectionId: String, folderId: String) -> HomeCatalogSection? {
        guard !t.items.isEmpty, let target = t.target else { return nil }
        let catalogTarget: any CatalogTarget
        switch target {
        case .collectionSource(let sourceKey, let contentType, let supportsPagination):
            catalogTarget = CatalogTargetCollectionSource(collectionId: collectionId,
                                                          folderId: folderId,
                                                          sourceKey: sourceKey,
                                                          contentType: contentType,
                                                          supportsPagination: supportsPagination)
        case .addon(let manifestUrl, let contentType, let catalogId, let genre, let supportsPagination):
            catalogTarget = CatalogTargetAddon(manifestUrl: manifestUrl,
                                               contentType: contentType,
                                               catalogId: catalogId,
                                               genre: genre,
                                               search: nil,
                                               supportsPagination: supportsPagination)
        }
        return HomeCatalogSection(key: rowKey(folderId: folderId, tabIndex: t.tabIndex),
                                  title: t.label,
                                  subtitle: t.typeLabel,
                                  // Empty, so the Stage heading's "· add-on" suffix (W2-A) never
                                  // shows on a folder row.
                                  addonName: "",
                                  target: catalogTarget,
                                  items: Array(t.items.prefix(previewLimit)),
                                  availableItemCount: Int32(t.items.count),
                                  hasMore: t.canLoadMore)
    }

    /// One row per source tab, in tab order. The "All" tab is omitted (Rows mode has no merged row).
    static func rows(_ tabs: [FolderTabSnapshot], collectionId: String, folderId: String) -> [FolderStripRow] {
        tabs.filter { !$0.isAllTab }.map { t in
            let rowStatus = status(t)
            let rowSection = rowStatus == .loaded ? section(t, collectionId: collectionId, folderId: folderId) : nil
            return FolderStripRow(id: rowKey(folderId: folderId, tabIndex: t.tabIndex),
                                  order: t.tabIndex,
                                  heading: t.label,
                                  status: rowStatus,
                                  section: rowSection,
                                  itemKeys: rowStatus == .loaded ? t.items.prefix(previewLimit).map(itemKey) : [],
                                  itemCount: t.items.count,
                                  hasMore: t.canLoadMore)
        }
    }

    // Forwarders to `StripRowsPlan` (the folder page's names, unchanged behaviour).

    static func reusing(_ previous: [FolderStripRow], for next: [FolderStripRow]) -> [FolderStripRow] {
        StripRowsPlan.reusing(previous, for: next)
    }

    /// The focused TAB's index is the row `order` on the folder page.
    static func visible(_ rows: [FolderStripRow], focusedTabIndex: Int?) -> [FolderStripRow] {
        StripRowsPlan.visible(rows, focusedOrder: focusedTabIndex)
    }

    static func firstFocusable(_ rows: [FolderStripRow]) -> FolderStripRow? {
        StripRowsPlan.firstFocusable(rows)
    }

    static var initialFocusWaitLimit: TimeInterval { StripRowsPlan.initialFocusWaitLimit }

    static func initialFocusTarget(_ rows: [FolderStripRow], waitOver: Bool) -> FolderStripRow? {
        StripRowsPlan.initialFocusTarget(rows, waitOver: waitOver)
    }

    static func focusablePosition(of rowId: String, in rows: [FolderStripRow]) -> Int? {
        StripRowsPlan.focusablePosition(of: rowId, in: rows)
    }

    static func pageState(_ rows: [FolderStripRow], allSettled: Bool) -> PageState {
        StripRowsPlan.pageState(rows, allSettled: allSettled)
    }

    static func nonBlank(_ value: String?) -> String? { StripRowsPlan.nonBlank(value) }

    /// §2.4: the stage preview of a folder with neither a backdrop nor a logo, for which
    /// `HomeRowPreviews.folder` returns nil (Home keeps the previous title for such a folder, but the
    /// folder's own page must still open on the folder). The same id and type as the Home preview
    /// (`nuvio-folder://…`, `nuvio.folder`, so `isCollectionHero` gates trailers and enrichment), the
    /// folder title as its name, the collection title as the meta line, `folderHeroDescription` as
    /// the synopsis, and no artwork at all.
    @MainActor
    static func plainFolderPreview(collection: NuvioCollection, folder: CollectionFolder) -> MetaPreview {
        MetaPreview(
            id: "\(collectionHeroIdScheme)\(collection.id)/\(folder.id)",
            type: collectionHeroType,
            name: folder.title.trimmingCharacters(in: .whitespacesAndNewlines),
            poster: nil,
            banner: nil,
            logo: nil,
            posterShape: .poster,
            description: HomeView.folderHeroDescription(collection: collection, folder: folder),
            releaseInfo: collection.title.trimmingCharacters(in: .whitespacesAndNewlines),
            rawReleaseDate: nil,
            popularity: nil,
            voteCount: nil,
            imdbRating: nil,
            genres: [],
            rawPosterUrl: nil,
            landscapePoster: nil,
            rawLandscapePosterUrl: nil,
            customPosterApplied: false
        )
    }
}

// MARK: - What the stage shows (§2.4, Q1)

/// Q1 (decided 2026-10-05): the stage shows the folder from open until the viewer's first move,
/// then follows focus for good. A card key is "\(rowId)|\(itemId ?? "-")"; the initial card is the
/// first card report after open (the initial focus landing).
nonisolated enum FolderStageInput {
    /// What the page remembers between reports.
    nonisolated struct State: Equatable, Sendable {
        /// The first card report after open; nil before it.
        var initialCard: String?
        /// The stage follows focus (latched: once true, never false again).
        var follows: Bool

        static let initial = State(initialCard: nil, follows: false)
    }

    static func cardKey(rowId: String, itemId: String?) -> String {
        "\(rowId)|\(itemId ?? "-")"
    }

    /// A card report that is not the initial landing starts following.
    static func startsFollowing(initial: String?, report: String) -> Bool {
        initial != nil && report != initial
    }

    /// One focus report. `report` is the card key, or nil when focus left a row (Up to the Edit
    /// band, a push). Returns the new state and whether the report goes to the stage.
    ///
    /// - Before following: the first card report records the initial card; the initial card again
    ///   or a nil report changes nothing (Up to the Edit band and back keeps the folder on stage and
    ///   the logo docked); any other card starts following and is forwarded.
    /// - Following: every report is forwarded, the initial card and nil reports included (the
    ///   stage's own funnel handles a cross-row nil). There is no path back.
    static func step(_ state: State, report: String?) -> (state: State, forward: Bool) {
        if state.follows { return (state, true) }
        guard let report else { return (state, false) }
        guard state.initialCard != nil else {
            return (State(initialCard: report, follows: false), false)
        }
        guard startsFollowing(initial: state.initialCard, report: report) else { return (state, false) }
        return (State(initialCard: state.initialCard, follows: true), true)
    }
}

// MARK: - Folder logo (§2.5)

/// The folder logo's rise (H5, Steven's "title always visible"): docked in the stage's logo slot at
/// full size until the first move (Q1), then a 60 % title at the top-left, just above the stage
/// block, for the rest of the page's life (no re-dock, so no title moves after the strip rests).
nonisolated enum FolderStageLogo {
    static let compactScale: CGFloat = 0.6
    /// The compact logo's bottom → the stage block's top.
    static let compactGap: CGFloat = 8
    /// The compact logo never goes higher than this.
    static let compactTopFloor: CGFloat = 12

    /// Docked = drawn in the stage's logo slot at full size: only until the first move, never again.
    static func docked(followsFocus: Bool) -> Bool {
        !followsFocus
    }

    /// The compact logo's top: `compactGap` above the stage block, floored at `compactTopFloor`.
    static func compactTop(blockTop: CGFloat, slot: CGFloat) -> CGFloat {
        max(compactTopFloor, blockTop - compactGap - compactScale * slot)
    }

    /// The layer's vertical offset (its frame sits at `blockTop`; the scale anchors at its top).
    static func offsetY(docked: Bool, blockTop: CGFloat, slot: CGFloat) -> CGFloat {
        docked ? 0 : compactTop(blockTop: blockTop, slot: slot) - blockTop
    }
}
