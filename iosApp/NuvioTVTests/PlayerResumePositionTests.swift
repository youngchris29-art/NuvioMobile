import XCTest
@testable import NuvioTV

/// W5 r2: `PlayerResumePosition`, the one decision about the position a native start or restart must
/// reach. The plan is checked against an oracle written from the prose of the normal start rule over
/// its full input product; the percent step and the restart decision over theirs; then the two review
/// scenarios end to end through the pure types.
final class PlayerResumePositionTests: XCTestCase {

    private typealias P = PlayerResumePosition

    // MARK: plan

    private let retries: [Double?] = [nil, 5, 10, 10.5, 50, .nan]
    private let durations: [Double] = [0, .nan, .infinity, 600]
    private let saved: [Double?] = [nil, 120]
    private let percents: [Double?] = [nil, 0, 40]

    /// The normal start, as written before W5 r2: a retry position over 10 s wins (Start Over included);
    /// then Start Over; then the saved row read with the duration when known (else 0); then, only with
    /// no finite duration, a percentage-only row waits.
    private func oracle(retry: Double?, startOver: Bool, duration: Double, saved: Double?, percent: Double?) -> P.Plan {
        let retryOK = retry.map { $0.isFinite && $0 > 10 } ?? false
        if retryOK, let retry { return .seek(retry) }
        if startOver { return .atStart }
        if let saved { return .seek(saved) }
        let known = duration.isFinite && duration > 0
        if !known, let percent, percent > 0 { return .awaitDuration(percent: percent) }
        return .atStart
    }

    func testPlanMatchesTheStartRuleOverTheFullProduct() {
        for retry in retries {
            for startOver in [false, true] {
                for duration in durations {
                    for s in saved {
                        for pct in percents {
                            var askedWith: [Double] = []
                            let got = P.plan(retryResumeSec: retry, startFromBeginning: startOver, durationSec: duration,
                                             savedResumeSec: { askedWith.append($0); return s },
                                             pendingPercent: { pct })
                            let label = "retry=\(String(describing: retry)) startOver=\(startOver) dur=\(duration) saved=\(String(describing: s)) pct=\(String(describing: pct))"
                            XCTAssertEqual(got, oracle(retry: retry, startOver: startOver, duration: duration, saved: s, percent: pct), label)
                            let known = duration.isFinite && duration > 0
                            for d in askedWith { XCTAssertEqual(d, known ? duration : 0, "\(label): the saved row gets the known duration or 0") }
                        }
                    }
                }
            }
        }
    }

    func testStateAfterEachPlan() {
        XCTAssertEqual(P.state(after: .seek(250)), .seeking(250))
        XCTAssertEqual(P.state(after: .atStart), .done)
        XCTAssertEqual(P.state(after: .awaitDuration(percent: 40)), .awaitingDuration(percent: 40))
    }

    // MARK: percentStep

    func testPercentStepOverPositionAndDuration() {
        let positions: [Double] = [.nan, 0, 12, 29.9, 30, 300]
        let durations: [Double] = [.nan, 0, .infinity, 20, 600]
        for pos in positions {
            for dur in durations {
                let got = P.percentStep(percent: 40, positionSec: pos, durationSec: dur)
                let want: P.PercentStep
                if !pos.isFinite || !dur.isFinite || dur <= 0 { want = .wait }
                else if pos >= 30 { want = .drop }
                else if dur * 0.4 > 10 { want = .seek(dur * 0.4) }
                else { want = .drop }
                XCTAssertEqual(got, want, "pos=\(pos) dur=\(dur)")
            }
        }
    }

    // MARK: restart

    func testRestartOverTheFullProduct() {
        let startups: [PlayerStartResume] = [.unresolved, .seeking(250), .seeking(.nan), .awaitingDuration(percent: 40), .done]
        let clocks: [Double?] = [nil, 0.4, 120]
        let seeks: [Double?] = [nil, 300, -1]
        for ready in [false, true] {
            for startup in startups {
                for clock in clocks {
                    for seek in seeks {
                        let got = P.restart(itemEverReady: ready, startup: startup, clockSec: clock, lastPositionSec: 7,
                                            userSeekInFlightSec: seek)
                        let position = clock ?? 7
                        let want: P.Restart
                        if !ready || startup != .done {
                            if case .seeking(let t) = startup, t.isFinite { want = .fromScratch(positionSec: t) }
                            else { want = .fromScratch(positionSec: position) }
                        } else {
                            want = .midPlay(positionSec: position, pendingSeekSec: seek == 300 ? 300 : nil)
                        }
                        XCTAssertEqual(got, want, "ready=\(ready) startup=\(startup) clock=\(String(describing: clock)) seek=\(String(describing: seek))")
                    }
                }
            }
        }
    }

