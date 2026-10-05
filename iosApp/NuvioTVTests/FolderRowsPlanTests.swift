import XCTest
import SharedCore
@testable import NuvioTV

/// Home Stage & Strip (H5, W2-B; P2 spec §2.3, §2.4, §4.2): the folder Rows page's pure plan —
/// one strip row per source tab (no "All"), each row's status and section, which rows show, the
/// page state, and Q1's stage input (the folder until the first move, then focus for good).
@MainActor
final class FolderRowsPlanTests: XCTestCase {
    private let collectionId = "c1"
    private let folderId = "f1"

    // MARK: - Fixtures

    private func item(_ id: String, poster: String? = nil) -> MetaPreview {
        MetaPreview(
            id: id, type: "movie", name: "Title \(id)",
            poster: poster, banner: nil, logo: nil,
            posterShape: .poster,
            description: nil, releaseInfo: nil, rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: [],
            rawPosterUrl: nil,
            landscapePoster: nil,
            rawLandscapePosterUrl: nil,
            customPosterApplied: false
        )
    }

    private func items(_ count: Int) -> [MetaPreview] {
        (0..<count).map { item("tt\($0)") }
    }

    private let addonTarget = FolderTabSnapshot.Target.addon(
        manifestUrl: "https://addon.test/manifest.json",
        contentType: "movie",
        catalogId: "top",
        genre: nil,
        supportsPagination: true
    )

    private func tab(_ index: Int,
                     label: String? = nil,
                     isAll: Bool = false,
                     loading: Bool = false,
                     items: [MetaPreview] = [],
                     error: String? = nil,
                     canLoadMore: Bool = false,
                     hasTarget: Bool = true) -> FolderTabSnapshot {
        FolderTabSnapshot(tabIndex: index,
                          label: label ?? "Row \(index)",
                          typeLabel: "Movie",
                          isAllTab: isAll,
                          isLoading: loading,
                          items: items,
                          error: error,
                          canLoadMore: canLoadMore,
                          target: hasTarget ? addonTarget : nil)
    }

    private func rows(_ tabs: [FolderTabSnapshot]) -> [FolderStripRow] {
        FolderRowsPlan.rows(tabs, collectionId: collectionId, folderId: folderId)
    }

    private func key(_ tabIndex: Int) -> String {
        FolderRowsPlan.rowKey(folderId: folderId, tabIndex: tabIndex)
    }

    /// loaded(1), failed(2), loading(3), empty(4), loaded(5).
    private var mixedRows: [FolderStripRow] {
        rows([
            tab(1, items: items(3)),
            tab(2, error: "boom"),
            tab(3, loading: true),
            tab(4),
            tab(5, items: items(2)),
        ])
    }

    // MARK: - Rows

    func testAllTabOmittedAndTabOrderKept() {
        let built = rows([
            tab(0, label: "All", isAll: true, items: items(5)),
            tab(1, label: "Popular", items: items(2)),
            tab(2, label: "Trending", loading: true),
            tab(3, label: "Missing", error: "Addon not found: zz"),
        ])
        XCTAssertEqual(built.map(\.tabIndex), [1, 2, 3], "one row per source tab, in tab order")
        XCTAssertEqual(built.map(\.heading), ["Popular", "Trending", "Missing"])
        XCTAssertFalse(built.contains { $0.heading == "All" }, "Rows mode has no merged All row")
        XCTAssertEqual(built.map(\.id), ["folder_f1_1", "folder_f1_2", "folder_f1_3"])
    }

    /// The row id IS the section key: `CatalogRowView` reports focus ownership and card memory under
    /// `section.key`, and the strip pages by the key a row reports.
    func testRowIdIsTheSectionKey() throws {
        let row = try XCTUnwrap(rows([tab(4, items: items(3))]).first)
        XCTAssertEqual(row.id, "folder_f1_4")
        XCTAssertEqual(row.section?.key, row.id)
    }

    func testKeysDistinctForDuplicateLabels() {
        let built = rows([
            tab(1, label: "Top", items: items(2)),
            tab(2, label: "Top", items: items(2)),
        ])
        XCTAssertEqual(Set(built.map(\.id)).count, 2)
        XCTAssertEqual(Set(built.compactMap { $0.section?.key }).count, 2)
    }

    // MARK: - Status

