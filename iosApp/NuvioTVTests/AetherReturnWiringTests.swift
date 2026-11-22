import XCTest
import NuvioAether
@testable import NuvioTV

/// Return from background, wave 2 (spec 9.2): `AetherReturnEffectRunner` driven with a fake session, a
/// fake controller host and a manual timer clock. The rule's tables are `PlayerForegroundReturnRuleTests`;
/// these pin the order the runner runs them in and what reaches the session and the controller.
@MainActor
final class AetherReturnWiringTests: XCTestCase {

    // MARK: Fakes

    @MainActor
    final class Session: AetherReturnSession {
        var needsForegroundRestore = true
        /// Like the façade's `@Published` latch: subscribers hear the new value in willSet, while the
        /// property still reads the old one (W5 r4).
        var firstFrameShown = true {
            willSet { if newValue != firstFrameShown { onFrame?(newValue) } }
        }
        var onFrame: ((Bool) -> Void)?
        var restoreResult: Result<AetherForegroundRestoreOutcome, Error> = .success(.reloaded)
        var restores = 0
        var seeks: [Double] = []
        var log: [String]

        init(log: [String] = []) { self.log = log }

        func restoreAfterBackground() async throws -> AetherForegroundRestoreOutcome {
            restores += 1
            log.append("restoreAfterBackground")
            firstFrameShown = false
            let outcome = try restoreResult.get()
            if outcome == .reloaded { needsForegroundRestore = false }
            return outcome
        }

        func seek(toSec target: Double, exact: Bool) async -> AetherSeekOutcome {
            seeks.append(target)
            return .landed(atSec: target)
        }
    }

    /// The tracker sink the controller owns: the runner has no path to it, so a restore can neither start
    /// nor stop a tracker. Counted to say so.
    @MainActor
    final class Recording: PlaybackRecording {
        var records = 0, traktStarts = 0, traktStops = 0, trackerStarts = 0, trackerStops = 0
        func pendingResumePercent() -> Double? { nil }
        func resumePositionSec(actualDurationSec: Double) -> Double? { nil }
        func record(positionSec: Double, durationSec: Double, isPaused: Bool, speed: Double, flush: Bool, isLive: Bool) { records += 1 }
        func startTrakt(positionSec: Double, durationSec: Double) { traktStarts += 1 }
        func stopTrakt(positionSec: Double, durationSec: Double, isLive: Bool) { traktStops += 1 }
        func startTrackers(positionSec: Double, durationSec: Double) { trackerStarts += 1 }
        func stopTrackers(positionSec: Double, durationSec: Double, isLive: Bool) { trackerStops += 1 }
    }

    @MainActor
    final class Host: AetherReturnHost {
        let session: Session
        var identity = PlaybackIdentity(accountKey: "user-1", profileId: 1)
        var presence: PlayerPresence = .front
        var settled = false
        var clock: Double? = 121
        var position: Double = 120
        var operationInFlight = false
        var sessionFailed = false
        var pendingSeek: Double?
        var calls: [String] = []
        var held: [Double?] = []
        var handOffs: [Double] = []
        var restoreLoads: [Double] = []
        var plays = 0, pauses = 0, exits = 0, rearms = 0, watchdogStops = 0
        var ui: [PlayerReturnUI] = []
        let recording = Recording()

        init(session: Session) { self.session = session }

        func returnSnapshot(enteredAtUptime: TimeInterval) -> PlayerBackgroundSnapshot {
            PlayerBackgroundSnapshot(route: .aetherLoopback, phase: .playing, positionSec: position,
                                     pendingSeekTargetSec: pendingSeek, enteredAtUptime: enteredAtUptime, audioTrackID: 2,
                                     subtitleTrackID: 3, subtitleDecided: true, audioName: nil, subtitleName: nil)
        }

        func returnFacts(enteredBackground: Bool, awaySec: Double) -> PlayerReturnFacts {
            PlayerReturnFacts(identity: identity, enteredBackground: enteredBackground, awaySec: awaySec,
                              presence: presence, contextSwapPending: false, operationInFlight: operationInFlight,
                              aetherNeedsRestore: session.needsForegroundRestore, aetherSessionFailed: sessionFailed,
                              clockSec: clock, nativeHealth: .notApplicable)
        }

        func returnBackstopSample(now: TimeInterval) -> PlayerBackstopSample {
            PlayerBackstopSample(now: now, clockSec: clock, userPaused: false, reportsPlaying: true, reportsBuffering: false)
        }

