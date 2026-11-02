import CoreGraphics
import XCTest
import NuvioAether

/// NuvioAether's pure logic (failure mapping, load ledger, seek resolver, phase reducer, cue flattening,
/// clock mirroring) through its public API, run by the NuvioTVTests scheme. The package's own test target
/// (`iosApp/NuvioAether/Tests`, run with the package as root) holds the FakeEngine session tests.
final class AetherFacadePureLogicTests: XCTestCase {

    // MARK: Failure kinds

    func testAllTwentyTwoEngineTokensMapToTheirOwnKind() {
        let expected: [AetherFailureKind] = [
            .sourceOpenFailed, .sourceRefused, .sourceCertificateRejected, .customSourceProbeFailed,
            .hlsFormatUnsupported, .hlsIngestFailed, .liveSourceUnavailable, .hlsPlaylistOnRawLivePath,
            .dolbyVisionRequiresHardware, .demuxedAudioLiveUnsupported, .nativeItemFailed,
            .noPlayableTrackWithinBudget, .masterPlaylistRejected, .vodSourceFailed, .sourceRateLimited,
            .softwarePipelineFailed, .audioSessionFailed, .reloadFailed, .liveReloadNeverReady,
            .audioTrackSwitchFailed, .audioBridgeProducedNoOutput, .storageExhausted,
        ]
        XCTAssertEqual(AetherFailureKind.engineTokens.count, 22)
        XCTAssertEqual(Set(AetherFailureKind.engineTokens).count, 22, "tokens are distinct")
        XCTAssertEqual(AetherFailureKind.engineTokens.map(AetherFailureKind.init(token:)), expected)
        for kind in expected {
            if case .unknown = kind { XCTFail("\(kind) mapped to unknown") }
            XCTAssertEqual(AetherFailureKind(token: kind.token), kind, "round trip \(kind.token)")
        }
    }

    func testUnknownAndFacadeTokensRoundTrip() {
        XCTAssertEqual(AetherFailureKind(token: "firstFrameTimeout"), .firstFrameTimeout)
        XCTAssertEqual(AetherFailureKind(token: "aFutureKind"), .unknown("aFutureKind"))
        XCTAssertEqual(AetherFailureKind.unknown("aFutureKind").token, "aFutureKind")
        XCTAssertEqual(AetherFailureKind(token: ""), .unknown(""))
    }

    func testHTTPStatusOnlyForRefusedAndRateLimited() {
        for token in AetherFailureKind.engineTokens {
            let f = AetherFailure.fromEngine(token: token, domain: "d", code: 403, ffmpegCode: -5, message: "x",
                                             atSec: 12, beforeFirstFrame: false)
            let carries = token == "sourceRefused" || token == "sourceRateLimited"
            XCTAssertEqual(f.httpStatus, carries ? 403 : nil, token)
            XCTAssertEqual(f.code, 403)
            XCTAssertEqual(f.domain, "d")
            XCTAssertEqual(f.ffmpegCode, -5)
            XCTAssertEqual(f.atSec, 12)
            XCTAssertFalse(f.beforeFirstFrame)
        }
    }

    func testThrownErrorWithoutInfoIsUnknownThrown() {
        struct ProbeError: Error {}
        let f = AetherFailure.thrown(ProbeError(), atSec: 0, beforeFirstFrame: true)
        XCTAssertEqual(f.kind, .unknown("thrown:ProbeError"))
        XCTAssertNil(f.httpStatus)
    }

    // MARK: Ledger

    private func failure(_ kind: AetherFailureKind) -> AetherFailure {
        AetherFailure(kind: kind, message: "m", atSec: 0, beforeFirstFrame: true)
    }

    func testLedgerEmitsOneFailurePerGeneration() {
        var ledger = AetherLoadLedger()
        let g = ledger.begin()
        XCTAssertEqual(ledger.report(failure(.vodSourceFailed), generation: g), failure(.vodSourceFailed))
        XCTAssertNil(ledger.report(failure(.vodSourceFailed), generation: g), "the throw after errorInfo is the same failure")
        XCTAssertNil(ledger.report(failure(.unknown("thrown:X")), generation: g))
        XCTAssertEqual(ledger.reportedFailure?.kind, .vodSourceFailed)
    }

