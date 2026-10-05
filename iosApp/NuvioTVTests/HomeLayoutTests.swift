import XCTest
@testable import NuvioTV

/// Home Stage & Strip (H1, W1-C; P2 spec sections 3.1 and 4.2): the `home_layout` key every Home
/// reader shares (HomeView, the folder page, the Settings panes), and the `home_ambient_background`
/// key the Ambient Background switch writes. Every test uses its own throwaway `UserDefaults`
/// suite, never `.standard`.
final class HomeLayoutTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "HomeLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: - Keys, cases, default

    func testKeysAndCases() {
        XCTAssertEqual(HomeLayout.defaultsKey, "home_layout")
        // Stage first: the Settings picker lists the cases in this order.
        XCTAssertEqual(HomeLayout.allCases.map(\.rawValue), ["stage", "classic"])
        XCTAssertEqual(HomeLayout.stage.rawValue, "stage")
        XCTAssertEqual(HomeLayout.classic.rawValue, "classic")
    }

    /// P2-8: Stage for new AND existing users, no migration.
    func testDefaultIsStage() {
        XCTAssertEqual(HomeLayout.defaultValue, .stage)
        // Every reader seeds its `@AppStorage` with this raw value, so an unset key reads Stage.
        XCTAssertEqual(HomeLayout.defaultValue.rawValue, "stage")
    }

    // MARK: - resolve

    func testUnknownAndBlankResolveToStage() {
        XCTAssertEqual(HomeLayout.resolve(nil), .stage)
        XCTAssertEqual(HomeLayout.resolve(""), .stage)
        XCTAssertEqual(HomeLayout.resolve("   "), .stage)
        XCTAssertEqual(HomeLayout.resolve("pinned"), .stage)
        XCTAssertEqual(HomeLayout.resolve("hero"), .stage)
        XCTAssertEqual(HomeLayout.resolve("1"), .stage)
    }

    func testKnownValuesResolve() {
        XCTAssertEqual(HomeLayout.resolve("stage"), .stage)
        XCTAssertEqual(HomeLayout.resolve("classic"), .classic)
        for layout in HomeLayout.allCases {
            XCTAssertEqual(HomeLayout.resolve(layout.rawValue), layout, "\(layout)")
        }
    }

    /// A hand-typed launch argument (`-home_layout Classic`) still resolves: trimmed, then
    /// lower-cased.
    func testResolveTrimsAndIgnoresCase() {
        XCTAssertEqual(HomeLayout.resolve(" Classic "), .classic)
        XCTAssertEqual(HomeLayout.resolve("CLASSIC"), .classic)
        XCTAssertEqual(HomeLayout.resolve("Classic\n"), .classic)
        XCTAssertEqual(HomeLayout.resolve(" STAGE "), .stage)
    }

    // MARK: - current

    func testCurrentReadsTheKey() {
        withDefaults { defaults in
            // Unset: the default.
            XCTAssertEqual(HomeLayout.current(defaults), .stage)

            defaults.set("classic", forKey: HomeLayout.defaultsKey)
            XCTAssertEqual(HomeLayout.current(defaults), .classic)

            defaults.set("stage", forKey: HomeLayout.defaultsKey)
            XCTAssertEqual(HomeLayout.current(defaults), .stage)

            // The same forgiving read the `@AppStorage` readers get through `resolve`.
            defaults.set(" Classic ", forKey: HomeLayout.defaultsKey)
            XCTAssertEqual(HomeLayout.current(defaults), .classic)

            // An unknown stored value never lands on a blank page: it reads as the default.
            defaults.set("pinned", forKey: HomeLayout.defaultsKey)
            XCTAssertEqual(HomeLayout.current(defaults), .stage)
        }
    }

    /// Removing the key (Reset, a wiped profile) returns to Stage.
    func testCurrentAfterRemovingTheKeyIsStage() {
        withDefaults { defaults in
            defaults.set("classic", forKey: HomeLayout.defaultsKey)
            XCTAssertEqual(HomeLayout.current(defaults), .classic)
            defaults.removeObject(forKey: HomeLayout.defaultsKey)
            XCTAssertEqual(HomeLayout.current(defaults), .stage)
        }
    }

    // MARK: - label

    func testLabelsAreNonEmptyAndDistinct() {
        let labels = HomeLayout.allCases.map(\.label)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty }, "\(labels)")
        XCTAssertEqual(Set(labels).count, labels.count, "\(labels)")
    }

    // MARK: - Ambient Background (W1-B's key, read by the Settings switch)

    /// `AmbientWashSetting` lives in `DesignSystem/AmbientWashLayer.swift` (W1-B); the Home Screen
    /// pane's Ambient Background switch and the wash layer both read this key. `@MainActor` so the
    /// test compiles whichever isolation that enum is declared with.
    @MainActor
    func testAmbientWashSettingKeyAndDefault() {
        XCTAssertEqual(AmbientWashSetting.defaultsKey, "home_ambient_background")
        XCTAssertTrue(AmbientWashSetting.defaultValue)
    }
}
