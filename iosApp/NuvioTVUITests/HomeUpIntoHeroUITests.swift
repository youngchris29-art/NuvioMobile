import XCTest

/// beta.18 verdict (BUG-112 residue): proves the Up-into-hero hook fires on the press path and
/// logs on every outcome. The success path used to be the only one that logged; now a decline
/// (`action=declined reason=...`) is visible too, so either line proves the gate ran. Helpers are
/// a trimmed copy of `HeroOffLaunchTests`' (private there, by this harness's duplication rule).
final class HomeUpIntoHeroUITests: XCTestCase {
    let remote = XCUIRemote.shared

    override func setUpWithError() throws { continueAfterFailure = true }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, gap: TimeInterval = 0.8) {
        for _ in 0..<times {
            remote.press(button)
            pause(gap)
        }
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

    func test74UpIntoHeroGateLogsOnEveryPath() throws {
        let app = launchToHome(extraArguments: ["-debug.homeScrollProbe", "YES"])
        pause(6)
        press(.down, times: 3)
        press(.up, times: 3)

        let fallback = app.staticTexts["debug_upfallback"]
        guard fallback.waitForExistence(timeout: 10) else {
            XCTFail("debug_upfallback probe missing — it is DEBUG-only (HomeView.swift); is this a Release build?")
            return
        }
        let deadline = Date().addingTimeInterval(1.0)
        var line = fallback.label
        // Any line stamped `src=press-any` proves the window-level Up press recognizer fired and
        // ran the gate; the fixture is hero-off, so a structural decline (`heroNotFocused`) is the
        // expected shape there. A reveal (`reason=upIntoHero`) or a gate decline also count.
        func proves(_ l: String) -> Bool {
            l.contains("src=press-any") || l.contains("reason=upIntoHero")
                || l.contains("action=declined reason=notPastTop")
        }
        while Date() < deadline, !proves(line) {
            pause(0.1)
            line = fallback.label
        }
        let attachment = XCTAttachment(string: line)
        attachment.name = "74_upfallback_line"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(proves(line),
                      "the Up-into-hero hook never logged on the press path. Full line: \(line)")
    }
}
