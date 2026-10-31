import XCTest

/// BUG-153 (Home half), evidence leg: how the first Down from the hero compares with the next
/// presses on Home, Stage and Classic. The test only presses; the numbers come from the app's own
/// probe lines (`[StageStrip] seg/PRESS` on Stage, `[HomeScrollProbe]` per-frame offsets on Classic)
/// read from the simulator's unified log while it runs, so the leg asserts nothing but "it pressed".
/// Each press line is printed with a wall-clock stamp (`[HomeFirstPress] PRESS n @ <epoch ms>`) so
/// the log lines can be grouped per press.
///
/// Gated like the other evidence legs: set `NUVIO_HOME_FIRST_PRESS=1` (`TEST_RUNNER_` prefix for
/// xcodebuild). Helpers are this file's own (the harness rule).
final class HomeFirstPressEvidenceUITests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NUVIO_HOME_FIRST_PRESS"] == "1",
                          "evidence leg: set NUVIO_HOME_FIRST_PRESS=1 to run")
        continueAfterFailure = true
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func epochMs() -> Int { Int((Date().timeIntervalSince1970 * 1000).rounded()) }

    private func note(_ text: String) {
        print("[HomeFirstPress] \(text)")
    }

    @discardableResult
    private func launch(_ arguments: [String], settle: TimeInterval = 16) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the FA87 fixture set up?")
        if chris.exists {
            DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
        }
        pause(settle)
        return app
    }

    /// Presses Down `count` times, `gap` seconds apart (past every glide and the verify), stamping each.
    private func walk(count: Int, gap: TimeInterval = 3.0) {
        for index in 1...count {
            note("PRESS \(index) @ \(epochMs())")
            remote.press(.down)
            pause(gap)
        }
        note("END @ \(epochMs())")
    }

    /// Stage, Rail chrome (focus lands on row 0's first card, so press 1 is row 0 → row 1).
    func testStageWalk() throws {
        let app = launch(["-home_layout", "stage", "-debug.homeScrollProbe", "YES", "-home_upcoming_row_enabled", "NO",
                          "-sidebar_style", "rail", "-debug.stripFitRows", "NO", "-inline_trailers_enabled", "NO"])
        _ = app
        walk(count: 5)
    }

    /// Classic, Tabs chrome: the launch lands on the tab bar, so a Down press enters the hero and the
    /// next one is the hero exit into row 1. `enter` extra presses first.
    func testClassicWalk() throws {
        let app = launch(["-home_layout", "classic", "-debug.homeScrollProbe", "YES", "-home_upcoming_row_enabled", "NO",
                          "-sidebar_style", "tabs", "-inline_trailers_enabled", "NO"])
        _ = app
        walk(count: 6)
    }
}
