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
        HubAccessibility.announceSoon(.started)
        let started = HubAccessibility.generation
        XCTAssertEqual(started, start + 1)
        HubAccessibility.invalidatePending()
        XCTAssertEqual(HubAccessibility.generation, started + 1, "invalidation must supersede the start announcement")
        HubAccessibility.announceSoon(.cancelled)
        XCTAssertEqual(HubAccessibility.generation, started + 2)
    }
}
