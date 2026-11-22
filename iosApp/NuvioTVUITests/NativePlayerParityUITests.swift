import XCTest
import UIKit

/// P4 native-engine parity legs (spec `docs/research/player-p4-spec-native-parity.md` §10.2).
///
/// Native legs launch the real `PlayerScreen` through the mpv smoke rig with
/// `-debug.mpvSmokeEngine native`, which sets `PlaybackContext.forcedEngine = .native`: the probe
/// and the silent fallback are skipped, so a leg can never quietly pass on mpv. They read the DEBUG
/// `debug_nativeProbe` label (`pos= speed= paused= bar= card= stage= chapters= subs= late=`).
/// Gated on `PLAYER_NATIVE_PROBE=1` and `PLAYER_SMOKE_URL` (pass them as `TEST_RUNNER_*`).
///
/// The mpv regression leg uses the P1 transport harness (`PLAYER_BAR_PROBE=1`).
///
/// Insights wave 2a: the swipe-down top panel is gone from both engines. The native route now uses
/// the system `AVPlayerViewController` info pills (Info / Cast / Up Next, behind the system swipe
/// down) and round `transportBarCustomMenuItems` (Episodes, Sources, Subtitle Timing, Sync Line,
/// Remember Speed) whose popovers are system UI. XCUITest on the simulator cannot issue the swipe
/// down or drive those popovers, so the panel-driven native legs (speed tab, sources column, chapters
/// tab, late-subtitle pick) were removed; they are device-pass items, with the pure logic in
/// `NativePlayerChromeTests`. What the sim can prove is kept: the custom items exist, the model
/// still receives chapters and the late rendition, the pause card, and the loading overlay.
class NativePlayerParityUITests: XCTestCase {
    let remote = XCUIRemote.shared

    // MARK: Environment

