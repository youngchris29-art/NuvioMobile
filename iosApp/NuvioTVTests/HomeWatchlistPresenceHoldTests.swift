import XCTest
@testable import NuvioTV

/// §16: the Watchlist presence-hold rule. Only an appearance is ever held.
final class HomeWatchlistPresenceHoldTests: XCTestCase {
    func testAppearanceIsHeldWhileBlocked() {
        XCTAssertTrue(HomeWatchlistPresenceHold.holds(currentPresent: false, nextPresent: true, blocked: true))
    }

    func testAppearancePublishesWhenNotBlocked() {
        XCTAssertFalse(HomeWatchlistPresenceHold.holds(currentPresent: false, nextPresent: true, blocked: false))
    }

    /// The sign-out invariant: a removal empties the row at once.
    func testRemovalIsNeverHeld() {
        XCTAssertFalse(HomeWatchlistPresenceHold.holds(currentPresent: true, nextPresent: false, blocked: true))
        XCTAssertFalse(HomeWatchlistPresenceHold.holds(currentPresent: true, nextPresent: false, blocked: false))
    }

    func testContentChangeIsNeverHeld() {
        XCTAssertFalse(HomeWatchlistPresenceHold.holds(currentPresent: true, nextPresent: true, blocked: true))
    }

    func testEmptyStaysEmpty() {
        XCTAssertFalse(HomeWatchlistPresenceHold.holds(currentPresent: false, nextPresent: false, blocked: true))
    }

    // MARK: - §17: the row focus is on, or will come back to

    private typealias Hold = HomeWatchlistPresenceHold

    private func r(owned: String? = nil, railFocused: Bool = false, railTarget: HomeRailReturnTarget? = nil,
                   covered: Bool = false, lastOwned: String? = nil, sinceRowRelease: TimeInterval? = nil) -> String? {
        Hold.returnRowKey(owned: owned, railFocused: railFocused, railTarget: railTarget,
                          covered: covered, lastOwned: lastOwned, sinceRowRelease: sinceRowRelease)
    }

    func testOwnedRowWins() {
        XCTAssertEqual(r(owned: "c3", railFocused: true, railTarget: .hero), "c3")
    }

    func testRailRowTargetBlocks() {
        let key = r(owned: nil, railFocused: true, railTarget: .row("c3"), sinceRowRelease: 5)
        XCTAssertEqual(key, "c3")
        XCTAssertTrue(Hold.isBelowSlot(key))
    }

    func testRailHeroOrNoTargetDoesNotBlock() {
        XCTAssertNil(r(railFocused: true, railTarget: .hero, lastOwned: "c3", sinceRowRelease: 5))
        XCTAssertNil(r(railFocused: true, railTarget: nil, lastOwned: "c3", sinceRowRelease: 5))
    }

    func testRailTargetContinueWatchingIsNotBelow() {
        let key = r(railFocused: true, railTarget: .row("continue-watching"))
        XCTAssertEqual(key, "continue-watching")
        XCTAssertFalse(Hold.isBelowSlot(key))
    }

    func testRailTargetIgnoredWhenRailNotFocused() {
        XCTAssertNil(r(railFocused: false, railTarget: .row("c3"), sinceRowRelease: 5))
    }

    func testCoveredUsesLastOwned() {
        XCTAssertEqual(r(covered: true, lastOwned: "c3"), "c3")
    }

    func testHopWindow() {
        XCTAssertEqual(r(lastOwned: "c3", sinceRowRelease: 0.2), "c3")
        XCTAssertNil(r(lastOwned: "c3", sinceRowRelease: 0.6))
    }

    func testIsBelowSlot() {
        XCTAssertFalse(Hold.isBelowSlot(nil))
        XCTAssertFalse(Hold.isBelowSlot("continue-watching"))
        XCTAssertFalse(Hold.isBelowSlot("home-watchlist"))
        XCTAssertTrue(Hold.isBelowSlot("upcoming"))
        XCTAssertTrue(Hold.isBelowSlot("c3"))
    }
}
