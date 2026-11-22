import XCTest
@testable import NuvioTV

/// Return from background, 5.2.2: the native restart reducer, its full state x event product, its
/// scenarios, and the two small pure readings the coordinator takes.
final class NativeRestartMachineTests: XCTestCase {

    private let target = NativeRestartTarget(positionSec: 100, audioName: "en", subtitleName: "sub")
    private let kinds: [NativeRestartKind] = [.midPlay, .fromScratch]

    // MARK: Drivers

    private func machine(_ kind: NativeRestartKind, in state: NativeRestartState, token: Int = 1) -> NativeRestartMachine {
        var m = NativeRestartMachine()
        if state == .idle { return m }
        _ = m.handle(.begin(kind, target), token: token)
        if state == .activating { return m }
        if state == .cancelled { _ = m.handle(.cancel, token: token); return m }
        if state == .failed { _ = m.handle(.remuxFailed(stage: "setup"), token: token); return m }
        _ = m.handle(.audioActivated, token: token)
        if state == .launching { return m }
        _ = m.handle(.firstSegmentReady, token: token)
        if state == .binding { return m }
        _ = m.handle(.bindSucceeded(url: "http://127.0.0.1:1/a.m3u8"), token: token)
        if state == .itemPending { return m }
        _ = m.handle(.itemReady, token: token)
        if state == .resuming || (state == .seeking && kind == .midPlay) { return m }
        if state == .seeking { _ = m.handle(.resumeChosen(.seek(50)), token: token); return m }
        if state == .awaitingDuration { _ = m.handle(.resumeChosen(.awaitDuration(percent: 40)), token: token); return m }
        // settled
        if kind == .midPlay {
            _ = m.handle(.seekLanded(clockSec: 100, pictureReady: true), token: token)
            _ = m.handle(.tracksRestored, token: token)
        } else { _ = m.handle(.resumeChosen(.atStart), token: token) }
        return m
    }

    private func reachable(_ kind: NativeRestartKind) -> [NativeRestartState] {
        var all: [NativeRestartState] = [.idle, .activating, .launching, .binding, .itemPending, .seeking,
                                         .settled, .failed, .cancelled]
        if kind == .fromScratch { all += [.resuming, .awaitingDuration] }
        return all
    }

    private struct Variant {
        let name: String
        let event: NativeRestartEvent
    }

    private var variants: [Variant] {
        [
            Variant(name: "audioActivated", event: .audioActivated),
            Variant(name: "firstSegmentReady", event: .firstSegmentReady),
            Variant(name: "bindSucceeded", event: .bindSucceeded(url: "u")),
            Variant(name: "bindFailed", event: .bindFailed),
            Variant(name: "itemReady", event: .itemReady),
            Variant(name: "itemFailedPreReady(true)", event: .itemFailedPreReady(signalingRetryAllowed: true)),
            Variant(name: "itemFailedPreReady(false)", event: .itemFailedPreReady(signalingRetryAllowed: false)),
            Variant(name: "itemFailedAfterReady", event: .itemFailedAfterReady),
            Variant(name: "remuxFailed", event: .remuxFailed(stage: "x")),
            Variant(name: "seekLanded", event: .seekLanded(clockSec: 100, pictureReady: true)),
            Variant(name: "tracksRestored", event: .tracksRestored),
            Variant(name: "resumeChosen(50)", event: .resumeChosen(.seek(50))),
            Variant(name: "resumeChosen(nil)", event: .resumeChosen(.atStart)),
            Variant(name: "resumeChosen(pct)", event: .resumeChosen(.awaitDuration(percent: 40))),
            Variant(name: "seekFailed", event: .seekFailed),
            Variant(name: "durationKnown(600)", event: .durationKnown(positionSec: 0.5, durationSec: 600, pictureReady: false)),
            Variant(name: "durationKnown(nan)", event: .durationKnown(positionSec: 0.5, durationSec: .nan, pictureReady: false)),
            Variant(name: "identityChanged", event: .identityChanged),
            Variant(name: "deadline", event: .deadline),
            Variant(name: "stop", event: .stop),
            Variant(name: "cancel", event: .cancel),
        ]
    }

    private func isActive(_ s: NativeRestartState) -> Bool {
        [.activating, .launching, .binding, .itemPending, .seeking, .resuming, .awaitingDuration].contains(s)
    }

