import XCTest
@testable import NuvioTV

final class PlayerRemoteRulesTests: XCTestCase {
    private func menu(panel: Bool = false, mode: Bool = false, upNext: Bool = false,
                      pill: Bool = false, bar: Bool = false) -> MenuPrecedence.Action {
        MenuPrecedence.resolve(panelOpen: panel, modeActive: mode, upNextShowing: upNext,
                               pillFocused: pill, barUp: bar)
    }

    func testPanelWinsOverEverything() {
        XCTAssertEqual(menu(panel: true, mode: true, upNext: true, pill: true, bar: true), .panel)
    }

    func testModeCancelBeatsUpNextPillAndBar() {
        XCTAssertEqual(menu(mode: true, upNext: true, pill: true, bar: true), .cancelMode)
    }

    func testUpNextBeatsPillAndBar() {
        XCTAssertEqual(menu(upNext: true, pill: true, bar: true), .dismissUpNext)
    }

    func testPillBeatsBar() {
        XCTAssertEqual(menu(pill: true, bar: true), .hidePill)
    }

    func testBarHidesBeforeExit() {
        XCTAssertEqual(menu(bar: true), .hideBar)
    }

    func testNothingUpExits() {
        XCTAssertEqual(menu(), .exit)
    }

    func testSwallowedReleases() {
        XCTAssertTrue(MenuPrecedence.swallowsRelease(.cancelMode))
        XCTAssertTrue(MenuPrecedence.swallowsRelease(.dismissUpNext))
        XCTAssertTrue(MenuPrecedence.swallowsRelease(.hidePill))
        XCTAssertTrue(MenuPrecedence.swallowsRelease(.hideBar))
        XCTAssertFalse(MenuPrecedence.swallowsRelease(.exit))
        XCTAssertFalse(MenuPrecedence.swallowsRelease(.panel))
    }

    func testLightTapBlockedWhileAnyPressIsDown() {
        XCTAssertFalse(LightTapGuard.allows(now: 100, lastPressUptime: 0, pressesDown: 1))
    }

    func testLightTapBlockedWithinWindowOfLastPress() {
        XCTAssertFalse(LightTapGuard.allows(now: 10.49, lastPressUptime: 10, pressesDown: 0))
        XCTAssertTrue(LightTapGuard.allows(now: 10.5, lastPressUptime: 10, pressesDown: 0))
    }

    /// A long Select hold: the window runs from the release, not the press.
    func testLongHoldReleaseRestartsWindow() {
        // pressed at 0, released at 2 (stamped at release): a tap at 2.2 is the same touch.
        XCTAssertFalse(LightTapGuard.allows(now: 2.2, lastPressUptime: 2, pressesDown: 0))
    }
}
