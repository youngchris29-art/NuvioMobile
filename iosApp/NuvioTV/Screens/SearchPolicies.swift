import Foundation

/// S1 W1 (2026-10-04): what Search shows while the next query loads.
///
/// `SearchRepository.search` publishes `isLoading = true` with EMPTY sections at the start of every
/// new query, so with results updating as you type the page blanked on every letter. This keeps
/// the previous query's rows on screen while the next one loads, and swaps when that search
/// finishes or extends them. Another query's rows stay at most `holdLimit` after the search that
/// replaces them starts, even when nothing more arrives (`tick`; review r1 P2-1: a catalog with no
/// matches emits nothing, so a slow add-on used to keep stale rows up until its 60 s timeout).
/// The view model reports each search start itself (`searchStarted`), since the repository's
/// start state can be swallowed (review r5 P2-1), and drops a cancelled search's late writes
/// (`isStale`, review r4 P2-1).
///
/// Search & Discover batch 2026-10-06 (B2): `SearchUiState.requestId` (C1) is now the identity. The
/// view model keeps the id `search()` returned as the active one, so ANY write of another search
/// is stale, including a settled "no results" with no rows (the r5 P3-1 flash S1 accepted), and
/// `relation` compares ids. The query-label pair stays as the fallback: after a clear there is no
/// active id (`clear()` returns none), and a re-search of the same query (Retry, a manifest
/// landing) gets a new id but should still hold its rows like a restart. Rows are whatever the
/// active `SearchRowsMode` draws (grouped type rows or per-add-on sections); `isFollowingIncoming`
/// tells the view model when to adopt the emission's Top result, "Found in", People and
/// suggestions along with its rows.
///
/// Device evidence (S1 Wave 0, Living Room Apple TV, Grid, "dune" one letter at a time): swapping
/// on the FIRST new row collapsed the page to one row and regrew it on every letter; holding until
/// the search finished kept the rows steady (swaps at 0.12–0.27 s on warm add-ons).
struct SearchRowsHold {
    /// Longest another query's rows stay up after the search that replaces them starts.
    static let holdLimit: TimeInterval = 1.0

    /// How the rows on screen relate to the search now loading (`relation(...)` computes it).
    enum Relation: Equatable {
        /// The rows on screen are this search's and the new emission contains them all: rows only
        /// grow during one search, so this is the same search progressing.
        case sameSearch
        /// The same query was searched again (a manifest refresh, Retry) and the new emission
        /// hasn't caught up with what is shown yet.
        case sameQueryRestart
        /// The rows on screen came from an earlier, different query.
        case otherQuery
    }

    /// The relation by request id (B2): the same id is the same search, so `.sameSearch` when the
    /// emission contains every shown row and `.sameQueryRestart` when it hasn't caught up. Different
    /// ids fall back to the query labels (`relation(shownQuery:...)`): the same query searched again
    /// relates like a restart, anything else is `.otherQuery`. A nil id (nothing shown yet, or the
    /// field was cleared) also falls back.
    static func relation(
        shownRequestId: Int64?,
        activeRequestId: Int64?,
        shownKeys: [String],
        incomingKeys: [String],
        shownQuery: String? = nil,
        activeQuery: String? = nil
    ) -> Relation {
        if let shownRequestId, let activeRequestId, shownRequestId == activeRequestId {
            let incoming = Set(incomingKeys)
            return shownKeys.allSatisfy { incoming.contains($0) } ? .sameSearch : .sameQueryRestart
        }
        return relation(shownQuery: shownQuery, activeQuery: activeQuery, shownKeys: shownKeys, incomingKeys: incomingKeys)
    }

    /// The relation for the rows on screen, from facts the view model reads off the rows
    /// themselves (review r3 P2-1: a query stamped when rows were taken can be the NEXT query's,
    /// when a deadline tick or a late write from a cancelled search lands after the query changed).
    /// `shownQuery` is the query the shown rows were searched with (nil when unknown or mixed);
    /// queries compare like the repository's request key (`sameQuery`).
    static func relation(
        shownQuery: String?,
        activeQuery: String?,
        shownKeys: [String],
        incomingKeys: [String]
    ) -> Relation {
        guard let shownQuery, let activeQuery, sameQuery(shownQuery, activeQuery) else { return .otherQuery }
        let incoming = Set(incomingKeys)
        return shownKeys.allSatisfy { incoming.contains($0) } ? .sameSearch : .sameQueryRestart
    }

    /// Whether an emission answers a search other than the active one (B2). Every
    /// `SearchRepository` publish carries the id of the call it answers, and the view model keeps
    /// the id `search()` returned, so this catches every late write of a cancelled search: rows,
    /// a start state, or a settled empty one. With no active id (the field was cleared, or no
    /// search has run) this can't judge; the caller uses `isStale(emissionQuery:activeQuery:)`.
    static func isStale(emissionRequestId: Int64, activeRequestId: Int64?) -> Bool {
        guard let activeRequestId else { return false }
        return emissionRequestId != activeRequestId
    }