    /// The expected (next state, effects) for a current-token event, written from the prose of 5.2.2.
    private func expected(_ kind: NativeRestartKind, _ state: NativeRestartState, _ name: String)
        -> (NativeRestartState, [NativeRestartEffect]) {
        guard isActive(state) else {
            return (state, name == "bindSucceeded" ? [.stopServer(stale: true)] : [])
        }
        switch name {
        case "stop", "cancel": return (.cancelled, [])
        case "identityChanged": return (.cancelled, [.reportAbandon])
        case "deadline": return (.failed, [.report(.timedOut)])
        case "remuxFailed": return (.failed, [.report(.failed("remuxFailed:x"))])
        case "audioActivated": return state == .activating ? (.launching, [.launchRemux]) : (state, [])
        case "firstSegmentReady": return state == .launching ? (.binding, [.makeServer]) : (state, [])
        case "bindSucceeded":
            return state == .binding ? (.itemPending, [.makeItem(signalingAttempt: 0)]) : (state, [.stopServer(stale: true)])
        case "bindFailed": return state == .binding ? (.failed, [.report(.failed("bindFailed"))]) : (state, [])
        case "itemReady":
            guard state == .itemPending else { return (state, []) }
            return kind == .midPlay
                ? (.seeking, [.seek(100), .restoreTracks(audio: "en", subtitle: "sub")])
                : (.resuming, [])
        case "itemFailedPreReady(true)":
            return state == .itemPending ? (.itemPending, [.makeItem(signalingAttempt: 1)]) : (state, [])
        case "itemFailedPreReady(false)":
            return state == .itemPending ? (.failed, [.report(.failed("itemFailedPreReady"))]) : (state, [])
        case "itemFailedAfterReady":
            return [.seeking, .resuming, .awaitingDuration].contains(state)
                ? (.failed, [.report(.failed("itemFailedAfterReady"))]) : (state, [])
        case "seekLanded":
            guard state == .seeking else { return (state, []) }
            // Mid-play: the tracks are still pending in the driver's seeking state, so the settle waits.
            let report = NativeRestartEffect.report(.settled(clockSec: 100, picture: true))
            return kind == .midPlay ? (.seeking, []) : (.settled, [.startTrackersOnce, report])
        case "tracksRestored":
            // Mid-play seeking: the tracks answer before the seek landed; nothing to settle yet.
            return (state, [])
        case "resumeChosen(50)": return state == .resuming ? (.seeking, [.seek(50)]) : (state, [])
        case "resumeChosen(nil)":
            guard state == .resuming else { return (state, []) }
            return (.settled, [.startTrackersOnce, .report(.settled(clockSec: 0, picture: false))])
        case "resumeChosen(pct)": return state == .resuming ? (.awaitingDuration, []) : (state, [])
        case "seekFailed":
            // The driver's seeking state has not used its retry: the same target again.
            guard state == .seeking else { return (state, []) }
            return (.seeking, [.seek(kind == .midPlay ? 100 : 50)])
        case "durationKnown(600)":
            // 40 % of 600 s from 0.5 s: the percentage seek, still unsettled.
            return state == .awaitingDuration ? (.seeking, [.seek(240)]) : (state, [])
        case "durationKnown(nan)": return (state, [])
        default:
            XCTFail("unknown variant \(name)")
            return (state, [])
        }
    }

    // MARK: Full product

    func testFullStateTimesEventProductWithTheCurrentToken() {
        for kind in kinds {
            for state in reachable(kind) {
                for v in variants {
                    var m = machine(kind, in: state)
                    XCTAssertEqual(m.state, state, "driver \(kind) \(state)")
                    let fx = m.handle(v.event, token: 1)
                    let (next, effects) = expected(kind, state, v.name)
                    XCTAssertEqual(m.state, next, "\(kind) \(state) + \(v.name)")
                    XCTAssertEqual(fx, effects, "\(kind) \(state) + \(v.name)")
                }
            }
        }
    }

    func testFullStateTimesEventProductWithAStaleToken() {
        for kind in kinds {
            for state in reachable(kind) {
                for v in variants {
                    var m = machine(kind, in: state)
                    let fx = m.handle(v.event, token: 99)
                    XCTAssertEqual(m.state, state, "\(kind) \(state) + stale \(v.name)")
                    let wantStop = v.name == "bindSucceeded"
                    XCTAssertEqual(fx, wantStop ? [.stopServer(stale: true)] : [], "\(kind) \(state) + stale \(v.name)")
                }
            }
        }
    }

