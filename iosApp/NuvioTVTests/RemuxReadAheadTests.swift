import Foundation
import XCTest
@testable import NuvioTV

/// BUG-224: the remux read-ahead bound (`Screens/RemuxReadAhead.swift`). The pacing decision is a
/// pure function; the gate's wait/wake paths run on a real background thread against short
/// timeouts, the way the remux worker parks on it.
final class RemuxReadAheadTests: XCTestCase {

    /// 100 segments of 4 s (400 s of media) behind a 90 s bound.
    /// `pollInterval` defaults to 30 s so the timed lost-wakeup insurance cannot stand in for a
    /// missing signal: a wake test that returns within a second proves the signal path.
    private func gate(bound: Double = 90, segments: Int = 100, pollInterval: TimeInterval = 30) -> RemuxReadAhead {
        RemuxReadAhead(segmentDurationsSec: Array(repeating: 4, count: segments),
                       totalDurationSec: Double(segments) * 4, boundSec: bound, pollInterval: pollInterval)!
    }

    /// Thread-safe flag for the `interrupted` check (the session's mailbox / cancel state).
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return raised }
            set { lock.lock(); raised = newValue; lock.unlock() }
        }
    }

    private final class Parked: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = -1      // -1 = still waiting
        var value: TimeInterval {
            get { lock.lock(); defer { lock.unlock() }; return seconds }
            set { lock.lock(); seconds = newValue; lock.unlock() }
        }
    }

    /// Run `waitWhileAhead` on a background thread; the expectation fulfils when it returns, and the
    /// returned reader gives the parked seconds (-1 while it is still waiting).
    private func parkInBackground(_ gate: RemuxReadAhead, producing: Int, interrupted: Flag,
                                  returned: XCTestExpectation) -> () -> TimeInterval {
        let parked = Parked()
        Thread.detachNewThread {
            parked.value = gate.waitWhileAhead(producing: producing, interrupted: { interrupted.value })
            returned.fulfill()
        }
        return { parked.value }
    }

    // MARK: - Pacing decision (pure)

    func testShouldParkAtAndPastTheBound() {
        XCTAssertFalse(RemuxReadAhead.shouldPark(producedSec: 89.9, requestedSec: 0, boundSec: 90))
        XCTAssertTrue(RemuxReadAhead.shouldPark(producedSec: 90, requestedSec: 0, boundSec: 90))
        XCTAssertTrue(RemuxReadAhead.shouldPark(producedSec: 500, requestedSec: 300, boundSec: 90))
        XCTAssertFalse(RemuxReadAhead.shouldPark(producedSec: 380, requestedSec: 300, boundSec: 90))
    }

    func testProductionBehindTheRequestNeverParks() {
        // Start-up / a seek ahead of the frontier: the player waits on production, never the reverse.
        XCTAssertFalse(RemuxReadAhead.shouldPark(producedSec: 8, requestedSec: 40, boundSec: 90))
    }

    func testZeroOrInvalidBoundNeverParks() {
        XCTAssertFalse(RemuxReadAhead.shouldPark(producedSec: 7_000, requestedSec: 0, boundSec: 0))
        XCTAssertFalse(RemuxReadAhead.shouldPark(producedSec: 7_000, requestedSec: 0, boundSec: -5))
        XCTAssertFalse(RemuxReadAhead.shouldPark(producedSec: 7_000, requestedSec: 0, boundSec: .infinity))
        XCTAssertFalse(RemuxReadAhead.shouldPark(producedSec: .nan, requestedSec: 0, boundSec: 90))
    }

    // MARK: - Knob

    func testKnobParsing() throws {
        let suite = "RemuxReadAheadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = RemuxReadAhead.boundKey
        XCTAssertEqual(key, "debug.remuxReadAheadSeconds")
        XCTAssertEqual(RemuxReadAhead.defaultBoundSec, 90)

        XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), 90, "unset = default")
        defaults.set("0", forKey: key)
        XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), 0, "launch-argument 0 = unbounded")
        defaults.set(0, forKey: key)
        XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), 0, "0 = unbounded")
        defaults.set("120", forKey: key)
        XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), 120)
        defaults.set(60.5, forKey: key)
        XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), 60.5)
        defaults.set(10, forKey: key)
        XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), RemuxReadAhead.minimumBoundSec,
                       "floored at AVPlayer's forward buffer")
        defaults.set(-5, forKey: key)
        XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), 90, "negative = default")
        defaults.set("fast", forKey: key)
        XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), 90, "non-numeric = default")
        // NSString's doubleValue reads "0x10" as 0 (= unbounded); Swift's parse reads the hex as 16,
        // floored to 24. Never unbounded by accident.
        defaults.set("0x10", forKey: key)
        XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), RemuxReadAhead.minimumBoundSec)
        // Non-finite or empty strings.
        for text in ["nan", "inf", "-inf", ""] {
            defaults.set(text, forKey: key)
            XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), 90, "\"\(text)\" = default")
        }
        defaults.set(" 45 ", forKey: key)
        XCTAssertEqual(RemuxReadAhead.resolveBound(from: defaults), 45, "whitespace trimmed")
    }

    // MARK: - Idle re-open rule

    func testIdleReopenOnlyShortlyAfterALongPark() {
        XCTAssertEqual(RemuxReadAhead.idleParkSec, 20)
        XCTAssertEqual(RemuxReadAhead.idleReopenWindowSegments, 3)
        // No long park in the session: a read error keeps the old path (fail to mpv).
        XCTAssertFalse(RemuxReadAhead.idleReopenApplies(lastLongParkSegment: nil, failedAtSegment: 40))
        // Within the window after a long park ended at segment 40.
        for seg in 40...43 {
            XCTAssertTrue(RemuxReadAhead.idleReopenApplies(lastLongParkSegment: 40, failedAtSegment: seg), "\(seg)")
        }
        // Long after it, or behind it (a reposition moved production back): ordinary error.
        XCTAssertFalse(RemuxReadAhead.idleReopenApplies(lastLongParkSegment: 40, failedAtSegment: 44))
        XCTAssertFalse(RemuxReadAhead.idleReopenApplies(lastLongParkSegment: 40, failedAtSegment: 12))
    }

    private func step(seekFailed: Bool = false, reopening: Bool = false, repositioned: Bool,
                      canReopen: Bool = true, idle: Bool = false, parks: Int = 0) -> RemuxReadAhead.FailureStep {
        RemuxReadAhead.afterFailure(seekFailed: seekFailed, reopening: reopening, everRepositioned: repositioned,
                                    canReopen: canReopen, idleReopenApplies: idle, consecutiveErrorParks: parks)
    }

    func testFailedReopenOfALinearSessionFailsInsteadOfParking() {
        // The re-open's seek or scan failed and nothing ever repositioned: nothing would wake the park.
        XCTAssertEqual(step(seekFailed: true, reopening: true, repositioned: false), .fail)
        // A seek that is not a re-open, or a session that has repositioned: the error park as before.
        XCTAssertEqual(step(seekFailed: true, reopening: false, repositioned: true), .park)
        XCTAssertEqual(step(seekFailed: true, reopening: false, repositioned: false), .park)
    }

    func testRepositionDuringAReopenScanTakesTheErrorPark() {
        // A newer target interrupted the re-open's scan: the worker marks the session repositioned
        // (`reopening` stays set until a segment finalizes). A failed scan for that target, and a
        // later read error or short EOF away from the park, take the self-healing path.
        XCTAssertEqual(step(seekFailed: true, reopening: true, repositioned: true), .park)
        XCTAssertEqual(step(reopening: true, repositioned: true), .park)
    }

    func testRunFailureReopensOnlyNearALongParkAndUnderTheCap() {
        XCTAssertEqual(step(repositioned: false, idle: true), .reopen)
        XCTAssertEqual(step(repositioned: true, idle: true, parks: 2), .reopen)
        // Third consecutive failure, or a write error: the old path.
        XCTAssertEqual(step(repositioned: false, idle: true, parks: 3), .fail)
        XCTAssertEqual(step(repositioned: true, idle: true, parks: 3), .park)
        XCTAssertEqual(step(repositioned: false, canReopen: false, idle: true), .fail)
        // Away from a long park: linear fails to mpv, repositioned self-heals.
        XCTAssertEqual(step(repositioned: false), .fail)
        XCTAssertEqual(step(repositioned: true), .park)
    }

    func testUnboundedOrUnknownDurationBuildsNoGate() throws {
        XCTAssertNil(RemuxReadAhead(segmentDurationsSec: [4, 4], totalDurationSec: 8, boundSec: 0),
                     "knob 0: no gate, the worker runs as before")
        XCTAssertNil(RemuxReadAhead(segmentDurationsSec: [4, 4], totalDurationSec: 0, boundSec: 90),
                     "unknown duration: unbounded")
        XCTAssertNil(RemuxReadAhead(segmentDurationsSec: [], totalDurationSec: 8, boundSec: 90))
        let kf: [Int64] = stride(from: 0, to: 400_000, by: 4_000).map { Int64($0) }
        let map = try XCTUnwrap(SegmentMap.build(keyframeTicks: kf, timeBaseNum: 1, timeBaseDen: 1000,
                                                 totalDurationSec: 400, segDurSec: 4))
        let fromMap = try XCTUnwrap(RemuxReadAhead(map: map, boundSec: 90))
        XCTAssertEqual(fromMap.boundSec, 90)
        XCTAssertFalse(fromMap.isAhead(producing: 23), "segment 23 starts at 88 s")
        XCTAssertTrue(fromMap.isAhead(producing: 24), "segment 24 starts at 92 s")
    }

    // MARK: - Reference request

    func testBeforeAnyRequestTheBoundCountsFromSegmentOne() {
        let g = gate()
        XCTAssertEqual(g.latestRequested, 1)
        XCTAssertFalse(g.isAhead(producing: 1), "the first segments are never held back")
        XCTAssertFalse(g.isAhead(producing: 23))
        XCTAssertTrue(g.isAhead(producing: 24))
    }

    func testMostRecentRequestNotHighest() {
        // Seek back: the player asked for 80, then 10. The frontier at 40 is 120 s past 10 → park,
        // even though it is behind the highest request ever made.
        let g = gate()
        g.noteRequest(segment: 80)
        XCTAssertFalse(g.isAhead(producing: 40))
        g.noteRequest(segment: 10)
        XCTAssertEqual(g.latestRequested, 10)
        XCTAssertTrue(g.isAhead(producing: 40))
    }

    func testRepositionTargetResetsTheBound() {
        // A reposition is a request for its target: the new run starts AT the reference (no lead)
        // and may run the full bound past it.
        let g = gate()
        g.noteRequest(segment: 5)
        XCTAssertTrue(g.isAhead(producing: 60))
        g.noteRequest(segment: 60)
        XCTAssertFalse(g.isAhead(producing: 60), "a seek target is served at once")
        XCTAssertFalse(g.isAhead(producing: 82))
        XCTAssertTrue(g.isAhead(producing: 83))
    }

    func testOutOfRangeRequestsAreIgnored() {
        let g = gate()
        g.noteRequest(segment: 50)
        g.noteRequest(segment: 0)
        g.noteRequest(segment: 101)
        XCTAssertEqual(g.latestRequested, 50)
    }

    // MARK: - Wait / wake

    func testNotAheadReturnsWithoutParking() {
        let g = gate()
        XCTAssertEqual(g.waitWhileAhead(producing: 10, interrupted: { false }), 0)
    }

    func testRequestPastTheBoundResumesProduction() {
        let g = gate()
        let interrupted = Flag()
        let returned = expectation(description: "worker resumes")
        let parked = parkInBackground(g, producing: 40, interrupted: interrupted, returned: returned)
        // Still parked while requests stay more than 90 s behind segment 40 (156 s).
        Thread.sleep(forTimeInterval: 0.3)
        g.noteRequest(segment: 2)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(parked(), -1, "a request that keeps the lead at the bound must not wake it for good")
        // Segment 18 starts at 68 s: the lead drops to 88 s < 90 s.
        g.noteRequest(segment: 18)
        wait(for: [returned], timeout: 1)
        XCTAssertGreaterThan(parked(), 0)
    }

    func testRepositionOrAudioSwitchWakesTheWorker() {
        let g = gate()
        let interrupted = Flag()
        let returned = expectation(description: "worker wakes for the mailbox")
        let parked = parkInBackground(g, producing: 40, interrupted: interrupted, returned: returned)
        Thread.sleep(forTimeInterval: 0.2)
        interrupted.value = true          // RemuxSession.reposition / selectAudio publish, then kick
        g.kick()
        wait(for: [returned], timeout: 1)
        XCTAssertGreaterThan(parked(), 0)
    }

    func testCancellationWithoutAKickStillReturns() {
        // Lost-wakeup insurance: stop() always kicks, but the timed wait must not depend on it.
        let g = gate(pollInterval: 0.25)
        let interrupted = Flag()
        let returned = expectation(description: "cancel ends the park")
        _ = parkInBackground(g, producing: 40, interrupted: interrupted, returned: returned)
        Thread.sleep(forTimeInterval: 0.1)
        interrupted.value = true
        wait(for: [returned], timeout: 2)
    }

    func testAlreadyInterruptedNeverParks() {
        let g = gate()
        XCTAssertEqual(g.waitWhileAhead(producing: 40, interrupted: { true }), 0)
    }

    func testEOFAndOutOfRangeProducingNeverPark() {
        // The worker reaches EOF with currentSeg == map.count and then parks in parkForRequest, not
        // here; nothing past the map can hold it, whatever the lead.
        let g = gate()
        XCTAssertEqual(g.waitWhileAhead(producing: 101, interrupted: { false }), 0)
        XCTAssertEqual(g.waitWhileAhead(producing: 0, interrupted: { false }), 0)
        // The last segment can be held (the player is far behind) and wakes on the next request.
        XCTAssertTrue(g.isAhead(producing: 100))
        let returned = expectation(description: "last segment resumes")
        _ = parkInBackground(g, producing: 100, interrupted: Flag(), returned: returned)
        Thread.sleep(forTimeInterval: 0.1)
        g.noteRequest(segment: 90)
        wait(for: [returned], timeout: 1)
    }

    // MARK: - Session side

    private func session() -> RemuxSession {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readahead-session-\(UUID().uuidString)")
        return RemuxSession(config: .init(url: URL(string: "http://127.0.0.1:9/never.mkv")!), outputDir: dir)
    }

    /// stop() while the worker is parked on the bound wakes it at once (not on the poll).
    func testSessionStopWakesAParkedWorker() {
        let s = session()
        defer { s.scheduleCleanup() }
        let g = gate()
        s.installReadAhead(g)
        let returned = expectation(description: "stop wakes the park")
        Thread.detachNewThread {
            _ = g.waitWhileAhead(producing: 40, interrupted: { s.readAheadInterrupted() })
            returned.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        s.stop()
        wait(for: [returned], timeout: 1)
    }

    /// reposition() publishes the mailbox, then kicks the parked worker; noteSegmentRequest()
    /// reaches the gate.
    func testSessionRepositionKicksAndRequestsReachTheGate() {
        let s = session()
        defer { s.stop(); s.scheduleCleanup() }
        let g = gate()
        s.installReadAhead(g)
        s.noteSegmentRequest(7)
        XCTAssertEqual(g.latestRequested, 7)
        s.noteSegmentRequest(1)
        let returned = expectation(description: "reposition wakes the park")
        Thread.detachNewThread {
            _ = g.waitWhileAhead(producing: 40, interrupted: { s.readAheadInterrupted() })
            returned.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(s.readAheadInterrupted())
        s.reposition(toSegment: 80)
        wait(for: [returned], timeout: 1)
        XCTAssertTrue(s.readAheadInterrupted(), "the target waits in the mailbox for the worker")
    }

    // MARK: - Server wiring

    /// The loopback server reports every media request (from disk too) and never an I-frame or
    /// playlist request.
    func testServerNotesMediaRequestsOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readahead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("seg-00003.m4s"))
        try Data([4, 5]).write(to: dir.appendingPathComponent("aud-1-00004.m4s"))
        let kf: [Int64] = stride(from: 0, to: 40_000, by: 4_000).map { Int64($0) }
        let map = try XCTUnwrap(SegmentMap.build(keyframeTicks: kf, timeBaseNum: 1, timeBaseDen: 1000,
                                                 totalDurationSec: 40, segDurSec: 4))
        let sig = VideoSignaling(codecs: "avc1.640028", supplementalCodecs: nil, videoRange: nil,
                                 width: 1920, height: 1080, frameRate: 24)
        let noted = NotedSegments()
        let server = LocalHLSServer(rootDir: dir, map: map, signaling: sig, bandwidth: 8_000_000,
                                    iFrames: true,
                                    producingInfo: { (5, nil) }, requestReposition: { _ in },
                                    noteSegmentRequest: { noted.add($0) })
        defer { server.stop() }
        let started = expectation(description: "server up")
        var master: URL?
        server.start(masterName: "master.m3u8") { url in master = url; started.fulfill() }
        wait(for: [started], timeout: 5)
        let base = try XCTUnwrap(master).deletingLastPathComponent()

        func get(_ name: String) {
            let done = expectation(description: name)
            URLSession.shared.dataTask(with: base.appendingPathComponent(name)) { _, _, _ in done.fulfill() }.resume()
            wait(for: [done], timeout: 8)
        }
        get("master.m3u8")
        get("media.m3u8")
        get("seg-00003.m4s")          // on disk
        get("aud-1-00004.m4s")        // on disk, audio rendition
        get("iframe-00003.m4s")       // must never move the frontier
        XCTAssertEqual(noted.all, [3, 4])
    }
}

private final class NotedSegments: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    func add(_ n: Int) { lock.lock(); items.append(n); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return items }
}
