import AVFoundation
import NuvioAether
import XCTest
@testable import NuvioTV

/// Aether Phase 1, W3-C: the failure ladder (`AetherFailurePolicy`), the interruption window, and the
/// once rule as the controller sees it (`AetherFailurePlan.resolve`).
@MainActor
final class AetherFailurePolicyTests: XCTestCase {

    private let interruptionKinds: [AetherFailureKind] = [.nativeItemFailed, .softwarePipelineFailed]

    private func failure(_ kind: AetherFailureKind) -> AetherFailure {
        AetherFailure(kind: kind, message: "x", atSec: 12, beforeFirstFrame: false)
    }

    private func decide(_ kind: AetherFailureKind, started: Bool = true, since: Double? = nil) -> AetherFailureDecision {
        AetherFailurePolicy.decide(kind: kind, startedPlaying: started, secondsPlayed: started ? 40 : 0,
                                   sinceInterruptionSec: since)
    }

    // MARK: Ladder rows

    func testRateLimitIsTerminalWithAndWithoutAnInterruption() {
        XCTAssertEqual(decide(.sourceRateLimited), .fail)
        XCTAssertEqual(decide(.sourceRateLimited, started: false), .fail)
        XCTAssertEqual(decide(.sourceRateLimited, since: 1), .fail, "an interruption never turns a rate limit into a rebuild")
    }

    func testEveryEngineTokenHasTheLadderRowWithNoInterruption() {
        // The 22 tokens 7.54.0 defines, plus the façade's firstFrameTimeout and an unknown future token.
        var kinds = AetherFailureKind.engineTokens.map { AetherFailureKind(token: $0) }
        kinds += [.firstFrameTimeout, .unknown("future"), .unknown("thrown:ProbeError")]
        XCTAssertEqual(AetherFailureKind.engineTokens.count, 22)
        for kind in kinds {
            let expected: AetherFailureDecision = kind == .sourceRateLimited ? .fail : .fallbackToMpv
            for started in [true, false] {
                XCTAssertEqual(decide(kind, started: started), expected, "\(kind.token) started=\(started)")
            }
        }
    }

    func testFallbackKindsNamedByTheLadder() {
        let fallbacks: [AetherFailureKind] = [
            .sourceOpenFailed, .sourceRefused, .sourceCertificateRejected, .vodSourceFailed, .nativeItemFailed,
            .softwarePipelineFailed, .dolbyVisionRequiresHardware, .audioBridgeProducedNoOutput, .reloadFailed,
            .audioSessionFailed, .audioTrackSwitchFailed, .storageExhausted, .noPlayableTrackWithinBudget,
            .masterPlaylistRejected, .firstFrameTimeout, .unknown("anything"),
            // Unreachable in Phase 1 (live, HLS and custom readers route to mpv): the fallback row.
            .liveSourceUnavailable, .hlsFormatUnsupported, .hlsIngestFailed, .hlsPlaylistOnRawLivePath,
            .demuxedAudioLiveUnsupported, .liveReloadNeverReady, .customSourceProbeFailed,
        ]
        for kind in fallbacks { XCTAssertEqual(decide(kind), .fallbackToMpv, kind.token) }
    }

    // MARK: Interruption window

    func testInterruptionKindsRebuildInsideTheWindowOnlyAfterAFirstFrame() {
        for kind in interruptionKinds {
            XCTAssertEqual(decide(kind, since: 0), .rebuildOnce, kind.token)
            XCTAssertEqual(decide(kind, since: 3.5), .rebuildOnce, kind.token)
            XCTAssertEqual(decide(kind, started: false, since: 3.5), .fallbackToMpv,
                           "\(kind.token): before a first frame there is no session to rebuild from")
        }
    }

    func testWindowEdges() {
        XCTAssertEqual(decide(.nativeItemFailed, since: 10), .rebuildOnce, "10 s is inside")
        XCTAssertEqual(decide(.nativeItemFailed, since: 10.001), .fallbackToMpv)
        XCTAssertEqual(decide(.softwarePipelineFailed, since: 9.999), .rebuildOnce)
        XCTAssertEqual(decide(.softwarePipelineFailed, since: 60), .fallbackToMpv)
        XCTAssertEqual(decide(.nativeItemFailed, since: nil), .fallbackToMpv, "no interruption seen")
        XCTAssertEqual(decide(.nativeItemFailed, since: -0.5), .fallbackToMpv, "a clock that went backwards is not inside")
        XCTAssertEqual(decide(.nativeItemFailed, since: .nan), .fallbackToMpv)
        XCTAssertEqual(decide(.nativeItemFailed, since: .infinity), .fallbackToMpv)
    }