        var returnIdentity: PlaybackIdentity { identity }
        var returnPresence: PlayerPresence { presence }
        var returnTransportSettled: Bool { settled }
        var returnClockSec: Double? { clock }
        var returnRestoreBudgetSec: Double { 25 }

        func returnActivateAudioSession() async { calls.append("audio"); session.log.append("audio") }
        func returnRestoreWillInvoke() { calls.append("willInvoke"); session.log.append("watchdog") }
        func returnRunRestoreLoad(atSec: Double) { restoreLoads.append(atSec) }
        func returnPlay() { plays += 1 }
        func returnPause() { pauses += 1 }
        func returnHandOff(atSec: Double, reason: String) { handOffs.append(atSec); calls.append("handOff \(reason)") }
        func returnExit() { exits += 1 }
        func returnSetUI(_ ui: PlayerReturnUI) { self.ui.append(ui) }
        func returnSetHeldPosition(_ sec: Double?) { held.append(sec) }
        var refused: [Bool] = []
        func returnSetTransportRefused(_ refused: Bool) { self.refused.append(refused) }
        func returnStopStartWatchdog() { watchdogStops += 1 }
        func returnRearmStartBudget() { rearms += 1 }
    }

    /// Timers that fire only when a test says so.
    @MainActor
    final class Clock {
        final class Timer: AetherReturnTimer {
            let seconds: Double
            var body: (@MainActor () -> Void)?
            init(seconds: Double, body: @escaping @MainActor () -> Void) { self.seconds = seconds; self.body = body }
            func cancel() { body = nil }
        }
        var timers: [Timer] = []
        var now: TimeInterval = 1000
        var schedule: AetherReturnSchedule {
            { [unowned self] seconds, body in
                let t = Timer(seconds: seconds, body: body)
                self.timers.append(t)
                return t
            }
        }
        /// Fires every live timer scheduled for `seconds`.
        func fire(_ seconds: Double) {
            for t in timers where t.seconds == seconds {
                let b = t.body
                t.body = nil
                b?()
            }
        }
        var live: [Double] { timers.filter { $0.body != nil }.map(\.seconds) }
    }

    private var session: Session!
    private var host: Host!
    private var clock: Clock!
    private var runner: AetherReturnEffectRunner!

    override func setUp() async throws {
        session = Session()
        host = Host(session: session)
        clock = Clock()
        runner = AetherReturnEffectRunner(owner: host.identity, session: session, host: host,
                                          schedule: clock.schedule, now: { [unowned self] in self.clock.now })
        session.onFrame = { [unowned self] shown in self.runner.frameChanged(shown) }
    }

    /// Lets the restore sequence's tasks run.
    private func drain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// Background then return with a teardown owed: the reload starts and its watchdog is armed.
    private func returnAndReload() async {
        session.firstFrameShown = true
        runner.enteredBackground()
        clock.now += 30
        runner.becameActive()
        await drain()
    }

    private func settleTransport(picture: Bool = true) {
        host.settled = true
        session.firstFrameShown = picture
        runner.sessionStateChanged()
    }

    // MARK: Order and transport

    func testAReloadRestoreRunsAudioThenWatchdogThenTheEngineCall() async {
        await returnAndReload()
        XCTAssertEqual(session.log, ["audio", "watchdog", "restoreAfterBackground"])
        XCTAssertEqual(runner.rule.mode, .restoring)
        XCTAssertEqual(clock.live, [25], "the restore budget is armed once, before the engine call")
        XCTAssertTrue(runner.transportRefused)
        XCTAssertEqual(host.restoreLoads, [], "the reload path sends no load request (I8)")
    }

    func testNoSessionTransportWhileRestoringAndTheReturnEndsPaused() async {
        await returnAndReload()
        runner.userToggle(transportPaused: true)
        runner.userToggle(transportPaused: true)
        XCTAssertEqual(host.plays, 0)
        XCTAssertEqual(host.pauses, 0, "presses during the restore only record the intent")
        settleTransport()
        XCTAssertEqual(runner.rule.mode, .idle)
        XCTAssertEqual(host.plays, 0)
        XCTAssertEqual(host.pauses, 1, "A: comes back paused")
        XCTAssertFalse(runner.transportRefused)
        XCTAssertEqual(clock.live, [], "the restore budget stood down")
    }

    func testAPlayQueuedDuringTheRestoreIsAppliedOnceAtTheSettle() async {
        await returnAndReload()
        runner.userToggle(transportPaused: true)
        settleTransport()
        XCTAssertEqual(host.plays, 1)
        XCTAssertEqual(host.pauses, 0)
        runner.sessionStateChanged()
        XCTAssertEqual(host.plays, 1, "exactly one")
    }

