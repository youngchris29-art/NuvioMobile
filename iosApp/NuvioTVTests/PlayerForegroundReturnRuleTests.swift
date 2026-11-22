import XCTest
@testable import NuvioTV

/// Return from background, wave 1: `PlayerForegroundReturnRule` (spec 4.3 to 4.7, 9.1). The decision table is
/// checked against an oracle written from the prose of 4.3; the transition table over its full mode x event
/// product; the rest as named rows and scenario sequences.
final class PlayerForegroundReturnRuleTests: XCTestCase {

    typealias E = PlayerReturnEffect

    // MARK: Fixtures

    private let owner = PlaybackIdentity(accountKey: "user-1", profileId: 1)
    private let intruder = PlaybackIdentity(accountKey: "user-2", profileId: 1)

    private func snap(route: PlayerReturnRoute = .aetherLoopback, phase: PlayerReturnPhase = .playing,
                      pos: Double = 120, pending: Double? = nil) -> PlayerBackgroundSnapshot {
        PlayerBackgroundSnapshot(route: route, phase: phase, positionSec: pos, pendingSeekTargetSec: pending,
                                 enteredAtUptime: 1000, audioTrackID: 2, subtitleTrackID: 3, subtitleDecided: true,
                                 audioName: "en", subtitleName: "sub")
    }

    private func facts(identity: PlaybackIdentity? = nil, entered: Bool = true, away: Double = 30,
                       presence: PlayerPresence = .front, ctx: Bool = false, op: Bool = false,
                       needs: Bool? = true, failed: Bool = false, clock: Double? = 121,
                       health: PlayerNativeHealth = .notApplicable) -> PlayerReturnFacts {
        PlayerReturnFacts(identity: identity ?? owner, enteredBackground: entered, awaySec: away, presence: presence,
                          contextSwapPending: ctx, operationInFlight: op, aetherNeedsRestore: needs,
                          aetherSessionFailed: failed, clockSec: clock, nativeHealth: health)
    }

    private func nonLog(_ fx: [E]) -> [E] {
        fx.filter { if case .log = $0 { return false } else { return true } }
    }

    private func logCount(_ fx: [E]) -> Int {
        fx.filter { if case .log = $0 { return true } else { return false } }.count
    }

    /// A rule plus a recorder of the non-log effects of every event it was fed.
    private final class Harness {
        var rule: PlayerForegroundReturnRule
        var all: [E] = []
        init(owner: PlaybackIdentity) { rule = PlayerForegroundReturnRule(owner: owner) }
        @discardableResult
        func send(_ event: PlayerReturnEvent) -> [E] {
            let fx = rule.handle(event).filter { if case .log = $0 { return false } else { return true } }
            all += fx
            return fx
        }
        func count(_ e: E) -> Int { all.filter { $0 == e }.count }
        var token: Int { rule.token }
    }

    private func harness() -> Harness { Harness(owner: owner) }

    private let reloadStart: [E] = [.startRestore(.aetherReload, token: 1), .refuseTransport(true), .setUI(.restoring)]
    private let settledPaused: [E] = [.releasePosition, .refuseTransport(false), .setUI(.normal), .pauseTransport]
    private let settledPlaying: [E] = [.releasePosition, .refuseTransport(false), .setUI(.normal), .play]
    private let pausedInPlace: [E] = [.pauseTransport, .releasePosition, .refuseTransport(false), .setUI(.normal)]

    /// Away, then a return that asks for a reload (token 1, `preparing`).
    private func reloading(_ h: Harness, snapshot: PlayerBackgroundSnapshot? = nil) {
        h.send(.enteredBackground(snapshot ?? snap()))
        h.send(.becameActive(facts()))
        h.send(.sequenceArmed(token: 1))
    }

    // MARK: decide: the oracle and the exhaustive table

    private struct Case {
        let route: PlayerReturnRoute, phase: PlayerReturnPhase, presence: PlayerPresence
        let entered: Bool, same: Bool, ctx: Bool, op: Bool, needs: Bool?, failed: Bool
        let health: PlayerNativeHealth, attempts: Int, away: Double
    }

    /// The prose rules of 4.3 as independent predicates, evaluated by priority.
    private func oracle(_ c: Case, position: Double) -> PlayerReturnAction {
        let aether = c.route != .native
        let terminal: [PlayerReturnPhase] = [.ended, .postPlay, .failed, .handedOff]
        let nativeLive: [PlayerReturnPhase] = [.operation, .playing, .paused]
        let rules: [(Bool, PlayerReturnAction)] = [
            (!c.entered, .nothing(.notBackgrounded)),
            (!c.same, .abandon),
            (c.presence == .leaving, .nothing(.leaving)),
            (terminal.contains(c.phase), .nothing(.terminal)),
            (c.ctx, .nothing(.contextSwap)),
            (c.presence == .covered, .deferUntil(.playerFront)),
            (c.attempts >= 1, .handOffToMpv(atSec: position)),
            (aether && c.failed, .aetherFreshLoad(atSec: position)),
            (aether && c.op, .deferUntil(.operationSettles)),
            (aether && c.needs == true, .aetherReload),
            (aether, .pauseInPlace),
            (!aether && c.phase == .starting, .nativeRestartFromScratch),
            (!aether && nativeLive.contains(c.phase), .nativeRestart(atSec: position)),
        ]
        return rules.first(where: { $0.0 })!.1
    }

    private func decide(_ c: Case, route: PlayerReturnRoute? = nil, clock: Double? = 121, position: Double = 77.5) -> PlayerReturnAction {
        PlayerForegroundReturnRule.decide(
            owner: owner,
            snapshot: snap(route: route ?? c.route, phase: c.phase),
            facts: facts(identity: c.same ? owner : intruder, entered: c.entered, away: c.away, presence: c.presence,
                         ctx: c.ctx, op: c.op, needs: c.needs, failed: c.failed, clock: clock, health: c.health),
            failedAttempts: c.attempts, positionSec: position)
    }

    func testDecideMatchesTheOracleOverTheFullProduct() {
        let routes: [PlayerReturnRoute] = [.native, .aetherLoopback, .aetherSoftware]
        let phases: [PlayerReturnPhase] = [.starting, .operation, .playing, .paused, .ended, .postPlay, .failed, .handedOff]
        let presences: [PlayerPresence] = [.front, .covered, .leaving]
        let healths: [PlayerNativeHealth] = [.notApplicable, .unknown, .alive, .listenerDead, .remuxDead]
        var combos = 0
        for route in routes {
            let needsValues: [Bool?] = route == .native ? [nil] : [true, false]
            for phase in phases { for presence in presences { for entered in [true, false] { for same in [true, false] {
            for ctx in [false, true] { for op in [false, true] { for needs in needsValues { for failed in [false, true] {
            for health in healths { for attempts in [0, 1] { for away in [0.1, 30, 300] {
                let c = Case(route: route, phase: phase, presence: presence, entered: entered, same: same, ctx: ctx,
                             op: op, needs: needs, failed: failed, health: health, attempts: attempts, away: away)
                let want = oracle(c, position: 77.5)
                let got = decide(c)
                combos += 1
                if got != want {
                    XCTFail("\(c) -> \(got), want \(want)")
                    return
                }
            } } } } } } } } } } }
        }
        // 3 routes x 8 phases x 3 presences x 2 x 2 x 2 x 2 x (needs: 1 native, 2 aether) x 2 x 5 x 2 x 3
        XCTAssertEqual(combos, 8 * 3 * 2 * 2 * 2 * 2 * 2 * 5 * 2 * 3 * (1 + 2 + 2))
    }