    func testLedgerDropsStaleGenerations() {
        var ledger = AetherLoadLedger()
        let first = ledger.begin()
        let second = ledger.begin()
        XCTAssertNil(ledger.report(failure(.nativeItemFailed), generation: first))
        XCTAssertNotNil(ledger.report(failure(.nativeItemFailed), generation: second))
        ledger.end()
        XCTAssertFalse(ledger.isCurrent(second))
        XCTAssertNil(ledger.report(failure(.nativeItemFailed), generation: second), "late event after stop()")
        XCTAssertNil(ledger.reportedFailure)
        let third = ledger.begin()
        XCTAssertNotNil(ledger.report(failure(.nativeItemFailed), generation: third), "new load reports again")
    }

    // MARK: Phase reducer

    func testPhaseMapping() {
        XCTAssertEqual(AetherPhaseReducer.reduce(.loading, engine: .playing), .playing)
        XCTAssertEqual(AetherPhaseReducer.reduce(.playing, engine: .paused), .paused)
        XCTAssertEqual(AetherPhaseReducer.reduce(.playing, engine: .seeking), .buffering(.seeking))
        XCTAssertEqual(AetherPhaseReducer.reduce(.playing, engine: .rebuffering), .buffering(.rebuffering))
        XCTAssertEqual(AetherPhaseReducer.reduce(.playing, engine: .stalled(reconnecting: true)),
                       .buffering(.stalled(reconnecting: true)))
        XCTAssertEqual(AetherPhaseReducer.reduce(.idle, engine: .loading), .loading)
        XCTAssertEqual(AetherPhaseReducer.reduce(.playing, engine: .idle), .idle)
        XCTAssertEqual(AetherPhaseReducer.reduce(.playing, engine: .error("x")), .playing,
                       "an engine error waits for the ledger")
    }

    func testEndedIsTerminal() {
        let ended = AetherPhaseReducer.reduce(.playing, engine: .ended)
        XCTAssertEqual(ended, .ended)
        for p in [AetherEnginePhase.playing, .paused, .seeking, .loading, .idle, .rebuffering, .error("x")] {
            XCTAssertEqual(AetherPhaseReducer.reduce(ended, engine: p), .ended, "\(p)")
        }
        let failed = AetherPhase.failed(failure(.vodSourceFailed))
        XCTAssertEqual(AetherPhaseReducer.reduce(failed, engine: .playing), failed)
        XCTAssertTrue(AetherPhase.ended.isTerminal)
        XCTAssertFalse(AetherPhase.paused.isTerminal)
    }

    // MARK: Seek resolver

    private func event(_ id: UInt64, _ origin: AetherSeekEventSample.Origin = .programmatic, target: Double,
                       _ outcome: AetherSeekEventSample.Outcome) -> AetherSeekEventSample {
        AetherSeekEventSample(id: id, origin: origin, target: target, outcome: outcome)
    }

    func testSeekLandsOnTheMatchingTerminalEvent() {
        var r = AetherSeekResolver(requestedSec: 120, afterID: 7)
        XCTAssertNil(r.consume(event(5, target: 120, .landed(renderedSec: 1))), "older than the call")
        XCTAssertNil(r.consume(event(8, .nativeScrub, target: 120, .landed(renderedSec: 2))), "AVKit's own scrub")
        XCTAssertNil(r.consume(event(9, target: 300, .began)), "another target")
        XCTAssertNil(r.consume(event(10, target: 120, .began)))
        XCTAssertEqual(r.latchedID, 10)
        XCTAssertNil(r.consume(event(9, target: 300, .landed(renderedSec: 300))), "the other seek's landing")
        XCTAssertEqual(r.consume(event(10, target: 120, .landed(renderedSec: 119.96))), .landed(atSec: 119.96))
        XCTAssertNil(r.consume(event(10, target: 120, .landed(renderedSec: 121))), "resolves once")
        XCTAssertEqual(r.outcome, .landed(atSec: 119.96))
    }

    func testSeekTerminalOutcomes() {
        var stalled = AetherSeekResolver(requestedSec: 10, afterID: 0)
        XCTAssertEqual(stalled.consume(event(1, target: 10, .stalled)), .stalled)
        var superseded = AetherSeekResolver(requestedSec: 10, afterID: 0)
        XCTAssertEqual(superseded.consume(event(1, target: 10.0005, .superseded)), .superseded)
        var rejected = AetherSeekResolver(requestedSec: 10, afterID: 0)
        XCTAssertEqual(rejected.consume(event(1, target: 10, .rejected(.sourceNotSeekable))), .rejected(.sourceNotSeekable))
        var deferred = AetherSeekResolver(requestedSec: 10, afterID: 0)
        XCTAssertEqual(deferred.consume(event(1, .deferred, target: 10, .landed(renderedSec: 10))), .landed(atSec: 10))
    }