    func testOtherKindsIgnoreTheWindow() {
        for kind: AetherFailureKind in [.sourceOpenFailed, .dolbyVisionRequiresHardware, .reloadFailed, .firstFrameTimeout,
                                        .audioSessionFailed, .unknown("x")] {
            XCTAssertEqual(decide(kind, since: 1), .fallbackToMpv, kind.token)
        }
    }

    // MARK: Observing the audio session

    func testPolicyStampsInterruptionsAndRouteChangesOnAnInjectedClock() {
        var now: TimeInterval = 1_000
        let center = NotificationCenter()
        let policy = AetherFailurePolicy(clock: { now }, center: center)
        XCTAssertNil(policy.sinceInterruptionSec)
        XCTAssertEqual(policy.decide(failure(.nativeItemFailed), startedPlaying: true, secondsPlayed: 40), .fallbackToMpv)

        // A real route change (an HDMI sink going away) opens the window.
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        now += 4
        XCTAssertEqual(policy.sinceInterruptionSec ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(policy.decide(failure(.softwarePipelineFailed), startedPlaying: true, secondsPlayed: 40), .rebuildOnce)
        now += 6.5
        XCTAssertEqual(policy.decide(failure(.softwarePipelineFailed), startedPlaying: true, secondsPlayed: 40), .fallbackToMpv)

        // An interruption (began) re-opens it.
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        now += 1
        XCTAssertEqual(policy.decide(failure(.nativeItemFailed), startedPlaying: true, secondsPlayed: 40), .rebuildOnce)
    }

    func testACategoryChangeIsNotARouteChange() {
        var now: TimeInterval = 50
        let center = NotificationCenter()
        let policy = AetherFailurePolicy(clock: { now }, center: center)
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.categoryChange.rawValue])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        now += 1
        XCTAssertNil(policy.sinceInterruptionSec, "the app's own setCategory must not open the window")
        XCTAssertFalse(AetherFailurePolicy.countsAsRouteChange(reasonRaw: AVAudioSession.RouteChangeReason.categoryChange.rawValue))
        XCTAssertTrue(AetherFailurePolicy.countsAsRouteChange(reasonRaw: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue))
        XCTAssertTrue(AetherFailurePolicy.countsAsRouteChange(reasonRaw: AVAudioSession.RouteChangeReason.override.rawValue))
        XCTAssertTrue(AetherFailurePolicy.countsAsRouteChange(reasonRaw: nil), "no reason: count it, the safe side is a rebuild")
    }

    // MARK: The once rule, as the controller resolves the policy's answer

    func testRebuildIsOncePerPlayerWhateverTheWindowSays() {
        let policy = AetherFailurePolicy(clock: { 0 }, center: NotificationCenter())
        policy.noteEvent("test")   // the window is open for every decision below
        let first = policy.decide(failure(.nativeItemFailed), startedPlaying: true, secondsPlayed: 40)
        XCTAssertEqual(first, .rebuildOnce)
        XCTAssertEqual(AetherFailurePlan.resolve(first, alreadyRebuilt: false), .rebuildOnce)
        // The rebuilt load fails again inside the same window: the policy says rebuild, the controller says mpv.
        let second = policy.decide(failure(.softwarePipelineFailed), startedPlaying: true, secondsPlayed: 41)
        XCTAssertEqual(second, .rebuildOnce)
        XCTAssertEqual(AetherFailurePlan.resolve(second, alreadyRebuilt: true), .fallbackToMpv)
        // A rate limit stays terminal after a rebuild.
        XCTAssertEqual(AetherFailurePlan.resolve(policy.decide(failure(.sourceRateLimited), startedPlaying: true, secondsPlayed: 41),
                                                 alreadyRebuilt: true), .fail)
    }

    func testTerminalKindMatchesTheLadder() {
        XCTAssertEqual(AetherFailurePlan.failureKind(.sourceRateLimited), .network)
        for kind in interruptionKinds + [.sourceRefused, .firstFrameTimeout] {
            XCTAssertEqual(AetherFailurePlan.failureKind(kind), .local, kind.token)
        }
    }
}
