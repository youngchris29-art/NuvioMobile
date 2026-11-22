import XCTest
import NuvioAether
@testable import NuvioTV

/// GitHub #29, request capture layer 1: `AetherLoadRequestFlow` is the only producer of the Aether
/// controller's requests. These tests drive it with the calls the controller makes on each path
/// (`fresh` in `startPlayback`, `reload` in `rebuild(after:)` and `replay()` through `reloadRequest`)
/// and change the inputs between calls to model a preference changed mid-session. Layer 2 (the same
/// requests through `AetherPlaybackSession` and `LiveEngine.options(for:)`) is in the NuvioAether
/// package's `AetherSessionTests`. The source scans at the end hold the wiring: one `session.load`
/// caller, requests only from the flow, and no mpv file reading the key.
@MainActor
final class AetherLoadRequestFlowTests: XCTestCase {
    private let url = URL(string: "https://example.com/film.mkv")!
    private let free98: Int64 = 98_000_000_000

    private let tenGB = AetherDiskCache(budgetBytes: 8_000_000_000, hardLimitBytes: 10_000_000_000, forwardSegments: 2700)
    private let twentyGB = AetherDiskCache(budgetBytes: 18_000_000_000, hardLimitBytes: 20_000_000_000, forwardSegments: 2700)

    private func inputs(_ choice: AetherDiskCacheChoice, aetherOn: Bool = true, free: Int64? = 98_000_000_000) -> AetherDiskCacheInputs {
        AetherDiskCacheInputs(choice: choice, aetherOn: aetherOn, freeBytes: free)
    }

    /// What `makeLoadRequest` gives the flow: everything but the cache.
    private func base(startSec: Double? = 42) -> AetherLoadRequest {
        AetherLoadRequest(url: url, startSec: startSec, headers: ["Authorization": "Bearer abcdef"],
                          preferredAudioLanguages: ["eng"], initialSubtitle: .preferLanguages(["eng"]),
                          externalSubtitles: [AetherExternalSubtitle(url: URL(string: "https://example.com/a.vtt")!)],
                          dualLayerDV: true, logTag: "player")
    }

    /// The controller's rebuild (`startSec` = the last position) and Replay (`0`), with live tracks.
    private func rebuild(_ current: AetherLoadRequest) -> AetherLoadRequest {
        AetherLoadRequestFlow.reload(from: current, startSec: 600, activeAudioID: 2, activeSubtitleID: 7,
                                     subtitleDecided: true, addedSubtitles: [])
    }

    private func replay(_ current: AetherLoadRequest) -> AetherLoadRequest {
        AetherLoadRequestFlow.reload(from: current, startSec: 0, activeAudioID: 2, activeSubtitleID: nil,
                                     subtitleDecided: true,
                                     addedSubtitles: [AetherExternalSubtitle(url: URL(string: "https://subs.example.com/b.srt")!)])
    }

    // MARK: - Snapshot on every path

    func testStartedOnSnapshotSurvivesRebuildAndReplay() {
        let first = AetherLoadRequestFlow.fresh(base: base(), inputs: inputs(.gigabytes(10)))
        let rebuilt = rebuild(first)
        let replayed = replay(first)
        XCTAssertEqual(first.diskCache, tenGB)
        XCTAssertEqual(rebuilt.diskCache, tenGB)
        XCTAssertEqual(replayed.diskCache, tenGB)
        // Only the start and the track fields differ from the fresh request.
        var expectedRebuild = first.starting(atSec: 600)
        expectedRebuild.audioStreamIndex = 2
        expectedRebuild.initialSubtitle = .track(id: 7)
        XCTAssertEqual(rebuilt, expectedRebuild)
        XCTAssertEqual(replayed.startSec, 0)
        XCTAssertEqual(replayed.initialSubtitle, .off)
        XCTAssertEqual(replayed.externalSubtitles.count, 2)
    }

    func testStartedOffSnapshotSurvivesRebuildAndReplay() {
        let first = AetherLoadRequestFlow.fresh(base: base(), inputs: inputs(.off))
        XCTAssertNil(first.diskCache)
        XCTAssertNil(rebuild(first).diskCache)
        XCTAssertNil(replay(first).diskCache)
    }

