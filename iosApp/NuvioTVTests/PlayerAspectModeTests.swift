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
    // MARK: Write-back (review r1 P2 #1)

    /// Walks the pill from `start` through `presses` and returns what the profile ends up holding,
    /// writing only where the pill comes to rest (the controller's flash-clear rule).
    private func settle(start: PlayerAspectMode, presses: Int) -> (stored: PlayerAspectMode, writes: Int) {
        var mode = start
        for _ in 0..<presses { mode = mode.next }
        if let write = AspectWriteback.valueToPersist(resting: mode, persisted: start) { return (write, 1) }
        return (start, 0)
    }

    func testFitToStretchPersistsNothing() {
        let r = settle(start: .fit, presses: 3)   // fit → fill → zoom → stretch
        XCTAssertEqual(r.stored, .fit)
        XCTAssertEqual(r.writes, 0, "Fill and Zoom were only passed through")
    }

    func testFitToFillPersistsFill() {
        let r = settle(start: .fit, presses: 1)
        XCTAssertEqual(r.stored, .fill)
        XCTAssertEqual(r.writes, 1)
    }

    func testFullCycleBackToStartWritesNothing() {
        for start in [PlayerAspectMode.fit, .fill, .zoom] {
            XCTAssertEqual(settle(start: start, presses: 4).writes, 0, "\(start)")
        }
    }

    func testStretchNeverPersists() {
        for stored in [PlayerAspectMode.fit, .fill, .zoom] {
            XCTAssertNil(AspectWriteback.valueToPersist(resting: .stretch, persisted: stored))
        }
    }

    func testRestingEqualToStoredWritesNothing() {
        XCTAssertNil(AspectWriteback.valueToPersist(resting: .zoom, persisted: .zoom))
        XCTAssertEqual(AspectWriteback.valueToPersist(resting: .fit, persisted: .zoom), .fit)
    }
}
