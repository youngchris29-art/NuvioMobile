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
                                 "plugins": "Plugins", "install": "Install add-on", "refresh": "Refresh all",
                                 "phone": "Manage from phone"]

    /// A focused element whose label is `label` or starts with it and a comma (List cells carry
    /// the row's label, toggles add their value).
    private func labelHasFocus(_ app: XCUIApplication, _ label: String) -> Bool {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        return focused.contains { $0.label == label || $0.label.hasPrefix(label + ",") }
    }

    private func waitLabelFocus(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if labelHasFocus(app, label) { return true }
            pause(0.2)
        }
        return labelHasFocus(app, label)
    }

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

    /// C2: Manage from phone hosts Remote Setup: it starts shortly after the section opens (status
    /// and address appear) and closes when the section is left. Prints no address (it carries the
    /// pairing token).
    func testManageFromPhoneStartsAndStops() throws {
        let app = launch(rail: false)
        XCTAssertTrue(waitSidebarFocus(app, "installed"), "entry focus is not Installed; focused: \(focusDump(app))")
        selectSection(app, "phone")
        XCTAssertTrue(element(app, "addons_phone_pane").waitForExistence(timeout: 3), "phone pane missing")
        XCTAssertTrue(element(app, "addons_phone_url").firstMatch.waitForExistence(timeout: 8), "Remote Setup never started")
        let status = element(app, "addons_phone_status").firstMatch
        XCTAssertTrue(status.exists)
        XCTAssertTrue(status.label.contains("Ready") || status.label.contains("Page opened"), "status: \(status.label)")
        say("phone: started, status \(status.label)")
        // Right enters the pane on its one control.
        press(.right)
        XCTAssertTrue(waitLabelFocus(app, "New code"), "the pane's control did not take focus; focused: \(focusDump(app))")
        // Back to the sidebar and up a section: the pane (and its server) goes away.
        press(.menu)
        XCTAssertTrue(moveSidebar(app, to: "refresh"), "could not move up to Refresh all")
        XCTAssertTrue(moveSidebar(app, to: "install"), "could not move up to Install add-on")
        pause(1.0)
        XCTAssertFalse(element(app, "addons_phone_pane").exists, "the phone pane outlived its section")
        say("phone: closed on leaving")
    }

    /// HTTP status for `url` (GET, 3 s), or nil when nothing answers. Never prints the address.
    private func httpStatus(_ url: String) -> Int? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target, timeoutInterval: 3)
        request.httpMethod = "GET"
        let done = DispatchSemaphore(value: 0)
        var status: Int?
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return status
    }

    /// Posts `body` to the session's /api/apply (token from the page address) and returns the
    /// change id, or nil. Never prints the address.
    private func postProposal(_ pageUrl: String, _ body: String) -> String? {
        guard let page = URLComponents(string: pageUrl),
              let token = page.queryItems?.first(where: { $0.name == "t" })?.value,
              var apply = URLComponents(string: pageUrl) else { return nil }
        apply.path = "/api/apply"
        apply.query = nil
        guard let url = apply.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Setup-Token")
        request.httpBody = Data(body.utf8)
        let done = DispatchSemaphore(value: 0)
        var id: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { id = json["id"] as? String }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return id
    }

    /// The status of change `id` (`/api/status/{id}`), or nil.
    private func proposalStatus(_ pageUrl: String, _ id: String) -> String? {
        guard let page = URLComponents(string: pageUrl),
              let token = page.queryItems?.first(where: { $0.name == "t" })?.value,
              var status = URLComponents(string: pageUrl) else { return nil }
        status.path = "/api/status/\(id)"
        status.query = nil
        guard let url = status.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue(token, forHTTPHeaderField: "X-Setup-Token")
        let done = DispatchSemaphore(value: 0)
        var value: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { value = json["status"] as? String }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return value
    }

    /// C3: a change from the phone opens the per-change dialog with focus on Confirm; Reject and
    /// Confirm settle it. The proposal is empty, so nothing on the fixture changes.
    func testPhoneChangeOpensTheConfirmDialog() throws {
        let app = launch(rail: false)
        XCTAssertTrue(waitSidebarFocus(app, "installed"), "entry focus is not Installed; focused: \(focusDump(app))")
        selectSection(app, "phone")
        let urlLabel = element(app, "addons_phone_url").firstMatch
        XCTAssertTrue(urlLabel.waitForExistence(timeout: 8), "Remote Setup never started")
        let page = urlLabel.label

        // Reject.
        let first = try XCTUnwrap(postProposal(page, "{}"), "the proposal was not accepted")
        let dialog = element(app, "phone_confirm_dialog").firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "the confirm dialog never opened")
        XCTAssertTrue(app.staticTexts["Nothing would change."].exists, "the empty change is not described")
        XCTAssertTrue(waitLabelFocus(app, "Confirm"), "focus is not on Confirm; focused: \(focusDump(app))")
        press(.left)
        XCTAssertTrue(waitLabelFocus(app, "Reject"), "Left did not reach Reject; focused: \(focusDump(app))")
        press(.select, settle: 1.5)
        XCTAssertFalse(dialog.exists, "the dialog stayed after Reject")
        XCTAssertEqual(proposalStatus(page, first), "rejected")
        say("phone: rejected from the dialog")

        // Confirm (an empty change applies nothing).
        pause(1.2)
        let second = try XCTUnwrap(postProposal(page, "{}"), "the second proposal was not accepted")
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "the confirm dialog never opened again")
        XCTAssertTrue(waitLabelFocus(app, "Confirm"), "focus is not on Confirm; focused: \(focusDump(app))")
        press(.select, settle: 1.5)
        XCTAssertFalse(dialog.exists, "the dialog stayed after Confirm")
        XCTAssertEqual(proposalStatus(page, second), "confirmed")
        say("phone: confirmed from the dialog")
    }

    /// C2 review r2: leaving the Add-ons TAB (not just the section) closes Remote Setup, and coming
    /// back opens a fresh session (a new address). The old address must stop answering.
    func testManageFromPhoneClosesWhenTheTabChanges() throws {
        let app = launch(rail: false)
        XCTAssertTrue(waitSidebarFocus(app, "installed"), "entry focus is not Installed; focused: \(focusDump(app))")
        selectSection(app, "phone")
        let urlLabel = element(app, "addons_phone_url").firstMatch
        XCTAssertTrue(urlLabel.waitForExistence(timeout: 8), "Remote Setup never started")
        let first = urlLabel.label
        XCTAssertEqual(httpStatus(first), 200, "the first session does not answer")
        // Up to the tab bar, then onto Library: the Add-ons tab is no longer selected.
        let tabNames = ["Home", "Search", "Discover", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<20 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            press(.up, settle: 0.4)
        }
        XCTAssertTrue(moveFocus(.left, until: app.buttons["Library"], max: 4), "Library tab never took focus")
        press(.select, settle: 2)
        XCTAssertNil(httpStatus(first).flatMap { $0 == 200 ? $0 : nil }, "the session still answers after leaving the tab")
        say("phone: closed on a tab switch")
        // Back to Add-ons: the section is still selected, so a fresh session starts.
        for _ in 0..<20 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            press(.up, settle: 0.4)
        }
        XCTAssertTrue(moveFocus(.right, until: app.buttons["Add-ons"], max: 4), "Add-ons tab never took focus")
        press(.select, settle: 2)
        let contents = ["installed", "catalogs", "debrid", "plugins", "install", "phone"].filter { element(app, "addons_content_\($0)").exists }
        say("back on Add-ons: sections showing \(contents)")
        // The old session stays closed whatever the hub restored to.
        XCTAssertNotEqual(httpStatus(first), 200, "the old session answers again after coming back")
        // The tab can rebuild the hub on return; open the section again if it is not showing.
        if !element(app, "addons_content_phone").exists {
            enterSidebar(app)
            selectSection(app, "phone")
        }
        let fresh = element(app, "addons_phone_url").firstMatch
        let restarted = NSPredicate(format: "exists == true AND label != %@", first)
        let wait = XCTNSPredicateExpectation(predicate: restarted, object: fresh)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 10), .completed, "no fresh session after coming back")
        XCTAssertEqual(httpStatus(fresh.label), 200, "the fresh session does not answer")
        say("phone: fresh session on return")
    }

    /// C2 review r3: Settings › Account & Profiles › Manage from phone switches to the Add-ons tab,
    /// selects the phone section and leaves focus on its sidebar row (hub already visited, Tabs).
    /// Never presses Select on any row other than the target (Sign Out sits first in that pane).
    func testSettingsRowOpensManageFromPhone() throws {
        let app = launch(rail: false)
        XCTAssertTrue(waitSidebarFocus(app, "installed"), "entry focus is not Installed; focused: \(focusDump(app))")
        let tabNames = ["Home", "Search", "Discover", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<20 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            press(.up, settle: 0.4)
        }
        XCTAssertTrue(moveFocus(.right, until: app.buttons["Settings"], max: 4), "Settings tab never took focus")
        press(.select, settle: 2)
        // List focus sits on the cell, so rows are matched by label (the row's identifier is on
        // its content, and the lazy List builds it only once scrolled into view).
        // Account & Profiles is the first category: Down from the tab bar until it holds focus.
        var onCategory = waitLabelFocus(app, "Account & Profiles", timeout: 2)
        for _ in 0..<3 where !onCategory {
            press(.down, settle: 1.0)
            onCategory = labelHasFocus(app, "Account & Profiles")
        }
        XCTAssertTrue(onCategory, "Account & Profiles never took focus; focused: \(focusDump(app))")
        guard onCategory else { return }
        press(.select, settle: 1.5)
        var onRow = false
        for _ in 0..<10 {
            if labelHasFocus(app, "Manage from phone") { onRow = true; break }
            press(.down, settle: 0.8)
        }
        XCTAssertTrue(onRow, "the Manage from phone row never took focus; focused: \(focusDump(app))")
        guard onRow else { return }
        press(.select, settle: 2.5)
        XCTAssertTrue(element(app, "addons_content_phone").waitForExistence(timeout: 5), "the hub did not show Manage from phone")
        XCTAssertTrue(waitSidebarFocus(app, "phone"), "focus is not on the phone row; focused: \(focusDump(app))")
        XCTAssertTrue(element(app, "addons_phone_url").firstMatch.waitForExistence(timeout: 8), "Remote Setup never started")
        say("phone: opened from Settings")
    }

    /// Sidebar rows, entry focus on Installed, selection follows focus after the dwell.
    func testSplitShellSelectsSectionByFocus() throws {
        let app = launch(rail: false)
        for section in ["installed", "catalogs", "debrid", "install", "refresh"] {
            XCTAssertTrue(sidebar(app, section).exists, "addons_sidebar_\(section) missing")
        }
        XCTAssertTrue(sidebar(app, "phone").exists, "Manage from phone is visible since C2")
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

    /// D2 + focus memory: the first row takes focus on Right, Select pushes the detail inside
    /// the content column, Menu pops back to the row; Left then Right comes back to the row.
    func testPushDetailMenuBackTabs() throws {
        try pushAndPop(launch(rail: false))
    }

    /// A0 finding 2: the same in Rail mode, where `HiddenTabBarFocusBlocker` used to throw focus
    /// onto the sidebar's top row 17 ms after the push.
    func testPushDetailMenuBackRail() throws {
        try pushAndPop(launch(rail: true))
    }

    /// A List row's focus sits on its CELL, so match the row's identifier OR a focused element whose
    /// label is the add-on's title (or starts with it and a comma). The label is compared, never printed.
    private func rowHasFocus(_ app: XCUIApplication, index: Int, title: String) -> Bool {
        let row = element(app, "addons_row_\(index)")
        if row.exists && row.hasFocus { return true }
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        return focused.contains { $0.label == title || $0.label.hasPrefix(title + ",") }
    }

    private func waitRowFocus(_ app: XCUIApplication, index: Int, title: String, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if rowHasFocus(app, index: index, title: title) { return true }
            pause(0.2)
        }
        return rowHasFocus(app, index: index, title: title)
    }

    private func pushAndPop(_ app: XCUIApplication) throws {
        let row0 = element(app, "addons_row_0")
        XCTAssertTrue(row0.waitForExistence(timeout: 15), "no addons_row_0 on the fixture (does Chris have add-ons?)")
        let title = row0.label
        XCTAssertFalse(title.isEmpty, "addons_row_0 has no label")
        XCTAssertTrue(moveSidebar(app, to: "installed"), "Installed never took focus; focused: \(focusDump(app))")
        press(.right)
        XCTAssertTrue(waitRowFocus(app, index: 0, title: title), "Right did not land on the first row; focused: \(focusDump(app))")
        press(.select, settle: 1.5)
        let detail = element(app, "addons_detail_root")
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "the detail page was not pushed")
        pause(1.5)
        XCTAssertTrue(detail.exists, "the pushed detail page went away on its own")
        // A5: the detail page opens on its Enabled row.
        XCTAssertTrue(waitLabelFocus(app, "Enabled"), "the detail page did not open on Enabled; focused: \(focusDump(app))")
        XCTAssertFalse(sidebarHasFocus(app, "installed"), "focus fell onto the sidebar after the push")
        press(.menu, settle: 1.5)
        XCTAssertFalse(detail.exists, "Menu did not pop the detail page")
        XCTAssertTrue(waitRowFocus(app, index: 0, title: title), "Menu did not return to the pushing row; focused: \(focusDump(app))")
        press(.left)
        XCTAssertTrue(waitSidebarFocus(app, "installed"), "Left did not land on Installed; focused: \(focusDump(app))")
        press(.right)
        XCTAssertTrue(waitRowFocus(app, index: 0, title: title), "Right did not come back to the remembered row; focused: \(focusDump(app))")
        say("push/pop ok")
    }
}