    func testStatusMapping() {
        XCTAssertEqual(FolderRowsPlan.status(tab(1, items: items(2))), .loaded)
        XCTAssertEqual(FolderRowsPlan.status(tab(1, items: items(2), error: "page 2 failed")), .loaded,
                       "an error from a later page is ignored once the row has items")
        XCTAssertEqual(FolderRowsPlan.status(tab(1, loading: true, items: items(2))), .loaded)
        XCTAssertEqual(FolderRowsPlan.status(tab(1, loading: true)), .loading)
        XCTAssertEqual(FolderRowsPlan.status(tab(1, error: "boom")), .failed)
        XCTAssertEqual(FolderRowsPlan.status(tab(1)), .empty)
        XCTAssertEqual(FolderRowsPlan.status(tab(1, items: items(2), hasTarget: false)), .empty,
                       "no buildable target → empty")
        XCTAssertEqual(FolderRowsPlan.status(tab(1, items: items(2), error: "x", hasTarget: false)), .failed)
        XCTAssertEqual(FolderRowsPlan.status(tab(1, loading: true, items: items(2), hasTarget: false)), .loading)
    }

    func testOnlyLoadedRowsAreFocusable() {
        XCTAssertEqual(mixedRows.map(\.isFocusable), [true, false, false, false, true])
        XCTAssertNotNil(mixedRows[0].section)
        XCTAssertNil(mixedRows[1].section)
        XCTAssertNil(mixedRows[2].section)
        XCTAssertNil(mixedRows[3].section)
    }

    // MARK: - Visibility

    func testNoFocusRemovesEveryEmptyAndFailedRowAndKeepsLoading() {
        let shown = FolderRowsPlan.visible(mixedRows, focusedTabIndex: nil)
        XCTAssertEqual(shown.map(\.tabIndex), [1, 3, 5])
    }

    func testEmptyAndFailedRowsShowOnlyAboveTheFocusedRow() {
        XCTAssertEqual(FolderRowsPlan.visible(mixedRows, focusedTabIndex: 5).map(\.tabIndex), [1, 2, 3, 4, 5],
                       "above the focus: kept")
        XCTAssertEqual(FolderRowsPlan.visible(mixedRows, focusedTabIndex: 3).map(\.tabIndex), [1, 2, 3, 5],
                       "the failed row above stays, the empty row below goes")
        XCTAssertEqual(FolderRowsPlan.visible(mixedRows, focusedTabIndex: 1).map(\.tabIndex), [1, 3, 5],
                       "below the focus: removed; the loading row always stays")
    }

    // MARK: - Section

    func testSectionTrimsToEighteenAndKeepsCountAndHasMore() throws {
        let t = tab(1, label: "Top", items: items(30), canLoadMore: true)
        let section = try XCTUnwrap(FolderRowsPlan.section(t, collectionId: collectionId, folderId: folderId))
        XCTAssertEqual(section.items.count, 18)
        XCTAssertEqual(section.items.map(\.id), (0..<18).map { "tt\($0)" })
        XCTAssertEqual(section.availableItemCount, 30, "See All still shows: the whole count is kept")
        XCTAssertTrue(section.hasMore)
        XCTAssertEqual(section.key, "folder_f1_1")
        XCTAssertEqual(section.title, "Top")
        XCTAssertEqual(section.subtitle, "Movie")
        XCTAssertEqual(section.addonName, "", "no add-on suffix on folder rows")

        let noMore = try XCTUnwrap(FolderRowsPlan.section(tab(1, items: items(5)), collectionId: collectionId, folderId: folderId))
        XCTAssertFalse(noMore.hasMore)
        XCTAssertEqual(noMore.items.count, 5)
        XCTAssertEqual(noMore.availableItemCount, 5)
    }

    func testNoSectionWithoutItemsOrTarget() {
        XCTAssertNil(FolderRowsPlan.section(tab(1), collectionId: collectionId, folderId: folderId))
        XCTAssertNil(FolderRowsPlan.section(tab(1, items: items(3), hasTarget: false),
                                            collectionId: collectionId, folderId: folderId))
    }

    func testPreviewLimitMatchesHomeRows() {
        XCTAssertEqual(FolderRowsPlan.previewLimit, CatalogRowView.homePreviewLimit)
        XCTAssertEqual(FolderRowsPlan.previewLimit, 18)
    }

