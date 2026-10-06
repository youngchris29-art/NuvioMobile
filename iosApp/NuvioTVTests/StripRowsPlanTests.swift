import XCTest
import SharedCore
@testable import NuvioTV

/// Home Stage & Strip: the source-agnostic strip-row plan (`StripRowsPlan`), moved out of the
/// folder page. These pin it on hand-built `StripRow`s; `FolderRowsPlanTests` still pins the folder
/// page through `FolderRowsPlan`'s forwarders (the regression oracle).
@MainActor
final class StripRowsPlanTests: XCTestCase {

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

    private func key(_ order: Int) -> String { "row_\(order)" }

    private func section(_ order: Int, items: [MetaPreview]) -> HomeCatalogSection {
        HomeCatalogSection(key: key(order),
                           title: "Row \(order)",
                           subtitle: "Movie",
                           addonName: "",
                           target: CatalogTargetAddon(manifestUrl: "https://addon.test/manifest.json",
                                                      contentType: "movie",
                                                      catalogId: "top",
                                                      genre: nil,
                                                      search: nil,
                                                      supportsPagination: true),
                           items: Array(items.prefix(StripRowsPlan.previewLimit)),
                           availableItemCount: Int32(items.count),
                           hasMore: false)
    }

    private func row(_ order: Int,
                     _ status: StripRowStatus,
                     heading: String? = nil,
                     items rowItems: [MetaPreview]? = nil,
                     hasMore: Bool = false) -> StripRow {
        let shown = status == .loaded ? (rowItems ?? items(3)) : []
        return StripRow(id: key(order),
                        order: order,
                        heading: heading ?? "Row \(order)",
                        status: status,
                        section: status == .loaded ? section(order, items: shown) : nil,
                        itemKeys: shown.prefix(StripRowsPlan.previewLimit).map(StripRowsPlan.itemKey),
                        itemCount: shown.count,
                        hasMore: hasMore)
    }

    /// loaded 1, failed 2, loading 3, empty 4, loaded 5.
    private var mixedRows: [StripRow] {
        [row(1, .loaded), row(2, .failed), row(3, .loading), row(4, .empty), row(5, .loaded)]
    }

    // MARK: - Constants

    func testPreviewLimitMatchesHomeRows() {
        XCTAssertEqual(StripRowsPlan.previewLimit, CatalogRowView.homePreviewLimit)
        XCTAssertEqual(StripRowsPlan.previewLimit, 18)
        XCTAssertEqual(StripRowsPlan.skeletonCount, 6)
        XCTAssertEqual(StripRowsPlan.initialFocusWaitLimit, 2.0)
    }

    func testFolderForwardersMatch() {
        XCTAssertEqual(FolderRowsPlan.previewLimit, StripRowsPlan.previewLimit)
        XCTAssertEqual(FolderRowsPlan.skeletonCount, StripRowsPlan.skeletonCount)
        XCTAssertEqual(FolderRowsPlan.initialFocusWaitLimit, StripRowsPlan.initialFocusWaitLimit)
    }

    func testPageStateTokens() {
        XCTAssertEqual(StripRowsPlan.PageState.rows.token, "rows")
        XCTAssertEqual(StripRowsPlan.PageState.loading.token, "loading")
        XCTAssertEqual(StripRowsPlan.PageState.empty.token, "empty")
        XCTAssertEqual(StripRowsPlan.PageState.failed.token, "failed")
    }

    // MARK: - Row model

    func testOnlyLoadedRowsAreFocusable() {
        XCTAssertEqual(mixedRows.map(\.isFocusable), [true, false, false, false, true])
    }

    func testItemKeyCarriesTypeIdAndPoster() {
        XCTAssertEqual(StripRowsPlan.itemKey(item("tt1")), "movie:tt1|")
        XCTAssertEqual(StripRowsPlan.itemKey(item("tt1", poster: "https://p.test/a.jpg")), "movie:tt1|https://p.test/a.jpg")
    }

    // MARK: - Equality and reuse

    func testRebuildWithTheSameItemsIsEqualAndKeepsTheSection() {
        let first = [row(1, .loaded, items: items(5)), row(2, .loading)]
        let second = [row(1, .loaded, items: items(5)), row(2, .loading)]
        XCTAssertEqual(first, second, "fresh section instances with the same identities are ==")
        XCTAssertFalse(first[0].section === second[0].section)
        let merged = StripRowsPlan.reusing(first, for: second)
        XCTAssertTrue(merged[0].section === first[0].section, "an unchanged row keeps its section instance")
        XCTAssertEqual(merged, second)
    }

    func testChangesBreakEquality() {
        let base = [row(1, .loaded, items: items(5))]
        XCTAssertNotEqual(base, [row(1, .loaded, items: items(6))], "a new item")
        XCTAssertNotEqual(base, [row(1, .loaded, items: items(5), hasMore: true)], "hasMore")
        XCTAssertNotEqual(base, [row(1, .loaded, heading: "Renamed", items: items(5))], "heading")
        XCTAssertNotEqual(base, [row(1, .loading)], "status")
        var reposted = items(5)
        reposted[2] = item("tt2", poster: "https://example.test/custom.jpg")
        XCTAssertNotEqual(base, [row(1, .loaded, items: reposted)], "a re-postered item")
        let reordered = StripRow(id: key(1), order: 9, heading: "Row 1", status: .loaded, section: base[0].section,
                                 itemKeys: base[0].itemKeys, itemCount: base[0].itemCount, hasMore: false)
        XCTAssertNotEqual(base[0], reordered, "order")
        // A changed row is the new instance.
        let changed = [row(1, .loaded, items: items(6))]
        let merged = StripRowsPlan.reusing(base, for: changed)
        XCTAssertTrue(merged[0].section === changed[0].section)
    }

