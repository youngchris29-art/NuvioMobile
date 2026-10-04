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

    func testNeverSwapsToAnEmptyPageWhileLoading() {
        var hold = SearchRowsHold()
        _ = hold.rows(current: previous, incoming: [], isLoading: true, now: 10)
        XCTAssertEqual(hold.rows(current: previous, incoming: [], isLoading: true, now: 15), previous)
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

    func testOncePerQuery() {
        var history = SearchHistoryOnOpen()
        XCTAssertEqual(history.pathChanged(from: 0, to: 1, query: "dune"), "dune")
        // Detail → person, and a second result opened for the same query: not saved again.
        XCTAssertNil(history.pathChanged(from: 1, to: 2, query: "dune"))
        XCTAssertNil(history.pathChanged(from: 0, to: 1, query: "dune"))
        XCTAssertEqual(history.pathChanged(from: 0, to: 1, query: "severance"), "severance")
    }
}
