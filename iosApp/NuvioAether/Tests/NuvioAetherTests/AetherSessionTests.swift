import XCTest
import AetherEngine
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

    func testSwitchBetweenSidecarsWithIdenticalCuesRepublishes() async throws {
        _ = try await session.load(request())
        let a = AetherTrack(id: 5, name: "A", codec: "srt")
        let b = AetherTrack(id: 6, name: "B", codec: "srt")
        let window = [AetherCue(id: 0, startSec: 1, endSec: 2, body: .text("hi"))]
        var publishes = 0
        let sub = session.$cues.dropFirst().sink { _ in publishes += 1 }
        engine.send(.tracks(audio: [], subtitle: [a, b], activeAudio: nil, activeSubtitle: 5))
        engine.send(.cues(window))
        XCTAssertEqual(publishes, 1)
        engine.send(.cues(window))
        XCTAssertEqual(publishes, 1, "same track and window is deduped")
        engine.send(.tracks(audio: [], subtitle: [a, b], activeAudio: nil, activeSubtitle: 6))
        engine.send(.cues(window))
        XCTAssertEqual(publishes, 2, "identical window under a new track must publish")
        sub.cancel()
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
        r.diskCache = AetherDiskCache(budgetBytes: 8_000_000_000, hardLimitBytes: 10_000_000_000, forwardSegments: 2700)
        _ = try await session.load(r)
        XCTAssertEqual(engine.loads, [r])
    }

    // MARK: Disk cache request path (5.1b layer 2)

    /// Sends each request through a real session over `FakeEngine` and maps what the engine recorded
    /// through the real `LiveEngine.options(for:)`.
    private func recordedOptions(_ requests: [AetherLoadRequest]) async throws -> [LoadOptions] {
        for r in requests { _ = try await session.load(r) }
        XCTAssertEqual(engine.loads, requests)
        return engine.loads.map(LiveEngine.options(for:))
    }

    private func cacheFields(_ o: LoadOptions) -> (Int?, Int?, Int?, Int, SoftwarePacketCacheStorage, Bool) {
        (o.forwardBufferSegments, o.sessionCacheByteBudget, o.sessionCacheHardLimitBytes,
         o.sessionCacheFreeReserveBytes, o.softwarePacketCacheStorage, o.retainsSessionCacheAfterStop)
    }

    private func assertEngineDefaults(_ o: LoadOptions, file: StaticString = #filePath, line: UInt = #line) {
        let f = cacheFields(o)
        XCTAssertNil(f.0, file: file, line: line)
        XCTAssertNil(f.1, file: file, line: line)
        XCTAssertNil(f.2, file: file, line: line)
        XCTAssertEqual(f.3, 0, file: file, line: line)
        XCTAssertEqual(f.4, .automatic, file: file, line: line)
        XCTAssertFalse(f.5, file: file, line: line)
    }

    private func assertTenGB(_ o: LoadOptions, file: StaticString = #filePath, line: UInt = #line) {
        let f = cacheFields(o)
        XCTAssertEqual(f.0, 2700, file: file, line: line)
        XCTAssertEqual(f.1, 8_000_000_000, file: file, line: line)
        XCTAssertEqual(f.2, 10_000_000_000, file: file, line: line)
        XCTAssertEqual(f.3, 0, file: file, line: line)
        XCTAssertEqual(f.4, .automatic, file: file, line: line)
        XCTAssertFalse(f.5, file: file, line: line)
    }

    private let tenGB = AetherDiskCache(budgetBytes: 8_000_000_000, hardLimitBytes: 10_000_000_000, forwardSegments: 2700)

    func testStartedOnSnapshotSurvivesRebuildAndReplay() async throws {
        let first = AetherLoadRequest(url: url, diskCache: tenGB)
        let rebuild = first.starting(atSec: 600)
        let replay = rebuild.starting(atSec: 0)
        XCTAssertEqual(rebuild.diskCache, tenGB)
        XCTAssertEqual(replay.diskCache, tenGB)
        let opts = try await recordedOptions([first, rebuild, replay])
        XCTAssertEqual(opts.count, 3)
        opts.forEach { assertTenGB($0) }
    }

    func testStartedOffSnapshotSurvivesRebuildAndReplay() async throws {
        let first = AetherLoadRequest(url: url)
        let opts = try await recordedOptions([first, first.starting(atSec: 600), first.starting(atSec: 0)])
        XCTAssertEqual(opts.count, 3)
        opts.forEach { assertEngineDefaults($0) }
    }

    func testOnToOffAndOffToOnApplyOnlyToTheNextFreshLoad() async throws {
        // On -> Off: rebuild and Replay keep On, the next fresh load is Off.
        let on = AetherLoadRequest(url: url, diskCache: tenGB)
        let off = AetherLoadRequest(url: url)
        let a = try await recordedOptions([on, on.starting(atSec: 600), on.starting(atSec: 0), off])
        assertTenGB(a[0]); assertTenGB(a[1]); assertTenGB(a[2]); assertEngineDefaults(a[3])
        // Off -> On (20 GB).
        engine.loads = []
        let twenty = AetherDiskCache(budgetBytes: 18_000_000_000, hardLimitBytes: 20_000_000_000, forwardSegments: 2700)
        let on20 = AetherLoadRequest(url: url, diskCache: twenty)
        let b = try await recordedOptions([off, off.starting(atSec: 600), off.starting(atSec: 0), on20])
        assertEngineDefaults(b[0]); assertEngineDefaults(b[1]); assertEngineDefaults(b[2])
        XCTAssertEqual(b[3].sessionCacheHardLimitBytes, 20_000_000_000)
        XCTAssertEqual(b[3].sessionCacheByteBudget, 18_000_000_000)
    }

    func testInvalidCacheOnTheRequestSendsOffThroughTheEngine() async throws {
        let bad = AetherLoadRequest(url: url, diskCache: AetherDiskCache(budgetBytes: 0, hardLimitBytes: 5, forwardSegments: 2700))
        let opts = try await recordedOptions([bad])
        assertEngineDefaults(opts[0])
    }
}

