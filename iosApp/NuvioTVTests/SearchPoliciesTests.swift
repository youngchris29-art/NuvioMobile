import XCTest
@testable import NuvioTV

final class SearchRowsHoldTests: XCTestCase {
    /// The previous query's settled rows, as the hold sees them.
    private let previous = [1, 2, 3]

    func testFirstSearchWithNothingOnScreenFollowsIncoming() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: [Int](), incoming: [], isLoading: true, now: 0), [])
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.rows(current: [], incoming: [7], isLoading: true, now: 0.2), [7])
        XCTAssertEqual(hold.rows(current: [7], incoming: [7, 8], isLoading: false, now: 0.4), [7, 8])
    }

    func testKeepsPreviousRowsWhileTheNextSearchLoads() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: true, now: 10), previous)
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.rows(current: previous, incoming: [9], isLoading: true, now: 10.3), previous)
    }

    func testSwapsWhenTheNextSearchFinishes() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10)
        XCTAssertEqual(hold.rows(current: previous, incoming: [9, 8], isLoading: false, now: 10.2), [9, 8])
        XCTAssertFalse(hold.isHolding)
    }

    func testSwapsOnceTheHoldLimitHasPassedAndNewRowsExist() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10)
        XCTAssertEqual(
            hold.rows(current: previous, incoming: [9], isLoading: true, now: 10 + SearchRowsHold.holdLimit),
            [9]
        )
        // Following now: later rows of the same search come straight through.
        XCTAssertEqual(hold.rows(current: [9], incoming: [9, 8], isLoading: true, now: 11.2), [9, 8])
    }

    func testKeepsTheRowsInsideTheLimitWhenNothingNewArrives() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10)
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: true, now: 10.5), previous)
    }

    func testPastTheLimitAnEmptyLoadingEmissionShowsSearching() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10)
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: true, now: 11.2), [])
        XCTAssertFalse(hold.isHolding)
    }

    // Review r1 P2-1: a catalog with no matches emits nothing, so the hold must end on its own.
    func testTickReleasesTheHoldAtTheDeadlineWithNoNewEmission() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10)
        _ = hold.rows(current: previous, incoming: [9], isLoading: true, now: 10.2)   // held
        XCTAssertEqual(hold.holdDeadline, 10 + SearchRowsHold.holdLimit)
        XCTAssertNil(hold.tick(lastIncoming: [9], isLoading: true, now: 10.9))
        XCTAssertEqual(hold.tick(lastIncoming: [9], isLoading: true, now: 11.0), [9])
        XCTAssertFalse(hold.isHolding)
        XCTAssertNil(hold.holdDeadline)
    }

    func testTickPastTheDeadlineWithNoNewRowsShowsSearching() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10)
        XCTAssertEqual(hold.tick(lastIncoming: [Int](), isLoading: true, now: 11.5), [])
    }

    func testTickDoesNothingWhenNotHolding() {
        var hold = SearchRowsHold()
        XCTAssertNil(hold.tick(lastIncoming: [1], isLoading: true, now: 100))
    }

    // Review r1 P3-1: the empty start emission conflated away; partial rows of the NEW query
    // arrive over the old query's rows.
    func testPartialRowsOverAnEarlierQuerysRowsAreHeld() {
        var hold = SearchRowsHold()
        XCTAssertEqual(
            hold.rows(current: previous, incoming: [9], isLoading: true, now: 10, currentBelongsToActiveSearch: false),
            previous
        )
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.rows(current: previous, incoming: [9, 8], isLoading: false, now: 10.3), [9, 8])
    }

    func testANewSearchStartingWhileFollowingHoldsWhatIsShown() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: [Int](), incoming: [9], isLoading: true, now: 0), [9])
        // The repository's empty loading emission is the next search starting.
        XCTAssertEqual(hold.rows(current: [9], incoming: [], isLoading: true, now: 0.5), [9])
        XCTAssertTrue(hold.isHolding)
    }

    func testASettledEmptySearchClearsTheRows() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10)
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: false, now: 10.4), [])
    }

    func testACachedFirstEmissionWithRowsIsShownAtOnce() {
        var hold = SearchRowsHold()
        XCTAssertEqual(hold.rows(current: previous, incoming: [5], isLoading: true, now: 0), [5])
        XCTAssertFalse(hold.isHolding)
    }

    func testResetDropsTheHold() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10)
        hold.reset()
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.rows(current: [Int](), incoming: [], isLoading: true, now: 11), [])
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