    func testDeferredSeekMatchesTheClampedTarget() {
        var r = AetherSeekResolver(requestedSec: 9_000, afterID: 3, durationSec: 5_400)
        XCTAssertNil(r.consume(event(4, .deferred, target: 5_400, .began)))
        XCTAssertEqual(r.consume(event(4, .deferred, target: 5_400, .landed(renderedSec: 5_399.5))), .landed(atSec: 5_399.5))
        var negative = AetherSeekResolver(requestedSec: -4, afterID: 0, durationSec: 100)
        XCTAssertEqual(negative.consume(event(1, .deferred, target: 0, .landed(renderedSec: 0))), .landed(atSec: 0))
    }

    func testDeferredSeekReplayedAsProgrammaticIsFollowed() {
        // While loading, the engine stashes the seek under a deferred ticket, then closes it `.superseded`
        // and replays it under a new programmatic ticket.
        var r = AetherSeekResolver(requestedSec: 300, afterID: 2, durationSec: 0)
        XCTAssertNil(r.consume(event(3, .deferred, target: 300, .began)))
        XCTAssertNil(r.consume(event(3, .deferred, target: 300, .superseded)), "not the end of this seek")
        XCTAssertNil(r.latchedID)
        XCTAssertNil(r.consume(event(4, target: 300, .began)))
        XCTAssertEqual(r.latchedID, 4)
        XCTAssertEqual(r.consume(event(4, target: 300, .landed(renderedSec: 300.02))), .landed(atSec: 300.02))
        var replaced = AetherSeekResolver(requestedSec: 100, afterID: 0)
        XCTAssertNil(replaced.consume(event(1, .deferred, target: 100, .began)))
        XCTAssertNil(replaced.consume(event(1, .deferred, target: 100, .superseded)))
        XCTAssertEqual(replaced.consume(event(2, .deferred, target: 200, .began)), .superseded,
                       "a second stashed seek replaced this one")
        var forwardOnly = AetherSeekResolver(requestedSec: 100, afterID: 0)
        XCTAssertNil(forwardOnly.consume(event(1, .deferred, target: 100, .began)))
        XCTAssertNil(forwardOnly.consume(event(1, .deferred, target: 100, .superseded)))
        XCTAssertEqual(forwardOnly.consume(event(2, target: 100, .rejected(.sourceNotSeekable))),
                       .rejected(.sourceNotSeekable), "forward-only refusal of the replayed seek")
        var plain = AetherSeekResolver(requestedSec: 300, afterID: 0)
        XCTAssertEqual(plain.consume(event(1, target: 300, .superseded)), .superseded, "a programmatic supersede is final")
    }

    func testSeekPrecheck() {
        XCTAssertEqual(AetherSeekResolver.precheck(targetSec: .nan, phase: .playing, hasSession: true), .rejected(.notFinite))
        XCTAssertEqual(AetherSeekResolver.precheck(targetSec: .infinity, phase: .playing, hasSession: true), .rejected(.notFinite))
        XCTAssertEqual(AetherSeekResolver.precheck(targetSec: 3, phase: .ended, hasSession: true), .rejected(.ended))
        XCTAssertEqual(AetherSeekResolver.precheck(targetSec: 3, phase: .idle, hasSession: false), .rejected(.noActiveSession))
        XCTAssertNil(AetherSeekResolver.precheck(targetSec: 3, phase: .paused, hasSession: true))
    }

    // MARK: Cue flattening

    private func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testTextAndRichTextFlattenToText() {
        let plain = AetherCueFlattener.flatten(id: 1, startSec: 1, endSec: 2, source: .text("Hello"))
        XCTAssertEqual(plain.text, "Hello")
        XCTAssertFalse(plain.isForced)
        let rich = AetherCueFlattener.flatten(id: 2, startSec: 3, endSec: 4, source: .runs(["Hel", "lo ", "there"]),
                                              alignment: 8, anchor: CGPoint(x: 0.5, y: 0.1))
        XCTAssertEqual(rich.text, "Hello there", "runs join with nothing between them")
        XCTAssertEqual(rich.alignment, 8)
        XCTAssertEqual(rich.anchor, CGPoint(x: 0.5, y: 0.1))
        XCTAssertEqual(rich.startSec, 3)
        XCTAssertEqual(rich.endSec, 4)
    }

