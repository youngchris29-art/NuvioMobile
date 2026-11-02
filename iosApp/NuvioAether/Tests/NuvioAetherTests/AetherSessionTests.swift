import XCTest
@testable import NuvioAether

/// The session's event wiring, driven by `FakeEngine`.
@MainActor
final class AetherSessionTests: XCTestCase {
    private var engine: FakeEngine!
    private var session: AetherPlaybackSession!
    private let url = URL(string: "http://127.0.0.1:8099/a.mkv")!

    override func setUp() async throws {
        engine = FakeEngine()
        session = AetherPlaybackSession(engine: engine)
    }

    override func tearDown() async throws {
        session.stop()
        session = nil
        engine = nil
    }

    private func request() -> AetherLoadRequest { AetherLoadRequest(url: url) }

    // MARK: Load end

    func testThrowPlusErrorInfoIsOneFailure() async {
        var failures: [AetherFailure] = []
        session.onFailure = { failures.append($0) }
        let published = AetherFailure.sample(.vodSourceFailed, message: "published")
        engine.onLoad = { e in
            e.send(.failure(published))           // $errorInfo first
            e.send(.phase(.error("published")))    // then $state / $playbackPhase
        }
        engine.loadResult = .failure(AetherFailure.sample(.vodSourceFailed, message: "thrown"))
        do {
            _ = try await session.load(request())
            XCTFail("load should throw")
        } catch let f as AetherFailure {
            XCTAssertEqual(f.message, "published", "the throw rethrows the failure already reported")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(session.phase, .failed(published))
    }

    func testThrowWithoutPublishedFailureIsReportedOnce() async {
        var failures: [AetherFailure] = []
        session.onFailure = { failures.append($0) }
        engine.loadResult = .failure(FakeError())
        do { _ = try await session.load(request()) } catch {}
        XCTAssertEqual(failures.map(\.kind), [.unknown("thrown:FakeError")])
    }

    func testCancellationIsNeverAFailure() async {
        var failures = 0
        session.onFailure = { _ in failures += 1 }
        engine.loadResult = .failure(CancellationError())
        do {
            _ = try await session.load(request())
            XCTFail("load should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(session.phase, .loading)
    }

    func testFailureAfterStopIsStale() async throws {
        _ = try await session.load(request())
        var failures = 0
        session.onFailure = { _ in failures += 1 }
        session.stop()
        engine.send(.failure(.sample(.nativeItemFailed)))
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(session.phase, .idle)
    }

    func testMidSessionFailureThenFreshLoadReportsAgain() async throws {
        var failures: [AetherFailureKind] = []
        session.onFailure = { failures.append($0.kind) }
        _ = try await session.load(request())
        engine.send(.failure(.sample(.nativeItemFailed)))
        engine.send(.failure(.sample(.nativeItemFailed)))
        XCTAssertEqual(failures, [.nativeItemFailed])
        // DV-interruption rebuild: a fresh load at the last position, not reloadAtCurrentPosition.
        let rebuild = try XCTUnwrap(session.currentRequest).starting(atSec: 812)
        _ = try await session.load(rebuild)
        XCTAssertEqual(engine.loads.last?.startSec, 812)
        XCTAssertEqual(session.phase, .loading)
        engine.send(.failure(.sample(.nativeItemFailed)))
        XCTAssertEqual(failures, [.nativeItemFailed, .nativeItemFailed])
    }

    func testFirstFrameTimeoutGoesThroughTheLedger() async throws {
        var failures: [AetherFailureKind] = []
        session.onFailure = { failures.append($0.kind) }
        _ = try await session.load(request())
        session.reportFirstFrameTimeout()
        session.reportFirstFrameTimeout()
        engine.send(.failure(.sample(.vodSourceFailed)))
        XCTAssertEqual(failures, [.firstFrameTimeout])
    }

    func testFirstFrameTimeoutIgnoredOnceAFrameIsUp() async throws {
        var failures = 0
        session.onFailure = { _ in failures += 1 }
        _ = try await session.load(request())
        engine.send(.firstFrame(true))
        engine.send(.firstFrame(false))
        XCTAssertTrue(session.firstFrameShown, "latched per load")
        session.reportFirstFrameTimeout()
        XCTAssertEqual(failures, 0)
    }

    // MARK: Ended

    func testEndedIsTerminalAndFiresOnce() async throws {
        var ended = 0
        session.onEnded = { ended += 1 }
        _ = try await session.load(request())
        engine.send(.phase(.playing))
        engine.send(.clock(AetherClockSample(currentSec: 599, durationSec: 600)))
        engine.send(.phase(.ended))
        engine.send(.phase(.playing))
        engine.send(.phase(.ended))
        engine.send(.clock(AetherClockSample(currentSec: 0, durationSec: 600)))
        XCTAssertEqual(session.phase, .ended)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(session.clock.currentSec, 599, "the clock holds at the last sample")
        session.play()
        session.togglePause()
        session.setRate(1.5)
        XCTAssertEqual(engine.plays + engine.toggles + engine.rates.count, 0)
        let outcome = await session.seek(toSec: 10, exact: false)
        XCTAssertEqual(outcome, .rejected(.ended))
        XCTAssertTrue(engine.seeks.isEmpty)
        XCTAssertFalse(session.canSeek)
        // Replay: load again at 0.
        _ = try await session.load(try XCTUnwrap(session.currentRequest).starting(atSec: 0))
        XCTAssertEqual(session.phase, .loading)
        engine.send(.phase(.playing))
        XCTAssertEqual(session.phase, .playing)
        session.play()
        XCTAssertEqual(engine.plays, 1)
    }

    // MARK: Seek

    func testSeekResolvesFromEventsEmittedDuringTheCall() async throws {
        _ = try await session.load(request())
        engine.send(.seek(AetherSeekEventSample(id: 4, origin: .programmatic, target: 1, outcome: .landed(renderedSec: 1))))
        engine.onSeek = { e, target in
            e.send(.seek(AetherSeekEventSample(id: 5, origin: .programmatic, target: target, outcome: .began)))
            e.send(.seek(AetherSeekEventSample(id: 5, origin: .programmatic, target: target, outcome: .landed(renderedSec: 299.98))))
        }
        let outcome = await session.seek(toSec: 300, exact: true)
        XCTAssertEqual(outcome, .landed(atSec: 299.98))
        XCTAssertEqual(engine.seeks.last?.exact, true)
    }

    func testSeekResolvesFromALaterEvent() async throws {
        _ = try await session.load(request())
        engine.onSeek = { e, target in
            e.send(.seek(AetherSeekEventSample(id: 1, origin: .programmatic, target: target, outcome: .began)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                e.send(.seek(AetherSeekEventSample(id: 1, origin: .programmatic, target: target, outcome: .stalled)))
            }
        }
        let outcome = await session.seek(toSec: 60, exact: false)
        XCTAssertEqual(outcome, .stalled)
    }

    func testSeekRejectedEventIsReported() async throws {
        _ = try await session.load(request())
        engine.onSeek = { e, target in
            e.send(.seek(AetherSeekEventSample(id: 1, origin: .programmatic, target: target,
                                               outcome: .rejected(.sourceNotSeekable))))
        }
        let outcome = await session.seek(toSec: 60, exact: false)
        XCTAssertEqual(outcome, .rejected(.sourceNotSeekable))
    }

    func testStopEndsAPendingSeek() async throws {
        _ = try await session.load(request())
        engine.onSeek = { e, target in
            e.send(.seek(AetherSeekEventSample(id: 1, origin: .programmatic, target: target, outcome: .began)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [session] in session?.stop() }
        let outcome = await session.seek(toSec: 60, exact: false)
        XCTAssertEqual(outcome, .rejected(.noActiveSession))
    }

    func testSeekWithoutSessionAndNonFiniteTarget() async throws {
        let none = await session.seek(toSec: 5, exact: false)
        XCTAssertEqual(none, .rejected(.noActiveSession))
        _ = try await session.load(request())
        let nan = await session.seek(toSec: .nan, exact: false)
        XCTAssertEqual(nan, .rejected(.notFinite))
        XCTAssertTrue(engine.seeks.isEmpty)
    }

    // MARK: Stop

    func testStopIsIdempotentAndHandOffKeepsCriteria() async throws {
        _ = try await session.load(request())
        session.stop(handingOff: true)
        session.stop()
        XCTAssertEqual(engine.stops.count, 1)
        XCTAssertEqual(engine.stops.first?.reset, false, "a handoff to mpv keeps the panel mode")
        XCTAssertEqual(engine.stops.first?.final, true)
        _ = try await session.load(request())
        session.stop()
        XCTAssertEqual(engine.stops.count, 2)
        XCTAssertEqual(engine.stops.last?.reset, true)
    }

    func testCommandsAfterStopReachNothing() async throws {
        _ = try await session.load(request())
        session.stop()
        XCTAssertNil(session.addExternalSubtitle(AetherExternalSubtitle(url: url, httpHeaders: ["Cookie": "secret-1"])))
        session.play()
        session.pause()
        session.selectAudio(id: 1)
        session.setAudioDelay(0.2)
        session.setAudioShaping(AetherAudioShaping(boostDB: 6))
        XCTAssertEqual(engine.plays + engine.pauses + engine.selectedAudio.count + engine.delays.count + engine.shapings.count, 0)
        XCTAssertFalse(session.updateRequestHeaders(["A": "b"]))
    }

    func testDeinitBackstopStopsTheEngine() async throws {
        let fake = FakeEngine()
        var s: AetherPlaybackSession? = AetherPlaybackSession(engine: fake)
        _ = try await s?.load(request())
        s = nil
        XCTAssertEqual(fake.stops.count, 1)
    }

    // MARK: Events

    func testEscalationIsReportedNotFailed() async throws {
        var escalations: [AetherEscalation] = []
        var failures = 0
        session.onEscalatedToSoftware = { escalations.append($0) }
        session.onFailure = { _ in failures += 1 }
        _ = try await session.load(request())
        let e = AetherEscalation(atSec: 0, duringStartup: true, absorbed: .nativeItemFailed)
        engine.send(.escalation(e))
        engine.send(.diagnostics(AetherDiagnostics(route: .software)))
        XCTAssertEqual(escalations, [e])
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(session.diagnostics.softwareEscalations, 1, "the session owns the count")
        XCTAssertEqual(session.diagnostics.route, .software)
        XCTAssertEqual(session.phase, .loading)
    }

    func testAudioDroppedFiresOncePerLoad() async throws {
        var dropped = 0
        session.onAudioDropped = { dropped += 1 }
        _ = try await session.load(request())
        engine.send(.audioDelivery(.bridged))
        engine.send(.audioDelivery(.droppedNoPipeline))
        engine.send(.audioDelivery(.droppedNoPipeline))
        XCTAssertEqual(dropped, 1)
        _ = try await session.load(request())
        engine.send(.audioDelivery(.droppedNoPipeline))
        XCTAssertEqual(dropped, 2)
    }

    func testTracksCuesChaptersAndAuthorization() async throws {
        var refused: [Int] = []
        session.onAuthorizationRefused = { refused.append($0) }
        _ = try await session.load(request())
        let a = AetherTrack(id: 1, name: "English", codec: "truehd", channels: 8, isAtmos: true)
        let s = AetherTrack(id: 3, name: "Signs", codec: "ass", isForced: true)
        engine.send(.tracks(audio: [a], subtitle: [s], activeAudio: 1, activeSubtitle: nil))
        engine.send(.cues([AetherCue(id: 1, startSec: 1, endSec: 2, body: .text("hi"))]))
        engine.send(.chapters([AetherChapter(id: 0, title: "Intro", startSec: 0, durationSec: 90)]))
        engine.send(.authorizationRefused(403))
        engine.send(.state(isPaused: true))
        XCTAssertEqual(session.audioTracks, [a])
        XCTAssertEqual(session.subtitleTracks, [s])
        XCTAssertEqual(session.activeAudioID, 1)
        XCTAssertNil(session.activeSubtitleID)
        XCTAssertEqual(session.cues.first?.text, "hi")
        XCTAssertEqual(session.chapters.first?.title, "Intro")
        XCTAssertEqual(refused, [403])
        XCTAssertTrue(session.isPaused)
    }

    func testClockMirrorsEngineSamples() async throws {
        _ = try await session.load(request())
        let sample = AetherClockSample(currentSec: 12, sourceSec: 12.5, bufferedSec: 40, durationSec: 600,
                                       residentRanges: [0...40], isClockHeld: false)
        engine.send(.clock(sample))
        XCTAssertEqual(session.clock.sample, sample)
    }

    func testNewSourceResetsClockAndCuesButReplayKeepsTheAxis() async throws {
        _ = try await session.load(request())
        engine.send(.clock(AetherClockSample(currentSec: 30, durationSec: 600)))
        engine.send(.cues([AetherCue(id: 1, startSec: 1, endSec: 2, body: .text("hi"))]))
        _ = try await session.load(request().starting(atSec: 30))
        XCTAssertEqual(session.clock.durationSec, 600, "same source keeps its axis")
        XCTAssertTrue(session.cues.isEmpty)
        _ = try await session.load(AetherLoadRequest(url: URL(string: "http://127.0.0.1:8099/b.mkv")!))
        XCTAssertEqual(session.clock.durationSec, 0)
    }

    func testShapingIsClampedBeforeTheEngine() async throws {
        _ = try await session.load(request())
        session.setAudioShaping(AetherAudioShaping(dialogueLiftDB: 3.5, boostDB: 40))
        XCTAssertEqual(engine.shapings, [AetherAudioShaping(dialogueLiftDB: 3.5, boostDB: 24)])
    }

    func testRequestReachesTheEngineUnchanged() async throws {
        var r = request()
        r.audioBridge = .surroundCompat
        r.displayCriteriaOwner = .forMatchContent(false)
        r.systemMatchingEnabled = false
        r.objectAudio = .render(.l514)
        _ = try await session.load(r)
        XCTAssertEqual(engine.loads, [r])
    }
}
