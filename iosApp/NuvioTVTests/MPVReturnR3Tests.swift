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

// MARK: - Code review W7 r4

final class MPVReturnReportedPositionTests: XCTestCase {
    func testTheHeldStartIsReportedUntilReached() {
        typealias P = MPVReturnReportedPosition
        let rows: [(held: Double?, reached: Bool, live: Double, expected: Double, name: String)] = [
            (2400, false, 0, 2400, "fresh start at FILE_LOADED: the seek is only queued"),
            (2400, false, 12, 2400, "mid-landing"),
            (2400, true, 2400.3, 2400.3, "landed: the player's own"),
            (6, false, 0, 6, "a short held start"),
            (0, false, 3, 0, "held at the top"),
            (nil, false, 12, 12, "a normal start"),
            (.nan, false, 12, 12, "an unusable held start"),
            (2400, true, .nan, 0, "garbage live reads 0"),
        ]
        for r in rows {
            XCTAssertEqual(P.position(heldStartSec: r.held, heldReached: r.reached, livePositionSec: r.live), r.expected, r.name)
        }
        XCTAssertEqual(P.heldStart(payload: .position(100), contextReturnStart: .position(5)), 100)
        XCTAssertEqual(P.heldStart(payload: nil, contextReturnStart: .position(5)), 5, "a retry's held start")
        XCTAssertNil(P.heldStart(payload: .live, contextReturnStart: .position(5)))
        XCTAssertNil(P.heldStart(payload: .normalStart, contextReturnStart: nil))
        XCTAssertNil(P.heldStart(payload: nil, contextReturnStart: nil))
    }
}

final class PlayerReturnEpochTests: XCTestCase {
    private let owner = PlaybackIdentity(accountKey: "a", profileId: 1)

    private func payload(_ g: Int) -> PlayerReturnHandoff {
        PlayerReturnHandoff(owner: owner, contextID: "c", streamKey: "k", start: .position(100), intent: .pause,
                            playedSec: 0, healthyReported: false, returnGeneration: g, freshStartsLeft: 1, audio: .auto,
                            subtitle: .auto, audioDelaySec: nil, speed: 1, origin: .mpvReturn)
    }

    /// A controller's first park, from the base the screen handed it.
    private func firstPark(base: Int) -> Int {
        let box = MPVParkBox()
        box.continueGeneration(from: base)
        return box.park()
    }

    /// return → fresh start fails → local retry (no payload) → background → the return is accepted.
    func testALocalRetryControllersFirstReturnIsAccepted() {
        var epoch = PlayerReturnEpoch()
        XCTAssertEqual(epoch.accept(payload(firstPark(base: epoch.baseForNextController)), current: owner, contextID: "c"), .accept)
        XCTAssertEqual(epoch.lastAccepted, 1)
        // The fresh controller failed; the local retry controller is created with the screen's base.
        let retryPark = firstPark(base: epoch.baseForNextController)
        XCTAssertEqual(epoch.accept(payload(retryPark), current: owner, contextID: "c"), .accept,
                       "it used to park at 1 and be refused as already accepted")
        // Before r4 the retry started at 0: its first park was refused.
        XCTAssertEqual(epoch.accept(payload(firstPark(base: 0)), current: owner, contextID: "c"), .discard(.generation))
    }

    /// The picker's retry builds a new PlayerScreen (a new epoch): its first return is accepted too.
    func testAPickerRetryStartsANewEpoch() {
        var old = PlayerReturnEpoch()
        _ = old.accept(payload(1), current: owner, contextID: "c")
        var fresh = PlayerReturnEpoch()
        XCTAssertEqual(fresh.accept(payload(firstPark(base: fresh.baseForNextController)), current: owner, contextID: "c"), .accept)
    }

    func testAContextChangeStartsOver() {
        var e = PlayerReturnEpoch()
        _ = e.accept(payload(3), current: owner, contextID: "c")
        e.reset()
        XCTAssertEqual(e.baseForNextController, 0)
    }
}

@MainActor
final class TrackerOwnerGateTests: XCTestCase {
    private func context() -> PlaybackContext {
        PlaybackContext(url: URL(string: "https://example.invalid/a.mkv")!, title: "T", contentType: "movie",
                        parentMetaId: "tt1", videoId: "tt1", season: nil, episode: nil, poster: nil, background: nil,
                        providerName: nil, providerAddonId: nil, streamTitle: nil, streamSubtitle: nil, externalSubtitles: [])
    }

    /// r4-2: the identity changes while the old start is in flight: the deferred stop is dropped, and
    /// the chain is released so the fresh start is not blocked.
    func testADeferredStopAfterAnIdentityChangeIsDroppedAndReleasesTheChain() {
        var log: [String] = []
        let backend = TrackerReturnChainTests.SlowBackend("old")
        backend.shared = { log.append($0) }
        let owner = PlaybackIdentity(accountKey: "a", profileId: 1)
        var current = owner
        let chain = TrackerReturnChain()
        let old = TrackerScrobbleSession(context: context(), owner: owner, identity: { current }, backend: backend)
        old.start(positionSec: 100, durationSec: 1000)
        old.stop(positionSec: 300, durationSec: 1000, isLive: false, settled: chain.hold(old))
        var freshStarted = false
        chain.whenIdle { freshStarted = true }
        current = PlaybackIdentity(accountKey: "a", profileId: 2)   // profile switched before the start completed
        backend.completeNext()
        XCTAssertEqual(log, ["old start 10"], "the deferred stop is dropped after the change")
        XCTAssertTrue(freshStarted, "the chain is released")
        XCTAssertTrue(chain.isIdle)
    }

    func testAHoldThatNeverSettlesTimesOut() {
        let chain = TrackerReturnChain()
        _ = chain.hold(nil, timeoutSec: 0.05)
        let ran = expectation(description: "released by the timeout")
        chain.whenIdle { ran.fulfill() }
        wait(for: [ran], timeout: 2)
    }
}
