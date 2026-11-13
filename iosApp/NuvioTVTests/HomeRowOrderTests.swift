import XCTest
import SharedCore
@testable import NuvioTV

/// Home Watchlist row (FEAT-92), W3: `HomeRowOrder` is the one source of Home's top-row order
/// (Classic's `previousRowTarget` / `pinnedLastRowId` / remount set and Stage's strip keys). These
/// pin the eight Continue Watching x Watchlist x Upcoming states (spec section 3) and prove that
/// with the Watchlist absent the helper is exactly today's code (`testAbsentWatchlistIsIdenticalToToday`).
final class HomeRowOrderTests: XCTestCase {

    private typealias Order = HomeRowOrder
    private typealias Row = HomeRowOrder.ModelRow

    private let c1 = Row(key: "cat.a", rowId: "cat.a")
    private let k1 = Row(key: "col1", rowId: "collection_col1")

    private let cw = HomeTopRowKey.continueWatching
    private let wl = HomeTopRowKey.watchlist
    private let up = HomeTopRowKey.upcoming
    private let top = HomeTopRowKey.topAnchor
    private let upAnchor = HomeTopRowKey.upcomingAnchorBelowWatchlist

    // MARK: - Matrix helpers

    /// One matrix row: `previousExpected` maps a top key to its expected (key, anchor) or nil.
    private func check(
        cw hasCW: Bool, wl hasWL: Bool, up hasUP: Bool,
        topKeys: [String],
        firstKey: String?,
        previous: [String: (key: String, anchor: String)?],
        previousOfC1: (key: String, anchor: String)?,
        lastNoRows: String?,
        stripNoRows: [String],
        lastTopNoRows: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let bare = Order(continueWatching: hasCW, watchlist: hasWL, upcoming: hasUP, rows: [])
        let full = Order(continueWatching: hasCW, watchlist: hasWL, upcoming: hasUP, rows: [c1, k1])

        XCTAssertEqual(full.topKeys, topKeys, "top keys", file: file, line: line)
        XCTAssertEqual(bare.topKeys, topKeys, "top keys (no model rows)", file: file, line: line)
        XCTAssertEqual(bare.entries.first?.key, firstKey, "first row with no model rows", file: file, line: line)
        XCTAssertEqual(full.entries.first?.key, firstKey ?? c1.key, "first row with model rows", file: file, line: line)

        for key in topKeys {
            let expected = previous[key] ?? nil
            let actual = full.previous(of: key)
            XCTAssertEqual(actual?.key, expected?.key, "previous(of: \(key)) key", file: file, line: line)
            XCTAssertEqual(actual?.anchor, expected?.anchor, "previous(of: \(key)) anchor", file: file, line: line)
        }
        let beforeC1 = full.previous(of: c1.key)
        XCTAssertEqual(beforeC1?.key, previousOfC1?.key, "previous(of: c1) key", file: file, line: line)
        XCTAssertEqual(beforeC1?.anchor, previousOfC1?.anchor, "previous(of: c1) anchor", file: file, line: line)

        XCTAssertEqual(bare.lastRowId, lastNoRows, "lastRowId with no model rows", file: file, line: line)
        XCTAssertEqual(full.lastRowId, "collection_col1", "lastRowId with model rows", file: file, line: line)
        XCTAssertEqual(bare.stripKeys, stripNoRows, "stripKeys with no model rows", file: file, line: line)
        XCTAssertEqual(full.stripKeys, topKeys + [c1.key, k1.key], "stripKeys with model rows", file: file, line: line)
        XCTAssertEqual(bare.lastTopRowKeyWhenNoModelRows, lastTopNoRows, "last top key with no model rows", file: file, line: line)
        XCTAssertNil(full.lastTopRowKeyWhenNoModelRows, "last top key with model rows", file: file, line: line)
    }

    // MARK: - The eight states (spec section 3)

    func testState1_None() {
        check(cw: false, wl: false, up: false, topKeys: [], firstKey: nil, previous: [:],
              previousOfC1: nil, lastNoRows: nil,
              stripNoRows: [], lastTopNoRows: nil)
    }

