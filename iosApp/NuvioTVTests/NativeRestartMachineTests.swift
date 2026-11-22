import XCTest
@testable import NuvioTV

/// Return from background, 5.2.2: the native restart reducer, its full state x event product, its
/// scenarios, and the two small pure readings the coordinator takes.
final class NativeRestartMachineTests: XCTestCase {

    private let target = NativeRestartTarget(positionSec: 100, audioName: "en", subtitleName: "sub")
    private let kinds: [NativeRestartKind] = [.midPlay, .fromScratch]

    // MARK: Drivers

    /// A landing of restart seek `gen` (durations unknown unless given).
    private func landed(_ clock: Double?, _ picture: Bool, gen: Int = 1, atIssue: Double? = nil,
                        now: Double? = nil) -> NativeRestartEvent {
        .seekLanded(clockSec: clock, durationAtIssueSec: atIssue, durationNowSec: now, pictureReady: picture, generation: gen)
    }

    /// Every restart seek is exact (spec-mpv-return §6.2).
    private func seekFx(_ t: Double, gen: Int = 1) -> NativeRestartEffect { .seek(t, exact: true, generation: gen) }

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
            _ = m.handle(landed(100, true), token: token)
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
            Variant(name: "seekLanded", event: landed(100, true)),
            Variant(name: "seekLanded(50)", event: landed(50, true)),
            Variant(name: "seekLanded(stale)", event: landed(100, true, gen: 0)),
            Variant(name: "seekFailed(stale)", event: .seekFailed(generation: 0)),
            Variant(name: "tracksRestored", event: .tracksRestored),
            Variant(name: "resumeChosen(50)", event: .resumeChosen(.seek(50))),
            Variant(name: "resumeChosen(nil)", event: .resumeChosen(.atStart)),
            Variant(name: "resumeChosen(pct)", event: .resumeChosen(.awaitDuration(percent: 40))),
            Variant(name: "seekFailed", event: .seekFailed(generation: 1)),
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
                ? (.seeking, [seekFx(100), .restoreTracks(audio: "en", subtitle: "sub")])
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
            // Mid-play (target 100): confirmed, but the tracks are still pending, so the settle waits.
            // From scratch (target 50): 50 s off, so one corrective exact seek (spec-mpv-return §6.2).
            return kind == .midPlay ? (.seeking, []) : (.seeking, [seekFx(50, gen: 2)])
        case "seekLanded(50)":
            guard state == .seeking else { return (state, []) }
            let report = NativeRestartEffect.report(.settled(clockSec: 50, picture: true))
            return kind == .midPlay ? (.seeking, [seekFx(100, gen: 2)]) : (.settled, [.startTrackersOnce, report])
        case "seekLanded(stale)", "seekFailed(stale)":
            return (state, [])
        case "tracksRestored":
            // Mid-play seeking: the tracks answer before the seek landed; nothing to settle yet.
            return (state, [])
        case "resumeChosen(50)": return state == .resuming ? (.seeking, [seekFx(50)]) : (state, [])
        case "resumeChosen(nil)":
            guard state == .resuming else { return (state, []) }
            return (.settled, [.startTrackersOnce, .report(.settled(clockSec: 0, picture: false))])
        case "resumeChosen(pct)": return state == .resuming ? (.awaitingDuration, []) : (state, [])
        case "seekFailed":
            // The driver's seeking state has not used its retry: the same target again.
            guard state == .seeking else { return (state, []) }
            return (.seeking, [seekFx(kind == .midPlay ? 100 : 50, gen: 2)])
        case "durationKnown(600)":
            // 40 % of 600 s from 0.5 s: the percentage seek, still unsettled.
            return state == .awaitingDuration ? (.seeking, [seekFx(240)]) : (state, [])
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
        all += m.handle(landed(99.5, false), token: 1)
        all += m.handle(.tracksRestored, token: 1)
        XCTAssertEqual(all, [
            .setPosition(100), .teardownPipeline(keepPlayer: true), .activateAudio, .launchRemux, .makeServer,
            .makeItem(signalingAttempt: 0), seekFx(100), .restoreTracks(audio: "en", subtitle: "sub"),
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
        all += m.handle(landed(42, true), token: 1)
        all += m.handle(landed(42, true), token: 1)
        XCTAssertEqual(all.filter { $0 == .startTrackersOnce }.count, 1)
        XCTAssertEqual(all.last, .report(.settled(clockSec: 42, picture: true)))
        XCTAssertEqual(m.state, .settled)
    }

    func testFromScratchIdentityChangeBeforeTheResumeReadAbandonsWithoutTrackers() {
        var m = machine(.fromScratch, in: .resuming)
        XCTAssertEqual(m.handle(.identityChanged, token: 1), [.reportAbandon])
        XCTAssertEqual(m.handle(.resumeChosen(.seek(42)), token: 1), [])
        XCTAssertEqual(m.handle(landed(42, true), token: 1), [])
        XCTAssertEqual(m.state, .cancelled)
    }

    func testFromScratchIdentityChangeAfterTheSeekAbandonsWithoutTrackers() {
        var m = machine(.fromScratch, in: .seeking)
        XCTAssertEqual(m.handle(.identityChanged, token: 1), [.reportAbandon])
        XCTAssertEqual(m.handle(landed(42, true), token: 1), [])
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
        XCTAssertEqual(m.handle(landed(99.5, true), token: 1), [])
        XCTAssertEqual(m.state, .seeking)
        XCTAssertTrue(m.isActive, "still the one failure owner while the tracks are selected")
        XCTAssertEqual(m.handle(landed(50, false), token: 1), [], "one landing only")
        XCTAssertEqual(m.handle(.tracksRestored, token: 1), [settled])
        XCTAssertEqual(m.state, .settled)
        XCTAssertEqual(m.handle(.tracksRestored, token: 1), [])
        // Tracks first: the landing settles at once.
        m = machine(.midPlay, in: .seeking)
        XCTAssertEqual(m.handle(.tracksRestored, token: 1), [])
        XCTAssertEqual(m.state, .seeking)
        XCTAssertEqual(m.handle(landed(99.5, true), token: 1), [settled])
        // A stale tracks answer moves nothing.
        m = machine(.midPlay, in: .seeking)
        _ = m.handle(landed(99.5, true), token: 1)
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
                        XCTAssertEqual(m.handle(.seekFailed(generation: 1), token: 1), [seekFx(finalTarget, gen: 2)], "\(label): one retry, same target")
                    case .failedTwice:
                        _ = m.handle(.seekFailed(generation: 1), token: 1)
                        run(.seekFailed(generation: 2))
                        XCTAssertEqual(reports, [.failed("seekFailed")], "\(label): the restart fails, never lands")
                        XCTAssertEqual(m.state, .failed, label)
                        run(landed(0, true))
                        XCTAssertEqual(reports.count, 1, label)
                        continue
                    }
                    XCTAssertEqual(reports, [], "\(label): nothing before the landing")
                    run(landed(finalTarget, frameEarly, gen: result == .failedOnce ? 2 : 1))
                    XCTAssertEqual(reports, [.settled(clockSec: finalTarget, picture: frameEarly)], label)
                    XCTAssertEqual(m.state, .settled, label)
                }
            }
        }
    }

    func testAMidPlayCorrectiveSeekThatFailsIsRetriedThenFailsNeverLands() {
        var m = machine(.midPlay, in: .seeking)
        XCTAssertEqual(m.handle(.seekFailed(generation: 1), token: 1), [seekFx(100, gen: 2)])
        XCTAssertEqual(m.handle(.tracksRestored, token: 1), [], "tracks alone settle nothing")
        XCTAssertEqual(m.handle(.seekFailed(generation: 2), token: 1), [.report(.failed("seekFailed"))])
        XCTAssertEqual(m.state, .failed)
        var n = machine(.midPlay, in: .seeking)
        _ = n.handle(.seekFailed(generation: 1), token: 1)
        _ = n.handle(.tracksRestored, token: 1)
        XCTAssertEqual(n.handle(landed(100, false, gen: 2), token: 1),
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

/// spec-mpv-return §6.2-6.3 (Problem 2): every restart seek is exact and its landing is checked by
/// `PlayerLandingCheck` before it is stored; one corrective seek, then the failure (mpv).
final class NativeRestartLandingTests: XCTestCase {

    private func landed(_ clock: Double?, gen: Int, picture: Bool = true, atIssue: Double? = 7000,
                        now: Double? = 7000) -> NativeRestartEvent {
        .seekLanded(clockSec: clock, durationAtIssueSec: atIssue, durationNowSec: now, pictureReady: picture, generation: gen)
    }

    private func fromScratchSeeking(_ target: Double) -> NativeRestartMachine {
        var m = NativeRestartMachine()
        _ = m.handle(.begin(.fromScratch, NativeRestartTarget(positionSec: 0, audioName: nil, subtitleName: nil)), token: 1)
        _ = m.handle(.audioActivated, token: 1)
        _ = m.handle(.firstSegmentReady, token: 1)
        _ = m.handle(.bindSucceeded(url: "u"), token: 1)
        _ = m.handle(.itemReady, token: 1)
        XCTAssertEqual(m.handle(.resumeChosen(.seek(target)), token: 1), [.seek(target, exact: true, generation: 1)])
        return m
    }

    private func midPlaySeeking(_ target: Double) -> NativeRestartMachine {
        var m = NativeRestartMachine()
        _ = m.handle(.begin(.midPlay, NativeRestartTarget(positionSec: target, audioName: "en", subtitleName: nil)), token: 1)
        _ = m.handle(.audioActivated, token: 1)
        _ = m.handle(.firstSegmentReady, token: 1)
        _ = m.handle(.bindSucceeded(url: "u"), token: 1)
        XCTAssertEqual(m.handle(.itemReady, token: 1),
                       [.seek(target, exact: true, generation: 1), .restoreTracks(audio: "en", subtitle: nil)])
        return m
    }

    /// The device pass's row: 1265.781 landed at the segment start 1252.209, corrected, settled.
    func testASegmentStartLandingIsCorrectedThenSettles() {
        var m = fromScratchSeeking(1265.781)
        XCTAssertEqual(m.handle(landed(1252.209, gen: 1), token: 1), [.seek(1265.781, exact: true, generation: 2)])
        XCTAssertEqual(m.state, .seeking)
        XCTAssertTrue(m.correctionUsed)
        XCTAssertEqual(m.handle(landed(1265.78, gen: 2), token: 1),
                       [.startTrackersOnce, .report(.settled(clockSec: 1265.78, picture: true))])
        XCTAssertEqual(m.lastVerdict, .confirmed)
    }

    func testOffTwiceFailsToMpv() {
        var m = fromScratchSeeking(1265.781)
        _ = m.handle(landed(1252.209, gen: 1), token: 1)
        XCTAssertEqual(m.handle(landed(1252.3, gen: 2), token: 1), [.report(.failed("offTarget"))])
        XCTAssertEqual(m.state, .failed)
        XCTAssertEqual(m.handle(landed(1265.78, gen: 3), token: 1), [], "nothing after the failure")
    }

    func testNilAndNegativeLandingsNeverConfirm() {
        for bad: Double? in [nil, -0.5, .nan] {
            var m = fromScratchSeeking(100)
            XCTAssertEqual(m.handle(landed(bad, gen: 1), token: 1), [.seek(100, exact: true, generation: 2)], "\(String(describing: bad))")
            XCTAssertEqual(m.handle(landed(bad, gen: 2), token: 1), [.report(.failed("offTarget"))])
        }
    }

    func testTheEndClampAndAChangedDuration() {
        var m = fromScratchSeeking(7000)
        XCTAssertEqual(m.handle(landed(6999.2, gen: 1), token: 1),
                       [.startTrackersOnce, .report(.settled(clockSec: 6999.2, picture: true))], "inside the end band")
        var n = fromScratchSeeking(100)
        XCTAssertEqual(n.handle(landed(100, gen: 1, atIssue: 7000, now: 3600), token: 1),
                       [.seek(100, exact: true, generation: 2)], "a duration that changed is not confirmable")
    }

    func testAStaleGenerationIsIgnored() {
        var m = fromScratchSeeking(100)
        _ = m.handle(landed(80, gen: 1), token: 1)                          // correction issued, gen 2
        XCTAssertEqual(m.handle(landed(100, gen: 1), token: 1), [], "the first seek's late landing")
        XCTAssertEqual(m.handle(.seekFailed(generation: 1), token: 1), [])
        XCTAssertEqual(m.state, .seeking)
        XCTAssertEqual(m.handle(landed(100, gen: 2), token: 1).last, .report(.settled(clockSec: 100, picture: true)))
    }

    /// Mid-play: tracks before, after and during the correction.
    func testTracksRestoredBeforeAfterAndDuringACorrection() {
        let settled = NativeRestartEffect.report(.settled(clockSec: 300, picture: true))
        // Before: the later confirmed landing settles.
        var a = midPlaySeeking(300)
        XCTAssertEqual(a.handle(.tracksRestored, token: 1), [])
        XCTAssertEqual(a.handle(landed(300, gen: 1), token: 1), [settled])
        // After: the confirmed landing is stored, the tracks settle.
        var b = midPlaySeeking(300)
        XCTAssertEqual(b.handle(landed(300, gen: 1), token: 1), [])
        XCTAssertEqual(b.handle(.tracksRestored, token: 1), [settled])
        // During the correction: nothing is stored by the miss; the correction's landing settles.
        var c = midPlaySeeking(300)
        XCTAssertEqual(c.handle(landed(290, gen: 1), token: 1), [.seek(300, exact: true, generation: 2)])
        XCTAssertNil(c.pendingLanding)
        XCTAssertEqual(c.handle(.tracksRestored, token: 1), [])
        XCTAssertEqual(c.handle(landed(300, gen: 2), token: 1), [settled])
    }

    func testSeekFailedThenACorrection() {
        var m = fromScratchSeeking(500)
        XCTAssertEqual(m.handle(.seekFailed(generation: 1), token: 1), [.seek(500, exact: true, generation: 2)])
        XCTAssertEqual(m.handle(landed(480, gen: 2), token: 1), [.seek(500, exact: true, generation: 3)], "the correction is separate")
        XCTAssertEqual(m.handle(landed(500, gen: 3), token: 1).last, .report(.settled(clockSec: 500, picture: true)))
    }

    func testThePercentageSeekIsExactAndChecked() {
        var m = NativeRestartMachine()
        _ = m.handle(.begin(.fromScratch, NativeRestartTarget(positionSec: 0, audioName: nil, subtitleName: nil)), token: 1)
        _ = m.handle(.audioActivated, token: 1)
        _ = m.handle(.firstSegmentReady, token: 1)
        _ = m.handle(.bindSucceeded(url: "u"), token: 1)
        _ = m.handle(.itemReady, token: 1)
        _ = m.handle(.resumeChosen(.awaitDuration(percent: 40)), token: 1)
        XCTAssertEqual(m.handle(.durationKnown(positionSec: 0.3, durationSec: 1800, pictureReady: false), token: 1),
                       [.seek(720, exact: true, generation: 1)])
        XCTAssertEqual(m.handle(landed(712, gen: 1, atIssue: 1800, now: 1800), token: 1), [.seek(720, exact: true, generation: 2)])
    }

    /// Exhaustive over landing sequences on both kinds: every seek effect is exact, a settle always
    /// follows a `.confirmed` current-generation landing (or no landing at all: the top, a drop), and
    /// at most one report is made.
    func testOracleSettledOnlyAfterAConfirmedLanding() {
        let clocks: [Double?] = [nil, -1, 0, 250, 249.7, 240, 7000]
        let gens = [0, 1, 2, 3]
        for kind in [NativeRestartKind.midPlay, .fromScratch] {
            for c1 in clocks {
                for g1 in gens {
                    for c2 in clocks {
                        for g2 in gens {
                            for tracksAt in 0...2 {
                                var m = kind == .midPlay ? midPlaySeeking(250) : fromScratchSeeking(250)
                                var reports = 0
                                var settledVerdict: PlayerLandingCheck.Verdict?
                                func feed(_ e: NativeRestartEvent) {
                                    for fx in m.handle(e, token: 1) {
                                        if case .seek(_, let exact, _) = fx { XCTAssertTrue(exact) }
                                        if case .report(let o) = fx {
                                            reports += 1
                                            if case .settled = o { settledVerdict = m.lastVerdict }
                                        }
                                    }
                                }
                                if tracksAt == 0 { feed(.tracksRestored) }
                                feed(landed(c1, gen: g1))
                                if tracksAt == 1 { feed(.tracksRestored) }
                                feed(landed(c2, gen: g2))
                                if tracksAt == 2 { feed(.tracksRestored) }
                                XCTAssertLessThanOrEqual(reports, 1)
                                if m.state == .settled {
                                    XCTAssertEqual(settledVerdict, .confirmed, "\(kind) \(String(describing: c1))/\(g1) \(String(describing: c2))/\(g2) t\(tracksAt)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
