import XCTest

/// Add-ons hub v2, A2: the split shell on the FA87 fixture (Chris, which has add-ons). Section
/// selection by focus, focus memory between the columns (A0 finding 1), Menu routing (D6), and a
/// push inside the content column with Menu back, in Tabs and in Rail mode (A0 finding 2). Prints
/// `[SplitLeg]` lines. Nothing on the fixture is changed: no toggle, move, remove or install.
///
/// A8 rewrites `AddonsHubUITests` onto the final panes; these legs cover the shell only.
final class AddonsSplitUITests: XCTestCase {
    let remote = XCUIRemote.shared

    private func pause(_ s: TimeInterval) { Thread.sleep(forTimeInterval: s) }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func say(_ text: String) { print("[SplitLeg] \(text)") }

    /// Identifiers only: labels can carry add-on hosts.
    private func focusDump(_ app: XCUIApplication) -> String {
        let nodes = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        return nodes.isEmpty ? "<none>" : nodes.map { "[id=\($0.identifier)]" }.joined(separator: " ")
    }

    private func sidebar(_ app: XCUIApplication, _ section: String) -> XCUIElement { element(app, "addons_sidebar_\(section)") }

    private static let titles = ["installed": "Installed", "catalogs": "Catalogs", "debrid": "Debrid",
                                 "plugins": "Plugins", "install": "Install add-on", "refresh": "Refresh all"]

    /// A List row's focus sits on its CELL (no identifier), so match the focused cell's label too.
    private func sidebarHasFocus(_ app: XCUIApplication, _ section: String) -> Bool {
        if sidebar(app, section).exists && sidebar(app, section).hasFocus { return true }
        guard let title = Self.titles[section] else { return false }
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        return focused.contains { $0.label == title || $0.label.hasPrefix(title + ",") }
    }

