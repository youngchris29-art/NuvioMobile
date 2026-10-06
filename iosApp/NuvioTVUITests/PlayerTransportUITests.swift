import XCTest

/// mpv transport legs (P1 preview-then-commit seek, scan). Run against a long (>= 10 min) file on
/// the mpv smoke rig. Skipped unless `PLAYER_BAR_PROBE=1` and `PLAYER_SMOKE_URL` are in the
/// environment (pass them as `TEST_RUNNER_PLAYER_BAR_PROBE=1` / `TEST_RUNNER_PLAYER_SMOKE_URL=...`).
/// Reads the DEBUG `debug_seekProbe` label (`Screens/Player/SeekProbe.swift`).
final class PlayerTransportUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    // MARK: Harness

    private func launch(extra: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_BAR_PROBE"] == "1")
        let url = try XCTUnwrap(env["PLAYER_SMOKE_URL"], "PLAYER_SMOKE_URL not set")
        let app = XCUIApplication()
        // 8 MiB forward cache keeps a long hold's target outside the cached range, so the
        // keyframes stage is exercised (the default cache swallows the whole smoke file).
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "NO",
                                "-player.bufferMB", "8"] + extra
        app.launch()
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 30), "player did not appear")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if probe(app)["pos"].flatMap(Double.init).map({ $0 > 1 }) == true { return app }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("playback never started (pos <= 1)")
        return app
    }

    private func probeText(_ app: XCUIApplication) -> String {
        let el = app.descendants(matching: .any)["debug_seekProbe"]
        guard el.waitForExistence(timeout: 5) else { return "" }
        return el.label
    }

    private func probe(_ app: XCUIApplication) -> [String: String] {
        var out: [String: String] = [:]
        for part in probeText(app).split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func pos(_ app: XCUIApplication) -> Double { Double(probe(app)["pos"] ?? "") ?? -1 }

    private func waitFor(_ app: XCUIApplication, timeout: TimeInterval = 4, _ cond: ([String: String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(probe(app)) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return cond(probe(app))
    }

    // MARK: Legs

    func testHoldStepCommitsOnce() throws {
        let app = try launch()
        let origin = pos(app)
        remote.press(.right, forDuration: 2.0)
        Thread.sleep(forTimeInterval: 2.0)
        let p = probe(app)
        XCTAssertEqual(p["commits"], "1", probeText(app))
        XCTAssertTrue(["ke", "e"].contains(p["stages"] ?? ""), probeText(app))
        let target = Double(p["lastTarget"] ?? "") ?? -1
        // 6, 7 or 8 ticks depending on release jitter: +140 / +170 / +230 from the press origin
        // (origin is read up to one poll earlier, hence the slack).
        XCTAssertGreaterThanOrEqual(target, origin + 140 - 4, probeText(app))
        XCTAssertLessThanOrEqual(target, origin + 230 + 4, probeText(app))
        remote.press(.right)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(probe(app)["commits"], "1", "a short press must be a relative seek, not a commit")
    }

    func testExactStageCancelledByNewPress() throws {
        let app = try launch()
        remote.press(.right, forDuration: 1.5)
        remote.press(.right)    // within the exact stage's 150 ms window
        Thread.sleep(forTimeInterval: 2.0)
        var p = probe(app)
        XCTAssertEqual(p["stages"], "k", "exact stage should have been cancelled: \(probeText(app))")
        XCTAssertEqual(p["commits"], "1", probeText(app))
        remote.press(.right, forDuration: 1.5)
        Thread.sleep(forTimeInterval: 2.0)
        p = probe(app)
        XCTAssertEqual(p["commits"], "2", probeText(app))
    }

    func testScanLatchesAndCycles() throws {
        let app = try launch(extra: ["-player.holdMode", "scan"])
        remote.press(.right, forDuration: 1.0)
        XCTAssertTrue(waitFor(app) { $0["speed"] == "2.0" && $0["mode"] == "scanning" }, probeText(app))
        Thread.sleep(forTimeInterval: 1.0)
        var p = probe(app)
        XCTAssertEqual(p["speed"], "2.0", "scan must latch after release: \(probeText(app))")
        XCTAssertEqual(p["mode"], "scanning", probeText(app))
        remote.press(.right)
        XCTAssertTrue(waitFor(app) { $0["speed"] == "3.0" }, probeText(app))
        remote.press(.right)
        XCTAssertTrue(waitFor(app) { $0["speed"] == "4.0" }, probeText(app))
        remote.press(.select)
        XCTAssertTrue(waitFor(app) { $0["speed"] == "1.0" && $0["mode"] == "idle" && $0["paused"] == "0" }, probeText(app))
    }

    /// Menu during a scan cancels back to where the scan started and keeps the player open. On the
    /// simulator the XCUIRemote Menu press is followed by the system dismissing the cover anyway
    /// (a consumed Menu is still cancelled and acted on above the player there; device-pass item:
    /// scan, Menu, the playhead returns and the controls stay up). Only the "player still
    /// presented" assertion is an expected failure; when the cover is gone the dependent reads are
    /// skipped, never passed. Menu precedence itself is unit-tested (`PlayerRemoteRulesTests`).
    func testScanMenuCancelsBackToOrigin() throws {
        let app = try launch(extra: ["-player.holdMode", "scan"])
        let origin = pos(app)
        remote.press(.right, forDuration: 1.0)
        XCTAssertTrue(waitFor(app) { $0["mode"] == "scanning" }, probeText(app))
        Thread.sleep(forTimeInterval: 2.0)
        remote.press(.menu)
        try requirePlayerStillPresented(app, "Menu during a scan must not exit the player")
        XCTAssertTrue(waitFor(app) { $0["mode"] == "idle" && $0["speed"] == "1.0" }, probeText(app))
        Thread.sleep(forTimeInterval: 2.0)
        let p = probe(app)
        let after = Double(p["pos"] ?? "") ?? -1
        XCTAssertEqual(after, origin, accuracy: 3.0, probeText(app))
    }

    /// The one simulator-only expected failure of the Menu legs; a dismissed cover skips the rest.
    private func requirePlayerStillPresented(_ app: XCUIApplication, _ message: String) throws {
        Thread.sleep(forTimeInterval: 1.0)          // the simulator dismisses ~0.6 s after the press
        let presented = app.otherElements["player.mpv"].exists
        XCTExpectFailure("simulator Menu dismisses the cover after the press was consumed", strict: false) {
            XCTAssertTrue(presented, message)
        }
        if !presented {
            throw XCTSkip("cover dismissed by the simulator after Menu; the remaining checks are device-pass items")
        }
    }

    // MARK: Transport bar (P1-B), reads `debug_transportProbe`

    private func barProbeText(_ app: XCUIApplication) -> String {
        let el = app.descendants(matching: .any)["debug_transportProbe"]
        guard el.waitForExistence(timeout: 5) else { return "" }
        return el.label
    }

    private func bar(_ app: XCUIApplication) -> [String: String] {
        var out: [String: String] = [:]
        for part in barProbeText(app).split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func waitBar(_ app: XCUIApplication, timeout: TimeInterval = 5, _ cond: ([String: String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(bar(app)) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return cond(bar(app))
    }

    /// The bar is up for the first 4 s of playback: let it hide so an Up press starts from a known state.
    private func launchWithBarHidden(extra: [String] = []) throws -> XCUIApplication {
        let app = try launch(extra: extra)
        XCTAssertTrue(waitBar(app, timeout: 10) { $0["vis"] == "0" }, "bar never hid: \(barProbeText(app))")
        return app
    }

    func testBarGeometryProbe() throws {
        let app = try launchWithBarHidden()
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" && abs((Double($0["y"] ?? "") ?? 0) - 95) <= 2 }, barProbeText(app))
        let p = bar(app)
        XCTAssertEqual(Double(p["y"] ?? "") ?? 0, 95, accuracy: 2, barProbeText(app))
        XCTAssertEqual(Double(p["x0"] ?? "") ?? 0, 86, accuracy: 1, barProbeText(app))
        XCTAssertEqual(Double(p["x1"] ?? "") ?? 0, 1834, accuracy: 1, barProbeText(app))
        XCTAssertGreaterThanOrEqual(Int(p["pills"] ?? "") ?? 0, 4, barProbeText(app))
        XCTAssertEqual(p["focus"], "track", barProbeText(app))
        print("[BarProbe] geometry: \(barProbeText(app))")
    }

    func testPillFocusWalk() throws {
        let app = try launchWithBarHidden()
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" && $0["focus"] == "track" }, barProbeText(app))
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["focus"] == "pill:subtitles" }, barProbeText(app))
        remote.press(.right)
        XCTAssertTrue(waitBar(app) { $0["focus"] == "pill:audio" }, barProbeText(app))
        remote.press(.down)
        XCTAssertTrue(waitBar(app) { $0["focus"] == "track" }, barProbeText(app))
        // Left seeks again once the focus is back on the track.
        let before = Double(bar(app)["pos"] ?? "") ?? -1
        remote.press(.left)
        XCTAssertTrue(waitBar(app, timeout: 6) { (Double($0["pos"] ?? "") ?? 9999) < before - 3 }, "Left did not seek: \(barProbeText(app))")
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["focus"] == "pill:subtitles" }, barProbeText(app))
        remote.press(.select)
        let tab = app.descendants(matching: .any)["player.panel.tab.subtitles"]
        XCTAssertTrue(tab.waitForExistence(timeout: 6), "subtitles tab did not open")
        XCTAssertEqual(tab.value as? String, "selected")
        print("[BarProbe] pillwalk end: \(barProbeText(app))")
    }

    func testLightTapFlipsEndTime() throws {
        let app = try launchWithBarHidden()
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, barProbeText(app))
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("com.nuvio.debug.transport.lightTap" as CFString), nil, nil, true)
        XCTAssertTrue(waitBar(app) { $0["ends"] == "1" }, barProbeText(app))
        let remaining = app.descendants(matching: .any)["player.bar.time.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 3))
        XCTAssertTrue(remaining.label.hasPrefix("ends"), remaining.label)
        Thread.sleep(forTimeInterval: 4.5)
        XCTAssertEqual(bar(app)["ends"], "0", barProbeText(app))
        print("[BarProbe] endtime end: \(barProbeText(app)) label=\(remaining.label)")
    }

    func testBarHideRules() throws {
        let app = try launchWithBarHidden()
        // Playing: up, then no input -> hidden by ~4 s.
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, barProbeText(app))
        let t0 = Date()
        XCTAssertTrue(waitBar(app, timeout: 6.5) { $0["vis"] == "0" }, barProbeText(app))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5.6, "bar took too long to hide while playing")
        // Paused (pause card on by default): bar up at 4.5 s, hidden by ~6 s.
        remote.press(.select)
        let t1 = Date()
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, barProbeText(app))
        // Probe reads are slow, so only the lower bound is meaningful: not hidden before ~4.5 s.
        XCTAssertTrue(waitBar(app, timeout: 9) { $0["vis"] == "0" }, "paused bar never hid: \(barProbeText(app))")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t1), 4.5, "paused bar hid early (card on: 5 s)")
        // A focused pill pins the bar.
        remote.press(.up)
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["focus"] == "pill:subtitles" }, barProbeText(app))
        Thread.sleep(forTimeInterval: 6.0)
        XCTAssertEqual(bar(app)["vis"], "1", "bar hid with a pill focused: \(barProbeText(app))")
        print("[BarProbe] hide end: \(barProbeText(app))")
    }

    /// Menu hides the bar first, a second Menu exits. On the simulator a consumed Menu press still
    /// dismisses the cover, so "player still presented" is the leg's one expected failure there and
    /// the rest is skipped (`requirePlayerStillPresented`). Device check: Up, Menu (bar hides, video
    /// stays), Menu (exits).
    func testMenuHidesBarThenExits() throws {
        let app = try launchWithBarHidden()
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, barProbeText(app))
        remote.press(.menu)
        try requirePlayerStillPresented(app, "first Menu must hide the bar, not exit")
        XCTAssertTrue(waitBar(app) { $0["vis"] == "0" }, "Menu did not hide the bar: \(barProbeText(app))")
        remote.press(.menu)
        let gone = NSPredicate(format: "exists == false")
        let exp = XCTNSPredicateExpectation(predicate: gone, object: app.otherElements["player.mpv"])
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: 6), .completed, "second Menu did not exit")
    }

    // MARK: Skip chip (P1-C)

    /// The chip hides 10 s after it appears and comes back on any remote press (mpv player).
    func testSkipChipAutoHides() throws {
        let app = try launch(extra: ["-debug.mpvSmokeSkipInterval", "0,100000,op"])
        XCTAssertTrue(waitFor(app, timeout: 20) { $0["chip"] == "1" }, "chip never appeared: \(probeText(app))")
        Thread.sleep(forTimeInterval: 11.0)
        XCTAssertTrue(waitFor(app, timeout: 3) { $0["chip"] == "0" }, "chip did not auto-hide: \(probeText(app))")
        remote.press(.left)
        XCTAssertTrue(waitFor(app, timeout: 4) { $0["chip"] == "1" }, "a press did not bring the chip back: \(probeText(app))")
        print("[SeekProbe] chip leg end: \(probeText(app))")
    }
}