    func testTheRestoreSettlesOnlyWithAFrame() async {
        await returnAndReload()
        settleTransport(picture: false)
        XCTAssertEqual(runner.rule.mode, .restoring, "transport settled, no frame: not done (I9)")
        XCTAssertEqual(Set(clock.live), [25, 3], "the watchdog stays armed and the nudge is scheduled")
        clock.fire(3)
        await drain()
        XCTAssertEqual(session.seeks, [121], "one exact seek to the adopted position")
        session.firstFrameShown = true
        runner.sessionStateChanged()
        XCTAssertEqual(runner.rule.mode, .idle)
        XCTAssertEqual(host.pauses, 1)
    }

    func testTheWatchdogWithNoFrameHandsOffAtTheHeldPosition() async {
        await returnAndReload()
        settleTransport(picture: false)
        clock.fire(25)
        XCTAssertEqual(host.handOffs, [121])
        XCTAssertTrue(host.calls.contains("handOff aether: foregroundRestoreFailed (timedOut)"))
        XCTAssertEqual(runner.rule.mode, .finished)
    }

    // MARK: Position (I6)

    func testThePositionIsHeldFromBackgroundAndReleasedOnceAtTheSettle() async {
        await returnAndReload()
        XCTAssertEqual(runner.heldPosition, 120, "clock samples (the reload zeroes the clock) never reach the mirror")
        settleTransport()
        XCTAssertNil(runner.heldPosition)
        XCTAssertEqual(host.held, [120, 121, nil], "the landed clock is held, then released into the mirror")
    }

    func testTeardownDuringTheRestoreReleasesTheHeldPositionAndReportsNoFailure() async {
        await returnAndReload()
        runner.cancelled()
        XCTAssertEqual(host.held, [120, nil], "released into the mirror the teardown flush reads")
        XCTAssertEqual(host.handOffs, [])
        XCTAssertEqual(clock.live, [])
        XCTAssertEqual(runner.rule.mode, .finished)
        settleTransport()
        XCTAssertEqual(host.pauses, 0, "nothing after the cancel")
        XCTAssertEqual(host.recording.traktStarts + host.recording.trackerStarts, 0)
        XCTAssertEqual(host.recording.traktStops + host.recording.trackerStops, 0)
    }

    // MARK: Identity (I7)

    func testAnIdentityChangeBetweenTheReloadAndTheSettleNeverPlays() async {
        await returnAndReload()
        runner.userToggle(transportPaused: true)
        host.identity = PlaybackIdentity(accountKey: "user-1", profileId: 2)
        settleTransport()
        XCTAssertEqual(host.plays, 0)
        XCTAssertEqual(host.handOffs, [])
        XCTAssertEqual(host.exits, 1)
        XCTAssertEqual(runner.rule.mode, .abandoned)
    }

    func testAnIdentityChangeWhileTheSequenceWaitsDropsItAndExits() async {
        session.firstFrameShown = true
        runner.enteredBackground()
        runner.becameActive()
        host.identity = PlaybackIdentity(accountKey: "user-2", profileId: 1)
        await drain()
        XCTAssertEqual(session.restores, 0, "the re-check failed: the engine is never called")
        XCTAssertEqual(host.exits, 1, "the dropped sequence re-asks at once and abandons")
        XCTAssertEqual(runner.rule.mode, .abandoned)
    }

    // MARK: Refusal, failure (D, E, I8)

    func testARefusedReloadSendsExactlyOneFreshLoadAtTheHeldPosition() async {
        session.restoreResult = .success(.refused(.notSeekable))
        await returnAndReload()
        XCTAssertEqual(host.restoreLoads, [120])
        XCTAssertEqual(runner.rule.mode, .restoring)
        session.firstFrameShown = true
        host.settled = true
        runner.loadReturned()
        XCTAssertEqual(runner.rule.mode, .idle)
        XCTAssertEqual(host.pauses, 1)
        XCTAssertEqual(host.restoreLoads.count, 1)
        XCTAssertEqual(host.handOffs, [])
    }

