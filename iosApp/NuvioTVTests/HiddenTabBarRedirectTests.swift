import XCTest
@testable import NuvioTV

final class HiddenTabBarRedirectTests: XCTestCase {
    func testALandingInTheHiddenBarRevealsTheSidebar() {
        XCTAssertTrue(HiddenTabBarRedirect.shouldReveal(landedInHiddenBar: true, sidebarMode: true, sidebarHoldsFocus: false))
    }

    func testOrdinaryFocusMovesNeverReveal() {
        XCTAssertFalse(HiddenTabBarRedirect.shouldReveal(landedInHiddenBar: false, sidebarMode: true, sidebarHoldsFocus: false))
    }

    func testTabsModeNeverReveals() {
        // The bar is visible and focusable in Tabs mode: landing on it is the normal Menu behaviour.
        XCTAssertFalse(HiddenTabBarRedirect.shouldReveal(landedInHiddenBar: true, sidebarMode: false, sidebarHoldsFocus: false))
    }

    func testNoRevealWhileTheSidebarAlreadyHoldsFocus() {
        XCTAssertFalse(HiddenTabBarRedirect.shouldReveal(landedInHiddenBar: true, sidebarMode: true, sidebarHoldsFocus: true))
    }
}

final class StrandedRescueGuardTests: XCTestCase {
    // Review r2 P2-1: successful redirects never suppress the next one.
    func testRedirectsWithoutAFailureAreNeverSuppressed() {
        let guardState = StrandedRescueGuard()
        XCTAssertTrue(guardState.allowsReveal(now: 100))
        XCTAssertTrue(guardState.allowsReveal(now: 100.2))
        XCTAssertTrue(guardState.allowsReveal(now: 100.4))
    }

    // Review r1 P3-3: a failed rescue's reset landing back in the bar must not loop.
    func testAFailedRescueSuppressesTheRedirectForItsWindow() {
        var guardState = StrandedRescueGuard()
        guardState.rescueFailed(now: 100)
        XCTAssertFalse(guardState.allowsReveal(now: 100.1))
        XCTAssertFalse(guardState.allowsReveal(now: 100 + StrandedRescueGuard.window))
        XCTAssertTrue(guardState.allowsReveal(now: 100 + StrandedRescueGuard.window + 0.01))
    }
}

final class SidebarHandOffLadderTests: XCTestCase {
    func testSearchWaitsForItsSystemKeyboard() {
        XCTAssertEqual(SidebarHandOffLadder.checks(forTabTitled: "Search").last, 2.5)
    }

    // Review r3 P3-3: every other tab keeps the short no-focus window.
    func testOtherTabsKeepTheShortLadder() {
        for title in ["Home", "Library", "Add-ons", "Settings", "Profile", nil] {
            XCTAssertEqual(SidebarHandOffLadder.checks(forTabTitled: title), [0.35, 1.0])
        }
    }
}