    // MARK: Review r2 scenarios

    /// Finding 1: background while the start's resume seek to 250 s is in flight (the item is ready, the
    /// clock still near 0). The return restarts from scratch (rerunning the plan) and a failed restart
    /// hands mpv the target, never the clock.
    func testABackgroundDuringTheInitialResumeSeekIsStillAStart() {
        let plan = P.plan(retryResumeSec: nil, startFromBeginning: false, durationSec: 1800,
                          savedResumeSec: { _ in 250 }, pendingPercent: { nil })
        let startup = P.state(after: plan)
        XCTAssertEqual(startup, .seeking(250))
        XCTAssertEqual(P.restart(itemEverReady: true, startup: startup, clockSec: 0.4, lastPositionSec: 0,
                                 userSeekInFlightSec: nil), .fromScratch(positionSec: 250))
        // Once it landed the player is mid-play at its clock.
        XCTAssertEqual(P.restart(itemEverReady: true, startup: .done, clockSec: 250.2, lastPositionSec: 250,
                                 userSeekInFlightSec: nil), .midPlay(positionSec: 250.2, pendingSeekSec: nil))
    }

    /// Finding 1: an ordinary chapter or skip seek still in flight is the target a mid-play restart holds.
    func testAUserSeekInFlightIsTheHeldTarget() {
        XCTAssertEqual(P.restart(itemEverReady: true, startup: .done, clockSec: 60, lastPositionSec: 60,
                                 userSeekInFlightSec: 900), .midPlay(positionSec: 60, pendingSeekSec: 900))
        // The rule holds the pending target (spec 4.7).
        var position = PlayerReturnPosition()
        position.hold(PlayerBackgroundSnapshot(route: .native, phase: .playing, positionSec: 60, pendingSeekTargetSec: 900,
                                               enteredAtUptime: 0, audioTrackID: nil, subtitleTrackID: nil,
                                               subtitleDecided: true, audioName: nil, subtitleName: nil))
        XCTAssertEqual(position.value, 900)
    }

    /// Finding 2: a restart from scratch with a percentage-only (Trakt) row and no duration yet keeps the
    /// percentage, and the first tick with a finite duration seeks there, exactly as the normal start.
    func testARestartFromScratchWithADelayedDurationKeepsAPercentOnlyRow() {
        // The restart reads the plan with the duration unknown (the item's duration not loaded yet).
        let plan = P.plan(retryResumeSec: nil, startFromBeginning: false, durationSec: .nan,
                          savedResumeSec: { _ in nil }, pendingPercent: { 40 })
        XCTAssertEqual(plan, .awaitDuration(percent: 40), "not 'start at 0'")
        var startup = P.state(after: plan)
        XCTAssertEqual(startup, .awaitingDuration(percent: 40))
        // A background now: still a start, so the next return reruns the plan instead of writing over it.
        if case .midPlay = P.restart(itemEverReady: true, startup: startup, clockSec: 1, lastPositionSec: 0,
                                     userSeekInFlightSec: nil) {
            XCTFail("a start waiting for its percentage is not mid-play")
        }
        // Ticks: no duration yet, then 1800 s.
        XCTAssertEqual(P.percentStep(percent: 40, positionSec: 0, durationSec: .nan), .wait)
        guard case .seek(let target) = P.percentStep(percent: 40, positionSec: 0.5, durationSec: 1800) else {
            return XCTFail("the first finite duration applies the percentage")
        }
        XCTAssertEqual(target, 720)
        startup = .seeking(target)
        XCTAssertEqual(P.restart(itemEverReady: true, startup: startup, clockSec: 0.5, lastPositionSec: 0,
                                 userSeekInFlightSec: nil), .fromScratch(positionSec: 720))
    }

