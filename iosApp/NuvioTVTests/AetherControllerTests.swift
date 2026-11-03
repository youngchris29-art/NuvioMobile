import CoreGraphics
import NuvioAether
import SharedCore
import XCTest
@testable import NuvioTV

/// Aether Phase 1, W3-A: the pure parts of `AetherTVPlayerViewController` (`AetherControllerRules.swift`
/// and the default failure decider), driven without an engine.
@MainActor
final class AetherControllerTests: XCTestCase {

    // MARK: Seek-mode mapping

    func testExactFlagFollowsMpvHrSeekDefault() {
        XCTAssertFalse(AetherSeekPlan.isExact(.relative(deltaSec: 10)))
        XCTAssertFalse(AetherSeekPlan.isExact(.absoluteKeyframes))
        XCTAssertTrue(AetherSeekPlan.isExact(.absolute))
        XCTAssertTrue(AetherSeekPlan.isExact(.absoluteExact))
    }

    func testRelativeTargetUsesGivenTargetElseInFlightElsePosition() {
        XCTAssertEqual(AetherSeekPlan.target(mode: .relative(deltaSec: 10), targetSec: 70, positionSec: 50,
                                             inFlightTargetSec: nil, durationSec: 600), 70)
        XCTAssertEqual(AetherSeekPlan.target(mode: .relative(deltaSec: 10), targetSec: nil, positionSec: 50,
                                             inFlightTargetSec: 200, durationSec: 600), 210)
        XCTAssertEqual(AetherSeekPlan.target(mode: .relative(deltaSec: -10), targetSec: nil, positionSec: 50,
                                             inFlightTargetSec: nil, durationSec: 600), 40)
    }

    func testAbsoluteTargetNeedsATargetAndIsClamped() {
        XCTAssertNil(AetherSeekPlan.target(mode: .absolute, targetSec: nil, positionSec: 5, inFlightTargetSec: nil, durationSec: 100))
        XCTAssertNil(AetherSeekPlan.target(mode: .absoluteExact, targetSec: .nan, positionSec: 5, inFlightTargetSec: nil, durationSec: 100))
        XCTAssertEqual(AetherSeekPlan.target(mode: .absoluteKeyframes, targetSec: 500, positionSec: 5,
                                             inFlightTargetSec: nil, durationSec: 100), 99.5)
        XCTAssertEqual(AetherSeekPlan.target(mode: .absolute, targetSec: -4, positionSec: 5,
                                             inFlightTargetSec: nil, durationSec: 100), 0)
        // Unknown duration: only the floor applies.
        XCTAssertEqual(AetherSeekPlan.clamp(5_000, durationSec: 0), 5_000)
    }

    func testOutcomeLanding() {
        XCTAssertEqual(AetherSeekPlan.landing(for: .landed(atSec: 41.2), targetSec: 40), .landed(atSec: 41.2))
        XCTAssertEqual(AetherSeekPlan.landing(for: .landed(atSec: .nan), targetSec: 40), .landed(atSec: 40))
        XCTAssertEqual(AetherSeekPlan.landing(for: .stalled, targetSec: 40), .landed(atSec: 40), "stalled counts as landed")
        XCTAssertEqual(AetherSeekPlan.landing(for: .unconfirmed, targetSec: 40), .landed(atSec: 40))
        XCTAssertEqual(AetherSeekPlan.landing(for: .superseded, targetSec: 40), .superseded)
        XCTAssertEqual(AetherSeekPlan.landing(for: .rejected(.ended), targetSec: 40), .rejected)
        XCTAssertEqual(AetherSeekPlan.landing(for: .rejected(.noActiveSession), targetSec: 40), .rejected)
    }

    // MARK: Stepped scan

    func testScanTwoXIsARateChangeOnly() {
        XCTAssertEqual(AetherScanPlan.engineRate(scanRate: 2, maxRate: 2), 2)
        XCTAssertFalse(AetherScanPlan.isStepped(scanRate: 2, maxRate: 2))
        XCTAssertNil(AetherScanPlan.stepTarget(positionSec: 100, scanRate: 2, maxRate: 2, durationSec: 1_000))
    }

