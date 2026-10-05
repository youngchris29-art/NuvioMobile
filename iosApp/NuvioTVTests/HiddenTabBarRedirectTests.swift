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
