import XCTest
@testable import NuvioTV

/// Player P3: the seek-preview mode switch (Settings › Player › Seek Preview Pictures).
final class SeekPreviewModeTests: XCTestCase {
    func testParseDefaultsToHarvest() {
        XCTAssertEqual(SeekPreviewMode.defaultMode, .harvest)
        XCTAssertEqual(SeekPreviewMode.parse(nil), .harvest)
        XCTAssertEqual(SeekPreviewMode.parse(""), .harvest)
        XCTAssertEqual(SeekPreviewMode.parse("garbage"), .harvest)
        XCTAssertEqual(SeekPreviewMode.parse("OFF"), .harvest)   // raw values are lowercase only
    }

    func testEveryValueRoundTrips() {
        for mode in SeekPreviewMode.allCases {
            XCTAssertEqual(SeekPreviewMode.parse(mode.rawValue), mode)
        }
        XCTAssertEqual(SeekPreviewMode.allCases.map(\.rawValue), ["off", "harvest", "decode"])
        XCTAssertEqual(SeekPreviewMode.defaultsKey, "debug.seekPreviewMode")
    }

    func testAllows() {
        XCTAssertFalse(SeekPreviewMode.off.allowsIFrames)
        XCTAssertFalse(SeekPreviewMode.off.allowsHarvest)
        XCTAssertFalse(SeekPreviewMode.off.allowsDecode)
        XCTAssertTrue(SeekPreviewMode.harvest.allowsIFrames)
        XCTAssertTrue(SeekPreviewMode.harvest.allowsHarvest)
        XCTAssertFalse(SeekPreviewMode.harvest.allowsDecode)
        XCTAssertTrue(SeekPreviewMode.decode.allowsIFrames)
        XCTAssertTrue(SeekPreviewMode.decode.allowsHarvest)
        XCTAssertTrue(SeekPreviewMode.decode.allowsDecode)
    }

    func testCurrentReadsDefaults() throws {
        let name = "SeekPreviewModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SeekPreviewMode.current(defaults), .harvest)
        defaults.set("off", forKey: SeekPreviewMode.defaultsKey)
        XCTAssertEqual(SeekPreviewMode.current(defaults), .off)
        defaults.set("decode", forKey: SeekPreviewMode.defaultsKey)
        XCTAssertEqual(SeekPreviewMode.current(defaults), .decode)
        defaults.set("nonsense", forKey: SeekPreviewMode.defaultsKey)
        XCTAssertEqual(SeekPreviewMode.current(defaults), .harvest)
    }

    func testDisplayNamesAreDistinct() {
        let names = SeekPreviewMode.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(SeekPreviewMode.harvest.displayName, "Watched Parts")
        XCTAssertEqual(SeekPreviewMode.decode.displayName, "Whole Video")
        XCTAssertEqual(SeekPreviewMode.off.displayName, "Off")
    }
    // MARK: BUG-168 native half (Native I-frame Scan, off by default)

    func testNativeIFramesNeedTheScanRow() {
        XCTAssertEqual(SeekPreviewMode.nativeIFrameScanKey, "debug.nativeIFrameScan")
        XCTAssertFalse(SeekPreviewMode.nativeIFrameScanDefault)
        for mode in SeekPreviewMode.allCases {
            XCTAssertFalse(mode.allowsNativeIFrames(scanEnabled: false), "\(mode)")
        }
        XCTAssertFalse(SeekPreviewMode.off.allowsNativeIFrames(scanEnabled: true))   // Off still wins
        XCTAssertTrue(SeekPreviewMode.harvest.allowsNativeIFrames(scanEnabled: true))
        XCTAssertTrue(SeekPreviewMode.decode.allowsNativeIFrames(scanEnabled: true))
        // The mpv switches do not read the row.
        XCTAssertTrue(SeekPreviewMode.harvest.allowsHarvest)
        XCTAssertTrue(SeekPreviewMode.decode.allowsDecode)
    }

    func testNativeIFramesReadDefaults() throws {
        let name = "SeekPreviewModeTests.native.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // Unset: the default mode (harvest) but no rendition.
        XCTAssertFalse(SeekPreviewMode.nativeIFrameScanEnabled(defaults))
        XCTAssertFalse(SeekPreviewMode.currentAllowsNativeIFrames(defaults))
        defaults.set(true, forKey: SeekPreviewMode.nativeIFrameScanKey)
        XCTAssertTrue(SeekPreviewMode.currentAllowsNativeIFrames(defaults))
        defaults.set("off", forKey: SeekPreviewMode.defaultsKey)
        XCTAssertFalse(SeekPreviewMode.currentAllowsNativeIFrames(defaults))
        defaults.set("decode", forKey: SeekPreviewMode.defaultsKey)
        defaults.set(false, forKey: SeekPreviewMode.nativeIFrameScanKey)
        XCTAssertFalse(SeekPreviewMode.currentAllowsNativeIFrames(defaults))
    }
}
