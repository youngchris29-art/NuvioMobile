import XCTest

/// GitHub #29, code review r4 finding 3: real playback through the Aether engine with a small hard
/// limit on the session cache. The cache fills, playback advances past the point where it filled (the
/// producer can only go on by evicting played segments), a seek back lands in evicted video and keeps
/// playing, and the engine's own count of cache bytes on disk never goes over the limit.
///
/// The limit comes from the DEBUG-only `debug.diskCacheHardLimitBytes` (3 MB here, about 55 s of the
/// 436 kbit/s fixture; the setting's own sizes start at 1 GB). The engine's numbers come from the
/// `debug_seekProbe` cache fields (`AetherCacheProbe.text`): `cdisk` is `currentDiskBytes` (resident
/// segments plus admitted staging, the total the engine's admission holds under the limit), `cpeak` the
/// highest value it reported this load, `bfrom`/`bto` the resident span in seconds.
///
/// Fixture: `aether-long.mkv` (600 s, H.264 640x360 + AAC, keyframe every 2 s) served by the range
/// server, as for `AetherPlayerUITests`:
///
///     TEST_RUNNER_AETHER_SMOKE_URL=http://127.0.0.1:8766/aether-long.mkv
///
/// Skipped unless `AETHER_SMOKE_URL` is set, and skipped when the engine does not take the loopback route
/// (always on the simulator, which has no VideoToolbox hardware decode; run it on an Apple TV).
final class AetherDiskCachePlaybackUITests: XCTestCase {
    private let remote = XCUIRemote.shared
    private static let hardLimit = 3_000_000
    /// The retention budget the app derives from that limit (`applyingDebugHardLimit`: the limit less
    /// its ¼ headroom), which the engine enforces as is.
    private static let budget = 2_250_000