    func testScanThreeAndFourXStepAtTheCap() {
        XCTAssertEqual(AetherScanPlan.engineRate(scanRate: 3, maxRate: 2), 2)
        XCTAssertEqual(AetherScanPlan.engineRate(scanRate: 4, maxRate: 2), 2)
        XCTAssertTrue(AetherScanPlan.isStepped(scanRate: 3, maxRate: 2))
        XCTAssertEqual(AetherScanPlan.stepTarget(positionSec: 100, scanRate: 3, maxRate: 2, durationSec: 1_000), 101)
        XCTAssertEqual(AetherScanPlan.stepTarget(positionSec: 100, scanRate: 4, maxRate: 2, durationSec: 1_000), 102)
        XCTAssertEqual(AetherScanPlan.stepTarget(positionSec: 100, scanRate: 4, maxRate: 2, intervalSec: 0.5,
                                                 durationSec: 1_000), 101)
        // An audio-only source (cap 3) plays 3x by itself.
        XCTAssertFalse(AetherScanPlan.isStepped(scanRate: 3, maxRate: 3))
    }

    func testScanStepStopsAtTheEndGuard() {
        XCTAssertNil(AetherScanPlan.stepTarget(positionSec: 996, scanRate: 4, maxRate: 2, durationSec: 1_000))
        XCTAssertNotNil(AetherScanPlan.stepTarget(positionSec: 990, scanRate: 4, maxRate: 2, durationSec: 1_000))
        XCTAssertNotNil(AetherScanPlan.stepTarget(positionSec: 990, scanRate: 4, maxRate: 2, durationSec: 0),
                        "unknown duration never blocks")
    }

    func testScanTreatsAMissingCapAsTwo() {
        XCTAssertEqual(AetherScanPlan.engineRate(scanRate: 4, maxRate: 0), 2)
        XCTAssertEqual(AetherScanPlan.engineRate(scanRate: 4, maxRate: .nan), 2)
        XCTAssertTrue(AetherScanPlan.isStepped(scanRate: 3, maxRate: 0))
    }

    // MARK: Rate clamp, audio delay, shaping

    func testSpeedClampsToTheEngineCap() {
        XCTAssertEqual(AetherRatePlan.clampedSpeed(1.5, maxRate: 2), 1.5)
        XCTAssertEqual(AetherRatePlan.clampedSpeed(3, maxRate: 2), 2)
        XCTAssertEqual(AetherRatePlan.clampedSpeed(0.1, maxRate: 2), 0.25)
        XCTAssertEqual(AetherRatePlan.clampedSpeed(.nan, maxRate: 2), 1)
        XCTAssertEqual(AetherRatePlan.clampedSpeed(-1, maxRate: 2), 1)
        for speed in PlayerPlaybackColumns.speeds {
            XCTAssertEqual(AetherRatePlan.clampedSpeed(speed, maxRate: 2), speed, "panel speed \(speed) plays as chosen")
        }
    }

    func testAudioDelayStaysInsideTheEngineLimit() {
        XCTAssertEqual(AetherAudioDelayPlan.clamped(1.25), 1.25)
        XCTAssertEqual(AetherAudioDelayPlan.clamped(4), 2)
        XCTAssertEqual(AetherAudioDelayPlan.clamped(-30), -2)
        XCTAssertEqual(AetherAudioDelayPlan.clamped(.infinity), 0)
        XCTAssertEqual(AetherAudioDelayPlan.uiLimitSec(sharedLimitSec: 10), 2)
        XCTAssertEqual(AetherAudioDelayPlan.uiLimitSec(sharedLimitSec: 60), 2)
        XCTAssertEqual(AetherAudioDelayPlan.uiLimitSec(sharedLimitSec: 1), 1)
    }