    // MARK: - Targets (from the repository's FolderTab)

    private func source(provider: String, addonId: String? = nil, type: String? = nil,
                        catalogId: String? = nil, genre: String? = nil) -> CollectionSource {
        CollectionSource(provider: provider, addonId: addonId, type: type, catalogId: catalogId, genre: genre,
                         tmdbSourceType: provider == "tmdb" ? "DISCOVER" : nil, title: "Source",
                         tmdbId: nil, traktListId: nil, mediaType: "movie",
                         sortBy: nil, sortHow: nil, filters: nil)
    }

    private func folderTab(source: CollectionSource?, sourceKey: String?, manifestUrl: String?,
                           type: String = "movie", catalogId: String = "top", genre: String? = nil,
                           supportsPagination: Bool = true, nextSkip: Int32? = 2,
                           items: [MetaPreview], error: String? = nil) -> FolderTab {
        FolderTab(label: "Source", typeLabel: "Movie", source: source, sourceKey: sourceKey,
                  manifestUrl: manifestUrl, type: type, catalogId: catalogId, genre: genre,
                  supportsPagination: supportsPagination, items: items, isLoading: false,
                  isLoadingMore: false, nextSkip: nextSkip.map { KotlinInt(int: $0) },
                  consecutiveDuplicatePages: 0, error: error, isAllTab: false)
    }

    func testCollectionSourceTargetForTmdbAndTrakt() throws {
        for provider in ["tmdb", "trakt"] {
            let tab = folderTab(source: source(provider: provider), sourceKey: "\(provider)_key",
                                manifestUrl: nil, items: items(3))
            let snapshot = FolderTabSnapshot(tab: tab, tabIndex: 2)
            XCTAssertEqual(snapshot.target,
                           .collectionSource(sourceKey: "\(provider)_key", contentType: "movie", supportsPagination: true),
                           provider)
            XCTAssertTrue(snapshot.canLoadMore, provider)
            let section = try XCTUnwrap(FolderRowsPlan.section(snapshot, collectionId: collectionId, folderId: folderId))
            let target = try XCTUnwrap(section.target as? CatalogTargetCollectionSource, provider)
            XCTAssertEqual(target.collectionId, collectionId)
            XCTAssertEqual(target.folderId, folderId)
            XCTAssertEqual(target.sourceKey, "\(provider)_key")
            XCTAssertEqual(target.contentType, "movie")
            XCTAssertTrue(target.supportsPagination)
        }
    }

    func testAddonTargetOtherwise() throws {
        let tab = folderTab(source: source(provider: "addon", addonId: "com.linvo.cinemeta", type: "series",
                                           catalogId: "top", genre: "Drama"),
                            sourceKey: "addon_key",
                            manifestUrl: "https://v3-cinemeta.strem.io/manifest.json",
                            type: "series", genre: "Drama", supportsPagination: false, nextSkip: nil,
                            items: items(4))
        let snapshot = FolderTabSnapshot(tab: tab, tabIndex: 1)
        XCTAssertEqual(snapshot.target,
                       .addon(manifestUrl: "https://v3-cinemeta.strem.io/manifest.json", contentType: "series",
                              catalogId: "top", genre: "Drama", supportsPagination: false))
        XCTAssertFalse(snapshot.canLoadMore)
        let section = try XCTUnwrap(FolderRowsPlan.section(snapshot, collectionId: collectionId, folderId: folderId))
        let target = try XCTUnwrap(section.target as? CatalogTargetAddon)
        XCTAssertEqual(target.manifestUrl, "https://v3-cinemeta.strem.io/manifest.json")
        XCTAssertEqual(target.contentType, "series")
        XCTAssertEqual(target.catalogId, "top")
        XCTAssertEqual(target.genre, "Drama")
        XCTAssertNil(target.search)
        XCTAssertFalse(target.supportsPagination)
    }