    func testBeginFromEveryStateStartsAgainOnlyWithANewerToken() {
        for kind in kinds {
            for state in reachable(kind) {
                var m = machine(kind, in: state)
                if state != .idle {
                    let stale = m.handle(.begin(kind, target), token: 1)
                    XCTAssertEqual(stale, [], "same token is ignored from \(state)")
                    XCTAssertEqual(m.state, state)
                }
                let fx = m.handle(.begin(kind, target), token: 2)
                XCTAssertEqual(m.state, .activating, "\(kind) from \(state)")
                XCTAssertEqual(m.token, 2)
                XCTAssertEqual(fx, beginEffects(kind))
                // The superseded token no longer reaches the machine.
                XCTAssertEqual(m.handle(.audioActivated, token: 1), [])
                XCTAssertEqual(m.state, .activating)
            }
        }
    }

    private func beginEffects(_ kind: NativeRestartKind) -> [NativeRestartEffect] {
        switch kind {
        case .midPlay: return [.setPosition(100), .teardownPipeline(keepPlayer: true), .activateAudio]
        case .fromScratch: return [.teardownPipeline(keepPlayer: false), .activateAudio]
        }
    }

    // MARK: Scenarios

    func testPositionIsSetBeforeTheTeardown() {
        var m = NativeRestartMachine()
        let fx = m.handle(.begin(.midPlay, target), token: 1)
        guard let set = fx.firstIndex(of: .setPosition(100)), let tear = fx.firstIndex(of: .teardownPipeline(keepPlayer: true)) else {
            return XCTFail("missing effects \(fx)")
        }
        XCTAssertLessThan(set, tear)
    }

    func testFromScratchSetsNoPositionAndKeepsNothingOfThePlayer() {
        var m = NativeRestartMachine()
        let fx = m.handle(.begin(.fromScratch, target), token: 1)
        XCTAssertFalse(fx.contains(.setPosition(100)))
        XCTAssertEqual(fx.first, .teardownPipeline(keepPlayer: false))
    }

    func testStopBeforeTheItemIsReadyReportsNothing() {
        for state in [NativeRestartState.activating, .launching, .binding, .itemPending] {
            var m = machine(.midPlay, in: state)
            XCTAssertEqual(m.handle(.stop, token: 1), [])
            XCTAssertEqual(m.state, .cancelled)
            for v in variants where v.name != "bindSucceeded" {
                XCTAssertEqual(m.handle(v.event, token: 1), [], "after stop: \(v.name)")
            }
        }
    }

    func testEachFailureSourceReportsExactlyOnce() {
        let sources: [(String, NativeRestartState, NativeRestartEvent)] = [
            ("remux failed", .launching, .remuxFailed(stage: "noSegments")),
            ("bind failed", .binding, .bindFailed),
            ("item failed pre-ready, no retry allowed", .itemPending, .itemFailedPreReady(signalingRetryAllowed: false)),
            ("not-ready rule", .itemPending, .itemFailedPreReady(signalingRetryAllowed: false)),
            ("item failed after ready", .seeking, .itemFailedAfterReady),
            ("deadline", .itemPending, .deadline),
        ]
        for (label, state, event) in sources {
            var m = machine(.midPlay, in: state)
            var reports = 0
            for e in [event, .deadline, .remuxFailed(stage: "again"), .bindFailed, .itemFailedAfterReady,
                      .itemFailedPreReady(signalingRetryAllowed: true)] {
                reports += m.handle(e, token: 1).filter { if case .report = $0 { return true } else { return false } }.count
            }
            XCTAssertEqual(reports, 1, label)
            XCTAssertEqual(m.state, .failed, label)
        }
    }

    func testAtMostOneSignalingRetryInsideTheOneAttempt() {
        var m = machine(.midPlay, in: .itemPending)
        XCTAssertEqual(m.handle(.itemFailedPreReady(signalingRetryAllowed: true), token: 1), [.makeItem(signalingAttempt: 1)])
        XCTAssertEqual(m.state, .itemPending)
        XCTAssertEqual(m.signalingAttempt, 1)
        XCTAssertEqual(m.handle(.itemFailedPreReady(signalingRetryAllowed: true), token: 1),
                       [.report(.failed("itemFailedPreReady"))], "the second pre-ready failure is the failure")
        XCTAssertEqual(m.state, .failed)
    }

