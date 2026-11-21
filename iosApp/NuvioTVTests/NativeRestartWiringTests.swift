import XCTest
@testable import NuvioTV

/// Return from background, wave 3 (spec 9.2): `NativeReturnEffectRunner` driven end to end with a fake
/// coordinator host whose pipeline steps (segment readiness, bind completion, item readiness, seek
/// landing, failures) the tests answer themselves, and a manual timer clock. The rule's and the machine's
/// tables are `PlayerForegroundReturnRuleTests` and `NativeRestartMachineTests`; these pin what the runner
/// does with them and what reaches the coordinator.
@MainActor
final class NativeRestartWiringTests: XCTestCase {

    // MARK: Fakes

    @MainActor
    final class Host: NativeReturnHost {
        var identity = PlaybackIdentity(accountKey: "user-1", profileId: 1)
        var presence: PlayerPresence = .front
        var phase: PlayerReturnPhase = .playing
        var position: Double = 120
        var clock: Double? = 120
        var pictureReady = false
        var health: PlayerNativeHealth = .alive
        /// nil = the probe answers at once; otherwise the answer waits here.
        var heldHealth: ((PlayerNativeHealth) -> Void)?
        var holdHealth = false
        var sample = PlayerBackstopSample(now: 0, clockSec: 120, userPaused: false, reportsPlaying: true,
                                          reportsBuffering: false)
        var calls: [String] = []
        var handOffs: [Double] = []
        var plays = 0, pauses = 0, exits = 0, nudges: [Double] = [], trackerStarts = 0, resumeReads = 0
        var held: [Double?] = []
        var ui: [PlayerReturnUI] = []
        var lastToken = 0
        var ended: [Bool] = []

        func returnSnapshot(enteredAtUptime: TimeInterval) -> PlayerBackgroundSnapshot {
            PlayerBackgroundSnapshot(route: .native, phase: phase, positionSec: position, pendingSeekTargetSec: nil,
                                     enteredAtUptime: enteredAtUptime, audioTrackID: nil, subtitleTrackID: nil,
                                     subtitleDecided: true, audioName: "English · AAC Stereo", subtitleName: "English")
        }

        func returnFacts(enteredBackground: Bool, awaySec: Double, health: PlayerNativeHealth) -> PlayerReturnFacts {
            PlayerReturnFacts(identity: identity, enteredBackground: enteredBackground, awaySec: awaySec,
                              presence: presence, contextSwapPending: false, operationInFlight: false,
                              aetherNeedsRestore: nil, aetherSessionFailed: false, clockSec: clock, nativeHealth: health)
        }

        func returnBackstopSample(now: TimeInterval) -> PlayerBackstopSample {
            PlayerBackstopSample(now: now, clockSec: sample.clockSec, userPaused: sample.userPaused,
                                 reportsPlaying: sample.reportsPlaying, reportsBuffering: sample.reportsBuffering)
        }

        var returnIdentity: PlaybackIdentity { identity }
        var returnPresence: PlayerPresence { presence }
        var returnClockSec: Double? { clock }
        var returnPictureReady: Bool { pictureReady }
        var returnRestoreBudgetSec: Double { 25 }

        func returnProbeHealth(_ done: @escaping @MainActor (PlayerNativeHealth) -> Void) {
            calls.append("health")
            if holdHealth { heldHealth = { done($0) } } else { done(health) }
        }

        func returnActivateAudioSession() async { calls.append("audio") }
        func returnBackgrounded() { calls.append("background") }
        func returnPlay() { plays += 1 }
        func returnPause() { pauses += 1 }
        func returnHandOff(atSec: Double, reason: String) { handOffs.append(atSec); calls.append("handOff \(reason)") }
        func returnExit() { exits += 1 }
        func returnSetUI(_ ui: PlayerReturnUI) { self.ui.append(ui) }
        func returnSetHeldPosition(_ sec: Double?) { held.append(sec) }
        func returnSetTransportRefused(_ refused: Bool) {}
        func returnNudgePicture(atSec: Double) { nudges.append(atSec) }

