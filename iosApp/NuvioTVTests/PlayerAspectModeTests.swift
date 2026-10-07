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
    // MARK: Write-back (review r1 P2 #1, r2 P2 #1)

    /// Walks the pill from `start` through `presses` within one flash and returns what the profile
    /// ends up holding, writing only where the pill comes to rest (the controller's flash-clear rule).
    private func settle(start: PlayerAspectMode, presses: Int) -> (stored: PlayerAspectMode, writes: Int) {
        var wb = AspectWriteback(start: start)
        var mode = start
        for _ in 0..<presses { mode = mode.next }
        let writes = rest(&wb, on: mode)
        return (wb.stored, writes)
    }

    /// The flash clears on `mode`: persist what the rule says (and echo it back through the
    /// watcher, as the settings repository does). Returns the number of writes (0 or 1).
    @discardableResult
    private func rest(_ wb: inout AspectWriteback, on mode: PlayerAspectMode, echo: Bool = true) -> Int {
        guard let write = wb.valueToPersist(resting: mode) else { return 0 }
        wb.didPersist(write)
        if echo { wb.watcherReported(write) }
        return 1
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

    /// Review r2 P2 #1: Fit, Fill (rests, written), Zoom (rests, written), Stretch at rest puts the
    /// session-start Fit back, so the rejected Zoom does not reach the profile or the phone.
    func testRestingEachModeThenStretchPersistsSessionStart() {
        var wb = AspectWriteback(start: .fit)
        XCTAssertEqual(rest(&wb, on: .fill), 1)
        XCTAssertEqual(rest(&wb, on: .zoom), 1)
        XCTAssertEqual(wb.stored, .zoom)
        XCTAssertEqual(wb.valueToPersist(resting: .stretch), .fit)
        XCTAssertEqual(rest(&wb, on: .stretch), 1)
        XCTAssertEqual(wb.stored, .fit)
        XCTAssertEqual(wb.sessionStart, .fit, "our own writes never move the session start")
    }

    /// The echo may never arrive before the next write (a conflated StateFlow): still the start.
    func testSessionStartSurvivesLateOrSkippedEchoes() {
        var wb = AspectWriteback(start: .fit)
        rest(&wb, on: .fill, echo: false)
        rest(&wb, on: .zoom, echo: false)
        wb.watcherReported(.zoom)   // conflated: Fill's echo skipped
        XCTAssertEqual(wb.sessionStart, .fit)
        XCTAssertEqual(wb.valueToPersist(resting: .stretch), .fit)
        var wb2 = AspectWriteback(start: .fit)
        rest(&wb2, on: .fill, echo: false)
        rest(&wb2, on: .zoom, echo: false)
        wb2.watcherReported(.fill)  // late echo of our first write
        wb2.watcherReported(.zoom)  // then our second
        XCTAssertEqual(wb2.sessionStart, .fit)
        XCTAssertEqual(wb2.valueToPersist(resting: .stretch), .fit)
    }

    /// A phone change to Fill mid-playback is deliberate: it becomes the session start, and a later
    /// Stretch at rest puts Fill back (not the Fit the file opened with).
    func testOutsideChangeBecomesSessionStart() {
        var wb = AspectWriteback(start: .fit)
        wb.watcherReported(.fill)
        XCTAssertEqual(wb.stored, .fill)
        XCTAssertEqual(wb.sessionStart, .fill)
        XCTAssertNil(wb.valueToPersist(resting: .stretch), "the profile already holds Fill")
        rest(&wb, on: .zoom)
        XCTAssertEqual(rest(&wb, on: .stretch), 1)
        XCTAssertEqual(wb.stored, .fill)
    }

    func testStretchWithNothingChangedWritesNothing() {
        for start in [PlayerAspectMode.fit, .fill, .zoom] {
            XCTAssertNil(AspectWriteback(start: start).valueToPersist(resting: .stretch), "\(start)")
        }
    }

    /// Any player setting change re-emits the same resize mode: not an outside change.
    func testRepeatedStoredValueIsIgnored() {
        var wb = AspectWriteback(start: .zoom)
        wb.watcherReported(.zoom)
        XCTAssertEqual(wb.sessionStart, .zoom)
        XCTAssertEqual(wb.stored, .zoom)
    }

    func testRestingEqualToStoredWritesNothing() {
        let wb = AspectWriteback(start: .zoom)
        XCTAssertNil(wb.valueToPersist(resting: .zoom))
        XCTAssertEqual(wb.valueToPersist(resting: .fit), .fit)
    }

    func testStretchIsNeverAStartValue() {
        XCTAssertEqual(AspectWriteback(start: .stretch).sessionStart, .fit)
    }
}