    func testShapingFromBoostAndDialogue() {
        XCTAssertEqual(AetherShapingPlan.shaping(boostDb: 0, mode: .off), AetherAudioShaping())
        XCTAssertFalse(AetherShapingPlan.shaping(boostDb: 0, mode: .off).isActive, "off keeps stream copy")
        XCTAssertEqual(AetherShapingPlan.shaping(boostDb: 6, mode: .dialogue),
                       AetherAudioShaping(dialogueLiftDB: 3.5, boostDB: 6))
        XCTAssertEqual(AetherShapingPlan.shaping(boostDb: 7, mode: .off).boostDB, 6, "snapped like mpv's steps")
    }

    // MARK: Start watchdog

    func testWatchdogActions() {
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: .waiting, firstFrameShown: false), .wait)
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: .fired(elapsed: 25), firstFrameShown: false), .reportTimeout)
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: .fired(elapsed: 25), firstFrameShown: true), .standDown,
                       "a frame that arrived on the last tick wins")
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: .inactive, firstFrameShown: false), .standDown)
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: .waiting, firstFrameShown: true), .standDown)
    }

    func testWatchdogBudgetIsMpvs() {
        var dog = MPVStartWatchdog(limitSeconds: MPVStartWatchdog.limitSeconds(shortened: false))
        dog.noteLoadStarted(at: 100)
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: dog.poll(now: 124), firstFrameShown: false), .wait)
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: dog.poll(now: 125), firstFrameShown: false), .reportTimeout)
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: dog.poll(now: 126), firstFrameShown: false), .standDown,
                       "fires once")
        XCTAssertEqual(MPVStartWatchdog.limitSeconds(shortened: true), 15)
    }

    // MARK: Default decider and failure plan

    private func failure(_ kind: AetherFailureKind) -> AetherFailure {
        AetherFailure(kind: kind, message: "x", atSec: 12, beforeFirstFrame: false)
    }

    func testDefaultDeciderRebuildsOnceOnInterruptionKindsMidPlay() {
        let d = AetherDefaultFailureDecider()
        XCTAssertEqual(d.decide(failure(.nativeItemFailed), startedPlaying: true, secondsPlayed: 40), .rebuildOnce)
        XCTAssertEqual(d.decide(failure(.softwarePipelineFailed), startedPlaying: true, secondsPlayed: 40), .rebuildOnce)
        XCTAssertEqual(d.decide(failure(.nativeItemFailed), startedPlaying: false, secondsPlayed: 0), .fallbackToMpv,
                       "before start there is no interruption to rebuild from")
    }

    func testDefaultDeciderRateLimitIsTerminalTheRestFallsBack() {
        let d = AetherDefaultFailureDecider()
        XCTAssertEqual(d.decide(failure(.sourceRateLimited), startedPlaying: true, secondsPlayed: 40), .fail)
        for kind: AetherFailureKind in [.sourceOpenFailed, .sourceRefused, .vodSourceFailed, .dolbyVisionRequiresHardware,
                                        .audioBridgeProducedNoOutput, .firstFrameTimeout, .reloadFailed, .storageExhausted,
                                        .unknown("future")] {
            XCTAssertEqual(d.decide(failure(kind), startedPlaying: true, secondsPlayed: 40), .fallbackToMpv, kind.token)
            XCTAssertEqual(d.decide(failure(kind), startedPlaying: false, secondsPlayed: 0), .fallbackToMpv, kind.token)
        }
    }

    func testRebuildHappensOncePerPlayer() {
        XCTAssertEqual(AetherFailurePlan.resolve(.rebuildOnce, alreadyRebuilt: false), .rebuildOnce)
        XCTAssertEqual(AetherFailurePlan.resolve(.rebuildOnce, alreadyRebuilt: true), .fallbackToMpv)
        XCTAssertEqual(AetherFailurePlan.resolve(.fail, alreadyRebuilt: true), .fail)
        XCTAssertEqual(AetherFailurePlan.resolve(.fallbackToMpv, alreadyRebuilt: false), .fallbackToMpv)
    }

    func testRateLimitAndOfflineNeverOfferAnMpvRetry() {
        // Review r3: the terminal rate limit reaches the alert as `.network`; mpv would hit the same meter.
        XCTAssertFalse(AetherFailurePlan.offersMpvRetry(AetherFailurePlan.failureKind(.sourceRateLimited)))
        XCTAssertFalse(AetherFailurePlan.offersMpvRetry(.offline))
        XCTAssertTrue(AetherFailurePlan.offersMpvRetry(AetherFailurePlan.failureKind(.sourceOpenFailed)))
        XCTAssertTrue(AetherFailurePlan.offersMpvRetry(.endedEarly))
    }

    func testNormalEndReportsTheDurationOnlyNearTheEnd() {
        // Review r4: a manual healthy source that ran dry at 30 min of 2 h is not marked watched.
        XCTAssertEqual(AetherFailurePlan.endPosition(positionSec: 1_800, durationSec: 7_200), 1_800)
        XCTAssertEqual(AetherFailurePlan.endPosition(positionSec: 7_195, durationSec: 7_200), 7_200)
        XCTAssertEqual(AetherFailurePlan.endPosition(positionSec: 7_140, durationSec: 7_200), 7_200, "inside the 60 s slack")
        XCTAssertEqual(AetherFailurePlan.endPosition(positionSec: 7_139, durationSec: 7_200), 7_139)
        XCTAssertEqual(AetherFailurePlan.endPosition(positionSec: 42, durationSec: 0), 42, "unknown duration")
        XCTAssertEqual(AetherFailurePlan.endPosition(positionSec: .nan, durationSec: 7_200), 0)
    }

    func testTerminalKindsAndHandoffPosition() {
        XCTAssertEqual(AetherFailurePlan.failureKind(.sourceRateLimited), .network)
        XCTAssertEqual(AetherFailurePlan.failureKind(.sourceRefused), .local)
        XCTAssertFalse(AetherFailurePlan.failureKind(.sourceOpenFailed).remembersLink)
        XCTAssertEqual(AetherFailurePlan.handoffPosition(123.4), 123.4)
        XCTAssertEqual(AetherFailurePlan.handoffPosition(-1), 0)
        XCTAssertEqual(AetherFailurePlan.handoffPosition(.nan), 0)
    }

    // MARK: Subtitle start plan moments (review r1 F1, r4, r5, r6 F3)

    func testLoadReturnRunWaitsOnlyWhileTheKickedFetchIsOut() {
        let key = "movie|tt1"
        XCTAssertFalse(AetherSubtitleStartGate.addonFetchPending(completedRequest: key, requestKey: key),
                       "a completed (deduplicated) fetch never arrives: decide now, Off included")
        XCTAssertTrue(AetherSubtitleStartGate.addonFetchPending(completedRequest: nil, requestKey: key))
        XCTAssertTrue(AetherSubtitleStartGate.addonFetchPending(completedRequest: "series|tt2:1:1", requestKey: key))
    }

    func testCompletionAloneDecidesEvenWithAConflatedLoadingEdge() {
        // r4/r5: no prefetch, a fetch that completes at once (empty, or only URLs already declared):
        // completion alone wakes the plan and nothing is still arriving, so Off can land.
        let key = "movie|tt1"
        XCTAssertEqual(AetherSubtitleStartGate.completion(completedRequest: key, requestKey: key, outstanding: true), .ours)
        XCTAssertFalse(AetherSubtitleStartGate.isArriving(searchInFlight: true, fetchCompleted: true, fetchOutstanding: false),
                       "a stale in-flight reading after completion")
        XCTAssertTrue(AetherSubtitleStartGate.isArriving(searchInFlight: false, fetchCompleted: false, fetchOutstanding: true),
                       "a stale idle reading before completion")
        XCTAssertEqual(AetherSubtitleStartGate.completion(completedRequest: nil, requestKey: key, outstanding: true), .none)
        XCTAssertEqual(AetherSubtitleStartGate.completion(completedRequest: "series|tt2:1:2", requestKey: key, outstanding: true),
                       .superseded, "the Up Next prefetch replaced ours: decide rather than wait forever")
        XCTAssertEqual(AetherSubtitleStartGate.completion(completedRequest: "series|tt2:1:2", requestKey: key, outstanding: false),
                       .none)
    }

    func testThePlanRunsOnTheWholeRegisteredBatchNotAPartialPublish() {
        // r6 F3: completion registers three add-on files; the queued publishes would carry them one at a
        // time. The plan's list right after registration already holds all of them.
        let embedded = AetherTrack(id: 3, name: "Japanese", codec: "subrip", language: "jpn")
        let esES = AetherTrack(id: AetherTrack.externalTrackIDBase, name: "Spanish", codec: "subrip", language: "es", isExternal: true)
        let es419 = AetherTrack(id: AetherTrack.externalTrackIDBase + 1, name: "Spanish (Latin America)", codec: "subrip",
                                language: "es-419", isExternal: true)
        let en = AetherTrack(id: AetherTrack.externalTrackIDBase + 2, name: "English", codec: "subrip", language: "en", isExternal: true)
        let partial = [embedded, esES]   // the first publish after the first registration
        let list = AetherSubtitleStartGate.planTracks(published: partial, registered: [esES, es419, en])
        XCTAssertEqual(list.map(\.id), [3, AetherTrack.externalTrackIDBase, AetherTrack.externalTrackIDBase + 1,
                                         AetherTrack.externalTrackIDBase + 2])
        XCTAssertEqual(AetherSubtitleStartGate.planTracks(published: list, registered: [en]).count, 4, "no duplicates")
    }

    func testForcedPolicyStartsTheEngineWithNoSubtitle() {
        // r6 F5: with "Use forced subtitles" on, the engine never picks the full English track on its own
        // while the host waits for add-ons; the host's audio-aware plan makes the only selection.
        XCTAssertEqual(AetherSubtitleStartGate.initialSubtitle(targets: ["eng"], useForcedSubtitles: true), .off)
        XCTAssertEqual(AetherSubtitleStartGate.initialSubtitle(targets: ["eng"], useForcedSubtitles: false),
                       .preferLanguages(["eng"]))
        XCTAssertEqual(AetherSubtitleStartGate.initialSubtitle(targets: [], useForcedSubtitles: false), .off)
    }

    func testAnOffDecisionAlwaysReachesTheEngine() {
        // r7: Off decided with nothing active (no English track, empty add-on fetch). The clear is what
        // stops a late next-episode add-on file from being switched on by the engine's own pick.
        XCTAssertEqual(AetherSubtitleStartGate.command(for: .off, activeSubtitleID: nil), .clear)
        XCTAssertEqual(AetherSubtitleStartGate.command(for: .off, activeSubtitleID: 3), .clear)
        XCTAssertEqual(AetherSubtitleStartGate.command(for: .select(id: 3), activeSubtitleID: nil), .select(id: 3))
        XCTAssertEqual(AetherSubtitleStartGate.command(for: .select(id: 3), activeSubtitleID: 4), .select(id: 3))
        XCTAssertEqual(AetherSubtitleStartGate.command(for: .select(id: 3), activeSubtitleID: 3), .none,
                       "an active track already blocks the engine's re-run")
    }

    // MARK: Fresh load keeps the live tracks (review r1 F3)

    private func startRequest() -> AetherLoadRequest {
        AetherLoadRequest(url: URL(string: "https://example.com/film.mkv")!, startSec: 600,
                          preferredAudioLanguages: ["eng"], initialSubtitle: .preferLanguages(["eng"]),
                          externalSubtitles: [AetherExternalSubtitle(url: URL(string: "https://example.com/a.vtt")!)])
    }

    func testRebuildAfterManualDubAndSubtitlesOffKeepsBoth() {
        let r = AetherReloadRequestPlan.request(from: startRequest(), startSec: 1234, activeAudioID: 2,
                                                activeSubtitleID: nil, subtitleDecided: true, addedSubtitles: [])
        XCTAssertEqual(r.startSec, 1234)
        XCTAssertEqual(r.audioStreamIndex, 2, "the dub picked mid-play, which wins over the language targets")
        XCTAssertEqual(r.initialSubtitle, .off, "the viewer's Off, not the start preference")
        XCTAssertNotEqual(r, startRequest().starting(atSec: 1234), "the old rebuild request dropped both picks")
    }

    func testReplayKeepsTheLiveSubtitleTrackAndReDeclaresAddonFiles() {
        let addon = AetherExternalSubtitle(url: URL(string: "https://subs.example.com/b.srt")!, language: "eng")
        let r = AetherReloadRequestPlan.request(from: startRequest(), startSec: 0, activeAudioID: 1,
                                                activeSubtitleID: AetherTrack.externalTrackIDBase + 1,
                                                subtitleDecided: true, addedSubtitles: [addon])
        XCTAssertEqual(r.startSec, 0)
        XCTAssertEqual(r.initialSubtitle, .track(id: AetherTrack.externalTrackIDBase + 1))
        XCTAssertEqual(r.externalSubtitles.map(\.url.lastPathComponent), ["a.vtt", "b.srt"],
                       "the add-on file keeps ordinal 1")
        let again = AetherReloadRequestPlan.request(from: r, startSec: 0, activeAudioID: 1, activeSubtitleID: nil,
                                                    subtitleDecided: true, addedSubtitles: [addon])
        XCTAssertEqual(again.externalSubtitles.count, 2, "a second fresh load never declares a file twice")
    }

    func testUndecidedSubtitleKeepsTheStartPreference() {
        let r = AetherReloadRequestPlan.request(from: startRequest(), startSec: nil, activeAudioID: nil,
                                                activeSubtitleID: nil, subtitleDecided: false, addedSubtitles: [])
        XCTAssertEqual(r.initialSubtitle, .preferLanguages(["eng"]), "the start plan still runs on the fresh load")
        XCTAssertNil(r.audioStreamIndex)
        XCTAssertNil(r.startSec)
    }

    // MARK: Per-viewing failover facts (review r6 F1)

    func testReplayIsJudgedOnItsOwnSecondsNotTheFirstViewings() {
        var v = AetherViewingState()
        v.firstFrameChanged(true)
        var now: TimeInterval = 0
        for _ in 0..<1_000 { now += 3; v.note(playing: true, at: now) }   // ~50 min of a first viewing
        XCTAssertGreaterThan(v.secondsPlayed(beforeFallback: 0), 2_900)
        XCTAssertFalse(PlaybackEndPolicy.isEarlyEndFailure(position: 600, duration: 7_200,
                                                           secondsPlayed: v.secondsPlayed(beforeFallback: 0),
                                                           launchSource: .manual),
                       "the old carried seconds hid a replay's early end")

        v.replayStarting()
        XCTAssertFalse(v.everShowedFrame, "a pre-frame replay failure is reported as not started")
        XCTAssertFalse(v.firstFrameShown)
        XCTAssertEqual(v.secondsPlayed(beforeFallback: 0), 0)
        v.firstFrameChanged(true)
        for _ in 0..<20 { now += 3; v.note(playing: true, at: now) }       // one minute into the replay
        XCTAssertTrue(PlaybackEndPolicy.isEarlyEndFailure(position: 600, duration: 7_200,
                                                          secondsPlayed: v.secondsPlayed(beforeFallback: 0),
                                                          launchSource: .manual),
                      "the replay's own minute: an early end is a failure")
    }

    func testAFreshLoadsWatchdogNeverStandsDownOnThePreviousLoadsFrame() {
        // Review r6 F2: rebuild after a route interruption; `session.load` still awaits the audio session
        // when the new watchdog's first tick runs.
        var v = AetherViewingState()
        v.firstFrameChanged(true)
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: .waiting, firstFrameShown: v.firstFrameShown), .standDown,
                       "what the old mirror told the new watchdog")
        v.loadStarting()
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: .waiting, firstFrameShown: v.firstFrameShown), .wait)
        XCTAssertEqual(AetherStartWatchdogRule.action(verdict: .fired(elapsed: 30), firstFrameShown: v.firstFrameShown), .reportTimeout,
                       "a load that never shows a frame times out")
        XCTAssertTrue(v.everShowedFrame, "a rebuild mid-viewing keeps the viewing's latch")
    }

    // MARK: Add-on forced subtitles (review r6 F4)

    func testAForcedAddonFileIsForcedAndStaysForcedAcrossAFreshLoad() {
        let forced = AddonSubtitle(id: "opensubtitles-forced-123", url: "https://subs.example.com/en.srt", language: "eng",
                                   display: "English (OpenSubtitles)", addonName: "OpenSubtitles", isSelected: false)
        let byURL = AddonSubtitle(id: "os-456", url: "https://subs.example.com/en.forced.srt", language: "eng",
                                  display: "English", addonName: nil, isSelected: false)
        let normal = AddonSubtitle(id: "os-789", url: "https://subs.example.com/en.full.srt", language: "eng",
                                   display: "English", addonName: nil, isSelected: false)
        XCTAssertEqual(AetherAddonSubtitlePlan.external(forced, credentialed: false)?.isForced, true, "by add-on id")
        XCTAssertEqual(AetherAddonSubtitlePlan.external(byURL, credentialed: false)?.isForced, true, "by URL")
        XCTAssertEqual(AetherAddonSubtitlePlan.external(normal, credentialed: false)?.isForced, false)
        XCTAssertEqual(AetherAddonSubtitlePlan.external(normal, credentialed: true)?.httpHeaders, [:])
        XCTAssertNil(AetherAddonSubtitlePlan.external(normal, credentialed: false)?.httpHeaders)

        let added = [AetherAddonSubtitlePlan.external(forced, credentialed: false)!]
        let r = AetherReloadRequestPlan.request(from: startRequest(), startSec: 10, activeAudioID: nil,
                                                activeSubtitleID: nil, subtitleDecided: false, addedSubtitles: added)
        XCTAssertEqual(r.externalSubtitles.last?.isForced, true, "re-declared forced on the rebuild / Replay load")
    }

    // MARK: Audio tab Atmos note (W3-C)

    func testAtmosNoteShowsOnlyOnAetherWithBoostOrDialogue() {
        let off = PlayerAudioEffectsState(boostDb: 0, mode: .off)
        XCTAssertFalse(PlayerAudioAtmosNote.isShown(endsAtmos: true, effects: off))
        XCTAssertTrue(PlayerAudioAtmosNote.isShown(endsAtmos: true, effects: PlayerAudioEffectsState(boostDb: 2, mode: .off)))
        XCTAssertTrue(PlayerAudioAtmosNote.isShown(endsAtmos: true, effects: PlayerAudioEffectsState(boostDb: 0, mode: .dialogue)))
        XCTAssertTrue(PlayerAudioAtmosNote.isShown(endsAtmos: true, effects: PlayerAudioEffectsState(boostDb: 6, mode: .dialogue)))
        XCTAssertFalse(PlayerAudioAtmosNote.isShown(endsAtmos: false, effects: PlayerAudioEffectsState(boostDb: 6, mode: .dialogue)),
                       "mpv keeps its passthrough rules: no note")
    }

    // MARK: Diagnostics → info rows

    private func diagnostics() -> AetherDiagnostics {
        AetherDiagnostics(route: .software, sourceFormat: .dolbyVision, outputFormat: .hdr10, sourceDVProfile: 7,
                          dvConvertedP7ToP81: true, videoCodec: "hevc", container: "matroska",
                          frameRate: 23.976, videoBitrate: 18_500_000, videoDecoder: "VideoToolbox HEVC",
                          audioDecoder: "libavcodec TrueHD", audioDelivery: .bridged, audioShaping: .applied,
                          softwareEscalations: 1, presentationSize: CGSize(width: 3840, height: 2160))
    }

    func testEngineRowNamesRouteDeliveryAndDVPath() {
        let label = AetherStreamInfo.engineLabel(routingNote: "", diagnostics: diagnostics(), subtitleDelaySec: 0)
        XCTAssertTrue(label.hasPrefix("Aether"), label)
        XCTAssertTrue(label.contains("software"), label)
        XCTAssertTrue(label.contains("audio bridged"), label)
        XCTAssertTrue(label.contains("DV P7\u{2192}8.1"), label)
        XCTAssertTrue(label.contains("escalations 1"), label)
        XCTAssertFalse(label.contains("subs"), label)
        let noted = AetherStreamInfo.engineLabel(routingNote: "Aether \u{00B7} DV P8.1", diagnostics: AetherDiagnostics(),
                                                 subtitleDelaySec: 1.5)
        XCTAssertEqual(noted, "Aether \u{00B7} DV P8.1 \u{00B7} subs +1.50 s")
    }

    func testSnapshotRows() {
        let atmos = AetherTrack(id: 1, name: "English", codec: "truehd", language: "eng", channels: 8, isAtmos: true)
        let info = AetherStreamInfo.snapshot(diagnostics: diagnostics(), routingNote: "", activeAudio: atmos,
                                             bufferedAheadSec: 12.4, subtitleDelaySec: 0)
        XCTAssertEqual(info.videoCodec, "hevc \u{00B7} DV P7 \u{2192} HDR10 \u{00B7} matroska")
        XCTAssertEqual(info.resolution, "3840\u{00D7}2160")
        XCTAssertEqual(info.fps, "23.976 fps")
        XCTAssertEqual(info.hwdec, "VideoToolbox HEVC")
        XCTAssertEqual(info.videoBitrate, "19 Mbps")
        XCTAssertEqual(info.audio, "truehd \u{00B7} 8ch \u{00B7} Atmos \u{00B7} libavcodec TrueHD \u{00B7} bridged \u{00B7} shaped")
        XCTAssertEqual(info.cache, "12s buffered")
        XCTAssertEqual(info.rows.first?.1, info.engine, "Engine is the first row")
    }

    func testSnapshotOmitsUnknowns() {
        let info = AetherStreamInfo.snapshot(diagnostics: AetherDiagnostics(), routingNote: "", activeAudio: nil,
                                             bufferedAheadSec: 0.2, subtitleDelaySec: 0)
        XCTAssertEqual(info.engine, "Aether")
        XCTAssertEqual(info.videoCodec, "SDR")
        XCTAssertEqual(info.resolution, "")
        XCTAssertEqual(info.cache, "")
        XCTAssertEqual(info.audio, "")
        XCTAssertEqual(info.rows.map(\.0).count, 2, "Engine and Video only")
    }

    // MARK: Tracks and chapters

    func testTrackRowsUseTheMpvShapes() {
        let a = AetherTrack(id: 2, name: "Commentary", codec: "aac", language: "eng")
        let b = AetherTrack(id: 3, name: "", codec: "", language: nil)
        XCTAssertEqual(AetherTrackRows.label(a), "eng \u{00B7} Commentary (aac)")
        XCTAssertEqual(AetherTrackRows.audio([a, b], activeID: 3).map(\.isSelected), [false, true])
        XCTAssertEqual(AetherTrackRows.subtitles([], activeID: nil), [], "no Off row without tracks")
        let subs = AetherTrackRows.subtitles([a], activeID: nil)
        XCTAssertEqual(subs.map(\.id), [-1, 2])
        XCTAssertEqual(subs.map(\.isSelected), [true, false])
        XCTAssertEqual(AetherTrackRows.subtitles([a], activeID: 2).map(\.isSelected), [false, true])
    }

    func testChaptersSortedAndEndMarkerTrimmed() {
        let list = [AetherChapter(id: 1, title: "Two", startSec: 300, durationSec: 300),
                    AetherChapter(id: 0, title: "One", startSec: 0, durationSec: 300),
                    AetherChapter(id: 2, title: "End", startSec: 600, durationSec: 0)]
        let mapped = AetherChapterMapping.transportChapters(list, durationSec: 600)
        XCTAssertEqual(mapped.raw.map(\.title), ["One", "Two", "End"])
        XCTAssertEqual(mapped.published, PlayerChapters.trimmed(mapped.raw, durationSec: 600))
        XCTAssertFalse(mapped.published.contains { $0.title == "End" }, "a marker at the end is never a seek target")
    }
}