    /// Structural: both starts read the resume through the one plan, and nothing else in the
    /// coordinator reads the resume row or the pending percentage.
    func testBothStartsUseTheOnePlan() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NuvioTV/Screens/NativePlaybackCoordinator.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "startResumePlan(durationSec:").count - 1, 3,
                       "the definition, the normal readiness branch and the restart from scratch")
        XCTAssertEqual(source.components(separatedBy: "resumePositionSec(actualDurationSec:").count - 1, 1,
                       "only inside startResumePlan")
        XCTAssertEqual(source.components(separatedBy: "pendingResumePercent()").count - 1, 1,
                       "only inside startResumePlan")
        XCTAssertFalse(source.contains("var pendingResumePercent"), "the percentage is the coordinator's startupResume")
    }

    // MARK: W5 r4: Aether's owed start resume

    func testOwedStepOverStateMediaHoldAndDuration() {
        let states: [PlayerStartResume] = [.unresolved, .seeking(250), .awaitingDuration(percent: 40), .done]
        for state in states {
            for media in [false, true] {
                for held in [false, true] {
                    for dur in [0.0, .nan, 1800] {
                        let got = P.owedStep(state, mediaReady: media, transportHeld: held, positionSec: 0.4, durationSec: dur)
                        let want: P.OwedStep
                        if case .awaitingDuration = state, media, !held, dur.isFinite, dur > 0 { want = .seek(720) }
                        else { want = .keep }
                        XCTAssertEqual(got, want, "\(state) media=\(media) held=\(held) dur=\(dur)")
                    }
                }
            }
        }
        XCTAssertEqual(P.owedStep(.awaitingDuration(percent: 40), mediaReady: true, transportHeld: false,
                                  positionSec: 45, durationSec: 1800), .done, "past the start: dropped")
    }

    /// Finding 1: the first load returns (with its duration) while the return still holds the transport.
    /// The percentage stays owed instead of being dropped by the gate, and the release applies it.
    func testALoadReturningDuringTheReturnKeepsThePercentUntilTheRelease() {
        let plan = P.plan(retryResumeSec: nil, startFromBeginning: false, durationSec: 0,
                          savedResumeSec: { _ in nil }, pendingPercent: { 40 })
        let state = P.state(after: plan)
        XCTAssertEqual(state, .awaitingDuration(percent: 40))
        XCTAssertEqual(P.owedStep(state, mediaReady: true, transportHeld: true, positionSec: 0, durationSec: 1800), .keep,
                       "load returned while the return holds the transport: still owed")
        XCTAssertEqual(P.owedStep(state, mediaReady: true, transportHeld: false, positionSec: 0.2, durationSec: 1800),
                       .seek(720), "the release applies it")
    }

    /// Finding 2: a late-subtitle pick wins the snapshot only while its rebuild runs.
    func testTheSnapshotSubtitlePrefersAPendingPickOnlyDuringItsRebuild() {
        XCTAssertEqual(NativeReturnMath.snapshotSubtitleName(rebuilding: true, pendingLate: "Late", current: "English"), "Late")
        XCTAssertEqual(NativeReturnMath.snapshotSubtitleName(rebuilding: true, pendingLate: nil, current: "English"), "English")
        XCTAssertEqual(NativeReturnMath.snapshotSubtitleName(rebuilding: false, pendingLate: "Late", current: nil), nil,
                       "after the restart consumed it, the viewer's Off wins")
        XCTAssertEqual(NativeReturnMath.snapshotSubtitleName(rebuilding: false, pendingLate: "Late", current: "French"), "French")
    }

    // MARK: W5 r5

    /// Finding 2: settled and stand-down over (op outstanding / returned) x (phase settled / not) x
    /// (frame since the op / stale or none).
    func testRestoreProgressOverOperationPhaseAndFrame() {
        for outstanding in [false, true] {
            for phase in [false, true] {
                for frame in [false, true] {
                    XCTAssertEqual(PlayerRestoreProgress.transportSettled(opOutstanding: outstanding, phaseSettled: phase),
                                   !outstanding && phase)
                    XCTAssertEqual(PlayerRestoreProgress.watchdogStandsDown(opOutstanding: outstanding, phaseSettled: phase,
                                                                           frameSinceOp: frame),
                                   !outstanding && phase && frame, "outstanding=\(outstanding) phase=\(phase) frame=\(frame)")
                }
            }
        }
    }

    /// Finding 1: a mid-play restart serves what this playback served, never the repository's latest list.
    func testAMidPlayRestartServesTheCurrentPlaybacksSubtitles() {
        let served = ["English", "Late English"], next = ["Next ep English"]
        XCTAssertEqual(NativeReturnMath.servedSubtitles(midPlayRestart: true, served: served, fresh: next), served)
        XCTAssertEqual(NativeReturnMath.servedSubtitles(midPlayRestart: false, served: served, fresh: next), next,
                       "a normal start or a restart from scratch builds fresh")
    }
}