    /// The fresh load through the controller's call: no cleanup to wait for, inputs from `read`.
    private func freshLoad(_ base: AetherLoadRequest, read: () -> AetherDiskCacheInputs) async -> AetherLoadRequestFlow.Fresh {
        await AetherLoadRequestFlow.fresh(base: base, awaitCleanup: { true }, readInputs: read)
    }

    func testOnToOffMidSessionAppliesOnlyToTheNextFreshLoad() async {
        var current = inputs(.gigabytes(10))
        let first = await freshLoad(base(), read: { current }).request
        current = inputs(.off)   // switched Off in Settings during the session
        XCTAssertEqual(rebuild(first).diskCache, tenGB)
        XCTAssertEqual(replay(first).diskCache, tenGB)
        let next = await freshLoad(base(startSec: nil), read: { current }).request
        XCTAssertNil(next.diskCache, "the next title starts with the new value")
    }

    func testOffToOnMidSessionAppliesOnlyToTheNextFreshLoad() async {
        var current = inputs(.off)
        let first = await freshLoad(base(), read: { current }).request
        current = inputs(.gigabytes(20))
        XCTAssertNil(rebuild(first).diskCache)
        XCTAssertNil(replay(first).diskCache)
        let next = await freshLoad(base(startSec: nil), read: { current }).request
        XCTAssertEqual(next.diskCache, twentyGB)
    }