    private func waitSidebarFocus(_ app: XCUIApplication, _ section: String, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if sidebarHasFocus(app, section) { return true }
            pause(0.2)
        }
        return sidebarHasFocus(app, section)
    }

    /// Moves focus within the sidebar to `section` (Down, then Up).
    @discardableResult
    private func moveSidebar(_ app: XCUIApplication, to section: String) -> Bool {
        for direction in [XCUIRemote.Button.down, .up] {
            for _ in 0..<7 {
                if sidebarHasFocus(app, section) { return true }
                remote.press(direction)
                pause(0.45)
            }
        }
        return sidebarHasFocus(app, section)
    }

    /// From the tab bar (Tabs mode) or wherever the tab entry left it: Down until a sidebar row has
    /// focus. The tab bar's own Right would switch tabs, so never press Right before this.
    private func enterSidebar(_ app: XCUIApplication) {
        for _ in 0..<4 {
            if Self.titles.keys.contains(where: { sidebarHasFocus(app, $0) }) { return }
            remote.press(.down)
            pause(0.8)
        }
    }

    @discardableResult
    private func moveFocus(_ direction: XCUIRemote.Button, until target: XCUIElement, max: Int) -> Bool {
        for _ in 0..<max {
            if target.exists && target.hasFocus { return true }
            remote.press(direction)
            pause(0.4)
        }
        return target.exists && target.hasFocus
    }

    private func waitFocus(_ target: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if target.exists && target.hasFocus { return true }
            pause(0.2)
        }
        return target.exists && target.hasFocus
    }

    private func press(_ button: XCUIRemote.Button, settle: TimeInterval = 1.0) {
        remote.press(button)
        pause(settle)
    }

    private static let baseArguments = ["-home_layout", "classic", "-debug.rememberLastProfile", "NO",
                                        "-debug.trailerForceNoTrailer", "YES", "-detail_trailer_autoplay", "NO"]

    private func launch(rail: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.baseArguments
        if rail {
            // `NavigationRailUITests.railArguments`: Stage Home, no upcoming row or inline trailers.
            app.launchArguments += ["-sidebar_style", "rail", "-rail_visibility", "always", "-home_layout", "stage",
                                    "-home_upcoming_row_enabled", "NO", "-inline_trailers_enabled", "NO",
                                    "-discover_placement", "off"]
        } else {
            app.launchArguments += ["-sidebar_style", "tabs"]
        }
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared")
        if chris.exists { DetailEntryRoute.selectChrisTile(self, app, timeout: 5) }
        pause(10)
        if rail { openAddonsViaRail(app) } else { openAddonsTab(app) }
        XCTAssertTrue(element(app, "addons_split_root").waitForExistence(timeout: 10),
                      "addons_split_root never appeared; focused: \(focusDump(app))")
        enterSidebar(app)
        say("entered: \(focusDump(app))")
        return app
    }

    private func openAddonsTab(_ app: XCUIApplication) {
        let tabNames = ["Home", "Search", "Discover", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<40 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.35)
        }
        let tab = app.buttons["Add-ons"]
        if !moveFocus(.right, until: tab, max: 7) { _ = moveFocus(.left, until: tab, max: 8) }
        XCTAssertTrue(tab.hasFocus, "the Add-ons tab never took focus; focused: \(focusDump(app))")
        press(.select, settle: 2)
    }

    /// `NavigationRailUITests`' route: Left until `rail_state` reads expanded, rail focus to item 3
    /// (Add-ons with Discover placement Off), Select.
    private func openAddonsViaRail(_ app: XCUIApplication) {
        func token(_ key: String) -> String? {
            let state = element(app, "rail_state").firstMatch
            guard state.exists else { return nil }
            for part in state.label.split(separator: " ") {
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2, pair[0] == Substring(key) { return String(pair[1]) }
            }
            return nil
        }
        for _ in 0..<15 where token("expanded") != "1" { press(.left, settle: 1.0) }
        XCTAssertEqual(token("expanded"), "1", "the rail never opened; focused: \(focusDump(app))")
        for _ in 0..<10 {
            let current = Int(token("focused") ?? "") ?? -1
            if current == 3 { break }
            if current >= 0 { remote.press(current < 3 ? .down : .up) }
            pause(0.5)
        }
        XCTAssertEqual(token("focused"), "3", "rail focus never reached Add-ons")
        press(.select, settle: 2.5)
    }

    /// From the sidebar, moves focus to `section`'s row and waits out the selection dwell.
    private func selectSection(_ app: XCUIApplication, _ section: String) {
        XCTAssertTrue(moveSidebar(app, to: section), "sidebar \(section) never took focus; focused: \(focusDump(app))")
        pause(0.8)
        XCTAssertTrue(element(app, "addons_content_\(section)").waitForExistence(timeout: 3),
                      "content for \(section) never appeared")
    }

    // MARK: - Legs

    /// Sidebar rows, entry focus on Installed, selection follows focus after the dwell.
    func testSplitShellSelectsSectionByFocus() throws {
        let app = launch(rail: false)
        for section in ["installed", "catalogs", "debrid", "install", "refresh"] {
            XCTAssertTrue(sidebar(app, section).exists, "addons_sidebar_\(section) missing")
        }
        XCTAssertFalse(sidebar(app, "phone").exists, "Manage from phone must stay hidden until Stage C")
        XCTAssertTrue(waitSidebarFocus(app, "installed"), "entry focus is not Installed; focused: \(focusDump(app))")
        XCTAssertTrue(element(app, "addons_content_installed").exists)
        selectSection(app, "catalogs")
        selectSection(app, "debrid")
        // The action row never becomes the content section: from Install add-on (selected) one
        // Down to Refresh all leaves the Install content in place.
        selectSection(app, "install")
        XCTAssertTrue(moveSidebar(app, to: "refresh"), "Refresh all never took focus")
        pause(0.8)
        XCTAssertTrue(element(app, "addons_content_install").exists, "focusing Refresh all replaced the content")
        say("selection by focus ok; focused: \(focusDump(app))")
    }

    /// A0 finding 1: Left from deep in the content lands on the SELECTED section's row and does
    /// not switch sections; D6: Menu at the content root goes to that row too.
    func testLeftAndMenuReturnToSelectedSection() throws {
        let app = launch(rail: false)
        selectSection(app, "debrid")
        press(.right)
        XCTAssertFalse(sidebarHasFocus(app, "debrid"), "Right did not leave the sidebar")
        for _ in 0..<4 { press(.down, settle: 0.6) }
        say("deep in Debrid content: \(focusDump(app))")
        press(.left)
        XCTAssertTrue(waitSidebarFocus(app, "debrid"), "Left landed off the selected row; focused: \(focusDump(app))")
        pause(0.8)
        XCTAssertTrue(element(app, "addons_content_debrid").exists, "Left switched the section")
        press(.right)
        XCTAssertFalse(sidebarHasFocus(app, "debrid"), "Right did not re-enter the content")
        press(.menu)
        XCTAssertTrue(waitSidebarFocus(app, "debrid"), "Menu at the content root did not go to the sidebar; focused: \(focusDump(app))")
        XCTAssertTrue(element(app, "addons_content_debrid").exists)
        XCTAssertTrue(element(app, "addons_split_root").exists, "Menu left the hub")
    }

    /// D2 + focus memory: the first card takes focus on Right, Select pushes the detail inside
    /// the content column, Menu pops back to the card; Left then Right comes back to the card.
    func testPushDetailMenuBackTabs() throws {
        try pushAndPop(launch(rail: false))
    }

    /// A0 finding 2: the same in Rail mode, where `HiddenTabBarFocusBlocker` used to throw focus
    /// onto the sidebar's top row 17 ms after the push.
    func testPushDetailMenuBackRail() throws {
        try pushAndPop(launch(rail: true))
    }

    private func pushAndPop(_ app: XCUIApplication) throws {
        let card0 = element(app, "addons_hub_card_0")
        XCTAssertTrue(card0.waitForExistence(timeout: 15), "no addons_hub_card_0 on the fixture (does Chris have add-ons?)")
        XCTAssertTrue(moveSidebar(app, to: "installed"), "Installed never took focus; focused: \(focusDump(app))")
        press(.right)
        XCTAssertTrue(waitFocus(card0), "Right did not land on the first card; focused: \(focusDump(app))")
        press(.select, settle: 1.5)
        let detail = element(app, "addons_detail_root")
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "the detail page was not pushed")
        pause(1.5)
        XCTAssertTrue(detail.exists, "the pushed detail page went away on its own")
        let refresh = element(app, "addons_hub_detail_refresh")
        XCTAssertTrue(waitFocus(refresh), "focus left the pushed page; focused: \(focusDump(app))")
        XCTAssertFalse(sidebarHasFocus(app, "installed"), "focus fell onto the sidebar after the push")
        press(.menu, settle: 1.5)
        XCTAssertFalse(detail.exists, "Menu did not pop the detail page")
        XCTAssertTrue(waitFocus(card0), "Menu did not return to the pushing card; focused: \(focusDump(app))")
        press(.left)
        XCTAssertTrue(waitSidebarFocus(app, "installed"), "Left did not land on Installed; focused: \(focusDump(app))")
        press(.right)
        XCTAssertTrue(waitFocus(card0), "Right did not come back to the remembered card; focused: \(focusDump(app))")
        say("push/pop ok")
    }
}