    func testRetryNotAllowedFailsAtOnce() {
        var m = machine(.midPlay, in: .itemPending)
        XCTAssertEqual(m.handle(.itemFailedPreReady(signalingRetryAllowed: false), token: 1),
                       [.report(.failed("itemFailedPreReady"))])
    }

    func testCancelByTokenLeavesNothingAfterIt() {
        var m = machine(.fromScratch, in: .binding)
        _ = m.handle(.cancel, token: 1)
        for v in variants where v.name != "bindSucceeded" {
            XCTAssertEqual(m.handle(v.event, token: 1), [], v.name)
        }
        XCTAssertEqual(m.state, .cancelled)
    }

    func testAStaleBindSucceededStopsItsServerAndNothingElse() {
        var m = machine(.midPlay, in: .binding)
        _ = m.handle(.begin(.midPlay, target), token: 2)
        XCTAssertEqual(m.handle(.bindSucceeded(url: "old"), token: 1), [.stopServer(stale: true)])
        XCTAssertEqual(m.state, .activating)
        XCTAssertEqual(m.token, 2)
    }

    func testABindThatArrivesInTheWrongStateStopsItsServer() {
        var m = machine(.midPlay, in: .itemPending)
        XCTAssertEqual(m.handle(.bindSucceeded(url: "dup"), token: 1), [.stopServer(stale: true)])
        XCTAssertEqual(m.state, .itemPending)
    }

    func testMidPlayRunEndToEndStartsNoTrackersAndSeeksOnce() {
        var m = NativeRestartMachine()
        var all: [NativeRestartEffect] = []
        all += m.handle(.begin(.midPlay, target), token: 1)
        all += m.handle(.audioActivated, token: 1)
        all += m.handle(.firstSegmentReady, token: 1)
        all += m.handle(.bindSucceeded(url: "u"), token: 1)
        all += m.handle(.itemReady, token: 1)
        all += m.handle(.seekLanded(clockSec: 99.5, pictureReady: false), token: 1)
        all += m.handle(.tracksRestored, token: 1)
        XCTAssertEqual(all, [
            .setPosition(100), .teardownPipeline(keepPlayer: true), .activateAudio, .launchRemux, .makeServer,
            .makeItem(signalingAttempt: 0), .seek(100), .restoreTracks(audio: "en", subtitle: "sub"),
            .report(.settled(clockSec: 99.5, picture: false)),
        ])
        XCTAssertFalse(all.contains(.startTrackersOnce))
        XCTAssertEqual(m.state, .settled)
    }

    func testFromScratchRunEndToEndStartsTrackersOnce() {
        var m = NativeRestartMachine()
        var all: [NativeRestartEffect] = []
        all += m.handle(.begin(.fromScratch, target), token: 1)
        all += m.handle(.audioActivated, token: 1)
        all += m.handle(.firstSegmentReady, token: 1)
        all += m.handle(.bindSucceeded(url: "u"), token: 1)
        all += m.handle(.itemReady, token: 1)
        all += m.handle(.resumeChosen(.seek(42)), token: 1)
        all += m.handle(.seekLanded(clockSec: 42, pictureReady: true), token: 1)
        all += m.handle(.seekLanded(clockSec: 42, pictureReady: true), token: 1)
        XCTAssertEqual(all.filter { $0 == .startTrackersOnce }.count, 1)
        XCTAssertEqual(all.last, .report(.settled(clockSec: 42, picture: true)))
        XCTAssertEqual(m.state, .settled)
    }

    func testFromScratchIdentityChangeBeforeTheResumeReadAbandonsWithoutTrackers() {
        var m = machine(.fromScratch, in: .resuming)
        XCTAssertEqual(m.handle(.identityChanged, token: 1), [.reportAbandon])
        XCTAssertEqual(m.handle(.resumeChosen(.seek(42)), token: 1), [])
        XCTAssertEqual(m.handle(.seekLanded(clockSec: 42, pictureReady: true), token: 1), [])
        XCTAssertEqual(m.state, .cancelled)
    }

    func testFromScratchIdentityChangeAfterTheSeekAbandonsWithoutTrackers() {
        var m = machine(.fromScratch, in: .seeking)
        XCTAssertEqual(m.handle(.identityChanged, token: 1), [.reportAbandon])
        XCTAssertEqual(m.handle(.seekLanded(clockSec: 42, pictureReady: true), token: 1), [])
        XCTAssertEqual(m.state, .cancelled)
    }

