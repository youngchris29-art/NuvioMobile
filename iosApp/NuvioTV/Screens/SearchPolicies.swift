import Foundation

/// S1 W1 (2026-10-04): what Search shows while the next query loads.
///
/// `SearchRepository.search` publishes `isLoading = true` with EMPTY sections at the start of every
/// new query, so with results updating as you type the page blanked on every letter. This keeps
/// the previous query's rows on screen while the next one loads, and swaps when that search
/// finishes or once `holdLimit` has passed since it started and it has rows to show.
///
/// Device evidence (S1 Wave 0, Living Room Apple TV, Grid, "dune" one letter at a time): swapping
/// on the FIRST new row collapsed the page to one row and regrew it on every letter; holding until
/// the search finished kept the rows steady (swaps at 0.12–0.27 s on warm add-ons).
struct SearchRowsHold {
    /// Longest the previous rows stay up once the new search has rows of its own.
    static let holdLimit: TimeInterval = 1.0

    private enum Phase: Equatable {
        /// No search loading.
        case idle
        /// A search is loading and the previous rows are still shown; `since` is its start.
        case holding(since: TimeInterval)
        /// A search is loading and its own rows are shown as they arrive.
        case following
    }

    private var phase: Phase = .idle

    var isHolding: Bool {
        if case .holding = phase { return true }
        return false
    }

    /// The rows to show for one repository emission. `current` is what is on screen, `incoming`
    /// the emission's sections, `now` a `systemUptime` value.
    mutating func rows<Row>(current: [Row], incoming: [Row], isLoading: Bool, now: TimeInterval) -> [Row] {
        guard isLoading else {
            // Settled: show exactly what the search found (empty means the "No results." state).
            phase = .idle
            return incoming
        }
        switch phase {
        case .idle:
            // A search started. With nothing on screen there is nothing to hold.
            if current.isEmpty || !incoming.isEmpty {
                phase = .following
                return incoming
            }
            phase = .holding(since: now)
            return current
        case .holding(let since):
            if incoming.isEmpty || now - since < Self.holdLimit { return current }
            phase = .following
            return incoming
        case .following:
            // Rows only grow during one search, so an empty loading emission is the NEXT search
            // starting: hold what this one has shown so far.
            if incoming.isEmpty && !current.isEmpty {
                phase = .holding(since: now)
                return current
            }
            return incoming
        }
    }

    /// The field was cleared: drop any hold.
    mutating func reset() {
        phase = .idle
    }
}

/// S1 W1 (2026-10-04): when a query joins Recent Searches.
///
/// The system search field's inline keyboard has no Search/Done key, so `.onSubmit(of: .search)`
/// never fires from the remote (spike 2026-10-04: nothing saved). A query is saved when something
/// is OPENED from it (a push onto Search's stack while the field holds it: a result, See All, a
/// person), once per query, matching VortX and the revamp board's "saved on intent". The iPhone
/// keyboard's return key still submits.
struct SearchHistoryOnOpen {
    /// `SearchHistoryRepository` ignores anything shorter.
    static let minimumLength = 2

    private(set) var recordedQuery: String?

    /// The query to record for a navigation-path change, or nil.
    mutating func pathChanged(from oldCount: Int, to newCount: Int, query: String) -> String? {
        guard newCount > oldCount else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumLength, trimmed != recordedQuery else { return nil }
        recordedQuery = trimmed
        return trimmed
    }
}
