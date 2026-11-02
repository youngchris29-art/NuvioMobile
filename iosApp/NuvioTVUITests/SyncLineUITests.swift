import XCTest

/// Sync Line (P5 B19) legs on the mpv route, driven through the Subtitles disc's popover
/// (`player.popover.subtitles`; the swipe-down top panel is gone). Skipped unless `PLAYER_BAR_PROBE=1`.
/// `PLAYER_SMOKE_URL` is the smoke video; `PLAYER_SMOKE_SUB_URL` an SRT beside it (cues every 2 s
/// over the first 10 minutes, kept in the gitignored `iosApp/build/smoke`). Pass both as
/// `TEST_RUNNER_*`. The tvOS 27 sim reports `hasFocus` only on some controls, so legs assert
/// existence and values and walk focus geometrically (`PlayerChrome.focusWalk`).
///
/// The native route's Sync Line is a `transportBarCustomMenuItems` action that presents a full-screen
/// sheet after the system popover dismisses; the simulator cannot drive that popover, so it is a
/// device-pass item (the old `testNativeSyncLineSetsDelay` was removed with the panel).
final class SyncLineUITests: XCTestCase {
    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func pause(_ s: TimeInterval) { Thread.sleep(forTimeInterval: s) }

    private func launch(withSubtitle: Bool) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_BAR_PROBE"] == "1", "PLAYER_BAR_PROBE not set")
        let url = try XCTUnwrap(env["PLAYER_SMOKE_URL"], "PLAYER_SMOKE_URL not set")
        let app = XCUIApplication()
        var args = ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "NO",
                    "-player.bufferMB", "8", "-debug.mpvSmokeStartOver", "YES"]
        if withSubtitle {
            let sub = try XCTUnwrap(env["PLAYER_SMOKE_SUB_URL"], "PLAYER_SMOKE_SUB_URL not set")
            args += ["-debug.mpvSmokeSubtitleURL", sub]
        }
        app.launchArguments += args
        app.launch()
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 40), "player did not appear")
        awaitPlaybackStarted(app)
        return app
    }

    /// Same start gates as `NativePlayerParityUITests`: `debug_seekProbe` pos > 1 and the transport
    /// bar hidden (`debug_transportProbe` vis=0), so the first Up starts from a known state.
    private func awaitPlaybackStarted(_ app: XCUIApplication) {
        let parse = NativePlayerParityUITests.parse
        let seek = app.descendants(matching: .any)["debug_seekProbe"]
        XCTAssertTrue(seek.waitForExistence(timeout: 30), "no seek probe")
        var end = Date().addingTimeInterval(30)
        while Date() < end, (Double(parse(seek.label)["pos"] ?? "") ?? 0) <= 1 { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertGreaterThan(Double(parse(seek.label)["pos"] ?? "") ?? 0, 1, "playback never started: \(seek.label)")
        let bar = app.descendants(matching: .any)["debug_transportProbe"]
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "no transport probe")
        end = Date().addingTimeInterval(20)
        while Date() < end, parse(bar.label)["vis"] != "0" { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertEqual(parse(bar.label)["vis"], "0", "bar never hid: \(bar.label)")
    }

    /// Pick the "Smoke EN" row, then walk focus to the Sync Line button.
    private func selectSmokeSubtitleAndReachSyncLine(_ app: XCUIApplication) {
        let smoke = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Smoke EN'")).firstMatch
        XCTAssertTrue(smoke.waitForExistence(timeout: 20), "no Smoke EN subtitle row")
        XCTAssertTrue(PlayerChrome.focusWalk(app, to: smoke), "focus never reached the Smoke EN row")
        remote.press(.select)
        pause(1.5)
        XCTAssertEqual(smoke.value as? String, "selected", "Smoke EN not selected")
        pause(2)
        let row = element(app, "player.panel.syncLine")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Sync Line row with an external subtitle selected")
        XCTAssertTrue(PlayerChrome.focusWalk(app, to: row), "focus never reached the Sync Line button")
    }

    func testMpvSyncLineSetsDelay() throws {
        let app = try launch(withSubtitle: true)
        PlayerChrome.openDisc(app, "subtitles")
        selectSmokeSubtitleAndReachSyncLine(app)
        remote.press(.select)
        let cue0 = element(app, "player.panel.syncLine.cue.0")
        XCTAssertTrue(cue0.waitForExistence(timeout: 12), "cue list never appeared")
        pause(1)   // focus moves to the anchor cue 0.35 s after the list fills
        remote.press(.select)   // the anchor cue holds focus after 0.35 s
        pause(2)
        let value = element(app, "player.panel.subtitleDelay.value")
        XCTAssertTrue(value.waitForExistence(timeout: 5), "no delay value after picking a cue")
        XCTAssertNotEqual(value.label, "+0.00 s", "Sync Line left the delay at zero")
        // Reset so the profile stays clean.
        let reset = element(app, "player.panel.subtitleDelay.reset")
        if reset.exists, PlayerChrome.focusWalk(app, to: reset) {
            remote.press(.select)
        }
    }

    func testSyncLineHiddenWithoutExternalSubtitle() throws {
        let app = try launch(withSubtitle: false)
        PlayerChrome.openDisc(app, "subtitles")
        XCTAssertTrue(element(app, "player.panel.subtitleDelay.value").waitForExistence(timeout: 5), "no Timing row")
        XCTAssertFalse(element(app, "player.panel.syncLine").exists, "Sync Line shown without an external subtitle")
    }
}