    func testAwayHealthAndClockNeverChangeTheActionAndTheTwoAetherRoutesAgree() {
        let phases: [PlayerReturnPhase] = [.starting, .operation, .playing, .paused, .ended, .postPlay, .failed, .handedOff]
        for route in [PlayerReturnRoute.native, .aetherLoopback] {
            let needsValues: [Bool?] = route == .native ? [nil] : [true, false]
            for phase in phases { for presence in [PlayerPresence.front, .covered, .leaving] { for entered in [true, false] {
            for same in [true, false] { for ctx in [false, true] { for op in [false, true] { for needs in needsValues {
            for failed in [false, true] { for attempts in [0, 1] {
                var seen: Set<String> = []
                for away in [0.1, 30, 300] {
                    for health in [PlayerNativeHealth.notApplicable, .unknown, .alive, .listenerDead, .remuxDead] {
                        for clock in [nil, 0, 5, Double.nan] as [Double?] {
                            let c = Case(route: route, phase: phase, presence: presence, entered: entered, same: same,
                                         ctx: ctx, op: op, needs: needs, failed: failed, health: health,
                                         attempts: attempts, away: away)
                            seen.insert("\(decide(c, clock: clock))")
                            if route == .aetherLoopback {
                                XCTAssertEqual(decide(c, route: .aetherLoopback, clock: clock),
                                               decide(c, route: .aetherSoftware, clock: clock))
                            }
                        }
                    }
                }
                XCTAssertEqual(seen.count, 1, "\(route) \(phase) \(presence)")
            } } } } } } } } }
        }
    }

    // One named test per row of 4.3.

    private func plain(route: PlayerReturnRoute = .aetherLoopback, phase: PlayerReturnPhase = .playing,
                       presence: PlayerPresence = .front, entered: Bool = true, same: Bool = true, ctx: Bool = false,
                       op: Bool = false, needs: Bool? = true, failed: Bool = false, attempts: Int = 0) -> PlayerReturnAction {
        decide(Case(route: route, phase: phase, presence: presence, entered: entered, same: same, ctx: ctx, op: op,
                    needs: needs, failed: failed, health: .notApplicable, attempts: attempts, away: 30))
    }

    func testRow1NotBackgrounded() { XCTAssertEqual(plain(entered: false), .nothing(.notBackgrounded)) }
    func testRow2IdentityChangedAbandons() { XCTAssertEqual(plain(same: false), .abandon) }
    func testRow3Leaving() { XCTAssertEqual(plain(presence: .leaving), .nothing(.leaving)) }
    func testRow4TerminalPhases() {
        for p in [PlayerReturnPhase.ended, .postPlay, .failed, .handedOff] {
            XCTAssertEqual(plain(phase: p), .nothing(.terminal), "\(p)")
        }
    }
    func testRow5ContextSwap() { XCTAssertEqual(plain(ctx: true), .nothing(.contextSwap)) }
    func testRow6CoveredDefersToThePlayerFront() { XCTAssertEqual(plain(presence: .covered), .deferUntil(.playerFront)) }
    func testRow7AFailedAttemptHandsOffAtThePosition() {
        XCTAssertEqual(plain(attempts: 1), .handOffToMpv(atSec: 77.5))
        XCTAssertEqual(plain(route: .native, attempts: 1), .handOffToMpv(atSec: 77.5))
    }
    func testRow8AFailedAetherSessionTakesAFreshLoad() { XCTAssertEqual(plain(failed: true), .aetherFreshLoad(atSec: 77.5)) }
    func testRow9AnOperationInFlightDefersToItsSettle() { XCTAssertEqual(plain(op: true), .deferUntil(.operationSettles)) }
    func testRow10AetherNeedsRestoreReloads() {
        XCTAssertEqual(plain(needs: true), .aetherReload)
        XCTAssertEqual(plain(route: .aetherSoftware, needs: true), .aetherReload)
    }
    func testRow11AetherOtherwisePausesInPlace() { XCTAssertEqual(plain(needs: false), .pauseInPlace) }
    func testRow12NativeStartingRestartsFromScratch() {
        XCTAssertEqual(plain(route: .native, phase: .starting, needs: nil), .nativeRestartFromScratch)
    }
    func testRow13NativeRestartsAtThePosition() {
        for p in [PlayerReturnPhase.operation, .playing, .paused] {
            XCTAssertEqual(plain(route: .native, phase: p, needs: nil), .nativeRestart(atSec: 77.5), "\(p)")
        }
    }

    // MARK: Transition table: the full mode x event product

    private enum ModeKey: CaseIterable {
        case idle, away, deferredOp, deferredFront, preparing, restoring, awayRestoring, abandoned, finished
    }

    private func build(_ key: ModeKey) -> PlayerForegroundReturnRule {
        let h = harness()
        switch key {
        case .idle: break
        case .away: h.send(.enteredBackground(snap()))
        case .deferredOp:
            h.send(.enteredBackground(snap())); h.send(.becameActive(facts(op: true)))
        case .deferredFront:
            h.send(.enteredBackground(snap())); h.send(.becameActive(facts(presence: .covered)))
        case .preparing:
            h.send(.enteredBackground(snap())); h.send(.becameActive(facts()))
        case .restoring:
            h.send(.enteredBackground(snap())); h.send(.becameActive(facts())); h.send(.sequenceArmed(token: 1))
        case .awayRestoring:
            h.send(.enteredBackground(snap())); h.send(.becameActive(facts())); h.send(.sequenceArmed(token: 1))
            h.send(.enteredBackground(snap()))
        case .abandoned:
            h.send(.enteredBackground(snap())); h.send(.becameActive(facts(identity: intruder)))
        case .finished: h.send(.cancelled)
        }
        return h.rule
    }

    private func expectedMode(_ key: ModeKey) -> PlayerForegroundReturnRule.Mode {
        switch key {
        case .idle: return .idle
        case .away: return .away
        case .deferredOp: return .deferred(.operationSettles)
        case .deferredFront: return .deferred(.playerFront)
        case .preparing: return .preparing
        case .restoring: return .restoring
        case .awayRestoring: return .awayRestoring
        case .abandoned: return .abandoned
        case .finished: return .finished
        }
    }

    private struct EventVariant {
        let key: String
        let make: (Int) -> PlayerReturnEvent          // given the token to use for tokened events
        let tokened: Bool
        let makeMismatch: (() -> PlayerReturnEvent)?  // the same event under a changed identity
    }

