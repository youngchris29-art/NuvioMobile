import XCTest

/// Detail + Settings revamp (2026-10-02): screenshot harness for the design checkpoints (Gate 1/2).
/// Not a pass/fail leg: each test opens one surface through the `-debug.openDeepLink` hook (or the
/// Settings tab), attaches screenshots plus the accessibility tree, and asserts only that it got
/// there. Attachments are pulled out of the .xcresult into
/// `docs/research/detail-settings-revamp-sim-evidence/`.
final class RevampEvidenceTests: XCTestCase {

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

    private func tree(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, gap: TimeInterval = 0.6) {
        for _ in 0..<times {
            remote.press(button)
            pause(gap)
        }
    }

    @discardableResult
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extra
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared")
        if chris.exists {
            // Default focus is the first profile; Left is a no-op there, Right would hit Add Profile.
            press(.left, times: 2, gap: 0.5)
            remote.press(.select)
        }
        return app
    }

    private func detail(_ name: String, url: String, layout: String = "cinematic", settle: TimeInterval = 14) {
        let app = launch(["-debug.openDeepLink", url, "-detail_layout", layout])
        pause(settle)
        shot("\(name)-landing")
        tree(app, "\(name)-tree")
        pause(8)
        shot("\(name)-settled")
    }

    func testDetailMovie() {
        detail("detail-movie-dune", url: "nuviotv://title?id=tt15239678&type=movie&name=Dune")
    }

    func testDetailSeries() {
        detail("detail-series-the100", url: "nuviotv://title?id=tt2661044&type=series&name=The%20100")
    }

    func testDetailLongSynopsis() {
        detail("detail-long-synopsis", url: "nuviotv://title?id=tt0903747&type=series&name=Breaking%20Bad")
    }

    func testDetailNoLogo() {
        detail("detail-no-logo", url: "nuviotv://title?id=tt0050083&type=movie&name=12%20Angry%20Men")
    }

    func testDetailNoBackdrop() {
        detail("detail-obscure", url: "nuviotv://title?id=tt0000417&type=movie&name=A%20Trip%20to%20the%20Moon")
    }

    func testDetailClassic() {
        detail("detail-classic-dune", url: "nuviotv://title?id=tt15239678&type=movie&name=Dune", layout: "classic")
    }

    func testDetailSynopsisSheetAndScroll() {
        let app = launch(["-debug.openDeepLink", "nuviotv://title?id=tt0903747&type=series&name=Breaking%20Bad"])
        pause(25)
        // Up from Play reaches the teaser when it is truncated.
        press(.up)
        pause(1)
        shot("detail-teaser-focused")
        if app.buttons["detail_synopsis_teaser"].exists || app.descendants(matching: .any)["detail_synopsis_teaser"].exists {
            remote.press(.select)
            pause(2)
            shot("detail-synopsis-sheet")
            tree(app, "detail-synopsis-sheet-tree")
            remote.press(.menu)
            pause(2)
            shot("detail-after-sheet-menu")
        }
        press(.down, times: 2, gap: 1.2)
        pause(2)
        shot("detail-down-into-rows")
    }

    func testSettingsRootAndPane() {
        let app = launch([])
        pause(8)
        let settings = app.buttons["Settings"]
        press(.up, times: 6, gap: 0.4)
        for _ in 0..<8 where !(settings.exists && settings.hasFocus) {
            remote.press(.right)
            pause(0.5)
        }
        remote.press(.select)
        pause(3)
        press(.down)
        pause(1.5)
        shot("settings-root")
        tree(app, "settings-root-tree")
        press(.down, times: 3, gap: 0.8)
        shot("settings-root-homescreen-focused")
        remote.press(.select)
        pause(2.5)
        shot("settings-pane-homescreen")
        press(.down, times: 2, gap: 0.8)
        shot("settings-pane-homescreen-row2")
        tree(app, "settings-pane-tree")
        remote.press(.menu)
        pause(2)
        shot("settings-after-pop")
    }

    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        press(.up, times: 6, gap: 0.4)
        for _ in 0..<8 where !(settings.exists && settings.hasFocus) {
            remote.press(.right)
            pause(0.5)
        }
        remote.press(.select)
        pause(3)
        press(.down)
        pause(1.5)
    }

    func testSettingsEveryPane() {
        let app = launch([])
        pause(8)
        openSettings(app)
        // Anchor on the first category, then walk the fixed root order.
        // Up×12 parks focus on the tab bar; one Down lands on the first category.
        press(.up, times: 12, gap: 0.3)
        press(.down)
        pause(1)
        shot("settings-root-top")
        let names = ["account", "services", "appearance", "homescreen", "detailpage",
                     "player", "sources", "subtitles", "about", "developer"]
        for (index, name) in names.enumerated() {
            remote.press(.select)
            pause(2.5)
            shot("pane-\(index)-\(name)-top")
            press(.down, times: 2, gap: 0.8)
            shot("pane-\(index)-\(name)-row")
            if index == 0 { tree(app, "pane-account-tree") }
            remote.press(.menu)
            pause(2)
            if index == 0 { shot("pane-0-after-pop") }
            press(.down)
            pause(0.8)
        }
    }

    func testDetailHeroMotion() {
        let app = launch(["-debug.openDeepLink", "nuviotv://title?id=tt15239678&type=movie&name=Dune"])
        pause(14)
        shot("motion-landing")
        press(.down)
        pause(2.5)
        shot("motion-down-from-hero")
        press(.up)
        pause(2.5)
        shot("motion-up-back-to-hero")
        press(.up)
        pause(1.5)
        shot("motion-teaser-focused")
        remote.press(.select)
        pause(2.5)
        shot("motion-synopsis-sheet")
        remote.press(.menu)
        pause(2)
        press(.down, times: 14, gap: 1.0)
        pause(2)
        shot("motion-bottom-about")
        tree(app, "motion-bottom-tree")
    }
}
