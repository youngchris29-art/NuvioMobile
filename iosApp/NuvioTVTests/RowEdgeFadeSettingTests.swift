import XCTest
import SwiftUI
@testable import NuvioTV

/// beta.19-rc1 verdict (F, FEAT-54): the `row_edge_fade` setting that replaced the BUG-118 Developer
/// A/B (`debug.rowEdgeFade`), its migration (only an explicit old "Off" survives), and the two
/// environment values rows read their geometry from. Every test uses its own throwaway
/// `UserDefaults` suite, never `.standard`.
final class RowEdgeFadeSettingTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "RowEdgeFadeSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testKeys() {
        XCTAssertEqual(RowEdgeFadeSetting.defaultsKey, "row_edge_fade")
        XCTAssertEqual(RowEdgeFadeSetting.legacyKey, "debug.rowEdgeFade")
        XCTAssertEqual(RowEdgeFadeSetting.allCases.map(\.rawValue), ["soft", "system", "off"])
    }

    func testUnknownResolvesToDefault() {
        XCTAssertEqual(RowEdgeFadeSetting.resolve(nil), RowEdgeFadeSetting.defaultValue)
        XCTAssertEqual(RowEdgeFadeSetting.resolve(""), RowEdgeFadeSetting.defaultValue)
        XCTAssertEqual(RowEdgeFadeSetting.resolve("hard"), RowEdgeFadeSetting.defaultValue)
        XCTAssertEqual(RowEdgeFadeSetting.resolve("2"), RowEdgeFadeSetting.defaultValue)
        XCTAssertEqual(RowEdgeFadeSetting.resolve("soft"), .soft)
        XCTAssertEqual(RowEdgeFadeSetting.resolve("system"), .system)
        XCTAssertEqual(RowEdgeFadeSetting.resolve("off"), .off)
        // A hand-typed launch argument still resolves.
        XCTAssertEqual(RowEdgeFadeSetting.resolve(" Off "), .off)
    }

    func testCurrentReadsTheKey() {
        withDefaults { defaults in
            XCTAssertEqual(RowEdgeFadeSetting.current(defaults), RowEdgeFadeSetting.defaultValue)
            defaults.set("system", forKey: RowEdgeFadeSetting.defaultsKey)
            XCTAssertEqual(RowEdgeFadeSetting.current(defaults), .system)
        }
    }

    /// Christian 2026-10-03: only an explicit old "Off" (3) carries across; Hard (0), Soft (1) and
    /// System (2) land on the new default. The legacy key is removed either way.
    func testMigrationKeepsOnlyOff() {
        for legacy in 0...3 {
            withDefaults { defaults in
                defaults.set(legacy, forKey: RowEdgeFadeSetting.legacyKey)
                RowEdgeFadeSetting.migrateLegacy(defaults)
                XCTAssertNil(defaults.object(forKey: RowEdgeFadeSetting.legacyKey), "legacy=\(legacy)")
                if legacy == 3 {
                    XCTAssertEqual(defaults.string(forKey: RowEdgeFadeSetting.defaultsKey), "off")
                    XCTAssertEqual(RowEdgeFadeSetting.current(defaults), .off)
                } else {
                    XCTAssertNil(defaults.object(forKey: RowEdgeFadeSetting.defaultsKey), "legacy=\(legacy)")
                    XCTAssertEqual(RowEdgeFadeSetting.current(defaults), RowEdgeFadeSetting.defaultValue, "legacy=\(legacy)")
                }
            }
        }
    }

    func testMigrationNeverOverwritesNewKey() {
        withDefaults { defaults in
            defaults.set("system", forKey: RowEdgeFadeSetting.defaultsKey)
            defaults.set(3, forKey: RowEdgeFadeSetting.legacyKey)
            RowEdgeFadeSetting.migrateLegacy(defaults)
            XCTAssertEqual(defaults.string(forKey: RowEdgeFadeSetting.defaultsKey), "system")
            XCTAssertNil(defaults.object(forKey: RowEdgeFadeSetting.legacyKey))
        }
    }

    func testMigrationNoopWithoutLegacy() {
        withDefaults { defaults in
            RowEdgeFadeSetting.migrateLegacy(defaults)
            XCTAssertNil(defaults.object(forKey: RowEdgeFadeSetting.defaultsKey))
            defaults.set("off", forKey: RowEdgeFadeSetting.defaultsKey)
            RowEdgeFadeSetting.migrateLegacy(defaults)
            XCTAssertEqual(defaults.string(forKey: RowEdgeFadeSetting.defaultsKey), "off")
        }
    }

    /// A second launch after the migration finds no legacy key and changes nothing.
    func testMigrationIsIdempotent() {
        withDefaults { defaults in
            defaults.set(3, forKey: RowEdgeFadeSetting.legacyKey)
            RowEdgeFadeSetting.migrateLegacy(defaults)
            defaults.set("soft", forKey: RowEdgeFadeSetting.defaultsKey) // the viewer picks Soft later
            RowEdgeFadeSetting.migrateLegacy(defaults)
            XCTAssertEqual(defaults.string(forKey: RowEdgeFadeSetting.defaultsKey), "soft")
        }
    }

    /// Critique #13: rows read their margins and ramp length from the environment; with nothing
    /// set they get the standard 140 pt margins and the 250 pt ramp.
    @MainActor
    func testEnvironmentDefaultsAreStandard() {
        let environment = EnvironmentValues()
        XCTAssertEqual(environment.rowEdgeMargins, RowEdgeMargins.standard)
        XCTAssertEqual(environment.rowEdgeRampLength, RowEdgeFade.rampLength)
        var custom = environment
        custom.rowEdgeMargins = RowEdgeMargins(leading: 116, trailing: 140)
        custom.rowEdgeRampLength = 200
        XCTAssertEqual(custom.rowEdgeMargins, RowEdgeMargins(leading: 116, trailing: 140))
        XCTAssertEqual(custom.rowEdgeRampLength, 200)
    }
}
