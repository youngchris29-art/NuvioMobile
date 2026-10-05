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