    private var eventVariants: [EventVariant] {
        let f = facts()
        let bad = facts(identity: intruder)
        let sample = PlayerBackstopSample(now: 100, clockSec: 121, userPaused: false, reportsPlaying: true, reportsBuffering: false)
        return [
            EventVariant(key: "enteredBackground", make: { _ in .enteredBackground(self.snap()) }, tokened: false, makeMismatch: nil),
            EventVariant(key: "becameActive", make: { _ in .becameActive(f) }, tokened: false, makeMismatch: { .becameActive(bad) }),
            EventVariant(key: "settled", make: { _ in .settled(f) }, tokened: false, makeMismatch: { .settled(bad) }),
            EventVariant(key: "reappeared", make: { _ in .reappeared(f) }, tokened: false, makeMismatch: { .reappeared(bad) }),
            EventVariant(key: "restoreOwed", make: { _ in .restoreOwedInForeground(self.snap(), f, pressedPlay: false) }, tokened: false,
                         makeMismatch: { .restoreOwedInForeground(self.snap(), bad, pressedPlay: false) }),
            EventVariant(key: "sequenceArmed", make: { .sequenceArmed(token: $0) }, tokened: true, makeMismatch: nil),
            EventVariant(key: "dropped.notNeeded", make: { .sequenceDropped(token: $0, .notNeeded) }, tokened: true, makeMismatch: nil),
            EventVariant(key: "dropped.dropped", make: { .sequenceDropped(token: $0, .dropped) }, tokened: true, makeMismatch: nil),
            EventVariant(key: "dropped.timedOut", make: { .sequenceDropped(token: $0, .preconditionTimedOut) }, tokened: true, makeMismatch: nil),
            EventVariant(key: "dropped.proceed", make: { .sequenceDropped(token: $0, .proceed) }, tokened: true, makeMismatch: nil),
            EventVariant(key: "finished.settledFrame", make: { .restoreFinished(token: $0, .settled(clockSec: 130, picture: true), f) },
                         tokened: true, makeMismatch: nil),
            EventVariant(key: "finished.settledNoFrame", make: { .restoreFinished(token: $0, .settled(clockSec: 130, picture: false), f) },
                         tokened: true, makeMismatch: nil),
            EventVariant(key: "finished.notNeeded", make: { .restoreFinished(token: $0, .notNeeded, f) }, tokened: true, makeMismatch: nil),
            EventVariant(key: "finished.refused", make: { .restoreFinished(token: $0, .refused, f) }, tokened: true, makeMismatch: nil),
            EventVariant(key: "finished.failed", make: { .restoreFinished(token: $0, .failed("x"), f) }, tokened: true,
                         makeMismatch: nil),
            EventVariant(key: "finished.mismatch", make: { .restoreFinished(token: $0, .settled(clockSec: 130, picture: true), bad) },
                         tokened: true, makeMismatch: nil),
            EventVariant(key: "timedOut", make: { .restoreTimedOut(token: $0, f) }, tokened: true, makeMismatch: nil),
            EventVariant(key: "nudgeDue", make: { .pictureNudgeDue(token: $0) }, tokened: true, makeMismatch: nil),
            EventVariant(key: "frameShown", make: { .frameShown(token: $0) }, tokened: true, makeMismatch: nil),
            EventVariant(key: "userPlay", make: { _ in .userPlay(f) }, tokened: false, makeMismatch: { .userPlay(bad) }),
            EventVariant(key: "userPause", make: { _ in .userPause }, tokened: false, makeMismatch: nil),
            EventVariant(key: "tick", make: { _ in .backstopTick(sample, f) }, tokened: false, makeMismatch: { .backstopTick(sample, bad) }),
            EventVariant(key: "cancelled", make: { _ in .cancelled }, tokened: false, makeMismatch: nil),
        ]
    }

    /// The listed row for a (mode, event) pair with the current token and the owner's identity, or nil when
    /// the pair is unlisted (unchanged, log only). Written from the transition table of 4.5.
    private func listed(_ key: ModeKey, _ ev: String) -> (PlayerForegroundReturnRule.Mode, [E])? {
        let release: [E] = [.releasePosition, .refuseTransport(false)]
        let intoReload: (PlayerForegroundReturnRule.Mode, [E]) = (.preparing, reloadStart)
        switch (key, ev) {
        case (.idle, "enteredBackground"): return (.away, [.holdPosition(120), .stopStartWatchdog])
        case (.idle, "restoreOwed"): return (.preparing, [.holdPosition(120)] + reloadStart)
        case (.idle, "userPlay"): return (.idle, [.play])
        case (.idle, "userPause"): return (.idle, [.pauseTransport])
        case (.idle, "tick"): return (.idle, [])
        case (.idle, "cancelled"): return (.finished, release)

        case (.away, "becameActive"): return intoReload
        case (.away, "userPlay"), (.away, "userPause"): return (.away, [])
        case (.away, "cancelled"): return (.finished, release)

        // W5 r1: a landed clock that differs from the held one is emitted again before anything reads it.
        case (.deferredOp, "settled"): return (.preparing, [.holdPosition(121)] + reloadStart)
        case (.deferredOp, "enteredBackground"): return (.away, [.stopStartWatchdog])
        case (.deferredOp, "userPlay"), (.deferredOp, "userPause"): return (.deferred(.operationSettles), [])
        case (.deferredOp, "cancelled"): return (.finished, release)

        case (.deferredFront, "reappeared"): return (.preparing, [.holdPosition(121)] + reloadStart)
        case (.deferredFront, "enteredBackground"): return (.away, [.stopStartWatchdog])
        case (.deferredFront, "userPlay"), (.deferredFront, "userPause"): return (.deferred(.playerFront), [])
        case (.deferredFront, "cancelled"): return (.finished, release)

        case (.preparing, "sequenceArmed"): return (.restoring, [])
        case (.preparing, "dropped.notNeeded"): return (.idle, pausedInPlace)
        case (.preparing, "dropped.dropped"): return (.away, [])
        case (.preparing, "dropped.timedOut"): return (.finished, [.handOff(atSec: 120), .setUI(.handingOff), .releasePosition])
        case (.preparing, "enteredBackground"): return (.away, [.cancelRestore(token: 1)])
        case (.preparing, "userPlay"), (.preparing, "userPause"): return (.preparing, [])
        case (.preparing, "cancelled"): return (.finished, [.cancelRestore(token: 1)] + release)

        case (.restoring, "userPlay"), (.restoring, "userPause"): return (.restoring, [])
        case (.restoring, "enteredBackground"): return (.awayRestoring, [.pauseRestoreWatchdog])
        case (.restoring, "finished.settledFrame"): return (.idle, [.holdPosition(130)] + settledPaused)
        case (.restoring, "finished.notNeeded"): return (.idle, [.holdPosition(121)] + settledPaused)
        case (.restoring, "finished.settledNoFrame"):
            return (.restoring, [.holdPosition(130), .schedulePictureNudge(token: 1, afterSec: 3)])
        case (.restoring, "finished.refused"):
            return (.preparing, [.startRestore(.aetherFreshLoad(atSec: 120), token: 2), .refuseTransport(true), .setUI(.restoring)])
        case (.restoring, "finished.failed"), (.restoring, "timedOut"):
            return (.finished, [.handOff(atSec: 120), .setUI(.handingOff), .releasePosition])
        case (.restoring, "nudgeDue"): return (.restoring, [.nudgePicture(atSec: 120)])
        case (.restoring, "cancelled"): return (.finished, [.cancelRestore(token: 1)] + release)

        case (.awayRestoring, "finished.settledFrame"), (.awayRestoring, "finished.settledNoFrame"):
            return (.away, [.holdPosition(130)])
        case (.awayRestoring, "finished.notNeeded"), (.awayRestoring, "finished.refused"),
             (.awayRestoring, "finished.failed"), (.awayRestoring, "timedOut"):
            return (.away, [])
        case (.awayRestoring, "becameActive"): return (.restoring, [.resumeRestoreWatchdog])
        case (.awayRestoring, "userPlay"), (.awayRestoring, "userPause"): return (.awayRestoring, [])
        case (.awayRestoring, "cancelled"): return (.finished, [.cancelRestore(token: 1)] + release)
        default: return nil
        }
    }

