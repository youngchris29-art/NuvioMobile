import XCTest
import SharedCore
@testable import NuvioTV

final class SearchRowsHoldTests: XCTestCase {
    /// The previous query's settled rows, as the hold sees them.
    private let previous = [1, 2, 3]

    func testFirstSearchWithNothingOnScreenFollowsIncoming() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: [Int](), incoming: [], isLoading: true, now: 0, relation: .otherQuery), [])
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.rows(current: [], incoming: [7], isLoading: true, now: 0.2, relation: .sameSearch), [7])
        XCTAssertEqual(hold.rows(current: [7], incoming: [7, 8], isLoading: false, now: 0.4, relation: .sameSearch), [7, 8])
    }

    func testTheSameSearchProgressingIsNeverHeld() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: [7], incoming: [7, 8], isLoading: true, now: 0, relation: .sameSearch), [7, 8])
        XCTAssertFalse(hold.isHolding)
    }

    func testKeepsAnotherQuerysRowsWhileTheNextSearchLoads() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery), previous)
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.rows(current: previous, incoming: [9], isLoading: true, now: 10.3, relation: .otherQuery), previous)
    }

    func testSwapsWhenTheNextSearchFinishes() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery)
        XCTAssertEqual(hold.rows(current: previous, incoming: [9, 8], isLoading: false, now: 10.2, relation: .otherQuery), [9, 8])
        XCTAssertFalse(hold.isHolding)
    }

    func testAnotherQuerysRowsGoOnceTheLimitHasPassed() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery)
        XCTAssertEqual(
            hold.rows(current: previous, incoming: [9], isLoading: true, now: 10 + SearchRowsHold.holdLimit, relation: .otherQuery),
            [9]
        )
        // Following now: later rows of the same search come straight through.
        XCTAssertEqual(hold.rows(current: [9], incoming: [9, 8], isLoading: true, now: 11.2, relation: .sameSearch), [9, 8])
    }

    func testPastTheLimitAnEmptyEmissionShowsSearching() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery)
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: true, now: 10.5, relation: .otherQuery), previous)
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: true, now: 11.2, relation: .otherQuery), [])
        XCTAssertFalse(hold.isHolding)
    }

    // Review r1 P2-1: a catalog with no matches emits nothing, so the hold must end on its own.
    func testTickReleasesAnotherQuerysRowsAtTheDeadline() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery)
        _ = hold.rows(current: previous, incoming: [9], isLoading: true, now: 10.2, relation: .otherQuery)
        XCTAssertEqual(hold.holdDeadline, 10 + SearchRowsHold.holdLimit)
        XCTAssertNil(hold.tick(lastIncoming: [9], isLoading: true, now: 10.9, relation: .otherQuery))
        XCTAssertEqual(hold.tick(lastIncoming: [9], isLoading: true, now: 11.0, relation: .otherQuery), [9])
        XCTAssertFalse(hold.isHolding)
        XCTAssertNil(hold.holdDeadline)
    }

    func testTickPastTheDeadlineWithNoNewRowsShowsSearching() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery)
        XCTAssertEqual(hold.tick(lastIncoming: [Int](), isLoading: true, now: 11.5, relation: .otherQuery), [])
    }

    func testTickDoesNothingWhenNotHolding() {
        var hold = SearchRowsHold()
        XCTAssertNil(hold.tick(lastIncoming: [1], isLoading: true, now: 100, relation: .otherQuery))
    }

    // Review r2 P3-1: a manifest refresh or Retry searches the SAME query again; its valid rows
    // stay until the restart catches up or settles, never blanked by the clock.
    func testASameQueryRestartKeepsItsRowsPastTheLimitUntilItCatchesUp() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .sameQueryRestart), previous)
        XCTAssertNil(hold.tick(lastIncoming: [Int](), isLoading: true, now: 20, relation: .sameQueryRestart))
        XCTAssertEqual(hold.rows(current: previous, incoming: [1], isLoading: true, now: 21, relation: .sameQueryRestart), previous)
        XCTAssertEqual(hold.rows(current: previous, incoming: [1, 2, 3], isLoading: true, now: 22, relation: .sameSearch), [1, 2, 3])
        XCTAssertFalse(hold.isHolding)
    }

    func testANewSearchStartingWhileFollowingHoldsWhatIsShown() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: [Int](), incoming: [9], isLoading: true, now: 0, relation: .sameSearch), [9])
        // The repository's empty loading emission is the next search starting.
        XCTAssertEqual(hold.rows(current: [9], incoming: [], isLoading: true, now: 0.5, relation: .otherQuery), [9])
        XCTAssertTrue(hold.isHolding)
    }

    // Review r1 P3-1: the empty start emission conflated away; partial rows of the NEW query
    // arrive over the old query's rows.
    func testPartialRowsOverAnotherQuerysRowsAreHeld() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: previous, incoming: [9], isLoading: true, now: 10, relation: .otherQuery), previous)
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.rows(current: previous, incoming: [9, 8], isLoading: false, now: 10.3, relation: .otherQuery), [9, 8])
    }

    func testASettledEmptySearchClearsTheRows() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery)
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: false, now: 10.4, relation: .otherQuery), [])
    }

    func testResetDropsTheHold() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery)
        hold.reset()
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.rows(current: [Int](), incoming: [], isLoading: true, now: 11, relation: .otherQuery), [])
    }

    func testARestartHoldHasNoDeadline() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .sameQueryRestart)
        XCTAssertTrue(hold.isHolding)
        XCTAssertNil(hold.holdDeadline)
    }

    // Review r3 P3-2: the 1 s bound runs from when the rows became ANOTHER query's, not from the
    // start of a long restart hold, so the next letter doesn't blank the page at once.
    func testARestartHoldTurningIntoAnotherQuerysStartsTheClockThen() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .sameQueryRestart)
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: true, now: 15, relation: .otherQuery), previous)
        XCTAssertEqual(hold.holdDeadline, 15 + SearchRowsHold.holdLimit)
        XCTAssertEqual(hold.rows(current: previous, incoming: [9], isLoading: true, now: 15.5, relation: .otherQuery), previous)
        XCTAssertEqual(hold.rows(current: previous, incoming: [9], isLoading: true, now: 16, relation: .otherQuery), [9])
    }

    // Review r3 P3-1: a new query whose start state equals the repository's current value is
    // never emitted; `searchStarted` starts the bound so the deadline tick can end the hold.
    func testSearchStartedStartsTheBoundWithoutAnEmission() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .sameQueryRestart)
        hold.searchStarted(relation: .otherQuery, hasRows: true, now: 20)
        XCTAssertEqual(hold.holdDeadline, 20 + SearchRowsHold.holdLimit)
        XCTAssertNil(hold.tick(lastIncoming: [Int](), isLoading: true, now: 20.5, relation: .otherQuery))
        XCTAssertEqual(hold.tick(lastIncoming: [Int](), isLoading: true, now: 21, relation: .otherQuery), [])
    }

    func testSearchStartedBackToTheShownQueryDropsTheBound() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery)
        hold.searchStarted(relation: .sameQueryRestart, hasRows: true, now: 10.5)
        XCTAssertTrue(hold.isHolding)
        XCTAssertNil(hold.holdDeadline)
    }

    // Review r4 P3-1: each debounced letter while another query's rows are held must not push
    // the bound out, or steady typing would never see new rows.
    func testSearchStartedDoesNotRestampAHoldAlreadyOverAnotherQuery() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery)
        hold.searchStarted(relation: .otherQuery, hasRows: true, now: 10.5)
        hold.searchStarted(relation: .otherQuery, hasRows: true, now: 10.9)
        XCTAssertEqual(hold.holdDeadline, 10 + SearchRowsHold.holdLimit)
    }

    // Review r4 P3-2: the rows on screen are the active query's again: no clock.
    func testSearchStartedToTheSameSearchDropsTheBound() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .otherQuery)
        hold.searchStarted(relation: .sameSearch, hasRows: true, now: 10.5)
        XCTAssertTrue(hold.isHolding)
        XCTAssertNil(hold.holdDeadline)
    }

    // Review r5 P2-1: following the previous search's rows, the next search's start state is
    // swallowed (a cancelled search's late write replaced it). The hold must still begin at the
    // search's start and end on time.
    func testSearchStartedHoldsAnotherQuerysRowsWhenTheStartStateIsSwallowed() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: [Int](), incoming: [9], isLoading: true, now: 0, relation: .sameSearch), [9])
        hold.searchStarted(relation: .otherQuery, hasRows: true, now: 5)
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.holdDeadline, 5 + SearchRowsHold.holdLimit)
        XCTAssertNil(hold.tick(lastIncoming: [Int](), isLoading: true, now: 5.5, relation: .otherQuery))
        XCTAssertEqual(hold.tick(lastIncoming: [Int](), isLoading: true, now: 6, relation: .otherQuery), [])
    }

    func testSearchStartedFromSettledRowsHoldsThem() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: [Int](), incoming: [9], isLoading: false, now: 0, relation: .sameSearch)
        hold.searchStarted(relation: .otherQuery, hasRows: true, now: 5)
        XCTAssertEqual(hold.holdDeadline, 5 + SearchRowsHold.holdLimit)
    }

    // Review r6 P3-4: a case-only edit during a Retry keeps the restart hold clockless.
    func testSearchStartedDuringARestartHoldOfTheSameQueryKeepsItClockless() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10, relation: .sameQueryRestart)
        hold.searchStarted(relation: .sameQueryRestart, hasRows: true, now: 12)
        hold.searchStarted(relation: .sameSearch, hasRows: true, now: 13)
        XCTAssertTrue(hold.isHolding)
        XCTAssertNil(hold.holdDeadline)
    }

    // Review r6 P3-4: the repository's same-key early return starts no search; nothing to hold.
    func testSearchStartedForTheSameSearchWhileFollowingHoldsNothing() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: [Int](), incoming: [9], isLoading: true, now: 0, relation: .sameSearch)
        hold.searchStarted(relation: .sameSearch, hasRows: true, now: 5)
        XCTAssertFalse(hold.isHolding)
    }

    func testSearchStartedWithNothingOnScreenHoldsNothing() {
        var hold = SearchRowsHold()
        hold.searchStarted(relation: .otherQuery, hasRows: false, now: 10)
        XCTAssertFalse(hold.isHolding)
    }

    func testSearchStartedOverTheActiveQuerysOwnRowsHoldsNothing() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: [Int](), incoming: [9], isLoading: true, now: 0, relation: .sameSearch)
        hold.searchStarted(relation: .sameQueryRestart, hasRows: true, now: 5)
        XCTAssertFalse(hold.isHolding)
    }
}

