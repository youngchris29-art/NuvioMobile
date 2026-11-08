import XCTest
@testable import NuvioTV

/// Add-ons hub v2: the VoiceOver wording Christian's check on the Apple TV asked for (2026-11-08).
/// Expectations are built from the active localization (review VO-r1: the test language is not
/// pinned), so the tests check the structure, not the English text.
final class HubAccessibilityTests: XCTestCase {
    private let current = String(localized: "current section")
    private let moving = String(localized: "Moving")

    func testSidebarLabelCarriesTheValueAndTheCurrentSection() {
        XCTAssertEqual(HubAccessibility.sidebarLabel(title: "Installed", value: "8", isSelected: true),
                       "Installed, 8, \(current)")
        XCTAssertEqual(HubAccessibility.sidebarLabel(title: "Catalogs", value: "40 of 115", isSelected: false),
                       "Catalogs, 40 of 115")
        XCTAssertEqual(HubAccessibility.sidebarLabel(title: "Install add-on", value: "", isSelected: false),
                       "Install add-on")
        XCTAssertEqual(HubAccessibility.sidebarLabel(title: "Debrid", value: "  ", isSelected: true),
                       "Debrid, \(current)")
    }

    func testRowValueLeadsWithMovingWhileLifted() {
        XCTAssertEqual(HubAccessibility.rowValue("On, torrentio.strem.fun", isMoving: true), "\(moving), On, torrentio.strem.fun")
        XCTAssertEqual(HubAccessibility.rowValue("Off, Cinemeta", isMoving: false), "Off, Cinemeta")
    }

    func testMoveAnnouncementsAreDistinctAndLocalized() {
        let started = HubAccessibility.announcement(.started)
        let committed = HubAccessibility.announcement(.committed)
        let cancelled = HubAccessibility.announcement(.cancelled)
        XCTAssertEqual(started, String(localized: "Moving. Press Up or Down, then Select to drop it, or Menu to cancel."))
        XCTAssertEqual(committed, String(localized: "Moved."))
        XCTAssertEqual(cancelled, String(localized: "Move cancelled."))
        XCTAssertEqual(Set([started, committed, cancelled]).count, 3)
    }

    /// Review VO-r1: every scheduled announcement and every invalidation moves the generation on,
    /// so an announcement scheduled before them no longer matches and is dropped when its delay
    /// ends.
    @MainActor
    func testSchedulingAndInvalidatingSupersedePendingAnnouncements() {
        let start = HubAccessibility.generation
        HubAccessibility.announceSoon(.started, rowKey: "row:a")
        let started = HubAccessibility.generation
        XCTAssertEqual(started, start + 1)
        HubAccessibility.invalidatePending()
        XCTAssertEqual(HubAccessibility.generation, started + 1, "invalidation must supersede the start announcement")
        HubAccessibility.announceSoon(.cancelled, rowKey: "row:a")
        XCTAssertEqual(HubAccessibility.generation, started + 2)
    }

    /// Review VO-r4: focus landing on the announced row (the hand-back) keeps the announcement;
    /// landing on another row (Installed `row:` or Catalogs `catalog:` keys) drops it.
    @MainActor
    func testFocusOnAnotherRowDropsTheWaitingAnnouncement() {
        HubAccessibility.announceSoon(.committed, rowKey: "row:a")
        let scheduled = HubAccessibility.generation
        HubAccessibility.focusLanded(on: "row:a")
        XCTAssertEqual(HubAccessibility.generation, scheduled, "the hand-back onto the moved row must keep it")
        XCTAssertEqual(HubAccessibility.pendingRowKey, "row:a")
        HubAccessibility.focusLanded(on: "row:b")
        XCTAssertEqual(HubAccessibility.generation, scheduled + 1, "focus on another add-on must drop it")
        XCTAssertNil(HubAccessibility.pendingRowKey)

        HubAccessibility.announceSoon(.cancelled, rowKey: "catalog:x")
        let catalogScheduled = HubAccessibility.generation
        HubAccessibility.focusLanded(on: "catalog:y")
        XCTAssertEqual(HubAccessibility.generation, catalogScheduled + 1, "focus on another catalog must drop it")
        // Nothing waiting: a landing changes nothing.
        HubAccessibility.focusLanded(on: "catalog:z")
        XCTAssertEqual(HubAccessibility.generation, catalogScheduled + 1)
    }
}
