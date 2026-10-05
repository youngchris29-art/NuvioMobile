import Combine
import XCTest
import UIKit
@testable import NuvioTV

/// Home Stage & Strip (H9, FEAT-45; P4 spec §7.2): the rail's focus decisions (when a failed move
/// arms it, what a failed move inside it does, Menu by open reason, Select), its visibility rule in
/// precedence order, and the chrome model's write-on-change mirror, motion record and return routes.
@MainActor
final class RailFocusPolicyTests: XCTestCase {

    // MARK: shouldArm (§2.2)

    private func shouldArm(heading: UIFocusHeading = [.left],
                           railMode: Bool = true,
                           railHoldsFocus: Bool = false,
                           originInTabContent: Bool = true,
                           presentedOverShell: Bool = false,
                           vetoed: Bool = false) -> Bool {
        RailFocusPolicy.shouldArm(heading: heading, railMode: railMode, railHoldsFocus: railHoldsFocus,
                                  originInTabContent: originInTabContent,
                                  presentedOverShell: presentedOverShell, vetoed: vetoed)
    }

    func testAPlainFailedLeftFromContentArms() {
        XCTAssertTrue(shouldArm())
    }

    func testEachConditionAloneBlocksArming() {
        XCTAssertFalse(shouldArm(railMode: false), "Tabs mode")
        XCTAssertFalse(shouldArm(railHoldsFocus: true), "the rail already holds (or is taking) focus")
        XCTAssertFalse(shouldArm(originInTabContent: false), "the failed move did not start in tab content")
        XCTAssertFalse(shouldArm(presentedOverShell: true), "a cover or alert is up")
        XCTAssertFalse(shouldArm(vetoed: true), "an app-handled Left owns the press")
        XCTAssertFalse(shouldArm(heading: [.right]), "only Left arms")
    }

    func testDiagonalsAndOtherHeadingsNeverArm() {
        XCTAssertFalse(shouldArm(heading: [.left, .up]))
        XCTAssertFalse(shouldArm(heading: [.left, .down]))
        XCTAssertFalse(shouldArm(heading: [.up]), "BUG-98: Up never opens the rail")
        XCTAssertFalse(shouldArm(heading: [.down]))
        XCTAssertFalse(shouldArm(heading: []))
    }

    // MARK: Inside the rail (§2.4)

    func testRightExitsAndEverythingElseIsContained() {
        XCTAssertEqual(RailFocusPolicy.moveFailedInRail(heading: [.right]), .exitToContent)
        XCTAssertEqual(RailFocusPolicy.moveFailedInRail(heading: [.up]), .contained)
        XCTAssertEqual(RailFocusPolicy.moveFailedInRail(heading: [.down]), .contained)
        XCTAssertEqual(RailFocusPolicy.moveFailedInRail(heading: [.left]), .contained)
    }

    /// R4 (critique Q2, decided 2026-10-05): Menu closes a rail Left opened; anywhere else it is the
    /// system default, so Menu opens the rail at a root and Menu again leaves the app.
    func testMenuInRailDependsOnHowItOpened() {
        XCTAssertEqual(RailFocusPolicy.menuInRail(openedBy: .left), .closeToContent)
        XCTAssertEqual(RailFocusPolicy.menuInRail(openedBy: .menu), .systemDefault)
        XCTAssertEqual(RailFocusPolicy.menuInRail(openedBy: .hiddenBarRedirect), .systemDefault)
        XCTAssertEqual(RailFocusPolicy.menuInRail(openedBy: .rearm), .systemDefault)
    }

    /// R1: Select switches tab; Select on the tab on screen is the same as Right.
    func testSelect() {
        XCTAssertEqual(RailFocusPolicy.select(item: 2, currentTab: 0), .switchTab(2))
        XCTAssertEqual(RailFocusPolicy.select(item: 5, currentTab: 4), .switchTab(5))
        XCTAssertEqual(RailFocusPolicy.select(item: 0, currentTab: 0), .returnToCurrent)
    }

