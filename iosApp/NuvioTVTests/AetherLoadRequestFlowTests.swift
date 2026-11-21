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

    func testOnToOffMidSessionAppliesOnlyToTheNextFreshLoad() {
        var current = inputs(.gigabytes(10))
        let first = AetherLoadRequestFlow.fresh(base: base(), readInputs: { current }).request
        current = inputs(.off)   // switched Off in Settings during the session
        XCTAssertEqual(rebuild(first).diskCache, tenGB)
        XCTAssertEqual(replay(first).diskCache, tenGB)
        let next = AetherLoadRequestFlow.fresh(base: base(startSec: nil), readInputs: { current }).request
        XCTAssertNil(next.diskCache, "the next title starts with the new value")
    }

    func testOffToOnMidSessionAppliesOnlyToTheNextFreshLoad() {
        var current = inputs(.off)
        let first = AetherLoadRequestFlow.fresh(base: base(), readInputs: { current }).request
        current = inputs(.gigabytes(20))
        XCTAssertNil(rebuild(first).diskCache)
        XCTAssertNil(replay(first).diskCache)
        let next = AetherLoadRequestFlow.fresh(base: base(startSec: nil), readInputs: { current }).request
        XCTAssertEqual(next.diskCache, twentyGB)
    }

    func testFreshReadsInputsOnce() {
        var reads = 0
        let result = AetherLoadRequestFlow.fresh(base: base(), readInputs: { reads += 1; return self.inputs(.maximum) })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.inputs, inputs(.maximum))
        XCTAssertEqual(result.request.diskCache?.hardLimitBytes, 24_000_000_000)
    }

    func testReloadNeverReadsInputs() {
        // `reload` takes no inputs at all; a counting stub on the controller's property would see none.
        var reads = 0
        let stub: () -> AetherDiskCacheInputs = { reads += 1; return self.inputs(.off) }
        let first = AetherLoadRequestFlow.fresh(base: base(), readInputs: stub).request
        reads = 0
        _ = rebuild(first)
        _ = replay(first)
        XCTAssertEqual(reads, 0)
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
        XCTAssertEqual(occurrences(of: "AetherLoadRequestFlow.fresh(", in: joined), 1)
        XCTAssertEqual(occurrences(of: "AetherLoadRequestFlow.reload(", in: joined), 1)
        // Both reload paths build through `reloadRequest`.
        XCTAssertEqual(occurrences(of: "runLoad(session, reloadRequest(", in: joined), 2)
        XCTAssertEqual(occurrences(of: "runLoad(session, request)", in: joined), 1)
        // No other app file sets a cache on a request (the smoke harness never does).
        for (name, source) in try appSources() where name != "AetherLoadRequestFlow.swift" {
            XCTAssertFalse(source.contains(".diskCache ="), "\(name) sets a request's cache")
        }
    }

    // MARK: - Source scan

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
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