final class SearchRowsHoldRelationTests: XCTestCase {
    private func relation(shown: String?, active: String?, shownKeys: [String] = ["a"], incomingKeys: [String] = []) -> SearchRowsHold.Relation {
        SearchRowsHold.relation(shownQuery: shown, activeQuery: active, shownKeys: shownKeys, incomingKeys: incomingKeys)
    }

    // Review r3 P2-1: the label comes from the rows, so rows of an earlier query (a deadline tick
    // or a cancelled search's late write landing after the query changed) are another query's.
    func testRowsOfAnotherQueryAreOtherQuery() {
        XCTAssertEqual(relation(shown: "dun", active: "dune"), .otherQuery)
    }

    func testUnlabelledRowsAreTreatedAsAnotherQuerys() {
        // Fails safe: another query's rows are bounded by the clock, a restart's are not.
        XCTAssertEqual(relation(shown: nil, active: "dune"), .otherQuery)
        XCTAssertEqual(relation(shown: "dune", active: nil), .otherQuery)
    }

    func testQueriesCompareLikeTheRepositorysRequestKey() {
        XCTAssertEqual(relation(shown: "Dune", active: "dune", incomingKeys: ["a"]), .sameSearch)
    }

    func testTheSameQueryContainedInTheEmissionIsTheSameSearch() {
        XCTAssertEqual(relation(shown: "dune", active: "dune", shownKeys: ["a", "b"], incomingKeys: ["a", "b", "c"]), .sameSearch)
    }