    // MARK: Visibility rule (§1.1, R7), one case per precedence step

    private func shown(railMode: Bool = true,
                       holdsFocus: Bool = false,
                       revealed: Bool = false,
                       rootCoverActive: Bool = false,
                       immersive: Bool = false,
                       scrolledDown: Bool = false,
                       visibility: NavigationChrome.RailVisibility = .whileBrowsing,
                       selectedTab: Int = 0) -> Bool {
        RailVisibilityRule.shown(RailVisibilityRule.Inputs(
            railMode: railMode, holdsFocus: holdsFocus, revealed: revealed,
            rootCoverActive: rootCoverActive, immersive: immersive, scrolledDown: scrolledDown,
            visibility: visibility, selectedTab: selectedTab))
    }

    func testNotRailModeIsNeverShown() {
        XCTAssertFalse(shown(railMode: false, holdsFocus: true, revealed: true, visibility: .always))
    }

    func testFocusWinsOverEveryHideTerm() {
        XCTAssertTrue(shown(holdsFocus: true, rootCoverActive: true, immersive: true, scrolledDown: true, selectedTab: 1))
    }

    func testRootCoverHidesAnUnfocusedRail() {
        XCTAssertFalse(shown(revealed: true, rootCoverActive: true, visibility: .always))
    }

    func testRevealedShowsOverTheBrowsingTerms() {
        XCTAssertTrue(shown(revealed: true, immersive: true, scrolledDown: true, selectedTab: 1))
    }

    func testAlwaysVisibleShowsWhileImmersiveScrolledOrOnSearch() {
        XCTAssertTrue(shown(immersive: true, scrolledDown: true, visibility: .always, selectedTab: 1))
    }

    func testHideWhileBrowsingHidesOnDetail() {
        XCTAssertFalse(shown(immersive: true))
    }

    func testHideWhileBrowsingHidesOnSearch() {
        XCTAssertFalse(shown(selectedTab: RailVisibilityRule.searchTab))
        XCTAssertEqual(RailVisibilityRule.searchTab, 1)
    }

    func testHideWhileBrowsingHidesWhenScrolledDown() {
        XCTAssertFalse(shown(scrolledDown: true))
    }

    func testHideWhileBrowsingShowsAtTheTop() {
        XCTAssertTrue(shown())
    }

    // MARK: The chrome model

    /// #8 / R4: a same-value `.scroll` write after a `.page` write leaves `.page` (Stage's page write
    /// owns the rail), and the mirror is per tab.
    func testSetScrolledDownKeepsTheMotionOfTheRealChange() {
        let model = NavigationChromeModel()
        model.setScrolledDown(tab: 0, true, motion: .page(seconds: 0.5))
        XCTAssertEqual(model.scrolledDownByTab[0], true)
        XCTAssertEqual(model.motionByTab[0], .page(seconds: 0.5))

        model.setScrolledDown(tab: 0, true)
        XCTAssertEqual(model.motionByTab[0], .page(seconds: 0.5), "a same-value write changes nothing")

        model.setScrolledDown(tab: 0, false)
        XCTAssertEqual(model.scrolledDownByTab[0], false)
        XCTAssertEqual(model.motionByTab[0], .scroll)

        model.setScrolledDown(tab: 2, true)
        XCTAssertEqual(model.motionByTab[2], .scroll)
        XCTAssertNil(model.scrolledDownByTab[1], "per tab, never one shared slot")
    }

    func testSetScrolledDownPublishesOnlyOnAChange() {
        let model = NavigationChromeModel()
        var publishes = 0
        let token = model.objectWillChange.sink { _ in publishes += 1 }
        model.setScrolledDown(tab: 0, true, motion: .page(seconds: 0.5))
        model.setScrolledDown(tab: 0, true)
        model.setScrolledDown(tab: 0, true, motion: .page(seconds: 0.5))
        model.setScrolledDown(tab: 0, false)
        XCTAssertEqual(publishes, 2)
        token.cancel()
    }