    func testMissingAddonOrRouteKeyBuildsNoTarget() {
        // The fixture's `zz.missing.addon` source: no manifest URL and "Addon not found" at once.
        let missing = folderTab(source: source(provider: "addon", addonId: "zz.missing.addon", type: "movie",
                                               catalogId: "zzmissing"),
                                sourceKey: "addon_key", manifestUrl: nil, items: [],
                                error: "Addon not found: zz.missing.addon")
        let missingSnapshot = FolderTabSnapshot(tab: missing, tabIndex: 4)
        XCTAssertNil(missingSnapshot.target)
        XCTAssertEqual(FolderRowsPlan.status(missingSnapshot), .failed)

        let noKey = folderTab(source: source(provider: "tmdb"), sourceKey: nil, manifestUrl: nil, items: items(2))
        let noKeySnapshot = FolderTabSnapshot(tab: noKey, tabIndex: 1)
        XCTAssertNil(noKeySnapshot.target)
        XCTAssertEqual(FolderRowsPlan.status(noKeySnapshot), .empty)
    }

    // MARK: - Equality and reuse

    func testRebuildWithTheSameItemsIsEqualAndKeepsTheSection() throws {
        let first = rows([tab(1, items: items(5), canLoadMore: true), tab(2, loading: true)])
        let second = rows([tab(1, items: items(5), canLoadMore: true), tab(2, loading: true)])
        XCTAssertEqual(first, second, "fresh item instances with the same identities are ==")
        let merged = FolderRowsPlan.reusing(first, for: second)
        XCTAssertTrue(merged[0].section === first[0].section, "an unchanged row keeps its section instance")
        XCTAssertEqual(merged, second)
    }

    func testChangesBreakEquality() {
        let base = rows([tab(1, items: items(5))])
        XCTAssertNotEqual(base, rows([tab(1, items: items(6))]), "a new item")
        XCTAssertNotEqual(base, rows([tab(1, items: items(5), canLoadMore: true)]), "hasMore")
        XCTAssertNotEqual(base, rows([tab(1, label: "Renamed", items: items(5))]), "heading")
        XCTAssertNotEqual(base, rows([tab(1, loading: true)]), "status")
        var reposted = items(5)
        reposted[2] = item("tt2", poster: "https://example.test/custom.jpg")
        XCTAssertNotEqual(base, rows([tab(1, items: reposted)]), "a re-postered item")
        // A changed row is the new instance.
        let changed = rows([tab(1, items: items(6))])
        let merged = FolderRowsPlan.reusing(base, for: changed)
        XCTAssertTrue(merged[0].section === changed[0].section)
    }

    func testCountBeyondThePreviewChangesEquality() {
        // 18 shown either way; only the whole count (the See All gate) differs.
        XCTAssertNotEqual(rows([tab(1, items: items(18))]), rows([tab(1, items: items(40))]))
    }

    // MARK: - Focus helpers

    func testFirstFocusable() {
        let built = rows([tab(1, loading: true), tab(2, error: "x"), tab(3, items: items(2)), tab(4, items: items(2))])
        XCTAssertEqual(FolderRowsPlan.firstFocusable(built)?.id, key(3))
        XCTAssertNil(FolderRowsPlan.firstFocusable(rows([tab(1, loading: true), tab(2)])))
        XCTAssertNil(FolderRowsPlan.firstFocusable([]))
    }

    func testFocusablePositionCountsOnlyFocusableRows() {
        // A failed row above the first loaded one does not push it off position 0 (the Edit band).
        let built = rows([tab(1, error: "x"), tab(2, items: items(2)), tab(3, loading: true), tab(4, items: items(2))])
        XCTAssertEqual(FolderRowsPlan.focusablePosition(of: key(2), in: built), 0)
        XCTAssertEqual(FolderRowsPlan.focusablePosition(of: key(4), in: built), 1)
        XCTAssertNil(FolderRowsPlan.focusablePosition(of: key(1), in: built))
        XCTAssertNil(FolderRowsPlan.focusablePosition(of: key(3), in: built))
        XCTAssertNil(FolderRowsPlan.focusablePosition(of: "folder_f1_99", in: built))
    }

    // MARK: - Page state

