import XCTest
import NuvioAether
@testable import NuvioTV

/// GitHub #29: `AetherDiskCachePlan`, the one decision behind Settings › Player › Buffering › Disk
/// Cache and the fresh load's cache fields. The label and the hard limit come from the same G, so the
/// row never shows more than the engine is told to allow.
@MainActor
final class AetherDiskCachePlanTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private let frees: [Int64?] = [nil, 0, 3_900_000_000, 40_000_000_000, 98_000_000_000, 2_000_000_000_000]

    // MARK: - Choice and key

    func testRawValueRoundTrip() {
        for raw in [0, 5, 10, 20, -1] {
            XCTAssertEqual(AetherDiskCacheChoice(rawValue: raw).rawValue, raw)
        }
        XCTAssertEqual(AetherDiskCacheChoice(rawValue: 0), .off)
        XCTAssertEqual(AetherDiskCacheChoice(rawValue: 10), .gigabytes(10))
        XCTAssertEqual(AetherDiskCacheChoice(rawValue: -1), .maximum)
        XCTAssertEqual(AetherDiskCacheChoice.all, [.off, .gigabytes(5), .gigabytes(10), .gigabytes(20), .maximum])
        XCTAssertEqual(PlayerTuning.diskCacheGBKey, "player.diskCacheGB")
    }

    func testUnknownRawValuesReadAsOff() {
        for raw in [1, 15, 30, 50, -2, Int.max, Int.min] {
            XCTAssertEqual(AetherDiskCacheChoice(rawValue: raw), .off, "\(raw)")
        }
    }

    func testMissingKeyReadsOff() throws {
        let suite = "AetherDiskCachePlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AetherTuning.diskCacheChoice(defaults: defaults), .off)
        defaults.set(-1, forKey: PlayerTuning.diskCacheGBKey)
        XCTAssertEqual(AetherTuning.diskCacheChoice(defaults: defaults), .maximum)
        defaults.set(20, forKey: PlayerTuning.diskCacheGBKey)
        XCTAssertEqual(AetherTuning.diskCacheChoice(defaults: defaults), .gigabytes(20))
        defaults.set(7, forKey: PlayerTuning.diskCacheGBKey)
        XCTAssertEqual(AetherTuning.diskCacheChoice(defaults: defaults), .off)
    }

    // MARK: - Off and unknown

    func testAetherOffSendsNilForEveryChoice() {
        for choice in AetherDiskCacheChoice.all {
            for free in frees {
                let r = AetherDiskCachePlan.resolve(choice, aetherOn: false, freeBytes: free)
                XCTAssertNil(r.cache, "\(choice) free=\(String(describing: free))")
                XCTAssertNil(r.shownGB, "\(choice) free=\(String(describing: free))")
                // The label reads as if on (the row is hidden while Aether is off).
                XCTAssertEqual(r.label, AetherDiskCachePlan.resolve(choice, aetherOn: true, freeBytes: free).label)
            }
        }
    }

    func testOffSendsNilForEveryFree() {
        for free in frees + [-1] {
            let r = AetherDiskCachePlan.resolve(.off, aetherOn: true, freeBytes: free)
            XCTAssertEqual(r, AetherDiskCacheResolution(shownGB: nil, cache: nil, label: .off))
        }
    }

    func testUnknownFreeSendsNilAndClaimsNoSize() {
        for choice in AetherDiskCacheChoice.all where choice != .off {
            let r = AetherDiskCachePlan.resolve(choice, aetherOn: true, freeBytes: nil)
            XCTAssertNil(r.cache)
            XCTAssertNil(r.shownGB)
            XCTAssertEqual(r.label, .unmeasured(choice))
        }
    }

    func testNegativeFreeIsUnknown() {
        XCTAssertNil(AetherDiskCachePlan.quarterOfFree(-1))
        for choice in AetherDiskCacheChoice.all {
            XCTAssertEqual(AetherDiskCachePlan.resolve(choice, aetherOn: true, freeBytes: -1),
                           AetherDiskCachePlan.resolve(choice, aetherOn: true, freeBytes: nil))
        }
    }

    func testBelowOneGigabyteActsOff() {
        for free: Int64 in [3_900_000_000, 3_999_999_999] {
            for choice in AetherDiskCacheChoice.all where choice != .off {
                let r = AetherDiskCachePlan.resolve(choice, aetherOn: true, freeBytes: free)
                XCTAssertNil(r.cache, "\(choice) free=\(free)")
                XCTAssertNil(r.shownGB)
                XCTAssertEqual(r.label, .notEnoughSpace)
            }
        }
        let one = AetherDiskCachePlan.resolve(.maximum, aetherOn: true, freeBytes: 4_000_000_000)
        XCTAssertEqual(one.shownGB, 1)
        XCTAssertEqual(one.cache?.hardLimitBytes, 1_000_000_000)
        XCTAssertEqual(one.cache?.budgetBytes, 750_000_000)
        XCTAssertEqual(one.label, .upTo(1))
    }

    // MARK: - Measured numbers

    func testTesterBox98GB() {
        let free: Int64 = 98_000_000_000
        let max = AetherDiskCachePlan.resolve(.maximum, aetherOn: true, freeBytes: free)
        XCTAssertEqual(max.shownGB, 24)
        XCTAssertEqual(max.cache, AetherDiskCache(budgetBytes: 22_000_000_000, hardLimitBytes: 24_000_000_000, forwardSegments: 2700))
        XCTAssertEqual(max.label, .upTo(24))
        XCTAssertEqual(max.label.text, "Up to 24 GB")
        let twenty = AetherDiskCachePlan.resolve(.gigabytes(20), aetherOn: true, freeBytes: free)
        XCTAssertEqual(twenty.cache, AetherDiskCache(budgetBytes: 18_000_000_000, hardLimitBytes: 20_000_000_000, forwardSegments: 2700))
        XCTAssertEqual(twenty.label, .gigabytes(20))
        let ten = AetherDiskCachePlan.resolve(.gigabytes(10), aetherOn: true, freeBytes: free)
        XCTAssertEqual(ten.cache, AetherDiskCache(budgetBytes: 8_000_000_000, hardLimitBytes: 10_000_000_000, forwardSegments: 2700))
        let five = AetherDiskCachePlan.resolve(.gigabytes(5), aetherOn: true, freeBytes: free)
        XCTAssertEqual(five.cache, AetherDiskCache(budgetBytes: 3_750_000_000, hardLimitBytes: 5_000_000_000, forwardSegments: 2700))
        XCTAssertEqual(five.label, .gigabytes(5))
    }

    func testFixedAboveCeilingClampsAndSaysUpTo() {
        let r = AetherDiskCachePlan.resolve(.gigabytes(20), aetherOn: true, freeBytes: 40_000_000_000)
        XCTAssertEqual(r.shownGB, 10)
        XCTAssertEqual(r.cache?.hardLimitBytes, 10_000_000_000)
        XCTAssertEqual(r.cache?.budgetBytes, 8_000_000_000)
        XCTAssertEqual(r.label, .upTo(10))
    }

    func testLabelFloorsToTheEnforcedLimit() {
        let r = AetherDiskCachePlan.resolve(.maximum, aetherOn: true, freeBytes: 99_990_000_000)
        XCTAssertEqual(r.label, .upTo(24))
        XCTAssertEqual(r.cache?.hardLimitBytes, 24_000_000_000)
        XCTAssertEqual(r.cache?.budgetBytes, 22_000_000_000)
    }

    func testQuarterMatchesEngineIntegerDivision() {
        for free: Int64 in [0, 1, 3, 5, 7, 98_000_000_001, 98_000_000_003, 99_999_999_999] {
            XCTAssertEqual(AetherDiskCachePlan.quarterOfFree(free), free / 4)
        }
        XCTAssertEqual(AetherDiskCachePlan.headroom(for: 24_000_000_000), 2_000_000_000)
        XCTAssertEqual(AetherDiskCachePlan.headroom(for: 5_000_000_000), 1_250_000_000)
    }

    // MARK: - Grids

    /// Free 0…200 GB in 0.25 GB steps plus each whole-GB-of-a-quarter boundary ± 1 byte.
    private var gridFrees: [Int64] {
        var out: [Int64] = stride(from: Int64(0), through: 200 * gb, by: Int(gb / 4)).map { $0 }
        for g in Int64(1)...50 {
            let boundary = 4 * g * gb
            out += [boundary - 1, boundary, boundary + 1]
        }
        return out
    }

    func testLabelEqualsEnforcedLimitGrid() {
        for free in gridFrees {
            for choice in AetherDiskCacheChoice.all {
                let r = AetherDiskCachePlan.resolve(choice, aetherOn: true, freeBytes: free, enforcement: .hardLimit)
                let context = "\(choice) free=\(free)"
                XCTAssertEqual(r.cache == nil, r.shownGB == nil, context)
                guard let cache = r.cache, let shown = r.shownGB else { continue }
                let hard = Int64(cache.hardLimitBytes ?? -1)
                XCTAssertEqual(hard, Int64(shown) * gb, context)
                XCTAssertTrue(r.label == .gigabytes(shown) || r.label == .upTo(shown), context)
                if case .gigabytes(let g) = choice { XCTAssertLessThanOrEqual(shown, g, context) }
                XCTAssertLessThanOrEqual(hard, free / 4, context)
                XCTAssertEqual(Int64(cache.budgetBytes), hard - AetherDiskCachePlan.headroom(for: hard), context)
                XCTAssertGreaterThanOrEqual(Int64(cache.budgetBytes) * 4, hard * 3, context)
                XCTAssertEqual(cache.forwardSegments, 2700, context)
                XCTAssertEqual(cache.sanitized, cache, "the plan never produces an input sanitize changes: \(context)")
            }
        }
    }

    func testBudgetOnlyModeGrid() {
        for free in gridFrees {
            for choice in AetherDiskCacheChoice.all {
                let r = AetherDiskCachePlan.resolve(choice, aetherOn: true, freeBytes: free, enforcement: .budgetOnly)
                let context = "\(choice) free=\(free)"
                XCTAssertEqual(r.cache == nil, r.shownGB == nil, context)
                guard let cache = r.cache, let shown = r.shownGB else { continue }
                XCTAssertNil(cache.hardLimitBytes, context)
                XCTAssertEqual(r.label, .about(shown), context)
                let n = Int64(shown) * gb
                XCTAssertEqual(Int64(cache.budgetBytes), n - AetherDiskCachePlan.headroom(for: n), context)
            }
        }
        XCTAssertEqual(AetherDiskCachePlan.enforcement, .hardLimit, "decision R: the hard limit ships")
    }

    // MARK: - Menu and row

    func testOptionsHideSizesAboveCeilingButKeepStored() {
        XCTAssertEqual(AetherDiskCachePlan.options(stored: .off, freeBytes: 40_000_000_000),
                       [.off, .gigabytes(5), .gigabytes(10), .maximum])
        XCTAssertEqual(AetherDiskCachePlan.options(stored: .off, freeBytes: 39_900_000_000),
                       [.off, .gigabytes(5), .maximum])
        XCTAssertEqual(AetherDiskCachePlan.options(stored: .gigabytes(20), freeBytes: 39_900_000_000),
                       [.off, .gigabytes(5), .gigabytes(20), .maximum])
        XCTAssertEqual(AetherDiskCachePlan.options(stored: .gigabytes(20), freeBytes: 40_000_000_000),
                       [.off, .gigabytes(5), .gigabytes(10), .gigabytes(20), .maximum])
        XCTAssertEqual(AetherDiskCachePlan.options(stored: .maximum, freeBytes: 0), [.off, .maximum])
        // Before the first reading every size is offered (none can be ruled out yet).
        XCTAssertEqual(AetherDiskCachePlan.options(stored: .off, freeBytes: nil), AetherDiskCacheChoice.all)
        for free in frees {
            for stored in AetherDiskCacheChoice.all {
                XCTAssertTrue(AetherDiskCachePlan.options(stored: stored, freeBytes: free).contains(stored))
            }
        }
    }

    func testRowVisibleOnlyWithAether() {
        XCTAssertFalse(AetherDiskCachePlan.rowVisible(aetherOn: false))
        XCTAssertTrue(AetherDiskCachePlan.rowVisible(aetherOn: true))
    }

    func testLabelTextsEnglish() {
        XCTAssertEqual(AetherDiskCacheLabel.upTo(24).text, "Up to 24 GB")
        XCTAssertEqual(AetherDiskCacheLabel.gigabytes(5).text, "5 GB")
        XCTAssertEqual(AetherDiskCacheLabel.unmeasured(.maximum).text, "Maximum")
        XCTAssertEqual(AetherDiskCacheLabel.unmeasured(.gigabytes(10)).text, "10 GB")
        XCTAssertEqual(AetherDiskCacheLabel.notEnoughSpace.text, "Not enough free space")
        XCTAssertEqual(AetherDiskCacheLabel.off.text, "Off")
        XCTAssertEqual(AetherDiskCachePlan.itemName(.off), "Off")
        XCTAssertEqual(AetherDiskCachePlan.itemName(.gigabytes(20)), "20 GB")
        XCTAssertEqual(AetherDiskCachePlan.itemName(.maximum), "Maximum")
    }

    // MARK: - Probe

    func testProbeReadsTheEngineKeyOnTmp() throws {
        let probed = try XCTUnwrap(TemporaryVolumeSpace.availableBytes())
        let direct = try XCTUnwrap(URL(fileURLWithPath: NSTemporaryDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
        XCTAssertLessThanOrEqual(abs(probed - Int64(direct)), 64 * 1024 * 1024, "probe \(probed) vs direct \(direct)")
        XCTAssertNil(TemporaryVolumeSpace.availableBytes(at: "/nonexistent-\(UUID().uuidString)/x"))
    }
}