    func testBitmapKeepsRectCanvasAndForcedFlag() {
        let rect = CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.1)
        let cue = AetherCueFlattener.flatten(id: 9, startSec: 10, endSec: 12,
                                             source: .image(image(), position: rect, canvasSize: CGSize(width: 1920, height: 1080), isForced: true),
                                             alignment: 2, anchor: CGPoint(x: 1, y: 1))
        guard case .image(let img, let normalized, let canvas) = cue.body else { return XCTFail("not a bitmap") }
        XCTAssertEqual(img.width, 2)
        XCTAssertEqual(normalized, rect)
        XCTAssertEqual(canvas, CGSize(width: 1920, height: 1080))
        XCTAssertTrue(cue.isForced)
        XCTAssertNil(cue.text)
        XCTAssertNil(cue.alignment, "placement is a text-cue fact")
        XCTAssertNil(cue.anchor)
    }

    func testCueEqualityIgnoresTheBody() {
        let a = AetherCue(id: 1, startSec: 1, endSec: 2, body: .text("a"))
        let b = AetherCue(id: 1, startSec: 1, endSec: 2, body: .text("b"))
        let c = AetherCue(id: 1, startSec: 1, endSec: 3, body: .text("a"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: Clock

    @MainActor
    func testClockMirrorsSamplesAndPublishesOnlyChanges() {
        let clock = AetherClock()
        var changes = 0
        let token = clock.objectWillChange.sink { changes += 1 }
        let s = AetherClockSample(currentSec: 5, sourceSec: 5.5, sourceFollowsPicture: false, bufferedSec: 30,
                                  durationSec: 600, residentRanges: [0...30], isClockHeld: true)
        clock.apply(s)
        XCTAssertEqual(clock.sample, s)
        XCTAssertEqual(changes, 7, "one publish per changed field")
        clock.apply(s)
        XCTAssertEqual(changes, 7, "an unchanged tick publishes nothing")
        var next = s
        next.currentSec = 5.1
        clock.apply(next)
        XCTAssertEqual(changes, 8)
        XCTAssertEqual(clock.currentSec, 5.1)
        clock.reset()
        XCTAssertEqual(clock.sample, AetherClockSample())
        token.cancel()
    }

    // MARK: Request, shaping, display criteria

    func testShapingClampsAndActivity() {
        XCTAssertFalse(AetherAudioShaping().isActive)
        XCTAssertTrue(AetherAudioShaping(boostDB: 6).isActive)
        XCTAssertTrue(AetherAudioShaping(dialogueLiftDB: 3.5).isActive)
        XCTAssertEqual(AetherAudioShaping(dialogueLiftDB: 40, boostDB: 99).clamped, AetherAudioShaping(dialogueLiftDB: 12, boostDB: 24))
        XCTAssertEqual(AetherAudioShaping(dialogueLiftDB: -3, boostDB: .nan).clamped, AetherAudioShaping())
        XCTAssertFalse(AetherAudioShaping(dialogueLiftDB: -3, boostDB: -1).isActive)
    }

    func testMatchContentMapsToTheCriteriaOwner() {
        XCTAssertEqual(AetherDisplayCriteriaOwner.forMatchContent(true), .engine)
        XCTAssertEqual(AetherDisplayCriteriaOwner.forMatchContent(false), .host)
    }

    func testRequestDefaultsAndRestart() {
        let url = URL(string: "https://example.invalid/a.mkv")!
        let r = AetherLoadRequest(url: url, startSec: 42, headers: ["Authorization": "Bearer abcdef", "X": "ab"],
                                  externalSubtitles: [AetherExternalSubtitle(url: url, httpHeaders: ["Cookie": "session=1234"])])
        XCTAssertEqual(r.audioBridge, .lossless, "the fork default (plan section 14)")
        XCTAssertEqual(r.objectAudio, .off)
        XCTAssertEqual(r.displayCriteriaOwner, .engine)
        XCTAssertEqual(r.secretHeaderValues, ["Bearer abcdef", "session=1234"], "values under 4 bytes are not secrets")
        XCTAssertEqual(r.starting(atSec: 0).startSec, 0)
        XCTAssertEqual(r.starting(atSec: 0).url, url)
        XCTAssertEqual(r.starting(atSec: 0).headers, r.headers)
    }

    func testDiagnosticsDualLayerFlag() {
        var d = AetherDiagnostics(route: .software, sourceDVProfile: 7)
        XCTAssertTrue(d.dualLayerComposed)
        d.dvConvertedP7ToP81 = true
        XCTAssertFalse(d.dualLayerComposed)
        XCTAssertFalse(AetherDiagnostics(route: .loopback, sourceDVProfile: 7).dualLayerComposed)
    }
}
