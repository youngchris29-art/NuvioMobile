import XCTest
import AetherEngine
@testable import NuvioAether

/// Disk cache façade (GitHub #29, W2): the `AetherDiskCache` contract and its mapping to `LoadOptions`.
@MainActor
final class AetherDiskCacheOptionsTests: XCTestCase {
    private let url = URL(string: "http://127.0.0.1:8099/a.mkv")!
    private let gb = 1_000_000_000

    private func cache(_ budget: Int, _ hard: Int?, _ window: Int = 2700) -> AetherDiskCache {
        AetherDiskCache(budgetBytes: budget, hardLimitBytes: hard, forwardSegments: window)
    }

    /// A request with every unrelated option set, so a leak into or out of the cache fields shows.
    private func busy(_ c: AetherDiskCache?) -> AetherLoadRequest {
        var r = AetherLoadRequest(url: url, startSec: 12, headers: ["Authorization": "Bearer abcd1234"],
                                  preferredAudioLanguages: ["eng"], audioStreamIndex: 2,
                                  initialSubtitle: .preferLanguages(["eng"]),
                                  externalSubtitles: [AetherExternalSubtitle(url: url, name: "x", language: "eng")],
                                  objectAudio: .render(.l514), audioBridge: .surroundCompat, dualLayerDV: true,
                                  displayCriteriaOwner: .forMatchContent(false), systemMatchingEnabled: false,
                                  audioDelaySec: 0.25, audioShaping: AetherAudioShaping(dialogueLiftDB: 3, boostDB: 6),
                                  preferSoftwareDecode: true, logTag: "t")
        r.diskCache = c
        return r
    }

    private func assertDefaults(_ o: LoadOptions, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(o.forwardBufferSegments, file: file, line: line)
        XCTAssertNil(o.sessionCacheByteBudget, file: file, line: line)
        XCTAssertNil(o.sessionCacheHardLimitBytes, file: file, line: line)
        XCTAssertEqual(o.sessionCacheFreeReserveBytes, 0, file: file, line: line)
        XCTAssertEqual(o.softwarePacketCacheStorage, .automatic, file: file, line: line)
        XCTAssertFalse(o.retainsSessionCacheAfterStop, file: file, line: line)
    }

    func testOffSendsEngineDefaultsForEveryCacheField() {
        assertDefaults(LiveEngine.options(for: AetherLoadRequest(url: url)))
        assertDefaults(LiveEngine.options(for: busy(nil)))
    }

    func testOnChangesOnlyTheThreeCacheFields() {
        var on = LiveEngine.options(for: busy(cache(8 * gb, 10 * gb)))
        let off = LiveEngine.options(for: busy(nil))
        XCTAssertNotEqual(on, off)
        on.forwardBufferSegments = nil
        on.sessionCacheByteBudget = nil
        on.sessionCacheHardLimitBytes = nil
        XCTAssertEqual(on, off)
    }

    func testOnMapsEveryField() {
        let o = LiveEngine.options(for: busy(cache(8 * gb, 10 * gb)))
        XCTAssertEqual(o.forwardBufferSegments, 2700)
        XCTAssertEqual(o.sessionCacheByteBudget, 8 * gb)
        XCTAssertEqual(o.sessionCacheHardLimitBytes, 10 * gb)
        XCTAssertEqual(o.sessionCacheFreeReserveBytes, 0)
        XCTAssertEqual(o.softwarePacketCacheStorage, .automatic)
        XCTAssertFalse(o.retainsSessionCacheAfterStop)
    }

    func testOnNeverSetsDiskPacketStore() {
        for g in [1, 5, 10, 20, 24, 100] {
            for hard in [Optional(g * gb), nil] {
                let n = g * gb
                let o = LiveEngine.options(for: busy(cache(n - min(2 * gb, n / 4), hard)))
                XCTAssertEqual(o.softwarePacketCacheStorage, .automatic, "g=\(g)")
                XCTAssertEqual(o.sessionCacheFreeReserveBytes, 0)
                XCTAssertFalse(o.retainsSessionCacheAfterStop)
            }
        }
    }

    func testNilHardLimitStaysUnset() {
        let o = LiveEngine.options(for: busy(cache(8 * gb, nil)))
        XCTAssertNil(o.sessionCacheHardLimitBytes)
        XCTAssertEqual(o.sessionCacheByteBudget, 8 * gb)
        XCTAssertEqual(cache(8 * gb, nil).sanitized?.hardLimitBytes, nil)
    }