    private func probe(_ app: XCUIApplication) -> [String: String] {
        let el = app.descendants(matching: .any)["debug_seekProbe"]
        guard el.waitForExistence(timeout: 5) else { return [:] }
        var out: [String: String] = [:]
        for part in el.label.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func num(_ p: [String: String], _ key: String) -> Double? { p[key].flatMap(Double.init) }

    /// Polls the probe until `cond` holds, checking the limit on every reading.
    private func wait(_ app: XCUIApplication, timeout: TimeInterval, _ what: String,
                      _ cond: ([String: String]) -> Bool) -> [String: String] {
        let end = Date().addingTimeInterval(timeout)
        var p = probe(app)
        while true {
            assertWithinLimit(p)
            if cond(p) { return p }
            if Date() >= end { break }
            Thread.sleep(forTimeInterval: 0.5)
            p = probe(app)
        }
        XCTFail("timed out waiting for \(what): \(p)")
        return p
    }

    private func assertWithinLimit(_ p: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        for key in ["cdisk", "cpeak"] {
            if let v = num(p, key) {
                XCTAssertLessThanOrEqual(Int(v), Self.hardLimit, "\(key) over the hard limit: \(p)", file: file, line: line)
            }
        }
    }

    func testSmallHardLimitFillsEvictsAndSeekBackKeepsPlaying() throws {
        let env = ProcessInfo.processInfo.environment
        // Code review r5: an absent fixture skips (as `AetherPlayerUITests` does), never fails.
        guard let url = env["AETHER_SMOKE_URL"] else {
            throw XCTSkip("AETHER_SMOKE_URL not set: TEST_RUNNER_AETHER_SMOKE_URL=http://127.0.0.1:8766/aether-long.mkv")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-debug.mpvSmokeURL", url, "-debug.mpvSmokeEngine", "aether",
                                "-debug.mpvSmokeStartOver", "YES", "-player.aetherEngine", "YES",
                                "-player.diskCacheGB", "5", "-debug.diskCacheHardLimitBytes", "\(Self.hardLimit)"]
        app.launch()
        XCTAssertTrue(app.otherElements["player.aether"].waitForExistence(timeout: 30), "the Aether controller did not appear")

        // 1. Playing with the 3 MB limit requested. The cache exists only on the loopback route, which
        // needs VideoToolbox hardware decode: the simulator has none, so the engine takes its software
        // route for every fixture (H.264 and HEVC both read `croute=software` there, 2026-11-21). The
        // leg skips then; it runs on an Apple TV.
        let requested = wait(app, timeout: 30, "playback start and the engine's route") {
            (self.num($0, "pos") ?? 0) > 1 && $0["croute"] != nil && $0["croute"] != "none"
        }
        XCTAssertEqual(requested["creq"], "\(Self.hardLimit)", "the load did not carry the test limit (Mac disk under 4 GB free?)")
        try XCTSkipUnless(requested["croute"] == "loopback",
                          "the engine took the \(requested["croute"] ?? "?") route: no session cache to test here (no hardware decode on the simulator)")
        let started = wait(app, timeout: 15, "the cache ledger") { $0["chard"] != nil }
        XCTAssertEqual(started["chard"], "\(Self.hardLimit)", "the load did not carry the test limit (Mac disk under 4 GB free?)")

        // 2. The cache fills. Review r6: the engine (pinned source, `PrefetchDiskBudget.shouldPark`) parks
        // the producer once its forward bytes reach the retention budget, which can hold the ledger
        // below the hard limit for the whole load, so `cwait` (hard-limit admission) may never read 1.
        // Either is the filled state: the ledger at the budget (forward bytes are part of `cdisk`), or
        // a writer waiting at the hard limit.
        let filled = wait(app, timeout: 60, "the cache to fill (budget park or hard-limit wait)") {
            $0["cwait"] == "1" || Int(self.num($0, "cdisk") ?? 0) >= Self.budget
        }
        let fillEnd = try XCTUnwrap(num(filled, "bto"), "no resident span at the fill: \(filled)")
        print("[CacheLeg] filled: \(filled)")

        // 3. Playback goes past the fill point: only possible if played segments were evicted to admit new ones.
        let past = wait(app, timeout: fillEnd + 60, "playback past the fill point \(fillEnd) s") {
            (self.num($0, "pos") ?? 0) > fillEnd + 10
        }
        XCTAssertGreaterThan(Int(num(past, "cevict") ?? 0), 0, "nothing was evicted: \(past)")
        XCTAssertTrue(app.otherElements["player.aether"].exists, "Aether stopped playing (fell back to mpv?)")
        print("[CacheLeg] past the fill: \(past)")

        // 4. Seek back into evicted video: well before the oldest resident second.
        let pos = try XCTUnwrap(num(past, "pos"))
        let oldest = try XCTUnwrap(num(past, "bfrom"), "no resident span: \(past)")
        XCTAssertGreaterThan(oldest, 15, "the start is still resident, so a seek there would not test eviction: \(past)")
        let presses = Int(((pos - (oldest - 10)) / 10).rounded(.up))
        let commits0 = Int(num(past, "commits") ?? 0)
        for _ in 0..<presses {
            remote.press(.left)
            Thread.sleep(forTimeInterval: 0.6)
        }
        let landed = wait(app, timeout: 20, "the seek back below \(oldest) s") {
            Int(self.num($0, "commits") ?? 0) > commits0 && (self.num($0, "pos") ?? .infinity) < oldest - 2
        }
        let landedPos = try XCTUnwrap(num(landed, "pos"))
        print("[CacheLeg] landed: \(landed) presses=\(presses)")

        // 5. And it keeps playing from there.
        let resumed = wait(app, timeout: 30, "playback to continue after the seek back") {
            (self.num($0, "pos") ?? 0) > landedPos + 8 && $0["paused"] == "0"
        }
        XCTAssertTrue(app.otherElements["player.aether"].exists, "Aether stopped playing after the seek back")
        assertWithinLimit(resumed)
        print("[CacheLeg] resumed: \(resumed)")
    }
}
