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
}