    func testState2_UpcomingOnly() {
        check(cw: false, wl: false, up: true, topKeys: [up], firstKey: up,
              previous: [up: nil],
              previousOfC1: (up, top), lastNoRows: "upcoming",
              stripNoRows: [up], lastTopNoRows: up)
    }

    func testState3_WatchlistOnly() {
        check(cw: false, wl: true, up: false, topKeys: [wl], firstKey: wl,
              previous: [wl: nil],
              previousOfC1: (wl, top), lastNoRows: "home-watchlist",
              stripNoRows: [wl], lastTopNoRows: wl)
    }

    func testState4_WatchlistAndUpcoming() {
        check(cw: false, wl: true, up: true, topKeys: [wl, up], firstKey: wl,
              previous: [wl: nil, up: (wl, top)],
              previousOfC1: (up, upAnchor), lastNoRows: "upcoming",
              stripNoRows: [wl, up], lastTopNoRows: up)
    }

    func testState5_ContinueWatchingOnly() {
        check(cw: true, wl: false, up: false, topKeys: [cw], firstKey: cw,
              previous: [cw: nil],
              previousOfC1: (cw, top), lastNoRows: "continue-watching",
              stripNoRows: [cw], lastTopNoRows: cw)
    }

    func testState6_ContinueWatchingAndUpcoming() {
        check(cw: true, wl: false, up: true, topKeys: [cw, up], firstKey: cw,
              previous: [cw: nil, up: (cw, top)],
              previousOfC1: (up, top), lastNoRows: "upcoming",
              stripNoRows: [cw, up], lastTopNoRows: up)
    }

    func testState7_ContinueWatchingAndWatchlist() {
        check(cw: true, wl: true, up: false, topKeys: [cw, wl], firstKey: cw,
              previous: [cw: nil, wl: (cw, top)],
              previousOfC1: (wl, top), lastNoRows: "home-watchlist",
              stripNoRows: [cw, wl], lastTopNoRows: wl)
    }

    func testState8_AllThree() {
        check(cw: true, wl: true, up: true, topKeys: [cw, wl, up], firstKey: cw,
              previous: [cw: nil, wl: (cw, top), up: (wl, top)],
              previousOfC1: (up, upAnchor), lastNoRows: "upcoming",
              stripNoRows: [cw, wl, up], lastTopNoRows: up)
    }

    // MARK: - Legacy copies (verbatim logic from e1ac41691 / 996a274c4, adapted to booleans + ModelRow)

    /// `HomeView.previousRowTarget(for:)` (L2276-2293).
    private func legacyPreviousRowTarget(
        for rowKey: String, continueWatching: Bool, upcoming: Bool, rows: [Row]
    ) -> (key: String, anchor: String)? {
        var order: [(key: String, anchor: String)] = []
        if continueWatching { order.append((key: "continue-watching", anchor: "home_top")) }
        if upcoming { order.append((key: "upcoming", anchor: "home_top")) }
        for row in rows {
            order.append((key: row.key, anchor: row.rowId))
        }
        guard let index = order.firstIndex(where: { $0.key == rowKey }), index > 0 else { return nil }
        return order[index - 1]
    }

    /// `HomeView.pinnedLastRowId` (L3153-3158).
    private func legacyPinnedLastRowId(continueWatching: Bool, upcoming: Bool, rows: [Row]) -> String? {
        if let id = rows.last?.rowId { return id }
        if upcoming { return "upcoming" }
        if continueWatching { return "continue-watching" }
        return nil
    }