    func testPageState() {
        XCTAssertEqual(FolderRowsPlan.pageState(mixedRows, allSettled: false), .rows)
        XCTAssertEqual(FolderRowsPlan.pageState(mixedRows, allSettled: true), .rows)
        XCTAssertEqual(FolderRowsPlan.pageState(rows([tab(1, loading: true), tab(2, error: "x")]), allSettled: false),
                       .loading)
        XCTAssertEqual(FolderRowsPlan.pageState(rows([tab(1), tab(2, error: "x")]), allSettled: true), .empty,
                       "settled, nothing focusable, not every row failed")
        XCTAssertEqual(FolderRowsPlan.pageState(rows([tab(1, error: "x"), tab(2, error: "y")]), allSettled: true),
                       .failed)
        XCTAssertEqual(FolderRowsPlan.pageState([], allSettled: false), .loading)
        XCTAssertEqual(FolderRowsPlan.pageState([], allSettled: true), .empty, "a folder with no sources")
    }

    func testPageStateTokens() {
        XCTAssertEqual(FolderRowsPlan.PageState.rows.token, "rows")
        XCTAssertEqual(FolderRowsPlan.PageState.loading.token, "loading")
        XCTAssertEqual(FolderRowsPlan.PageState.empty.token, "empty")
        XCTAssertEqual(FolderRowsPlan.PageState.failed.token, "failed")
    }

    // MARK: - Stage input (Q1)

    func testStartsFollowing() {
        let row0 = key(1)
        let row1 = key(2)
        let initial = FolderStageInput.cardKey(rowId: row0, itemId: "tt0")
        XCTAssertFalse(FolderStageInput.startsFollowing(initial: nil, report: initial), "nil initial")
        XCTAssertFalse(FolderStageInput.startsFollowing(initial: initial, report: initial), "the initial card")
        XCTAssertTrue(FolderStageInput.startsFollowing(initial: initial,
                                                       report: FolderStageInput.cardKey(rowId: row0, itemId: "tt1")),
                      "another card in row 0")
        XCTAssertTrue(FolderStageInput.startsFollowing(initial: initial,
                                                       report: FolderStageInput.cardKey(rowId: row1, itemId: "tt0")),
                      "a card in row 1")
    }

    func testCardKey() {
        XCTAssertEqual(FolderStageInput.cardKey(rowId: "folder_f1_1", itemId: "tt7"), "folder_f1_1|tt7")
        XCTAssertEqual(FolderStageInput.cardKey(rowId: "folder_f1_1", itemId: nil), "folder_f1_1|-")
    }

    func testStepKeepsTheFolderUntilTheFirstMoveThenFollowsForGood() {
        let a = FolderStageInput.cardKey(rowId: key(1), itemId: "tt0")
        let b = FolderStageInput.cardKey(rowId: key(1), itemId: "tt1")

        // Nothing focused yet; focus leaving a row is not a move.
        var step = FolderStageInput.step(.initial, report: nil)
        XCTAssertEqual(step.state, .initial)
        XCTAssertFalse(step.forward)

        // The initial landing is recorded, not forwarded: the stage keeps the folder.
        step = FolderStageInput.step(step.state, report: a)
        XCTAssertEqual(step.state, FolderStageInput.State(initialCard: a, follows: false))
        XCTAssertFalse(step.forward)

        // Up to the Edit band (a nil report) and back to the same card: still the folder.
        step = FolderStageInput.step(step.state, report: nil)
        XCTAssertFalse(step.forward)
        XCTAssertFalse(step.state.follows)
        step = FolderStageInput.step(step.state, report: a)
        XCTAssertFalse(step.forward)
        XCTAssertFalse(step.state.follows)

        // The first move starts following and is forwarded.
        step = FolderStageInput.step(step.state, report: b)
        XCTAssertTrue(step.state.follows)
        XCTAssertTrue(step.forward)

        // No path back: the initial card again, and nil reports, are forwarded and keep following.
        step = FolderStageInput.step(step.state, report: a)
        XCTAssertTrue(step.state.follows)
        XCTAssertTrue(step.forward)
        step = FolderStageInput.step(step.state, report: nil)
        XCTAssertTrue(step.state.follows)
        XCTAssertTrue(step.forward)
        XCTAssertEqual(step.state.initialCard, a)
    }

    // MARK: - Misc

    func testNonBlank() {
        XCTAssertNil(FolderRowsPlan.nonBlank(nil))
        XCTAssertNil(FolderRowsPlan.nonBlank(""))
        XCTAssertNil(FolderRowsPlan.nonBlank("   \n"))
        XCTAssertEqual(FolderRowsPlan.nonBlank(" https://x.test/c.jpg "), "https://x.test/c.jpg")
    }
}
