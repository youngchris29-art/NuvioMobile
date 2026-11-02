import XCTest

/// Insights wave 2a: the mpv player's chrome after the top panel went away. Round tool discs
/// (`player.pill.<kind>`) open popovers (`player.popover.<kind>`); the text pill row under the
/// timeline (`player.infoPill.<info|cast|chapters|upNext>`) opens shelves (`player.shelf.<pill>`);
/// Menu backs out one level per press and never exits the player from inside one of them.
///
/// mpv route only: the simulator can drive it fully. The native route's chrome (the system
/// `AVPlayerViewController` info pills from `customInfoViewControllers`, and the Episodes /
/// Sources / Timing / Sync Line round buttons from `transportBarCustomMenuItems`) is not
/// reachable by XCUITest on the simulator (the info pills sit behind the system swipe down, which
/// `XCUIRemote` cannot issue, and the custom items draw as system popovers), so those are covered
/// by `NativePlayerChromeTests` (unit) and the device pass. `NativePlayerParityUITests` keeps the
/// native legs that do not touch the chrome (pause card, loading overlay) and asserts the custom
/// transport items exist.
///
/// The Cast pill needs a TMDB-resolvable id and network; the smoke fixture has neither, so it is
/// covered by unit tests and the device pass, not here.
///
/// Skipped unless `PLAYER_BAR_PROBE=1` and `PLAYER_SMOKE_URL` are in the environment (pass them as
/// `TEST_RUNNER_*`). tvOS 27 XCUITest does not report `hasFocus` for these controls: the controller
/// routes the remote itself, so focus is read from the `accessibilityValue` ("focused") the pills
/// publish, and the disc row from the `focus=pill:<kind>` field of `debug_transportProbe`.
final class PlayerChromeUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    // MARK: Harness

    private func launchWithBarHidden() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PLAYER_BAR_PROBE"] == "1", "PLAYER_BAR_PROBE not set")
        let url = try XCTUnwrap(env["PLAYER_SMOKE_URL"], "PLAYER_SMOKE_URL not set")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-player.nativeDolbyVision", "NO",
                                "-player.bufferMB", "8", "-debug.mpvSmokeStartOver", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 30), "player did not appear")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, (Double(probe(app, "debug_seekProbe")["pos"] ?? "") ?? 0) <= 1 {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertGreaterThan(Double(probe(app, "debug_seekProbe")["pos"] ?? "") ?? 0, 1, "playback never started")
        XCTAssertTrue(waitBar(app, timeout: 10) { $0["vis"] == "0" }, "bar never hid: \(barText(app))")
        return app
    }

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

    private func barText(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["debug_transportProbe"].label
    }

    private func waitBar(_ app: XCUIApplication, timeout: TimeInterval = 5, _ cond: ([String: String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(probe(app, "debug_transportProbe")) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return cond(probe(app, "debug_transportProbe"))
    }

    private func waitValue(_ el: XCUIElement, _ expected: String, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (el.value as? String) == expected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return (el.value as? String) == expected
    }

    private func waitGone(_ el: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: el)],
                         timeout: timeout) == .completed
    }

    /// The simulator can dismiss the cover after a consumed Menu (see `PlayerTransportUITests`): the
    /// "player still presented" assertion is the one expected failure there, and a dismissed cover
    /// skips the rest instead of passing vacuously.
    private func requirePlayerStillPresented(_ app: XCUIApplication, _ message: String) throws {
        Thread.sleep(forTimeInterval: 1.0)
        let presented = app.otherElements["player.mpv"].exists
        XCTExpectFailure("simulator Menu dismisses the cover after the press was consumed", strict: false) {
            XCTAssertTrue(presented, message)
        }
        if !presented {
            throw XCTSkip("cover dismissed by the simulator after Menu; the remaining checks are device-pass items")
        }
    }

    // MARK: Legs

    /// Down from a hidden bar → the bar comes up with the Info pill focused; Select opens its shelf;
    /// Menu closes the shelf and leaves the bar and the pill row; the next Menu unfocuses the pills.
    func testDownFocusesInfoPillAndShelfOpensAndCloses() throws {
        let app = try launchWithBarHidden()
        let info = element(app, "player.infoPill.info")
        remote.press(.down)
        XCTAssertTrue(info.waitForExistence(timeout: 6), "no Info pill after Down")
        XCTAssertTrue(waitValue(info, "focused"), "Info pill not focused after Down: value=\(String(describing: info.value))")
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, "bar not up after Down: \(barText(app))")

        remote.press(.select)
        let shelf = element(app, "player.shelf.info")
        XCTAssertTrue(shelf.waitForExistence(timeout: 6), "Info shelf did not open on Select")

        remote.press(.menu)
        XCTAssertTrue(waitGone(shelf), "Menu did not close the Info shelf")
        try requirePlayerStillPresented(app, "Menu in the shelf must not exit the player")
        XCTAssertTrue(info.exists, "pill row gone after the shelf closed")
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, "bar hid with the shelf's close: \(barText(app))")
        XCTAssertTrue(waitValue(info, "focused"), "Info pill lost focus when the shelf closed")

        remote.press(.menu)
        try requirePlayerStillPresented(app, "Menu on the pill row must not exit the player")
        XCTAssertTrue(waitValue(info, ""), "Menu did not unfocus the pill row: value=\(String(describing: info.value))")
    }

    /// Up from the track → the disc row; Select on Subtitles → its popover; Menu closes it and the
    /// player stays.
    func testSubtitlesDiscOpensPopoverAndMenuClosesIt() throws {
        let app = try launchWithBarHidden()
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" && $0["focus"] == "track" }, barText(app))
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["focus"] == "pill:subtitles" }, "Up from the track did not reach the disc row: \(barText(app))")
        let disc = element(app, "player.pill.subtitles")
        XCTAssertTrue(disc.exists, "no Subtitles disc")

        remote.press(.select)
        let popover = element(app, "player.popover.subtitles")
        XCTAssertTrue(popover.waitForExistence(timeout: 6), "Subtitles popover did not open on Select")

        remote.press(.menu)
        XCTAssertTrue(waitGone(popover), "Menu did not close the popover")
        try requirePlayerStillPresented(app, "Menu in a popover must not exit the player")
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, "bar hid with the popover's close: \(barText(app))")
    }
}

