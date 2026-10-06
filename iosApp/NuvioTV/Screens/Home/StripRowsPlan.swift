import Foundation
import SharedCore

// Home Stage & Strip: the pure half of a stage-and-strip rows page that is not tied to where the
// rows come from. Moved out of `FolderRowsPlan.swift` (the folder Rows page, H5 / FEAT-43, P2 spec
// §2.3) so another strip page (Discover) can reuse the row model, the visibility rule, the initial
// focus wait and the page states. The folder page reaches all of it through `FolderRowsPlan`'s
// forwarders and the `FolderStripRow` / `FolderRowStatus` aliases, unchanged.
//
// Everything here is a pure function of the rows, so `StripRowsPlanTests` (and the folder's
// `FolderRowsPlanTests`, through the forwarders) pin it without a view host.

// MARK: - Row model (§2.3)

/// What a strip row draws. First match, top down: loaded, loading, failed, empty.
nonisolated enum StripRowStatus: Equatable, Sendable {
    /// Posters, and a buildable See All target (an `error` from a later page is ignored).
    case loaded
    /// The first page is still on its way: heading + skeleton cards.
    case loading
    /// Settled with an error: heading + "Couldn't load this source."
    case failed
    /// Settled with nothing (or with no buildable target): heading + "Nothing here yet."
    case empty
}

/// One strip row (on the folder page: one source tab of the folder).
///
/// `id` is the row's strip key AND its section's key (on the folder page `FolderRowsPlan.rowKey`):
/// `CatalogRowView` reports focus ownership, records card memory and matches focus requests under
/// `section.key` (its `pinnedRowUpFallbackTarget(rowKey: section.key, …)`), and the strip pager
/// pages by the key a row reports, so the two must be the same string. One key per row, whatever
/// the status, so a row keeps its identity from loading to loaded.
nonisolated struct StripRow: Identifiable, Equatable {
    let id: String
    /// The row's place in the page's source order (on the folder page: the tab index in
    /// `FolderDetailUiState.tabs`). The visibility rule compares it with the focused row's.
    let order: Int
    let heading: String
    let status: StripRowStatus
    /// Non-nil only when `.loaded`.
    let section: HomeCatalogSection?
    /// The shown items' identities (first `previewLimit`), part of the equality key.
    let itemKeys: [String]
    /// The row's whole item count (`availableItemCount`, the See All gate), part of the equality key.
    let itemCount: Int
    /// The row can page further (`hasMore`, the See All gate), part of the equality key.
    let hasMore: Bool

    var isFocusable: Bool { status == .loaded }

    /// The equality key: everything a row draws, never the section instance. A rebuild with the same
    /// items is `==`, so the view model keeps the previous row and its `HomeCatalogSection`.
    static func == (lhs: StripRow, rhs: StripRow) -> Bool {
        lhs.id == rhs.id
            && lhs.order == rhs.order
            && lhs.heading == rhs.heading
            && lhs.status == rhs.status
            && lhs.itemKeys == rhs.itemKeys
            && lhs.itemCount == rhs.itemCount
            && lhs.hasMore == rhs.hasMore
    }
}

nonisolated enum StripRowsPlan {
    /// `CatalogRowView.homePreviewLimit` (18): strip rows don't paginate in place (P2-5). They show
    /// the first 18 items plus the See All tile, exactly like Home rows. A literal here because the
    /// view's constant is main-actor isolated; `StripRowsPlanTests` pins the two together.
    static let previewLimit = 18
    /// Skeleton cards drawn by a loading row.
    static let skeletonCount = 6

    /// What the page draws in its strip area (§2.3, "Page states").
    nonisolated enum PageState: Equatable, Sendable {
        /// At least one row has posters.
        case rows
        /// Nothing focusable yet and the sources are still loading: the skeleton rows.
        case loading
        /// Settled, nothing focusable, not every row failed: "Nothing here yet." + Go Back.
        case empty
        /// Settled and every row failed: "Couldn't load this folder." + Try Again + Go Back.
        case failed

        /// The `folder_rows_state … state=` token.
        var token: String {
            switch self {
            case .rows: return "rows"
            case .loading: return "loading"
            case .empty: return "empty"
            case .failed: return "failed"
            }
        }
    }

    /// One shown item's identity in the row's equality key. The poster is part of it so a re-postered
    /// item (custom poster pattern) re-renders.
    static func itemKey(_ item: MetaPreview) -> String {
        "\(item.type):\(item.id)|\(item.poster ?? "")"
    }

    /// `next`, where every row equal to the previous row with the same id is that previous
    /// instance, so its `HomeCatalogSection` (and the row view's input) does not change identity.
    static func reusing(_ previous: [StripRow], for next: [StripRow]) -> [StripRow] {
        guard !previous.isEmpty else { return next }
        var byId: [String: StripRow] = [:]
        for row in previous where byId[row.id] == nil {
            byId[row.id] = row
        }
        return next.map { row in
            if let kept = byId[row.id], kept == row { return kept }
            return row
        }
    }

    /// Visibility: loading and loaded rows always show. An empty or failed row shows only above the
    /// focused row (`order < focusedOrder`); with no focused row every one is removed. So a
    /// source that loads to nothing never leaves a dead page below the viewer, and nothing above the
    /// focused row ever vanishes.
    static func visible(_ rows: [StripRow], focusedOrder: Int?) -> [StripRow] {
        rows.filter { row in
            switch row.status {
            case .loaded, .loading:
                return true
            case .empty, .failed:
                guard let focusedOrder else { return false }
                return row.order < focusedOrder
            }
        }
    }

    static func firstFocusable(_ rows: [StripRow]) -> StripRow? {
        rows.first(where: \.isFocusable)
    }

    /// How long initial focus waits for an earlier row that is still loading (§2.3).
    static let initialFocusWaitLimit: TimeInterval = 2.0

    /// §2.3's "open → row 0, first card": the row initial focus lands on. The rows load in parallel,
    /// so a later row can be focusable before an earlier one has finished, and landing there opened
    /// the page on its second row (end-of-Wave-2 FA87 walk). While a row ABOVE the first focusable
    /// row is still loading, wait (nil) until `waitOver`, then take the first focusable row. Failed
    /// and empty rows never hold it up.
    static func initialFocusTarget(_ rows: [StripRow], waitOver: Bool) -> StripRow? {
        for row in rows {
            if row.isFocusable { return row }
            if row.status == .loading, !waitOver { return nil }
        }
        return nil
    }

    /// The row's index among the FOCUSABLE rows of `rows` (0 = the top row the viewer can land
    /// on), or nil when it is not a focusable row there. The Edit band shows at position 0, which
    /// holds even when an empty or failed row sits above the first focusable one.
    static func focusablePosition(of rowId: String, in rows: [StripRow]) -> Int? {
        rows.filter(\.isFocusable).firstIndex { $0.id == rowId }
    }

    /// What the strip area draws. `rows` is EVERY row (not only the visible ones): "every row failed"
    /// counts the failed rows the visibility rule hides.
    static func pageState(_ rows: [StripRow], allSettled: Bool) -> PageState {
        if rows.contains(where: \.isFocusable) { return .rows }
        if !allSettled { return .loading }
        if !rows.isEmpty, rows.allSatisfy({ $0.status == .failed }) { return .failed }
        return .empty
    }

    /// Blank and whitespace-only payload URLs count as absent (the rule every folder artwork check
    /// applies).
    static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