    func testTheSameQueryNotYetCaughtUpIsARestart() {
        XCTAssertEqual(relation(shown: "dune", active: "dune", shownKeys: ["a", "b"], incomingKeys: ["a"]), .sameQueryRestart)
    }

    // Review r4 P2-1: a cancelled search's late write is another query's and is dropped.
    func testRowsOfAnotherSearchAreStale() {
        XCTAssertTrue(SearchRowsHold.isStale(emissionQuery: "du", activeQuery: "dun"))
        XCTAssertTrue(SearchRowsHold.isStale(emissionQuery: "du", activeQuery: nil)) // field cleared
    }

    func testTheActiveSearchsRowsAreNotStale() {
        XCTAssertFalse(SearchRowsHold.isStale(emissionQuery: "Dune", activeQuery: "dune"))
    }

    // Review r5 P3-2: Kotlin's trim() also strips U+001C–U+001F; a label must still match.
    func testQueriesCompareTrimmedLikeKotlin() {
        XCTAssertTrue(SearchRowsHold.sameQuery("dune", "dune\u{1F}"))
        XCTAssertFalse(SearchRowsHold.isStale(emissionQuery: "dune", activeQuery: "\u{1C}Dune "))
    }

    func testUnlabelledEmissionsAreNeverStale() {
        // Start states and empty settles carry no rows to label.
        XCTAssertFalse(SearchRowsHold.isStale(emissionQuery: nil, activeQuery: "dune"))
        XCTAssertFalse(SearchRowsHold.isStale(emissionQuery: nil, activeQuery: nil))
    }
}