/// Return from background (spec 5.1.1, 9.2): the façade's foreground restore and its transport guard.
@MainActor
final class AetherSessionRestoreTests: XCTestCase {
    private var engine: FakeEngine!
    private var session: AetherPlaybackSession!
    private let url = URL(string: "http://127.0.0.1:8099/a.mkv")!

    override func setUp() async throws {
        engine = FakeEngine()
        session = AetherPlaybackSession(engine: engine)
        _ = try await session.load(AetherLoadRequest(url: url))
        engine.send(.firstFrame(true))
        engine.send(.phase(.playing))
        engine.send(.clock(AetherClockSample(currentSec: 120)))
    }

    override func tearDown() async throws {
        session.stop()
        session = nil
        engine = nil
    }

    func testRestoreLowersTheFrameSetsLoadingKeepsTheClockAndReloadsOnce() async throws {
        engine.needsForegroundRestore = true
        XCTAssertTrue(session.needsForegroundRestore)
        var seenDuring: (frame: Bool, phase: AetherPhase, clock: Double)?
        engine.onRestore = { [unowned self] _ in
            seenDuring = (self.session.firstFrameShown, self.session.phase, self.session.clock.currentSec)
        }
        let outcome = try await session.restoreAfterBackground()
        XCTAssertEqual(outcome, .reloaded)
        XCTAssertEqual(engine.restores, 1)
        XCTAssertEqual(seenDuring?.frame, false)
        XCTAssertEqual(seenDuring?.phase, .loading)
        XCTAssertEqual(seenDuring?.clock, 120)
        XCTAssertEqual(engine.loads.count, 1, "a restore sends no load")
        XCTAssertFalse(session.needsForegroundRestore)
        engine.send(.firstFrame(true))
        XCTAssertTrue(session.firstFrameShown, "the engine's latch raises it again")
    }

    func testRestoreReturnsEachOutcome() async throws {
        engine.needsForegroundRestore = true
        engine.restoreResult = .success(.refused(.notSeekable))
        let refused = try await session.restoreAfterBackground()
        XCTAssertEqual(refused, .refused(.notSeekable))
        engine.restoreResult = .success(.notNeeded)
        let notNeeded = try await session.restoreAfterBackground()
        XCTAssertEqual(notNeeded, .notNeeded)
    }

    func testRestoreWithNoTeardownOwedTouchesNothing() async throws {
        let outcome = try await session.restoreAfterBackground()
        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertEqual(engine.restores, 0, "the engine is never asked to reload a live session")
        XCTAssertTrue(session.firstFrameShown)
        XCTAssertEqual(session.phase, .playing)
    }

    func testRestoreThrowIsReportedOnceAsANewGeneration() async {
        var failures: [AetherFailure] = []
        session.onFailure = { failures.append($0) }
        // The old generation reported a failure already; the restore's own failure still reports.
        engine.send(.failure(AetherFailure.sample(.nativeItemFailed)))
        XCTAssertEqual(failures.count, 1)
        engine.needsForegroundRestore = true
        engine.restoreResult = .failure(AetherFailure.sample(.reloadFailed))
        do {
            _ = try await session.restoreAfterBackground()
            XCTFail("the restore should throw")
        } catch let f as AetherFailure {
            XCTAssertEqual(f.kind, .reloadFailed)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(failures.map(\.kind), [.nativeItemFailed, .reloadFailed])
    }

    func testStopDuringTheRestoreUnwindsAsCancellationAndReportsNothing() async {
        var failures = 0
        session.onFailure = { _ in failures += 1 }
        engine.needsForegroundRestore = true
        engine.restoreResult = .failure(AetherFailure.sample(.reloadFailed))
        engine.onRestore = { [unowned self] _ in self.session.stop() }
        do {
            _ = try await session.restoreAfterBackground()
            XCTFail("should unwind")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(failures, 0)
    }

    func testStoppedSessionRestoreIsCancellation() async {
        session.stop()
        engine.needsForegroundRestore = true
        do {
            _ = try await session.restoreAfterBackground()
            XCTFail("should unwind")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(engine.restores, 0)
        XCTAssertFalse(session.needsForegroundRestore, "a stopped session owes nothing")
    }

    func testTransportIsRefusedWhileARestoreIsOwed() async {
        engine.needsForegroundRestore = true
        session.play()
        session.togglePause()
        session.setRate(1)
        let seek = await session.seek(toSec: 30, exact: true)
        XCTAssertEqual(seek, .rejected(.foregroundRestoreOwed))
        XCTAssertEqual(engine.plays, 0)
        XCTAssertEqual(engine.toggles, 0)
        XCTAssertEqual(engine.rates, [])
        XCTAssertTrue(engine.seeks.isEmpty)
        session.pause()
        session.setRate(0)
        XCTAssertEqual(engine.pauses, 1, "pause still reaches the engine")
        XCTAssertEqual(engine.rates, [0])
        engine.needsForegroundRestore = false
        session.play()
        XCTAssertEqual(engine.plays, 1)
    }
}
