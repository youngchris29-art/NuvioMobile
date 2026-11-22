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
    /// r5-4/5: every start PlayerScreen creates has an owner, return or not.
    func testEveryStartHasAnOwner() {
        XCTAssertEqual(PlayerReturnFailureOwner.decide(hostHasCallback: true, localOwnerAvailable: true), .host)
        XCTAssertEqual(PlayerReturnFailureOwner.decide(hostHasCallback: true, localOwnerAvailable: false), .host)
        XCTAssertEqual(PlayerReturnFailureOwner.decide(hostHasCallback: false, localOwnerAvailable: true), .local,
                       "the library: PlayerScreen's alert, a local retry's second failure included")
        XCTAssertEqual(PlayerReturnFailureOwner.decide(hostHasCallback: false, localOwnerAvailable: false), .none)
    }

    func testTheLocalRetryStart() {
        var f = PlaybackFailure(reason: "r", positionSec: 812, secondsPlayed: 90, startedPlaying: true)
        XCTAssertEqual(PlayerReturnFailureOwner.localRetryStart(for: f), .position(812), "an ordinary start that played")
        f.returnRecovery = .position(1265.8)
        XCTAssertEqual(PlayerReturnFailureOwner.localRetryStart(for: f), .position(1265.8), "a return's held start wins")
        let never = PlaybackFailure(reason: "r", positionSec: 0, secondsPlayed: 0, startedPlaying: false)
        XCTAssertEqual(PlayerReturnFailureOwner.localRetryStart(for: never), .normalStart)
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
    typealias P = MPVReturnReportedPosition

    func testTheHeldStartIsReportedUntilReachedThenTheLandingUntilTheClockCatchesUp() {
        var r = P(heldStartSec: 2400)
        XCTAssertEqual(r.position(livePositionSec: 0), 2400, "FILE_LOADED: the seek is only queued")
        r.clockSample(0)
        r.seekLanded(atSec: 50)
        XCTAssertEqual(r.position(livePositionSec: 0), 2400, "held until reached")
        r.reached(landedSec: 2400.2)
        // r5-3: an exit right after the landing, before the next poll, reports the landing, not 0.
        XCTAssertEqual(r.position(livePositionSec: 0), 2400.2)
        r.clockSample(0)
        XCTAssertEqual(r.position(livePositionSec: 0), 2400.2, "a stale 0 sample has not caught up")
        r.clockSample(2400.2)
        XCTAssertEqual(r.phase, .clock)
        XCTAssertEqual(r.position(livePositionSec: 2405), 2405)
    }

    func testALaterSeekLandingMovesTheReferenceUntilTheClockFollows() {
        var r = P(heldStartSec: 100)
        r.reached(landedSec: nil)
        XCTAssertEqual(r.position(livePositionSec: 0), 100, "reached at the held start itself")
        r.clockSample(100.5)
        r.seekLanded(atSec: 900)
        XCTAssertEqual(r.position(livePositionSec: 100.6), 900)
        r.clockSample(899.6)
        XCTAssertEqual(r.position(livePositionSec: 899.6), 899.6)
    }

    func testANormalStartIsTheClockFromTheBeginning() {
        var r = P(heldStartSec: nil)
        XCTAssertEqual(r.position(livePositionSec: 12), 12)
        r.reached(landedSec: 50)
        XCTAssertEqual(r.position(livePositionSec: 12), 12)
        XCTAssertEqual(P(heldStartSec: .nan).phase, .clock)
        XCTAssertEqual(P(heldStartSec: 0).position(livePositionSec: 3), 0, "held at the top")
    }

    func testHeldStart() {
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


// MARK: - Code review W7 r5

final class PlayerReturnTransferStartTests: XCTestCase {
    typealias T = PlayerReturnTransfer
    func testThreeWay() {
        XCTAssertEqual(T.start(heldSec: 0, startedBeforeBackground: false, restartTargetSec: nil), .normalStart,
                       "held 0 before the engine was ready: mpv runs today's resume lookup")
        XCTAssertEqual(T.start(heldSec: 0, startedBeforeBackground: false, restartTargetSec: 1265.8), .position(1265.8),
                       "the from-scratch restart read the saved resume point, then failed")
        XCTAssertEqual(T.start(heldSec: 300, startedBeforeBackground: true, restartTargetSec: nil), .position(300))
        XCTAssertEqual(T.start(heldSec: 0, startedBeforeBackground: true, restartTargetSec: nil), .position(0), "it had played from the top")
        XCTAssertEqual(T.start(heldSec: 300, startedBeforeBackground: true, restartTargetSec: 301), .position(301))
        XCTAssertEqual(T.start(heldSec: .nan, startedBeforeBackground: true, restartTargetSec: .nan), .normalStart)
    }
}

final class PlayerFallbackRouteTests: XCTestCase {
    private let p = PlayerReturnTransfer(owner: PlaybackIdentity(accountKey: "a", profileId: 1), intent: .pause,
                                         start: .position(10), generation: 2)
        .payload(contextID: "c", streamKey: "k", origin: .nativeReturn, playedSec: 0)

    func testEveryCallerGetsOneObeyedRoute() {
        XCTAssertEqual(PlayerFallbackRoute.decide(transfer: nil, validation: nil), .plain)
        XCTAssertEqual(PlayerFallbackRoute.decide(transfer: p, validation: .accept), .returnPayload(p))
        XCTAssertEqual(PlayerFallbackRoute.decide(transfer: p, validation: .discard(.owner)), .exit,
                       "the old stream never starts under the new profile")
        XCTAssertEqual(PlayerFallbackRoute.decide(transfer: p, validation: .discard(.generation)), .plain)
        XCTAssertEqual(PlayerFallbackRoute.decide(transfer: p, validation: .discard(.context)), .plain)
    }

    /// The epoch the screen validates with: an owner switched after the native failed phase.
    func testAnOwnerChangeBeforeTheCallbackExits() {
        var epoch = PlayerReturnEpoch()
        let v = epoch.accept(p, current: PlaybackIdentity(accountKey: "a", profileId: 2), contextID: "c")
        XCTAssertEqual(PlayerFallbackRoute.decide(transfer: p, validation: v), .exit)
        XCTAssertEqual(epoch.lastAccepted, 0, "nothing accepted")
    }
}

final class MPVStartDeadlineTests: XCTestCase {
    func testAStallAfterAnAcceptedSeekFires() {
        var d = MPVStartDeadline(limitSec: 45)
        d.begin(now: 100)
        XCTAssertFalse(d.poll(now: 144))
        XCTAssertTrue(d.poll(now: 145), "the start never completed: one bounded end")
        XCTAssertFalse(d.poll(now: 500), "once")
    }

    func testBackgroundMidStallDoesNotFire() {
        var d = MPVStartDeadline(limitSec: 45)
        d.begin(now: 0)
        d.suspend(now: 30)
        XCTAssertFalse(d.poll(now: 1000), "no time counts while away or parked")
        d.resume(now: 1000)
        XCTAssertFalse(d.poll(now: 1014))
        XCTAssertTrue(d.poll(now: 1015), "30 s before + 15 s after")
    }

    func testCompletionOrACancellingViewerSeekEndsIt() {
        var d = MPVStartDeadline(limitSec: 45)
        d.begin(now: 0)
        d.complete()
        XCTAssertFalse(d.poll(now: 1000))
        d.begin(now: 0)
        XCTAssertEqual(d.phase, .done, "a completed deadline never starts again")
        var idle = MPVStartDeadline()
        XCTAssertFalse(idle.poll(now: 1000), "a normal start has none")
        idle.resume(now: 5)
        XCTAssertFalse(idle.isRunning)
    }
}