    func testAResumeOfZeroStartsAtTheTopWithoutASeek() {
        var m = machine(.fromScratch, in: .resuming)
        XCTAssertEqual(m.handle(.resumeChosen(.seek(0)), token: 1),
                       [.startTrackersOnce, .report(.settled(clockSec: 0, picture: false))])
    }

    /// W5 r1: the mid-play restart settles only once both the corrective seek landed and the snapshot's
    /// tracks were selected, in either order, so a late selection never lands after the viewer's own pick.
    func testAMidPlayRestartSettlesOnlyAfterTheSeekAndTheTracks() {
        let settled = NativeRestartEffect.report(.settled(clockSec: 99.5, picture: true))
        // Seek first: held until the tracks answer, then settled with the seek's landing.
        var m = machine(.midPlay, in: .seeking)
        XCTAssertTrue(m.tracksPending)
        XCTAssertEqual(m.handle(.seekLanded(clockSec: 99.5, pictureReady: true), token: 1), [])
        XCTAssertEqual(m.state, .seeking)
        XCTAssertTrue(m.isActive, "still the one failure owner while the tracks are selected")
        XCTAssertEqual(m.handle(.seekLanded(clockSec: 50, pictureReady: false), token: 1), [], "one landing only")
        XCTAssertEqual(m.handle(.tracksRestored, token: 1), [settled])
        XCTAssertEqual(m.state, .settled)
        XCTAssertEqual(m.handle(.tracksRestored, token: 1), [])
        // Tracks first: the landing settles at once.
        m = machine(.midPlay, in: .seeking)
        XCTAssertEqual(m.handle(.tracksRestored, token: 1), [])
        XCTAssertEqual(m.state, .seeking)
        XCTAssertEqual(m.handle(.seekLanded(clockSec: 99.5, pictureReady: true), token: 1), [settled])
        // A stale tracks answer moves nothing.
        m = machine(.midPlay, in: .seeking)
        _ = m.handle(.seekLanded(clockSec: 99.5, pictureReady: true), token: 1)
        XCTAssertEqual(m.handle(.tracksRestored, token: 9), [])
        XCTAssertEqual(m.state, .seeking)
        // A failure while the tracks are selected is the one report.
        XCTAssertEqual(m.handle(.itemFailedAfterReady, token: 1), [.report(.failed("itemFailedAfterReady"))])
        XCTAssertEqual(m.handle(.tracksRestored, token: 1), [])
        // From scratch selects no tracks: its landing settles directly.
        m = machine(.fromScratch, in: .seeking)
        XCTAssertFalse(m.tracksPending)
    }

    // MARK: W5 r3: settled ⇔ the player is confirmed at the final target

    private enum SeekResult: CaseIterable { case ok, failedOnce, failedTwice }

    /// The product (seek ok / failed then ok / failed twice) x (percentage pending / none) x (frame early /
    /// late), from scratch, plus the mid-play corrective seek. The machine reports exactly one outcome;
    /// a settle carries the landing at the final target, never a seek that returned false; a pending
    /// percentage keeps it unsettled until its own seek landed.
    func testSettledOnlyAtTheFinalTargetOverSeekResultPercentAndFrame() {
        for result in SeekResult.allCases {
            for percent in [false, true] {
                for frameEarly in [false, true] {
                    let label = "\(result) percent=\(percent) frameEarly=\(frameEarly)"
                    var m = machine(.fromScratch, in: .resuming)
                    var reports: [PlayerRestoreOutcome] = []
                    func run(_ e: NativeRestartEvent) {
                        for fx in m.handle(e, token: 1) { if case .report(let o) = fx { reports.append(o) } }
                    }
                    let finalTarget: Double
                    if percent {
                        run(.resumeChosen(.awaitDuration(percent: 40)))
                        XCTAssertEqual(m.state, .awaitingDuration, label)
                        run(.durationKnown(positionSec: 0, durationSec: .nan, pictureReady: frameEarly))
                        XCTAssertEqual(reports, [], "\(label): no duration, no settle")
                        run(.durationKnown(positionSec: 0.3, durationSec: 1800, pictureReady: frameEarly))
                        finalTarget = 720
                    } else {
                        run(.resumeChosen(.seek(250)))
                        finalTarget = 250
                    }
                    XCTAssertEqual(m.state, .seeking, label)
                    XCTAssertEqual(m.seekTarget, finalTarget, label)
                    switch result {
                    case .ok:
                        break
                    case .failedOnce:
                        XCTAssertEqual(m.handle(.seekFailed, token: 1), [.seek(finalTarget)], "\(label): one retry, same target")
                    case .failedTwice:
                        _ = m.handle(.seekFailed, token: 1)
                        run(.seekFailed)
                        XCTAssertEqual(reports, [.failed("seekFailed")], "\(label): the restart fails, never lands")
                        XCTAssertEqual(m.state, .failed, label)
                        run(.seekLanded(clockSec: 0, pictureReady: true))
                        XCTAssertEqual(reports.count, 1, label)
                        continue
                    }
                    XCTAssertEqual(reports, [], "\(label): nothing before the landing")
                    run(.seekLanded(clockSec: finalTarget, pictureReady: frameEarly))
                    XCTAssertEqual(reports, [.settled(clockSec: finalTarget, picture: frameEarly)], label)
                    XCTAssertEqual(m.state, .settled, label)
                }
            }
        }
    }

