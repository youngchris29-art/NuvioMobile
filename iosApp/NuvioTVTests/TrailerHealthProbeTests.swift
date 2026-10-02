import XCTest
import AVFoundation
@testable import NuvioTV

/// BUG-128: coverage for the trailer playback-health summary and monitor.
final class TrailerHealthProbeTests: XCTestCase {
    private let key = "debug.trailerDiagnostics"
    private var previousValue = false

    override func setUp() {
        super.setUp()
        previousValue = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        TrailerZoomProbe.clear()
        DetailHitchSnapshot.reset()
    }

    override func tearDown() {
        TrailerZoomProbe.clear()
        DetailHitchSnapshot.reset()
        UserDefaults.standard.set(previousValue, forKey: key)
        super.tearDown()
    }

    private func sample(surface: String = "detail-bg", kind: String = "repack") -> TrailerHealthSummary {
        TrailerHealthSummary(
            surface: surface,
            source: TrailerHealthSource(kind: kind, height: 1080, fps: 60, itag: "299", throttledN: false),
            startupMs: 1240, playedSeconds: 38.2, waits: 2, waitMs: 1810, stalls: 1, empties: 2,
            accessStalls: 1, droppedFrames: 0, indicatedMbps: 5.9, observedMbps: 12.3,
            presentation: CGSize(width: 1920, height: 1080), errorStatus: nil, errorComment: nil,
            hitches: DetailHitchSnapshot.Value(hitches: 3, frames: 2280, maxGapMs: 48))
    }

    func testClassifyLoopbackWithoutRegisteredTokenIsRepackWithZeros() {
        let s = TrailerHealthSource.classify(urlString: "http://127.0.0.1:54321/abc123/master.m3u8")
        XCTAssertEqual(s.kind, "repack")
        XCTAssertEqual(s.height, 0)
        XCTAssertNil(s.itag)
    }

    func testClassifyGoogleVideoProgressiveReadsItagAndN() {
        let s = TrailerHealthSource.classify(urlString: "https://rr1.googlevideo.com/videoplayback?itag=299&n=abc&x=1")
        XCTAssertEqual(s.kind, "progressive")
        XCTAssertEqual(s.itag, "299")
        XCTAssertTrue(s.throttledN)
    }

    func testClassifyM3u8IsHLS() {
        let s = TrailerHealthSource.classify(urlString: "https://example.com/path/index.m3u8?itag=18")
        XCTAssertEqual(s.kind, "hls")
        XCTAssertEqual(s.itag, "18")
        XCTAssertFalse(s.throttledN)
    }

    func testConsoleLineTokensAndOrder() {
        let line = sample().consoleLine()
        let tokens = ["end surface=detail-bg", "src=repack 1080p60", "itag=299", "n=0", "startup=1240ms", "played=38.2s",
                      "waits=2", "waitMs=1810", "stalls=1", "empties=2", "accStalls=1", "dropped=0", "ind=5.9Mb",
                      "obs=12.3Mb", "size=1920x1080", "err=-", "hitches=3/2280", "maxGap=48ms"]
        var cursor = line.startIndex
        for t in tokens {
            guard let r = line.range(of: t, range: cursor..<line.endIndex) else {
                return XCTFail("missing or out of order: \(t) in \(line)")
            }
            cursor = r.upperBound
        }
    }

    func testPaneLineFormatAndWorstCaseLength() {
        let pane = sample().paneLine()
        XCTAssertEqual(pane, "health detail-bg repack 1080p60 n=0 start=1.2s play=38s wait=2/1.8s stall=1 drop=0 obs=12.3 ind=5.9")

        let worst = TrailerHealthSummary(
            surface: "a-very-long-surface-name",
            source: TrailerHealthSource(kind: "progressive", height: 2160, fps: 60, itag: "999", throttledN: true),
            startupMs: 999_999, playedSeconds: 99_999, waits: 9999, waitMs: 9_999_999, stalls: 9999, empties: 9999,
            accessStalls: 9999, droppedFrames: 99_999, indicatedMbps: 9999, observedMbps: 9999,
            presentation: .zero, errorStatus: nil, errorComment: nil, hitches: nil)
        XCTAssertLessThanOrEqual(worst.paneLine().count, 110)
        XCTAssertTrue(worst.paneLine().hasPrefix("health "))
        XCTAssertTrue(worst.paneLine().contains("ind="))
    }

    func testNilFieldsRenderDashNotZero() {
        let s = TrailerHealthSummary(
            surface: "inline", source: TrailerHealthSource(kind: "other", height: 0, fps: 0, itag: nil, throttledN: false),
            startupMs: nil, playedSeconds: 0, waits: 0, waitMs: 0, stalls: 0, empties: 0, accessStalls: 0,
            droppedFrames: 0, indicatedMbps: nil, observedMbps: nil, presentation: .zero,
            errorStatus: nil, errorComment: nil, hitches: nil)
        let console = s.consoleLine()
        XCTAssertTrue(console.contains("startup=-"), console)
        XCTAssertTrue(console.contains("ind=- obs=-"), console)
        XCTAssertTrue(console.contains("hitches=- maxGap=-"), console)
        let pane = s.paneLine()
        XCTAssertTrue(pane.contains("start=-"), pane)
        XCTAssertTrue(pane.hasSuffix("obs=- ind=-"), pane)
    }

    func testMonitorOnItemlessPlayerEmitsExactlyOneHealthLine() {
        let monitor = TrailerPlaybackHealthMonitor(player: AVPlayer(), surface: "inline", urlString: "https://example.com/v.mp4")
        monitor.start()
        monitor.start()
        monitor.stop()
        monitor.stop()
        let health = TrailerZoomProbe.lines.filter { $0.contains("health inline") }
        XCTAssertEqual(health.count, 1, "\(TrailerZoomProbe.lines)")
    }

    func testOpenWaitAtStopIsCounted() {
        let monitor = TrailerPlaybackHealthMonitor(player: AVPlayer(), surface: "openwait", urlString: "https://example.com/v.mp4")
        monitor.start()
        monitor.simulatePlayingForTesting()
        monitor.simulateWaitForTesting(openedSecondsAgo: 0.5)
        monitor.stop()
        let health = TrailerZoomProbe.lines.filter { $0.contains("health openwait") }
        XCTAssertEqual(health.count, 1, "\(TrailerZoomProbe.lines)")
        XCTAssertTrue(health.first?.contains("wait=1/0.") == true || health.first?.contains("wait=1/1.") == true, "\(health)")
    }

    func testFoldingTheSameItemTwiceDoesNotGrowTotals() {
        let monitor = TrailerPlaybackHealthMonitor(player: AVPlayer(), surface: "foldtwice", urlString: "https://example.com/v.mp4")
        let item = AVPlayerItem(url: URL(string: "https://example.com/v.mp4")!)
        monitor.registerItemForTesting(item)
        monitor.registerItemForTesting(nil)   // folds `item`
        monitor.registerItemForTesting(item)
        monitor.registerItemForTesting(nil)   // folds `item` again: baseline makes it a no-op
        monitor.stop()
        let health = TrailerZoomProbe.lines.filter { $0.contains("health foldtwice") }
        XCTAssertEqual(health.count, 1, "\(TrailerZoomProbe.lines)")
        XCTAssertTrue(health.first?.contains("play=0s") == true && health.first?.contains("drop=0 ") == true, "\(health)")
    }
}