    func testAFailureDuringTheRestoreIsTheRulesAndHandsOffOnce() async {
        await returnAndReload()
        let failure = AetherFailure(kind: .reloadFailed, message: "x", atSec: 0, beforeFirstFrame: true)
        XCTAssertTrue(runner.ownsFailures)
        XCTAssertTrue(runner.failureArrived(failure))
        XCTAssertEqual(host.handOffs, [120])
        XCTAssertTrue(host.calls.contains("handOff aether: foregroundRestoreFailed (reloadFailed)"))
        XCTAssertFalse(runner.failureArrived(failure), "after the handoff the ladder owns failures again")
        XCTAssertEqual(host.handOffs.count, 1)
    }

    func testAThrownReloadHandsOffOnce() async {
        session.restoreResult = .failure(AetherFailure(kind: .foregroundRestoreFailed, message: "x", atSec: 0,
                                                       beforeFirstFrame: true))
        await returnAndReload()
        XCTAssertEqual(host.handOffs, [120])
    }

    // MARK: Paths with no reload

    func testANoTeardownReturnPausesInPlaceWithoutARestore() async {
        session.needsForegroundRestore = false
        runner.enteredBackground()
        runner.becameActive()
        await drain()
        XCTAssertEqual(session.restores, 0)
        XCTAssertEqual(host.pauses, 1)
        XCTAssertEqual(runner.rule.mode, .idle)
        XCTAssertEqual(host.held, [120, 121, nil])
    }

    func testALateTeardownSeenAtThePressReloadsWithThePlayQueued() async {
        session.needsForegroundRestore = false
        runner.enteredBackground()
        runner.becameActive()
        session.needsForegroundRestore = true
        runner.userToggle(transportPaused: true)
        await drain()
        XCTAssertEqual(session.restores, 1)
        XCTAssertEqual(host.plays, 0)
        settleTransport()
        XCTAssertEqual(host.plays, 1)
    }

    func testALateTeardownSeenByTheTickEndsPaused() async {
        session.needsForegroundRestore = true
        runner.tick()
        await drain()
        XCTAssertEqual(session.restores, 1)
        settleTransport()
        XCTAssertEqual(host.plays, 0)
        XCTAssertEqual(host.pauses, 1)
    }

    func testAReturnDuringAnOperationWaitsForItsSettle() async {
        host.operationInFlight = true
        runner.enteredBackground()
        runner.becameActive()
        XCTAssertEqual(runner.rule.mode, .deferred(.operationSettles))
        XCTAssertTrue(runner.ownsFailures)
        runner.operationMayHaveSettled()
        XCTAssertEqual(runner.rule.mode, .deferred(.operationSettles), "still in flight")
        host.operationInFlight = false
        runner.operationMayHaveSettled()
        await drain()
        XCTAssertEqual(session.restores, 1, "the settled operation left a teardown: reload")
    }

    func testBackgroundDuringTheReloadPausesTheWatchdogAndTheNextReturnResumesIt() async {
        await returnAndReload()
        runner.enteredBackground()
        XCTAssertEqual(runner.rule.mode, .awayRestoring)
        XCTAssertEqual(clock.live, [], "time away never counts")
        runner.becameActive()
        XCTAssertEqual(runner.rule.mode, .restoring)
        XCTAssertEqual(clock.live, [25], "a fresh budget from the return")
        settleTransport()
        XCTAssertEqual(runner.rule.mode, .idle)
    }

    // MARK: W5 review r1

    /// Finding 1: a seek to 250 issued before Home landed at 240 while away. The runner's held value and
    /// the value released into the mirror (the exit flush and the paused bar read it) are the landing.
    func testALandingAwayFromTheHeldTargetIsWhatTheMirrorGetsAtTheRelease() async {
        host.operationInFlight = true
        session.needsForegroundRestore = false
        host.position = 100
        host.pendingSeek = 250
        host.clock = 240
        runner.enteredBackground()
        runner.becameActive()
        XCTAssertEqual(runner.rule.mode, .deferred(.operationSettles))
        host.operationInFlight = false
        runner.operationMayHaveSettled()
        XCTAssertEqual(runner.rule.mode, .idle, "paused in place")
        XCTAssertEqual(host.held, [250, 240, nil], "the last held value before the release is the landing")
        XCTAssertNil(runner.heldPosition)
    }

