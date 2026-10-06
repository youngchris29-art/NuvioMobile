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
    /// (`pressesCancelled` .menu right after `pressesBegan` consumed it; the cancel itself runs:
    /// the mode goes idle before the exit), so the leg is recorded as an expected failure there.
    /// Device pass item: scan, Menu, the playhead returns and the controls stay up.
    func testScanMenuCancelsBackToOrigin() throws {
        let app = try launch(extra: ["-player.holdMode", "scan"])
        XCTExpectFailure("simulator Menu dismisses the cover after the press was consumed", strict: false)
        let origin = pos(app)
        remote.press(.right, forDuration: 1.0)
        XCTAssertTrue(waitFor(app) { $0["mode"] == "scanning" }, probeText(app))
        Thread.sleep(forTimeInterval: 2.0)
        remote.press(.menu)
        XCTAssertTrue(waitFor(app) { $0["mode"] == "idle" && $0["speed"] == "1.0" }, probeText(app))
        Thread.sleep(forTimeInterval: 2.0)
        let p = probe(app)
        let after = Double(p["pos"] ?? "") ?? -1
        XCTAssertEqual(after, origin, accuracy: 3.0, probeText(app))
        XCTAssertTrue(app.otherElements["player.mpv"].exists, "Menu during a scan must not exit the player")
    }
}