    /// Fallback (S1): whether an emission's rows came from a search other than the active one (review r4 P2-1).
    /// A cancelled search can still write after the next one starts (a `StateFlow` write is not a
    /// suspension point), and its rows must neither reach the screen nor be what a hold releases
    /// to. `emissionQuery` is nil for an emission with no rows to label (start states, empty
    /// settles): this can't judge those, so it never calls them stale.
    static func isStale(emissionQuery: String?, activeQuery: String?) -> Bool {
        guard let emissionQuery else { return false }
        guard let activeQuery else { return true }
        return !sameQuery(emissionQuery, activeQuery)
    }

    /// Queries compare like the repository's request key: trimmed, case-insensitive. The label
    /// is Kotlin's `trim()` of the query, which also strips U+001C–U+001F that Swift's
    /// `.whitespacesAndNewlines` keeps (review r5 P3-2), so both sides trim the union.
    static func sameQuery(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    private static let queryTrim = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}"))

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: queryTrim).lowercased()
    }

    private enum Phase: Equatable {
        /// No search loading.
        case idle
        /// A search is loading and the previous rows are still shown. `overOtherQuery`: they are
        /// another query's, and `since` is when they became so (the 1 s bound runs from there).
        /// Otherwise they are this query's, held through a restart with no clock.
        case holding(since: TimeInterval, overOtherQuery: Bool)
        /// A search is loading and its own rows are shown as they arrive.
        case following
    }

    private var phase: Phase = .idle

    var isHolding: Bool {
        if case .holding = phase { return true }
        return false
    }

    /// B2: the rows on screen are the latest emission's (idle or following), so the view model
    /// adopts that emission's Top result, "Found in", People and suggestions too. While holding it
    /// keeps the previous ones, so the extras never describe rows that aren't shown.
    var isFollowingIncoming: Bool { !isHolding }

    /// When a hold over ANOTHER query's rows must end even if the repository emits nothing more.
    /// A same-query restart has none.
    var holdDeadline: TimeInterval? {
        if case .holding(let since, true) = phase { return since + Self.holdLimit }
        return nil
    }

    /// The rows to show for one repository emission. `current` is what is on screen, `incoming`
    /// the emission's sections, `now` a `systemUptime` value, `relation` how `current` relates to
    /// the loading search.
    ///
    /// - Settled (`isLoading == false`): exactly what the search found (empty = the view model's `SearchEmptyState`).
    /// - Rows on screen and the emission doesn't extend them (an empty start emission, a
    ///   restart that hasn't caught up, or another query's rows under conflated partial rows;
    ///   review r1 P3-1): hold them.
    /// - Holding: release as soon as the emission extends the held rows; another query's rows are
    ///   also released once `holdLimit` has passed since they became another query's (to the new
    ///   rows, or none = "Searching…"; review r3 P3-2), while a same-query restart keeps its rows
    ///   until it catches up or settles (review r2 P3-1).
    mutating func rows<Row>(
        current: [Row],
        incoming: [Row],
        isLoading: Bool,
        now: TimeInterval,
        relation: Relation
    ) -> [Row] {
        guard isLoading else {
            phase = .idle
            return incoming
        }
        switch phase {
        case .idle, .following:
            if !current.isEmpty && (incoming.isEmpty || relation != .sameSearch) {
                phase = .holding(since: now, overOtherQuery: relation == .otherQuery)
                return current
            }
            phase = .following
            return incoming
        case .holding(let since, let overOtherQuery):
            switch relation {
            case .sameSearch:
                phase = .following
                return incoming
            case .sameQueryRestart:
                phase = .holding(since: since, overOtherQuery: false)
                return current
            case .otherQuery:
                let start = overOtherQuery ? since : now
                if now - start >= Self.holdLimit {
                    phase = .following
                    return incoming
                }
                phase = .holding(since: start, overOtherQuery: true)
                return current
            }
        }
    }

    /// The view model started a search. The repository's start state can't be relied on to say
    /// so: it doesn't depend on the query, so it isn't re-emitted when equal to the current value
    /// (review r3 P3-1), and a cancelled search's late write can replace it before the view model
    /// reads it (review r5 P2-1). So:
    /// - not holding, with another query's rows on screen: hold them, bounded from now;
    /// - holding a restart that is now another query's: the bound starts now;
    /// - holding another query's rows that are the active query's again: drop the bound;
    /// - holding another query's rows already: keep the clock, so steady typing still swaps.
    /// The caller reschedules its tick.
    mutating func searchStarted(relation: Relation, hasRows: Bool, now: TimeInterval) {
        switch phase {
        case .idle, .following:
            if hasRows && relation == .otherQuery {
                phase = .holding(since: now, overOtherQuery: true)
            }
        case .holding(let since, let overOtherQuery):
            switch relation {
            case .otherQuery where !overOtherQuery:
                phase = .holding(since: now, overOtherQuery: true)
            case .sameQueryRestart where overOtherQuery, .sameSearch where overOtherQuery:
                phase = .holding(since: since, overOtherQuery: false)
            default:
                break
            }
        }
    }

    /// Re-evaluates a hold when no emission arrives (review r1 P2-1: a catalog with no matches
    /// emits nothing). Past the deadline a hold over ANOTHER query's rows ends with the last
    /// emission's rows (none = "Searching…"); otherwise returns nil and nothing changes.
    mutating func tick<Row>(lastIncoming: [Row], isLoading: Bool, now: TimeInterval, relation: Relation) -> [Row]? {
        guard case .holding(let since, true) = phase, relation == .otherQuery,
              now - since >= Self.holdLimit else { return nil }
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
