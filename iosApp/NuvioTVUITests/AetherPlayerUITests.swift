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

    // MARK: Seek preview on skips (GitHub #33): the bar probe's cap= / card= / cardw= / hcard=

    /// A 2 s Right hold shows a still card from video Aether already loaded. Skips when the session
    /// reports no still support on this runtime (probe `cap=0`).
    func testHoldSkipShowsStillCardOnAether() throws {
        let app = try launchAether()
        let capable = waitBar(app, timeout: 10) { $0["cap"] == "1" }
        try XCTSkipUnless(capable, "the Aether session serves no scrub stills here (cap=0): \(barText(app))")
        XCTAssertTrue(waitSeek(app, timeout: 20) { (Double($0["pos"] ?? "") ?? 0) >= 8 }, "playback stalled: \(seekText(app))")
        // Back over loaded ground: the press-down click lands 10 s back, the ticks keep going.
        remote.press(.left, forDuration: 2.0)
        let p = probe(app, "debug_transportProbe")
        print("[AetherLeg] hold still card: \(barText(app))")
        XCTAssertGreaterThanOrEqual(Int(p["hcard"] ?? "") ?? 0, 1, "no still card during the hold: \(barText(app))")
        XCTAssertEqual(Double(p["cardw"] ?? "") ?? 0, 400, accuracy: 1, barText(app))
        XCTAssertTrue(waitBar(app, timeout: 3) { $0["card"] == "n" }, "the card outlived the release: \(barText(app))")
    }

    /// `-debug.seekPreviewMode off`: Aether creates no still source, reports no capability, and a hold
    /// draws no card.
    func testSeekPreviewOffHonouredOnAether() throws {
        let app = try launchAether(extra: ["-debug.seekPreviewMode", "off"])
        XCTAssertTrue(waitSeek(app, timeout: 20) { (Double($0["pos"] ?? "") ?? 0) >= 5 }, "playback stalled: \(seekText(app))")
        XCTAssertEqual(probe(app, "debug_transportProbe")["cap"], "0", "Off still reports a still source: \(barText(app))")
        remote.press(.right, forDuration: 2.0)
        let p = probe(app, "debug_transportProbe")
        print("[AetherLeg] off: \(barText(app))")
        XCTAssertEqual(p["hcard"], "0", "a hold drew a picture card in Off mode: \(barText(app))")
        XCTAssertEqual(p["cap"], "0", barText(app))
        XCTAssertEqual(p["cardw"], "0", "a card body was laid out in Off mode: \(barText(app))")
        XCTAssertTrue(waitBar(app, timeout: 3) { $0["card"] == "n" }, barText(app))
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

    // MARK: Return from background (spec 9.3, T-UI-A1 to A6; the simulator is the software route)

    /// The rule's mode (`ret=<mode>/<last outcome>` on the seek probe).
    private func retMode(_ p: [String: String]) -> String { (p["ret"] ?? "-").components(separatedBy: "/").first ?? "-" }
    private func retOutcome(_ p: [String: String]) -> String { (p["ret"] ?? "-").components(separatedBy: "/").dropFirst().first ?? "-" }

    /// A real background trip: Home on the Siri Remote, `awaySec` on the tvOS home screen, then the app is
    /// brought back with `activate()`. Returns false (with the state it saw) when the simulator does not
    /// background or foreground the app.
    private func homeAndReturn(_ app: XCUIApplication, awaySec: TimeInterval) -> (ok: Bool, note: String) {
        var how = "Home"
        remote.press(.home)
        var left = Date().addingTimeInterval(8)
        while Date() < left, app.state == .runningForeground { Thread.sleep(forTimeInterval: 0.25) }
        if app.state == .runningForeground {
            // The tvOS simulator can leave the app in front on an XCUIRemote Home press; bringing another
            // app forward is a real background trip too (the system sends didEnterBackground).
            how = "Settings app in front"
            XCUIApplication(bundleIdentifier: "com.apple.TVSettings").activate()
            left = Date().addingTimeInterval(15)
            while Date() < left, app.state == .runningForeground { Thread.sleep(forTimeInterval: 0.25) }
        }
        guard app.state != .runningForeground else { return (false, "still foreground after Home and after the Settings app") }
        let away = app.state
        Thread.sleep(forTimeInterval: awaySec)   // the time away itself, not an assertion
        app.activate()
        let back = Date().addingTimeInterval(20)
        while Date() < back, app.state != .runningForeground { Thread.sleep(forTimeInterval: 0.25) }
        guard app.state == .runningForeground else { return (false, "not foreground 20 s after activate (away state \(away.rawValue))") }
        return (true, "\(how), away state \(away.rawValue)")
    }

    /// The DEBUG in-process cycle (`DebugBackgroundCycle`): background notifications at `atSec`, active again
    /// `awaySec` later. The app stays foreground, so the faults and timings are deterministic.
    private func cycleArgs(atSec: Int, awaySec: Int) -> [String] {
        ["-debug.backgroundCycleAtSec", String(atSec), "-debug.backgroundCycleAwaySec", String(awaySec)]
    }

    /// Waits for the DEBUG cycle's background half to be seen by the rule (mode `away`, or already past it).
    private func waitCycleStarted(_ app: XCUIApplication, timeout: TimeInterval = 40) -> Bool {
        waitSeek(app, timeout: timeout) { (self.retMode($0) != "idle" && self.retMode($0) != "-") || self.retOutcome($0) != "-" }
    }

    /// The return is over: paused, the rule idle with `outcome`, a frame displayed.
    private func waitReturnSettled(_ app: XCUIApplication, outcome: String? = "settled", timeout: TimeInterval = 45) -> Bool {
        waitSeek(app, timeout: timeout) {
            self.retMode($0) == "idle" && (outcome == nil || self.retOutcome($0) == outcome)
                && $0["paused"] == "1" && $0["picture"] == "1"
        }
    }

    /// After a settled return: still paused (no auto-resume), then one Play/Pause plays on from there.
    private func assertPausedThenPlays(_ app: XCUIApplication, from back: Double, file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(seek(app)["paused"], "1", "the return did not stay paused: \(seekText(app))", file: file, line: line)
        XCTAssertEqual(pos(app), back, accuracy: 0.6, "the position moved while paused after the return: \(seekText(app))", file: file, line: line)
        remote.press(.playPause)
        var lowest = Double.infinity
        XCTAssertTrue(waitSeek(app, timeout: 20) {
            let p = Double($0["pos"] ?? "") ?? -1
            if $0["paused"] == "0", p >= 0 { lowest = min(lowest, p) }
            return $0["paused"] == "0" && p >= back + 2
        }, "Play after the return did not play on: back=\(back) \(seekText(app))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(lowest, back - 1, "Play started from an earlier position than the return showed: back=\(back) lowest=\(lowest)",
                                    file: file, line: line)
        XCTAssertTrue(app.otherElements["player.aether"].exists, "no longer the Aether controller", file: file, line: line)
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "mpv took over", file: file, line: line)
    }

    /// T-UI-A1, real background (Home, 5 s on the home screen, activate): paused at the pre-Home position
    /// with a picture (`picture=1`), `ret=idle/settled`; Play plays on. Records whether the exact-seek nudge
    /// was needed on the software route (`nudged=`, spec E11). Then leaves the player and backgrounds again:
    /// nothing comes back (no restore after leaving).
    func testBackgroundReturnComesBackPausedAndPlays() throws {
        let app = try launchAether()
        XCTAssertTrue(waitSeek(app, timeout: 40) { (Double($0["pos"] ?? "") ?? 0) >= 10 }, "never reached 10 s: \(seekText(app))")
        let p0 = pos(app)
        let trip = homeAndReturn(app, awaySec: 5)
        XCTAssertTrue(trip.ok, "the simulator did not background and foreground the app: \(trip.note)")
        guard trip.ok else { return }
        print("[ReturnLeg] A1 home trip: \(trip.note) p0=\(p0)")
        XCTAssertTrue(app.otherElements["player.aether"].waitForExistence(timeout: 10), "the Aether controller is gone after the return")
        XCTAssertTrue(waitReturnSettled(app), "the return never settled paused with a picture: \(seekText(app))")
        let back = pos(app)
        print("[ReturnLeg] A1 settled: p0=\(p0) back=\(back) \(seekText(app))")
        XCTAssertGreaterThan(back, 1, "the position was reset to 0: \(seekText(app))")
        XCTAssertEqual(back, p0, accuracy: 2.5, "the return is not at the pre-Home position: p0=\(p0) \(seekText(app))")
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "a plain return handed off to mpv")
        assertPausedThenPlays(app, from: back)

        // Leave the player, then background and return: no player comes back.
        for _ in 0..<3 where app.otherElements["player.aether"].exists {
            remote.press(.menu)
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertFalse(app.otherElements["player.aether"].exists, "Menu never left the player")
        let trip2 = homeAndReturn(app, awaySec: 3)
        XCTAssertTrue(trip2.ok, trip2.note)
        Thread.sleep(forTimeInterval: 4.0)
        XCTAssertFalse(app.otherElements["player.aether"].exists, "a player came back after it was left")
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "mpv appeared after the player was left")
    }

    /// Opens the Subtitles popover and picks the row whose title contains `title`; closes the popover.
    private func pickSubtitle(_ app: XCUIApplication, _ title: String) {
        PlayerChrome.openDisc(app, "subtitles")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'player.panel.subtitle.' AND NOT identifier BEGINSWITH 'player.panel.subtitleDelay' AND label CONTAINS %@", title))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "no \(title) row in the Subtitles popover")
        XCTAssertTrue(PlayerChrome.focusWalk(app, to: row), "focus never reached the \(title) row")
        remote.press(.select)
        let end = Date().addingTimeInterval(4)
        while Date() < end, (row.value as? String) != "selected" { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertEqual(row.value as? String, "selected", "\(title) not selected after the pick")
        remote.press(.menu)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "player.popover.subtitles"))
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 4), .completed, "Menu did not close the Subtitles popover")
    }

    /// T-UI-A2 (DEBUG cycle at 32 s, 5 s away): a picked subtitle, Boost 6 dB with Dialogue, and a 0.3 s audio
    /// delay are all the same after the restore (`sub=`, `audio=`, `shaping=`, `delay=` on the seek probe).
    func testBackgroundReturnKeepsTracksDelayAndShaping() throws {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["AETHER_SMOKE_SUBS_URL"], "AETHER_SMOKE_SUBS_URL not set")
        // Resume at 12 s (not Start Over: the controller honours `resumeAtSec` > 10), as the subtitle legs do.
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-debug.mpvSmokeEngine", "aether", "-debug.mpvSmokeResumeSec", "12",
                                "-player.boostDb", "6", "-player.audioMode", "dialogue",
                                "-debug.mpvSmokeAudioDelayMs", "300"] + cycleArgs(atSec: 50, awaySec: 5)
        app.launch()
        XCTAssertTrue(app.otherElements["player.aether"].waitForExistence(timeout: 30), "the Aether controller did not appear")
        XCTAssertTrue(waitSeek(app, timeout: 40) { (Double($0["pos"] ?? "") ?? 0) >= 12 }, "playback never reached the resume point: \(seekText(app))")
        // The Subtitles disc is reached from a hidden bar (as in the subtitle legs).
        XCTAssertTrue(waitBar(app, timeout: 14) { $0["vis"] == "0" }, "the bar never hid: \(barText(app))")
        pickSubtitle(app, "Embedded EN")
        XCTAssertTrue(waitSeek(app, timeout: 10) { $0["sub"] != nil && $0["sub"] != "-" }, "no subtitle track active after the pick: \(seekText(app))")
        let before = seek(app)
        XCTAssertLessThan(pos(app), 47, "the pick took too long; the cycle would land inside it: \(seekText(app))")
        print("[ReturnLeg] A2 before: \(seekText(app))")
        XCTAssertEqual(before["shaping"], "3.5/6.0", "Boost/Dialogue did not reach the session: \(seekText(app))")
        XCTAssertEqual(before["delay"], "0.30", "the audio delay did not reach the session: \(seekText(app))")
        XCTAssertTrue(waitCycleStarted(app, timeout: 40), "the DEBUG background cycle never ran: \(seekText(app))")
        XCTAssertTrue(waitReturnSettled(app), "the return never settled paused with a picture: \(seekText(app))")
        let after = seek(app)
        print("[ReturnLeg] A2 after: \(seekText(app))")
        for key in ["sub", "audio", "delay", "shaping"] {
            XCTAssertEqual(after[key], before[key], "\(key) changed across the return: before \(before[key] ?? "nil") after \(after[key] ?? "nil")")
        }
        XCTAssertEqual(Double(after["pos"] ?? "") ?? 0, 50.5, accuracy: 2.5, "not back at the cycle position: \(seekText(app))")
    }

    /// T-UI-A3 (`-debug.aetherRestoreFault refuse`, DEBUG cycle at 10 s): the reload is refused, the fresh
    /// paused load takes over at the position (`refused` seen, then `idle/settled`), no mpv.
    func testRestoreRefusedTakesFreshLoad() throws {
        let app = try launchAether(extra: ["-debug.aetherRestoreFault", "refuse"] + cycleArgs(atSec: 10, awaySec: 5))
        XCTAssertTrue(waitCycleStarted(app), "the DEBUG background cycle never ran: \(seekText(app))")
        var sawRefused = false
        let end = Date().addingTimeInterval(45)
        var settled = false
        while Date() < end {
            let p = seek(app)
            if retOutcome(p) == "refused" || (p["trail"] ?? "").components(separatedBy: ",").contains("refused") { sawRefused = true }
            if retMode(p) == "idle", retOutcome(p) == "settled", p["paused"] == "1", p["picture"] == "1" { settled = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(sawRefused, "the refused reload was never reported: \(seekText(app))")
        XCTAssertTrue(settled, "the fresh load never settled paused with a picture: \(seekText(app))")
        let back = pos(app)
        print("[ReturnLeg] A3 settled: \(seekText(app))")
        XCTAssertEqual(back, 10.5, accuracy: 2.5, "the fresh load is not at the held position: \(seekText(app))")
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "a refusal handed off to mpv")
        assertPausedThenPlays(app, from: back)
    }

    /// T-UI-A4 (`-debug.aetherRestoreFault throw`, DEBUG cycle at 10 s): the failed restore hands the stream to
    /// mpv at the held position (decision E; mpv starts playing, Q1).
    func testRestoreFailureHandsToMpv() throws {
        let app = try launchAether(extra: ["-debug.aetherRestoreFault", "throw"] + cycleArgs(atSec: 10, awaySec: 5))
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 60), "mpv never took over after the failed restore: \(seekText(app))")
        XCTAssertFalse(app.otherElements["player.aether"].exists, "the Aether controller is still showing after the handoff")
        var first = -1.0
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            let p = pos(app)
            if p > 1 { first = p; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("[ReturnLeg] A4 mpv first pos=\(first) \(seekText(app))")
        XCTAssertGreaterThan(first, 7.5, "mpv did not resume at the held position (~10 s): first pos=\(first)")
        XCTAssertLessThan(first, 15.0, "mpv resumed far past the held position (~10 s): first pos=\(first)")
    }

    /// T-UI-A5 (`-debug.aetherRestoreFault delay3s`, DEBUG cycle at 10 s): Play pressed while the restore runs
    /// is queued and applied when it settles: playback goes on without a second press.
    func testPlayDuringRestoreIsQueued() throws {
        let app = try launchAether(extra: ["-debug.aetherRestoreFault", "delay3s"] + cycleArgs(atSec: 10, awaySec: 4))
        XCTAssertTrue(waitSeek(app, timeout: 40) { ["preparing", "restoring"].contains(self.retMode($0)) },
                      "the restore never started: \(seekText(app))")
        remote.press(.playPause)
        let during = seek(app)
        print("[ReturnLeg] A5 Play pressed during: \(seekText(app))")
        XCTAssertTrue(["preparing", "restoring"].contains(retMode(during)), "Play landed after the restore, not during it: \(seekText(app))")
        XCTAssertTrue(waitSeek(app, timeout: 45) { self.retMode($0) == "idle" && $0["paused"] == "0" && $0["picture"] == "1" },
                      "the queued Play was not applied at the settle: \(seekText(app))")
        let back = pos(app)
        XCTAssertTrue(waitSeek(app, timeout: 15) { (Double($0["pos"] ?? "") ?? 0) >= back + 2 && $0["paused"] == "0" },
                      "playback did not go on after the queued Play: \(seekText(app))")
        XCTAssertGreaterThan(back, 7.5, "the queued Play started from a reset position: \(seekText(app))")
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "mpv took over")
    }

    /// T-UI-A6 (`-debug.aetherStartDelaySec 4`, DEBUG cycle at the first tick, 3 s away): a return while the
    /// first load is still held ends paused near the start with a picture, and no false first-frame timeout
    /// hands it to mpv.
    func testReturnDuringStartPausesAtStart() throws {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["AETHER_SMOKE_URL"])
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-debug.mpvSmokeEngine", "aether", "-debug.mpvSmokeStartOver", "YES",
                                "-debug.aetherStartDelaySec", "4"] + cycleArgs(atSec: 0, awaySec: 3)
        app.launch()
        XCTAssertTrue(app.otherElements["player.aether"].waitForExistence(timeout: 30), "the Aether controller did not appear")
        XCTAssertTrue(waitSeek(app, timeout: 60) { self.retMode($0) == "idle" && $0["paused"] == "1" && $0["picture"] == "1" },
                      "the start never ended paused with a picture after the return: \(seekText(app))")
        let back = pos(app)
        print("[ReturnLeg] A6 settled: \(seekText(app))")
        XCTAssertLessThan(back, 3, "a return during the start did not stay at the start: \(seekText(app))")
        // Longer than the start watchdog would take to fire on a wrongly counted budget.
        let watch = Date().addingTimeInterval(12)
        while Date() < watch {
            XCTAssertFalse(app.otherElements["player.mpv"].exists, "a false first-frame timeout handed off to mpv")
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(seek(app)["paused"], "1", "the start did not stay paused: \(seekText(app))")
        remote.press(.playPause)
        XCTAssertTrue(waitSeek(app, timeout: 20) { $0["paused"] == "0" && (Double($0["pos"] ?? "") ?? 0) >= back + 2 },
                      "Play after the return did not play: \(seekText(app))")
    }
}
