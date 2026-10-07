import XCTest
@testable import NuvioTV

private final class MemoryStore: HarvestSentinelStore {
    var values: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}

/// Review r1 P2 #3: a capture that never returned turns the harvest off on the next player open.
final class HarvestCrashSentinelTests: XCTestCase {
    func testCleanCaptureLeavesHarvestOn() {
        let store = MemoryStore()
        let s = HarvestCrashSentinel(store: store)
        s.arm()
        s.clear()
        XCTAssertFalse(s.checkAtLaunch())
        XCTAssertFalse(s.isDisabled)
    }

    func testArmedFlagAtLaunchDisablesOnceAndClears() {
        let store = MemoryStore()
        let s = HarvestCrashSentinel(store: store)
        s.arm()                                   // the process dies here
        XCTAssertTrue(s.checkAtLaunch(), "a capture that never returned must disable the harvest")
        XCTAssertTrue(s.isDisabled)
        XCTAssertFalse(store.bool(forKey: HarvestCrashSentinel.inFlightKey), "the in-flight flag is consumed")
        XCTAssertFalse(s.checkAtLaunch(), "logged once: the next open does not disable again")
        XCTAssertTrue(s.isDisabled, "stays off until re-enabled")
    }

    func testReenableClearsTheVerdict() {
        let store = MemoryStore()
        let s = HarvestCrashSentinel(store: store)
        s.arm()
        s.checkAtLaunch()
        s.reenable()
        XCTAssertFalse(s.isDisabled)
        s.arm()
        s.clear()
        XCTAssertFalse(s.checkAtLaunch())
        XCTAssertFalse(s.isDisabled)
    }

    func testNothingArmedNothingDisabled() {
        let s = HarvestCrashSentinel(store: MemoryStore())
        XCTAssertFalse(s.checkAtLaunch())
        XCTAssertFalse(s.isDisabled)
    }
}
