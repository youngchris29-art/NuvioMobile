import Foundation

/// S1 W1 (2026-10-04): what Search shows while the next query loads.
///
/// `SearchRepository.search` publishes `isLoading = true` with EMPTY sections at the start of every
/// new query, so with results updating as you type the page blanked on every letter. This keeps
/// the previous query's rows on screen while the next one loads, and swaps when that search
/// finishes or once `holdLimit` has passed since it started. Past the limit it shows the new
/// search's rows, or none ("Searching…"): the previous query's rows never stay longer, even when
/// nothing more arrives (`tick`; review r1 P2-1: a catalog with no matches emits nothing, so a
/// slow add-on used to keep stale rows up until its 60 s timeout).
///
/// Device evidence (S1 Wave 0, Living Room Apple TV, Grid, "dune" one letter at a time): swapping
/// on the FIRST new row collapsed the page to one row and regrew it on every letter; holding until
/// the search finished kept the rows steady (swaps at 0.12–0.27 s on warm add-ons).
struct SearchRowsHold {
    /// Longest the previous query's rows stay up after the next search starts.
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

    /// When the current hold must end even if the repository emits nothing more.
    var holdDeadline: TimeInterval? {
        if case .holding(let since) = phase { return since + Self.holdLimit }
        return nil
    }

    /// The rows to show for one repository emission. `current` is what is on screen, `incoming`
    /// the emission's sections, `now` a `systemUptime` value. `currentBelongsToActiveSearch` is
    /// false when the rows on screen came from an EARLIER query than the one loading (the view
    /// model reads it off the section keys): the repository's empty start emission can be
    /// conflated away on a fast or cached search, and the first emission then already carries the
    /// new search's partial rows (review r1 P3-1).
    mutating func rows<Row>(
        current: [Row],
        incoming: [Row],
        isLoading: Bool,
        now: TimeInterval,
        currentBelongsToActiveSearch: Bool = true
    ) -> [Row] {
        guard isLoading else {
            // Settled: show exactly what the search found (empty means the "No results." state).
            phase = .idle
            return incoming
        }
        switch phase {
        case .idle, .following:
            // Rows only grow during one search, so an empty loading emission over rows on screen
            // is the NEXT search starting; so are partial rows over an earlier query's rows.
            if !current.isEmpty && (incoming.isEmpty || !currentBelongsToActiveSearch) {
                phase = .holding(since: now)
                return current
            }
            phase = .following
            return incoming
        case .holding(let since):
            if now - since < Self.holdLimit { return current }
            phase = .following
            return incoming
        }
    }

    /// Re-evaluates a hold when no emission arrives (review r1 P2-1). Once the deadline has
    /// passed, ends the hold and returns the last emission's rows (none means "Searching…");
    /// otherwise returns nil and nothing changes.
    mutating func tick<Row>(lastIncoming: [Row], isLoading: Bool, now: TimeInterval) -> [Row]? {
        guard case .holding(let since) = phase, now - since >= Self.holdLimit else { return nil }
        phase = isLoading ? .following : .idle
        return lastIncoming
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

    /// The field's text changed. "Once per query" means once per TYPING of it: after the text
    /// moves away (including a clear, the only way to reach the Recent chips and remove one), the
    /// same query records again (review r1 P3-2).
    mutating func queryChanged(to query: String) {
        if query.trimmingCharacters(in: .whitespacesAndNewlines) != recordedQuery { recordedQuery = nil }
    }

    /// The iPhone keyboard's return key submitted `query` (recorded by the caller).
    mutating func submitted(_ query: String) {
        recordedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
