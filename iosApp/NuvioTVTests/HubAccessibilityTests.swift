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

    // MARK: - Settled announcements (review VO-r1…r6)

    @MainActor
    private func spoken(after work: () -> Void) -> [String] {
        var said: [String] = []
        let original = HubAccessibility.post
        HubAccessibility.post = { said.append($0) }
        defer { HubAccessibility.post = original }
        work()
        let settled = expectation(description: "settle delay passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + HubAccessibility.settleDelay + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        return said
    }

    @MainActor
    func testAnnouncementIsSpokenWhenStillCurrent() {
        let said = spoken { HubAccessibility.announceWhenSettled(.started) { true } }
        XCTAssertEqual(said, [HubAccessibility.announcement(.started)])
    }

    /// Focus or state changed before it fired (another row, the sidebar, the tab bar, a page,
    /// the move already over): nothing is spoken.
    @MainActor
    func testAnnouncementIsDroppedWhenNoLongerCurrent() {
        var stillCurrent = true
        let said = spoken {
            HubAccessibility.announceWhenSettled(.committed) { stillCurrent }
            stillCurrent = false
        }
        XCTAssertTrue(said.isEmpty)
    }

    /// A newer announcement supersedes an older one: a quick cancel after a start says only the
    /// cancel.
    @MainActor
    func testANewerAnnouncementSupersedesAnOlderOne() {
        let said = spoken {
            HubAccessibility.announceWhenSettled(.started) { true }
            HubAccessibility.announceWhenSettled(.cancelled) { true }
        }
        XCTAssertEqual(said, [HubAccessibility.announcement(.cancelled)])
    }

    /// The pane that scheduled it went away: nothing is spoken.
    @MainActor
    func testInvalidationDropsAWaitingAnnouncement() {
        let said = spoken {
            HubAccessibility.announceWhenSettled(.committed) { true }
            HubAccessibility.invalidatePending()
        }
        XCTAssertTrue(said.isEmpty)
    }
}
