import XCTest

/// beta.18 verdict (BUG-66): the explicit tab-bar scroll link (`TabBarContentScrollLink`), proven
/// through the Tab Bar Geometry pane's `trk=` field (`TabBarStateProbe`).
///
/// The tester's two pane photos showed the bar following Home's rows after a cold launch in one
/// session and pinned in another; the reading is that UIKit's own scroll-view search found the
/// rows only before the pinned hero header mounted, and lost them after a tab switch. Leg A proves
/// the link holds across exactly that switch; leg B proves the A/B knob's OFF leg leaves nothing
/// linked, so the device A/B compares the right two things.
///
/// Fixture: the signed-in simulator `FA87E9B6-F28D-4DF9-84E4-A5A4C5DBFC4E` (profile "Chris").
/// Hero mode is whatever the fixture profile carries — neither leg depends on it.
///
/// Helpers are a trimmed copy of `HeroOffLaunchTests`' (private there, by this harness's
/// duplication rule).
final class TabBarScrollLinkTests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, gap: TimeInterval = 0.8) {
        for _ in 0..<times {
            remote.press(button)
            pause(gap)
        }
    }

    @discardableResult
    private func moveFocus(_ direction: XCUIRemote.Button, until element: XCUIElement, max: Int = 12) -> Bool {
        for _ in 0..<max {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(0.7)
        }
        return element.exists && element.hasFocus
    }

    /// Copy of `HeroOffLaunchTests.openTab`.
    private func openTab(_ app: XCUIApplication, named title: String) {
        let tabNames = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<40 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.35)
        }
        press(.up, times: 1, gap: 0.5)
        let tab = app.buttons[title]
        if !moveFocus(.right, until: tab, max: 6) {
            _ = moveFocus(.left, until: tab, max: 8)
        }
        remote.press(.select)
        pause(2)
        press(.down, times: 1)
    }

    // MARK: - Settings root navigation (detail-settings-revamp W3-C, FEAT-50)
    //
    // Settings is a `NavigationStack`: a root `List` of ten categories (`settings_root_list`, each
    // row `settings_category_<raw>`) and one pushed pane per category (`settings_pane_<raw>`).
    // Select on a root row pushes the pane and focus lands on the pane's FIRST focusable row; Menu
    // inside a pane pops back to the root with focus on the category just left. There is no
    // sidebar and no Right-into-the-pane step any more. Duplicated per file (house rule: every UI
    // test file owns its helpers).

    /// The fixed root order, mirroring `SettingsCategory.allCases` (SettingsView.swift).
    private static let settingsRootOrder: [(title: String, raw: String)] = [
        ("Account & Profiles", "accountProfiles"), ("Services", "services"), ("Appearance", "appearance"),
        ("Home Screen", "homeScreen"), ("Detail Page", "detailPage"), ("Player", "player"),
        ("Sources", "sources"), ("Subtitles & Audio", "subtitlesAudio"), ("About", "about"),
        ("Developer", "developer"),
    ]

    /// Whether the Settings ROOT list is on screen (a pushed pane removes it from the tree).
    private func settingsRootPresent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings_root_list"].exists
            || app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings_category_'"))
                .firstMatch.exists
    }

    /// Whether a pushed Settings pane is on screen.
    private func settingsPanePresent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings_pane_title"].exists
            || app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings_pane_'"))
                .firstMatch.exists
    }

    /// Identifier + label of every element that reports focus, from ONE snapshot (a List row's
    /// focus can sit on its wrapping Cell or on the inner Button; reading both in one pass avoids
    /// the per-element `hasFocus` sweep).
    private func focusedNodes(_ app: XCUIApplication) -> [(identifier: String, label: String)] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [(identifier: String, label: String)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus { out.append((node.identifier, node.label)) }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// The title of the focused Settings ROOT row, or nil. Detected by the row's identifier
    /// (`settings_category_<raw>`) or by a focused element whose label begins with a category
    /// title (corrections F9).
    private func focusedSettingsRootTitle(_ app: XCUIApplication) -> String? {
        let nodes = focusedNodes(app)
        for node in nodes where node.identifier.hasPrefix("settings_category_") {
            let raw = String(node.identifier.dropFirst("settings_category_".count))
            if let entry = Self.settingsRootOrder.first(where: { $0.raw == raw }) { return entry.title }
        }
        for node in nodes {
            if let entry = Self.settingsRootOrder.first(where: { node.label.hasPrefix($0.title) }) { return entry.title }
        }
        return nil
    }

    /// Opens the Settings tab and makes sure the ROOT list is showing: pops any pane the persisted
    /// path left open (Menu only while a pane is up and the root is absent — Menu AT the root
    /// reveals the sidebar or leaves the app). Returns whether the root is on screen.
    @discardableResult
    private func enterSettingsRoot(_ app: XCUIApplication) -> Bool {
        openTab(app, named: "Settings")
        pause(0.8)
        for _ in 0..<3 where !settingsRootPresent(app) && settingsPanePresent(app) {
            remote.press(.menu)
            pause(1.2)
        }
        return settingsRootPresent(app)
    }

    /// With the root showing, puts focus on the root row `title` WITHOUT pushing it.
    ///
    /// Arrival is detected by identifier / focused label; when detection never fires the walk falls
    /// back to the fixed root order: Down ×12 parks on the LAST row (Down from the last row does
    /// nothing), then Up by the distance. (Up ×12 to the tab bar then Down is NOT deterministic:
    /// Down from the tab bar lands on the root's preferred row, which is the last category opened,
    /// not the first.) Returns whether arrival was DETECTED (false after a blind fallback).
    @discardableResult
    private func focusSettingsRootRow(_ app: XCUIApplication, named title: String) -> Bool {
        guard let index = Self.settingsRootOrder.firstIndex(where: { $0.title == title }) else {
            XCTFail("focusSettingsRootRow: unknown category '\(title)'")
            return false
        }
        if focusedSettingsRootTitle(app) == title { return true }
        for _ in 0..<10 {
            remote.press(.down)
            pause(0.6)
            if focusedSettingsRootTitle(app) == title { return true }
        }
        for _ in 0..<10 {
            remote.press(.up)
            pause(0.6)
            if focusedSettingsRootTitle(app) == title { return true }
        }
        press(.down, times: 12, gap: 0.4)
        press(.up, times: Self.settingsRootOrder.count - 1 - index, gap: 0.6)
        pause(0.6)
        return focusedSettingsRootTitle(app) == title
    }

    /// Opens Settings, returns to the root, focuses the category `title` and pushes it. Returns
    /// whether `settings_pane_<raw>` appeared.
    @discardableResult
    private func openSettingsCategory(_ app: XCUIApplication, named title: String) -> Bool {
        guard let entry = Self.settingsRootOrder.first(where: { $0.title == title }) else {
            XCTFail("openSettingsCategory: unknown category '\(title)'")
            return false
        }
        guard enterSettingsRoot(app) else {
            XCTFail("openSettingsCategory(\(title)): the Settings root list never appeared")
            return false
        }
        focusSettingsRootRow(app, named: title)
        remote.press(.select)
        pause(1.5)
        return app.descendants(matching: .any)["settings_pane_\(entry.raw)"].waitForExistence(timeout: 4)
    }

    /// Settings › Developer (the probe readouts moved here from About in the revamp).
    @discardableResult
    private func openDeveloper(_ app: XCUIApplication) -> Bool {
        openSettingsCategory(app, named: "Developer")
    }

    @discardableResult
    private func launchToHome(extraArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // Home Stage & Strip (W3, 2026-10-05): Stage is the app's default Home now, and this file
        // measures Classic Home (Classic's rows scroll link; the Stage analogue is
        // `StageStripUITests.testS06`), so every launch pins Classic.
        app.launchArguments += ["-home_layout", "classic"]
        app.launchArguments += extraArguments
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90),
                      "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        return app
    }

    /// Reads `tab_bar_state_probe_blob` off Settings › About (the hidden single-`Text` blob, in the
    /// PERSISTED chronological order — see `AboutSettingsPane`).
    private func tabBarProbeLines(_ app: XCUIApplication) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        func findBlob(_ node: XCUIElementSnapshot) -> String? {
            if node.identifier == "tab_bar_state_probe_blob", !node.label.isEmpty { return node.label }
            for child in node.children {
                if let hit = findBlob(child) { return hit }
            }
            return nil
        }
        guard let blob = findBlob(root) else { return [] }
        return blob.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func probeField(_ line: String, _ key: String) -> String? {
        let prefix = "\(key)="
        for token in line.split(separator: " ") where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    /// Search, back to Home, two Downs, then Settings › Developer (About until the revamp); returns the pane's lines.
    private func walkAndReadPane(_ app: XCUIApplication, tag: String) -> [String] {
        // Rows and hero settle; the attach (or its absence) happens in this window.
        pause(10)
        shot(app, "\(tag)_home_settled")
        openTab(app, named: "Search")
        pause(1.5)
        openTab(app, named: "Home")
        pause(2)
        press(.down, times: 2)
        pause(1.5)
        shot(app, "\(tag)_home_after_switch")

        // Revamp (FEAT-50): the probe readouts moved from About into the Developer pane, reached
        // root → push (no sidebar, no Right step).
        XCTAssertTrue(openDeveloper(app), "Settings › Developer pane did not open")
        pause(1.0)
        // The Tab Bar Geometry block sits well down the Developer pane's lazy List: walk Down until
        // its blob is in the tree (an overshoot is harmless extra presses at the bottom).
        for _ in 0..<30 where tabBarProbeLines(app).isEmpty {
            remote.press(.down)
            pause(0.5)
        }
        shot(app, "\(tag)_about_probe")

        let lines = tabBarProbeLines(app)
        let blob = lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: blob)
        attachment.name = "\(tag)_tab_bar_probe_lines"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[TabBarStateProbe] \(tag):\n\(blob)")
        return lines
    }

    // MARK: - Leg A

    func test75TabBarScrollLinkTracksHomeRowsAfterTabSwitch() throws {
        let app = launchToHome(extraArguments: ["-debug.tabBarStateProbe", "YES"])
        let lines = walkAndReadPane(app, tag: "75")
        guard !lines.isEmpty else {
            XCTFail("75: tab_bar_state_probe_blob produced no lines — probe not armed, or the About readout did not render")
            return
        }

        guard let attachIdx = lines.firstIndex(where: { probeField($0, "r") == "attach" }) else {
            XCTFail("75: no r=attach line — TabBarContentScrollLink never linked the Home rows. lines=\(lines)")
            return
        }
        XCTAssertEqual(probeField(lines[attachIdx], "trk"), "rows",
                       "75: the attach sample must already read trk=rows — \(lines[attachIdx])")

        // The settled sample after the return to Home: the last `tab2` whose selection is Home.
        let homeTab2 = lines.filter { probeField($0, "r") == "tab2" && probeField($0, "sel") == "0" }
        XCTAssertFalse(homeTab2.isEmpty, "75: no r=tab2 sel=0 line after returning to Home. lines=\(lines)")
        if let last = homeTab2.last {
            XCTAssertEqual(probeField(last, "trk"), "rows",
                           "75: after Search → Home the bar must still track the rows — \(last)")
        }

        // `r=tab` is sampled the instant the selection changes, before Home's rows view has
        // re-entered the window (review r2: the link is withdrawn while Home is off-window and
        // re-asserted on `didMoveToWindow`), so that one sample legitimately reads `trk=none`;
        // the settled `tab2` sample and every later tick must not.
        let lostAfterAttach = lines[attachIdx...].filter {
            probeField($0, "sel") == "0" && probeField($0, "trk") == "none" && probeField($0, "r") != "tab"
        }
        XCTAssertTrue(lostAfterAttach.isEmpty,
                      "75: Home lost its tracked scroll view after the attach — \(lostAfterAttach)")
    }

    // MARK: - Leg B

    func test76TabBarScrollLinkOffIsInert() throws {
        let app = launchToHome(extraArguments: [
            "-debug.tabBarStateProbe", "YES",
            "-debug.bug66ContentScrollView", "NO",
        ])
        let lines = walkAndReadPane(app, tag: "76")
        guard !lines.isEmpty else {
            XCTFail("76: tab_bar_state_probe_blob produced no lines — probe not armed, or the About readout did not render")
            return
        }
        let attaches = lines.filter { probeField($0, "r") == "attach" }
        XCTAssertTrue(attaches.isEmpty, "76: the OFF leg must never link — \(attaches)")

        let home = lines.filter { probeField($0, "sel") == "0" }
        XCTAssertFalse(home.isEmpty, "76: no sel=0 sample at all. lines=\(lines)")
        let linked = home.filter {
            let trk = probeField($0, "trk")
            return trk != "none" && trk != "other"
        }
        XCTAssertTrue(linked.isEmpty, "76: with the link OFF, Home samples must read trk=none/other — \(linked)")
    }
}
