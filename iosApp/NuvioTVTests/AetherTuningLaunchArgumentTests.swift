import XCTest
@testable import NuvioTV

final class AetherTuningLaunchArgumentTests: XCTestCase {
    private var suiteName = ""
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AetherTuningLaunchArgumentTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    func testStringYesReadsTrue() {
        suite.set("YES", forKey: "k")
        XCTAssertTrue(AetherTuning.bool("k", default: false, defaults: suite))
    }

    func testStringNoReadsFalse() {
        suite.set("NO", forKey: "k")
        XCTAssertFalse(AetherTuning.bool("k", default: true, defaults: suite))
    }

    func testStringOneReadsTrue() {
        suite.set("1", forKey: "k")
        XCTAssertTrue(AetherTuning.bool("k", default: false, defaults: suite))
    }

    func testStoredBoolFalseBeatsTrueDefault() {
        suite.set(false, forKey: "k")
        XCTAssertFalse(AetherTuning.bool("k", default: true, defaults: suite))
    }

    func testMissingKeyKeepsDefault() {
        XCTAssertTrue(AetherTuning.bool("missing", default: true, defaults: suite))
        XCTAssertFalse(AetherTuning.bool("missing", default: false, defaults: suite))
    }

    func testEngineEnabledReadsStringYes() {
        suite.set("YES", forKey: PlayerTuning.aetherEngineKey)
        XCTAssertTrue(AetherTuning.isEngineEnabled(defaults: suite))
    }
}