    /// `StageStripHome.rowKeys` (L201-219).
    private func legacyRowKeys(continueWatching: Bool, upcoming: Bool, rows: [Row]) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        if continueWatching, seen.insert("continue-watching").inserted {
            keys.append("continue-watching")
        }
        if upcoming, seen.insert("upcoming").inserted {
            keys.append("upcoming")
        }
        for row in rows {
            if seen.insert(row.key).inserted { keys.append(row.key) }
        }
        return keys
    }

    func testAbsentWatchlistIsIdenticalToToday() {
        let rowSets: [[Row]] = [[], [c1], [c1, k1], [c1, c1], [k1, c1]]
        var compared = 0
        for hasCW in [false, true] {
            for hasUP in [false, true] {
                for rows in rowSets {
                    let order = Order(continueWatching: hasCW, watchlist: false, upcoming: hasUP, rows: rows)
                    var keys = Set(rows.map(\.key))
                    keys.formUnion([cw, up, wl, "unknown"])
                    for key in keys {
                        let legacy = legacyPreviousRowTarget(for: key, continueWatching: hasCW, upcoming: hasUP, rows: rows)
                        let now = order.previous(of: key)
                        XCTAssertEqual(now?.key, legacy?.key, "previous key cw=\(hasCW) up=\(hasUP) rows=\(rows.map(\.key)) of \(key)")
                        XCTAssertEqual(now?.anchor, legacy?.anchor, "previous anchor cw=\(hasCW) up=\(hasUP) rows=\(rows.map(\.key)) of \(key)")
                        compared += 1
                    }
                    XCTAssertEqual(order.lastRowId,
                                   legacyPinnedLastRowId(continueWatching: hasCW, upcoming: hasUP, rows: rows),
                                   "lastRowId cw=\(hasCW) up=\(hasUP) rows=\(rows.map(\.key))")
                    XCTAssertEqual(order.stripKeys,
                                   legacyRowKeys(continueWatching: hasCW, upcoming: hasUP, rows: rows),
                                   "stripKeys cw=\(hasCW) up=\(hasUP) rows=\(rows.map(\.key))")
                    // The remount set and its log text: CW then Upcoming, as today's two `if`s.
                    var legacyTop: [String] = []
                    if hasCW { legacyTop.append("continue-watching") }
                    if hasUP { legacyTop.append("upcoming") }
                    XCTAssertEqual(order.topKeys, legacyTop)
                    XCTAssertEqual(order.topKeys.joined(separator: ","), legacyTop.joined(separator: ","))
                }
            }
        }
        XCTAssertGreaterThan(compared, 100)
    }

    // MARK: - The rest

    func testUpcomingAnchorFollowsTheWatchlist() {
        for hasCW in [false, true] {
            let without = Order(continueWatching: hasCW, watchlist: false, upcoming: true, rows: [c1])
            XCTAssertEqual(without.entries.first(where: { $0.key == up })?.anchor, top, "cw=\(hasCW)")
            XCTAssertEqual(without.previous(of: c1.key)?.anchor, top, "cw=\(hasCW)")

            let with = Order(continueWatching: hasCW, watchlist: true, upcoming: true, rows: [c1])
            XCTAssertEqual(with.entries.first(where: { $0.key == up })?.anchor, upAnchor, "cw=\(hasCW)")
            XCTAssertEqual(with.previous(of: c1.key)?.anchor, upAnchor, "cw=\(hasCW)")
        }
    }

    func testIsTopRow() {
        XCTAssertTrue(HomeTopRowKey.isTopRow("continue-watching"))
        XCTAssertTrue(HomeTopRowKey.isTopRow("home-watchlist"))
        XCTAssertTrue(HomeTopRowKey.isTopRow("upcoming"))
        XCTAssertFalse(HomeTopRowKey.isTopRow("cat.a"))
        XCTAssertFalse(HomeTopRowKey.isTopRow("collection_col1"))
        XCTAssertFalse(HomeTopRowKey.isTopRow(""))
    }

    func testWatchlistKeyAndCapMatchShared() {
        XCTAssertEqual(HomeTopRowKey.watchlist, LibraryProviderRowsKt.HOME_WATCHLIST_ROW_KEY)
        XCTAssertEqual(Int(LibraryProviderRowsKt.HomeWatchlistRowLimit), CatalogRowView.homePreviewLimit)
    }

    func testWatchlistSectionShowsNoSeeAllAtEighteen() {
        let previews = (0..<18).map { index in
            MetaPreview(
                id: "tt\(index)", type: "movie", name: "Title \(index)",
                poster: nil, banner: nil, logo: nil,
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
        let section = LibraryProviderRowsKt.homeWatchlistRowSectionOf(title: "Watchlist", previews: previews)
        XCTAssertEqual(section.key, HomeTopRowKey.watchlist)
        XCTAssertFalse(section.canOpenCatalog(previewLimit: 18))
    }
}
