import SwiftUI
import UIKit
import XCTest
@testable import NuvioTV

/// FEAT-31: `Theme.Font`'s font-family machinery (device-local `ui_font` UserDefaults key +
/// system/Open Sans resolution) is pure enough to test without a view. The load-bearing guarantee
/// is that DEFAULT behavior — the key absent, or before `apply(.openSans)` is ever called — stays
/// byte-identical to the pre-FEAT-31 fixed `SwiftUI.Font` literals; see
/// `testSystemModeMatchesPreFeat31Literals`.
///
/// Each `AppFontFamily.fromDefaults` case uses its own throwaway, UUID-suffixed `UserDefaults`
/// suite (same isolation pattern as `TrailerZoomCacheVerifyTests`), so these never touch
/// `.standard` or interact with each other. `Theme.Font.apply` is process-global state, so every
/// test that changes it restores `.system` in `tearDown()`.
final class AppFontResolverTests: XCTestCase {

    override func tearDown() {
        Theme.Font.apply(.system)
        super.tearDown()
    }

    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suiteName = "AppFontResolverTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - AppFontFamily.fromDefaults

    func testFromDefaultsReturnsSystemWhenKeyMissing() {
        let defaults = makeIsolatedDefaults()
        XCTAssertEqual(Theme.AppFontFamily.fromDefaults(defaults), .system)
    }