    func testSanitizedContractTable() {
        // Rule 1: non-positive hard limit -> Off.
        for hard in [0, -1, Int.min] { XCTAssertNil(cache(gb, hard).sanitized, "hard \(hard)") }
        // Rule 2: non-positive budget -> Off.
        for budget in [0, -1, Int.min] { XCTAssertNil(cache(budget, 10 * gb).sanitized, "budget \(budget)") }
        XCTAssertNil(cache(0, nil).sanitized)
        // Rule 1 wins over rule 2 and over everything after it.
        XCTAssertNil(cache(0, 0).sanitized)
        // Rule 3: budget above hard limit -> hard limit.
        XCTAssertEqual(cache(12 * gb, 10 * gb).sanitized, cache(10 * gb, 10 * gb))
        // Rule 4: window clamp.
        XCTAssertEqual(cache(gb, 2 * gb, 1).sanitized?.forwardSegments, 4)
        XCTAssertEqual(cache(gb, 2 * gb, 9999).sanitized?.forwardSegments, 2700)
        XCTAssertEqual(cache(gb, 2 * gb, Int.max).sanitized?.forwardSegments, 2700)
        XCTAssertEqual(cache(gb, 2 * gb, Int.min).sanitized?.forwardSegments, 4)
        XCTAssertEqual(cache(gb, 2 * gb, 4).sanitized?.forwardSegments, 4)
        // Rule 5: a nil hard limit stays nil.
        XCTAssertEqual(cache(gb, nil).sanitized, cache(gb, nil))
        // Valid input unchanged.
        XCTAssertEqual(cache(8 * gb, 10 * gb).sanitized, cache(8 * gb, 10 * gb))
        XCTAssertEqual(cache(10 * gb, 10 * gb).sanitized, cache(10 * gb, 10 * gb))
    }

    func testSanitizedIsIdempotent() {
        let budgets = [Int.min, -1, 0, 1, gb, 8 * gb, 12 * gb, Int.max]
        let hards: [Int?] = [nil, Int.min, -1, 0, 1, gb, 10 * gb, Int.max]
        let windows = [Int.min, 0, 1, 4, 10, 2700, 2701, Int.max]
        for b in budgets { for h in hards { for w in windows {
            let x = cache(b, h, w)
            XCTAssertEqual(x.sanitized?.sanitized, x.sanitized, "\(x)")
        } } }
    }

    func testSanitizedOutputIsAlwaysSafe() {
        let budgets = [Int.min, -1, 0, 1, gb, 12 * gb, Int.max]
        let hards: [Int?] = [nil, Int.min, 0, 1, gb, Int.max]
        for b in budgets { for h in hards {
            guard let s = cache(b, h, 5000).sanitized else { continue }
            XCTAssertGreaterThan(s.budgetBytes, 0)
            if let hard = s.hardLimitBytes { XCTAssertGreaterThan(hard, 0); XCTAssertLessThanOrEqual(s.budgetBytes, hard) }
            XCTAssertTrue((4...2700).contains(s.forwardSegments))
        } }
    }

    func testInvalidCacheSendsOff() {
        assertDefaults(LiveEngine.options(for: busy(cache(0, 5 * gb))))
        assertDefaults(LiveEngine.options(for: busy(cache(gb, -3))))
    }

    func testOutOfRangeValuesAreSanitizedBeforeTheEngineSeesThem() {
        let o = LiveEngine.options(for: busy(cache(12 * gb, 10 * gb, 9999)))
        XCTAssertEqual(o.sessionCacheByteBudget, 10 * gb)
        XCTAssertEqual(o.sessionCacheHardLimitBytes, 10 * gb)
        XCTAssertEqual(o.forwardBufferSegments, 2700)
    }

    func testStartingAtKeepsDiskCache() {
        let on = busy(cache(8 * gb, 10 * gb))
        XCTAssertEqual(on.starting(atSec: 0).diskCache, on.diskCache)
        XCTAssertEqual(on.starting(atSec: 600).diskCache, cache(8 * gb, 10 * gb))
        XCTAssertNil(busy(nil).starting(atSec: 0).diskCache)
    }

    func testDefaultRequestHasNoDiskCache() {
        XCTAssertNil(AetherLoadRequest(url: url).diskCache)
    }

    func testCacheLogLineOnlyForLoopbackRoute() {
        func status(_ route: SessionCacheRoute) -> SessionCacheStatus {
            SessionCacheStatus(route: route, capability: .active, requestedBudgetBytes: 8 * gb,
                               volumeSafetyLimitBytes: nil, baseEffectiveBudgetBytes: 8 * gb,
                               playbackSafeFloorBytes: 0, effectiveBudgetBytes: 8_000_000_000,
                               currentResidentBytes: 3_000_000_000, currentForwardBytes: 2_000_000_000,
                               forwardWindowSegments: 2700, backwardWindowSegments: 20, producerParked: true,
                               evictionCount: 7, hardWindowFloorExceeded: false, cleanupReason: nil,
                               cleanupResult: .notRun, lastFailure: nil, hardLimitBytes: 10_000_000_000,
                               stagingBytes: 44_000_000, rejectedDiskWrites: 2, diskAdmissionWaiting: false)
        }
        XCTAssertNil(LiveEngine.cacheLogLine(status(.none)))
        XCTAssertNil(LiveEngine.cacheLogLine(status(.nativeRemoteHLS)))
        XCTAssertEqual(LiveEngine.cacheLogLine(status(.loopbackFMP4)),
                       "[AetherCache] budget=8000 hard=10000 disk=3044 staging=44 fwd=2000 parked=1 waiting=0 rejected=2 evictions=7 failure=-")
    }
}
