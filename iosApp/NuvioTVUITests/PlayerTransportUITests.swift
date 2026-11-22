import XCTest
import UIKit

/// mpv transport legs (P1 preview-then-commit seek, scan). Run against a long (>= 10 min) file on
/// the mpv smoke rig. Skipped unless `PLAYER_BAR_PROBE=1` and `PLAYER_SMOKE_URL` are in the
/// environment (pass them as `TEST_RUNNER_PLAYER_BAR_PROBE=1` / `TEST_RUNNER_PLAYER_SMOKE_URL=...`).
/// Reads the DEBUG `debug_seekProbe` label (`Screens/Player/SeekProbe.swift`).
final class PlayerTransportUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    // MARK: Harness

    /// `url`: a fixture other than `PLAYER_SMOKE_URL` (the chapter legs pass
    /// `PLAYER_SMOKE_CHAPTERS_URL`, critique C24); nil = the plain smoke file.
    private func launch(url fixture: String? = nil, extra: [String] = [], waitForPlay: Bool = true) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_BAR_PROBE"] == "1")
        let url = try fixture ?? XCTUnwrap(env["PLAYER_SMOKE_URL"], "PLAYER_SMOKE_URL not set")
        let app = XCUIApplication()
        // 8 MiB forward cache keeps a long hold's target outside the cached range, so the
        // keyframes stage is exercised (the default cache swallows the whole smoke file).
        // Start-over: the rig would otherwise resume from the previous run's saved position and a
        // hold-step leg could run into the 600 s fixture's end.
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "NO",
                                "-player.bufferMB", "8", "-debug.mpvSmokeStartOver", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 30), "player did not appear")
        guard waitForPlay else { return app }
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

    /// A press that lands while a keyframes-first commit still owes its exact stage cancels that stage.
    /// `-debug.commitExactHoldMs 4000` (DEBUG) holds the exact stage at least 4 s after the commit on
    /// both of its paths, so the second press always lands first; without it the stage could finish
    /// inside the 150 ms window before the press arrived ("ke", the 2026-11-17 flake).
    /// `testExactStageRunsWhenNotInterrupted` is the control: the same hold with no second press.
    func testExactStageCancelledByNewPress() throws {
        let app = try launch(extra: ["-debug.commitExactHoldMs", "4000"])
        remote.press(.right, forDuration: 1.5)
        remote.press(.right)    // lands inside the 4 s hold
        Thread.sleep(forTimeInterval: 2.0)
        var p = probe(app)
        XCTAssertEqual(p["stages"], "k", "exact stage should have been cancelled: \(probeText(app))")
        XCTAssertEqual(p["commits"], "1", probeText(app))
        remote.press(.right, forDuration: 1.5)
        Thread.sleep(forTimeInterval: 2.0)
        p = probe(app)
        XCTAssertEqual(p["commits"], "2", probeText(app))
    }

    /// Control for the leg above: the same 4 s hold and no second press, so the exact stage runs once the
    /// hold is over ("ke"). Proves the hold only delays the stage and does not suppress it.
    func testExactStageRunsWhenNotInterrupted() throws {
        let app = try launch(extra: ["-debug.commitExactHoldMs", "4000"])
        remote.press(.right, forDuration: 1.5)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(probe(app)["stages"], "k", "the exact stage ran inside the hold: \(probeText(app))")
        XCTAssertTrue(waitFor(app, timeout: 8) { $0["stages"] == "ke" }, "the exact stage never ran after the hold: \(probeText(app))")
        XCTAssertEqual(probe(app)["commits"], "1", probeText(app))
    }

    func testScanLatchesAndCycles() throws {
        let app = try launch(extra: ["-player.holdMode", "scan"])
        remote.press(.right, forDuration: 1.0)
        XCTAssertTrue(waitFor(app) { $0["speed"] == "2.0" && $0["mode"] == "scanning" }, probeText(app))
        // GitHub #33: a scan shows no preview card at any rate (the video is the preview).
        XCTAssertEqual(bar(app)["card"], "n", barProbeText(app))
        Thread.sleep(forTimeInterval: 1.0)
        var p = probe(app)
        XCTAssertEqual(p["speed"], "2.0", "scan must latch after release: \(probeText(app))")
        XCTAssertEqual(p["mode"], "scanning", probeText(app))
        remote.press(.right)
        XCTAssertTrue(waitFor(app) { $0["speed"] == "3.0" }, probeText(app))
        XCTAssertEqual(bar(app)["card"], "n", barProbeText(app))
        remote.press(.right)
        XCTAssertTrue(waitFor(app) { $0["speed"] == "4.0" }, probeText(app))
        XCTAssertEqual(bar(app)["card"], "n", barProbeText(app))
        remote.press(.select)
        XCTAssertTrue(waitFor(app) { $0["speed"] == "1.0" && $0["mode"] == "idle" && $0["paused"] == "0" }, probeText(app))
        let b = bar(app)
        XCTAssertEqual(b["card"], "n", barProbeText(app))
        XCTAssertEqual(b["hcard"], "0", "no hold card during a scan: \(barProbeText(app))")
        XCTAssertEqual(b["ccard"], "0", "a scan-armed hold is not a click: \(barProbeText(app))")
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
        let scanEnd = pos(app)
        remote.press(.menu)
        try requirePlayerStillPresented(app, "Menu during a scan must not exit the player")
        XCTAssertTrue(waitFor(app) { $0["mode"] == "idle" && $0["speed"] == "1.0" }, probeText(app))
        // The return seek is recorded on the probe as stages=r with its target; the playhead keeps
        // moving once it lands, so the target is the oracle and the position only has to drop
        // below the scan end at some poll (the exact backward seek can take a few seconds here).
        let p = probe(app)
        XCTAssertEqual(p["stages"], "r", "Menu did not issue the return seek: \(probeText(app))")
        let target = Double(p["lastTarget"] ?? "") ?? -1
        XCTAssertEqual(target, origin, accuracy: 3.0, "return seek target off the origin: \(probeText(app))")
        XCTAssertGreaterThan(scanEnd, origin + 1.5, "the scan did not move before Menu: scanEnd=\(scanEnd)")
        XCTAssertTrue(waitFor(app, timeout: 12) {
            guard let after = Double($0["pos"] ?? "") else { return false }
            return after < scanEnd - 1.0
        }, "position never dropped below the scan end \(scanEnd): \(probeText(app))")
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
    private func launchWithBarHidden(url: String? = nil, extra: [String] = []) throws -> XCUIApplication {
        let app = try launch(url: url, extra: extra)
        XCTAssertTrue(waitBar(app, timeout: 10) { $0["vis"] == "0" }, "bar never hid: \(barProbeText(app))")
        return app
    }

    // MARK: Exit (BUG-165, Batch B)

    /// BUG-165 (Steven, rc4 verdict): leaving the mpv player with Home underneath sent the app to
    /// the tvOS home screen. The smoke host presents the player over the ROOT view, which is the
    /// same shape (nothing under the cover answers a Menu), so this leg is the simulator half of
    /// the repro: the exit Menu, then a second Menu inside the dismissal (a slow release or a
    /// double tap), then the app must still be in the foreground once the cover is gone. The
    /// control leg below passes with the shield off too (the dismissing cover takes the second
    /// press on the simulator), so this leg guards the exit-then-double-Menu path itself, not the
    /// shield; the shield's own proof needs the device (`[MenuProbe] shield swallowed`).
    func testMenuExitOverRootKeepsTheAppForeground() throws {
        try menuExitOverRoot(shieldOff: false)
    }

    /// The control run: the same presses with the shield off (`-debug.menuExitShieldOff`). Opt-in
    /// (`PLAYER_EXIT_CONTROL=1`): it ends with the app in the background when the shield is what
    /// keeps it up, which is the leg's proof, and a backgrounded app wedges the legs after it.
    func testMenuExitOverRootControlWithShieldOff() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAYER_EXIT_CONTROL"] == "1")
        try menuExitOverRoot(shieldOff: true)
    }

    private func menuExitOverRoot(shieldOff: Bool) throws {
        let app = try launchWithBarHidden(extra: shieldOff ? ["-debug.menuExitShieldOff", "YES"] : [])
        remote.press(.menu)                      // bar hidden → `MenuPrecedence.exit`
        Thread.sleep(forTimeInterval: 0.25)      // inside the cover's dismissal
        remote.press(.menu)
        let gone = NSPredicate(format: "exists == false")
        let exp = XCTNSPredicateExpectation(predicate: gone, object: app.otherElements["player.mpv"])
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: 6), .completed, "Menu did not exit the player")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(app.state, .runningForeground, "the app left the foreground after the player exit")
        // Past the shield's ceiling the root gets its Menu back; nothing is pressed here, a Menu on
        // the smoke root legitimately leaves the app.
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(app.state, .runningForeground, "the app left the foreground late")
    }

    func testBarGeometryProbe() throws {
        let app = try launchWithBarHidden()
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" && abs((Double($0["y"] ?? "") ?? 0) - 155) <= 2 }, barProbeText(app))
        let p = bar(app)
        // 155: the track sits above the text pill row (Insights wave 1d moved it up from 95).
        XCTAssertEqual(Double(p["y"] ?? "") ?? 0, 155, accuracy: 2, barProbeText(app))
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
        let popover = app.descendants(matching: .any)["player.popover.subtitles"]
        XCTAssertTrue(popover.waitForExistence(timeout: 6), "subtitles popover did not open")
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

    // MARK: Swipe scrub (P2-A), driven by `-debug.scrubInject` (the simulator cannot swipe)

    /// 10 samples of 20 pt: the stroke turns horizontal at 60 pt (bar up: 45 pt threshold) and the
    /// remaining 140 pt move the preview (Orivio on the 600 s fixture: 0.25 s/pt → +35 s).
    private static let scrubScript = Array(repeating: "20,0.03", count: 10).joined(separator: ";")

    private func postScrubInject() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("com.nuvio.debug.transport.scrubInject" as CFString), nil, nil, true)
    }

    /// Bar up from a hidden bar, then 0.6 s so the Up press is outside the arbiter's move suppression.
    /// Call it LAST before the inject: the bar auto-hides 4 s after Up, and with the bar hidden the
    /// arbiter's horizontal intent is 160 pt instead of 45 pt, which eats most of the 200 pt script
    /// (a probe read is ~1–1.5 s on the simulator, so two reads in between raced the auto-hide).
    /// Read `commits`/`pos` before raising: the probes report them with the bar hidden too.
    private func raiseBarForScrub(_ app: XCUIApplication) {
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, barProbeText(app))
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Posts the inject and waits for the scrub to start and the script (0.3 s) to finish; returns
    /// the scrub target.
    private func injectAndReadTarget(_ app: XCUIApplication) -> Double {
        postScrubInject()
        let started = waitBar(app) { $0["mode"] == "scrubbing" }
        XCTAssertTrue(started, "scrub never started (vis=\(bar(app)["vis"] ?? "?")): \(barProbeText(app))")
        Thread.sleep(forTimeInterval: 0.6)
        let p = bar(app)
        print("[ScrubLeg] after inject vis=\(p["vis"] ?? "?"): \(barProbeText(app))")
        return Double(p["scrub"] ?? "") ?? -1
    }

    func testScrubSelectCommitsOnce() throws {
        let app = try launchWithBarHidden(extra: ["-debug.scrubInject", Self.scrubScript])
        let c0 = Int(probe(app)["commits"] ?? "") ?? -1
        let before = Double(bar(app)["pos"] ?? "") ?? -1
        raiseBarForScrub(app)
        let target = injectAndReadTarget(app)
        print("[ScrubLeg] select before=\(before) scrub=\(target) delta=\(target - before)")
        let b = bar(app)
        XCTAssertEqual(b["curve"], "o", barProbeText(app))
        XCTAssertEqual(b["arb"], "h", barProbeText(app))
        XCTAssertGreaterThanOrEqual(target - before, 30, "scrub moved too little: before=\(before) \(barProbeText(app))")
        // 35 s of scrub plus the playback drift between the `before` read and the scrub's base
        // (review r1 P3 #10: 42 left ~3 s of headroom).
        XCTAssertLessThanOrEqual(target - before, 45, "scrub moved too far: before=\(before) \(barProbeText(app))")
        remote.press(.select)
        let selectedAt = Date()
        XCTAssertTrue(waitFor(app, timeout: 5) {
            Int($0["commits"] ?? "") == c0 + 1 && $0["scrubs"] == "1" && $0["mode"] == "idle"
                && abs((Double($0["lastTarget"] ?? "") ?? -999) - target) <= 1
        }, "scrub commit not recorded: \(probeText(app))")
        Thread.sleep(forTimeInterval: 4.0)
        let p = probe(app)
        // The bar read takes ~1 s on the simulator: the clock before and after it, and the
        // midpoint as the read time, so the bias is neither side of the read (review r2 P3 #3).
        let readStart = Date()
        let livePos = Double(bar(app)["pos"] ?? "") ?? -1
        let readEnd = Date()
        let elapsed = (readStart.timeIntervalSince(selectedAt) + readEnd.timeIntervalSince(selectedAt)) / 2
        XCTAssertEqual(livePos, target + elapsed, accuracy: 2.5,
                       "playback did not continue from the target \(target) (+\(elapsed) s): \(barProbeText(app))")
        XCTAssertEqual(Int(p["commits"] ?? ""), c0 + 1, "a scrub must be exactly one commit: \(probeText(app))")
        XCTAssertEqual(bar(app)["mode"], "idle", barProbeText(app))
        print("[ScrubLeg] select end: \(probeText(app)) | \(barProbeText(app))")
    }

    /// Menu cancels the scrub (nothing committed) and the player stays: since 0c10ca4a4 the cover's
    /// Menu tap is gated, so this asserts the player directly (critique C26).
    func testScrubMenuCancels() throws {
        let app = try launchWithBarHidden(extra: ["-debug.scrubInject", Self.scrubScript])
        let c0 = Int(probe(app)["commits"] ?? "") ?? -1
        raiseBarForScrub(app)
        _ = injectAndReadTarget(app)
        remote.press(.menu)
        XCTAssertTrue(waitBar(app) { $0["mode"] == "idle" && $0["prev"] == "nil" && $0["vis"] == "1" },
                      "Menu did not cancel back to idle with the bar up: \(barProbeText(app))")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.otherElements["player.mpv"].exists, "Menu during a scrub exited the player")
        let p = probe(app)
        XCTAssertEqual(p["scrubs"], "0", probeText(app))
        XCTAssertEqual(Int(p["commits"] ?? ""), c0, "Menu must commit nothing: \(probeText(app))")
        print("[ScrubLeg] menu end: \(probeText(app)) | \(barProbeText(app))")
    }

    /// A focused pill needs 190 pt: a 150 pt stroke does nothing and the pill keeps focus. The same
    /// stroke with the focus back on the track scrubs (proves the inject ran).
    func testPillFocusedScrubIgnored() throws {
        let script = Array(repeating: "25,0.03", count: 6).joined(separator: ";")
        let app = try launchWithBarHidden(extra: ["-debug.scrubInject", script])
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, barProbeText(app))
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["focus"] == "pill:subtitles" }, barProbeText(app))
        Thread.sleep(forTimeInterval: 0.6)
        postScrubInject()
        Thread.sleep(forTimeInterval: 1.5)
        let b = bar(app)
        XCTAssertEqual(b["mode"], "idle", barProbeText(app))
        XCTAssertEqual(b["focus"], "pill:subtitles", barProbeText(app))
        XCTAssertEqual(b["arb"], "u", barProbeText(app))
        XCTAssertEqual(probe(app)["scrubs"], "0", probeText(app))
        // Control: focus back on the track, same stroke → a scrub.
        remote.press(.down)
        XCTAssertTrue(waitBar(app) { $0["focus"] == "track" }, barProbeText(app))
        Thread.sleep(forTimeInterval: 0.6)
        postScrubInject()
        XCTAssertTrue(waitBar(app) { $0["mode"] == "scrubbing" && $0["arb"] == "h" },
                      "control stroke did not scrub: \(barProbeText(app))")
        print("[ScrubLeg] pill end: \(barProbeText(app))")
        remote.press(.menu)
        XCTAssertTrue(waitBar(app) { $0["mode"] == "idle" }, barProbeText(app))
    }

    /// A 150 pt downward stroke (decided at 120 pt) is a Down press and nothing else: the bar comes
    /// up with the Info pill focused (the top panel it used to open is gone) and no scrub starts.
    func testVerticalSwipeFocusesInfoPill() throws {
        let script = Array(repeating: "0,0.03,30", count: 5).joined(separator: ";")
        let app = try launchWithBarHidden(extra: ["-debug.scrubInject", script])
        raiseBarForScrub(app)
        postScrubInject()
        let info = app.descendants(matching: .any)["player.infoPill.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 6), "info pill did not appear")
        let end = Date().addingTimeInterval(5)
        while Date() < end, (info.value as? String) != "focused" { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertEqual(info.value as? String, "focused", "a down swipe did not focus the Info pill")
        XCTAssertEqual(probe(app)["scrubs"], "0", probeText(app))
    }

    /// `-debug.scrubCurve bobsupra` ("Flick"): 7 × 20 pt at 600 s = +40.32 s.
    func testScrubCurveFlick() throws {
        let app = try launchWithBarHidden(extra: ["-debug.scrubInject", Self.scrubScript, "-debug.scrubCurve", "bobsupra"])
        let before = Double(bar(app)["pos"] ?? "") ?? -1
        raiseBarForScrub(app)
        let target = injectAndReadTarget(app)
        XCTAssertEqual(bar(app)["curve"], "b", barProbeText(app))
        XCTAssertGreaterThanOrEqual(target - before, 36, "before=\(before) \(barProbeText(app))")
        XCTAssertLessThanOrEqual(target - before, 47, "before=\(before) \(barProbeText(app))")
        remote.press(.menu)
        XCTAssertTrue(waitBar(app) { $0["mode"] == "idle" }, barProbeText(app))
    }

    // MARK: Seek preview harvest (P2-B)

    /// ~25 s of uninterrupted play harvests at least two frames (Auto = one per 10 s of play).
    /// Reads the bar probe's `thumbs=` (it is drawn while the bar is hidden too, so no press is
    /// needed: a press would hold the harvest off for 1.5 s).
    func testHarvestGrows() throws {
        #if targetEnvironment(simulator)
        // Device-only (critique C12/C29): on the simulator `screenshot-raw` traps in MTLSimDriver
        // (`xpc_shmem_create` misuse under MoltenVK's buffer import), so the app turns the real
        // harvest off there. `testHarvestPlumbingSynthetic` covers the rest of the path.
        try XCTSkipIf(true, "device-only: screenshot-raw cannot run on the simulator's Metal driver")
        #else
        let app = try launch()
        let ok = waitBar(app, timeout: 35) { (Int($0["thumbs"] ?? "") ?? 0) >= 2 }
        print("[HarvestLeg] end: \(barProbeText(app))")
        XCTAssertTrue(ok, "store never reached 2 frames: \(barProbeText(app))")
        #endif
    }

    /// The harvest path minus `screenshot-raw` (DEBUG synthetic frames, same scheduler, scaler,
    /// store, probe and card): frames grow while playing, and a scrub back over played ground
    /// shows a frame on the card (`frame=1`).
    func testHarvestPlumbingSynthetic() throws {
        // Leads with a zero sample: a launch-argument value starting with "-" would be read as a key.
        let back = (["0,0.03"] + Array(repeating: "-10,0.03", count: 10)).joined(separator: ";")
        let app = try launch(extra: ["-debug.harvestSynthetic", "YES", "-debug.scrubInject", back])
        XCTAssertTrue(waitBar(app, timeout: 45) { (Int($0["thumbs"] ?? "") ?? 0) >= 3 },
                      "store never reached 3 frames: \(barProbeText(app))")
        print("[HarvestLeg] synthetic grown: \(barProbeText(app))")
        XCTAssertTrue(waitBar(app, timeout: 10) { $0["vis"] == "0" }, "bar never hid: \(barProbeText(app))")
        let before = Double(bar(app)["pos"] ?? "") ?? -1
        raiseBarForScrub(app)
        postScrubInject()
        XCTAssertTrue(waitBar(app) { $0["mode"] == "scrubbing" }, "scrub never started: \(barProbeText(app))")
        let framed = waitBar(app, timeout: 3) { $0["frame"] == "1" }
        print("[HarvestLeg] scrub back from \(before): \(barProbeText(app))")
        XCTAssertTrue(framed, "no preview frame on a scrub back over played ground: \(barProbeText(app))")
        remote.press(.menu)
        XCTAssertTrue(waitBar(app) { $0["mode"] == "idle" && $0["frame"] == "0" }, barProbeText(app))
    }

    // MARK: Seek preview decode (P3), reads the bar probe's `decoded=` / `fsec=`

    /// Whole Video (`-debug.seekPreviewMode decode`): on the simulator the harvest is off, so every stored frame here came from
    /// the keyframe thumbnailer's pre-warm (it opens after 20 s of healthy play, then passes of up
    /// to 8 frames every 10 s). Ten frames within 60 s of playback.
    func testDecodePrewarmGrows() throws {
        // Review r2 P3 #2: no budget override. The 116 MB fixture's budget is a tenth of it (11.6 MB
        // under the 16 MB floor): an open of about 3 MB plus 288 KB per keyframe leaves room for
        // the ten frames (`-debug.thumbBudgetMB` stays for experiments).
        let app = try launch(extra: ["-debug.seekPreviewMode", "decode"])
        let ok = waitBar(app, timeout: 60) {
            (Int($0["decoded"] ?? "") ?? 0) >= 10 && (Int($0["thumbs"] ?? "") ?? 0) >= 10
        }
        print("[DecodeLeg] prewarm end: \(barProbeText(app))")
        XCTAssertTrue(ok, "pre-warm never reached 10 decoded frames: \(barProbeText(app))")
    }

    /// A scrub at about 8 s of playback (before the 20 s healthy open, so nothing is decoded yet)
    /// into unwatched ground: the miss opens the thumbnailer and decodes the keyframe there, and
    /// the card shows a frame stamped within 5 s of the target (critique C23).
    func testDecodeScrubIntoUnwatched() throws {
        let app = try launchWithBarHidden(extra: ["-debug.seekPreviewMode", "decode", "-debug.scrubInject", Self.scrubScript])
        let before = bar(app)
        print("[DecodeLeg] before scrub: \(barProbeText(app))")
        XCTAssertEqual(before["decoded"], "0", "something decoded before the scrub: \(barProbeText(app))")
        XCTAssertEqual(before["thumbs"], "0", barProbeText(app))
        XCTAssertLessThan(Double(before["pos"] ?? "") ?? 99, 18, "scrub too late for the premise: \(barProbeText(app))")
        raiseBarForScrub(app)
        let target = injectAndReadTarget(app)
        let start = Date()
        XCTAssertGreaterThanOrEqual(target - (Double(before["pos"] ?? "") ?? 0), 25, "scrub moved too little: \(barProbeText(app))")
        // Review r1 P3 #11: the window includes the thumbnailer's lazy open (the first scrub opens
        // it), so it is 3 s, the urgent frame deadline; 1.11 s was measured. Over 1.5 s is logged
        // as SLOW so a loaded simulator can be told apart from a missed scrub.
        let framed = waitBar(app, timeout: 3.0) {
            guard $0["mode"] == "scrubbing", $0["frame"] == "1", let f = Double($0["fsec"] ?? "") else { return false }
            return abs(f - target) <= 5
        }
        let elapsed = Date().timeIntervalSince(start)
        let p = bar(app)
        print("[DecodeLeg] scrub target=\(target) framed=\(framed) after \(String(format: "%.2f", elapsed)) s: \(barProbeText(app))")
        if framed, elapsed > 1.5 { print("[DecodeLeg] SLOW: framed after \(String(format: "%.2f", elapsed)) s (open included)") }
        XCTAssertTrue(framed, "no decoded frame near the scrub target \(target): \(barProbeText(app))")
        XCTAssertGreaterThanOrEqual(Int(p["decoded"] ?? "") ?? 0, 1, barProbeText(app))
        remote.press(.menu)
        XCTAssertTrue(waitBar(app) { $0["mode"] == "idle" && $0["frame"] == "0" && $0["fsec"] == "nil" }, barProbeText(app))
    }

    /// Off beats the DEBUG synthetic harvest (critique C22): with `-debug.harvestSynthetic YES` the
    /// store grows in harvest mode (`testHarvestPlumbingSynthetic`, the positive control); with
    /// the mode Off nothing is stored or decoded after 30 s of playback.
    func testDecodeOffByMode() throws {
        let app = try launch(extra: ["-debug.seekPreviewMode", "off", "-debug.harvestSynthetic", "YES"])
        XCTAssertTrue(waitBar(app, timeout: 45) { (Double($0["pos"] ?? "") ?? 0) >= 30 }, "playback stalled: \(barProbeText(app))")
        let p = bar(app)
        print("[DecodeLeg] off end: \(barProbeText(app))")
        XCTAssertEqual(p["thumbs"], "0", barProbeText(app))
        XCTAssertEqual(p["decoded"], "0", barProbeText(app))
        XCTAssertEqual(p["cap"], "0", barProbeText(app))
        // GitHub #33: Off draws no picture card for a hold, and a click's card is the time only.
        remote.press(.right, forDuration: 2.0)
        remote.press(.right)
        let c = bar(app)
        print("[PreviewLeg] off hold + click: \(barProbeText(app))")
        XCTAssertEqual(c["hcard"], "0", "a hold drew a picture card in Off mode: \(barProbeText(app))")
        // Two clicks: the hold's own press-down is a Step click (its card until the first tick),
        // then the click.
        XCTAssertEqual(c["ccard"], "2", "the clicks' time-only cards were never laid out: \(barProbeText(app))")
        XCTAssertNotEqual(c["card"], "p", "a placeholder in Off mode: \(barProbeText(app))")
        XCTAssertNotEqual(c["card"], "f", "a picture in Off mode: \(barProbeText(app))")
        // Review r6: a time-only click card leaves the chrome as it is (lockup and pills shown).
        if c["card"] == "t", c["mode"] == "idle" {
            XCTAssertEqual(c["cc"], "0", "an Off-mode click compacted the chrome: \(barProbeText(app))")
        }
        remote.press(.right)
        XCTAssertTrue(waitBar(app, timeout: 2) { $0["mode"] == "idle" }, barProbeText(app))
        let t = bar(app)
        print("[PreviewLeg] off click chrome: \(barProbeText(app))")
        XCTAssertNotEqual(t["card"], "p", barProbeText(app))
        XCTAssertNotEqual(t["card"], "f", barProbeText(app))
        XCTAssertEqual(t["cc"], "0", "an Off-mode click compacted the chrome: \(barProbeText(app))")
        XCTAssertEqual(t["ccd"], "0", "an Off-mode click had a compact dwell: \(barProbeText(app))")
        XCTAssertTrue(waitBar(app, timeout: 4.5) { $0["card"] == "n" }, "the click card never left: \(barProbeText(app))")
        XCTAssertEqual(bar(app)["cardw"], "0", "no card body was ever laid out in Off mode: \(barProbeText(app))")
    }

    // MARK: Seek preview on skips (GitHub #33): the probe's card= / cardw= / hcard= / ccard=

    /// The card's laid-out width (`TransportBarLayout.cardSize.width`).
    private static let cardWidth = 400.0

    /// Whole Video: a 2 s Right hold draws a picture card at its real size (the keyframe decoder
    /// fills the unwatched ground ahead), and the card goes with the release.
    func testHoldSkipShowsPreviewCard() throws {
        let app = try launch(extra: ["-debug.seekPreviewMode", "decode"])
        XCTAssertTrue(waitBar(app, timeout: 20) { (Double($0["pos"] ?? "") ?? 0) >= 10 }, "playback stalled: \(barProbeText(app))")
        XCTAssertEqual(bar(app)["cap"], "1", barProbeText(app))
        remote.press(.right, forDuration: 2.0)
        let p = bar(app)
        print("[PreviewLeg] hold skip: \(barProbeText(app))")
        XCTAssertGreaterThanOrEqual(Int(p["hcard"] ?? "") ?? 0, 1, "no picture card during the hold: \(barProbeText(app))")
        XCTAssertEqual(Double(p["cardw"] ?? "") ?? 0, Self.cardWidth, accuracy: 1, barProbeText(app))
        XCTAssertTrue(waitBar(app, timeout: 3) { $0["card"] == "n" }, "the card outlived the release: \(barProbeText(app))")
    }

    /// Watched Parts with the DEBUG synthetic harvest: a Left hold back over played ground shows a
    /// harvested picture.
    func testHoldBackShowsHarvestedCard() throws {
        let app = try launch(extra: ["-debug.harvestSynthetic", "YES"])
        XCTAssertTrue(waitBar(app, timeout: 45) { (Int($0["thumbs"] ?? "") ?? 0) >= 3 },
                      "store never reached 3 frames: \(barProbeText(app))")
        remote.press(.left, forDuration: 1.5)
        let p = bar(app)
        print("[PreviewLeg] hold back: \(barProbeText(app))")
        XCTAssertGreaterThanOrEqual(Int(p["hcard"] ?? "") ?? 0, 1, "no harvested picture during the hold: \(barProbeText(app))")
        XCTAssertEqual(Double(p["cardw"] ?? "") ?? 0, Self.cardWidth, accuracy: 1, barProbeText(app))
        XCTAssertTrue(waitBar(app, timeout: 3) { $0["card"] == "n" }, barProbeText(app))
    }

    /// One Right click shows a card at the landing point (a placeholder until a picture is ready),
    /// and the card goes after its dwell (at most the 4 s fallback).
    ///
    /// Review r6: while that card body is up after the release (mode idle again) the bar draws the
    /// compact chrome (probe `cc=`, written by the laid-out bar): no title lockup or pill row under
    /// the card. Once it goes the chrome is back and the bar's hide timer runs again.
    /// `PLAYER_DWELL_SCREENSHOT=<path>` (optional) saves one screenshot mid-dwell.
    func testClickShowsLandingCard() throws {
        let app = try launch(extra: ["-debug.seekPreviewMode", "decode"])
        XCTAssertEqual(bar(app)["ccard"], "0", barProbeText(app))
        remote.press(.right)
        // Every sample of the dwell (card body up, press released) has compact chrome.
        var dwellSamples = 0
        var shot = false
        let end = Date().addingTimeInterval(4.5)
        while Date() < end {
            let s = bar(app)
            guard s["card"] == "p" || s["card"] == "f" else { break }
            if s["mode"] == "idle" {
                dwellSamples += 1
                XCTAssertEqual(s["cc"], "1", "the lockup and pills came back under the click card: \(s)")
                if !shot, let path = ProcessInfo.processInfo.environment["PLAYER_DWELL_SCREENSHOT"] {
                    shot = true
                    let png = XCUIScreen.main.screenshot().pngRepresentation
                    XCTAssertNoThrow(try png.write(to: URL(fileURLWithPath: path)))
                    print("[PreviewLeg] dwell screenshot \(path): \(barProbeText(app))")
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let p = bar(app)
        print("[PreviewLeg] click: \(barProbeText(app)) dwellSamples=\(dwellSamples)")
        // The sticky counters cover a dwell shorter than one probe read: the bar drew this click's
        // dwell compact, and never drew a dwell with the full chrome.
        XCTAssertEqual(p["ccd"], "1", "the click's dwell was never drawn with compact chrome: \(barProbeText(app))")
        XCTAssertEqual(p["ccx"], "0", "a dwell was drawn with the lockup and pills: \(barProbeText(app))")
        XCTAssertEqual(p["ccard"], "1", "the click drew no card: \(barProbeText(app))")
        XCTAssertEqual(Double(p["cardw"] ?? "") ?? 0, Self.cardWidth, accuracy: 1, barProbeText(app))
        XCTAssertEqual(p["hcard"], "0", "a click is not a hold: \(barProbeText(app))")
        XCTAssertTrue(waitBar(app, timeout: 4.5) { $0["card"] == "n" }, "the click card never left: \(barProbeText(app))")
        let after = bar(app)
        XCTAssertEqual(after["cc"], "0", "the chrome stayed compact after the card: \(barProbeText(app))")
        // The hide timer held by the dwell runs again: the bar hides on its own (4 s while playing;
        // probe reads are too slow to assert the bar is still up the instant the card goes).
        XCTAssertTrue(waitBar(app, timeout: 7) { $0["vis"] == "0" }, "the bar never hid after the dwell: \(barProbeText(app))")
    }

    /// Three clicks 0.3 s apart: each one replaces the card (three counted), and one card leaves at the end.
    func testRepeatedClicksKeepOneCard() throws {
        let app = try launch(extra: ["-debug.seekPreviewMode", "decode"])
        let c0 = Int(probe(app)["commits"] ?? "") ?? -1
        for _ in 0..<3 {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.3)
        }
        let p = bar(app)
        print("[PreviewLeg] repeated clicks: \(barProbeText(app))")
        XCTAssertEqual(p["ccard"], "3", "each click should have replaced the card: \(barProbeText(app))")
        // Review r6: the chrome stays compact across the clicks (no lockup flash between them).
        XCTAssertGreaterThanOrEqual(Int(p["ccd"] ?? "") ?? 0, 1, barProbeText(app))
        XCTAssertEqual(p["ccx"], "0", "a dwell was drawn with the lockup and pills: \(barProbeText(app))")
        XCTAssertEqual(p["hcard"], "0", barProbeText(app))
        XCTAssertEqual(Int(probe(app)["commits"] ?? ""), c0, "clicks are relative seeks, never commits: \(probeText(app))")
        XCTAssertTrue(waitBar(app, timeout: 4.5) { $0["card"] == "n" }, "the card never left: \(barProbeText(app))")
    }

    // MARK: Chapters and aspect (P2-C)

    /// The chapters fixture (five chapters at 0/90/240/390/540 s); skips when unset.
    private func chaptersURL() throws -> String {
        let url = ProcessInfo.processInfo.environment["PLAYER_SMOKE_CHAPTERS_URL"]
        try XCTSkipIf(url == nil, "PLAYER_SMOKE_CHAPTERS_URL not set: run with TEST_RUNNER_PLAYER_SMOKE_CHAPTERS_URL=http://127.0.0.1:8000/test-long-chapters.mkv")
        return url!
    }

    /// Chapter-derived skip intervals (test plan D7, simulator half): `chapters-named.mkv` has Recap
    /// 0–45, Opening 45–135, Episode, Ending 1260–1350 and Preview; the titles alone give three bar
    /// spans and the Skip Recap chip at the start (the smoke context has no provider data). Skips
    /// when `PLAYER_SMOKE_CHAPTERS_NAMED_URL` is unset.
    func testNamedChaptersProduceSkipChipAndSpans() throws {
        let url = ProcessInfo.processInfo.environment["PLAYER_SMOKE_CHAPTERS_NAMED_URL"]
        try XCTSkipIf(url == nil, "PLAYER_SMOKE_CHAPTERS_NAMED_URL not set: run with TEST_RUNNER_PLAYER_SMOKE_CHAPTERS_NAMED_URL=http://127.0.0.1:8000/chapters-named.mkv")
        let app = try launch(url: url!)
        XCTAssertTrue(waitBar(app, timeout: 10) { $0["spans"] == "3" }, "three skip spans never drawn: \(barProbeText(app))")
        XCTAssertTrue(waitFor(app, timeout: 5) { $0["chip"] == "1" }, "no skip chip over the Recap chapter: \(probeText(app))")
        print("[ChapterSkipLeg] \(probeText(app)) | \(barProbeText(app))")
    }

    /// The bar draws one tick per chapter; the probe counts what it was given.
    func testChapterTicksProbe() throws {
        let app = try launch(url: try chaptersURL())
        XCTAssertTrue(waitBar(app, timeout: 10) { $0["chapters"] == "5" }, "chapters never reached 5: \(barProbeText(app))")
        print("[ChapterLeg] ticks: \(barProbeText(app))")
    }

    /// Down focuses the pill row (past the Opening skip span); the Chapters pill opens its shelf; its third row seeks to 240 s
    /// and closes the shelf. Re-opened mid-file, the shelf ticks Act Two and focus enters the list on
    /// it (the list's default focus), not on the first row.
    func testChaptersShelfSeeks() throws {
        let app = try launchWithBarHidden(url: try chaptersURL())
        XCTAssertTrue(waitBar(app) { $0["chapters"] == "5" }, barProbeText(app))
        // The Opening chapter (0-90 s) is a skip span, and Down skips it ahead of the pill row
        // (`DownPressRule`: a skip interval at the playhead wins). Step past it with Right first.
        for _ in 0..<20 where pos(app) < 100 {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.6)
        }
        XCTAssertGreaterThan(pos(app), 100, "never left the Opening span: \(probeText(app))")
        XCTAssertLessThan(pos(app), 235, "stepped into Act Two: \(probeText(app))")
        XCTAssertTrue(waitBar(app, timeout: 10) { $0["vis"] == "0" }, "bar never hid: \(barProbeText(app))")
        let c0 = Int(probe(app)["commits"] ?? "") ?? -1
        let shelf = PlayerChrome.openShelf(app, "chapters")
        let row = app.descendants(matching: .any)["player.panel.chapter.2"]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "no chapter row 2")
        XCTAssertTrue(row.label.contains("Act Two"), row.label)
        XCTAssertEqual(app.descendants(matching: .any)["player.panel.chapter.1"].value as? String, "selected",
                       "the current chapter (Act One) is not ticked")
        for _ in 0..<6 where !row.hasFocus {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(row.hasFocus, "focus never reached chapter row 2")
        remote.press(.select)
        XCTAssertTrue(waitFor(app, timeout: 5) {
            Int($0["commits"] ?? "") == c0 + 1 && $0["stages"] == "ch" && $0["lastTarget"] == "240"
        }, "chapter seek not recorded: \(probeText(app))")
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: shelf)], timeout: 5),
                       .completed, "shelf did not close")
        XCTAssertTrue(waitFor(app, timeout: 8) { (Double($0["pos"] ?? "") ?? 0) >= 239 }, "never landed at 240: \(probeText(app))")
        print("[ChapterLeg] shelf seek: \(probeText(app)) | \(barProbeText(app))")

        XCTAssertTrue(waitBar(app, timeout: 8) { $0["vis"] == "0" }, "bar never hid: \(barProbeText(app))")
        PlayerChrome.openShelf(app, "chapters")
        XCTAssertTrue(row.waitForExistence(timeout: 3), "no chapter row 2 on re-open")
        XCTAssertEqual(row.value as? String, "selected", "the current chapter (Act Two) is not ticked")
        let first = app.descendants(matching: .any)["player.panel.chapter.0"]
        // Since the Insights device fixes the controller pulls the focus into the shelf as it
        // opens (`UIFocusSystem.requestFocusUpdate`) and the list's first entry lands on the
        // current chapter, with no press. (Until then nothing was focused after the open on the
        // simulator and this leg pressed Down to make the controller ask; that press now moves
        // the focus one row on.) A press is sent only if nothing in the shelf is focused yet.
        let anyRowFocused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH 'player.panel.chapter.'"))
        let entry = Date()
        while anyRowFocused.count == 0 && Date().timeIntervalSince(entry) < 2 { Thread.sleep(forTimeInterval: 0.2) }
        if anyRowFocused.count == 0 {
            print("[ChapterLeg] nothing focused 2 s after the open; pressing Down")
            remote.press(.down)
        }
        let landed = Date()
        while !row.hasFocus && Date().timeIntervalSince(landed) < 4 { Thread.sleep(forTimeInterval: 0.2) }
        if !row.hasFocus {
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
                .map { "\($0.identifier)|\($0.label)" }
            print("[ChapterLeg] focused elements: \(focused) | \(barProbeText(app))")
        }
        XCTAssertTrue(row.hasFocus, "focus did not enter the list on the current chapter (row 2)")
        XCTAssertFalse(first.hasFocus, "focus entered the list on the first row, not the current chapter")
        print("[ChapterLeg] shelf end: \(probeText(app)) | \(barProbeText(app))")
    }

    /// Chapter mode: one Right click jumps to the next chapter (on release, C8); a hold after
    /// that steps from where it is and commits once, with no chapter jump first; Left goes back to
    /// the start of the chapter it lands in.
    func testEdgeClickChapterMode() throws {
        let app = try launch(url: try chaptersURL(), extra: ["-player.edgeClickMode", "chapter"])
        XCTAssertTrue(waitBar(app, timeout: 10) { $0["chapters"] == "5" }, barProbeText(app))
        XCTAssertLessThan(pos(app), 80, probeText(app))
        let c0 = Int(probe(app)["commits"] ?? "") ?? -1
        remote.press(.right)
        XCTAssertTrue(waitFor(app, timeout: 5) {
            Int($0["commits"] ?? "") == c0 + 1 && $0["stages"] == "ch" && $0["lastTarget"] == "90"
                && (Double($0["pos"] ?? "") ?? 0) >= 89
        }, "Right click did not jump to chapter 2 (90 s): \(probeText(app))")
        // Click-then-hold: a held Right steps from the current position and commits once.
        let origin = pos(app)
        remote.press(.right, forDuration: 2.0)
        Thread.sleep(forTimeInterval: 2.0)
        var p = probe(app)
        XCTAssertEqual(Int(p["commits"] ?? ""), c0 + 2, "a hold must be one commit, no chapter jump: \(probeText(app))")
        XCTAssertTrue(["ke", "e", "k"].contains(p["stages"] ?? ""), "the hold landed as a chapter seek: \(probeText(app))")
        let held = Double(p["lastTarget"] ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(held, origin + 140 - 4, "hold jumped back or stepped short: origin=\(origin) \(probeText(app))")
        XCTAssertLessThanOrEqual(held, origin + 230 + 4, "origin=\(origin) \(probeText(app))")
        XCTAssertTrue(waitFor(app, timeout: 8) { abs((Double($0["pos"] ?? "") ?? 0) - held) < 6 }, probeText(app))
        print("[ChapterLeg] hold: origin=\(origin) \(probeText(app))")
        // Left: back to the start of the chapter the hold landed in (more than 3 s past it).
        let here = pos(app)
        let starts = [0.0, 90, 240, 390, 540]
        let expected = starts.last { $0 < here - 3 } ?? 0
        remote.press(.left)
        XCTAssertTrue(waitFor(app, timeout: 5) {
            Int($0["commits"] ?? "") == c0 + 3 && $0["stages"] == "ch" && $0["lastTarget"] == String(format: "%.0f", expected)
        }, "Left click from \(here) did not go to \(expected): \(probeText(app))")
        p = probe(app)
        print("[ChapterLeg] edge end: \(probeText(app)) | \(barProbeText(app))")
    }

    /// Up, Up, Right ×3 to the Aspect pill; each Select moves to the next mode, flashes its name and
    /// keeps the pill focused. The write-back (C28, review r1 P2 #1, r2 P2 #1) is asserted on the
    /// probe's stored= / aw= fields:
    /// 1. one press, rest: one write (the next mode);
    /// 2. three presses inside one flash back to the start mode: one more write (the start), the
    ///    modes passed through are never written;
    /// 3. rest on each mode in turn up to Stretch: each synced mode is written, and Stretch at rest
    ///    puts the start mode back; one more press returns to the start mode and writes nothing.
    /// The flash is 6 s here (`-debug.aspectFlashSec`, review r2 P3 #3) so the presses of step 2,
    /// 0.5 s apart plus a press's own cost, can never outlast it on a slow simulator; the oracle for
    /// every write is the flash clearing (the controller's only write trigger short of an exit).
    func testAspectPillCycles() throws {
        let flashSec = 6.0
        let app = try launchWithBarHidden(extra: ["-debug.aspectFlashSec", String(flashSec)])
        let order = ["fit", "fill", "zoom", "stretch"]
        let start = try XCTUnwrap(bar(app)["aspect"], barProbeText(app))
        XCTAssertNotEqual(start, "stretch", "Stretch is session-only, never a start mode")
        // On a Zoom start the walk reaches Stretch first and the old write-back rule passes too
        // (review r3 P3 #2): the proof needs a Fit or Fill start, so say so instead of passing.
        XCTAssertNotEqual(start, "zoom", "the Stretch rule cannot be told from the old one on a Zoom start; set the Test profile's resize mode to Fit or Fill")
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, barProbeText(app))
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["focus"] == "pill:subtitles" }, barProbeText(app))
        for _ in 0..<3 { remote.press(.right) }
        XCTAssertTrue(waitBar(app) { $0["focus"] == "pill:aspect" }, barProbeText(app))
        var i = try XCTUnwrap(order.firstIndex(of: start))
        XCTAssertEqual(bar(app)["stored"], start, "the profile's resize mode is the start mode: \(barProbeText(app))")
        XCTAssertEqual(bar(app)["aw"], "0", barProbeText(app))
        let flash = app.descendants(matching: .any)["player.aspect.flash"]
        let gone = NSPredicate(format: "exists == false")
        func waitFlashClear(_ step: String) {
            XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: flash)],
                                            timeout: flashSec + 4), .completed, "flash did not clear (\(step))")
        }
        var writes = 0
        var stored = start

        // 1. One press, rest.
        remote.press(.select)
        i = (i + 1) % 4
        XCTAssertTrue(flash.waitForExistence(timeout: 3), "no aspect flash")
        XCTAssertTrue(waitBar(app) { $0["aspect"] == order[i] && $0["focus"] == "pill:aspect" }, barProbeText(app))
        XCTAssertEqual(bar(app)["aw"], "0", "written before the flash cleared: \(barProbeText(app))")
        waitFlashClear("step 1")
        writes += 1; stored = order[i]   // never Stretch: Stretch is fourth and never a start mode
        XCTAssertTrue(waitBar(app) { $0["stored"] == stored && $0["aw"] == String(writes) },
                      "the settled mode was not written once: \(barProbeText(app))")
        print("[AspectLeg] step1: \(barProbeText(app))")

        // 2. Three presses inside one flash, back to the start mode.
        for _ in 0..<3 {
            remote.press(.select)
            Thread.sleep(forTimeInterval: 0.5)
        }
        i = (i + 3) % 4
        XCTAssertEqual(order[i], start)
        XCTAssertTrue(waitBar(app) { $0["aspect"] == start }, "did not cycle back to \(start): \(barProbeText(app))")
        XCTAssertEqual(bar(app)["aw"], String(writes), "a mode passed through was written: \(barProbeText(app))")
        waitFlashClear("step 2")
        writes += 1; stored = start
        XCTAssertTrue(waitBar(app) { $0["stored"] == stored && $0["aw"] == String(writes) },
                      "the restore was not exactly one more write: \(barProbeText(app))")
        print("[AspectLeg] step2: \(barProbeText(app))")

        // 3. Rest on each mode up to Stretch, then one more press back to the start mode.
        repeat {
            remote.press(.select)
            i = (i + 1) % 4
            let mode = order[i]
            XCTAssertTrue(waitBar(app) { $0["aspect"] == mode }, barProbeText(app))
            waitFlashClear("step 3 \(mode)")
            let target = mode == "stretch" ? start : mode
            if target != stored { writes += 1; stored = target }
            XCTAssertTrue(waitBar(app) { $0["stored"] == stored && $0["aw"] == String(writes) },
                          "resting on \(mode): expected stored=\(stored) aw=\(writes): \(barProbeText(app))")
            print("[AspectLeg] step3 \(mode): \(barProbeText(app))")
        } while order[i] != "stretch"
        XCTAssertEqual(stored, start, "Stretch at rest must leave the profile on the start mode")
        remote.press(.select)
        i = (i + 1) % 4
        XCTAssertEqual(order[i], start)
        XCTAssertTrue(waitBar(app) { $0["aspect"] == start }, barProbeText(app))
        waitFlashClear("back to start")
        XCTAssertTrue(waitBar(app) { $0["stored"] == start && $0["aw"] == String(writes) },
                      "back on the start mode must write nothing: \(barProbeText(app))")
        print("[AspectLeg] end: \(barProbeText(app))")
    }

    /// C12 one-off: on a 4:3 source, Fit leaves black bars at the screen edges and Stretch
    /// (`video-aspect-override 16:9`) fills them; back to Fit restores the bars. Skips unless
    /// `PLAYER_SMOKE_ASPECT_URL` (a 4:3 file whose left edge is not black) is set.
    func testAspectStretchFillsOn43() throws {
        let url = ProcessInfo.processInfo.environment["PLAYER_SMOKE_ASPECT_URL"]
        try XCTSkipIf(url == nil, "PLAYER_SMOKE_ASPECT_URL not set: run with TEST_RUNNER_PLAYER_SMOKE_ASPECT_URL=<a 4:3 file>, e.g. http://127.0.0.1:8000/test-43.mkv")
        let app = try launchWithBarHidden(url: url)
        let order = ["fit", "fill", "zoom", "stretch"]
        let start = try XCTUnwrap(bar(app)["aspect"], barProbeText(app))
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, barProbeText(app))
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["focus"] == "pill:subtitles" }, barProbeText(app))
        for _ in 0..<3 { remote.press(.right) }
        XCTAssertTrue(waitBar(app) { $0["focus"] == "pill:aspect" }, barProbeText(app))
        var i = try XCTUnwrap(order.firstIndex(of: start))
        var lumas: [String: Double] = [:]
        if start == "fit" { Thread.sleep(forTimeInterval: 0.5); lumas["fit"] = edgeLuma() }
        for _ in 0..<4 {
            remote.press(.select)
            i = (i + 1) % 4
            XCTAssertTrue(waitBar(app) { $0["aspect"] == order[i] }, barProbeText(app))
            Thread.sleep(forTimeInterval: 0.8)
            lumas[order[i]] = edgeLuma()
        }
        XCTAssertEqual(bar(app)["aspect"], start, "not back at \(start)")
        // Let the last flash clear so the profile's resize mode settles back on the start (P2 #1).
        XCTAssertTrue(waitBar(app, timeout: 6) { $0["stored"] == start }, "profile left off \(start): \(barProbeText(app))")
        print("[AspectLeg] edge luma by mode: \(lumas)")
        XCTAssertLessThan(lumas["fit"] ?? 1, 0.05, "Fit should leave a black bar at the left edge of a 4:3 source")
        XCTAssertGreaterThan(lumas["stretch"] ?? 0, 0.15, "Stretch should fill the left edge")
    }

    /// Mean brightness (0…1) of a strip at 1–3 % of the screen width, 25–45 % of its height.
    private func edgeLuma() -> Double {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return -1 }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, n = 0.0
        for y in stride(from: h * 25 / 100, to: h * 45 / 100, by: 4) {
            for x in stride(from: w / 100, to: w * 3 / 100, by: 2) {
                let o = (y * w + x) * 4
                sum += (Double(px[o]) + Double(px[o + 1]) + Double(px[o + 2])) / (3 * 255)
                n += 1
            }
        }
        return n > 0 ? sum / n : -1
    }

    // MARK: Return from background (spec-mpv-return §5.3, legs M1 to M13)

    /// The process-wide ledger on the smoke host (`debug_mpvReturnLedger`): `mctl= mlast= mret= mcrit= mwrites= mfail=`.
    private func ledgerText(_ app: XCUIApplication) -> String {
        let el = app.descendants(matching: .any)["debug_mpvReturnLedger"]
        guard el.waitForExistence(timeout: 5) else { return "" }
        return el.label
    }

    private func ledger(_ app: XCUIApplication) -> [String: String] {
        var out: [String: String] = [:]
        for part in ledgerText(app).split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func ctl(_ p: [String: String]) -> Int { Int(p["ctl"] ?? "") ?? 0 }
    private func heldSec(_ p: [String: String]) -> Double? { p["held"].flatMap(Double.init) }
    private func posOf(_ p: [String: String]) -> Double { Double(p["pos"] ?? "") ?? -1 }

    /// The position in a ledger failure, `returnAlert(position(6.0))` -> 6.0.
    private func alertPosition(_ fail: String?) -> Double? {
        guard let fail, fail.hasPrefix("returnAlert(position("), let close = fail.firstIndex(of: ")") else { return nil }
        return Double(fail[fail.index(fail.startIndex, offsetBy: "returnAlert(position(".count)..<close])
    }

    /// A real background trip (Home, `awaySec` away, activate). The tvOS sim leaves the app in front on a
    /// Home press, so the Settings app is brought forward the way the Aether and native return legs do.
    private func realBackground(_ app: XCUIApplication, awaySec: TimeInterval) -> (ok: Bool, note: String) {
        var how = "Home"
        remote.press(.home)
        var left = Date().addingTimeInterval(8)
        while Date() < left, app.state == .runningForeground { Thread.sleep(forTimeInterval: 0.25) }
        if app.state == .runningForeground {
            how = "Settings app in front"
            XCUIApplication(bundleIdentifier: "com.apple.TVSettings").activate()
            left = Date().addingTimeInterval(15)
            while Date() < left, app.state == .runningForeground { Thread.sleep(forTimeInterval: 0.25) }
        }
        guard app.state != .runningForeground else { return (false, "still foreground after Home and after the Settings app") }
        Thread.sleep(forTimeInterval: awaySec)   // the time away itself, not an assertion
        app.activate()
        let back = Date().addingTimeInterval(20)
        while Date() < back, app.state != .runningForeground { Thread.sleep(forTimeInterval: 0.25) }
        guard app.state == .runningForeground else { return (false, "not foreground 20 s after activate") }
        return (true, how)
    }

    /// The DEBUG in-process cycle at a playhead position.
    private func cycle(atSec: Int, awaySec: Int) -> [String] {
        ["-debug.backgroundCycleAtSec", String(atSec), "-debug.backgroundCycleAwaySec", String(awaySec)]
    }

    /// Waits for the probe of a controller with serial >= `minCtl` in `phase`.
    private func waitReturn(_ app: XCUIApplication, minCtl: Int = 2, phase: String = "settled",
                            timeout: TimeInterval = 60) -> Bool {
        waitFor(app, timeout: timeout) { self.ctl($0) >= minCtl && $0["ret"] == phase }
    }

    /// The fresh controller first shows on the probe (`ctl >= minCtl`); returns that probe.
    private func waitFreshAppears(_ app: XCUIApplication, minCtl: Int = 2, timeout: TimeInterval = 60) -> [String: String]? {
        var seen: [String: String]?
        _ = waitFor(app, timeout: timeout) {
            if self.ctl($0) >= minCtl { seen = $0; return true }
            return false
        }
        return seen
    }

    /// After a settled return that must stay paused: still paused 2 s later, same place.
    private func assertStaysPaused(_ app: XCUIApplication, at held: Double, _ label: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 2.0)
        let p = probe(app)
        XCTAssertEqual(p["paused"], "1", "\(label): did not stay paused: \(probeText(app))", file: file, line: line)
        XCTAssertEqual(posOf(p), held, accuracy: 0.5, "\(label): the position moved while paused: \(probeText(app))", file: file, line: line)
    }

    /// Play from a paused return: advances >= 2 s from `held` and never plays from before it.
    private func assertPlaysFrom(_ app: XCUIApplication, held: Double, press: Bool = true, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        if press { remote.press(.playPause) }
        var lowest = Double.infinity
        XCTAssertTrue(waitFor(app, timeout: 20) {
            let p = self.posOf($0)
            if $0["paused"] == "0", p >= 0 { lowest = min(lowest, p) }
            return $0["paused"] == "0" && p >= held + 2
        }, "\(label): Play did not advance 2 s from \(held): \(probeText(app))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(lowest, held - 0.5, "\(label): played from before the held position: held=\(held) lowest=\(lowest)", file: file, line: line)
        XCTAssertTrue(app.otherElements["player.mpv"].exists, "\(label): mpv left", file: file, line: line)
    }

    private func reachSec(_ app: XCUIApplication, _ sec: Double) {
        XCTAssertTrue(waitFor(app, timeout: 40) { self.posOf($0) >= sec }, "never reached \(sec) s: \(probeText(app))")
    }

    /// M1 (rewrites T-UI-M1), real background 5 s while playing: one fresh controller, back PAUSED (although it
    /// was playing) within 0.5 s of its held position, the held position within ~2 s of the pre-Home one, and
    /// Play advances at least 2 s from held without ever playing from before it.
    func testMpvBackgroundReturnFreshControllerPaused() throws {
        let app = try launch()
        reachSec(app, 8)
        let p0 = pos(app)
        let trip = realBackground(app, awaySec: 5)
        XCTAssertTrue(trip.ok, "the simulator did not background and foreground the app: \(trip.note)")
        guard trip.ok else { return }
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 10), "mpv is gone after the return")
        XCTAssertFalse(app.otherElements["player.aether"].exists, "an Aether player appeared")
        XCTAssertFalse(app.otherElements["player.native"].exists, "a native player appeared")
        XCTAssertTrue(waitReturn(app), "the fresh controller never settled: p0=\(p0) \(probeText(app)) \(ledgerText(app))")
        let p = probe(app)
        print("[ReturnLeg] M1 (\(trip.note)) p0=\(p0) \(probeText(app)) \(ledgerText(app))")
        XCTAssertEqual(ctl(p), 2, "ctl did not change once: \(probeText(app))")
        XCTAssertEqual(ledger(app)["mctl"], "2", "not exactly two controllers: \(ledgerText(app))")
        XCTAssertEqual(p["paused"], "1", "the return came back playing: \(probeText(app))")
        let held = try XCTUnwrap(heldSec(p), "no held position: \(probeText(app))")
        XCTAssertEqual(held, p0, accuracy: 2.5, "held is not near the pre-Home position: p0=\(p0) \(probeText(app))")
        XCTAssertEqual(posOf(p), held, accuracy: 0.5, "pos is not within 0.5 s of held: \(probeText(app))")
        assertStaysPaused(app, at: held, "M1")
        assertPlaysFrom(app, held: held, "M1")
        XCTAssertEqual(ledger(app)["mctl"], "2", "a third controller appeared: \(ledgerText(app))")
    }

    /// M2: paused before Home (real background): a new controller, paused, the same position.
    func testMpvReturnWhilePausedStaysPausedAtTheSamePosition() throws {
        let app = try launch()
        reachSec(app, 6)
        remote.press(.playPause)
        XCTAssertTrue(waitFor(app, timeout: 6) { $0["paused"] == "1" }, "never paused: \(probeText(app))")
        Thread.sleep(forTimeInterval: 1.0)
        let p0 = pos(app)
        let trip = realBackground(app, awaySec: 4)
        XCTAssertTrue(trip.ok, "the simulator did not background and foreground the app: \(trip.note)")
        guard trip.ok else { return }
        XCTAssertTrue(waitReturn(app), "the fresh controller never settled: \(probeText(app)) \(ledgerText(app))")
        let p = probe(app)
        print("[ReturnLeg] M2 p0=\(p0) \(probeText(app))")
        XCTAssertEqual(ctl(p), 2, "no new controller: \(probeText(app))")
        XCTAssertEqual(p["paused"], "1", "not paused: \(probeText(app))")
        XCTAssertEqual(p["intent"], "pause", "the intent is not pause: \(probeText(app))")
        XCTAssertEqual(posOf(p), p0, accuracy: 0.5, "not the same position: p0=\(p0) \(probeText(app))")
        XCTAssertEqual(heldSec(p) ?? -1, p0, accuracy: 0.5, "held is not the paused position: \(probeText(app))")
        assertStaysPaused(app, at: posOf(p), "M2")
    }

    /// M3: Play 0.5 s after the fresh controller appears: it plays, once, from held (no sample of the fresh controller
    /// ever plays from before held). The probe's `intent=` field is not asserted: it lags the press by one
    /// (see the report), the behaviour is what counts.
    func testMpvPlayAfterReturnPlaysOnceFromHeld() throws {
        let app = try launch(extra: cycle(atSec: 8, awaySec: 3))
        let fresh = waitFreshAppears(app)
        XCTAssertNotNil(fresh, "the fresh controller never appeared: \(probeText(app))")
        Thread.sleep(forTimeInterval: 0.5)
        remote.press(.playPause)
        var lowest = Double.infinity
        var held: Double?
        var pauses = 0
        var wasPlaying = false
        XCTAssertTrue(waitFor(app, timeout: 60) {
            guard self.ctl($0) >= 2 else { return false }
            if let h = self.heldSec($0) { held = h }
            let playing = $0["paused"] == "0"
            if playing, self.posOf($0) >= 0 { lowest = min(lowest, self.posOf($0)) }
            if wasPlaying, !playing { pauses += 1 }
            wasPlaying = playing
            return $0["ret"] == "settled" && playing && self.posOf($0) >= (held ?? 0) + 2
        }, "the fresh controller never played on from held: \(probeText(app)) \(ledgerText(app))")
        print("[ReturnLeg] M3 held=\(held ?? -1) lowest=\(lowest) pauses=\(pauses) \(probeText(app))")
        let h = try XCTUnwrap(held, "no held position")
        XCTAssertGreaterThanOrEqual(lowest, h - 0.5, "the fresh controller played from before held: held=\(h) lowest=\(lowest)")
        XCTAssertEqual(pauses, 0, "it paused again after playing")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(probe(app)["paused"], "0", "the player paused again: \(probeText(app))")
        XCTAssertEqual(ledger(app)["mctl"], "2", "a third controller appeared: \(ledgerText(app))")
    }

    /// M4: Play then Pause during the fresh start: it ends paused at held.
    func testMpvPlayThenPauseDuringStartEndsPaused() throws {
        let app = try launch(extra: cycle(atSec: 8, awaySec: 3))
        XCTAssertNotNil(waitFreshAppears(app), "the fresh controller never appeared: \(probeText(app))")
        remote.press(.playPause)
        Thread.sleep(forTimeInterval: 0.25)
        remote.press(.playPause)
        XCTAssertTrue(waitReturn(app, timeout: 40), "the fresh controller never settled: \(probeText(app)) \(ledgerText(app))")
        let p = probe(app)
        print("[ReturnLeg] M4 \(probeText(app))")
        let held = try XCTUnwrap(heldSec(p), "no held position: \(probeText(app))")
        XCTAssertEqual(p["paused"], "1", "Play then Pause did not end paused: \(probeText(app))")
        XCTAssertEqual(posOf(p), held, accuracy: 0.5, "not at held: \(probeText(app))")
        assertStaysPaused(app, at: held, "M4")
    }

    /// M5: the cycle runs right after the load is issued (`loadIssued`), 40 s away, on an auto-play launch with
    /// a 15 s start-up limit and the return alert armed, saved resume 120: no limit fire, no failure, the fresh
    /// controller settles paused at the resume point.
    func testMpvReturnDuringLoadWithStartupLimitSettlesAtResume() throws {
        let app = try launch(extra: ["-debug.backgroundCycleAtStage", "loadIssued", "-debug.backgroundCycleAwaySec", "40",
                                     "-debug.mpvSmokeLaunchSource", "autoPlay", "-debug.mpvSmokeStartupLimitSec", "15",
                                     "-debug.mpvSmokeReturnAlert", "YES", "-debug.mpvSmokeResumeSec", "120"],
                             waitForPlay: false)
        XCTAssertTrue(waitReturn(app, timeout: 150), "the fresh controller never settled: \(probeText(app)) \(ledgerText(app))")
        let p = probe(app)
        let l = ledger(app)
        print("[ReturnLeg] M5 \(probeText(app)) \(ledgerText(app))")
        XCTAssertEqual(l["mfail"], "none", "a failure or the start-up limit fired: \(ledgerText(app))")
        XCTAssertEqual(ctl(p), 2, "not the second controller: \(probeText(app))")
        XCTAssertEqual(p["paused"], "1", "not paused: \(probeText(app))")
        XCTAssertEqual(posOf(p), 120, accuracy: 0.5, "not at the resume point: \(probeText(app))")
        XCTAssertTrue(app.otherElements["player.mpv"].exists, "mpv left")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(ledger(app)["mfail"], "none", "a failure came late: \(ledgerText(app))")
    }

    /// `failFreshStart` reports 1.5 s after the fresh controller's load, and only counts as a return failure while the
    /// start has not settled. On the simulator with a local file the fresh start settles in under 1.5 s, so the report
    /// is not a return failure (`mfail=other`, no alert): these legs need a start slower than that, a fixture URL behind
    /// a delaying server (`PLAYER_SMOKE_SLOWSTART_URL`; the gate does not provide one, so they skip without it).
    private func slowStartURL() throws -> String {
        guard let url = ProcessInfo.processInfo.environment["PLAYER_SMOKE_SLOWSTART_URL"], !url.isEmpty else {
            throw XCTSkip("PLAYER_SMOKE_SLOWSTART_URL not set: failFreshStart fires 1.5 s after the load and the local fixture settles first")
        }
        return url
    }

    /// Waits for the host's return alert and reads the held position from it.
    private func waitReturnAlert(_ app: XCUIApplication, _ label: String) throws -> Double {
        var fail: String?
        let end = Date().addingTimeInterval(60)
        while Date() < end {
            if let f = ledger(app)["mfail"], f != "none" { fail = f; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("[ReturnLeg] \(label) ledger \(ledgerText(app))")
        return try XCTUnwrap(alertPosition(fail), "\(label): no return alert with a position: mfail=\(fail ?? "nil") \(ledgerText(app))")
    }

    /// The retry player (the third controller serial) starts at `x`: its first position is within 0.5 s of `x`, it never
    /// shows an earlier one, and it plays. The DEBUG position cycle re-fires on the retry (it starts at or past the
    /// trigger and has no payload), so later controllers are not looked at.
    private func assertRetryStartsAt(_ app: XCUIApplication, x: Double, _ label: String) {
        var first = -1.0
        var lowest = Double.infinity
        var playing = false
        let end = Date().addingTimeInterval(40)
        var lastSeen = Date.distantFuture
        while Date() < end {
            let p = probe(app)
            if ctl(p) == 3, posOf(p) > 1 {
                if first < 0 { first = posOf(p); lastSeen = Date() }
                lowest = min(lowest, posOf(p))
                if p["paused"] == "0" { playing = true }
            }
            if first >= 0, playing || Date().timeIntervalSince(lastSeen) > 4 { break }
            Thread.sleep(forTimeInterval: 0.15)
        }
        print("[ReturnLeg] \(label) retry x=\(x) first=\(first) lowest=\(lowest) playing=\(playing) \(probeText(app))")
        XCTAssertGreaterThan(first, 0, "\(label): the retry player never showed a position: \(probeText(app))")
        XCTAssertEqual(first, x, accuracy: 0.5, "\(label): the retry did not start at the held position \(x): first=\(first)")
        XCTAssertGreaterThanOrEqual(lowest, x - 0.5, "\(label): the retry played from before \(x): lowest=\(lowest)")
        XCTAssertTrue(playing, "\(label): the retry did not play: \(probeText(app))")
    }

    private func failFreshStartLeg(source: String, cycleAt: Int, label: String) throws {
        let app = try launch(url: slowStartURL(), extra: cycle(atSec: cycleAt, awaySec: 3) + ["-debug.mpvReturnFault", "failFreshStart",
                                                                                           "-debug.mpvSmokeReturnAlert", "YES",
                                                                                           "-debug.mpvSmokeLaunchSource", source])
        let x = try waitReturnAlert(app, label)
        assertRetryStartsAt(app, x: x, label)
    }

    /// M6 (auto-play): `failFreshStart`: the alert (no picker redirect) and the retry from held.
    func testMpvFreshStartFailureRetriesAtHeldAutoPlay() throws { try failFreshStartLeg(source: "autoPlay", cycleAt: 12, label: "M6 autoPlay") }

    /// M6 (next-episode context).
    func testMpvFreshStartFailureRetriesAtHeldNextEpisode() throws { try failFreshStartLeg(source: "nextEpisode", cycleAt: 12, label: "M6 nextEpisode") }

    /// M6b: `failFreshStart` with held about 6 s: the retry resumes at about 6 s, not at 0 or at saved progress.
    func testMpvFreshStartFailureRetryResumesAtShortHeld() throws {
        let app = try launch(url: slowStartURL(), extra: cycle(atSec: 6, awaySec: 3) + ["-debug.mpvReturnFault", "failFreshStart",
                                                                                     "-debug.mpvSmokeReturnAlert", "YES",
                                                                                     "-debug.mpvSmokeLaunchSource", "autoPlay"])
        let x = try waitReturnAlert(app, "M6b")
        XCTAssertTrue((5.5...9.5).contains(x), "the held position is not about 6 s: \(x)")
        assertRetryStartsAt(app, x: x, "M6b")
    }

    /// M7: `stuckOldQueue`: the old controller's queue never answers; the fresh controller still settles promptly.
    func testMpvStuckOldQueueStillSettlesPromptly() throws {
        let app = try launch(extra: cycle(atSec: 8, awaySec: 3) + ["-debug.mpvReturnFault", "stuckOldQueue"])
        let began = Date()
        XCTAssertTrue(waitReturn(app, timeout: 60), "the fresh controller never settled: \(probeText(app)) \(ledgerText(app))")
        let p = probe(app)
        print("[ReturnLeg] M7 settled after \(Date().timeIntervalSince(began)) s \(probeText(app))")
        XCTAssertEqual(ctl(p), 2, "not the second controller: \(probeText(app))")
        XCTAssertEqual(p["paused"], "1", "not paused: \(probeText(app))")
        let held = try XCTUnwrap(heldSec(p), "no held position")
        XCTAssertEqual(posOf(p), held, accuracy: 0.5, "not at held: \(probeText(app))")
        XCTAssertEqual(ledger(app)["mctl"], "2", "not exactly two controllers: \(ledgerText(app))")
    }

    /// M8: Menu right after the fresh controller appears: the player closes, one fresh controller, criteria cleared.
    func testMpvMenuRightAfterReturnClosesAndClearsCriteria() throws {
        let app = try launch(extra: cycle(atSec: 8, awaySec: 3))
        XCTAssertNotNil(waitFreshAppears(app), "the fresh controller never appeared: \(probeText(app))")
        for _ in 0..<4 where app.otherElements["player.mpv"].exists {
            remote.press(.menu)
            Thread.sleep(forTimeInterval: 1.5)
        }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.otherElements["player.mpv"])
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "Menu never closed the player: \(ledgerText(app))")
        Thread.sleep(forTimeInterval: 1.5)
        let l = ledger(app)
        print("[ReturnLeg] M8 \(ledgerText(app))")
        XCTAssertEqual(l["mctl"], "2", "not exactly two controllers: \(ledgerText(app))")
        XCTAssertEqual(l["mcrit"], "0", "display criteria were not cleared: \(ledgerText(app))")
    }

    /// M9: two cycles 2 s apart: the second return lands during the first fresh start; one settle, at the first
    /// held position.
    func testMpvSecondReturnDuringFreshStartSettlesAtFirstHeld() throws {
        let app = try launch(extra: cycle(atSec: 8, awaySec: 3) + ["-debug.backgroundCycleSecondAfterSec", "2"])
        var firstHeld: Double?
        var parkedPos: Double?
        XCTAssertTrue(waitFor(app, timeout: 90) {
            if self.ctl($0) == 1, $0["ret"] == "parked" { parkedPos = self.posOf($0) }
            if self.ctl($0) == 2, let h = self.heldSec($0) { firstHeld = h }
            return self.ctl($0) >= 3 && $0["ret"] == "settled"
        }, "no settle on the third controller: \(probeText(app)) \(ledgerText(app))")
        let p = probe(app)
        print("[ReturnLeg] M9 parked=\(parkedPos ?? -1) firstHeld=\(firstHeld ?? -1) \(probeText(app)) \(ledgerText(app))")
        XCTAssertEqual(ctl(p), 3, "not the third controller: \(probeText(app))")
        XCTAssertEqual(ledger(app)["mctl"], "3", "not exactly three controllers: \(ledgerText(app))")
        let held = try XCTUnwrap(heldSec(p), "no held position")
        let ref = try XCTUnwrap(firstHeld ?? parkedPos, "never observed the first held position or the park")
        XCTAssertEqual(held, ref, accuracy: 0.5, "the second return did not settle at the first held position: first=\(ref) \(probeText(app))")
        XCTAssertEqual(posOf(p), held, accuracy: 0.5, "pos is not at held: \(probeText(app))")
        XCTAssertEqual(p["paused"], "1", "not paused: \(probeText(app))")
    }

    /// M10: user-picked audio plus an embedded subtitle survive a return. Needs a fixture with two audio tracks and an
    /// embedded subtitle; the gate's mpv fixtures have one audio track and no subtitles.
    func testMpvReturnKeepsAudioAndEmbeddedSubtitlePicks() throws {
        throw XCTSkip("M10: no fixture with two audio tracks and an embedded subtitle on the mpv route (test-long.mkv has one AAC track and none)")
    }

    /// Opens the Subtitles popover from a bar that may already be showing (a paused return keeps it up): Up until a
    /// disc has focus, Right to Subtitles, Select. Returns the row of the "Smoke EN" add-on subtitle.
    private func smokeRow(_ app: XCUIApplication) -> XCUIElement {
        for _ in 0..<4 where !(PlayerChrome.probe(app, "debug_transportProbe")["focus"] ?? "").hasPrefix("pill:") {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.6)
        }
        for _ in 0..<8 where PlayerChrome.probe(app, "debug_transportProbe")["focus"] != "pill:subtitles" {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertEqual(PlayerChrome.probe(app, "debug_transportProbe")["focus"], "pill:subtitles", "never reached the subtitles disc")
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["player.popover.subtitles"].waitForExistence(timeout: 6), "subtitles popover did not open")
        Thread.sleep(forTimeInterval: 1.0)
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'player.panel.subtitle.' AND NOT identifier BEGINSWITH 'player.panel.subtitleDelay' AND label CONTAINS 'Smoke EN'"))
            .firstMatch
    }

    private func closeSubtitlePopover(_ app: XCUIApplication) {
        remote.press(.menu)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.descendants(matching: .any)["player.popover.subtitles"])
        _ = XCTWaiter().wait(for: [closed], timeout: 4)
    }

    /// M10b: a user-picked add-on subtitle is selected again once the side-load lands after the return
    /// (`-debug.subtitleSideLoadDelaySec 5`).
    func testMpvReturnKeepsAddonSubtitlePickAfterSideLoad() throws {
        let sub = try XCTUnwrap(ProcessInfo.processInfo.environment["PLAYER_SMOKE_SUB_URL"], "PLAYER_SMOKE_SUB_URL not set")
        let app = try launch(extra: ["-debug.mpvSmokeSubtitleURL", sub, "-debug.subtitleSideLoadDelaySec", "5"])
        XCTAssertTrue(waitFor(app, timeout: 30) { self.posOf($0) > 3 })
        var row = smokeRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Smoke EN row")
        XCTAssertTrue(PlayerChrome.focusWalk(app, to: row), "focus never reached the Smoke EN row")
        remote.press(.select)
        let pickEnd = Date().addingTimeInterval(8)
        while Date() < pickEnd, (row.value as? String) != "selected" { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertEqual(row.value as? String, "selected", "Smoke EN not selected before the return")
        closeSubtitlePopover(app)
        Thread.sleep(forTimeInterval: 1)
        let trip = realBackground(app, awaySec: 3)
        XCTAssertTrue(trip.ok, trip.note)
        guard trip.ok else { return }
        XCTAssertTrue(waitReturn(app, timeout: 60), "the fresh controller never settled: \(probeText(app))")
        row = smokeRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Smoke EN row after the return")
        let end = Date().addingTimeInterval(25)
        while Date() < end, (row.value as? String) != "selected" { Thread.sleep(forTimeInterval: 0.5) }
        print("[ReturnLeg] M10b selected=\(String(describing: row.value)) \(probeText(app))")
        XCTAssertEqual(row.value as? String, "selected", "the add-on subtitle pick was not restored after the side-load")
    }

    /// M10b variant: the fresh controller loads none of the stream's own subtitle files: the pick falls to automatic
    /// at the deadline and nothing is selected; the player keeps going.
    func testMpvReturnAddonSubtitleMissFallsToAuto() throws {
        let sub = try XCTUnwrap(ProcessInfo.processInfo.environment["PLAYER_SMOKE_SUB_URL"], "PLAYER_SMOKE_SUB_URL not set")
        let app = try launch(extra: ["-debug.mpvSmokeSubtitleURL", sub, "-debug.mpvReturnDropExternalSubs", "YES"])
        XCTAssertTrue(waitFor(app, timeout: 30) { self.posOf($0) > 3 })
        let row = smokeRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Smoke EN row")
        XCTAssertTrue(PlayerChrome.focusWalk(app, to: row), "focus never reached the Smoke EN row")
        remote.press(.select)
        let pickEnd = Date().addingTimeInterval(8)
        while Date() < pickEnd, (row.value as? String) != "selected" { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertEqual(row.value as? String, "selected", "Smoke EN not selected before the return")
        closeSubtitlePopover(app)
        Thread.sleep(forTimeInterval: 1)
        let trip = realBackground(app, awaySec: 3)
        XCTAssertTrue(trip.ok, trip.note)
        guard trip.ok else { return }
        XCTAssertTrue(waitReturn(app, timeout: 60), "the fresh controller never settled: \(probeText(app))")
        Thread.sleep(forTimeInterval: 24)   // past the 20 s pending-pick deadline
        let after = smokeRow(app)
        let present = after.waitForExistence(timeout: 5)
        let value = present ? (after.value as? String) : nil
        print("[ReturnLeg] M10b-miss row present=\(present) value=\(value ?? "-") \(probeText(app))")
        XCTAssertNotEqual(value, "selected", "the missing add-on subtitle is still shown as selected")
        XCTAssertTrue(app.otherElements["player.mpv"].exists, "mpv left")
    }

    /// M12: the identity changes at park (`beforeHome`) or right after it (`away`): the player exits and nothing is
    /// written after the park.
    private func ownerFlipLeg(_ mode: String) throws {
        let app = try launch(extra: cycle(atSec: 8, awaySec: 3) + ["-debug.ownerFlip", mode])
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.otherElements["player.mpv"])
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 60), .completed, "\(mode): the player did not exit: \(probeText(app)) \(ledgerText(app))")
        Thread.sleep(forTimeInterval: 2)
        let l = ledger(app)
        print("[ReturnLeg] M12 \(mode) \(ledgerText(app))")
        XCTAssertEqual(l["mwrites"], "0", "\(mode): a write happened after the park: \(ledgerText(app))")
        XCTAssertEqual(l["mctl"], "1", "\(mode): a fresh controller was made: \(ledgerText(app))")
    }

    func testMpvOwnerFlipBeforeHomeExitsWithoutWrites() throws { try ownerFlipLeg("beforeHome") }
    func testMpvOwnerFlipWhileAwayExitsWithoutWrites() throws { try ownerFlipLeg("away") }

    /// M13: a live HLS stream returns paused, and the forced reconnect (`-debug.liveForceEOFAtSec`) leaves it
    /// paused. Needs `scripts/device/fixtures/live-hls-fixture.py` served (its segments generated first); pass its
    /// playlist as `TEST_RUNNER_LIVE_HLS_URL`.
    func testMpvLiveReturnPausedAndReconnectStaysPaused() throws {
        guard let live = ProcessInfo.processInfo.environment["LIVE_HLS_URL"], !live.isEmpty else {
            throw XCTSkip("LIVE_HLS_URL not set (needs scripts/device/fixtures/live-hls-fixture.py running; pass TEST_RUNNER_LIVE_HLS_URL)")
        }
        let app = try launch(url: live, extra: cycle(atSec: 6, awaySec: 3) + ["-debug.liveForceEOFAtSec", "4"])
        XCTAssertTrue(waitReturn(app, timeout: 60), "the live return never settled: \(probeText(app)) \(ledgerText(app))")
        XCTAssertEqual(probe(app)["paused"], "1", "the live return came back playing: \(probeText(app))")
        Thread.sleep(forTimeInterval: 8)   // past the forced reconnect
        let p = probe(app)
        print("[ReturnLeg] M13 \(probeText(app))")
        XCTAssertEqual(p["paused"], "1", "the reconnect resumed a paused live stream: \(probeText(app))")
        XCTAssertTrue(app.otherElements["player.mpv"].exists, "mpv left")
    }
}