    func testFreshReadsInputsOnce() async {
        var reads = 0
        let result = await freshLoad(base(), read: { reads += 1; return self.inputs(.maximum) })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.inputs, inputs(.maximum))
        XCTAssertEqual(result.request.diskCache?.hardLimitBytes, 24_000_000_000)
    }

    func testReloadNeverReadsInputs() async {
        // `reload` takes no inputs at all; a counting stub on the controller's property would see none.
        var reads = 0
        let stub: () -> AetherDiskCacheInputs = { reads += 1; return self.inputs(.off) }
        let first = await freshLoad(base(), read: stub).request
        reads = 0
        _ = rebuild(first)
        _ = replay(first)
        XCTAssertEqual(reads, 0)
    }

    // MARK: - Leftover cleanup before the free-space reading (code review r5)

    /// A fresh load awaits the cleanup exactly once, and reads the inputs only after it returned, so the
    /// free space it sizes the cache from is the space after the leftovers' deletion.
    func testFreshAwaitsCleanupOnceBeforeTheRead() async {
        var events: [String] = []
        var free: Int64 = 3_000_000_000   // leftovers still on disk: below the 4 GB Maximum needs
        let result = await AetherLoadRequestFlow.fresh(
            base: base(),
            awaitCleanup: { events.append("cleanup"); free = 98_000_000_000; return true },
            readInputs: { events.append("read"); return self.inputs(.maximum, free: free) })
        XCTAssertEqual(events, ["cleanup", "read"])
        XCTAssertTrue(result.cleanupFinished)
        XCTAssertEqual(result.request.diskCache?.hardLimitBytes, 24_000_000_000, "sized after the deletion")
    }

    /// The wait hit its bound: the load still goes ahead, with the reading as it is, and says so.
    func testFreshProceedsWhenTheCleanupWaitTimesOut() async {
        var events: [String] = []
        let result = await AetherLoadRequestFlow.fresh(
            base: base(),
            awaitCleanup: { events.append("cleanup"); return false },
            readInputs: { events.append("read"); return self.inputs(.gigabytes(10)) })
        XCTAssertEqual(events, ["cleanup", "read"])
        XCTAssertFalse(result.cleanupFinished)
        XCTAssertEqual(result.request.diskCache, tenGB)
    }

    /// Rebuild and Replay reuse the snapshot: `reload` has no cleanup step and no reading, so neither
    /// waits (a counting awaiter used for the fresh load sees no further calls).
    func testReloadsNeverAwaitCleanup() async {
        var awaits = 0
        let first = await AetherLoadRequestFlow.fresh(base: base(), awaitCleanup: { awaits += 1; return true },
                                                      readInputs: { self.inputs(.gigabytes(10)) }).request
        XCTAssertEqual(awaits, 1)
        _ = rebuild(first)
        _ = replay(first)
        XCTAssertEqual(awaits, 1)
    }

    /// Code review r6: with a delayed cleanup, the start watchdog is armed only after the wait returned,
    /// right before the load, so the wait never counts against the watchdog budget.
    func testStartArmsTheWatchdogOnlyAfterTheCleanupWait() async {
        var events: [String] = []
        let built = await AetherLoadRequestFlow.start(
            base: base(),
            awaitCleanup: {
                events.append("wait begins")
                try? await Task.sleep(nanoseconds: 50_000_000)
                events.append("wait returns")
                return true
            },
            readInputs: { events.append("read"); return self.inputs(.gigabytes(10)) },
            isCurrent: { events.append("check"); return true },
            armWatchdog: { events.append("arm") },
            load: { fresh in events.append("load"); XCTAssertEqual(fresh.request.diskCache, self.tenGB) })
        XCTAssertEqual(events, ["wait begins", "wait returns", "read", "check", "arm", "load"])
        XCTAssertEqual(built?.request.diskCache, tenGB)
    }

    /// A load cancelled, handed off or torn down during the wait arms no watchdog and never loads.
    func testStartDroppedDuringTheWaitArmsNothingAndLoadsNothing() async {
        var events: [String] = []
        var current = true
        let built = await AetherLoadRequestFlow.start(
            base: base(),
            awaitCleanup: { events.append("wait"); current = false; return false },
            readInputs: { self.inputs(.gigabytes(10)) },
            isCurrent: { current },
            armWatchdog: { events.append("arm") },
            load: { _ in events.append("load") })
        XCTAssertEqual(events, ["wait"])
        XCTAssertNil(built)
    }

    func testFreshReplacesAnyCacheOnTheBase() {
        var b = base()
        b.diskCache = twentyGB
        XCTAssertNil(AetherLoadRequestFlow.fresh(base: b, inputs: inputs(.off)).diskCache)
        XCTAssertEqual(AetherLoadRequestFlow.fresh(base: b, inputs: inputs(.gigabytes(10))).diskCache, tenGB)
        // Everything else is the base, untouched.
        var withoutCache = AetherLoadRequestFlow.fresh(base: b, inputs: inputs(.gigabytes(10)))
        withoutCache.diskCache = nil
        b.diskCache = nil
        XCTAssertEqual(withoutCache, b)
    }

    /// Code review r1, finding 2: the app does not predict the engine's route. The engine picks it after
    /// `load` and has one window field for both routes, so an On load carries the same cache whatever the
    /// request hints (dual-layer Dolby Vision, software decode); on the software route that window only
    /// lifts the memory store's seconds limit inside its fixed caps (`AetherDiskCachePlan.forwardSegments`).
    func testOnCacheDoesNotDependOnRouteHints() {
        var hints = base()
        hints.dualLayerDV = true
        hints.preferSoftwareDecode = true
        var plain = base()
        plain.dualLayerDV = false
        plain.preferSoftwareDecode = false
        for choice in AetherDiskCacheChoice.all {
            XCTAssertEqual(AetherLoadRequestFlow.fresh(base: hints, inputs: inputs(choice)).diskCache,
                           AetherLoadRequestFlow.fresh(base: plain, inputs: inputs(choice)).diskCache, "\(choice)")
        }
        XCTAssertEqual(AetherLoadRequestFlow.fresh(base: hints, inputs: inputs(.gigabytes(10))).diskCache?.forwardSegments, 2700)
    }

    func testAetherOffSendsNoCache() {
        XCTAssertNil(AetherLoadRequestFlow.fresh(base: base(), inputs: inputs(.maximum, aetherOn: false)).diskCache)
    }

    func testUnknownFreeAndBelowOneGBSendOff() {
        let unknown = inputs(.maximum, free: nil)
        let low = inputs(.maximum, free: 3_900_000_000)
        let a = AetherLoadRequestFlow.fresh(base: base(), inputs: unknown)
        let b = AetherLoadRequestFlow.fresh(base: base(), inputs: low)
        XCTAssertNil(a.diskCache)
        XCTAssertNil(b.diskCache)
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(a, inputs: unknown), "off(free unknown)")
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(b, inputs: low), "off(below 1 GB)")
        // Their rebuilds log the same field from the same snapshot.
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(rebuild(a), inputs: unknown), "off(free unknown)")
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(rebuild(b), inputs: low), "off(below 1 GB)")
    }

    func testLogFieldMatchesRequest() {
        let i = inputs(.gigabytes(10))
        let first = AetherLoadRequestFlow.fresh(base: base(), inputs: i)
        let field = "shown:10GB,budget:8000,hard:10000,window:2700"
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(first, inputs: i), field)
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(rebuild(first), inputs: i), field)
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(replay(first), inputs: i), field)
        let max = inputs(.maximum)
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(AetherLoadRequestFlow.fresh(base: base(), inputs: max), inputs: max),
                       "shown:24GB,budget:22000,hard:24000,window:2700")
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(AetherLoadRequestFlow.fresh(base: base(), inputs: inputs(.off)),
                                                           inputs: inputs(.off)), "off")
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(base(), inputs: nil), "off")
        var budgetOnly = base()
        budgetOnly.diskCache = AetherDiskCache(budgetBytes: 8_000_000_000, hardLimitBytes: nil, forwardSegments: 2700)
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(budgetOnly, inputs: nil), "shown:-GB,budget:8000,hard:-,window:2700")
    }

    // MARK: - Return from background: the fresh-load fallback (spec 5.1.5)

    private func restore(_ current: AetherLoadRequest, at: Double = 600) -> AetherLoadRequest {
        AetherLoadRequestFlow.restore(from: current, atSec: at, audioTrackID: 2, subtitleTrackID: 7,
                                      subtitleDecided: true, liveAudioDelaySec: 0.35,
                                      liveShaping: AetherAudioShaping(dialogueLiftDB: 4, boostDB: 6),
                                      addedSubtitles: [])
    }

    func testRestoreTakesTheSnapshotTracksAndTheLiveDelayAndShapingPaused() {
        let first = AetherLoadRequestFlow.fresh(base: base(), inputs: inputs(.gigabytes(10)))
        let r = restore(first)
        XCTAssertTrue(r.startPaused)
        XCTAssertEqual(r.startSec, 600)
        XCTAssertEqual(r.audioStreamIndex, 2, "the snapshot's audio, not the live (possibly empty) list")
        XCTAssertEqual(r.initialSubtitle, .track(id: 7))
        XCTAssertEqual(r.audioDelaySec, 0.35)
        XCTAssertEqual(r.audioShaping, AetherAudioShaping(dialogueLiftDB: 4, boostDB: 6))
        // Everything else is the rebuild's request.
        var expected = rebuild(first)
        expected.startPaused = true
        expected.audioDelaySec = 0.35
        expected.audioShaping = AetherAudioShaping(dialogueLiftDB: 4, boostDB: 6)
        XCTAssertEqual(r, expected)
        XCTAssertFalse(first.startPaused, "the fresh load itself autoplays")
    }

    /// W5 r1: after a paused fresh-load restore `currentRequest` carries `startPaused`; the interruption
    /// rebuild and Replay built from it must autoplay again, and a second restore stays paused.
    func testRebuildAndReplayFromAPausedRestoreAutoplay() {
        let first = AetherLoadRequestFlow.fresh(base: base(), inputs: inputs(.gigabytes(10)))
        let restored = restore(first)
        XCTAssertTrue(restored.startPaused)
        XCTAssertFalse(rebuild(restored).startPaused, "the interruption rebuild resumes playing")
        XCTAssertFalse(replay(restored).startPaused, "Play Again plays")
        XCTAssertTrue(restore(restored).startPaused, "a later restore is paused again")
    }

    func testRestoreKeepsTheVisitsCacheSnapshotOnAndOff() {
        let on = AetherLoadRequestFlow.fresh(base: base(), inputs: inputs(.gigabytes(10)))
        let off = AetherLoadRequestFlow.fresh(base: base(), inputs: inputs(.off))
        XCTAssertEqual(restore(on).diskCache, tenGB)
        XCTAssertNil(restore(off).diskCache)
    }

    func testRestoreNearTheHeadStartsAtTheHead() {
        let first = AetherLoadRequestFlow.fresh(base: base(), inputs: inputs(.off))
        XCTAssertNil(restore(first, at: 0.5).startSec)
        XCTAssertEqual(restore(first, at: 1.5).startSec, 1.5)
    }

    /// I8: the fallback reads no setting and waits on no cleanup. It takes no reader or awaiter at all,
    /// and the flow's only awaiter / reader use is `fresh`.
    func testRestoreReadsNoInputsAndAwaitsNoCleanup() throws {
        let flow = try appSources().first { $0.name == "AetherLoadRequestFlow.swift" }?.source ?? ""
        let body = flow.components(separatedBy: "static func restore(").dropFirst().first ?? ""
        let restoreBody = body.components(separatedBy: "static func cacheLogField(").first ?? ""
        XCTAssertFalse(restoreBody.isEmpty)
        for needle in ["readInputs", "awaitCleanup", "AetherDiskCacheInputs", "pendingDeletionFinished"] {
            XCTAssertFalse(restoreBody.contains(needle), "restore names \(needle)")
        }
    }

    // MARK: - The mpv handoff

    func testHandoffCarriesNoCache() {
        let first = AetherLoadRequestFlow.fresh(base: base(), inputs: inputs(.maximum))
        XCTAssertNotNil(first.diskCache)
        let handoff = PlaybackHandoff(positionSec: 120, secondsPlayed: 80, startedPlaying: true, kind: .local)
        // A later cache field on the handoff fails here.
        XCTAssertEqual(Mirror(reflecting: handoff).children.compactMap(\.label),
                       ["positionSec", "secondsPlayed", "startedPlaying", "kind"])
    }

    /// mpv builds its options inline from UserDefaults (no pure builder exists), so the guarantee that
    /// the mpv side ignores Disk Cache is held at the source: only the setting's own files name the key
    /// or read the choice, and no mpv file does.
    func testOnlyTheSettingsOwnFilesReadTheKey() throws {
        let allowed: Set<String> = ["PlaybackModels.swift", "SettingsViewModel.swift", "AetherDiskCachePlan.swift"]
        var readers = Set<String>()
        for (name, source) in try appSources() {
            if source.contains("diskCacheGBKey") || source.contains("\"player.diskCacheGB\"")
                || source.contains("diskCacheChoice(") || source.contains("AetherDiskCacheInputs.live") {
                readers.insert(name)
            }
        }
        XCTAssertTrue(readers.subtracting(allowed.union(["AetherTVPlayerViewController.swift"])).isEmpty,
                      "unexpected readers of the Disk Cache key: \(readers.sorted())")
        XCTAssertFalse(readers.contains { $0.hasPrefix("MPV") }, "an mpv file reads the Disk Cache key: \(readers.sorted())")
        XCTAssertTrue(readers.isSuperset(of: allowed), "scanner found: \(readers.sorted())")
    }

    // MARK: - The controller's wiring (the W3 grep check, held as a test)

    func testOneSessionLoadCallerAndRequestsOnlyFromTheFlow() throws {
        let aether = try appSources().filter { $0.name.hasPrefix("AetherTVPlayerViewController") }
        XCTAssertEqual(aether.count, 2, "files: \(aether.map(\.name))")
        let joined = aether.map(\.source).joined(separator: "\n")
        XCTAssertEqual(occurrences(of: "session.load(", in: joined), 1, "runLoad is the only caller of session.load")
        XCTAssertEqual(occurrences(of: "AetherLoadRequest(", in: joined), 1, "only makeLoadRequest's base is built here")
        XCTAssertEqual(occurrences(of: ".diskCache =", in: joined), 0, "the cache is set only by the flow")
        XCTAssertEqual(occurrences(of: "AetherReloadRequestPlan.request(", in: joined), 0, "reloads go through the flow")
        XCTAssertEqual(occurrences(of: "AetherLoadRequestFlow.fresh(", in: joined), 0)
        XCTAssertEqual(occurrences(of: "AetherLoadRequestFlow.start(", in: joined), 1)
        // Review r6: the fresh load's watchdog is armed only by the flow, after the wait; the other two
        // calls are rebuild and Replay (plus the definition).
        XCTAssertEqual(occurrences(of: "armWatchdog: { self?.armStartWatchdog() }", in: joined), 1)
        // Return from background: the fifth is the rule's `rearmStartWatchdog` effect (start budget after
        // a return during a start or an operation).
        XCTAssertEqual(occurrences(of: "armStartWatchdog()", in: joined), 5)
        // Code review r5: the fresh load hands the flow the controller's cleanup awaiter, and only it.
        XCTAssertEqual(occurrences(of: "awaitCleanup: awaitCleanup", in: joined), 1)
        XCTAssertEqual(occurrences(of: "pendingDeletionFinished(", in: joined), 1, "only the awaiter's default")
        XCTAssertEqual(occurrences(of: "AetherLoadRequestFlow.reload(", in: joined), 1)
        // Both reload paths build through `reloadRequest`.
        XCTAssertEqual(occurrences(of: "runLoad(session, reloadRequest(", in: joined), 2)
        XCTAssertEqual(occurrences(of: "runLoad(session, request)", in: joined), 1)
        // Return from background (spec I8): the reload path sends no request; the fresh-load fallback
        // sends exactly one, built by the flow through `restoreRequest(at:)`.
        XCTAssertEqual(occurrences(of: "runLoad(session, restoreLoad)", in: joined), 1)
        XCTAssertEqual(occurrences(of: "AetherLoadRequestFlow.restore(", in: joined), 1)
        XCTAssertEqual(occurrences(of: "restoreRequest(at:", in: joined), 1)
        XCTAssertEqual(occurrences(of: "restoreAfterBackground(", in: joined), 0, "the restore goes through the runner")
        // No other app file sets a cache on a request (the smoke harness never does).
        for (name, source) in try appSources() where name != "AetherLoadRequestFlow.swift" {
            XCTAssertFalse(source.contains(".diskCache ="), "\(name) sets a request's cache")
        }
    }

    // MARK: - Source scan

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - DEBUG hard-limit override (code review r4, finding 3)

    /// The override only lowers the hard limit of a load that is already On; Off, Aether off, unknown
    /// free space and below 1 GB stay Off, and a larger value never raises the resolved limit.
    func testDebugHardLimitOnlyLowersAnOnLoad() {
        func fresh(_ i: AetherDiskCacheInputs) -> AetherDiskCache? { AetherLoadRequestFlow.fresh(base: base(), inputs: i).diskCache }
        func with(_ i: AetherDiskCacheInputs, _ bytes: Int?) -> AetherDiskCacheInputs {
            var o = i
            o.debugHardLimitBytes = bytes
            return o
        }
        XCTAssertEqual(fresh(with(inputs(.gigabytes(5)), 3_000_000)),
                       AetherDiskCache(budgetBytes: 2_250_000, hardLimitBytes: 3_000_000, forwardSegments: 2700))
        XCTAssertEqual(fresh(with(inputs(.gigabytes(10)), 20_000_000_000)), tenGB, "never raised")
        XCTAssertEqual(fresh(with(inputs(.gigabytes(10)), nil)), tenGB)
        XCTAssertEqual(fresh(with(inputs(.gigabytes(10)), 0)), tenGB)
        XCTAssertEqual(fresh(with(inputs(.gigabytes(10)), -1)), tenGB)
        for off in [inputs(.off), inputs(.maximum, aetherOn: false), inputs(.maximum, free: nil), inputs(.maximum, free: 3_900_000_000)] {
            XCTAssertNil(fresh(with(off, 3_000_000)), "\(off)")
        }
        XCTAssertEqual(AetherLoadRequestFlow.cacheLogField(AetherLoadRequestFlow.fresh(base: base(), inputs: with(inputs(.gigabytes(5)), 3_000_000)),
                                                           inputs: nil),
                       "shown:0GB,budget:2,hard:3,window:2700")
    }

    func testDebugHardLimitKeyParsing() throws {
        let suite = "AetherLoadRequestFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(AetherDiskCachePlan.debugHardLimit(defaults: defaults))
        defaults.set("3000000", forKey: AetherDiskCachePlan.debugHardLimitKey)   // as a launch argument arrives
        XCTAssertEqual(AetherDiskCachePlan.debugHardLimit(defaults: defaults), 3_000_000)
        defaults.set(0, forKey: AetherDiskCachePlan.debugHardLimitKey)
        XCTAssertNil(AetherDiskCachePlan.debugHardLimit(defaults: defaults))
        defaults.set(-5, forKey: AetherDiskCachePlan.debugHardLimitKey)
        XCTAssertNil(AetherDiskCachePlan.debugHardLimit(defaults: defaults))
        XCTAssertEqual(AetherDiskCachePlan.debugHardLimitKey, "debug.diskCacheHardLimitBytes")
    }

    /// Release cannot reach the override: every app line that names it sits inside an `#if DEBUG`
    /// region, the key appears in one file, and only `AetherDiskCacheInputs.live()` reads it. (The
    /// Release build itself is checked by the gate's string scan of the binary.)
    func testDebugHardLimitExistsOnlyInDebugBlocks() throws {
        let tokens = ["debugHardLimit", "debug.diskCacheHardLimitBytes", "applyingDebugHardLimit"]
        var keyFiles: Set<String> = []
        var readers: [String] = []
        for (name, source) in try appSources() {
            // One frame per open `#if`: whether its condition is exactly DEBUG, and whether we are past its `#else`.
            var stack: [(debug: Bool, inElse: Bool)] = []
            for (n, raw) in source.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#if ") { stack.append((line == "#if DEBUG", false)); continue }
                if line.hasPrefix("#else") || line.hasPrefix("#elseif"), let top = stack.popLast() {
                    stack.append((top.debug, true))
                    continue
                }
                if line.hasPrefix("#endif") { _ = stack.popLast(); continue }
                let inDebug = stack.contains { $0.debug && !$0.inElse }
                guard tokens.contains(where: line.contains) else { continue }
                XCTAssertTrue(inDebug, "\(name):\(n + 1) names the DEBUG override outside #if DEBUG: \(line)")
                if line.contains("\"debug.diskCacheHardLimitBytes\"") { keyFiles.insert(name) }
                if line.contains("debugHardLimit(defaults:"), !line.contains("static func") { readers.append(name) }
            }
        }
        XCTAssertEqual(keyFiles, ["AetherDiskCachePlan.swift"])
        XCTAssertEqual(readers, ["AetherDiskCachePlan.swift"], "read anywhere but AetherDiskCacheInputs.live()")
    }

    func testCacheProbeText() {
        XCTAssertEqual(AetherCacheProbe.text(nil, resident: [], requestedHard: nil, route: "none"), "creq=- croute=none cdisk=-")
        let s = AetherSessionCacheSnapshot(diskBytes: 2_900_000, peakDiskBytes: 3_000_000, hardLimitBytes: 3_000_000,
                                           evictions: 12, rejectedWrites: 0, admissionWaiting: true)
        XCTAssertEqual(AetherCacheProbe.text(s, resident: [10...40.4, 52...90.6], requestedHard: 3_000_000, route: "loopback"),
                       "creq=3000000 croute=loopback cdisk=2900000 cpeak=3000000 chard=3000000 cevict=12 crej=0 cwait=1 bfrom=10 bto=91 branges=2")
        var noHard = s
        noHard.hardLimitBytes = nil
        XCTAssertTrue(AetherCacheProbe.text(noHard, resident: [], requestedHard: nil, route: "loopback").contains("chard=- "))
        XCTAssertTrue(AetherCacheProbe.text(noHard, resident: [], requestedHard: nil, route: "loopback").hasSuffix("bfrom=- bto=- branges=0"))
    }

    /// Every Swift file under `NuvioTV/`, resolved from this file's path (simulator tests run on the host).
    private func appSources() throws -> [(name: String, source: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NuvioTV")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var out: [(String, String)] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            out.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 50, "no sources at \(root.path)")
        return out
    }
}
