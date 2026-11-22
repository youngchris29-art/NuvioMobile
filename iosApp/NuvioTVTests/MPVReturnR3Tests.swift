import XCTest
@testable import NuvioTV
import SharedCore

/// Code review W7 r3: the first-frame-safe paused start, the return-failure owner, the tracker
/// ordering across a replacement, and the played seconds a park carries.
final class MPVReturnStartModeTests: XCTestCase {
    func testRouteTimesIntent() {
        XCTAssertEqual(MPVReturnStartMode.decide(usesGpuNext: false, startsPaused: true), .loadPaused)
        XCTAssertEqual(MPVReturnStartMode.decide(usesGpuNext: true, startsPaused: true), .pauseAfterFirstFrame,
                       "gpu-next must never be paused before its first frame")
        XCTAssertEqual(MPVReturnStartMode.decide(usesGpuNext: false, startsPaused: false), .loadPlaying)
        XCTAssertEqual(MPVReturnStartMode.decide(usesGpuNext: true, startsPaused: false), .loadPlaying)
    }

    /// The pause lands with the unmute; a press asking for play during the window wins.
    func testTheFirstFrameAppliesTheLatestIntent() {
        XCTAssertTrue(MPVReturnStartMode.atFirstFrame(desiredPlaying: false).pause)
        XCTAssertFalse(MPVReturnStartMode.atFirstFrame(desiredPlaying: true).pause)
        XCTAssertTrue(MPVReturnStartMode.atFirstFrame(desiredPlaying: false).unmute)
        XCTAssertTrue(MPVReturnStartMode.atFirstFrame(desiredPlaying: true).unmute)
    }
}

final class PlayerReturnFailureOwnerTests: XCTestCase {
    func testEveryReturnFailureHasAnOwner() {
        for host in [false, true] {
            for pending in [false, true] {
                let o = PlayerReturnFailureOwner.decide(hostHasCallback: host, returnStartPending: pending)
                if host { XCTAssertEqual(o, .host) }
                else if pending { XCTAssertEqual(o, .local, "the library host has no callback: PlayerScreen owns it") }
                else { XCTAssertEqual(o, .none, "a failure after the return settled is today's") }
                if pending { XCTAssertNotEqual(o, .none) }
            }
        }
    }
}

final class MPVParkedPlayedSecondsTests: XCTestCase {
    func testTheCarriedSecondsSurviveASecondBackgroundBeforeTheLoad() {
        let i = MPVViewerIntent()
        let rows: [(carried: Double, own: Double, expected: Double, name: String)] = [
            (812, 0, 812, "mid-connect: nothing of its own yet"),
            (812, 40, 852, "after the load"),
            (0, 40, 40, "a first controller"),
            (0, 0, 0, "nothing played"),
            (.nan, -3, 0, "garbage reads as 0"),
        ]
        for r in rows {
            XCTAssertEqual(i.parked(observedSpeed: 1, observedAudioDelaySec: nil, carriedPlayedSec: r.carried,
                                    ownPlayedSec: r.own).playedSec, r.expected, r.name)
        }
    }
}

@MainActor
final class TrackerReturnChainTests: XCTestCase {
    /// A slow tracker: every dispatch waits until the test completes it.
    final class SlowBackend: PlaybackRecorderBackend {
        final class Targets: TrackerScrobbleTargets {}
        var log: [String] = []
        let name: String
        private var pending: [@MainActor () -> Void] = []
        init(_ name: String, log: [String] = []) { self.name = name; self.log = log }
        var shared: ((String) -> Void)?

