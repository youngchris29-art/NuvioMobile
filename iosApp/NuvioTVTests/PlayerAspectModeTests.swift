import XCTest
import SharedCore
@testable import NuvioTV

final class PlayerAspectModeTests: XCTestCase {
    func testCycleOrderAndWrap() {
        XCTAssertEqual(PlayerAspectMode.fit.next, .fill)
        XCTAssertEqual(PlayerAspectMode.fill.next, .zoom)
        XCTAssertEqual(PlayerAspectMode.zoom.next, .stretch)
        XCTAssertEqual(PlayerAspectMode.stretch.next, .fit)
    }

    /// C10/C11: every mode writes the same three properties; `-1` keeps the container aspect,
    /// Zoom is panscan 0.5, Stretch forces 16:9, `video-zoom` stays 0.
    func testPropsTable() {
        XCTAssertEqual(PlayerAspectMode.fit.mpvProps, MPVAspectProps(aspectOverride: "-1", panscan: 0, videoZoom: 0))
        XCTAssertEqual(PlayerAspectMode.fill.mpvProps, MPVAspectProps(aspectOverride: "-1", panscan: 1, videoZoom: 0))
        XCTAssertEqual(PlayerAspectMode.zoom.mpvProps, MPVAspectProps(aspectOverride: "-1", panscan: 0.5, videoZoom: 0))
        XCTAssertEqual(PlayerAspectMode.stretch.mpvProps, MPVAspectProps(aspectOverride: "16:9", panscan: 0, videoZoom: 0))
        for mode in PlayerAspectMode.allCases {
            XCTAssertNotEqual(mode.mpvProps.aspectOverride, "no", "\(mode): `no` squashes anamorphic files")
        }
    }

    func testSyncedNames() {
        XCTAssertEqual(PlayerAspectMode.fit.syncedName, "Fit")
        XCTAssertEqual(PlayerAspectMode.fill.syncedName, "Fill")
        XCTAssertEqual(PlayerAspectMode.zoom.syncedName, "Zoom")
        XCTAssertNil(PlayerAspectMode.stretch.syncedName)
    }

    /// C9: Stretch is session-only, so the start mode only ever comes from the synced value.
    func testInitialFromSyncedName() {
        XCTAssertEqual(PlayerAspectMode.initial(syncedName: "Fit"), .fit)
        XCTAssertEqual(PlayerAspectMode.initial(syncedName: "Fill"), .fill)
        XCTAssertEqual(PlayerAspectMode.initial(syncedName: "Zoom"), .zoom)
        XCTAssertEqual(PlayerAspectMode.initial(syncedName: "Stretch"), .fit)
        XCTAssertEqual(PlayerAspectMode.initial(syncedName: "bogus"), .fit)
        XCTAssertEqual(PlayerAspectMode.initial(syncedName: nil), .fit)
    }

    /// The Swift side reads the Kotlin `PlayerResizeMode` through `.name`; it must round-trip.
    func testKotlinEnumNamesRoundTrip() {
        XCTAssertEqual(PlayerAspectMode.initial(syncedName: PlayerResizeMode.fit.name), .fit)
        XCTAssertEqual(PlayerAspectMode.initial(syncedName: PlayerResizeMode.fill.name), .fill)
        XCTAssertEqual(PlayerAspectMode.initial(syncedName: PlayerResizeMode.zoom.name), .zoom)
    }

    func testLabels() {
        XCTAssertEqual(PlayerAspectMode.allCases.map(\.label), ["Fit", "Fill", "Zoom", "Stretch"])
    }
}