    /// Finding 2: the controller's paused mirror does not change while the return holds the transport, so
    /// two presses during a restore must cancel out: the second asks for Pause, and the return ends paused.
    func testTwoPressesDuringTheRestoreCancelOutWhileTheMirrorStaysPaused() async {
        await returnAndReload()
        runner.userToggle(transportPaused: true)
        XCTAssertEqual(runner.rule.intent, .play)
        runner.userToggle(transportPaused: true)
        XCTAssertEqual(runner.rule.intent, .pause, "the second press toggles the queued intent")
        settleTransport()
        XCTAssertEqual(host.plays, 0)
        XCTAssertEqual(host.pauses, 1)
        // With the mirror still saying "playing", one press queues Play.
        setUp2()
        await returnAndReload()
        runner.userToggle(transportPaused: false)
        XCTAssertEqual(runner.rule.intent, .play)
        settleTransport()
        XCTAssertEqual(host.plays, 1)
    }

    /// Finding 3: a reload that fails while the app is backgrounded again is the return's: the failover
    /// ladder never sees it, nothing hands off while away, and the next return takes the fresh load.
    func testAReloadFailureWhileAwayIsTheReturnsAndTheNextReturnTakesAFreshLoad() async {
        await returnAndReload()
        runner.enteredBackground()
        XCTAssertEqual(runner.rule.mode, .awayRestoring)
        XCTAssertTrue(runner.ownsFailures)
        let failure = AetherFailure(kind: .reloadFailed, message: "x", atSec: 0, beforeFirstFrame: true)
        XCTAssertTrue(runner.failureArrived(failure), "owned: never the ladder's rebuild or mpv handoff")
        XCTAssertEqual(host.handOffs, [])
        XCTAssertEqual(runner.rule.mode, .away)
        XCTAssertEqual(runner.rule.failedAttempts, 0, "not an attempt")
        host.sessionFailed = true
        runner.becameActive()
        await drain()
        XCTAssertEqual(host.restoreLoads, [120], "row 8: a fresh load at the held position")
        XCTAssertEqual(host.handOffs, [])
    }

    private func setUp2() {
        session = Session()
        host = Host(session: session)
        clock = Clock()
        runner = AetherReturnEffectRunner(owner: host.identity, session: session, host: host,
                                          schedule: clock.schedule, now: { [unowned self] in self.clock.now })
        session.onFrame = { [unowned self] shown in self.runner.frameChanged(shown) }
    }

    // MARK: W5 review r4

    /// Finding 3: the transport settles first, then the frame rises through the façade's willSet. The
    /// runner uses the published value, so the return settles at once: no 3 s nudge, the queued Play
    /// goes out now.
    func testAFrameRisingAfterTheTransportSettlesAtOnceWithThePublishedValue() async {
        await returnAndReload()
        runner.userToggle(transportPaused: true)
        host.settled = true
        runner.sessionStateChanged()
        XCTAssertEqual(runner.rule.mode, .restoring, "transport settled, no frame yet")
        session.firstFrameShown = true
        XCTAssertEqual(runner.rule.mode, .idle, "settled on the published frame, not after the nudge")
        XCTAssertEqual(host.plays, 1)
        XCTAssertEqual(session.seeks, [], "no nudge seek")
    }

    /// Finding 1 (runner side): every release of the transport reaches the controller, so a start resume
    /// owed while the return held it is applied then.
    func testTheTransportReleaseReachesTheHost() async {
        host.operationInFlight = true
        session.needsForegroundRestore = false
        runner.enteredBackground()
        runner.becameActive()
        XCTAssertEqual(host.refused, [true])
        host.operationInFlight = false
        runner.operationMayHaveSettled()
        XCTAssertEqual(host.refused, [true, false])
        XCTAssertFalse(runner.transportRefused)
        XCTAssertFalse(runner.rule.holdsIntent, "nothing holds the transport when the host hears the release")
    }

    // MARK: W5 review r5

    /// Finding 2: a frozen-clock rebuild starts a fresh load from a settled, framed session; the load
    /// stalls and never returns. The old phase and the old frame latch must not stand the watchdog down.
    func testAStalledFreshLoadAfterAFramedSessionStillTimesOut() async {
        session.needsForegroundRestore = false
        host.settled = true
        runner.enteredBackground()
        runner.becameActive()
        XCTAssertEqual(runner.rule.mode, .idle)
        runner.userToggle(transportPaused: true)
        for _ in 0..<5 {
            clock.now += 3
            runner.tick()
        }
        await drain()
        XCTAssertEqual(host.restoreLoads, [121], "the backstop's fresh load went out and never returns")
        XCTAssertEqual(runner.rule.mode, .restoring)
        XCTAssertTrue(session.firstFrameShown, "the session still shows the previous load's frame")
        clock.fire(25)
        XCTAssertEqual(host.handOffs, [121], "the watchdog fires: mpv, not a spinner for ever")
    }
}
