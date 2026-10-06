import XCTest
@testable import NuvioTV

/// Search & Discover B3 a: the Search wash's timing, on an injected clock. Pending at once,
/// displayed after 0.45 s of quiet, a new title re-arms the wait, `clear()` nils both.
final class SearchWashPolicyTests: XCTestCase {
    private typealias Policy = SearchWashPolicy<String>
    private let quiet = SearchWashPolicy<String>.quietDelay

    func testQuietDelayIsHomesPause() {
        XCTAssertEqual(quiet, 0.45, accuracy: 0.0001)
    }

    func testReportIsPendingAtOnceAndDisplayedAfterQuiet() {
        var policy = Policy()
        policy.report("movie:a", now: 10)
        XCTAssertEqual(policy.pending, "movie:a")
        XCTAssertNil(policy.displayed)
        XCTAssertFalse(policy.tick(now: 10.2))
        XCTAssertNil(policy.displayed)
        XCTAssertTrue(policy.tick(now: 10 + quiet))
        XCTAssertEqual(policy.displayed, "movie:a")
        XCTAssertNil(policy.deadline)
    }

    func testNewReportReArmsTheWait() {
        var policy = Policy()
        policy.report("movie:a", now: 0)
        policy.report("movie:b", now: 0.3)
        XCTAssertEqual(policy.pending, "movie:b")
        XCTAssertFalse(policy.tick(now: 0.5))
        XCTAssertNil(policy.displayed)
        XCTAssertTrue(policy.tick(now: 0.3 + quiet))
        XCTAssertEqual(policy.displayed, "movie:b")
    }

    func testSameTitleAgainKeepsTheRunningWait() {
        var policy = Policy()
        policy.report("movie:a", now: 0)
        policy.report("movie:a", now: 0.4)
        XCTAssertTrue(policy.tick(now: quiet))
        XCTAssertEqual(policy.displayed, "movie:a")
    }

    func testBackOnTheDisplayedTitleCancelsTheWait() {
        var policy = Policy()
        policy.report("movie:a", now: 0)
        _ = policy.tick(now: quiet)
        policy.report("movie:b", now: 1)
        policy.report("movie:a", now: 1.1)
        XCTAssertEqual(policy.pending, "movie:a")
        XCTAssertNil(policy.deadline)
        XCTAssertFalse(policy.tick(now: 5))
        XCTAssertEqual(policy.displayed, "movie:a")
    }

    func testNilReportIsIgnored() {
        var policy = Policy()
        policy.report("movie:a", now: 0)
        policy.report(nil, now: 0.1)
        XCTAssertEqual(policy.pending, "movie:a")
        XCTAssertTrue(policy.focusInResults)
        XCTAssertTrue(policy.tick(now: quiet))
    }

    func testClearNilsBoth() {
        var policy = Policy()
        policy.report("movie:a", now: 0)
        _ = policy.tick(now: quiet)
        policy.report("movie:b", now: 1)
        policy.clear()
        XCTAssertNil(policy.pending)
        XCTAssertNil(policy.displayed)
        XCTAssertNil(policy.deadline)
        XCTAssertFalse(policy.focusInResults)
        XCTAssertFalse(policy.tick(now: 10))
    }

    func testTopResultFollowedOnlyWhileFocusIsOutsideTheResults() {
        var policy = Policy()
        policy.topResultChanged("movie:top", now: 0)
        XCTAssertEqual(policy.pending, "movie:top")

        policy.report("series:card", now: 1)
        policy.topResultChanged("movie:other", now: 1.1)
        XCTAssertEqual(policy.pending, "series:card")

        policy.queryTyped()
        policy.topResultChanged("movie:other", now: 2)
        XCTAssertEqual(policy.pending, "movie:other")
    }

    func testNilTopResultKeepsTheWash() {
        var policy = Policy()
        policy.topResultChanged("movie:top", now: 0)
        _ = policy.tick(now: quiet)
        policy.topResultChanged(nil, now: 1)
        XCTAssertEqual(policy.pending, "movie:top")
        XCTAssertEqual(policy.displayed, "movie:top")
    }

    func testPersonFocusKeepsTheWashAndStopsFollowingTheTopResult() {
        var policy = Policy()
        policy.report("movie:a", now: 0)
        _ = policy.tick(now: quiet)
        policy.queryTyped()
        policy.noteResultFocus()
        policy.topResultChanged("movie:b", now: 1)
        XCTAssertEqual(policy.pending, "movie:a")
        XCTAssertEqual(policy.displayed, "movie:a")
    }

    func testKeyboardFocusShowsTheTopResult() {
        var policy = Policy()
        policy.report("series:card", now: 0)
        _ = policy.tick(now: quiet)
        policy.keyboardFocused(topResult: "movie:top", now: 1)
        XCTAssertFalse(policy.focusInResults)
        XCTAssertEqual(policy.pending, "movie:top")
        XCTAssertTrue(policy.tick(now: 1 + quiet))
        XCTAssertEqual(policy.displayed, "movie:top")
    }
}
