import XCTest
@testable import NuvioTV

private final class MemoryStore: HarvestSentinelStore {
    var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
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
        HarvestCrashSentinel(store: store, token: "earlier-process").arm()   // that process dies here
        XCTAssertTrue(s.checkAtLaunch(), "a capture that never returned must disable the harvest")
        XCTAssertTrue(s.isDisabled)
        XCTAssertNil(store.string(forKey: HarvestCrashSentinel.inFlightKey), "the in-flight flag is consumed")
        XCTAssertFalse(s.checkAtLaunch(), "logged once: the next open does not disable again")
        XCTAssertTrue(s.isDisabled, "stays off until re-enabled")
    }

    func testReenableClearsTheVerdict() {
        let store = MemoryStore()
        let s = HarvestCrashSentinel(store: store)
        HarvestCrashSentinel(store: store, token: "earlier-process").arm()
        XCTAssertTrue(s.checkAtLaunch())
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

    /// Review r2 P3 #2: a player opening while another controller of this process is mid-capture
    /// (next-episode autoplay, Replay) is not a crash, and the live flag is left for its clear.
    func testSameProcessFlagIsNotACrash() {
        let store = MemoryStore()
        let live = HarvestCrashSentinel(store: store)
        live.arm()
        let opening = HarvestCrashSentinel(store: store)
        XCTAssertFalse(opening.checkAtLaunch())
        XCTAssertFalse(opening.isDisabled)
        XCTAssertEqual(store.string(forKey: HarvestCrashSentinel.inFlightKey), HarvestCrashSentinel.processToken)
        live.clear()
        XCTAssertNil(store.string(forKey: HarvestCrashSentinel.inFlightKey))
    }

    func testForeignTokenIsACrash() {
        let store = MemoryStore()
        store.set("another-process" as Any?, forKey: HarvestCrashSentinel.inFlightKey)
        XCTAssertTrue(HarvestCrashSentinel(store: store).checkAtLaunch())
    }

    func testDefaultTokenIsTheProcessToken() {
        XCTAssertEqual(HarvestCrashSentinel(store: MemoryStore()).token, HarvestCrashSentinel.processToken)
    }
}