    /// harness-w4 (2026-10-23): a `TEST_RUNNER_*` variable this leg needs, or an `XCTSkip` when it is
    /// absent or empty. `XCTUnwrap` FAILED the legs on a runner that never set it (first full run,
    /// 2026-10-22: testNativeChaptersTab and testNativeLateSubtitleLazyPick read their URL before
    /// the `PLAYER_NATIVE_PROBE` gate): an unset rig is an environment choice, not a regression.
    func requiredEnv(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("\(key) not set (pass it as TEST_RUNNER_\(key))")
        }
        return value
    }

    // MARK: Native harness

    /// Launches the smoke rig on the native engine and waits until playback has started.
    func launchNative(url fixture: String? = nil, extra: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_NATIVE_PROBE"] == "1", "PLAYER_NATIVE_PROBE not set")
        let url = try fixture ?? requiredEnv("PLAYER_SMOKE_URL")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "YES",
                                "-debug.mpvSmokeEngine", "native", "-debug.mpvSmokeStartOver", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.otherElements["player.native"].waitForExistence(timeout: 40), "native player did not appear")
        XCTAssertTrue(waitNative(app, timeout: 40) { (Double($0["pos"] ?? "") ?? 0) > 1 },
                      "native playback never started: \(nativeProbeText(app))")
        return app
    }

    func nativeProbeText(_ app: XCUIApplication) -> String {
        let el = app.descendants(matching: .any)["debug_nativeProbe"]
        guard el.waitForExistence(timeout: 5) else { return "" }
        return el.label
    }

    func nativeProbe(_ app: XCUIApplication) -> [String: String] {
        Self.parse(nativeProbeText(app))
    }

    func waitNative(_ app: XCUIApplication, timeout: TimeInterval = 5, _ cond: ([String: String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(nativeProbe(app)) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return cond(nativeProbe(app))
    }

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in text.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    // MARK: Shared helpers

    func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// Geometric focus walk: presses Down/Up/Left/Right toward `target` until it has focus.
    /// Never presses Up from a row level with or above the target (that would leave the content
    /// section for the tab row).
    @discardableResult
    func focusWalk(_ app: XCUIApplication, to target: XCUIElement, maxSteps: Int = 24) -> Bool {
        for _ in 0..<maxSteps {
            if target.hasFocus { return true }
            let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
            guard focused.exists else { remote.press(.down); Thread.sleep(forTimeInterval: 0.4); continue }
            let f = focused.frame, t = target.frame
            if f.midY < t.minY - 4 {
                remote.press(.down)
            } else if f.midY > t.maxY + 4 {
                remote.press(.up)
            } else if f.midX < t.midX {
                remote.press(.right)
            } else {
                remote.press(.left)
            }
            Thread.sleep(forTimeInterval: 0.45)
        }
        return target.hasFocus
    }

    // MARK: mpv regression (A step 1)

    /// Regression only: the mpv Speed popover keeps its speed row, Audio Delay and Stream Info after
    /// the columns moved into `PlayerPlaybackColumns.swift` and the Playback tab became a disc
    /// popover. Picking 1.25 marks that button selected.
    func testMpvSpeedPopoverUnchanged() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_BAR_PROBE"] == "1", "PLAYER_BAR_PROBE not set")
        let url = try requiredEnv("PLAYER_SMOKE_URL")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "NO",
                                "-player.bufferMB", "8", "-debug.mpvSmokeStartOver", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 30), "player did not appear")
        // Same start gate as the P1 harness: playback has really started (pos > 1).
        let seek = element(app, "debug_seekProbe")
        XCTAssertTrue(seek.waitForExistence(timeout: 30), "no seek probe")
        let started = Date().addingTimeInterval(30)
        while Date() < started, (Double(Self.parse(seek.label)["pos"] ?? "") ?? 0) <= 1 { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertGreaterThan(Double(Self.parse(seek.label)["pos"] ?? "") ?? 0, 1, "playback never started: \(seek.label)")
        let bar = element(app, "debug_transportProbe")
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "no transport probe")
        let end = Date().addingTimeInterval(20)
        while Date() < end, Self.parse(bar.label)["vis"] != "0" { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertEqual(Self.parse(bar.label)["vis"], "0", "bar never hid: \(bar.label)")

        PlayerChrome.openDisc(app, "speed")
        for speed in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0] {
            XCTAssertTrue(element(app, "player.panel.speed.\(speed)").waitForExistence(timeout: 3), "no speed \(speed)")
        }
        XCTAssertTrue(element(app, "player.panel.diagnostics").exists, "no Diagnostics row")
        XCTAssertTrue(app.staticTexts["Audio Delay"].exists, "no Audio Delay row")
        XCTAssertEqual(element(app, "player.panel.speed.1.0").value as? String, "selected", "1x is not ticked")
        let target = element(app, "player.panel.speed.1.25")
        XCTAssertTrue(focusWalk(app, to: target), "focus never reached 1.25x")
        remote.press(.select)
        let end2 = Date().addingTimeInterval(4)
        while Date() < end2, (target.value as? String) != "selected" { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertEqual(target.value as? String, "selected", "1.25x not selected after the pick")
        print("[ParityLeg] mpv speed popover: \(seek.label) | \(bar.label)")
    }

    // MARK: Native legs (A step 6)

    /// Lets the start-of-playback transport bar hide (or gives up after `timeout`), so a Down
    /// press starts from the same state the viewer usually has.
    func waitBarSettled(_ app: XCUIApplication, timeout: TimeInterval = 10) {
        _ = waitNative(app, timeout: timeout) { $0["bar"] == "0" }
    }

    /// D5: the transport bar's custom round buttons exist next to the system speed pill. Their
    /// popovers (Sources list, Episodes, Subtitle Timing) are system UI the simulator cannot drive:
    /// opening them is a device-pass item. Select on the first custom item must at least leave the player running.
    func testNativeTransportMenuItemsExist() throws {
        let app = try launchNative()
        waitBarSettled(app)
        remote.press(.select)                       // raise the bar
        XCTAssertTrue(waitNative(app, timeout: 4) { $0["bar"] == "1" }, "bar did not show: \(nativeProbeText(app))")
        // tvOS 26 draws the custom menu items as cells in the bar's top-right row, left of the
        // speed pill and the Subtitles / Audio cells. Review r3: each round button now carries its
        // name as `accessibilityLabel` (Sources, Episodes, Subtitle Timing, Sync Line, Remember
        // Speed for This Show), so they are found by name. If this simulator's AVKit still exposes
        // the cells with an empty label (the wave 2a reading), the leg falls back to counting the
        // empty-label cells and logs it; the device pass confirms VoiceOver reads the names.
        XCTAssertTrue(app.cells["Playback Speed"].waitForExistence(timeout: 5), "no system speed pill (playerVC.speeds)")
        let names = ["Sources", "Episodes", "Subtitle Timing", "Sync Line", "Remember Speed for This Show"]
        let named = app.cells.matching(NSPredicate(format: "label IN %@", names))
        let custom: XCUIElementQuery
        if named.count > 0 {
            custom = named
            let labels = named.allElementsBoundByIndex.map(\.label)
            XCTAssertTrue(labels.contains("Sources"), "no Sources button by name: \(labels)")
            print("[ParityLeg] native custom items by name: \(labels)")
        } else {
            custom = app.cells.matching(NSPredicate(format: "label == ''"))
            print("[ParityLeg] native custom items expose no label on this sim; counted by empty label")
        }
        XCTAssertGreaterThanOrEqual(custom.count, 1, "no custom transport items beside the system pills")
        let first = custom.element(boundBy: 0)
        for _ in 0..<4 where !first.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.6)
        }
        XCTAssertTrue(first.hasFocus || focusWalk(app, to: first, maxSteps: 8), "focus never reached a custom item")
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.otherElements["player.native"].exists, "the native player left after Select on a custom item")
        XCTAssertFalse(element(app, "player.panel").exists, "an app-drawn panel appeared on native")
        print("[ParityLeg] native custom items=\(custom.count)")
        print("[ParityLeg] native menu items: \(nativeProbeText(app))")
    }

    /// B16: the pause card never draws over a visible transport bar; once the bar is known hidden
    /// while paused it shows within 2 s, and one press hides it. If the simulator's bar never hides
    /// while paused, the leg skips (it must not pass vacuously, [C-19]).
    func testNativePauseCard() throws {
        let app = try launchNative()
        waitBarSettled(app)
        remote.press(.playPause)
        XCTAssertTrue(waitNative(app, timeout: 4) { $0["paused"] == "1" }, "did not pause: \(nativeProbeText(app))")
        var sawBarHidden: Date?
        var cardShownAt: Date?
        let end = Date().addingTimeInterval(12)
        while Date() < end {
            let p = nativeProbe(app)
            if p["card"] == "1" {
                XCTAssertEqual(p["bar"], "0", "card drawn while the bar is not known hidden: \(nativeProbeText(app))")
                cardShownAt = cardShownAt ?? Date()
            }
            if p["bar"] == "0", p["paused"] == "1" { sawBarHidden = sawBarHidden ?? Date() }
            if cardShownAt != nil { break }
            if let hidden = sawBarHidden, Date().timeIntervalSince(hidden) > 2 { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard sawBarHidden != nil else {
            throw XCTSkip("sim bar never hides while paused: \(nativeProbeText(app))")
        }
        XCTAssertNotNil(cardShownAt, "bar hidden while paused but no card within 2 s: \(nativeProbeText(app))")
        remote.press(.up)
        XCTAssertTrue(waitNative(app, timeout: 3) { $0["card"] == "0" }, "a press did not hide the card: \(nativeProbeText(app))")
        print("[ParityLeg] native pause card: \(nativeProbeText(app))")
    }

    /// Menu on the simulator can dismiss the cover even when consumed (see PlayerTransportUITests).
    func requireNativeStillPresented(_ app: XCUIApplication) throws {
        if !app.otherElements["player.native"].waitForExistence(timeout: 2) {
            throw XCTSkip("the simulator dismissed the native player on Menu (environmental)")
        }
    }

    // MARK: B legs (agent B, step 8)

    /// A6-native: the remux's chapters reach the model (`chapters=5` on the probe). The system
    /// Chapters pill that draws them is behind the system swipe down: device-pass item.
    func testNativeChaptersReachModel() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAYER_NATIVE_PROBE"] == "1", "PLAYER_NATIVE_PROBE not set")
        let url = try requiredEnv("PLAYER_SMOKE_CHAPTERS_URL")
        let app = try launchNative(url: url)
        XCTAssertTrue(waitNative(app, timeout: 10) { $0["chapters"] == "5" }, "chapters: \(nativeProbeText(app))")
        print("[NativeParityLeg] chapters: \(nativeProbeText(app))")
    }

    /// B17 lazy path: an add-on subtitle injected after the master (DEBUG knobs) is published as a
    /// rendition (`late=published`), or rebuilt at once when the profile prefers a subtitle
    /// language. Picking it from the system subtitles menu (and the pause card after the rebuild) is
    /// a device-pass item: the simulator cannot drive that menu.
    func testNativeLateSubtitlePublished() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_NATIVE_PROBE"] == "1", "PLAYER_NATIVE_PROBE not set")
        let smoke = try requiredEnv("PLAYER_SMOKE_URL")
        let base = smoke.components(separatedBy: "/").dropLast().joined(separator: "/")
        let app = try launchNative(extra: ["-debug.nativeLateSubtitleURL", base + "/test.srt",
                                           "-debug.nativeLateSubtitleDelaySec", "6",
                                           "-debug.nativeSubsGateSec", "0"])
        XCTAssertTrue(waitNative(app, timeout: 20) { $0["late"] == "published" || $0["late"] == "rebuilt" },
                      "late rendition never published: \(nativeProbeText(app))")
        print("[NativeParityLeg] late: \(nativeProbeText(app))")
    }

    // MARK: B24 loading screen (agent C, spec §10.2)

    /// `debug_loadingHistory` reads `<stage>>…>started overlay=<stage the overlay was first drawn
    /// at | none>`; returns the stage chain and the overlay field.
    func loadingHistory(_ app: XCUIApplication) -> String {
        let el = element(app, "debug_loadingHistory")
        let label = el.waitForExistence(timeout: 2) ? el.label : ""
        return label.components(separatedBy: " overlay=").first ?? label
    }

    func overlayDrawnAt(_ app: XCUIApplication) -> String {
        let el = element(app, "debug_loadingHistory")
        let label = el.waitForExistence(timeout: 2) ? el.label : ""
        return label.components(separatedBy: " overlay=").dropFirst().first ?? "none"
    }

    /// The exact recipe that made `build/smoke/test-long.ts` (2026-10-16; ffprobe: format mpegts,
    /// 600.02 s, stream 0 hevc, stream 1 aac, 166,052,128 bytes from the 158,083,364-byte mkv):
    ///
    ///     cd iosApp/build/smoke && ~/bin/ffmpeg -v error -y -i test-long.mkv -map 0 -c copy test-long.ts
    ///     ffprobe -v error -show_entries format=format_name,duration:stream=codec_name -of compact test-long.ts
    static let mpvFixtureRecipe = "cd iosApp/build/smoke && ~/bin/ffmpeg -v error -y -i test-long.mkv -map 0 -c copy test-long.ts"

    /// The mpv twin of the smoke fixture: the same file remuxed to MPEG-TS (recipe above), which
    /// the router sends to mpv ("container mpegts") with the native engine on. The SDR Matroska
    /// fixture itself routes native, so it cannot exercise the probe → mpv path. Skips with the
    /// recipe when the smoke server does not have the file (the 10-04 disk purge deleted it once).
    func mpvFixtureURL() throws -> String {
        let env = ProcessInfo.processInfo.environment
        let url: String
        if let ts = env["PLAYER_SMOKE_TS_URL"] {
            url = ts
        } else {
            let mkv = try requiredEnv("PLAYER_SMOKE_URL")
            url = mkv.replacingOccurrences(of: ".mkv", with: ".ts")
        }
        try XCTSkipUnless(Self.fixtureAnswers(url), "\(url) is missing; make it with: \(Self.mpvFixtureRecipe)")
        return url
    }

    /// HEAD request to the smoke server; true on a 2xx.
    static func fixtureAnswers(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse { ok = (200..<300).contains(http.statusCode) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return ok
    }

    /// Native, forced: the overlay is up within 1 s of the player's host appearing, is gone once
    /// playback runs, and the history never saw `checking` (a forced engine skips the probe).
    func testNativeLoadingOverlay() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_NATIVE_PROBE"] == "1", "PLAYER_NATIVE_PROBE not set")
        let url = try requiredEnv("PLAYER_SMOKE_URL")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "YES",
                                "-debug.mpvSmokeEngine", "native", "-debug.mpvSmokeStartOver", "YES"]
        app.launch()
        let overlay = element(app, "player.loadingOverlay")
        // The overlay is drawn from the first `.preparing` frame, before the host view exists;
        // either may be seen first.
        let firstSeen = Date().addingTimeInterval(40)
        while Date() < firstSeen, !overlay.exists, !app.otherElements["player.native"].exists {
            Thread.sleep(forTimeInterval: 0.1)
        }
        // A warm start (fixture already cached) can finish between two snapshots, so the hard
        // oracle is the DEBUG record of the stage the overlay was first drawn at.
        let seenLive = overlay.waitForExistence(timeout: 1)
        print("[LoadingLeg] native overlay live=\(seenLive) value=\(seenLive ? (overlay.value as? String ?? "-") : "-")")
        XCTAssertTrue(waitNative(app, timeout: 40) { (Double($0["pos"] ?? "") ?? 0) > 1 },
                      "native playback never started: \(nativeProbeText(app))")
        let drawnAt = overlayDrawnAt(app)
        XCTAssertTrue(drawnAt == "connecting" || drawnAt.hasPrefix("preparing"),
                      "the overlay was not the first startup frame (drawn at: \(drawnAt))")
        let gone = Date().addingTimeInterval(3)
        while Date() < gone, overlay.exists { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(overlay.exists, "overlay still up after playback started")
        let history = loadingHistory(app)
        XCTAssertTrue(history.hasPrefix("connecting>"), history)
        XCTAssertTrue(history.contains(">buffering>"), history)
        XCTAssertTrue(history.hasSuffix(">started"), history)
        XCTAssertFalse(history.contains("checking"), "a forced native engine never probes: \(history)")
        print("[LoadingLeg] native history=\(history) overlay=\(drawnAt) probe=\(nativeProbeText(app))")
    }

    /// mpv through the router (no forced engine, native on): the probe phase shows `checking`, then
    /// mpv's own stages; the overlay is gone once playback runs.
    func testMpvLoadingOverlay() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_NATIVE_PROBE"] == "1", "PLAYER_NATIVE_PROBE not set")
        let url = try mpvFixtureURL()
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "YES",
                                "-debug.mpvSmokeStartOver", "YES"]
        app.launch()
        let overlay = element(app, "player.loadingOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 30), "no loading overlay at the start: \(loadingHistory(app))")
        print("[LoadingLeg] mpv overlay value=\(overlay.value as? String ?? "-")")
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 30),
                      "the router did not pick mpv: \(loadingHistory(app))")
        let seek = element(app, "debug_seekProbe")
        XCTAssertTrue(seek.waitForExistence(timeout: 30), "no seek probe")
        let started = Date().addingTimeInterval(40)
        while Date() < started, (Double(Self.parse(seek.label)["pos"] ?? "") ?? 0) <= 1 { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertGreaterThan(Double(Self.parse(seek.label)["pos"] ?? "") ?? 0, 1, "playback never started: \(seek.label)")
        let gone = Date().addingTimeInterval(3)
        while Date() < gone, overlay.exists { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(overlay.exists, "overlay still up after playback started")
        let history = loadingHistory(app)
        XCTAssertTrue(history.hasPrefix("checking>connecting>buffering"), history)
        XCTAssertTrue(history.hasSuffix(">started"), history)
        XCTAssertEqual(overlayDrawnAt(app), "checking", "the probe phase's first frame is the overlay")
        print("[LoadingLeg] mpv history=\(history) overlay=\(overlayDrawnAt(app)) seek=\(seek.label)")
    }

    /// Settings › Player › Loading Screen off → the overlay never draws and the spinner path runs.
    /// The setting is profile-scoped and FA87 is the shared fixture, so the leg puts it back to the
    /// value it found in a teardown block (critique C18, r1 P3). The teardown is registered before
    /// the first toggle and keys on the value read just before the press, so it also runs when the
    /// leg fails mid-way. ⚠️ `show_loading_overlay` is synced with the phone app: run this leg only
    /// on a GUEST fixture (FA87 today), never a signed-in profile, or the account sees "off" for the
    /// length of the run.
    func testLoadingOverlayOff() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_NATIVE_PROBE"] == "1", "PLAYER_NATIVE_PROBE not set")
        let url = try requiredEnv("PLAYER_SMOKE_URL")

        final class Found { var before: Bool? }
        let found = Found()
        addTeardownBlock { [weak self] in
            guard let self else { return }
            guard let before = found.before else {
                print("[LoadingLeg] teardown: the row was never read, nothing to restore")
                return
            }
            let app = self.launchToProfileHome()
            let was = self.setLoadingScreen(app, on: before)
            print("[LoadingLeg] teardown: Loading Screen was on=\(was.map(String.init) ?? "unreadable"), restored to on=\(before)")
            app.terminate()
        }
        let settingsApp = launchToProfileHome()
        let before = try XCTUnwrap(setLoadingScreen(settingsApp, on: false, onRead: { found.before = $0 }),
                                   "Loading Screen row not found or unreadable")
        print("[LoadingLeg] off: the fixture had Loading Screen on=\(before)")
        Thread.sleep(forTimeInterval: 2)     // let the defaults write land before the kill
        settingsApp.terminate()

        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "YES",
                                "-debug.mpvSmokeEngine", "native", "-debug.mpvSmokeStartOver", "YES"]
        app.launch()
        let overlay = element(app, "player.loadingOverlay")
        let probe = element(app, "debug_nativeProbe")
        var sawOverlay = false
        let end = Date().addingTimeInterval(45)
        while Date() < end {
            if overlay.exists { sawOverlay = true; break }
            if probe.exists, (Double(Self.parse(probe.label)["pos"] ?? "") ?? 0) > 1 { break }
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertFalse(sawOverlay, "the loading overlay drew with Loading Screen off")
        XCTAssertEqual(overlayDrawnAt(app), "none", "the loading overlay drew with Loading Screen off")
        XCTAssertTrue(waitNative(app, timeout: 40) { (Double($0["pos"] ?? "") ?? 0) > 1 },
                      "native playback never started: \(nativeProbeText(app))")
        print("[LoadingLeg] off: overlay never drawn; history=\(loadingHistory(app)) probe=\(nativeProbeText(app))")
    }

    // MARK: Settings helpers (B24 off leg; trimmed copies, house rule: each file owns its helpers)

    /// Launches to the profile picker and enters the fixture's "Chris" profile.
    func launchToProfileHome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared")
        if chris.exists {
            // ui-legs: the shared verified step (Select only once "Chris" reads focused).
            DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
        }
        Thread.sleep(forTimeInterval: 6)
        return app
    }

    func focusedNodes(_ app: XCUIApplication) -> [(identifier: String, label: String, value: String)] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [(identifier: String, label: String, value: String)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus { out.append((node.identifier, node.label, (node.value as? String) ?? "")) }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Opens Settings › Player, walks to "Loading Screen" and sets it. Returns the state it found
    /// (nil = row not reached or unreadable).
    /// `onRead` gets the found state before any press (the off leg's teardown keys on it).
    @discardableResult
    func setLoadingScreen(_ app: XCUIApplication, on: Bool, onRead: ((Bool) -> Void)? = nil) -> Bool? {
        guard openSettingsPlayer(app) else { return nil }
        var reached = false
        for _ in 0..<30 {
            if focusedNodes(app).contains(where: { $0.label.hasPrefix("Loading Screen") }) { reached = true; break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard reached, let before = loadingScreenState(app) else { return nil }
        onRead?(before)
        if before != on {
            remote.press(.select)
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertEqual(loadingScreenState(app), on, "Loading Screen did not end up \(on ? "on" : "off")")
        return before
    }

    func loadingScreenState(_ app: XCUIApplication) -> Bool? {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Loading Screen")).allElementsBoundByIndex
        for e in matches {
            if let value = e.value as? String, ["On", "Off", "1", "0"].contains(value) { return value == "On" || value == "1" }
        }
        for e in matches {
            if e.label.hasSuffix(", On") { return true }
            if e.label.hasSuffix(", Off") { return false }
        }
        return nil
    }

    /// Settings tab → root → "Player" pushed. Tabs-mode fixture: Up to the tab bar, then across.
    func openSettingsPlayer(_ app: XCUIApplication) -> Bool {
        let tabNames = ["Home", "Search", "Discover", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<40 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.35)
        }
        let tab = app.buttons["Settings"]
        for direction in [XCUIRemote.Button.right, .left] {
            for _ in 0..<8 where !(tab.exists && tab.hasFocus) {
                remote.press(direction)
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
        guard tab.exists, tab.hasFocus else { return false }
        remote.press(.select)
        Thread.sleep(forTimeInterval: 2)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1)
        // A pane the persisted path left open: pop back to the root.
        for _ in 0..<3 where !element(app, "settings_category_player").exists {
            remote.press(.menu)
            Thread.sleep(forTimeInterval: 1.2)
        }
        let row = element(app, "settings_category_player")
        guard row.waitForExistence(timeout: 4) else { return false }
        var focused = false
        for direction in [XCUIRemote.Button.down, .up] {
            for _ in 0..<12 where !focused {
                if focusedNodes(app).contains(where: { $0.identifier == "settings_category_player" || $0.label.hasPrefix("Player") }) {
                    focused = true
                } else {
                    remote.press(direction)
                    Thread.sleep(forTimeInterval: 0.6)
                }
            }
        }
        guard focused else { return false }
        remote.press(.select)
        return element(app, "settings_pane_player").waitForExistence(timeout: 4)
    }

    // MARK: Return from background (spec 9.3, T-UI-N1 to N5)

    /// The rule's mode and last outcome (`ret=<mode>/<outcome>` on the native probe).
    func retMode(_ p: [String: String]) -> String { (p["ret"] ?? "-").components(separatedBy: "/").first ?? "-" }
    func retOutcome(_ p: [String: String]) -> String { (p["ret"] ?? "-").components(separatedBy: "/").dropFirst().first ?? "-" }

    /// A real background trip: Home, `awaySec` on the home screen, `activate()`. False when the simulator
    /// does not background or foreground the app.
    func homeAndReturn(_ app: XCUIApplication, awaySec: TimeInterval) -> (ok: Bool, note: String) {
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

    /// The DEBUG in-process cycle (`DebugBackgroundCycle`, ticked by the coordinator).
    func cycleArgs(atSec: Int, awaySec: Int) -> [String] {
        ["-debug.backgroundCycleAtSec", String(atSec), "-debug.backgroundCycleAwaySec", String(awaySec)]
    }

    /// The return is over: the rule idle with `outcome`, the restart finished, paused, a frame displayed.
    func waitNativeReturnSettled(_ app: XCUIApplication, outcome: String = "settled", timeout: TimeInterval = 60) -> Bool {
        waitNative(app, timeout: timeout) {
            self.retMode($0) == "idle" && self.retOutcome($0) == outcome && $0["restoring"] == "0"
                && $0["paused"] == "1" && $0["picture"] == "1"
        }
    }

    /// After a settled return: still paused, then Play/Pause plays on from there.
    func assertNativePausedThenPlays(_ app: XCUIApplication, from back: Double, file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(nativeProbe(app)["paused"], "1", "the return did not stay paused: \(nativeProbeText(app))", file: file, line: line)
        let still = Double(nativeProbe(app)["pos"] ?? "") ?? -1
        XCTAssertEqual(still, back, accuracy: 0.6, "the position moved while paused after the return: \(nativeProbeText(app))", file: file, line: line)
        remote.press(.playPause)
        var lowest = Double.infinity
        XCTAssertTrue(waitNative(app, timeout: 20) {
            let p = Double($0["pos"] ?? "") ?? -1
            if $0["paused"] == "0", p >= 0 { lowest = min(lowest, p) }
            return $0["paused"] == "0" && p >= back + 2
        }, "Play after the return did not play on: back=\(back) \(nativeProbeText(app))", file: file, line: line)
        // W4 (2026-11-21): AVKit's Play on a restarted player seeked to 0 before playing; the wait above
        // alone passed that way once the clock ran past back + 2.
        XCTAssertGreaterThanOrEqual(lowest, back - 1, "Play started from an earlier position than the return showed: back=\(back) lowest=\(lowest)",
                                    file: file, line: line)
        XCTAssertTrue(app.otherElements["player.native"].exists, "no longer the native player", file: file, line: line)
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "mpv took over", file: file, line: line)
    }

    /// One mid-play return (N1 to N3): paused at `p0` with a picture and the same audio and subtitle
    /// renditions, then Play plays on. Returns the settled probe.
    @discardableResult
    func assertNativeMidPlayReturn(_ app: XCUIApplication, p0: Double, before: [String: String],
                                   file: StaticString = #filePath, line: UInt = #line) -> [String: String] {
        XCTAssertTrue(waitNativeReturnSettled(app), "the restart never settled paused with a picture: \(nativeProbeText(app))", file: file, line: line)
        let after = nativeProbe(app)
        let back = Double(after["pos"] ?? "") ?? -1
        print("[ReturnLeg] native settled: p0=\(p0) \(nativeProbeText(app))")
        XCTAssertGreaterThan(back, 1, "the position was reset to 0: \(nativeProbeText(app))", file: file, line: line)
        XCTAssertEqual(back, p0, accuracy: 2.5, "the restart is not at the pre-Home position: p0=\(p0) \(nativeProbeText(app))", file: file, line: line)
        XCTAssertEqual(after["aud"], before["aud"], "the audio rendition changed across the return", file: file, line: line)
        XCTAssertEqual(after["sub"], before["sub"], "the subtitle rendition changed across the return", file: file, line: line)
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "a plain restart handed off to mpv", file: file, line: line)
        assertNativePausedThenPlays(app, from: back, file: file, line: line)
        return after
    }

    /// The DEBUG cycle's away half: the old player is paused at the held position (the observe tick fires
    /// the cycle, so anywhere from 10 to 13 s). Returns that position.
    func heldPositionWhileAway(_ app: XCUIApplication) throws -> Double {
        XCTAssertTrue(waitNative(app, timeout: 40) { self.retMode($0) == "away" }, "the DEBUG background cycle never ran: \(nativeProbeText(app))")
        let held = Double(nativeProbe(app)["pos"] ?? "") ?? -1
        print("[ReturnLeg] native away: \(nativeProbeText(app))")
        return try XCTUnwrap(held >= 9 ? held : nil, "no held position while away: \(nativeProbeText(app))")
    }

    /// T-UI-N1, real background (Home, 5 s on the home screen, activate): the pipeline restarts paused at the
    /// position with a picture and the same renditions; Play plays on.
    func testNativeBackgroundReturnRestartsPaused() throws {
        let app = try launchNative()
        XCTAssertTrue(waitNative(app, timeout: 40) { (Double($0["pos"] ?? "") ?? 0) >= 10 }, "never reached 10 s: \(nativeProbeText(app))")
        let before = nativeProbe(app)
        let p0 = Double(before["pos"] ?? "") ?? -1
        let trip = homeAndReturn(app, awaySec: 5)
        XCTAssertTrue(trip.ok, "the simulator did not background and foreground the app: \(trip.note)")
        guard trip.ok else { return }
        print("[ReturnLeg] N1 home trip: \(trip.note) p0=\(p0)")
        XCTAssertTrue(app.otherElements["player.native"].waitForExistence(timeout: 10), "the native player is gone after the return")
        let after = assertNativeMidPlayReturn(app, p0: p0, before: before)
        print("[ReturnLeg] N1 health=\(after["health"] ?? "-") nudged=\(after["nudged"] ?? "-")")
    }

    /// T-UI-N2 (`-debug.nativeBackgroundFault killListener`, DEBUG cycle at 10 s): the loopback listener is
    /// cancelled while away; the restart rebuilds it (health reads `listenerDead`).
    func testNativeReturnWithDeadListenerRestarts() throws {
        let app = try launchNative(extra: ["-debug.nativeBackgroundFault", "killListener"] + cycleArgs(atSec: 10, awaySec: 5))
        let before = nativeProbe(app)
        let p0 = try heldPositionWhileAway(app)
        let after = assertNativeMidPlayReturn(app, p0: p0, before: before)
        XCTAssertEqual(after["health"], "listenerDead", "the killed listener was not seen at the return: \(nativeProbeText(app))")
    }

    /// T-UI-N3 (`-debug.nativeBackgroundFault failRemuxInput`, DEBUG cycle at 10 s): the remux input fails
    /// while away; the restart starts a new remux.
    func testNativeReturnWithFailedRemuxInputRestarts() throws {
        let app = try launchNative(extra: ["-debug.nativeBackgroundFault", "failRemuxInput"] + cycleArgs(atSec: 10, awaySec: 5))
        let before = nativeProbe(app)
        let p0 = try heldPositionWhileAway(app)
        let after = assertNativeMidPlayReturn(app, p0: p0, before: before)
        print("[ReturnLeg] N3 health=\(after["health"] ?? "-")")
    }

    /// The mpv seek probe's key=value fields.
    func mpvSeekProbe(_ app: XCUIApplication) -> [String: String] {
        let el = element(app, "debug_seekProbe")
        guard el.waitForExistence(timeout: 5) else { return [:] }
        return Self.parse(el.label)
    }

    /// Routed (not forced) launch of the SDR Matroska smoke file with `failRestart` and a DEBUG cycle at 10 s: the
    /// router picks native for it, as the app does (a forced native engine has no mpv fallback by design).
    func launchRoutedWithFailedRestart(awaySec: Int) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_NATIVE_PROBE"] == "1", "PLAYER_NATIVE_PROBE not set")
        let url = try requiredEnv("PLAYER_SMOKE_URL")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "YES", "-debug.mpvSmokeStartOver", "YES",
                                "-debug.nativeBackgroundFault", "failRestart"] + cycleArgs(atSec: 10, awaySec: awaySec)
        app.launch()
        XCTAssertTrue(app.otherElements["player.native"].waitForExistence(timeout: 60), "the router did not pick the native player")
        XCTAssertTrue(waitNative(app, timeout: 40) { (Double($0["pos"] ?? "") ?? 0) > 1 }, "native playback never started: \(nativeProbeText(app))")
        return app
    }

    /// T-UI-N4 (`-debug.nativeBackgroundFault failRestart`, DEBUG cycle at 10 s): the restart fails once, and
    /// the stream goes to mpv from the payload (decision E). Decided spec (mpv returns, Q-M1): mpv starts PAUSED
    /// at the native held position with no press, and Play plays on from there (never from before it).
    func testNativeRestartFailureHandsToMpv() throws {
        let app = try launchRoutedWithFailedRestart(awaySec: 5)
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 60), "mpv never took over after the failed restart: \(nativeProbeText(app))")
        XCTAssertFalse(app.otherElements["player.native"].exists, "the native player is still showing after the handoff")
        let seek = element(app, "debug_seekProbe")
        XCTAssertTrue(seek.waitForExistence(timeout: 30), "no mpv seek probe")
        var settled: [String: String] = [:]
        let end = Date().addingTimeInterval(40)
        while Date() < end {
            let p = Self.parse(seek.label)
            if p["paused"] == "1", (Double(p["pos"] ?? "") ?? 0) > 1 { settled = p; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        let first = Double(settled["pos"] ?? "") ?? -1
        print("[ReturnLeg] N4 mpv first paused pos=\(first) \(seek.label)")
        XCTAssertGreaterThan(first, 7.5, "mpv did not start paused at the held position (~10 s): \(seek.label)")
        XCTAssertLessThan(first, 17.0, "mpv started far past the held position (10 to 13 s): \(seek.label)")
        Thread.sleep(forTimeInterval: 2.5)
        let still = mpvSeekProbe(app)
        XCTAssertEqual(still["paused"], "1", "mpv did not stay paused with no press: \(seek.label)")
        XCTAssertEqual(Double(still["pos"] ?? "") ?? -1, first, accuracy: 0.5, "the position moved while paused: \(seek.label)")
        remote.press(.playPause)
        var lowest = Double.infinity
        let playEnd = Date().addingTimeInterval(20)
        var played = false
        while Date() < playEnd {
            let p = Self.parse(seek.label)
            let pos = Double(p["pos"] ?? "") ?? -1
            if p["paused"] == "0", pos >= 0 { lowest = min(lowest, pos) }
            if p["paused"] == "0", pos >= first + 2 { played = true; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(played, "Play did not play on from the held position: first=\(first) \(seek.label)")
        XCTAssertGreaterThanOrEqual(lowest, first - 0.5, "Play started from before the held position: first=\(first) lowest=\(lowest)")
    }

    /// M11 (spec-mpv-return §5.3): native `failRestart` with a Play press queued while away: the stream goes to mpv from
    /// the payload at the native held position, and the queued Play makes it play without a second press.
    func testNativeRestartFailureWithQueuedPlayStartsMpvPlaying() throws {
        let app = try launchRoutedWithFailedRestart(awaySec: 10)
        XCTAssertTrue(waitNative(app, timeout: 40) { self.retMode($0) == "away" }, "the DEBUG background cycle never ran: \(nativeProbeText(app))")
        let nativeHeld = Double(nativeProbe(app)["pos"] ?? "") ?? -1
        XCTAssertGreaterThan(nativeHeld, 7.5, "no native held position while away: \(nativeProbeText(app))")
        remote.press(.playPause)
        print("[ReturnLeg] M11 Play pressed while away at \(nativeHeld): \(nativeProbeText(app))")
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 90), "mpv never took over after the failed restart: \(nativeProbeText(app))")
        let seek = element(app, "debug_seekProbe")
        XCTAssertTrue(seek.waitForExistence(timeout: 30), "no mpv seek probe")
        var heldField = -1.0
        var lowest = Double.infinity
        var playing = false
        var intentSeen = "-"
        let end = Date().addingTimeInterval(60)
        while Date() < end {
            let p = Self.parse(seek.label)
            let pos = Double(p["pos"] ?? "") ?? -1
            if let h = Double(p["held"] ?? "") { heldField = h; intentSeen = p["intent"] ?? "-" }
            if p["paused"] == "0", pos > 1 { lowest = min(lowest, pos) }
            if p["paused"] == "0", pos >= max(heldField, nativeHeld) + 2 { playing = true; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("[ReturnLeg] M11 nativeHeld=\(nativeHeld) held=\(heldField) intent=\(intentSeen) lowest=\(lowest) \(seek.label)")
        XCTAssertTrue(playing, "mpv did not play from the queued Play: nativeHeld=\(nativeHeld) \(seek.label)")
        XCTAssertEqual(heldField, nativeHeld, accuracy: 0.5, "mpv's start is not the native held position: \(seek.label)")
        XCTAssertGreaterThanOrEqual(lowest, nativeHeld - 0.5, "mpv played from before the native held position: lowest=\(lowest)")
    }

    /// Play/Pause during the restart (I5; `-debug.nativeBackgroundFault delayRestart` holds the restart 5 s;
    /// DEBUG cycle at 10 s). AVKit owns the remote on this route and ignores Play on the restart's item-less
    /// player, so the press reaches the return through the host's Play/Pause recogniser, is queued, and is
    /// applied when the restart settles: playback goes on from the held position without a second press.
    func testNativePlayDuringReturnIsQueued() throws {
        let app = try launchNative(extra: ["-debug.nativeBackgroundFault", "delayRestart"] + cycleArgs(atSec: 10, awaySec: 4))
        let held = try heldPositionWhileAway(app)
        XCTAssertTrue(waitNative(app, timeout: 20) { $0["restoring"] == "1" }, "the restart never started: \(nativeProbeText(app))")
        remote.press(.playPause)
        Thread.sleep(forTimeInterval: 1.0)   // the held re-pause lands in the same turn as the start
        let during = nativeProbe(app)
        print("[ReturnLeg] N6 after Play during the restart: \(nativeProbeText(app))")
        XCTAssertEqual(during["restoring"], "1", "Play landed after the restart, not during it: \(nativeProbeText(app))")
        XCTAssertNotEqual(during["paused"], "0", "a Play during the restart reached the player: \(nativeProbeText(app))")
        var lowest = Double.infinity
        XCTAssertTrue(waitNative(app, timeout: 60) {
            let p = Double($0["pos"] ?? "") ?? -1
            if self.retMode($0) == "idle", $0["paused"] == "0", p >= 0 { lowest = min(lowest, p) }
            return self.retMode($0) == "idle" && $0["restoring"] == "0" && $0["paused"] == "0" && $0["picture"] == "1" && p >= held + 2
        }, "the queued Play was not applied after the restart: \(nativeProbeText(app))")
        XCTAssertGreaterThanOrEqual(lowest, held - 1, "the queued Play started before the held position: held=\(held) lowest=\(lowest)")
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "mpv took over")
    }

    /// T-UI-N5 (`-debug.nativeStartDelaySec 6`, DEBUG cycle at the first poll tick, 3 s away): a return before
    /// anything played restarts from scratch through the normal start and ends paused at its resume point
    /// (30 s, `-debug.mpvSmokeResumeSec`) with a picture.
    func testNativeReturnBeforeReadyRestartsFromScratch() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_NATIVE_PROBE"] == "1", "PLAYER_NATIVE_PROBE not set")
        let url = try requiredEnv("PLAYER_SMOKE_URL")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "YES", "-debug.mpvSmokeEngine", "native",
                                "-debug.mpvSmokeResumeSec", "30", "-debug.nativeStartDelaySec", "6"] + cycleArgs(atSec: 0, awaySec: 3)
        app.launch()
        XCTAssertTrue(waitNative(app, timeout: 60) { self.retMode($0) == "idle" && $0["paused"] == "1" && $0["picture"] == "1"
                                                        && $0["restoring"] == "0" && (Double($0["pos"] ?? "") ?? 0) > 1 },
                      "the start never ended paused with a picture after the return: \(nativeProbeText(app))")
        let p = nativeProbe(app)
        let back = Double(p["pos"] ?? "") ?? -1
        print("[ReturnLeg] N5 settled: \(nativeProbeText(app))")
        XCTAssertEqual(back, 30, accuracy: 3, "the restart from scratch is not at its resume point: \(nativeProbeText(app))")
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "the restart from scratch handed off to mpv")
        assertNativePausedThenPlays(app, from: back)
    }

    /// N7 (spec-mpv-return §6.3): a saved resume that falls mid-segment (47.3 s), the DEBUG cycle at loading and the
    /// first restart seek made coarse (`-debug.nativeRestartFirstSeekCoarse`: it lands on a segment start): the landing
    /// check corrects it and the native restart settles within 0.5 s of the saved position.
    func testNativeRestartMidSegmentResumeLandsExactly() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_NATIVE_PROBE"] == "1", "PLAYER_NATIVE_PROBE not set")
        let url = try requiredEnv("PLAYER_SMOKE_URL")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "YES", "-debug.mpvSmokeEngine", "native",
                                "-debug.mpvSmokeResumeSec", "47.3", "-debug.nativeStartDelaySec", "6",
                                "-debug.nativeRestartFirstSeekCoarse", "YES"] + cycleArgs(atSec: 0, awaySec: 3)
        app.launch()
        XCTAssertTrue(waitNative(app, timeout: 90) { self.retMode($0) == "idle" && $0["paused"] == "1" && $0["picture"] == "1"
                                                        && $0["restoring"] == "0" && (Double($0["pos"] ?? "") ?? 0) > 1 },
                      "the start never ended paused with a picture after the return: \(nativeProbeText(app))")
        let back = Double(nativeProbe(app)["pos"] ?? "") ?? -1
        print("[ReturnLeg] N7 settled: \(nativeProbeText(app))")
        XCTAssertEqual(back, 47.3, accuracy: 0.5, "the restart is not within 0.5 s of the saved position: \(nativeProbeText(app))")
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "the restart handed off to mpv")
        assertNativePausedThenPlays(app, from: back)
    }
}
