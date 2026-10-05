import XCTest

/// Home Stage & Strip, W2-D (2026-10-05): the main session's simulator A/B of the rail's content
/// gate (`-debug.railGate uikit|perTab`) and a walk of the rail's focus graph. Not a pass/fail
/// leg: each step records the focused element and the `rail_state` probe, and screenshots go into
/// `docs/research/home-stage-strip-sim-evidence/`. W3 writes the real rail UI tests.
final class RailGateEvidenceTests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func focusedLabel(_ app: XCUIApplication) -> String {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard focused.exists else { return "<none>" }
        let id = focused.identifier.isEmpty ? "" : " #\(focused.identifier)"
        return "\(focused.label)\(id)"
    }

    private func railState(_ app: XCUIApplication) -> String {
        let probe = app.descendants(matching: .any)["rail_state"].firstMatch
        return probe.exists ? probe.label : "rail_state <absent>"
    }

    @discardableResult
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extra
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared")
        if chris.exists {
            remote.press(.left)
            pause(0.5)
            remote.press(.left)
            pause(0.5)
            remote.press(.select)
        }
        return app
    }

    func testRailWalkGateUIKit() {
        railWalk(gate: "uikit")
    }

    func testRailWalkGatePerTab() {
        railWalk(gate: "perTab")
    }

    private func railWalk(gate: String) {
        let app = launch(["-sidebar_style", "rail", "-home_layout", "stage", "-debug.railGate", gate])
        pause(16)
        var log: [String] = []
        func step(_ name: String, _ button: XCUIRemote.Button?, wait: TimeInterval = 1.5) {
            if let button { remote.press(button); pause(wait) }
            log.append("\(name): focus=\(focusedLabel(app)) | \(railState(app))")
        }
        let tag = "rail-\(gate)"
        step("launch", nil)
        shot("\(tag)-0-launch")
        step("down", .down, wait: 2.5)
        step("right", .right)
        step("right2", .right)
        step("left", .left)
        step("left2", .left)
        step("left-from-card0", .left, wait: 2)
        shot("\(tag)-1-rail-open")
        for i in 1...6 { step("rail-down\(i)", .down, wait: 0.8) }
        shot("\(tag)-2-rail-bottom")
        for i in 1...6 { step("rail-up\(i)", .up, wait: 0.8) }
        step("right-exit", .right, wait: 2)
        shot("\(tag)-3-after-right")
        step("page-down", .down, wait: 2.5)
        step("page-right", .right)
        step("page-right2", .right)
        step("menu-to-row0", .menu, wait: 3)
        step("menu-at-row0", .menu, wait: 2)
        shot("\(tag)-4-menu-rail")
        step("rail-to-search", .down, wait: 0.8)
        step("select-search", .select, wait: 4)
        shot("\(tag)-5-search")
        step("search-menu", .menu, wait: 2)
        shot("\(tag)-6-search-menu-rail")
        step("search-right", .right, wait: 3.5)
        shot("\(tag)-7-search-back")
        note("\(tag)-walk", log.joined(separator: "\n"))
    }

    /// Probe I (P4 §8; review r1, B P2-4): Always Visible on Search. Records the Linear and Grid
    /// keyboards' frames (the whole keyboard and its "a" key), Search's left content edge and the
    /// pill, with a screenshot of each keyboard. Decides whether the system keyboard clears the pill.
    func testProbeISearchAlwaysVisible() {
        let app = launch(["-sidebar_style", "rail", "-rail_visibility", "always", "-home_layout", "stage"])
        pause(16)
        var log: [String] = []
        func frame(_ element: XCUIElement) -> String {
            element.exists ? "\(element.frame)" : "<none>"
        }
        func record(_ name: String) {
            let pill = app.descendants(matching: .any)["navigation_rail"].firstMatch
            log.append("\(name): keyboard=\(frame(app.keyboards.firstMatch)) keyA=\(frame(app.keys["a"].firstMatch)) "
                       + "recent=\(frame(app.staticTexts["Recent Searches"].firstMatch)) "
                       + "field=\(frame(app.searchFields.firstMatch)) pill=\(frame(pill)) "
                       + "focus=\(focusedLabel(app)) | \(railState(app))")
        }
        remote.press(.down)          // into the strip
        pause(2.5)
        remote.press(.left)          // card 0: Left opens the rail
        pause(2)
        remote.press(.down)          // Home → Search
        pause(0.8)
        remote.press(.select)
        pause(4.5)                   // the system keyboard arrives 1–2 s after the tab opens
        record("linear")
        shot("probeI-0-linear")
        remote.press(.playPause)     // "Press ⏯ to change keyboards"
        pause(2.5)
        record("grid")
        shot("probeI-1-grid")
        remote.press(.playPause)     // back to Linear, the fixture's default
        pause(1.5)
        record("linear-again")
        note("probeI", log.joined(separator: "\n"))
    }

    /// R3 sweep (W3 Rail08 / Probe I follow-up, 2026-10-05): Always Visible's reserved width on every
    /// tab root and on a pushed Detail, after it moved to UIKit safe area at the shell. Records each
    /// screen's content left edge (the smallest minX among on-screen texts and buttons right of the
    /// pill) with a screenshot. Spec (P4 R3): 176 everywhere; Stage reads it from the environment.
    func testAlwaysVisibleInsetSweep() {
        var log: [String] = []
        func contentLeftEdge(_ app: XCUIApplication) -> String {
            let elements = app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex
            let xs = elements.compactMap { element -> CGFloat? in
                guard element.exists else { return nil }
                let f = element.frame
                // Right of the pill (16…100, plus its faded labels' overflow) and on screen.
                guard f.minX >= 110, f.minX < 1900, f.minY >= 0, f.minY < 1080, f.width > 20 else { return nil }
                return f.minX
            }
            guard let minX = xs.min() else { return "<none>" }
            return String(format: "%.1f", minX)
        }
        func record(_ app: XCUIApplication, _ name: String) {
            log.append("\(name): left=\(contentLeftEdge(app)) focus=\(focusedLabel(app)) | \(railState(app))")
            shot("inset-\(name)")
        }
        func press(_ button: XCUIRemote.Button, _ times: Int) {
            for _ in 0..<times {
                remote.press(button)
                pause(0.3)
            }
        }
        func openTab(_ app: XCUIApplication, steps: Int) {
            remote.press(.menu)                 // a tab root: Menu opens the rail on the current item
            pause(1.5)
            press(.up, 6)                       // to Home
            pause(0.6)
            press(.down, steps)
            pause(0.6)
            remote.press(.select)
            pause(4)
        }
        // Classic Home first (the Rail08 finding), then the other roots from it.
        let classic = launch(["-sidebar_style", "rail", "-rail_visibility", "always", "-home_layout", "classic"])
        pause(16)
        remote.press(.down)
        pause(1.5)
        remote.press(.down)
        pause(2)
        record(classic, "classic-home")
        remote.press(.select)                   // a Detail pushed from a Classic row
        pause(5)
        record(classic, "detail")
        remote.press(.menu)
        pause(2.5)
        // Up to the top of Home so Menu opens the rail rather than paging back.
        press(.up, 3)
        pause(2)
        openTab(classic, steps: 1)
        record(classic, "search")
        openTab(classic, steps: 2)
        record(classic, "library")
        openTab(classic, steps: 3)
        record(classic, "addons")
        openTab(classic, steps: 4)
        record(classic, "settings")
        note("inset-sweep", log.joined(separator: "\n"))
    }

    /// Hide While Browsing: the rail shows at the top and hides once the strip leaves row 0.
    func testRailHideWhileBrowsing() {
        let app = launch(["-sidebar_style", "rail", "-home_layout", "stage", "-rail_visibility", "browsing"])
        pause(16)
        var log: [String] = []
        func step(_ name: String, _ button: XCUIRemote.Button?, wait: TimeInterval = 2.5) {
            if let button { remote.press(button); pause(wait) }
            log.append("\(name): focus=\(focusedLabel(app)) | \(railState(app))")
        }
        step("launch", nil)
        shot("rail-browsing-0-launch")
        step("down", .down)
        shot("rail-browsing-1-down")
        step("down2", .down)
        shot("rail-browsing-2-down2")
        step("up", .up)
        step("up2", .up)
        shot("rail-browsing-3-top")
        note("rail-browsing-walk", log.joined(separator: "\n"))
    }
}
