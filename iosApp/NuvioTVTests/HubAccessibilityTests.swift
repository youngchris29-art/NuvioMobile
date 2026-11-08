import XCTest
@testable import NuvioTV

/// Add-ons hub v2: the VoiceOver wording Christian's check on the Apple TV asked for (2026-11-08).
final class HubAccessibilityTests: XCTestCase {
    func testSidebarLabelCarriesTheValueAndTheCurrentSection() {
        XCTAssertEqual(HubAccessibility.sidebarLabel(title: "Installed", value: "8", isSelected: true),
                       "Installed, 8, current section")
        XCTAssertEqual(HubAccessibility.sidebarLabel(title: "Catalogs", value: "40 of 115", isSelected: false),
                       "Catalogs, 40 of 115")
        XCTAssertEqual(HubAccessibility.sidebarLabel(title: "Install add-on", value: "", isSelected: false),
                       "Install add-on")
        XCTAssertEqual(HubAccessibility.sidebarLabel(title: "Debrid", value: "  ", isSelected: true),
                       "Debrid, current section")
    }

    func testRowValueLeadsWithMovingWhileLifted() {
        XCTAssertEqual(HubAccessibility.rowValue("On, torrentio.strem.fun", isMoving: true), "Moving, On, torrentio.strem.fun")
        XCTAssertEqual(HubAccessibility.rowValue("Off, Cinemeta", isMoving: false), "Off, Cinemeta")
    }

    func testMoveAnnouncements() {
        XCTAssertEqual(HubAccessibility.announcement(.started),
                       "Moving. Press Up or Down, then Select to drop it, or Menu to cancel.")
        XCTAssertEqual(HubAccessibility.announcement(.committed), "Moved.")
        XCTAssertEqual(HubAccessibility.announcement(.cancelled), "Move cancelled.")
    }
}