    func testEveryModeReachesItsFixture() {
        for key in ModeKey.allCases {
            XCTAssertEqual(build(key).mode, expectedMode(key), "\(key)")
        }
        XCTAssertTrue(build(.preparing).blocksTransport)
        XCTAssertTrue(build(.restoring).blocksTransport)
        XCTAssertTrue(build(.deferredOp).blocksTransport)
        XCTAssertTrue(build(.deferredFront).blocksTransport)
        for key in [ModeKey.idle, .away, .awayRestoring, .abandoned, .finished] {
            XCTAssertFalse(build(key).blocksTransport, "\(key)")
        }
        XCTAssertTrue(build(.idle).allowsPlay)
        XCTAssertFalse(build(.away).allowsPlay)
    }

    func testFullModeTimesEventProduct() {
        for key in ModeKey.allCases {
            let token = build(key).token
            let terminal = key == .abandoned || key == .finished
            let inFlight = key == .preparing || key == .restoring || key == .awayRestoring
            for v in eventVariants {
                // Current token, owner's identity.
                var rule = build(key)
                var fx = rule.handle(v.make(token))
                var label = "\(key) + \(v.key)"
                if !terminal, let (mode, effects) = listed(key, v.key) {
                    XCTAssertEqual(rule.mode, mode, label)
                    XCTAssertEqual(nonLog(fx), effects, label)
                    if !(key == .idle && v.key == "tick") { XCTAssertEqual(logCount(fx), 1, label) }
                } else if !terminal && v.key == "finished.mismatch" {
                    let want: [E] = (inFlight ? [.cancelRestore(token: token)] : [])
                        + [.releasePosition, .refuseTransport(false), .setUI(.normal), .exitPlayer]
                    XCTAssertEqual(rule.mode, .abandoned, label)
                    XCTAssertEqual(nonLog(fx), want, label)
                } else {
                    XCTAssertEqual(rule.mode, expectedMode(key), "\(label) unlisted: unchanged")
                    XCTAssertEqual(nonLog(fx), [], "\(label) unlisted: no effects")
                    XCTAssertEqual(logCount(fx), 1, "\(label) unlisted: one log")
                }

                // A stale token (tokened events only): ignored in every mode.
                if v.tokened {
                    rule = build(key)
                    fx = rule.handle(v.make(token + 7))
                    label = "\(key) + stale \(v.key)"
                    XCTAssertEqual(rule.mode, expectedMode(key), label)
                    XCTAssertEqual(nonLog(fx), [], label)
                }

                // A changed identity (fact-carrying events): the abandon row from every live mode.
                if let mismatch = v.makeMismatch {
                    rule = build(key)
                    fx = rule.handle(mismatch())
                    label = "\(key) + changed identity \(v.key)"
                    if terminal {
                        XCTAssertEqual(rule.mode, expectedMode(key), label)
                        XCTAssertEqual(nonLog(fx), [], label)
                    } else {
                        let want: [E] = (inFlight ? [.cancelRestore(token: token)] : [])
                            + [.releasePosition, .refuseTransport(false), .setUI(.normal), .exitPlayer]
                        XCTAssertEqual(rule.mode, .abandoned, label)
                        XCTAssertEqual(nonLog(fx), want, label)
                    }
                }
            }
        }
    }

    // MARK: Scenarios