        func noteSessionProgress(profileId: Int32, item: TraktItemBox, percent: Float) {}
        func writeProgress(context: PlaybackContext, snapshot: PlayerPlaybackSnapshot, flush: Bool) {}
        func buildTraktItem(context: PlaybackContext, completion: @escaping @MainActor (TraktItemBox?) -> Void) {}
        func scrobbleStart(profileId: Int32, item: TraktItemBox, percent: Float) {}
        func scrobbleStop(profileId: Int32, item: TraktItemBox, percent: Float) {}
        func openTrackerTargets(context: PlaybackContext) -> TrackerScrobbleTargets? { Targets() }
        func dispatchTracker(_ action: TrackerScrobbleDispatch, targets: TrackerScrobbleTargets, profileId: Int32,
                             percent: Double, completion: (@MainActor () -> Void)?) {
            shared?("\(name) \(action == .start ? "start" : "stop") \(Int(percent))")
            if let completion { pending.append(completion) }
        }
        func completeNext() { guard !pending.isEmpty else { return }; pending.removeFirst()() }
    }

    private func context() -> PlaybackContext {
        PlaybackContext(url: URL(string: "https://example.invalid/a.mkv")!, title: "T", contentType: "movie",
                        parentMetaId: "tt1", videoId: "tt1", season: nil, episode: nil, poster: nil, background: nil,
                        providerName: nil, providerAddonId: nil, streamTitle: nil, streamSubtitle: nil, externalSubtitles: [])
    }

    /// The old session's start is still in flight when the replacement happens: its stop is deferred
    /// behind it, the old controller goes away, and the fresh start must wait for that stop.
    func testTheFreshStartWaitsForTheReplacedStopEvenBehindASlowStart() {
        var log: [String] = []
        let oldBackend = SlowBackend("old"), newBackend = SlowBackend("new")
        oldBackend.shared = { log.append($0) }
        newBackend.shared = { log.append($0) }
        let chain = TrackerReturnChain()
        var old: TrackerScrobbleSession? = TrackerScrobbleSession(context: context(), backend: oldBackend)
        old?.start(positionSec: 100, durationSec: 1000)                  // start in flight
        let teardownHold = chain.hold()                                   // prepareForReplacement
        old?.stop(positionSec: 300, durationSec: 1000, isLive: false, settled: chain.hold(old))
        teardownHold()                                                    // teardown registered its stop
        weak var weakOld = old
        old = nil                                                         // the old controller deallocates
        XCTAssertNotNil(weakOld, "the chain keeps the old session until its stop settled")
        let fresh = TrackerScrobbleSession(context: context(), backend: newBackend)
        chain.whenIdle { fresh.start(positionSec: 300, durationSec: 1000) }
        XCTAssertEqual(log, ["old start 10"], "no stop yet (deferred), and the fresh start waits")
        oldBackend.completeNext()                                         // old start completes → deferred stop
        XCTAssertEqual(log, ["old start 10", "old stop 30"])
        XCTAssertFalse(chain.isIdle)
        oldBackend.completeNext()                                         // old stop completes
        XCTAssertEqual(log, ["old start 10", "old stop 30", "new start 30"], "stop strictly before the next start")
        XCTAssertTrue(chain.isIdle)
        XCTAssertNil(weakOld, "released once settled")
    }

    func testNothingToStopOrNoReplacementStartsAtOnce() {
        let chain = TrackerReturnChain()
        var ran = 0
        chain.whenIdle { ran += 1 }
        XCTAssertEqual(ran, 1)
        let s = TrackerScrobbleSession(context: context(), backend: SlowBackend("x"))
        var settled = 0
        s.stop(positionSec: 1, durationSec: 1000, isLive: false, settled: { settled += 1 })  // never started
        XCTAssertEqual(settled, 1)
        let release = chain.hold()
        chain.whenIdle { ran += 1 }
        release(); release()
        XCTAssertEqual(ran, 2, "released once, waiters run once")
    }

    func testAStopAfterAFinishedStartSettlesWhenItCompletes() {
        var log: [String] = []
        let b = SlowBackend("old"); b.shared = { log.append($0) }
        let s = TrackerScrobbleSession(context: context(), backend: b)
        s.start(positionSec: 0, durationSec: 1000)
        b.completeNext()
        var settled = false
        s.stop(positionSec: 500, durationSec: 1000, isLive: false, settled: { settled = true })
        XCTAssertEqual(log, ["old start 0", "old stop 50"])
        XCTAssertFalse(settled)
        b.completeNext()
        XCTAssertTrue(settled)
    }
}