    func testFromDefaultsReturnsSystemForGarbageValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("not-a-real-family", forKey: Theme.AppFontFamily.defaultsKey)
        XCTAssertEqual(Theme.AppFontFamily.fromDefaults(defaults), .system)
    }

    func testFromDefaultsReturnsOpenSansForKnownValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("openSans", forKey: Theme.AppFontFamily.defaultsKey)
        XCTAssertEqual(Theme.AppFontFamily.fromDefaults(defaults), .openSans)
    }

    // MARK: - baseSize(for:)

    func testBaseSizeForTitle2MatchesPlatformDefaultCategoryMetricAndIsPositive() {
        let expected = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: .title2,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        let actual = Theme.Font.baseSize(for: .title2)

        XCTAssertEqual(actual, expected)
        XCTAssertGreaterThan(actual, 0)
    }

    // MARK: - System-mode identity (default behavior must stay byte-identical)

    func testSystemModeMatchesPreFeat31Literals() {
        Theme.Font.apply(.system)

        XCTAssertEqual(Theme.Font.hero, SwiftUI.Font.title2.weight(.bold))
        XCTAssertEqual(Theme.Font.screenTitle, SwiftUI.Font.title3.weight(.bold))
        XCTAssertEqual(Theme.Font.sectionTitle, SwiftUI.Font.callout.weight(.semibold))
        XCTAssertEqual(Theme.Font.cardTitle, SwiftUI.Font.caption2)
        XCTAssertEqual(Theme.Font.body, SwiftUI.Font.body)
        // rc14 (Steven rc13 verdict, 2026-09-30): `meta` is `.medium` now, in both families.
        XCTAssertEqual(Theme.Font.meta, SwiftUI.Font.caption.weight(.medium))
        // beta.18 verdict (FEAT-44 / FEAT-31): synopsis/detail pin an explicit `.regular`;
        // `metaStrong` is the semibold hero/Detail year + genre line.
        XCTAssertEqual(Theme.Font.metaStrong, SwiftUI.Font.caption.weight(.semibold))
        XCTAssertEqual(Theme.Font.synopsis, SwiftUI.Font.caption.weight(.regular))
        XCTAssertEqual(Theme.Font.detail, SwiftUI.Font.caption.weight(.regular))
        XCTAssertEqual(Theme.Font.caption, SwiftUI.Font.caption2)
    }

    /// beta.18 verdict (FEAT-44 / FEAT-31): documents why the explicit `.regular` on the synopsis
    /// and detail tokens is load-bearing — tvOS's default caption1 weight is heavier than Regular.
    func testTvOSCaptionDefaultWeightIsHeavierThanRegular() throws {
        let descriptor = UIFont.preferredFont(forTextStyle: .caption1).fontDescriptor
        let traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        guard let weight = traits?[.weight] as? CGFloat else {
            throw XCTSkip("no weight trait on the default caption1 font")
        }
        XCTAssertGreaterThan(weight, 0)
    }

    // MARK: - Open Sans mode

    /// Distinct tokens (a hero display size vs. body copy) must still resolve to distinct fonts —
    /// guards against a bug where Open Sans mode collapses every token to one fixed custom font
    /// ignoring size/`relativeTo`. Whether the face is actually installed in this test host is a
    /// separate question, covered by `isCustomFaceAvailable` below.
    func testOpenSansModeProducesDistinctTokens() {
        Theme.Font.apply(.openSans)
        XCTAssertNotEqual(Theme.Font.hero, Theme.Font.body)
    }

    /// FEAT-44 (Steven, rc12 verdict 2026-09-13): before this fix, a token with no explicit weight
    /// (`.body`, the synopsis token) resolved through a bare `Font.custom("Open Sans", …)` with no
    /// `.weight()` call, letting CoreText pick among the three registered faces. It must now pin to
    /// `.regular` explicitly — and stay visually distinct from `.meta`, which carries `.medium` (beta.18 verdict: size is the
    /// scaled `openSansPointSize`).
    func testOpenSansModeBodyResolvesWithRegularWeightAndStaysDistinctFromMeta() {
        Theme.Font.apply(.openSans)
        let expectedBody = SwiftUI.Font.custom(
            "Open Sans",
            size: Theme.Font.openSansPointSize(for: .body),
            relativeTo: .body
        ).weight(.regular)

        XCTAssertEqual(Theme.Font.body, expectedBody)
        XCTAssertNotEqual(Theme.Font.body, Theme.Font.meta)
    }

    func testOpenSansMetaStrongUsesTheSemiBoldFace() {
        Theme.Font.apply(.openSans)
        let expected = SwiftUI.Font.custom(
            "Open Sans",
            size: Theme.Font.openSansPointSize(for: .caption1),
            relativeTo: .caption
        ).weight(.semibold)
        XCTAssertEqual(Theme.Font.metaStrong, expected)
    }

    func testOpenSansScaleIsAppliedToEveryTextStyle() {
        let styles: [UIFont.TextStyle] = [.title2, .title3, .callout, .body, .caption1, .caption2]
        for style in styles {
            XCTAssertEqual(Theme.Font.openSansPointSize(for: style),
                           Theme.Font.baseSize(for: style) * 0.92,
                           accuracy: 0.001, "\(style)")
        }
    }

    /// 25 × 0.92 × 1.3618 = 31.32; 29 × 0.92 × 1.3618 = 36.33; 31 × 0.92 × 1.3618 = 38.84.
    func testOpenSansLineHeightsLandNearTheSystemFace() throws {
        Theme.Font.apply(.openSans)
        try XCTSkipUnless(Theme.Font.isCustomFaceAvailable, "Open Sans face not registered in this test host")

        XCTAssertEqual(Theme.Font.synopsisLineHeight, 31.32, accuracy: 0.5)
        XCTAssertEqual(Theme.Font.bodyLineHeight, 36.33, accuracy: 0.5)
        XCTAssertEqual(Theme.Font.sectionTitleLineHeight, 38.84, accuracy: 0.5)
    }

    /// `uiFont(for:)` only actually returns an Open Sans face if the bundled TTFs were registered
    /// with CoreText — `AppFontRegistrar.registerIfNeeded()` does that at launch, which a unit-test
    /// host never runs. Skip rather than fail when the face isn't available, so this test asserts
    /// the real behavior on a device/sim run without being a false failure in a bare XCTest host.
    func testOpenSansModeUiFontUsesTheRegisteredFaceWhenAvailable() throws {
        Theme.Font.apply(.openSans)
        try XCTSkipUnless(Theme.Font.isCustomFaceAvailable, "Open Sans face not registered in this test host")

        XCTAssertEqual(Theme.Font.uiFont(for: .caption2).familyName, "Open Sans")
    }
}