    func testReloadThenSettledPausesOnceAndNeverPlays() {
        let h = harness()
        h.send(.enteredBackground(snap()))
        XCTAssertEqual(h.send(.becameActive(facts())), reloadStart)
        h.send(.sequenceArmed(token: 1))
        XCTAssertEqual(h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: true), facts())), [.holdPosition(130)] + settledPaused)
        XCTAssertEqual(h.count(.pauseTransport), 1)
        XCTAssertEqual(h.count(.play), 0)
        XCTAssertEqual(h.rule.mode, .idle)
    }

    func testPlayDuringTheRestoreIsQueuedAndAppliedOnceAtTheSettle() {
        let h = harness()
        reloading(h)
        XCTAssertEqual(h.send(.userPlay(facts())), [], "never a transport effect during a restore")
        XCTAssertEqual(h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: true), facts())), [.holdPosition(130)] + settledPlaying)
        XCTAssertEqual(h.count(.play), 1)
        XCTAssertEqual(h.count(.pauseTransport), 0)
    }

    func testPlayThenPauseDuringTheRestoreNeverPlays() {
        let h = harness()
        reloading(h)
        h.send(.userPlay(facts()))
        h.send(.userPause)
        h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: true), facts()))
        XCTAssertEqual(h.count(.play), 0)
        XCTAssertEqual(h.count(.pauseTransport), 1)
    }

    func testRefusedThenFreshLoadSettledIsOneAttemptThatSucceeds() {
        let h = harness()
        reloading(h)
        XCTAssertEqual(h.send(.restoreFinished(token: 1, .refused, facts())),
                       [.startRestore(.aetherFreshLoad(atSec: 120), token: 2), .refuseTransport(true), .setUI(.restoring)])
        XCTAssertEqual(h.rule.failedAttempts, 0, "a refusal costs nothing")
        h.send(.sequenceArmed(token: 2))
        XCTAssertEqual(h.send(.restoreFinished(token: 2, .settled(clockSec: 120, picture: true), facts())), settledPaused)
        XCTAssertEqual(h.rule.failedAttempts, 0)
    }

    func testRefusedThenFreshLoadFailsHandsOffOnceAtTheHeldPosition() {
        let h = harness()
        reloading(h)
        h.send(.restoreFinished(token: 1, .refused, facts()))
        h.send(.sequenceArmed(token: 2))
        XCTAssertEqual(h.send(.restoreFinished(token: 2, .failed("x"), facts())),
                       [.handOff(atSec: 120), .setUI(.handingOff), .releasePosition])
        XCTAssertEqual(h.rule.failedAttempts, 1)
        XCTAssertEqual(h.count(.handOff(atSec: 120)), 1)
        XCTAssertEqual(h.rule.mode, .finished)
    }

    func testARestoreThatFailsWhileActiveHandsOffOnce() {
        for outcome in [PlayerRestoreOutcome.failed("boom"), .timedOut] {
            let h = harness()
            reloading(h)
            h.send(.restoreFinished(token: 1, outcome, facts()))
            XCTAssertEqual(h.all.filter { if case .handOff = $0 { return true } else { return false } }.count, 1)
            XCTAssertEqual(h.rule.mode, .finished)
        }
        let h = harness()
        reloading(h)
        h.send(.restoreTimedOut(token: 1, facts()))
        XCTAssertEqual(h.count(.handOff(atSec: 120)), 1)
    }

    func testARestoreThatSucceedsWhileAwayDoesNotPlayAndTheNextReturnDecidesAgain() {
        let h = harness()
        reloading(h)
        XCTAssertEqual(h.send(.enteredBackground(snap())), [.pauseRestoreWatchdog])
        h.send(.userPlay(facts()))
        XCTAssertEqual(h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: true), facts())), [.holdPosition(130)])
        XCTAssertEqual(h.count(.play), 0, "no play while away")
        XCTAssertEqual(h.rule.mode, .away, "still pending")
        // The engine kept the restored session: pause in place, with the queued Play.
        let fx = h.send(.becameActive(facts(needs: false)))
        XCTAssertEqual(fx, [.holdPosition(121), .play, .releasePosition, .refuseTransport(false), .setUI(.normal)])
        XCTAssertEqual(h.count(.play), 1)
    }

    func testARestoreThatFailsWhileAwayIsNotAnAttemptAndTheNextReturnTakesAFreshLoad() {
        let h = harness()
        reloading(h)
        h.send(.enteredBackground(snap()))
        XCTAssertEqual(h.send(.restoreFinished(token: 1, .failed("x"), facts())), [])
        XCTAssertEqual(h.rule.failedAttempts, 0)
        XCTAssertEqual(h.all.filter { if case .handOff = $0 { return true } else { return false } }.count, 0)
        let fx = h.send(.becameActive(facts(failed: true)))
        XCTAssertEqual(fx, [.startRestore(.aetherFreshLoad(atSec: 120), token: 2), .refuseTransport(true), .setUI(.restoring)])
    }

    func testANativeRestartCancelledByASecondBackgroundRestartsOnTheNextReturn() {
        let h = harness()
        let s = snap(route: .native)
        h.send(.enteredBackground(s))
        XCTAssertEqual(h.send(.becameActive(facts(needs: nil, health: .alive))),
                       [.startRestore(.nativeRestart(atSec: 120), token: 1), .refuseTransport(true), .setUI(.restoring)])
        h.send(.sequenceArmed(token: 1))
        XCTAssertEqual(h.send(.enteredBackground(s)), [.cancelRestore(token: 1)])
        XCTAssertEqual(h.rule.mode, .away)
        XCTAssertEqual(h.send(.becameActive(facts(needs: nil, health: .alive))),
                       [.startRestore(.nativeRestart(atSec: 120), token: 3), .refuseTransport(true), .setUI(.restoring)])
        XCTAssertEqual(h.rule.failedAttempts, 0, "a cancel is not an attempt")
    }

    func testNativeStartingRestartsFromScratch() {
        let h = harness()
        h.send(.enteredBackground(snap(route: .native, phase: .starting)))
        XCTAssertEqual(h.send(.becameActive(facts(needs: nil))),
                       [.startRestore(.nativeRestartFromScratch, token: 1), .refuseTransport(true), .setUI(.restoring)])
    }

    func testCoveredThenReappearedDecidesOnce() {
        let h = harness()
        h.send(.enteredBackground(snap()))
        XCTAssertEqual(h.send(.becameActive(facts(presence: .covered))), [.refuseTransport(true), .setUI(.restoring)])
        XCTAssertEqual(h.rule.mode, .deferred(.playerFront))
        XCTAssertEqual(h.send(.reappeared(facts())), [.holdPosition(121)] + reloadStart)
        XCTAssertEqual(h.send(.reappeared(facts())), [], "a second reappearance is ignored")
    }

    func testAReAskDecidesEvenWhenItsFactsSayNoBackgroundWasSeen() {
        let h = harness()
        h.send(.enteredBackground(snap()))
        h.send(.becameActive(facts(presence: .covered)))
        XCTAssertEqual(h.send(.reappeared(facts(entered: false))), [.holdPosition(121)] + reloadStart)
    }

    func testDeferredThenSettledReloadsOrPausesInPlace() {
        var h = harness()
        h.send(.enteredBackground(snap()))
        XCTAssertEqual(h.send(.becameActive(facts(op: true))), [.refuseTransport(true), .setUI(.restoring)])
        XCTAssertEqual(h.send(.settled(facts(needs: true))), [.holdPosition(121)] + reloadStart)

        h = harness()
        h.send(.enteredBackground(snap()))
        h.send(.becameActive(facts(op: true)))
        XCTAssertEqual(h.send(.settled(facts(needs: false))), [.holdPosition(121)] + pausedInPlace)
        XCTAssertEqual(h.rule.mode, .idle)
    }

    func testAReturnDuringStartingRearmsTheStartWatchdogAndBackgroundStopsIt() {
        let h = harness()
        XCTAssertEqual(h.send(.enteredBackground(snap(phase: .starting))), [.holdPosition(120), .stopStartWatchdog])
        XCTAssertEqual(h.send(.becameActive(facts(op: true))), [.refuseTransport(true), .setUI(.restoring), .rearmStartWatchdog])
        // A background again while deferred: time away never counts.
        XCTAssertEqual(h.send(.enteredBackground(snap(phase: .starting))), [.stopStartWatchdog])
    }

    func testNoRestoreReturnThenLateTeardownThenPlayReloadsWithPlayQueuedAndPlaysOnce() {
        let h = harness()
        h.send(.enteredBackground(snap()))
        XCTAssertEqual(h.send(.becameActive(facts(needs: false))), [.holdPosition(121)] + pausedInPlace)
        // The engine tears down late: the controller sees needsForegroundRestore at the Play press.
        let fresh = snap(pos: 140)
        XCTAssertEqual(h.send(.restoreOwedInForeground(fresh, facts(clock: 140), pressedPlay: true)),
                       [.holdPosition(140)] + reloadStart)
        h.send(.sequenceArmed(token: 1))
        XCTAssertEqual(h.send(.restoreFinished(token: 1, .settled(clockSec: 141, picture: true), facts())), [.holdPosition(141)] + settledPlaying)
        XCTAssertEqual(h.count(.play), 1)
    }

    func testLateTeardownSeenByTheTickWithoutAPressEndsPaused() {
        let h = harness()
        h.send(.enteredBackground(snap()))
        h.send(.becameActive(facts(needs: false)))
        h.send(.restoreOwedInForeground(snap(pos: 140), facts(clock: 140), pressedPlay: false))
        h.send(.sequenceArmed(token: 1))
        XCTAssertEqual(h.send(.restoreFinished(token: 1, .settled(clockSec: 141, picture: true), facts())), [.holdPosition(141)] + settledPaused)
        XCTAssertEqual(h.count(.play), 0)
    }

    func testAnOwedRestoreThatCannotRunReleasesTheHold() {
        for f in [facts(presence: .leaving), facts(ctx: true)] {
            let h = harness()
            XCTAssertEqual(h.send(.restoreOwedInForeground(snap(), f, pressedPlay: true)), [.holdPosition(120), .releasePosition])
            XCTAssertEqual(h.rule.mode, .idle)
        }
        let h = harness()
        XCTAssertEqual(h.send(.restoreOwedInForeground(snap(), facts(presence: .covered), pressedPlay: false)),
                       [.holdPosition(120), .refuseTransport(true), .setUI(.restoring)])
        XCTAssertEqual(h.rule.mode, .deferred(.playerFront))
        let h2 = harness()
        XCTAssertEqual(h2.send(.restoreOwedInForeground(snap(), facts(op: true), pressedPlay: false)),
                       [.holdPosition(120), .refuseTransport(true), .setUI(.restoring)])
        XCTAssertEqual(h2.rule.mode, .deferred(.operationSettles))
    }

    func testIdentityChangeBeforeTheReturnDuringTheRestoreAndOnAQueuedPlayAbandons() {
        // Before the return.
        var h = harness()
        h.send(.enteredBackground(snap()))
        XCTAssertEqual(h.send(.becameActive(facts(identity: intruder))),
                       [.releasePosition, .refuseTransport(false), .setUI(.normal), .exitPlayer])
        // During the restore await (on restoreFinished): no play, no handOff.
        h = harness()
        reloading(h)
        let fx = h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: true), facts(identity: intruder)))
        XCTAssertEqual(fx, [.cancelRestore(token: 1), .releasePosition, .refuseTransport(false), .setUI(.normal), .exitPlayer])
        XCTAssertEqual(h.count(.play), 0)
        // On a queued Play.
        h = harness()
        reloading(h)
        h.send(.userPlay(facts()))
        h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: true), facts(identity: intruder)))
        XCTAssertEqual(h.count(.play), 0)
        XCTAssertEqual(h.count(.exitPlayer), 1)
        XCTAssertEqual(h.rule.mode, .abandoned)
        // And a failure under a changed identity exits instead of handing off.
        h = harness()
        reloading(h)
        h.send(.restoreTimedOut(token: 1, facts(identity: intruder)))
        XCTAssertEqual(h.all.filter { if case .handOff = $0 { return true } else { return false } }.count, 0)
        XCTAssertEqual(h.count(.exitPlayer), 1)
    }

    func testCancelledMidRestoreLeavesNoEffectsAfterIt() {
        let h = harness()
        reloading(h)
        XCTAssertEqual(h.send(.cancelled), [.cancelRestore(token: 1), .releasePosition, .refuseTransport(false)])
        for v in eventVariants {
            let fx = h.rule.handle(v.make(1))
            XCTAssertEqual(nonLog(fx), [], v.key)
        }
        XCTAssertEqual(h.rule.mode, .finished)
    }

    func testEveryExitPathReleasesThePositionExactlyOnce() {
        func releases(_ h: Harness) -> Int { h.count(.releasePosition) }
        var h = harness()   // nothing
        h.send(.enteredBackground(snap(phase: .ended))); h.send(.becameActive(facts()))
        XCTAssertEqual(releases(h), 1, "nothing")
        h = harness()       // pause in place
        h.send(.enteredBackground(snap())); h.send(.becameActive(facts(needs: false)))
        XCTAssertEqual(releases(h), 1, "pause in place")
        h = harness()       // settle
        reloading(h); h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: true), facts()))
        XCTAssertEqual(releases(h), 1, "settle")
        h = harness()       // deferred then idle
        h.send(.enteredBackground(snap())); h.send(.becameActive(facts(op: true))); h.send(.settled(facts(needs: false)))
        XCTAssertEqual(releases(h), 1, "deferred then idle")
        h = harness()       // failure to mpv
        reloading(h); h.send(.restoreFinished(token: 1, .failed("x"), facts()))
        XCTAssertEqual(releases(h), 1, "handoff")
        h = harness()       // precondition timeout
        h.send(.enteredBackground(snap())); h.send(.becameActive(facts())); h.send(.sequenceDropped(token: 1, .preconditionTimedOut))
        XCTAssertEqual(releases(h), 1, "precondition timeout")
        h = harness()       // abandon
        reloading(h); h.send(.becameActive(facts(identity: intruder)))
        XCTAssertEqual(releases(h), 1, "abandon from restoring")
        h = harness()
        h.send(.enteredBackground(snap())); h.send(.becameActive(facts(identity: intruder)))
        XCTAssertEqual(releases(h), 1, "abandon")
        h = harness()       // cancel
        reloading(h); h.send(.cancelled)
        XCTAssertEqual(releases(h), 1, "cancel")
    }

    func testPreparingDroppedAndPreconditionRows() {
        var h = harness()
        h.send(.enteredBackground(snap())); h.send(.becameActive(facts()))
        XCTAssertEqual(h.send(.sequenceDropped(token: 1, .preconditionTimedOut)),
                       [.handOff(atSec: 120), .setUI(.handingOff), .releasePosition])
        XCTAssertEqual(h.rule.failedAttempts, 1)
        // A background during preparation cancels, moves the token, and the next return restarts under a new one.
        h = harness()
        h.send(.enteredBackground(snap())); h.send(.becameActive(facts()))
        XCTAssertEqual(h.send(.enteredBackground(snap())), [.cancelRestore(token: 1)])
        XCTAssertEqual(h.token, 2)
        XCTAssertEqual(h.send(.sequenceDropped(token: 1, .dropped)), [], "the cancelled sequence's report is stale")
        XCTAssertEqual(h.rule.failedAttempts, 0, "not an attempt")
        XCTAssertEqual(h.send(.becameActive(facts())).first, .startRestore(.aetherReload, token: 3))
    }

    // MARK: Picture (4.9, I9)

    func testSettledWithoutAFrameSchedulesTheNudgeAndKeepsTheWatchdogArmed() {
        let h = harness()
        reloading(h)
        let fx = h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: false), facts()))
        XCTAssertEqual(fx, [.holdPosition(130), .schedulePictureNudge(token: 1, afterSec: 3)])
        XCTAssertEqual(h.rule.mode, .restoring)
        XCTAssertFalse(fx.contains(.resumeRestoreWatchdog))
    }

    func testAFrameBeforeTheNudgeSettlesAndNoNudgeFollows() {
        let h = harness()
        reloading(h)
        h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: false), facts()))
        XCTAssertEqual(h.send(.frameShown(token: 1)), settledPaused)
        XCTAssertEqual(h.send(.pictureNudgeDue(token: 1)), [], "idle ignores a late nudge")
        XCTAssertEqual(h.count(.nudgePicture(atSec: 130)), 0)
    }

    func testNudgeDueIssuesExactlyOneNudgeAndAFrameAfterItSettles() {
        let h = harness()
        reloading(h)
        h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: false), facts()))
        XCTAssertEqual(h.send(.pictureNudgeDue(token: 1)), [.nudgePicture(atSec: 130)])
        XCTAssertEqual(h.send(.pictureNudgeDue(token: 1)), [], "one nudge per return")
        XCTAssertEqual(h.send(.frameShown(token: 1)), settledPaused)
    }

    func testWatchdogExpiryWithNoFrameHandsOffOnce() {
        let h = harness()
        reloading(h)
        h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: false), facts()))
        h.send(.pictureNudgeDue(token: 1))
        XCTAssertEqual(h.send(.restoreTimedOut(token: 1, facts())), [.handOff(atSec: 130), .setUI(.handingOff), .releasePosition])
        XCTAssertEqual(h.all.filter { if case .handOff = $0 { return true } else { return false } }.count, 1)
    }

    func testSettledWithoutAFrameWhileAwayMakesTheNextPauseInPlaceWaitForThePicture() {
        let h = harness()
        reloading(h)
        h.send(.enteredBackground(snap()))
        h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: false), facts()))
        XCTAssertEqual(h.rule.mode, .away)
        let fx = h.send(.becameActive(facts(needs: false)))
        XCTAssertEqual(fx, [.holdPosition(121), .resumeRestoreWatchdog, .schedulePictureNudge(token: 2, afterSec: 3)], "fresh budget and the nudge")
        XCTAssertEqual(h.rule.mode, .restoring)
        XCTAssertEqual(h.send(.userPlay(facts())), [], "a queued Play waits")
        XCTAssertEqual(h.send(.frameShown(token: 2)), settledPlaying)
    }

    func testSettledWithAFrameWhileAwayEndsIdleAsUsual() {
        let h = harness()
        reloading(h)
        h.send(.enteredBackground(snap()))
        h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: true), facts()))
        XCTAssertEqual(h.send(.becameActive(facts(needs: false))), [.holdPosition(121)] + pausedInPlace)
        XCTAssertEqual(h.rule.mode, .idle)
    }

    func testANudgeDueWhileAwayIsIgnoredRescheduledOnReturnAndIssuedOnce() {
        let h = harness()
        reloading(h)
        h.send(.restoreFinished(token: 1, .settled(clockSec: 130, picture: false), facts()))
        XCTAssertEqual(h.send(.enteredBackground(snap())), [.pauseRestoreWatchdog])
        XCTAssertEqual(h.send(.pictureNudgeDue(token: 1)), [], "ignored while away")
        XCTAssertFalse(h.rule.nudgeIssued)
        XCTAssertEqual(h.send(.becameActive(facts())), [.resumeRestoreWatchdog, .schedulePictureNudge(token: 1, afterSec: 3)])
        XCTAssertEqual(h.send(.pictureNudgeDue(token: 1)), [.nudgePicture(atSec: 130)])
        XCTAssertEqual(h.send(.pictureNudgeDue(token: 1)), [])
    }

    // MARK: Backstop

    func testFirstPlayAfterAPauseInPlaceArmsTheBackstopAFrozenClockRebuildsAndTheSecondFreezeHandsOff() {
        func tick(_ now: Double, clock: Double = 10) -> PlayerReturnEvent {
            .backstopTick(PlayerBackstopSample(now: now, clockSec: clock, userPaused: false, reportsPlaying: true,
                                               reportsBuffering: false), facts(needs: false, clock: clock))
        }
        let h = harness()
        h.send(.enteredBackground(snap(pos: 10)))
        h.send(.becameActive(facts(needs: false)))
        XCTAssertTrue(h.rule.backstopOwed)
        XCTAssertEqual(h.send(tick(50)), [], "not armed before the first Play")
        h.send(.userPlay(facts(needs: false, clock: 10)))
        XCTAssertFalse(h.rule.backstopOwed)
        XCTAssertEqual(h.send(tick(100)), [], "armed at the first tick")
        XCTAssertEqual(h.send(tick(107)), [])
        XCTAssertEqual(h.send(tick(108)),
                       [.holdPosition(10), .startRestore(.aetherFreshLoad(atSec: 10), token: 1), .refuseTransport(true), .setUI(.restoring)])
        h.send(.sequenceArmed(token: 1))
        XCTAssertEqual(h.send(.restoreFinished(token: 1, .settled(clockSec: 10, picture: true), facts(needs: false, clock: 10))),
                       settledPlaying, "the rebuild re-arms at its settle and plays")
        XCTAssertEqual(h.send(tick(200)), [])
        XCTAssertEqual(h.send(tick(207)), [])
        XCTAssertEqual(h.send(tick(208)), [.handOff(atSec: 10), .setUI(.handingOff), .releasePosition])
        XCTAssertEqual(h.rule.mode, .finished)
    }

    func testASecondPlayDoesNotArmAgainAndAPauseDisarms() {
        let h = harness()
        h.send(.enteredBackground(snap(pos: 10)))
        h.send(.becameActive(facts(needs: false)))
        h.send(.userPlay(facts(clock: 10)))
        XCTAssertFalse(h.rule.backstopOwed)
        h.send(.userPause)
        h.send(.userPlay(facts(clock: 10)))
        XCTAssertFalse(h.rule.backstopArmPending, "no second arming from a later Play")
    }

    // MARK: Position (4.7)

    func testHoldPrefersThePendingSeekTarget() {
        var p = PlayerReturnPosition()
        p.hold(snap(pos: 100, pending: 250))
        XCTAssertEqual(p.value, 250)
        XCTAssertTrue(p.isHeld)
        p.release()
        XCTAssertFalse(p.isHeld)
        XCTAssertEqual(p.value, 250, "the value stays readable after the release")
        p.hold(snap(pos: 100))
        XCTAssertEqual(p.value, 100)
        p.hold(snap(pos: .nan))
        XCTAssertEqual(p.value, 0)
    }

    func testAdoptAtAnOperationSettleAcceptsAnyFiniteValueIncludingZero() {
        var p = PlayerReturnPosition()
        p.hold(snap(pos: 100, pending: 250))
        XCTAssertTrue(p.adopt(0, at: .operation), "a seek can land or be clamped at 0")
        XCTAssertEqual(p.value, 0)
        p.hold(snap(pos: 100, pending: 250))
        XCTAssertTrue(p.adopt(80, at: .operation), "a seek that landed away from its target: the clock wins")
        XCTAssertEqual(p.value, 80)
        XCTAssertFalse(p.adopt(nil, at: .operation))
        XCTAssertFalse(p.adopt(.nan, at: .operation))
        XCTAssertFalse(p.adopt(.infinity, at: .operation))
        XCTAssertFalse(p.adopt(-3, at: .operation))
        XCTAssertEqual(p.value, 80)
    }

    func testAdoptAtARestoreSettleRejectsATransientZeroUnlessTheHeldValueIsSmall() {
        var p = PlayerReturnPosition()
        p.hold(snap(pos: 120))
        XCTAssertFalse(p.adopt(0, at: .restore), "a 0 over a real position is a reading before the clock reported")
        XCTAssertEqual(p.value, 120)
        XCTAssertTrue(p.adopt(130, at: .restore))
        XCTAssertEqual(p.value, 130)
        p.hold(snap(pos: 1.5))
        XCTAssertTrue(p.adopt(0, at: .restore), "held value under 2 s: 0 is accepted")
        XCTAssertEqual(p.value, 0)
        p.hold(snap(pos: 50))
        XCTAssertFalse(p.adopt(nil, at: .restore))
        XCTAssertFalse(p.adopt(.nan, at: .restore))
        XCTAssertFalse(p.adopt(-1, at: .restore))
        XCTAssertEqual(p.value, 50)
    }

    func testASeekPendingBeforeHomeIsTheHandoffPositionUnlessTheSettleMovedIt() {
        // Held at the user's target; the deferred seek lands at 80: the handoff uses 80, not 200.
        var h = harness()
        h.send(.enteredBackground(snap(phase: .operation, pos: 100, pending: 200)))
        XCTAssertEqual(h.send(.becameActive(facts(op: true))), [.refuseTransport(true), .setUI(.restoring), .rearmStartWatchdog])
        h.send(.settled(facts(needs: true, clock: 80)))
        h.send(.sequenceArmed(token: 1))
        XCTAssertEqual(h.send(.restoreFinished(token: 1, .failed("x"), facts())), [.handOff(atSec: 80), .setUI(.handingOff), .releasePosition])
        // A seek that landed at 0 is accepted.
        h = harness()
        h.send(.enteredBackground(snap(phase: .operation, pos: 100, pending: 200)))
        h.send(.becameActive(facts(op: true)))
        h.send(.settled(facts(needs: true, clock: 0)))
        h.send(.sequenceArmed(token: 1))
        XCTAssertEqual(h.send(.restoreTimedOut(token: 1, facts())), [.handOff(atSec: 0), .setUI(.handingOff), .releasePosition])
        // Untouched by a settle: the held target.
        h = harness()
        h.send(.enteredBackground(snap(pos: 100, pending: 200)))
        h.send(.becameActive(facts()))
        h.send(.sequenceArmed(token: 1))
        XCTAssertEqual(h.send(.restoreTimedOut(token: 1, facts())), [.handOff(atSec: 200), .setUI(.handingOff), .releasePosition])
    }

    // MARK: W2 rulings (spec "W1 gap rulings")

    /// Ruling 9: a pause in place before the first frame (or during an operation) re-arms the start
    /// budget the background stopped; a return that already showed its frame does not.
    func testAPauseInPlaceDuringAStartRearmsTheStartWatchdog() {
        for phase in [PlayerReturnPhase.starting, .operation] {
            let h = harness()
            h.send(.enteredBackground(snap(phase: phase)))
            h.send(.becameActive(facts(op: true)))
            XCTAssertEqual(h.send(.settled(facts(needs: false))), [.holdPosition(121), .rearmStartWatchdog] + pausedInPlace, "\(phase)")
            XCTAssertEqual(h.rule.mode, .idle)
        }
        let h = harness()
        h.send(.enteredBackground(snap(phase: .paused)))
        XCTAssertEqual(h.send(.becameActive(facts(needs: false))), [.holdPosition(121)] + pausedInPlace)
    }

    /// Ruling 5: a reappearance adopts the clock with the restore rule, but not while the operation the
    /// user started before Home is still in flight: its own settle adopts the landing.
    func testAReappearanceWithAnOperationInFlightKeepsTheHeldTarget() {
        let h = harness()
        h.send(.enteredBackground(snap(phase: .operation, pos: 100, pending: 200)))
        h.send(.becameActive(facts(presence: .covered, op: true)))
        XCTAssertEqual(h.rule.mode, .deferred(.playerFront))
        h.send(.reappeared(facts(op: true, clock: 100)))
        XCTAssertEqual(h.rule.mode, .deferred(.operationSettles))
        h.send(.settled(facts(needs: true, clock: nil)))
        h.send(.sequenceArmed(token: 1))
        XCTAssertEqual(h.send(.restoreTimedOut(token: 1, facts())), [.handOff(atSec: 200), .setUI(.handingOff), .releasePosition])
        // With nothing in flight the reappearance adopts the clock (restore rule).
        let g = harness()
        g.send(.enteredBackground(snap(pos: 100)))
        g.send(.becameActive(facts(presence: .covered)))
        g.send(.reappeared(facts(clock: 105)))
        g.send(.sequenceArmed(token: 1))
        XCTAssertEqual(g.send(.restoreTimedOut(token: 1, facts())), [.handOff(atSec: 105), .setUI(.handingOff), .releasePosition])
    }

    // MARK: W5 review r1

    /// r1 finding 1: an adopted landing is emitted as the held position before the release, so the
    /// runner's held value and the mirror the release writes are the landing, never the requested target.
    func testAnAdoptedLandingIsEmittedBeforeTheRelease() {
        // A seek to 250 issued before Home lands at 240 while away; the return pauses in place.
        let h = harness()
        h.send(.enteredBackground(snap(phase: .operation, pos: 100, pending: 250)))
        h.send(.becameActive(facts(op: true)))
        let fx = h.send(.settled(facts(needs: false, clock: 240)))
        XCTAssertEqual(fx.first, .holdPosition(240))
        guard let hold = fx.firstIndex(of: .holdPosition(240)), let release = fx.firstIndex(of: .releasePosition) else {
            return XCTFail("missing effects \(fx)")
        }
        XCTAssertLessThan(hold, release)
        XCTAssertEqual(h.count(.holdPosition(250)), 1, "the target was held once, at background")
        // A restore settle that lands away from the held value: re-held, then released.
        let g = harness()
        reloading(g, snapshot: snap(pos: 100))
        XCTAssertEqual(g.send(.restoreFinished(token: 1, .settled(clockSec: 98, picture: true), facts())),
                       [.holdPosition(98)] + settledPaused)
        // Settled without a frame: the bar follows the landing while the rule waits for the picture.
        let k = harness()
        reloading(k, snapshot: snap(pos: 100))
        XCTAssertEqual(k.send(.restoreFinished(token: 1, .settled(clockSec: 97, picture: false), facts())),
                       [.holdPosition(97), .schedulePictureNudge(token: 1, afterSec: 3)])
        // An unchanged or rejected clock emits nothing extra.
        let m = harness()
        reloading(m, snapshot: snap(pos: 100))
        XCTAssertEqual(m.send(.restoreFinished(token: 1, .settled(clockSec: 100, picture: true), facts())), settledPaused)
        let n = harness()
        reloading(n, snapshot: snap(pos: 100))
        XCTAssertEqual(n.send(.restoreFinished(token: 1, .settled(clockSec: 0, picture: true), facts())), settledPaused,
                       "a transient 0 at a restore settle is not adopted")
    }

    /// r1 finding 2: while the return holds the intent a press toggles it (the held transport stays paused,
    /// so its paused state carries no meaning); otherwise the live transport decides.
    func testAPressTogglesTheQueuedIntentWhileTheReturnHoldsItAndFollowsTheTransportOtherwise() {
        for key in ModeKey.allCases {
            let rule = build(key)
            let holds = [ModeKey.away, .deferredOp, .deferredFront, .preparing, .restoring, .awayRestoring].contains(key)
            XCTAssertEqual(rule.holdsIntent, holds, "\(key)")
            for paused in [true, false] {
                let want = holds ? rule.intent == .pause : paused
                XCTAssertEqual(rule.pressAsksForPlay(transportPaused: paused), want, "\(key) paused=\(paused)")
            }
        }
        // Two presses during a restore with the transport paused throughout: Play then Pause, ends paused.
        let h = harness()
        reloading(h)
        for _ in 0..<2 {
            h.send(h.rule.pressAsksForPlay(transportPaused: true) ? .userPlay(facts()) : .userPause)
        }
        XCTAssertEqual(h.rule.intent, .pause)
        XCTAssertEqual(h.send(.restoreFinished(token: 1, .settled(clockSec: 120, picture: true), facts())), settledPaused)
        XCTAssertEqual(h.count(.play), 0)
        // One press with the mirror still saying "playing": queues Play, not Pause.
        let g = harness()
        reloading(g)
        g.send(g.rule.pressAsksForPlay(transportPaused: false) ? .userPlay(facts()) : .userPause)
        XCTAssertEqual(g.send(.restoreFinished(token: 1, .settled(clockSec: 120, picture: true), facts())), settledPlaying)
    }

    /// r1 finding 3: who owns an Aether session failure, per mode. A failure while a restore op runs in the
    /// background is the restore's (not an attempt, no handoff while away), never the ladder's.
    func testTheFailureOwnerPerMode() {
        typealias O = PlayerForegroundReturnRule.FailureOwner
        let want: [ModeKey: O] = [.idle: .ladder, .away: .ladder, .deferredOp: .operation, .deferredFront: .ladder,
                                  .preparing: .absorbed, .restoring: .restore, .awayRestoring: .restore,
                                  .abandoned: .ladder, .finished: .ladder]
        for key in ModeKey.allCases {
            XCTAssertEqual(build(key).aetherFailureOwner, want[key], "\(key)")
        }
        // The awayRestoring row for that failure: away, no handoff; the next return takes a fresh load.
        var rule = build(.awayRestoring)
        XCTAssertEqual(nonLog(rule.handle(.restoreFinished(token: 1, .failed("reloadFailed"), facts()))), [])
        XCTAssertEqual(rule.mode, .away)
        XCTAssertEqual(rule.failedAttempts, 0)
        XCTAssertEqual(nonLog(rule.handle(.becameActive(facts(failed: true)))),
                       [.startRestore(.aetherFreshLoad(atSec: 120), token: 2), .refuseTransport(true), .setUI(.restoring)])
    }
}