    func testReusingWithNoPreviousReturnsNext() {
        let next = [row(1, .loaded)]
        XCTAssertTrue(StripRowsPlan.reusing([], for: next)[0].section === next[0].section)
    }

    // MARK: - Visibility

    func testNoFocusRemovesEveryEmptyAndFailedRowAndKeepsLoading() {
        XCTAssertEqual(StripRowsPlan.visible(mixedRows, focusedOrder: nil).map(\.order), [1, 3, 5])
    }

    func testEmptyAndFailedRowsShowOnlyAboveTheFocusedRow() {
        XCTAssertEqual(StripRowsPlan.visible(mixedRows, focusedOrder: 5).map(\.order), [1, 2, 3, 4, 5],
                       "above the focus: kept")
        XCTAssertEqual(StripRowsPlan.visible(mixedRows, focusedOrder: 3).map(\.order), [1, 2, 3, 5],
                       "the failed row above stays, the empty row below goes")
        XCTAssertEqual(StripRowsPlan.visible(mixedRows, focusedOrder: 1).map(\.order), [1, 3, 5],
                       "below the focus: removed; the loading row always stays")
    }

    // MARK: - Focus helpers

    func testFirstFocusable() {
        XCTAssertEqual(StripRowsPlan.firstFocusable([row(1, .loading), row(2, .failed), row(3, .loaded), row(4, .loaded)])?.id,
                       key(3))
        XCTAssertNil(StripRowsPlan.firstFocusable([row(1, .loading), row(2, .empty)]))
        XCTAssertNil(StripRowsPlan.firstFocusable([]))
    }

    func testInitialFocusWaitsForALoadingRowAbove() {
        let built = [row(1, .loading), row(2, .loaded)]
        XCTAssertNil(StripRowsPlan.initialFocusTarget(built, waitOver: false))
        XCTAssertEqual(StripRowsPlan.initialFocusTarget(built, waitOver: true)?.id, key(2))
    }

    func testInitialFocusNeverWaitsOnFailedOrEmptyRowsOrRowsBelow() {
        XCTAssertEqual(StripRowsPlan.initialFocusTarget([row(1, .loaded), row(2, .loading)], waitOver: false)?.id, key(1))
        XCTAssertEqual(StripRowsPlan.initialFocusTarget([row(1, .failed), row(2, .empty), row(3, .loaded)],
                                                        waitOver: false)?.id, key(3))
        XCTAssertNil(StripRowsPlan.initialFocusTarget([row(1, .loading)], waitOver: true))
        XCTAssertNil(StripRowsPlan.initialFocusTarget([], waitOver: true))
    }

    func testFocusablePositionCountsOnlyFocusableRows() {
        let built = [row(1, .failed), row(2, .loaded), row(3, .loading), row(4, .loaded)]
        XCTAssertEqual(StripRowsPlan.focusablePosition(of: key(2), in: built), 0)
        XCTAssertEqual(StripRowsPlan.focusablePosition(of: key(4), in: built), 1)
        XCTAssertNil(StripRowsPlan.focusablePosition(of: key(1), in: built))
        XCTAssertNil(StripRowsPlan.focusablePosition(of: key(3), in: built))
        XCTAssertNil(StripRowsPlan.focusablePosition(of: "row_99", in: built))
    }

    // MARK: - Page state

    func testPageState() {
        XCTAssertEqual(StripRowsPlan.pageState(mixedRows, allSettled: false), .rows)
        XCTAssertEqual(StripRowsPlan.pageState(mixedRows, allSettled: true), .rows)
        XCTAssertEqual(StripRowsPlan.pageState([row(1, .loading), row(2, .failed)], allSettled: false), .loading)
        XCTAssertEqual(StripRowsPlan.pageState([row(1, .empty), row(2, .failed)], allSettled: true), .empty,
                       "not every row failed")
        XCTAssertEqual(StripRowsPlan.pageState([row(1, .failed), row(2, .failed)], allSettled: true), .failed)
        XCTAssertEqual(StripRowsPlan.pageState([], allSettled: false), .loading)
        XCTAssertEqual(StripRowsPlan.pageState([], allSettled: true), .empty)
    }

    // MARK: - nonBlank

    func testNonBlank() {
        XCTAssertNil(StripRowsPlan.nonBlank(nil))
        XCTAssertNil(StripRowsPlan.nonBlank(""))
        XCTAssertNil(StripRowsPlan.nonBlank("   \n"))
        XCTAssertEqual(StripRowsPlan.nonBlank(" https://x.test/c.jpg "), "https://x.test/c.jpg")
    }
}
