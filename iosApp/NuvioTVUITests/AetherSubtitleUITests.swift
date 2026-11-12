import XCTest
import Vision

/// Aether Phase 1, W4: the Aether subtitle overlay (`AetherSubtitleOverlay`) over an embedded SRT track, a
/// sidecar WebVTT file, the subtitle delay, Off, and the forced-only start plan.
///
/// The overlay is hidden from accessibility (`AetherSubtitleOverlay`: `.accessibilityHidden(true)`), so the legs
/// read what is on screen: a screenshot of the lower part of the screen goes through Vision's text recogniser and
/// the cue text (an all-caps marker word such as "EMBEDDED ALPHA", chosen so the test pattern's own digits can never
/// match) is searched in the result. Clock-driven legs pause playback first, so the overlay's time axis is fixed
/// and the answer does not depend on how long the remote navigation took.
///
/// Fixtures come from `scripts/dev/aether-smoke-fixtures.sh` (see `AetherPlayerUITests`):
///   - `aether-subs.mkv`: audio "eng", embedded SRT "Embedded EN" (30-90 s "EMBEDDED ALPHA", 120-180 s
///     "EMBEDDED BRAVO") and "Forced EN" (forced disposition, 40-100 s "FORCED NOTE");
///   - `aether-sidecar.vtt`: a WebVTT sidecar loaded as the app's external "Smoke EN" subtitle through
///     `-debug.mpvSmokeSubtitleURL` (30-90 s "SIDECAR ALPHA").
///
/// Skipped unless `AETHER_SMOKE_SUBS_URL` is in the environment (`TEST_RUNNER_AETHER_SMOKE_SUBS_URL=http://127.0.0.1:8766/aether-subs.mkv`);
/// the sidecar leg also needs `TEST_RUNNER_AETHER_SMOKE_SIDECAR_URL=http://127.0.0.1:8766/aether-sidecar.vtt`.
final class AetherSubtitleUITests: XCTestCase {
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
    private func pos(_ app: XCUIApplication) -> Double { Double(probe(app, "debug_seekProbe")["pos"] ?? "") ?? -1 }