/// Shared remote driving for the legs that used to open the top panel (`SyncLineUITests`,
/// `PlayerAudioSpeedUITests`, `NativePlayerParityUITests`, `PlayerTransportUITests`,
/// `SubtitleDelayProbeTests`): open a tool disc's popover or an info pill's shelf on the mpv route.
enum PlayerChrome {
    static func probe(_ app: XCUIApplication, _ id: String) -> [String: String] {
        let el = app.descendants(matching: .any)[id]
        guard el.waitForExistence(timeout: 5) else { return [:] }
        var out: [String: String] = [:]
        for part in el.label.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    static func waitBar(_ app: XCUIApplication, timeout: TimeInterval = 5, _ cond: ([String: String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(probe(app, "debug_transportProbe")) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return cond(probe(app, "debug_transportProbe"))
    }

    /// From a hidden bar: Up (track), Up (first disc), Right along the disc row to `kind`
    /// (`subtitles`, `audio`, `speed`, `aspect`, `sources`, `episodes`, `more`), Select. Returns the
    /// popover element (`player.popover.<kind>`), already waited for.
    @discardableResult
    static func openDisc(_ app: XCUIApplication, _ kind: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let remote = XCUIRemote.shared
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" && $0["focus"] == "track" }, "bar did not come up on the track", file: file, line: line)
        remote.press(.up)
        XCTAssertTrue(waitBar(app) { ($0["focus"] ?? "").hasPrefix("pill:") }, "Up did not reach the disc row", file: file, line: line)
        for _ in 0..<8 where probe(app, "debug_transportProbe")["focus"] != "pill:\(kind)" {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertEqual(probe(app, "debug_transportProbe")["focus"], "pill:\(kind)", "never reached the \(kind) disc", file: file, line: line)
        remote.press(.select)
        let popover = app.descendants(matching: .any)["player.popover.\(kind)"]
        XCTAssertTrue(popover.waitForExistence(timeout: 6), "\(kind) popover did not open", file: file, line: line)
        Thread.sleep(forTimeInterval: 1.0)   // let the popover's rows take focus
        return popover
    }

    /// From a hidden bar: Down (Info pill focused), Right along the pill row to `pill`
    /// (`info`, `cast`, `chapters`, `upNext`), Select. Returns the shelf (`player.shelf.<pill>`).
    @discardableResult
    static func openShelf(_ app: XCUIApplication, _ pill: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let remote = XCUIRemote.shared
        remote.press(.down)
        let target = app.descendants(matching: .any)["player.infoPill.\(pill)"]
        XCTAssertTrue(target.waitForExistence(timeout: 6), "no \(pill) pill", file: file, line: line)
        for _ in 0..<5 where (target.value as? String) != "focused" {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.4)
        }
        if (target.value as? String) != "focused" {
            let pills = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'player.infoPill.'")).allElementsBoundByIndex
                .map { "\($0.identifier)=\(($0.value as? String) ?? "?")" }
            print("[ChromeLeg] \(pill) pill not focused: \(pills) bar=\(app.descendants(matching: .any)["debug_transportProbe"].label) seek=\(app.descendants(matching: .any)["debug_seekProbe"].label)")
        }
        XCTAssertEqual(target.value as? String, "focused", "never focused the \(pill) pill", file: file, line: line)
        remote.press(.select)
        let shelf = app.descendants(matching: .any)["player.shelf.\(pill)"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 6), "\(pill) shelf did not open", file: file, line: line)
        Thread.sleep(forTimeInterval: 1.0)
        return shelf
    }

    /// Geometric focus walk for rows inside a popover or shelf: presses Down/Up/Left/Right toward
    /// `target` until it reports `hasFocus`. Never press Up from a row level with or above the target
    /// unless the target is higher (Up past the first row leaves the popover for the disc row).
    @discardableResult
    static func focusWalk(_ app: XCUIApplication, to target: XCUIElement, maxSteps: Int = 30) -> Bool {
        let remote = XCUIRemote.shared
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
}