        func restartWillBegin(token: Int, kind: NativeRestartKind, target: NativeRestartTarget) {
            lastToken = token
            calls.append("begin \(kind)")
        }
        func restartSetPosition(_ sec: Double) { calls.append("setPosition \(Int(sec))") }
        func restartTeardown(keepPlayer: Bool) { calls.append("teardown \(keepPlayer ? 1 : 0)") }
        func restartLaunchRemux(token: Int) { calls.append("launchRemux") }
        func restartMakeServer(token: Int) { calls.append("makeServer") }
        func restartMakeItem(token: Int, signalingAttempt: Int) { calls.append("makeItem \(signalingAttempt)") }
        func restartSeek(token: Int, toSec: Double) { calls.append("seek \(Int(toSec))") }
        func restartRestoreTracks(token: Int, audio: String?, subtitle: String?) {
            calls.append("tracks \(audio ?? "-")/\(subtitle ?? "off")")
        }
        func restartStartTrackersOnce() { trackerStarts += 1 }
        func restartChooseResume(token: Int) { resumeReads += 1; calls.append("chooseResume") }
        func restartEnded(token: Int, settled: Bool) { ended.append(settled) }
    }

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
        func fire(_ seconds: Double) {
            for t in timers where t.seconds == seconds {
                let b = t.body
                t.body = nil
                b?()
            }
        }
        var live: [Double] { timers.filter { $0.body != nil }.map(\.seconds) }
    }

    private var host: Host!
    private var clock: Clock!
    private var runner: NativeReturnEffectRunner!

    override func setUp() async throws {
        host = Host()
        clock = Clock()
        runner = NativeReturnEffectRunner(owner: host.identity, host: host, schedule: clock.schedule,
                                          now: { [unowned self] in self.clock.now })
    }

    private func drain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private var token: Int { host.lastToken }

    /// Background then return while playing: the restart starts and its watchdog is armed.
    private func returnAndRestart() async {
        runner.enteredBackground()
        clock.now += 30
        runner.becameActive()
        await drain()
    }

    /// The restart's pipeline up to a ready item (mid-play: the corrective seek is issued).
    private func buildPipeline(stale: (() -> Void)? = nil) {
        runner.machine(.firstSegmentReady, token: token)
        runner.bindCompleted(token: token, url: URL(string: "http://127.0.0.1:8190/t/master.m3u8"),
                             stopStale: { stale?() })
        runner.machine(.itemReady, token: token)
    }

    private func land(picture: Bool) {
        host.pictureReady = picture
        runner.machine(.seekLanded(clockSec: 120, pictureReady: picture), token: token)
    }

    // MARK: Order

    func testAMidPlayRestartRunsAudioThenWatchdogThenPositionBeforeTeardown() async {
        await returnAndRestart()
        XCTAssertEqual(Array(host.calls.prefix(7)),
                       ["background", "health", "audio", "begin midPlay", "setPosition 120", "teardown 1", "launchRemux"])
        XCTAssertEqual(runner.rule.mode, .restoring)
        XCTAssertEqual(runner.machine.state, .launching)
        XCTAssertEqual(clock.live, [25], "the restore budget is armed once, before the restart")
        XCTAssertTrue(runner.transportRefused)
        XCTAssertEqual(host.held.first ?? nil, 120)
    }

    func testTheRestartBuildsAServerAnItemThenSeeksAndRestoresTheTracks() async {
        await returnAndRestart()
        buildPipeline()
        XCTAssertTrue(host.calls.contains("makeServer"))
        XCTAssertTrue(host.calls.contains("makeItem 0"))
        XCTAssertEqual(Array(host.calls.suffix(2)), ["seek 120", "tracks English · AAC Stereo/English"])
        XCTAssertEqual(runner.machine.state, .seeking)
    }

    func testARestartWithAFrameSettlesPausedAndReleasesEverything() async {
        await returnAndRestart()
        buildPipeline()
        land(picture: true)
        XCTAssertEqual(runner.rule.mode, .idle)
        XCTAssertEqual(host.ended, [true])
        XCTAssertEqual(host.plays, 0, "A: the mid-play restart never plays")
        XCTAssertEqual(host.pauses, 1)
        XCTAssertEqual(host.held.last, .some(nil), "the position is released")
        XCTAssertFalse(runner.transportRefused)
        XCTAssertEqual(clock.live, [], "the restore budget stood down")
        XCTAssertEqual(host.trackerStarts, 0, "a mid-play restart starts no tracker (I6)")
        XCTAssertEqual(host.handOffs, [])
    }

    // MARK: Presses (AVKit owns the remote; observed, I1 and I5)

    func testAPlayPressDuringTheRestartIsHeldAndAppliedOnceAtTheSettle() async {
        await returnAndRestart()
        let pausesBefore = host.pauses
        runner.observedRate(playing: true)
        XCTAssertEqual(host.pauses, pausesBefore + 1, "the player is held paused while the return runs")
        XCTAssertEqual(host.plays, 0)
        buildPipeline()
        land(picture: true)
        XCTAssertEqual(host.plays, 1, "exactly one play, after the settle")
        runner.observedRate(playing: true)
        XCTAssertEqual(host.plays, 1, "the observed start of that play is not played again")
    }

    func testPlayThenPauseDuringTheRestartEndsPaused() async {
        await returnAndRestart()
        runner.observedRate(playing: true)
        runner.observedRate(playing: false)
        runner.observedRate(playing: true)
        buildPipeline()
        land(picture: true)
        XCTAssertEqual(host.plays, 0, "the last press (pause) wins")
    }

    // MARK: Picture (I9)

    func testASettleWithoutAFrameNudgesOnceThenSettlesOnTheFrame() async {
        await returnAndRestart()
        buildPipeline()
        land(picture: false)
        XCTAssertEqual(runner.rule.mode, .restoring, "no frame: not done")
        XCTAssertEqual(host.ended, [true], "the machine settled; the rule waits for the frame")
        XCTAssertEqual(Set(clock.live), [25, 3])
        clock.fire(3)
        XCTAssertEqual(host.nudges, [120], "one exact seek to the adopted position")
        host.pictureReady = true
        runner.pictureChanged()
        XCTAssertEqual(runner.rule.mode, .idle, "a frame that rises after the machine settled ends the return")
        XCTAssertEqual(host.pauses, 1)
    }

    func testNoFrameByTheWatchdogHandsOffOnce() async {
        await returnAndRestart()
        buildPipeline()
        land(picture: false)
        clock.fire(25)
        XCTAssertEqual(host.handOffs, [120])
        XCTAssertEqual(runner.rule.mode, .finished)
    }

    // MARK: The tokened bind

    func testABindDelayedPastACancelAndAReplacementInstallsNothing() async {
        await returnAndRestart()
        let first = token
        runner.machine(.firstSegmentReady, token: first)
        // Background again while the bind is pending: the restart is cancelled and torn down.
        runner.enteredBackground()
        XCTAssertTrue(host.calls.contains("teardown 1"))
        XCTAssertEqual(runner.machine.state, .cancelled)
        runner.becameActive()
        await drain()
        let second = token
        XCTAssertGreaterThan(second, first)
        runner.machine(.firstSegmentReady, token: second)
        var staleStops = 0
        let itemsBefore = host.calls.filter { $0.hasPrefix("makeItem") }.count
        runner.bindCompleted(token: first, url: URL(string: "http://127.0.0.1:8191/x/master.m3u8"),
                             stopStale: { staleStops += 1 })
        XCTAssertEqual(staleStops, 1, "the stale server is stopped")
        XCTAssertEqual(host.calls.filter { $0.hasPrefix("makeItem") }.count, itemsBefore, "and installs no player")
        runner.bindCompleted(token: second, url: URL(string: "http://127.0.0.1:8190/y/master.m3u8"), stopStale: {})
        XCTAssertEqual(host.calls.filter { $0.hasPrefix("makeItem") }.count, itemsBefore + 1, "the newer restart's does")
    }

    // MARK: One failure owner

    func testEachFailureSourceDuringTheRestartEndsInExactlyOneHandOff() async {
        let sources: [(String, (NativeReturnEffectRunner, Int) -> Void)] = [
            ("remux", { r, _ in _ = r.failureArrived(.remux("read/write error")) }),
            ("bind", { r, t in
                r.machine(.firstSegmentReady, token: t)
                r.bindCompleted(token: t, url: nil, stopStale: {})
            }),
            ("preReady", { r, t in
                r.machine(.firstSegmentReady, token: t)
                r.bindCompleted(token: t, url: URL(string: "http://127.0.0.1:8190/t/m.m3u8"), stopStale: {})
                _ = r.failureArrived(.itemPreReady(retryAllowed: false))
            }),
            ("afterReady", { r, t in
                r.machine(.firstSegmentReady, token: t)
                r.bindCompleted(token: t, url: URL(string: "http://127.0.0.1:8190/t/m.m3u8"), stopStale: {})
                r.machine(.itemReady, token: t)
                _ = r.failureArrived(.itemAfterReady("stalled"))
            }),
        ]
        for (name, fail) in sources {
            try? await setUp()
            await returnAndRestart()
            fail(runner, token)
            XCTAssertEqual(host.handOffs, [120], "\(name): one handoff at the held position")
            XCTAssertEqual(runner.rule.mode, .finished, name)
            XCTAssertEqual(host.ended, [false], name)
            XCTAssertEqual(host.calls.filter { $0 == "makeItem 1" }, [], "\(name): no signaling retry")
            XCTAssertFalse(runner.failureArrived(.remux("late")), "\(name): later failures are not the return's")
        }
    }

    func testTheDeadlineWhileTheMachineRunsIsTheMachinesOneReport() async {
        await returnAndRestart()
        runner.machine(.firstSegmentReady, token: token)
        clock.fire(25)
        XCTAssertEqual(host.handOffs, [120])
        XCTAssertEqual(runner.machine.state, .failed)
        XCTAssertTrue(host.calls.contains("handOff native: foreground restore failed (timedOut)"))
    }

    func testTheOneSignalingRetryIsInsideTheAttempt() async {
        await returnAndRestart()
        runner.machine(.firstSegmentReady, token: token)
        runner.bindCompleted(token: token, url: URL(string: "http://127.0.0.1:8190/t/m.m3u8"), stopStale: {})
        XCTAssertTrue(runner.failureArrived(.itemPreReady(retryAllowed: true)))
        XCTAssertEqual(host.calls.filter { $0 == "makeItem 1" }.count, 1)
        XCTAssertEqual(host.handOffs, [])
        XCTAssertTrue(runner.failureArrived(.itemPreReady(retryAllowed: true)))
        XCTAssertEqual(host.calls.filter { $0 == "makeItem 1" }.count, 1, "at most one retry")
        XCTAssertEqual(host.handOffs, [120])
    }

    func testAFailureOfTheOldPipelineWhileAwayIsAbsorbedAndIdleFailuresAreNot() async {
        XCTAssertFalse(runner.failureArrived(.itemAfterReady("stalled")), "idle: today's path")
        runner.enteredBackground()
        XCTAssertTrue(runner.failureArrived(.remux("read error")), "away: the return restarts anyway (C)")
        XCTAssertEqual(host.handOffs, [])
        runner.becameActive()
        await drain()
        XCTAssertEqual(runner.rule.mode, .restoring, "the restart runs as usual")
    }

    func testStopBeforeTheItemIsReadyReportsNothing() async {
        await returnAndRestart()
        runner.machine(.firstSegmentReady, token: token)
        runner.cancelled()
        XCTAssertEqual(runner.machine.state, .cancelled)
        XCTAssertEqual(runner.rule.mode, .finished)
        XCTAssertEqual(host.handOffs, [])
        XCTAssertEqual(host.exits, 0)
        XCTAssertEqual(clock.live, [])
        // The position was written before the teardown, so the coordinator's stop() records it.
        let set = host.calls.firstIndex(of: "setPosition 120")!
        let teardown = host.calls.firstIndex(of: "teardown 1")!
        XCTAssertLessThan(set, teardown)
    }

    // MARK: From scratch

    private func returnFromScratch() async {
        host.phase = .starting
        host.position = 0
        await returnAndRestart()
    }

    func testAReturnBeforeAnythingPlayedRestartsFromScratchThroughTheStartPath() async {
        await returnFromScratch()
        XCTAssertTrue(host.calls.contains("begin fromScratch"))
        XCTAssertTrue(host.calls.contains("teardown 0"))
        XCTAssertFalse(host.calls.contains { $0.hasPrefix("setPosition") })
        buildPipeline()
        XCTAssertEqual(host.resumeReads, 1, "the resume row is read once, after readiness")
        runner.machine(.resumeChosen(sec: 300), token: token)
        XCTAssertEqual(host.calls.last, "seek 300")
        XCTAssertEqual(host.trackerStarts, 0, "no tracker before the seek landed")
        host.pictureReady = true
        runner.machine(.seekLanded(clockSec: 300, pictureReady: true), token: token)
        XCTAssertEqual(host.trackerStarts, 1, "trackers start once")
        XCTAssertEqual(runner.rule.mode, .idle)
        XCTAssertEqual(host.plays, 0, "A: the paused start skips its play")
        runner.machine(.seekLanded(clockSec: 300, pictureReady: true), token: token)
        XCTAssertEqual(host.trackerStarts, 1)
    }

    func testFromScratchWithNoResumeRowSettlesAtTheTop() async {
        await returnFromScratch()
        buildPipeline()
        host.pictureReady = true
        runner.machine(.resumeChosen(sec: nil), token: token)
        XCTAssertEqual(host.trackerStarts, 1)
        XCTAssertEqual(runner.rule.mode, .idle)
    }

    func testAnIdentityChangeBeforeTheResumeReadAbandons() async {
        await returnFromScratch()
        buildPipeline()
        host.identity = PlaybackIdentity(accountKey: "user-1", profileId: 2)
        runner.machine(.identityChanged, token: token)
        XCTAssertEqual(runner.rule.mode, .abandoned)
        XCTAssertEqual(host.exits, 1)
        XCTAssertEqual(host.trackerStarts, 0)
        XCTAssertEqual(host.handOffs, [])
        XCTAssertEqual(host.plays, 0)
    }

    func testAnIdentityChangeDuringTheResumeSeekAbandons() async {
        await returnFromScratch()
        buildPipeline()
        runner.machine(.resumeChosen(sec: 300), token: token)
        host.identity = PlaybackIdentity(accountKey: "signed-out", profileId: 1)
        runner.machine(.identityChanged, token: token)
        XCTAssertEqual(runner.rule.mode, .abandoned)
        XCTAssertEqual(host.trackerStarts, 0)
        XCTAssertEqual(host.handOffs, [])
    }

    // MARK: Identity and lifecycle

    func testAReturnUnderAnotherProfileRestartsNothing() async {
        runner.enteredBackground()
        host.identity = PlaybackIdentity(accountKey: "user-1", profileId: 9)
        runner.becameActive()
        await drain()
        XCTAssertEqual(runner.rule.mode, .abandoned)
        XCTAssertEqual(host.exits, 1)
        XCTAssertFalse(host.calls.contains { $0.hasPrefix("begin") })
    }

    func testAnIdentityChangeBeforeAQueuedPlayIsAppliedExits() async {
        await returnAndRestart()
        runner.observedRate(playing: true)
        buildPipeline()
        host.identity = PlaybackIdentity(accountKey: "user-2", profileId: 1)
        land(picture: true)
        XCTAssertEqual(host.plays, 0)
        XCTAssertEqual(runner.rule.mode, .abandoned)
        XCTAssertEqual(host.exits, 1)
    }

    func testAHealthAnswerAfterANewerBackgroundIsDropped() async {
        host.holdHealth = true
        runner.enteredBackground()
        runner.becameActive()
        let late = host.heldHealth
        runner.enteredBackground()
        late?(.listenerDead)
        await drain()
        XCTAssertEqual(runner.rule.mode, .away, "no decision from a stale probe")
        XCTAssertFalse(host.calls.contains { $0.hasPrefix("begin") })
    }

    func testTheHealthReadingIsLoggedButNeverChangesTheAction() async {
        for health in [PlayerNativeHealth.alive, .listenerDead, .remuxDead, .unknown] {
            try? await setUp()
            host.health = health
            await returnAndRestart()
            XCTAssertEqual(runner.lastHealth, health)
            XCTAssertTrue(host.calls.contains("begin midPlay"), "\(health): decision C restarts")
        }
    }

    func testABecameActiveWithoutABackgroundDoesNothing() async {
        runner.becameActive()
        await drain()
        XCTAssertEqual(runner.rule.mode, .idle)
        XCTAssertFalse(host.calls.contains("health"))
    }

    // MARK: Backstop (G)

    func testAFrozenClockAfterTheFirstPlayRestartsOnce() async {
        await returnAndRestart()
        buildPipeline()
        land(picture: true)
        XCTAssertEqual(runner.rule.mode, .idle)
        let begins = host.calls.filter { $0.hasPrefix("begin") }.count
        runner.observedRate(playing: true)   // the viewer's first Play after the return
        for _ in 0..<5 {
            clock.now += 3
            runner.tick()
        }
        await drain()
        XCTAssertEqual(host.calls.filter { $0.hasPrefix("begin") }.count, begins + 1,
                       "the clock never moved while reporting playing: one more restart")
    }
}
