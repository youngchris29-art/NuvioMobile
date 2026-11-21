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
        var firstFrameShown = true
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
                                     pendingSeekTargetSec: nil, enteredAtUptime: enteredAtUptime, audioTrackID: 2,
                                     subtitleTrackID: 3, subtitleDecided: true, audioName: nil, subtitleName: nil)
        }

        func returnFacts(enteredBackground: Bool, awaySec: Double) -> PlayerReturnFacts {
            PlayerReturnFacts(identity: identity, enteredBackground: enteredBackground, awaySec: awaySec,
                              presence: presence, contextSwapPending: false, operationInFlight: operationInFlight,
                              aetherNeedsRestore: session.needsForegroundRestore, aetherSessionFailed: false,
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
        runner.userToggle(toPlay: true)
        runner.userToggle(toPlay: false)
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
        runner.userToggle(toPlay: true)
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
        XCTAssertEqual(host.held, [120, nil])
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
        runner.userToggle(toPlay: true)
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
        XCTAssertEqual(host.held, [120, nil])
    }

    func testALateTeardownSeenAtThePressReloadsWithThePlayQueued() async {
        session.needsForegroundRestore = false
        runner.enteredBackground()
        runner.becameActive()
        session.needsForegroundRestore = true
        runner.userToggle(toPlay: true)
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
}
