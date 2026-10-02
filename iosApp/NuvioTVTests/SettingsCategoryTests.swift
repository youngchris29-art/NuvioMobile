import XCTest
import UIKit
@testable import NuvioTV

/// FEAT-50 (detail-settings-revamp W1-B): the Settings root's categories, groups and order.
/// The root-list order is also the UI tests' walk order (P2 spec §I), so a reorder here must move
/// those counts too.
@MainActor
final class SettingsCategoryTests: XCTestCase {
    func testRootOrderIsTheTenCategoryList() {
        XCTAssertEqual(SettingsCategory.allCases, [
            .accountProfiles, .services,
            .appearance, .homeScreen, .detailPage,
            .player, .sources, .subtitlesAudio,
            .about, .developer,
        ])
    }

    func testGroupsAreYouLookWatchSystem() {
        XCTAssertEqual(SettingsCategoryGroup.allCases, [.you, .look, .watch, .system])
    }

    func testGroupMapping() {
        XCTAssertEqual(SettingsCategoryGroup.you.categories, [.accountProfiles, .services])
        XCTAssertEqual(SettingsCategoryGroup.look.categories, [.appearance, .homeScreen, .detailPage])
        XCTAssertEqual(SettingsCategoryGroup.watch.categories, [.player, .sources, .subtitlesAudio])
        XCTAssertEqual(SettingsCategoryGroup.system.categories, [.about, .developer])
    }

    /// Each group's categories sit next to each other in `allCases`, so walking the root list
    /// never leaves a group and comes back.
    func testGroupsAreContiguousAndCoverEveryCategory() {
        let flattened = SettingsCategoryGroup.allCases.flatMap(\.categories)
        XCTAssertEqual(flattened, SettingsCategory.allCases)
    }

    func testRawValuesAreStableIdentifiers() {
        // The UI tests address root rows as `settings_category_<raw>` and panes as
        // `settings_pane_<raw>`.
        XCTAssertEqual(SettingsCategory.allCases.map(\.rawValue), [
            "accountProfiles", "services", "appearance", "homeScreen", "detailPage",
            "player", "sources", "subtitlesAudio", "about", "developer",
        ])
        for category in SettingsCategory.allCases {
            XCTAssertEqual(category.id, category.rawValue)
        }
    }

    func testCopyIsNonEmpty() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.title.isEmpty, "\(category) title")
            XCTAssertFalse(String(localized: category.subtitle).isEmpty, "\(category) subtitle")
            XCTAssertFalse(String(localized: category.summary).isEmpty, "\(category) summary")
        }
        for group in SettingsCategoryGroup.allCases {
            XCTAssertFalse(group.title.isEmpty, "\(group) title")
        }
    }

    func testIconsAreRealSFSymbols() {
        for category in SettingsCategory.allCases {
            XCTAssertNotNil(UIImage(systemName: category.icon), "\(category): \(category.icon)")
        }
    }
}
