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

    @discardableResult
    private func launchToHome(extraArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extraArguments
        app.launch()
        let chris = app.buttons["Chris"]
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

    /// Search, back to Home, two Downs, then Settings › About; returns the pane's lines.
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

        openTab(app, named: "Settings")
        let about = app.buttons["About"]
        _ = moveFocus(.down, until: about, max: 8)
        press(.right, times: 1)
        pause(1.5)
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

        let lostAfterAttach = lines[attachIdx...].filter {
            probeField($0, "sel") == "0" && probeField($0, "trk") == "none"
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