    private func waitSeek(_ app: XCUIApplication, timeout: TimeInterval = 5, _ cond: ([String: String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(probe(app, "debug_seekProbe")) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return cond(probe(app, "debug_seekProbe"))
    }

    private func waitBar(_ app: XCUIApplication, timeout: TimeInterval = 8, _ cond: ([String: String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(probe(app, "debug_transportProbe")) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return cond(probe(app, "debug_transportProbe"))
    }

    /// Everything Vision reads in the lower 45 % of the screen right now, upper-cased.
    private func lowerScreenText() -> String {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return "" }
        let h = image.height
        let band = CGRect(x: 0, y: Int(Double(h) * 0.55), width: image.width, height: Int(Double(h) * 0.45))
        guard let crop = image.cropping(to: band) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: " | ").uppercased()
    }

    /// Polls the screen until the recogniser finds (or, with `present: false`, stops finding) `needle`.
    private func waitForText(_ needle: String, present: Bool = true, timeout: TimeInterval = 8) -> (ok: Bool, seen: String) {
        let end = Date().addingTimeInterval(timeout)
        var seen = ""
        repeat {
            seen = lowerScreenText()
            if seen.contains(needle) == present { return (true, seen) }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < end
        return (false, seen)
    }

    /// Launches the Aether player on the subtitles fixture at `resume` seconds (resume, not Start Over: the
    /// controller honours `resumeAtSec` > 10), pauses it as soon as it is there, and waits for the paused bar to
    /// hide, so the overlay's time axis is fixed and the next Up starts from a hidden bar.
    private func launchPaused(resume: Double, sidecar: Bool = false, extra: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["AETHER_SMOKE_SUBS_URL"], "AETHER_SMOKE_SUBS_URL not set")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-debug.mpvSmokeEngine", "aether",
                                "-debug.mpvSmokeResumeSec", String(Int(resume))] + extra
        if sidecar {
            let side = try XCTUnwrap(env["AETHER_SMOKE_SIDECAR_URL"], "AETHER_SMOKE_SIDECAR_URL not set")
            app.launchArguments += ["-debug.mpvSmokeSubtitleURL", side]
        }
        app.launch()
        XCTAssertTrue(app.otherElements["player.aether"].waitForExistence(timeout: 30), "the Aether controller did not appear")
        XCTAssertTrue(waitSeek(app, timeout: 40) { (Double($0["pos"] ?? "") ?? 0) >= resume - 0.5 }, "playback never reached the resume point: \(seekText(app))")
        remote.press(.playPause)
        XCTAssertTrue(waitSeek(app, timeout: 4) { $0["paused"] == "1" }, "did not pause: \(seekText(app))")
        XCTAssertTrue(waitBar(app, timeout: 14) { $0["vis"] == "0" }, "the paused bar never hid: \(barText(app))")
        return app
    }

    /// Opens the Subtitles popover and picks the row whose title contains `title` ("Off" for the Off row); the
    /// popover stays open (a pick does not close it), the row reads "selected" afterwards.
    @discardableResult
    private func pick(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !element(app, "player.popover.subtitles").exists { PlayerChrome.openDisc(app, "subtitles", file: file, line: line) }
        let row = subtitleRow(app, title)
        XCTAssertTrue(row.waitForExistence(timeout: 4), "no \(title) row in the Subtitles popover", file: file, line: line)
        XCTAssertTrue(PlayerChrome.focusWalk(app, to: row), "focus never reached the \(title) row", file: file, line: line)
        remote.press(.select)
        let end = Date().addingTimeInterval(4)
        while Date() < end, (row.value as? String) != "selected" { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertEqual(row.value as? String, "selected", "\(title) not selected after the pick", file: file, line: line)
        Thread.sleep(forTimeInterval: 0.8)   // the engine publishes the new track's cues
        return row
    }

    /// The subtitle popover's option row whose title contains `title`.
    private func subtitleRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'player.panel.subtitle.' AND NOT identifier BEGINSWITH 'player.panel.subtitleDelay' AND label CONTAINS %@", title))
            .firstMatch
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AETHER_SMOKE_SUBS_URL"] != nil, "AETHER_SMOKE_SUBS_URL not set")
    }

    // MARK: Legs

    /// Embedded SRT: nothing before the first cue; the cue shows from 30 s; the gap after 90 s shows nothing; the
    /// second cue shows from 120 s. Paused throughout, so each answer belongs to the position the Right press
    /// landed on (relative seeks of 10 s).
    func testEmbeddedSrtCueShowsAtItsCueTime() throws {
        let app = try launchPaused(resume: 12)
        pick(app, "Embedded EN")
        // Menu closes the popover (the pill keeps the focus); Down returns the focus to the track, where Right is a seek.
        remote.press(.menu)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "player.popover.subtitles"))
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 4), .completed, "Menu did not close the Subtitles popover")
        XCTAssertTrue(app.otherElements["player.aether"].exists, "Menu left the player")
        remote.press(.down)
        XCTAssertTrue(waitBar(app, timeout: 4) { $0["focus"] == "track" }, "focus did not return to the track: \(barText(app))")
        let before = waitForText("EMBEDDED", present: false, timeout: 4)
        XCTAssertTrue(before.ok, "a cue showed at \(pos(app)) s, before the first cue: \(before.seen)")

        func seekRight(times: Int, toAtLeast target: Double) {
            for _ in 0..<times { remote.press(.right); Thread.sleep(forTimeInterval: 0.7) }
            XCTAssertTrue(waitSeek(app, timeout: 8) { (Double($0["pos"] ?? "") ?? 0) >= target }, "never reached \(target) s: \(seekText(app))")
            Thread.sleep(forTimeInterval: 0.8)
        }
        seekRight(times: 2, toAtLeast: 31)      // 12 -> ~32
        let alpha = waitForText("EMBEDDED ALPHA", timeout: 10)
        XCTAssertTrue(alpha.ok, "no EMBEDDED ALPHA at \(pos(app)) s: \(alpha.seen)")
        seekRight(times: 6, toAtLeast: 91)      // ~32 -> ~92, past the cue's end
        let gap = waitForText("EMBEDDED", present: false, timeout: 10)
        XCTAssertTrue(gap.ok, "a cue still showed at \(pos(app)) s, in the gap: \(gap.seen)")
        seekRight(times: 3, toAtLeast: 121)     // ~92 -> ~122
        let bravo = waitForText("EMBEDDED BRAVO", timeout: 10)
        XCTAssertTrue(bravo.ok, "no EMBEDDED BRAVO at \(pos(app)) s: \(bravo.seen)")
        print("[SubLeg] embedded cue timing ok: alpha \(alpha.seen) | bravo \(bravo.seen)")
    }

    /// The sidecar WebVTT (`-debug.mpvSmokeSubtitleURL`) is listed as the external "Smoke EN" track and its
    /// cue shows once picked.
    func testSidecarVttShowsAsAnExternalSubtitle() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["AETHER_SMOKE_SIDECAR_URL"] == nil, "AETHER_SMOKE_SIDECAR_URL not set: TEST_RUNNER_AETHER_SMOKE_SIDECAR_URL=http://127.0.0.1:8766/aether-sidecar.vtt")
        let app = try launchPaused(resume: 36, sidecar: true)
        let beforePick = lowerScreenText()
        XCTAssertFalse(beforePick.contains("SIDECAR"), "the sidecar cue showed before it was picked: \(beforePick)")
        let row = pick(app, "Smoke EN")
        XCTAssertTrue(row.label.lowercased().contains("webvtt"), "the sidecar row is not the WebVTT file: \(row.label)")
        let shown = waitForText("SIDECAR ALPHA", timeout: 10)
        XCTAssertTrue(shown.ok, "no SIDECAR ALPHA at \(pos(app)) s: \(shown.seen)")
    }

    /// Subtitle delay: a positive delay shows the cue later. Paused just after 30 s, +N s (N = enough to move the
    /// cue's start past the playhead) hides the cue and Reset brings it back.
    func testSubtitleDelayShiftsTheCue() throws {
        let app = try launchPaused(resume: 31)
        pick(app, "Embedded EN")
        let shown = waitForText("EMBEDDED ALPHA", timeout: 10)
        XCTAssertTrue(shown.ok, "no EMBEDDED ALPHA at \(pos(app)) s: \(shown.seen)")

        let value = element(app, "player.panel.subtitleDelay.value")
        let reset = element(app, "player.panel.subtitleDelay.reset")
        if !(value.label.contains("+0.00")) {      // an earlier run can leave a saved delay for this smoke title
            XCTAssertTrue(PlayerChrome.focusWalk(app, to: reset), "focus never reached Reset")
            remote.press(.select)
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(value.label.contains("+0.00"), "delay not at zero before the leg: \(value.label)")
        let held = pos(app)
        let presses = Int(ceil(held - 29.9))
        XCTAssertTrue((1...6).contains(presses), "paused at \(held) s, outside the leg's range")
        let plus1 = element(app, "player.panel.subtitleDelay.plus1")
        XCTAssertTrue(PlayerChrome.focusWalk(app, to: plus1), "focus never reached +1 s")
        for _ in 0..<presses { remote.press(.select); Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(value.label.contains(String(format: "+%d.00", presses)), "delay value is \(value.label), expected +\(presses).00 s")
        let hidden = waitForText("EMBEDDED ALPHA", present: false, timeout: 10)
        XCTAssertTrue(hidden.ok, "the cue still shows with +\(presses) s of delay at \(held) s: \(hidden.seen)")

        XCTAssertTrue(PlayerChrome.focusWalk(app, to: reset), "focus never reached Reset")
        remote.press(.select)
        let back = waitForText("EMBEDDED ALPHA", timeout: 10)
        XCTAssertTrue(back.ok, "the cue did not come back after Reset: \(back.seen)")
    }

    /// Off hides the cue that a picked track was showing.
    func testSubtitlesOffHidesTheCue() throws {
        let app = try launchPaused(resume: 36)
        pick(app, "Embedded EN")
        let shown = waitForText("EMBEDDED ALPHA", timeout: 10)
        XCTAssertTrue(shown.ok, "no EMBEDDED ALPHA at \(pos(app)) s: \(shown.seen)")
        pick(app, "Off")
        let hidden = waitForText("EMBEDDED", present: false, timeout: 10)
        XCTAssertTrue(hidden.ok, "the cue still shows after Off: \(hidden.seen)")
    }

    /// Forced-only start plan: with "Use forced subtitles" on, an English subtitle target and English audio, the start
    /// plan picks the forced track on its own and the overlay shows its cue, never the full track's. Settings are
    /// profile-scoped defaults (`<key>_<profile id>`; the fixture sim runs the guest profile, id 1).
    func testForcedOnlyPlanShowsTheForcedTrack() throws {
        let app = try launchPaused(resume: 50, extra: [
            "-subtitle_use_forced_subtitles_1", "YES", "-preferred_subtitle_language_1", "en",
            "-preferred_audio_language_1", "en"])
        let forced = waitForText("FORCED NOTE", timeout: 15)
        XCTAssertTrue(forced.ok, "no FORCED NOTE at \(pos(app)) s: \(forced.seen)")
        XCTAssertFalse(forced.seen.contains("EMBEDDED"), "the full track's cue showed in forced-only mode: \(forced.seen)")
        let row = {
            PlayerChrome.openDisc(app, "subtitles")
            return self.subtitleRow(app, "Forced EN")
        }()
        XCTAssertEqual(row.value as? String, "selected", "the Forced EN row is not the selected track")
        XCTAssertNotEqual(subtitleRow(app, "Embedded EN").value as? String, "selected")
    }

    // MARK: Late (mid-play) add-on subtitles

    /// The no-subtitles fixture (`AETHER_SMOKE_URL`) playing from `resume`, with `aether-sidecar.vtt` handed to the
    /// player as an add-on file once playback passes 20 s (`-debug.aetherLateSubtitleURL`, DEBUG only). Returns
    /// paused at about 22 s with the bar hidden: the file arrived while playing, never during the load.
    private func launchLate(extra: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["AETHER_SMOKE_URL"], "AETHER_SMOKE_URL not set (the no-subtitles fixture)")
        let side = try XCTUnwrap(env["AETHER_SMOKE_SIDECAR_URL"], "AETHER_SMOKE_SIDECAR_URL not set")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-debug.mpvSmokeEngine", "aether",
                                "-debug.mpvSmokeResumeSec", "12",
                                "-debug.aetherLateSubtitleURL", side, "-debug.aetherLateSubtitleDelaySec", "20"] + extra
        app.launch()
        XCTAssertTrue(app.otherElements["player.aether"].waitForExistence(timeout: 30), "the Aether controller did not appear")
        XCTAssertTrue(waitSeek(app, timeout: 60) { (Double($0["pos"] ?? "") ?? 0) >= 22 }, "playback never passed 22 s: \(seekText(app))")
        remote.press(.playPause)
        XCTAssertTrue(waitSeek(app, timeout: 4) { $0["paused"] == "1" }, "did not pause: \(seekText(app))")
        XCTAssertTrue(waitBar(app, timeout: 14) { $0["vis"] == "0" }, "the paused bar never hid: \(barText(app))")
        print("[SubLeg] late: paused at \(pos(app)) s")
        return app
    }

    /// (1) + (3): the file that arrives mid-play is listed without reopening the player, and once picked by hand
    /// its cue shows at the cue's own time (30-90 s).
    func testLateSubtitleFileListsAndShowsItsCue() throws {
        let app = try launchLate()
        PlayerChrome.openDisc(app, "subtitles")
        let row = subtitleRow(app, "Late EN")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Late EN row after the mid-play add")
        print("[SubLeg] late row id=\(row.identifier) label=\(row.label) value=\(String(describing: row.value))")
        pick(app, "Late EN")
        remote.press(.menu)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "player.popover.subtitles"))
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 4), .completed, "Menu did not close the Subtitles popover")
        remote.press(.playPause)
        XCTAssertTrue(waitSeek(app, timeout: 30) { (Double($0["pos"] ?? "") ?? 0) >= 32 }, "playback never reached 32 s: \(seekText(app))")
        remote.press(.playPause)
        XCTAssertTrue(waitSeek(app, timeout: 4) { $0["paused"] == "1" }, "did not pause: \(seekText(app))")
        let shown = waitForText("SIDECAR ALPHA", timeout: 12)
        XCTAssertTrue(shown.ok, "no SIDECAR ALPHA at \(pos(app)) s after picking the late file: \(shown.seen)")
    }

    /// (2): with a preferred subtitle language and no decision made, the start plan picks the late file by itself.
    func testLateSubtitleFileIsAutoPickedWhenNothingWasDecided() throws {
        let app = try launchLate(extra: ["-preferred_subtitle_language_1", "en", "-preferred_audio_language_1", "en"])
        PlayerChrome.openDisc(app, "subtitles")
        let row = subtitleRow(app, "Late EN")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Late EN row after the mid-play add")
        print("[SubLeg] late auto row id=\(row.identifier) value=\(String(describing: row.value))")
        XCTAssertEqual(row.value as? String, "selected", "the late file was not auto-picked (row value \(String(describing: row.value)))")
    }
}
