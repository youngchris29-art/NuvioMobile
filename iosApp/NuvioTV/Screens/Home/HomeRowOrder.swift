import Foundation
import SharedCore

/// Home's non-catalog rows, in render order. The strings are the rows' focus keys
/// (`pinnedRowUpFallbackTarget(rowKey:)`, `reportRowFocus` sources, `StageStripHome` keys).
nonisolated enum HomeTopRowKey {
    static let continueWatching = "continue-watching"
    /// = `LibraryProviderRowsKt.HOME_WATCHLIST_ROW_KEY` (asserted in `HomeRowOrderTests`).
    static let watchlist = "home-watchlist"
    static let upcoming = "upcoming"
    /// The BUG-27 anchor on the rows `LazyVStack` (`HomeView.swift` L1587 `.id("home_top")`).
    static let topAnchor = "home_top"
    /// Decision P (b): Upcoming's own scroll anchor while a Watchlist row sits above it.
    static let upcomingAnchorBelowWatchlist = "home_upcoming_top"

    static func isTopRow(_ key: String) -> Bool {
        key == continueWatching || key == watchlist || key == upcoming
    }
}

/// The one source of Home's row order (Classic and Stage). Pure; built per use.
nonisolated struct HomeRowOrder: Equatable {
    /// A catalog or collection row from `model.rows`: its focus key (`section.key` / bare
    /// `collection.id`) and its `HomeRow.id` (scroll anchor and `pinnedLastRowId`).
    struct ModelRow: Equatable { let key: String; let rowId: String }

    struct Entry: Equatable {
        let key: String      // focus key
        let anchor: String   // id `proxy.scrollTo` needs
        let rowId: String    // HomeRow.id for model rows; the key for top rows
        let isTopRow: Bool
    }

    /// Render order, NOT de-duplicated (today's `previousRowTarget` order).
    let entries: [Entry]

    init(continueWatching: Bool, watchlist: Bool, upcoming: Bool, rows: [ModelRow]) {
        var e: [Entry] = []
        if continueWatching {
            e.append(Entry(key: HomeTopRowKey.continueWatching, anchor: HomeTopRowKey.topAnchor,
                           rowId: HomeTopRowKey.continueWatching, isTopRow: true))
        }
        if watchlist {
            e.append(Entry(key: HomeTopRowKey.watchlist, anchor: HomeTopRowKey.topAnchor,
                           rowId: HomeTopRowKey.watchlist, isTopRow: true))
        }
        if upcoming {
            e.append(Entry(key: HomeTopRowKey.upcoming,
                           anchor: watchlist ? HomeTopRowKey.upcomingAnchorBelowWatchlist : HomeTopRowKey.topAnchor,
                           rowId: HomeTopRowKey.upcoming, isTopRow: true))
        }
        for row in rows {
            e.append(Entry(key: row.key, anchor: row.rowId, rowId: row.rowId, isTopRow: false))
        }
        entries = e
    }

    /// Present top rows, in order (the remount set and the matrix's "top keys").
    var topKeys: [String] { entries.filter(\.isTopRow).map(\.key) }

    /// The row above `key` (first occurrence, as today), nil for the topmost or an unknown key.
    func previous(of key: String) -> Entry? {
        guard let i = entries.firstIndex(where: { $0.key == key }), i > 0 else { return nil }
        return entries[i - 1]
    }

    /// `HomeView.pinnedLastRowId`: last row's `rowId`, nil when nothing is laid out.
    var lastRowId: String? { entries.last?.rowId }

    /// The last entry's key when it is a top row (no model rows below), else nil.
    var lastTopRowKeyWhenNoModelRows: String? {
        guard let last = entries.last, last.isTopRow else { return nil }
        return last.key
    }

    /// `StageStripHome.rowKeys`: the same order, de-duplicated (first wins).
    var stripKeys: [String] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.key).inserted ? $0.key : nil }
    }
}

@MainActor
extension HomeRowOrder {
    /// The live order for Home. `watchlistEnabled` / `upcomingEnabled` are the two toggles.
    static func live(model: HomeViewModel, upcomingEnabled: Bool, watchlistEnabled: Bool) -> HomeRowOrder {
        HomeRowOrder(
            continueWatching: !model.continueWatching.isEmpty,
            watchlist: watchlistEnabled && model.watchlistSection != nil,
            upcoming: upcomingEnabled && !model.upcoming.isEmpty,
            rows: model.rows.map { row in
                switch row {
                case .catalog(let section): return ModelRow(key: section.key, rowId: row.id)
                case .collection(let collection): return ModelRow(key: collection.id, rowId: row.id)
                }
            }
        )
    }
}
