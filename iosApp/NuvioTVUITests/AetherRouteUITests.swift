import XCTest

/// Aether Phase 1, W3-C: `PlayerScreen` dispatches `.aether` (forced by `debug.mpvSmokeEngine aether`),
/// the Aether controller plays behind the shared chrome and Down brings the bar up with the Info pill.
/// The fuller Aether legs are W4's.
///
/// Skipped unless `AETHER_BAR_PROBE=1` and `PLAYER_SMOKE_URL` are in the environment (pass them as
/// `TEST_RUNNER_*`). The URL must be http(s) or a file the Aether engine can open (the sim's range
/// server serving `sdr-h264-truehd.mkv`).
final class AetherRouteUITests: XCTestCase {
    private let remote = XCUIRemote.shared

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

    private func waitBar(_ app: XCUIApplication, timeout: TimeInterval = 8, _ cond: ([String: String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(probe(app, "debug_transportProbe")) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return cond(probe(app, "debug_transportProbe"))
    }

    func testAetherPlaysThroughPlayerScreenAndDownShowsTheBar() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["AETHER_BAR_PROBE"] == "1", "AETHER_BAR_PROBE not set")
        let url = try XCTUnwrap(env["PLAYER_SMOKE_URL"], "PLAYER_SMOKE_URL not set")
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-debug.mpvSmokeEngine", "aether",
                                "-debug.mpvSmokeStartOver", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["player.aether"].waitForExistence(timeout: 30), "the Aether controller did not appear")
        XCTAssertFalse(app.otherElements["player.mpv"].exists, "mpv is showing instead of Aether")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, (Double(probe(app, "debug_seekProbe")["pos"] ?? "") ?? 0) <= 1 {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertGreaterThan(Double(probe(app, "debug_seekProbe")["pos"] ?? "") ?? 0, 1, "Aether playback never started")
        XCTAssertTrue(waitBar(app, timeout: 12) { $0["vis"] == "0" }, "bar never hid")
        remote.press(.down)
        let info = app.descendants(matching: .any).matching(identifier: "player.infoPill.info").firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 6), "no Info pill after Down")
        XCTAssertTrue(waitBar(app) { $0["vis"] == "1" }, "bar not up after Down")
        XCTAssertTrue(app.otherElements["player.aether"].exists, "still the Aether controller")
    }
}
