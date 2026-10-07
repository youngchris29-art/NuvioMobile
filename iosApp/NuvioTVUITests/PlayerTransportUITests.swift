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
    private func launch(url fixture: String? = nil, extra: [String] = []) throws -> XCUIApplication {
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

    /// A 150 pt downward stroke (decided at 120 pt) opens the top panel on Info.
    func testVerticalSwipeOpensPanel() throws {
        let script = Array(repeating: "0,0.03,30", count: 5).joined(separator: ";")
        let app = try launchWithBarHidden(extra: ["-debug.scrubInject", script])
        raiseBarForScrub(app)
        postScrubInject()
        let tab = app.descendants(matching: .any)["player.panel.tab.info"]
        XCTAssertTrue(tab.waitForExistence(timeout: 6), "info tab did not open")
        XCTAssertEqual(tab.value as? String, "selected")
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

    // MARK: Chapters and aspect (P2-C)

    /// The chapters fixture (five chapters at 0/90/240/390/540 s); skips when unset.
    private func chaptersURL() throws -> String {
        let url = ProcessInfo.processInfo.environment["PLAYER_SMOKE_CHAPTERS_URL"]
        try XCTSkipIf(url == nil, "PLAYER_SMOKE_CHAPTERS_URL not set: run with TEST_RUNNER_PLAYER_SMOKE_CHAPTERS_URL=http://127.0.0.1:8000/test-long-chapters.mkv")
        return url!
    }

    /// The bar draws one tick per chapter; the probe counts what it was given.
    func testChapterTicksProbe() throws {
        let app = try launch(url: try chaptersURL())
        XCTAssertTrue(waitBar(app, timeout: 10) { $0["chapters"] == "5" }, "chapters never reached 5: \(barProbeText(app))")
        print("[ChapterLeg] ticks: \(barProbeText(app))")
    }

    /// Down opens the panel; the Chapters tab is last; its third row seeks to 240 s and closes the panel.
    func testChaptersTabSeeks() throws {
        let app = try launchWithBarHidden(url: try chaptersURL())
        XCTAssertTrue(waitBar(app) { $0["chapters"] == "5" }, barProbeText(app))
        let c0 = Int(probe(app)["commits"] ?? "") ?? -1
        remote.press(.down)
        let chaptersTab = app.descendants(matching: .any)["player.panel.tab.chapters"]
        XCTAssertTrue(chaptersTab.waitForExistence(timeout: 6), "no Chapters tab")
        for _ in 0..<6 where (chaptersTab.value as? String) != "selected" {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(chaptersTab.value as? String, "selected", "never reached the Chapters tab")
        let row = app.descendants(matching: .any)["player.panel.chapter.2"]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "no chapter row 2")
        XCTAssertTrue(row.label.contains("Act Two"), row.label)
        XCTAssertEqual(app.descendants(matching: .any)["player.panel.chapter.0"].value as? String, "selected",
                       "the current chapter (Opening) is not ticked")
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
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: chaptersTab)], timeout: 5),
                       .completed, "panel did not close")
        XCTAssertTrue(waitFor(app, timeout: 8) { (Double($0["pos"] ?? "") ?? 0) >= 239 }, "never landed at 240: \(probeText(app))")
        print("[ChapterLeg] tab seek: \(probeText(app)) | \(barProbeText(app))")

        // Review r2 P3 #4: re-opened mid-file, the tab ticks Act Two and one Down into the list
        // lands on it (the list's default focus), not on the first row.
        XCTAssertTrue(waitBar(app, timeout: 8) { $0["vis"] == "0" }, "bar never hid: \(barProbeText(app))")
        remote.press(.down)
        XCTAssertTrue(chaptersTab.waitForExistence(timeout: 6), "panel did not re-open")
        for _ in 0..<6 where (chaptersTab.value as? String) != "selected" {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(chaptersTab.value as? String, "selected", "never reached the Chapters tab again")
        XCTAssertTrue(row.waitForExistence(timeout: 3), "no chapter row 2 on re-open")
        XCTAssertEqual(row.value as? String, "selected", "the current chapter (Act Two) is not ticked")
        let first = app.descendants(matching: .any)["player.panel.chapter.0"]
        XCTAssertFalse(row.hasFocus, "a list row is focused before entering the list")
        remote.press(.down)
        // Wait for the focus to land rather than sleeping a fixed 0.8 s (review r3 P3 #3).
        let landed = Date()
        while !row.hasFocus && Date().timeIntervalSince(landed) < 4 { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(row.hasFocus, "focus did not enter the list on the current chapter (row 2)")
        XCTAssertFalse(first.hasFocus, "focus entered the list on the first row, not the current chapter")
        print("[ChapterLeg] tab end: \(probeText(app)) | \(barProbeText(app))")
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
}