    func testAMidPlayCorrectiveSeekThatFailsIsRetriedThenFailsNeverLands() {
        var m = machine(.midPlay, in: .seeking)
        XCTAssertEqual(m.handle(.seekFailed, token: 1), [.seek(100)])
        XCTAssertEqual(m.handle(.tracksRestored, token: 1), [], "tracks alone settle nothing")
        XCTAssertEqual(m.handle(.seekFailed, token: 1), [.report(.failed("seekFailed"))])
        XCTAssertEqual(m.state, .failed)
        var n = machine(.midPlay, in: .seeking)
        _ = n.handle(.seekFailed, token: 1)
        _ = n.handle(.tracksRestored, token: 1)
        XCTAssertEqual(n.handle(.seekLanded(clockSec: 100, pictureReady: false), token: 1),
                       [.report(.settled(clockSec: 100, picture: false))], "the retry's landing settles")
    }

    func testAPercentThatResolvesToDropSettlesAtThePosition() {
        var m = machine(.fromScratch, in: .awaitingDuration)
        XCTAssertEqual(m.handle(.durationKnown(positionSec: 2, durationSec: 20, pictureReady: true), token: 1),
                       [.startTrackersOnce, .report(.settled(clockSec: 2, picture: true))], "40 % of 20 s is under 10 s")
    }

    func testIsActiveCoversExactlyTheInFlightStates() {
        for kind in kinds {
            for state in reachable(kind) {
                XCTAssertEqual(machine(kind, in: state).isActive, isActive(state), "\(state)")
            }
        }
    }

    // MARK: Pure readings

    func testSnapshotPositionFallsBackToLastPositionThenZero() {
        XCTAssertEqual(NativeReturnMath.snapshotPositionSec(playerTimeSec: 12.5, lastPositionSec: 9), 12.5)
        XCTAssertEqual(NativeReturnMath.snapshotPositionSec(playerTimeSec: 0, lastPositionSec: 9), 0)
        XCTAssertEqual(NativeReturnMath.snapshotPositionSec(playerTimeSec: nil, lastPositionSec: 9), 9)
        XCTAssertEqual(NativeReturnMath.snapshotPositionSec(playerTimeSec: .nan, lastPositionSec: 9), 9)
        XCTAssertEqual(NativeReturnMath.snapshotPositionSec(playerTimeSec: -1, lastPositionSec: 9), 9)
        XCTAssertEqual(NativeReturnMath.snapshotPositionSec(playerTimeSec: .infinity, lastPositionSec: .nan), 0)
        XCTAssertEqual(NativeReturnMath.snapshotPositionSec(playerTimeSec: nil, lastPositionSec: -4), 0)
    }

    func testHealthMappingOverPingListenerAndRemux() {
        for ping in [nil, true, false] as [Bool?] {
            for listener in [false, true] {
                for remux in [false, true] {
                    let got = NativeReturnMath.health(pingAnswered: ping, listenerFailedAfterReady: listener, remuxFailed: remux)
                    let want: PlayerNativeHealth
                    if remux { want = .remuxDead }
                    else if listener || ping == false { want = .listenerDead }
                    else if ping == true { want = .alive }
                    else { want = .unknown }
                    XCTAssertEqual(got, want, "ping \(String(describing: ping)) listener \(listener) remux \(remux)")
                }
            }
        }
    }
}
