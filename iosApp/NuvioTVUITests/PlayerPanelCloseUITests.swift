import XCTest

/// BUG-186 successor legs on the mpv smoke rig. The swipe-down top panel is gone; the same hazard
/// now lives in the popovers (`player.popover.<disc>`) and the pill shelves (`player.shelf.<pill>`):
/// a Menu that lands while one is still being presented used to latch the host's `closing` flag with
/// the surface left on screen, so every later Menu was swallowed and the player could not be left.
/// In both legs the popover or shelf must be gone within 2 s, the player must still be on screen
/// (Menu inside an overlay never exits), and the Menu ladder (bar hides, then exit) must still work
/// afterwards. Skipped unless `PLAYER_BAR_PROBE=1` and `PLAYER_SMOKE_URL` are in the environment
/// (pass them as `TEST_RUNNER_*`).
final class PlayerPanelCloseUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    private func launch(extra: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_BAR_PROBE"] == "1", "PLAYER_BAR_PROBE not set")
        let url = try XCTUnwrap(env["PLAYER_SMOKE_URL"], "PLAYER_SMOKE_URL not set")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "NO",
                                "-debug.mpvSmokeStartOver", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 30), "player did not appear")
        let seek = app.descendants(matching: .any)["debug_seekProbe"]
        XCTAssertTrue(seek.waitForExistence(timeout: 30), "no seek probe")
        let started = Date().addingTimeInterval(30)
        while Date() < started, Self.pos(seek.label) <= 1 { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertGreaterThan(Self.pos(seek.label), 1, "playback never started: \(seek.label)")
        return app
    }

    private static func pos(_ label: String) -> Double {
        for part in label.split(separator: " ") where part.hasPrefix("pos=") {
            return Double(part.dropFirst(4)) ?? 0
        }
        return 0
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: element)],
                                timeout: timeout) == .completed
    }

    /// The overlay is gone within 2 s, the player is still presented, and the Menu ladder still
    /// exits it (a visible bar takes one Menu to hide first; the swallowed-Menu bug ignores both).
    private func assertClosesThenExits(_ app: XCUIApplication, overlay: XCUIElement, _ leg: String) {
        XCTAssertTrue(waitGone(overlay, timeout: 2), "\(leg): overlay still up 2 s after the close")
        let player = app.otherElements["player.mpv"]
        Thread.sleep(forTimeInterval: 1.0)   // the simulator dismisses a cover ~0.6 s after a consumed Menu
        XCTAssertTrue(player.exists, "\(leg): Menu inside the overlay left the player")
        guard player.exists else { return }
        remote.press(.menu)
        if waitGone(player, timeout: 3) { return }
        remote.press(.menu)
        XCTAssertTrue(waitGone(player, timeout: 4), "\(leg): Menu after the close did not exit the player")
    }

    /// Menu straight after the Select that opens a popover (inside its ~0.2 s present).
    func testMenuDuringPopoverPresent() throws {
        let app = try launch()
        Thread.sleep(forTimeInterval: 4)   // let the start-of-playback bar hide
        remote.press(.up)                  // bar up, track focused
        remote.press(.up)                  // disc row (Subtitles first)
        remote.press(.select)
        let pressedAt = Date()
        remote.press(.menu)
        print("[BUG186Leg] Menu \(Int(Date().timeIntervalSince(pressedAt) * 1000)) ms after Select returned")
        // The popover may or may not have been drawn before the close; either way it must not stay.
        let popover = app.descendants(matching: .any)["player.popover.subtitles"]
        _ = popover.waitForExistence(timeout: 0.5)
        assertClosesThenExits(app, overlay: popover, "menu-during-popover-present")
    }

    /// Menu straight after the Select that opens the Info shelf, from a hidden bar via Down.
    func testMenuDuringShelfPresent() throws {
        let app = try launch()
        Thread.sleep(forTimeInterval: 4)
        remote.press(.down)                // bar up, Info pill focused
        remote.press(.select)
        remote.press(.menu)
        let shelf = app.descendants(matching: .any)["player.shelf.info"]
        _ = shelf.waitForExistence(timeout: 0.5)
        assertClosesThenExits(app, overlay: shelf, "menu-during-shelf-present")
    }
}
