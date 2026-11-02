import XCTest

/// Aether Phase 1, W4: the Aether player (`player.aether`, forced with `-debug.mpvSmokeEngine aether`)
/// behind the shared chrome, driven through `XCUIRemote` like the mpv legs: bar and Info pill, seek,
/// pause card, chapters shelf, scan rate chip, and the fallback to mpv (`debug.mpvSmokeAetherBreak`
/// for a start failure, `debug.mpvSmokeAetherFailAtSec` for a mid-play failure with a carried position).
///
/// Fixtures come from `scripts/dev/aether-smoke-fixtures.sh` (written to `iosApp/build/smoke`, gitignored)
/// and are served over http by a range server (`scripts/device/range_server.py` in the outer repo):
///
///     scripts/dev/aether-smoke-fixtures.sh                     # once
///     (cd iosApp/build/smoke && python3 <outer>/scripts/device/range_server.py 8766 .)
///
/// Skipped unless `AETHER_SMOKE_URL` is in the environment (`TEST_RUNNER_AETHER_SMOKE_URL=http://127.0.0.1:8766/aether-long.mkv`).
/// The chapters leg also needs `TEST_RUNNER_AETHER_SMOKE_CHAPTERS_URL=http://127.0.0.1:8766/aether-chapters.mkv` and skips without it.
///
/// What the chrome exposes on Aether: the same `debug_seekProbe` / `debug_transportProbe` labels as mpv
/// (position, speed, mode, paused, bar visibility, chapter count), `player.aether` / `player.mpv` for the
/// engine in front, `player.pauseCard`, the Info shelf's "Engine" row ("Aether · …"). The scan rate chip is
/// read as `speed` and `mode` on the seek probe (it has no accessibility element of its own).
final class AetherPlayerUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    // MARK: Harness

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func probe(_ app: XCUIApplication, _ id: String) -> [String: String] {
        let el = app.descendants(matching: .any)[id]
        guard el.waitForExistence(timeout: 5) else { return [:] }
        var out: [String: String] = [:]
        for part in el.label.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func seekText(_ app: XCUIApplication) -> String { element(app, "debug_seekProbe").label }
    private func barText(_ app: XCUIApplication) -> String { element(app, "debug_transportProbe").label }
    private func seek(_ app: XCUIApplication) -> [String: String] { probe(app, "debug_seekProbe") }
    private func pos(_ app: XCUIApplication) -> Double { Double(seek(app)["pos"] ?? "") ?? -1 }
    private func barPos(_ app: XCUIApplication) -> Double { Double(probe(app, "debug_transportProbe")["pos"] ?? "") ?? -1 }

    private func waitSeek(_ app: XCUIApplication, timeout: TimeInterval = 5, _ cond: ([String: String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(seek(app)) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return cond(seek(app))
    }

    private func waitBar(_ app: XCUIApplication, timeout: TimeInterval = 8, _ cond: ([String: String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(probe(app, "debug_transportProbe")) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return cond(probe(app, "debug_transportProbe"))
    }

    /// Launches the Aether player on `fixture` (default: `AETHER_SMOKE_URL`), waits for the Aether
    /// controller and for playback to pass 1 s. Skips the leg when the env is unset.
    private func launchAether(url fixture: String? = nil, extra: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let base = try XCTUnwrap(env["AETHER_SMOKE_URL"], "AETHER_SMOKE_URL not set")
        let url = fixture ?? base
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-debug.mpvSmokeEngine", "aether",
                                "-debug.mpvSmokeStartOver", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.otherElements["player.aether"].waitForExistence(timeout: 30), "the Aether controller did not appear")
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "mpv is showing instead of Aether")
        XCTAssertTrue(waitSeek(app, timeout: 30) { (Double($0["pos"] ?? "") ?? 0) > 1 }, "Aether playback never started: \(seekText(app))")
        return app
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AETHER_SMOKE_URL"] != nil, "AETHER_SMOKE_URL not set")
    }

    // MARK: Legs

    /// Down from a hidden bar → the bar and the Info pill; Select opens the Info shelf and its Engine row
    /// names Aether (the Stream Info card).
    func testPlayShowsBarInfoPillAndStreamInfoNamesAether() throws {
        let app = try launchAether()
        XCTAssertTrue(waitBar(app, timeout: 12) { $0["vis"] == "0" }, "bar never hid: \(barText(app))")
        remote.press(.down)
        let info = element(app, "player.infoPill.info")
        XCTAssertTrue(info.waitForExistence(timeout: 6), "no Info pill after Down")
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, "bar not up after Down: \(barText(app))")
        remote.press(.select)
        let shelf = element(app, "player.shelf.info")
        XCTAssertTrue(shelf.waitForExistence(timeout: 6), "Info shelf did not open")
        Thread.sleep(forTimeInterval: 1.0)
        let aetherText = shelf.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Aether' OR value CONTAINS[c] 'Aether'")).firstMatch
        XCTAssertTrue(aetherText.waitForExistence(timeout: 4), "the Stream Info shelf never says Aether")
        print("[AetherLeg] stream info engine row: \(aetherText.label)")
        XCTAssertTrue(app.otherElements["player.aether"].exists, "no longer the Aether controller")
    }

    /// Right then Left: the playhead (seek probe and the bar's own position) moves forward then back.
    func testSeekRightAndLeftMoveThePosition() throws {
        let app = try launchAether()
        XCTAssertTrue(waitBar(app, timeout: 12) { $0["vis"] == "0" }, "bar never hid: \(barText(app))")
        let p0 = pos(app)
        remote.press(.right)
        XCTAssertTrue(waitSeek(app, timeout: 8) { (Double($0["pos"] ?? "") ?? 0) > p0 + 6 }, "Right did not move forward: p0=\(p0) \(seekText(app))")
        let p1 = pos(app)
        XCTAssertTrue(waitBar(app, timeout: 4) { (Double($0["pos"] ?? "") ?? 0) > p0 + 6 }, "the bar's position did not follow: \(barText(app))")
        remote.press(.left)
        XCTAssertTrue(waitSeek(app, timeout: 8) { (Double($0["pos"] ?? "") ?? 99_999) < p1 - 5 }, "Left did not move back: p1=\(p1) \(seekText(app))")
        print("[AetherLeg] seek: p0=\(p0) after Right=\(p1) after Left=\(pos(app))")
    }

    /// Play/Pause pauses (probe paused=1), the bar hides and the pause card shows; Play/Pause resumes and the
    /// card goes.
    func testPauseCardShowsAndResumes() throws {
        let app = try launchAether()
        XCTAssertTrue(waitBar(app, timeout: 12) { $0["vis"] == "0" }, "bar never hid: \(barText(app))")
        remote.press(.playPause)
        XCTAssertTrue(waitSeek(app, timeout: 4) { $0["paused"] == "1" }, "did not pause: \(seekText(app))")
        let card = element(app, "player.pauseCard")
        XCTAssertTrue(card.waitForExistence(timeout: 12), "no pause card after the bar hid: \(seekText(app)) | \(barText(app))")
        let held = pos(app)
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(pos(app), held, accuracy: 0.6, "position moved while paused")
        remote.press(.playPause)
        XCTAssertTrue(waitSeek(app, timeout: 4) { $0["paused"] == "0" }, "did not resume: \(seekText(app))")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 4), .completed, "pause card still up after resuming")
        XCTAssertTrue(waitSeek(app, timeout: 6) { (Double($0["pos"] ?? "") ?? 0) > held + 1 }, "playback did not advance after resuming: \(seekText(app))")
    }

    /// The chapters fixture: five chapters reach the bar; the Chapters pill's shelf lists them, ticks the current
    /// one, and a pick seeks to its start (Act Three at 240 s).
    func testChaptersShelfSeeksOnAether() throws {
        let env = ProcessInfo.processInfo.environment
        let url = env["AETHER_SMOKE_CHAPTERS_URL"]
        try XCTSkipIf(url == nil, "AETHER_SMOKE_CHAPTERS_URL not set: TEST_RUNNER_AETHER_SMOKE_CHAPTERS_URL=http://127.0.0.1:8766/aether-chapters.mkv")
        let app = try launchAether(url: url)
        XCTAssertTrue(waitBar(app, timeout: 12) { $0["chapters"] == "5" }, "five chapters never reached the bar: \(barText(app))")
        XCTAssertTrue(waitBar(app, timeout: 12) { $0["vis"] == "0" }, "bar never hid: \(barText(app))")
        let c0 = Int(seek(app)["commits"] ?? "") ?? -1
        let shelf = PlayerChrome.openShelf(app, "chapters")
        let current = element(app, "player.panel.chapter.0")
        XCTAssertTrue(current.waitForExistence(timeout: 3), "no chapter row 0")
        XCTAssertTrue(current.label.contains("Act One"), current.label)
        XCTAssertEqual(current.value as? String, "selected", "the current chapter (Act One) is not ticked")
        let row = element(app, "player.panel.chapter.2")
        XCTAssertTrue(row.waitForExistence(timeout: 3), "no chapter row 2")
        XCTAssertTrue(row.label.contains("Act Three"), row.label)
        XCTAssertTrue(PlayerChrome.focusWalk(app, to: row), "focus never reached chapter row 2")
        remote.press(.select)
        XCTAssertTrue(waitSeek(app, timeout: 6) {
            Int($0["commits"] ?? "") == c0 + 1 && $0["lastTarget"] == "240"
        }, "chapter seek not recorded: \(seekText(app))")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: shelf)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "shelf did not close after the pick")
        XCTAssertTrue(waitSeek(app, timeout: 12) { (Double($0["pos"] ?? "") ?? 0) >= 239 }, "never landed at 240: \(seekText(app))")
        print("[AetherLeg] chapter seek: \(seekText(app)) | \(barText(app))")
    }

    /// Scan mode: a Right hold latches 2x (rate chip: speed 2.0, mode scanning), Right steps 3x then 4x, the
    /// playhead runs ahead, Select ends it and the speed returns to 1x.
    func testScanRateChipCyclesTwoThreeFour() throws {
        let app = try launchAether(extra: ["-player.holdMode", "scan"])
        let origin = pos(app)
        remote.press(.right, forDuration: 1.0)
        XCTAssertTrue(waitSeek(app, timeout: 5) { $0["speed"] == "2.0" && $0["mode"] == "scanning" }, "2x never latched: \(seekText(app))")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(seek(app)["speed"], "2.0", "scan must stay latched after release: \(seekText(app))")
        remote.press(.right)
        XCTAssertTrue(waitSeek(app, timeout: 4) { $0["speed"] == "3.0" }, "3x not reached: \(seekText(app))")
        remote.press(.right)
        XCTAssertTrue(waitSeek(app, timeout: 4) { $0["speed"] == "4.0" }, "4x not reached: \(seekText(app))")
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertGreaterThan(pos(app), origin + 6, "the playhead did not run ahead during the scan: \(seekText(app))")
        remote.press(.select)
        XCTAssertTrue(waitSeek(app, timeout: 5) { $0["speed"] == "1.0" && $0["mode"] == "idle" && $0["paused"] == "0" },
                      "Select did not end the scan: \(seekText(app))")
        XCTAssertTrue(app.otherElements["player.aether"].exists, "no longer the Aether controller after the scan")
    }

    /// `debug.mpvSmokeAetherBreak`: Aether opens a missing file, the policy answers fall back, and mpv plays the
    /// real URL (`player.mpv` replaces `player.aether`).
    func testStartFailureFallsBackToMpv() throws {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["AETHER_SMOKE_URL"])
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-debug.mpvSmokeEngine", "aether",
                                "-debug.mpvSmokeStartOver", "YES", "-debug.mpvSmokeAetherBreak", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 60), "mpv never took over from the failed Aether start")
        XCTAssertFalse(app.otherElements["player.aether"].exists, "the Aether controller is still showing after the handoff")
        XCTAssertTrue(waitSeek(app, timeout: 40) { (Double($0["pos"] ?? "") ?? 0) > 1 }, "mpv never started playing after the fallback: \(seekText(app))")
        // The Info shelf's Engine row no longer says "Aether" as the engine in front: it carries the fallback note.
        print("[AetherLeg] start failure fallback: \(seekText(app))")
    }

    /// `debug.mpvSmokeAetherFailAtSec 20`: a software-pipeline failure after 20 s of playback hands off to mpv at
    /// the carried position (`[Failover] mpv resumes at the engine handoff position`), not at 0 and not at the
    /// saved progress. The first position mpv reports is within a few seconds of 20 (the handoff itself is at
    /// 20.0 to 20.9 s; the allowance covers mpv's load time).
    func testMidPlayFailureCarriesThePositionToMpv() throws {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["AETHER_SMOKE_URL"])
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-debug.mpvSmokeEngine", "aether",
                                "-debug.mpvSmokeStartOver", "YES", "-debug.mpvSmokeAetherFailAtSec", "<real>20</real>"]
        app.launch()
        XCTAssertTrue(app.otherElements["player.aether"].waitForExistence(timeout: 30), "the Aether controller did not appear")
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 90), "mpv never took over after the injected failure")
        XCTAssertFalse(app.otherElements["player.aether"].exists, "the Aether controller is still showing after the handoff")
        // First reading of mpv's playhead: must be at the carried position, not a restart.
        var first = -1.0
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            let p = pos(app)
            if p > 1 { first = p; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertGreaterThan(first, 17.5, "mpv resumed before the carried position (a restart reads near 0): first pos=\(first)")
        XCTAssertLessThan(first, 26.0, "mpv resumed far past the failure point 20 s: first pos=\(first)")
        print("[AetherLeg] mid-play failure: mpv first pos=\(first) \(seekText(app))")
    }
}