/// Review r3 P2-1: the hold's label is read off the rows (the See All target's query, BUG-48).
@MainActor
final class SearchedQueryTests: XCTestCase {
    private func section(_ key: String, search: String?) -> HomeCatalogSection {
        HomeCatalogSection(
            key: key, title: key, subtitle: "", addonName: "",
            target: CatalogTargetAddon(manifestUrl: "https://addon.test", contentType: "movie", catalogId: "top",
                                       genre: nil, search: search, supportsPagination: false),
            items: [], availableItemCount: 0, hasMore: false
        )
    }

    func testRowsOfOneSearchCarryItsQuery() {
        XCTAssertEqual(SearchViewModel.searchedQuery(of: [section("a", search: "dune"), section("b", search: "dune")]), "dune")
    }

    func testMixedOrMissingQueriesAreUnknown() {
        XCTAssertNil(SearchViewModel.searchedQuery(of: [section("a", search: "dun"), section("b", search: "dune")]))
        XCTAssertNil(SearchViewModel.searchedQuery(of: [section("a", search: nil)]))
        XCTAssertNil(SearchViewModel.searchedQuery(of: []))
    }
}

final class SearchHistoryOnOpenTests: XCTestCase {
    func testAPushWhileTheFieldHoldsAQueryRecordsIt() {
        var history = SearchHistoryOnOpen()
        XCTAssertEqual(history.pathChanged(from: 0, to: 1, query: "dune"), "dune")
    }

    func testAPopRecordsNothing() {
        var history = SearchHistoryOnOpen()
        XCTAssertNil(history.pathChanged(from: 1, to: 0, query: "dune"))
    }

    func testEmptyShortAndBlankQueriesAreIgnored() {
        var history = SearchHistoryOnOpen()
        XCTAssertNil(history.pathChanged(from: 0, to: 1, query: ""))
        XCTAssertNil(history.pathChanged(from: 0, to: 1, query: "d"))
        XCTAssertNil(history.pathChanged(from: 0, to: 1, query: "   "))
    }

    func testTheQueryIsTrimmed() {
        var history = SearchHistoryOnOpen()
        XCTAssertEqual(history.pathChanged(from: 0, to: 1, query: "  the bear "), "the bear")
    }

    func testChangingTheQueryLetsTheSameQueryRecordAgain() {
        var history = SearchHistoryOnOpen()
        XCTAssertEqual(history.pathChanged(from: 0, to: 1, query: "dune"), "dune")
        history.queryChanged(to: "dune")          // the same text: still recorded
        XCTAssertNil(history.pathChanged(from: 0, to: 1, query: "dune"))
        history.queryChanged(to: "")              // cleared (the only way to reach the Recent chips)
        history.queryChanged(to: "dune")
        XCTAssertEqual(history.pathChanged(from: 0, to: 1, query: "dune"), "dune")
    }

