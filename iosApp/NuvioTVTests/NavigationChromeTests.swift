import XCTest
import UIKit
@testable import NuvioTV

/// Home Stage & Strip (H9, FEAT-45; P4 spec §7.2): the navigation chrome's mode and visibility
/// resolution, the one-time `sidebar_style` migration, the Always Visible inset math and the
/// clearance it guarantees, and the DEBUG content-gate knob. Every defaults test uses its own
/// throwaway `UserDefaults` suite (its persistent domain is the suite name), never `.standard`.
@MainActor
final class NavigationChromeTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let suite = "NavigationChromeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }

    // MARK: Keys and resolution

    func testKeysAreTheDeviceLocalOnes() {
        XCTAssertEqual(NavigationChrome.styleKey, "sidebar_style", "kept from FEAT-30 so the stored choice survives")
        XCTAssertEqual(NavigationChrome.railVisibilityKey, "rail_visibility")
        XCTAssertEqual(NavigationChrome.legacySidebarValue, "sidebar")
        XCTAssertEqual(NavigationChrome.Style.tabs.rawValue, "tabs")
        XCTAssertEqual(NavigationChrome.Style.rail.rawValue, "rail")
        XCTAssertEqual(NavigationChrome.RailVisibility.always.rawValue, "always")
        XCTAssertEqual(NavigationChrome.RailVisibility.whileBrowsing.rawValue, "browsing")
    }

    func testStyleResolution() {
        XCTAssertEqual(NavigationChrome.style(raw: "tabs"), .tabs)
        XCTAssertEqual(NavigationChrome.style(raw: "rail"), .rail)
        XCTAssertEqual(NavigationChrome.style(raw: "sidebar"), .rail, "FEAT-30's stored value reads as Rail")
        XCTAssertEqual(NavigationChrome.style(raw: nil), .tabs)
        XCTAssertEqual(NavigationChrome.style(raw: ""), .tabs)
        XCTAssertEqual(NavigationChrome.style(raw: "garbage"), .tabs)
        XCTAssertEqual(NavigationChrome.style(raw: " Rail "), .rail, "a hand-typed launch argument still resolves")
    }

    func testVisibilityResolution() {
        XCTAssertEqual(NavigationChrome.railVisibility(raw: "browsing"), .whileBrowsing)
        XCTAssertEqual(NavigationChrome.railVisibility(raw: "always"), .always)
        XCTAssertEqual(NavigationChrome.railVisibility(raw: nil), .always)
        XCTAssertEqual(NavigationChrome.railVisibility(raw: "garbage"), .always)
    }

    func testModeReadsTheKeys() {
        withDefaults { defaults, _ in
            XCTAssertEqual(NavigationChrome.style(defaults), .tabs, "an untouched install is Tabs")
            XCTAssertFalse(NavigationChrome.isRail(defaults))
            XCTAssertFalse(NavigationChrome.reservesWidth(defaults))

            defaults.set("rail", forKey: NavigationChrome.styleKey)
            XCTAssertTrue(NavigationChrome.isRail(defaults))
            XCTAssertEqual(NavigationChrome.railVisibility(defaults), .always, "Always Visible is the default")
            XCTAssertTrue(NavigationChrome.reservesWidth(defaults))

            defaults.set("browsing", forKey: NavigationChrome.railVisibilityKey)
            XCTAssertFalse(NavigationChrome.reservesWidth(defaults))

            defaults.set("sidebar", forKey: NavigationChrome.styleKey)
            XCTAssertTrue(NavigationChrome.isRail(defaults))

            defaults.set("tabs", forKey: NavigationChrome.styleKey)
            defaults.set("always", forKey: NavigationChrome.railVisibilityKey)
            XCTAssertFalse(NavigationChrome.reservesWidth(defaults), "Tabs mode never reserves width")
        }
    }

    // MARK: Migration (R6)

    func testMigratedValueIsExactlyForSidebar() {
        XCTAssertEqual(NavigationChrome.migratedValue(forPersisted: "sidebar"), "rail")
        XCTAssertNil(NavigationChrome.migratedValue(forPersisted: "rail"))
        XCTAssertNil(NavigationChrome.migratedValue(forPersisted: "tabs"))
        XCTAssertNil(NavigationChrome.migratedValue(forPersisted: nil))
        XCTAssertNil(NavigationChrome.migratedValue(forPersisted: "Sidebar"), "exact match only")
        XCTAssertNil(NavigationChrome.migratedValue(forPersisted: 1))
    }

    func testMigrationRewritesSidebarToRail() {
        withDefaults { defaults, suite in
            defaults.set("sidebar", forKey: NavigationChrome.styleKey)
            XCTAssertTrue(NavigationChrome.migrateLegacy(defaults, domain: suite))
            XCTAssertEqual(defaults.string(forKey: NavigationChrome.styleKey), "rail")
            XCTAssertTrue(NavigationChrome.isRail(defaults))
        }
    }

    func testMigrationLeavesRailAndTabsAlone() {
        for value in ["rail", "tabs"] {
            withDefaults { defaults, suite in
                defaults.set(value, forKey: NavigationChrome.styleKey)
                XCTAssertFalse(NavigationChrome.migrateLegacy(defaults, domain: suite), value)
                XCTAssertEqual(defaults.string(forKey: NavigationChrome.styleKey), value)
            }
        }
    }

    func testMigrationLeavesAMissingKeyMissing() {
        withDefaults { defaults, suite in
            XCTAssertFalse(NavigationChrome.migrateLegacy(defaults, domain: suite))
            XCTAssertNil(defaults.object(forKey: NavigationChrome.styleKey))
        }
    }

    func testMigrationLeavesGarbageUnchanged() {
        withDefaults { defaults, suite in
            defaults.set("floating", forKey: NavigationChrome.styleKey)
            XCTAssertFalse(NavigationChrome.migrateLegacy(defaults, domain: suite))
            XCTAssertEqual(defaults.string(forKey: NavigationChrome.styleKey), "floating")
        }
    }

    func testMigrationSecondRunIsANoOp() {
        withDefaults { defaults, suite in
            defaults.set("sidebar", forKey: NavigationChrome.styleKey)
            XCTAssertTrue(NavigationChrome.migrateLegacy(defaults, domain: suite))
            XCTAssertFalse(NavigationChrome.migrateLegacy(defaults, domain: suite))
            XCTAssertEqual(defaults.string(forKey: NavigationChrome.styleKey), "rail")
        }
    }

    func testMigrationNeverTouchesRailVisibility() {
        withDefaults { defaults, suite in
            defaults.set("sidebar", forKey: NavigationChrome.styleKey)
            XCTAssertTrue(NavigationChrome.migrateLegacy(defaults, domain: suite))
            XCTAssertNil(defaults.object(forKey: NavigationChrome.railVisibilityKey),
                         "an untouched visibility stays unset (Always Visible)")

            defaults.set("browsing", forKey: NavigationChrome.railVisibilityKey)
            defaults.set("sidebar", forKey: NavigationChrome.styleKey)
            XCTAssertTrue(NavigationChrome.migrateLegacy(defaults, domain: suite))
            XCTAssertEqual(defaults.string(forKey: NavigationChrome.railVisibilityKey), "browsing")
        }
    }

    func testMigrationWithoutADomainDoesNothing() {
        withDefaults { defaults, _ in
            defaults.set("sidebar", forKey: NavigationChrome.styleKey)
            XCTAssertFalse(NavigationChrome.migrateLegacy(defaults, domain: ""))
            XCTAssertEqual(defaults.string(forKey: NavigationChrome.styleKey), "sidebar")
        }
    }

    // MARK: Inset math (R3, §1.2)

    func testReservedEdgeAndPill() {
        XCTAssertEqual(NavigationChrome.reservedEdge, 116, "16 bezel + 84 pill + 16 gap")
        XCTAssertEqual(NavigationChrome.pillTrailingEdge, 100)
    }

    func testContentSafeAreaExtra() {
        XCTAssertEqual(NavigationChrome.contentSafeAreaExtra(sideSafeArea: 80, reservesWidth: true), 36)
        XCTAssertEqual(NavigationChrome.contentSafeAreaExtra(sideSafeArea: 80, reservesWidth: false), 0)
        XCTAssertEqual(NavigationChrome.contentSafeAreaExtra(sideSafeArea: 116, reservesWidth: true), 0)
        XCTAssertEqual(NavigationChrome.contentSafeAreaExtra(sideSafeArea: 130, reservesWidth: true), 0, "never negative")
    }

    func testContentLeading() {
        XCTAssertEqual(NavigationChrome.contentLeading(sideSafeArea: 80, reservesWidth: true), 176)
        XCTAssertEqual(NavigationChrome.contentLeading(sideSafeArea: 80, reservesWidth: false), 140)
    }

    func testRowEdgeMargins() {
        XCTAssertEqual(NavigationChrome.rowEdgeMargins(sideSafeArea: 80, reservesWidth: true),
                       RowEdgeMargins(leading: 176, trailing: 140))
        XCTAssertEqual(NavigationChrome.rowEdgeMargins(sideSafeArea: 80, reservesWidth: false),
                       RowEdgeMargins(leading: 140, trailing: 140))
        // Production passes the session's side safe area: no reserved width is exactly `.standard`.
        XCTAssertEqual(NavigationChrome.rowEdgeMargins(sideSafeArea: PinnedRowGeometry.sideSafeArea, reservesWidth: false),
                       RowEdgeMargins.standard)
    }

    /// §1.2 clearance: the widest row lift (a Saga card, ≈30 pt per side) never reaches under the
    /// pill. Always Visible: 176 − 30 ≥ 116. Hide While Browsing: 140 − 30 > 100.
    func testFirstCardLiftClearsThePill() {
        let lift = NavigationChrome.widestRowLiftOverhang
        XCTAssertEqual(lift, 30, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(NavigationChrome.contentLeading(sideSafeArea: 80, reservesWidth: true) - lift,
                                    NavigationChrome.reservedEdge)
        XCTAssertGreaterThan(NavigationChrome.contentLeading(sideSafeArea: 80, reservesWidth: false) - lift,
                             NavigationChrome.pillTrailingEdge)
    }

    // MARK: Search keyboard inset (B4)

    func testReservedLeadingInsetCollapsesOnlyForTheSearchKeyboard() {
        func inset(_ visibility: NavigationChrome.RailVisibility, tab: Int, kb: Bool, hold: Bool = false) -> CGFloat {
            RailVisibilityRule.reservedLeadingInset(sideSafeArea: 80, visibility: visibility,
                                                    selectedTab: tab, keyboardFocused: kb, holdInset: hold)
        }
        XCTAssertEqual(inset(.always, tab: 1, kb: false), 36)
        XCTAssertEqual(inset(.always, tab: 1, kb: true), 0, "Search keyboard: the content takes the width")
        XCTAssertEqual(inset(.always, tab: 0, kb: true), 36, "the flag means nothing off Search")
        XCTAssertEqual(inset(.always, tab: 1, kb: true, hold: true), 36, "the A/B knob holds the inset")
        XCTAssertEqual(inset(.whileBrowsing, tab: 1, kb: true), 0)
        XCTAssertEqual(inset(.whileBrowsing, tab: 0, kb: false), 0)
    }

    func testKeyboardHidesRailOnlyOnSearch() {
        XCTAssertTrue(RailVisibilityRule.keyboardHidesRail(selectedTab: RailVisibilityRule.searchTab, keyboardFocused: true))
        XCTAssertFalse(RailVisibilityRule.keyboardHidesRail(selectedTab: RailVisibilityRule.searchTab, keyboardFocused: false))
        XCTAssertFalse(RailVisibilityRule.keyboardHidesRail(selectedTab: 0, keyboardFocused: true))
    }

    func testSearchInsetHoldKnobKey() {
        XCTAssertEqual(RailSearchInsetHold.defaultsKey, "debug.railSearchInsetHold")
    }

    // MARK: Content gate knob (DEBUG A/B)

    func testRailGateModeResolution() {
        XCTAssertEqual(RailGateMode.resolve(nil), .uikit, "the primary is the default")
        XCTAssertEqual(RailGateMode.resolve("uikit"), .uikit)
        XCTAssertEqual(RailGateMode.resolve("perTab"), .perTab)
        XCTAssertEqual(RailGateMode.resolve("PERTAB"), .perTab)
        XCTAssertEqual(RailGateMode.resolve(" per-tab "), .perTab)
        XCTAssertEqual(RailGateMode.resolve("disabled"), .uikit)
        XCTAssertEqual(RailGateMode.defaultsKey, "debug.railGate")
    }
}
