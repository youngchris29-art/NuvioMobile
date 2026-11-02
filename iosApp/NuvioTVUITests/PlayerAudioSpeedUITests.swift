import XCTest

/// P5 Wave 1 (B20 audio effects, B23 per-show speed) legs on the mpv route, driven through the
/// Audio and Speed discs' popovers (`player.popover.audio` / `player.popover.speed`; the swipe-down
/// top panel is gone). Gated on `PLAYER_BAR_PROBE=1` plus `PLAYER_SMOKE_URL` (pass as
/// `TEST_RUNNER_*`), like the P1/P4 harness legs. The native route has no Boost/Dialogue rows and
/// its Audio and Speed are system pills the simulator cannot open: that contrast is a device-pass
/// item (the old `testNativeAudioTabHasNoEffects` went with the panel). Remember Speed on native is
/// a round transport button, covered by `NativePlayerChromeTests`.
class PlayerAudioSpeedUITests: XCTestCase {
    let remote = XCUIRemote.shared

    // MARK: Harness

    private func launch(extra: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_BAR_PROBE"] == "1", "PLAYER_BAR_PROBE not set")
        let url = try XCTUnwrap(env["PLAYER_SMOKE_URL"], "PLAYER_SMOKE_URL not set")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "NO",
                                "-player.bufferMB", "8", "-debug.mpvSmokeStartOver", "YES"]
        app.launchArguments += extra
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

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// Opens the disc's popover (`audio` / `speed`) from a hidden bar.
    private func openPopover(_ app: XCUIApplication, _ disc: String) {
        PlayerChrome.openDisc(app, disc)
    }

    /// Down/Up/Left/Right toward `target` until it has focus.
    @discardableResult
    private func focusWalk(_ app: XCUIApplication, to target: XCUIElement, maxSteps: Int = 30) -> Bool {
        for _ in 0..<maxSteps {
            if target.hasFocus { return true }
            let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
            guard focused.exists else { remote.press(.down); Thread.sleep(forTimeInterval: 0.4); continue }
            let f = focused.frame, t = target.frame
            if f.midY < t.minY - 4 { remote.press(.down) }
            else if f.midY > t.maxY + 4 { remote.press(.up) }
            else if f.midX < t.midX { remote.press(.right) }
            else { remote.press(.left) }
            Thread.sleep(forTimeInterval: 0.45)
        }
        return target.hasFocus
    }

    private func press(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "no \(id)")
        XCTAssertTrue(focusWalk(app, to: target), "focus never reached \(id)")
        remote.press(.select)
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func waitValue(_ el: XCUIElement, _ expected: String, timeout: TimeInterval = 4) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (el.value as? String) == expected || el.label == expected { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return (el.value as? String) == expected || el.label == expected
    }

    // MARK: Legs

    func testMpvAudioEffectsRows() throws {
        let app = try launch()
        openPopover(app, "audio")
        let boost = element(app, "player.panel.audioFx.boost.value")
        XCTAssertTrue(boost.waitForExistence(timeout: 5), "no Boost value")
        XCTAssertTrue(waitValue(boost, "Off"), "Boost not Off: \(boost.label)")
        press(app, "player.panel.audioFx.boost.plus")
        XCTAssertTrue(waitValue(boost, "+2 dB"), "Boost not +2 dB: \(boost.label)")
        press(app, "player.panel.audioFx.boost.reset")
        XCTAssertTrue(waitValue(boost, "Off"), "Boost not reset: \(boost.label)")
        let dialogue = element(app, "player.panel.audioFx.mode.dialogue")
        press(app, "player.panel.audioFx.mode.dialogue")
        XCTAssertEqual(dialogue.value as? String, "selected", "Dialogue not selected")
        press(app, "player.panel.audioFx.mode.off")
        XCTAssertEqual(element(app, "player.panel.audioFx.mode.off").value as? String, "selected", "Off not restored")
    }

    func testSpeedMemoryMpv() throws {
        let series = ["-debug.mpvSmokeSeries", "YES"]
        var app = try launch(extra: series)
        openPopover(app, "speed")
        press(app, "player.panel.speed.1.25")
        XCTAssertEqual(element(app, "player.panel.speed.1.25").value as? String, "selected")
        press(app, "player.panel.speed.remember")
        XCTAssertEqual(element(app, "player.panel.speed.remember").value as? String, "on", "Remember not on")
        app.terminate()

        app = try launch(extra: series)
        openPopover(app, "speed")
        let speed = element(app, "player.panel.speed.1.25")
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        XCTAssertTrue(waitValue(speed, "selected"), "1.25x not restored")
        // End state clean: forget the show's speed and put the rate back.
        press(app, "player.panel.speed.remember")
        XCTAssertEqual(element(app, "player.panel.speed.remember").value as? String, "off", "Remember not off")
        press(app, "player.panel.speed.1.0")
    }

    func testSpeedMemoryHiddenForMovies() throws {
        let app = try launch()
        openPopover(app, "speed")
        XCTAssertTrue(element(app, "player.panel.speed.1.0").waitForExistence(timeout: 5), "no speed row")
        XCTAssertFalse(element(app, "player.panel.speed.remember").exists, "Remember row shown for a movie")
    }
}
