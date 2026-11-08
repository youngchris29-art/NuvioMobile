import XCTest
@testable import NuvioTV

final class AddonHealthLevelTests: XCTestCase {
    func testThresholds() {
        XCTAssertEqual(AddonHealthLevel.of(latencyMs: 0, failed: false), .good)
        XCTAssertEqual(AddonHealthLevel.of(latencyMs: 999, failed: false), .good)
        XCTAssertEqual(AddonHealthLevel.of(latencyMs: 1000, failed: false), .slow)
        XCTAssertEqual(AddonHealthLevel.of(latencyMs: 2999, failed: false), .slow)
        XCTAssertEqual(AddonHealthLevel.of(latencyMs: 3000, failed: false), .bad)
    }

    func testFailedIsBadRegardlessOfLatency() {
        XCTAssertEqual(AddonHealthLevel.of(latencyMs: 10, failed: true), .bad)
        XCTAssertEqual(AddonHealthLevel.of(latencyMs: nil, failed: true), .bad)
    }

    func testNoDataHasNoLevel() {
        XCTAssertNil(AddonHealthLevel.of(latencyMs: nil, failed: false))
        XCTAssertNil(AddonHealthLevel.of(nil))
    }

    func testSnapshotOverload() {
        let s = AddonHealthSnapshot(latencyMs: 1800, failed: false, checkedAt: Date())
        XCTAssertEqual(AddonHealthLevel.of(s), .slow)
    }

    func testWording() {
        XCTAssertEqual(AddonHealthText.latency(210), "210 ms")
        XCTAssertEqual(AddonHealthText.latency(1800), "1.8 s")
        let ok = AddonHealthSnapshot(latencyMs: 210, failed: false, checkedAt: Date())
        XCTAssertEqual(AddonHealthText.rowSuffix(ok), " · 210 ms")
        XCTAssertEqual(AddonHealthText.rowSuffix(nil), "")
        XCTAssertEqual(AddonHealthText.spoken(ok), "Responds in 210 ms")
        let slow = AddonHealthSnapshot(latencyMs: 1800, failed: false, checkedAt: Date())
        XCTAssertEqual(AddonHealthText.spoken(slow), "Slow, 1.8 s")
        let bad = AddonHealthSnapshot(latencyMs: 50, failed: true, checkedAt: Date())
        XCTAssertEqual(AddonHealthText.spoken(bad), "Not responding")
        XCTAssertEqual(AddonHealthText.rowSuffix(bad), " · Not responding")
        XCTAssertEqual(AddonHealthText.lastChecked(nil), "Not checked yet")
        XCTAssertTrue(AddonHealthText.lastChecked(ok).hasSuffix(" · 210 ms"))
        XCTAssertTrue(AddonHealthText.lastChecked(bad).hasSuffix(" · Not responding"))
    }

    func testPersistenceRoundTrip() {
        let map = ["https://a.example.com/manifest.json":
                    AddonHealthSnapshot(latencyMs: 210, failed: false, checkedAt: Date(timeIntervalSince1970: 1_000))]
        XCTAssertEqual(AddonHealthStore.decode(AddonHealthStore.encode(map)), map)
        XCTAssertEqual(AddonHealthStore.decode(nil), [:])
        XCTAssertEqual(AddonHealthStore.decode(Data("junk".utf8)), [:])
    }
}