    func testASubmitCountsAsRecorded() {
        var history = SearchHistoryOnOpen()
        history.submitted("severance ")
        XCTAssertNil(history.pathChanged(from: 0, to: 1, query: "severance"))
    }

    func testOncePerQuery() {
        var history = SearchHistoryOnOpen()
        XCTAssertEqual(history.pathChanged(from: 0, to: 1, query: "dune"), "dune")
        // Detail → person, and a second result opened for the same query: not saved again.
        XCTAssertNil(history.pathChanged(from: 1, to: 2, query: "dune"))
        XCTAssertNil(history.pathChanged(from: 0, to: 1, query: "dune"))
        XCTAssertEqual(history.pathChanged(from: 0, to: 1, query: "severance"), "severance")
    }
}

/// Search & Discover batch 2026-10-06 (B2): the hold keyed on `SearchUiState.requestId`.
final class SearchRowsHoldRequestIdTests: XCTestCase {
    // A cancelled search's late write is stale whatever it carries: rows, a start state, or a
    // settled empty one (the "no results" flash S1 accepted in review r5 P3-1).
    func testAnotherRequestIdIsStaleRowsOrEmptySettles() {
        XCTAssertTrue(SearchRowsHold.isStale(emissionRequestId: 3, activeRequestId: 4))
        XCTAssertTrue(SearchRowsHold.isStale(emissionRequestId: 5, activeRequestId: 4))
        XCTAssertFalse(SearchRowsHold.isStale(emissionRequestId: 4, activeRequestId: 4))
        // No active id (field cleared): can't judge by id; the caller falls back to the label.
        XCTAssertFalse(SearchRowsHold.isStale(emissionRequestId: 4, activeRequestId: nil))
    }

    func testTheSameIdExtendingTheRowsIsTheSameSearch() {
        XCTAssertEqual(
            SearchRowsHold.relation(shownRequestId: 7, activeRequestId: 7, shownKeys: ["a"], incomingKeys: ["a", "b"]),
            .sameSearch
        )
    }

    func testTheSameIdNotCaughtUpIsARestart() {
        XCTAssertEqual(
            SearchRowsHold.relation(shownRequestId: 7, activeRequestId: 7, shownKeys: ["a", "b"], incomingKeys: ["a"]),
            .sameQueryRestart
        )
    }

    func testDifferentIdsFallBackToTheQueryLabels() {
        // Another query: other.
        XCTAssertEqual(
            SearchRowsHold.relation(shownRequestId: 7, activeRequestId: 8, shownKeys: ["a"], incomingKeys: ["a"],
                                    shownQuery: "dun", activeQuery: "dune"),
            .otherQuery
        )
        // The same query searched again (Retry, a manifest landing): a restart until it catches up.
        XCTAssertEqual(
            SearchRowsHold.relation(shownRequestId: 7, activeRequestId: 8, shownKeys: ["a"], incomingKeys: [],
                                    shownQuery: "dune", activeQuery: "Dune"),
            .sameQueryRestart
        )
        // Unlabelled: other.
        XCTAssertEqual(
            SearchRowsHold.relation(shownRequestId: 7, activeRequestId: 8, shownKeys: ["a"], incomingKeys: ["a"]),
            .otherQuery
        )
        XCTAssertEqual(
            SearchRowsHold.relation(shownRequestId: nil, activeRequestId: 8, shownKeys: [], incomingKeys: ["a"]),
            .otherQuery
        )
    }

    func testFollowingFlipsOnRelease() {
        var hold = SearchRowsHold()
        XCTAssertTrue(hold.isFollowingIncoming)
        _ = hold.rows(current: [1, 2], incoming: [Int](), isLoading: true, now: 10, relation: .otherQuery)
        XCTAssertFalse(hold.isFollowingIncoming)
        _ = hold.rows(current: [1, 2], incoming: [9], isLoading: true, now: 10.2, relation: .otherQuery)
        XCTAssertFalse(hold.isFollowingIncoming)
        XCTAssertEqual(hold.rows(current: [1, 2], incoming: [9, 8], isLoading: false, now: 10.4, relation: .otherQuery), [9, 8])
        XCTAssertTrue(hold.isFollowingIncoming)
    }
}