    func testRevealRequestsAreDistinctAndCarryTheirReason() {
        let model = NavigationChromeModel()
        let start = model.revealRequest.generation
        model.requestReveal(.menu)
        let first = model.revealRequest
        model.requestReveal(.menu)
        XCTAssertNotEqual(model.revealRequest, first, "two Menu presses are two observable changes")
        XCTAssertEqual(model.revealRequest.generation, start + 2)
        model.requestReveal(.hiddenBarRedirect)
        XCTAssertEqual(model.revealRequest.reason, .hiddenBarRedirect)
    }

    func testFocusedChromeAndGateAreWriteOnChange() {
        let model = NavigationChromeModel()
        var publishes = 0
        let token = model.objectWillChange.sink { _ in publishes += 1 }
        model.setFocusedChrome(true)
        model.setFocusedChrome(true)
        model.setContentGated(true)
        model.setContentGated(true)
        XCTAssertTrue(model.isFocusedChrome)
        XCTAssertTrue(model.contentGated)
        XCTAssertEqual(publishes, 2)
        token.cancel()
    }

    // MARK: Return routes (§2.5)

    private func route(_ name: String) -> RailReturnRoute {
        RailReturnRoute(name: name, capture: {}, restore: { false }, vetoesLeftArm: { false })
    }

    func testReturnRoutesAreAStackPerTab() {
        let model = NavigationChromeModel()
        let home = UUID(), detail = UUID(), search = UUID()
        XCTAssertNil(model.topReturnRoute(tab: 0))
        model.pushReturnRoute(tab: 0, token: home, route("home"))
        model.pushReturnRoute(tab: 0, token: detail, route("detail"))
        model.pushReturnRoute(tab: 1, token: search, route("search-detail"))
        XCTAssertEqual(model.topReturnRoute(tab: 0)?.name, "detail", "a page pushed over Home is on top")
        XCTAssertEqual(model.topReturnRoute(tab: 1)?.name, "search-detail")

        model.removeReturnRoute(tab: 0, token: detail)
        XCTAssertEqual(model.topReturnRoute(tab: 0)?.name, "home", "popping the page uncovers Home's route")
        model.removeReturnRoute(tab: 0, token: home)
        XCTAssertNil(model.topReturnRoute(tab: 0))
        XCTAssertEqual(model.topReturnRoute(tab: 1)?.name, "search-detail")
    }

    func testRePushingATokenMovesItToTheTopWithoutDuplicating() {
        let model = NavigationChromeModel()
        let home = UUID(), folder = UUID()
        model.pushReturnRoute(tab: 0, token: home, route("home"))
        model.pushReturnRoute(tab: 0, token: folder, route("folder"))
        model.pushReturnRoute(tab: 0, token: home, route("home"))
        XCTAssertEqual(model.topReturnRoute(tab: 0)?.name, "home")
        model.removeReturnRoute(tab: 0, token: home)
        XCTAssertEqual(model.topReturnRoute(tab: 0)?.name, "folder", "one entry per token")
        model.removeReturnRoute(tab: 0, token: UUID())
        XCTAssertEqual(model.topReturnRoute(tab: 0)?.name, "folder", "an unknown token removes nothing")
    }

    // MARK: Items

    func testRailItemsMatchTheTabShell() {
        XCTAssertEqual(RailItem.tabs.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertEqual(RailItem.tabs.map(\.title), ["Home", "Search", "Library", "Add-ons", "Settings"])
        XCTAssertEqual(RailItem.profile.id, 5)
        XCTAssertEqual(RailItem.title(for: 1), "Search")
        XCTAssertEqual(RailItem.title(for: 5), "Profile")
        XCTAssertNil(RailItem.title(for: 9))
        // The hand-off ladder keys Search's longer wait on the item title.
        XCTAssertEqual(SidebarHandOffLadder.checks(forTabTitled: RailItem.title(for: 1)).last, 2.5)
    }
}
