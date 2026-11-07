import XCTest
import SharedCore
@testable import NuvioTV

/// Add-ons hub v2 (A1): the sidebar section rules, the persisted refresh stamp and the stall ceiling.
final class HubSectionTests: XCTestCase {

    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func freshDefaults() -> UserDefaults {
        let name = "hubv2-tests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func summary(
        installed: Int = 3, on: Int = 2, catalogsOn: Int = 2, catalogsTotal: Int = 3,
        debrid: [String] = [], plugins: AddonsViewModel.PluginSummary? = nil
    ) -> AddonsViewModel.HubSummary {
        AddonsViewModel.HubSummary(
            addonsInstalled: installed, addonsOn: on, catalogsOn: catalogsOn, catalogsTotal: catalogsTotal,
            debridConnected: debrid, plugins: plugins
        )
    }

    private let pluginSummary = AddonsViewModel.PluginSummary(repositories: 2, providers: 7)

    // MARK: visibility

    /// Review r4: Plugins stays visible with plugins off (its pane turns them back on).
    func testPluginsVisibleWhetherOrNotPluginsAreOn() {
        XCTAssertTrue(HubSection.plugins.isVisible(summary: summary(), phoneEnabled: true))
        XCTAssertTrue(HubSection.plugins.isVisible(summary: summary(plugins: pluginSummary), phoneEnabled: true))
    }

    func testPhoneHiddenUnlessEnabled() {
        XCTAssertFalse(HubSection.phone.isVisible(summary: summary(), phoneEnabled: false))
        XCTAssertTrue(HubSection.phone.isVisible(summary: summary(), phoneEnabled: true))
    }

    func testVisibleKeepsDisplayOrder() {
        XCTAssertEqual(
            HubSection.visible(summary: summary(), phoneEnabled: false),
            [.installed, .catalogs, .debrid, .plugins, .install, .refresh]
        )
        XCTAssertEqual(
            HubSection.visible(summary: summary(plugins: pluginSummary), phoneEnabled: true),
            HubSection.allCases
        )
        XCTAssertEqual(
            HubSection.visible(summary: summary(plugins: pluginSummary), phoneEnabled: false),
            HubSection.allCases.filter { $0 != .phone }
        )
    }

    func testOnlyRefreshIsAnAction() {
        XCTAssertEqual(HubSection.allCases.filter { $0.isAction }, [.refresh])
    }

    // MARK: resolved

    func testResolvedRestoresOnlyAVisibleNonActionSection() {
        let all = HubSection.allCases
        XCTAssertEqual(HubSection.resolved(raw: nil, visible: all), .installed)
        XCTAssertEqual(HubSection.resolved(raw: "catalogs", visible: all), .catalogs)
        XCTAssertEqual(HubSection.resolved(raw: "refresh", visible: all), .installed)
        let noPlugins = all.filter { $0 != .plugins }
        XCTAssertEqual(HubSection.resolved(raw: "plugins", visible: noPlugins), .installed)
        XCTAssertEqual(HubSection.resolved(raw: "garbage", visible: all), .installed)
    }

    // MARK: trailing values

    func testTrailingValues() {
        let s = summary(installed: 5, catalogsOn: 2, catalogsTotal: 3, debrid: ["TorBox", "Real-Debrid"], plugins: pluginSummary)
        XCTAssertEqual(HubSection.installed.trailingValue(summary: s), "5")
        XCTAssertEqual(HubSection.catalogs.trailingValue(summary: s), "2 of 3")
        XCTAssertEqual(HubSection.debrid.trailingValue(summary: s), "TorBox, Real-Debrid")
        XCTAssertEqual(HubSection.plugins.trailingValue(summary: s), "7")
        XCTAssertNil(HubSection.install.trailingValue(summary: s))
        XCTAssertNil(HubSection.refresh.trailingValue(summary: s))
        XCTAssertNil(HubSection.phone.trailingValue(summary: s))
    }

    func testTrailingValueDebridEmptyAndPluginsNil() {
        let s = summary()
        XCTAssertEqual(HubSection.debrid.trailingValue(summary: s), "Not connected")
        XCTAssertEqual(HubSection.plugins.trailingValue(summary: s), "Off")
    }

    // MARK: refresh stamp

    func testRefreshStampAbsentIsNil() {
        XCTAssertNil(AddonsViewModel.loadRefreshStamp(defaults: freshDefaults(), profileId: 1, profileIdentity: "p1"))
    }

    func testRefreshStampRoundTrips() {
        let defaults = freshDefaults()
        let date = Date(timeIntervalSince1970: 1_800_000_123.456)
        AddonsViewModel.saveRefreshStamp(date, defaults: defaults, profileId: 2, profileIdentity: "p2")
        let loaded = AddonsViewModel.loadRefreshStamp(defaults: defaults, profileId: 2, profileIdentity: "p2")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRefreshStampsAreIndependentPerProfile() {
        let defaults = freshDefaults()
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let second = Date(timeIntervalSince1970: 1_800_005_000)
        AddonsViewModel.saveRefreshStamp(first, defaults: defaults, profileId: 1, profileIdentity: "p1")
        XCTAssertNil(AddonsViewModel.loadRefreshStamp(defaults: defaults, profileId: 2, profileIdentity: "p2"))
        AddonsViewModel.saveRefreshStamp(second, defaults: defaults, profileId: 2, profileIdentity: "p2")
        XCTAssertEqual(AddonsViewModel.loadRefreshStamp(defaults: defaults, profileId: 1, profileIdentity: "p1")?.timeIntervalSince1970 ?? 0, first.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(AddonsViewModel.loadRefreshStamp(defaults: defaults, profileId: 2, profileIdentity: "p2")?.timeIntervalSince1970 ?? 0, second.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRefreshStampKeyFormat() {
        XCTAssertEqual(AddonsViewModel.refreshStampKey(profileId: 3), "addons.lastRefreshedAt.3")
    }

    // MARK: stall ceiling

    func testStalledUrlsRespectTheCeiling() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let ages = ["a": start, "b": start.addingTimeInterval(10)]
        XCTAssertEqual(AddonsViewModel.stalledUrls(startedAt: ages, now: start.addingTimeInterval(29.9)), [])
        XCTAssertEqual(AddonsViewModel.stalledUrls(startedAt: ages, now: start.addingTimeInterval(30)), ["a"])
        XCTAssertEqual(AddonsViewModel.stalledUrls(startedAt: ages, now: start.addingTimeInterval(40)), ["a", "b"])
        XCTAssertEqual(AddonsViewModel.stalledUrls(startedAt: [:], now: start.addingTimeInterval(45)), [])
    }

    /// Review r2: ages come from the live list, so a refresh the repository started itself (not
    /// through this model) is aged too; a URL that stops refreshing is forgotten.
    func testRefreshAgesFollowTheLiveList() {
        typealias Age = AddonsViewModel.RefreshAge
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = t0.addingTimeInterval(5)
        var ages = AddonsViewModel.updatedRefreshAges([:], refreshing: ["a": 1], now: t0)
        XCTAssertEqual(ages, ["a": Age(generation: 1, startedAt: t0)])
        ages = AddonsViewModel.updatedRefreshAges(ages, refreshing: ["a": 1, "b": 4], now: t1)
        XCTAssertEqual(ages, ["a": Age(generation: 1, startedAt: t0), "b": Age(generation: 4, startedAt: t1)],
                       "a request already refreshing keeps its first-seen time")
        ages = AddonsViewModel.updatedRefreshAges(ages, refreshing: ["b": 4], now: t1)
        XCTAssertEqual(ages, ["b": Age(generation: 4, startedAt: t1)])
    }

    /// Review r5: a NEW request for the same add-on (another generation, e.g. one that started
    /// while the hub was away) starts its own age rather than inheriting the old one.
    func testANewRequestForTheSameAddonStartsItsOwnAge() {
        typealias Age = AddonsViewModel.RefreshAge
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let later = t0.addingTimeInterval(120)
        let before = ["a": Age(generation: 1, startedAt: t0)]
        let after = AddonsViewModel.updatedRefreshAges(before, refreshing: ["a": 2], now: later)
        XCTAssertEqual(after, ["a": Age(generation: 2, startedAt: later)])
        XCTAssertEqual(AddonsViewModel.stalledUrls(startedAt: after.mapValues(\.startedAt), now: later.addingTimeInterval(1)), [])
    }

    /// Review r2: focus memory only lands on controls the card keeps enabled.
    func testInstalledFocusKeysFollowTheCardsDisabledRules() {
        let keys = AddonsHubSplitView.installedFocusKeys(urls: ["a", "b", "c"], isReadOnly: false)
        XCTAssertTrue(keys.isSuperset(of: ["card:a", "toggle:a", "remove:a", "down:a", "up:b", "down:b", "up:c"]))
        XCTAssertFalse(keys.contains("up:a"), "the first card's Up is disabled")
        XCTAssertFalse(keys.contains("down:c"), "the last card's Down is disabled")
        let readOnly = AddonsHubSplitView.installedFocusKeys(urls: ["a", "b"], isReadOnly: true)
        XCTAssertEqual(readOnly, ["card:a", "card:b"])
    }

    /// Review r10: a stamp written by another profile that held the same slot (deleted here or on
    /// another device, then the slot reused) is ignored, so the new profile reads "Not refreshed yet".
    func testAStampFromAnotherProfileInTheSameSlotIsIgnored() {
        let suite = "hubv2-tests-slot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stamp = Date(timeIntervalSince1970: 2_000_000)
        AddonsViewModel.saveRefreshStamp(stamp, defaults: defaults, profileId: 2, profileIdentity: "old-profile")
        XCTAssertNil(AddonsViewModel.loadRefreshStamp(defaults: defaults, profileId: 2, profileIdentity: "new-profile"))
        XCTAssertNotNil(AddonsViewModel.loadRefreshStamp(defaults: defaults, profileId: 2, profileIdentity: "old-profile"))
    }

    /// Review r11: a profile without a stable id (guest, or applied locally before a pull) never
    /// persists or reads a stamp, so a reused guest slot cannot inherit one.
    func testAProfileWithoutAStableIdNeverPersistsAStamp() {
        let suite = "hubv2-tests-guest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        AddonsViewModel.saveRefreshStamp(Date(timeIntervalSince1970: 2_000_000), defaults: defaults, profileId: 4, profileIdentity: "")
        XCTAssertNil(defaults.object(forKey: AddonsViewModel.refreshStampKey(profileId: 4)))
        XCTAssertNil(AddonsViewModel.loadRefreshStamp(defaults: defaults, profileId: 4, profileIdentity: ""))
    }

    /// Review r12: the stamp `start()` shows across a stop/start and a profile change.
    func testStampOnStartKeepsASessionStampForTheSameProfileOnly() {
        let session = Date(timeIntervalSince1970: 3_000_000)
        let stored = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(AddonsViewModel.stampOnStart(current: session, currentSlot: 4, slot: 4, loaded: nil), session,
                       "same profile, nothing stored (no stable id): the session stamp stays")
        XCTAssertNil(AddonsViewModel.stampOnStart(current: session, currentSlot: 4, slot: 2, loaded: nil),
                     "another profile never sees it")
        XCTAssertEqual(AddonsViewModel.stampOnStart(current: session, currentSlot: 4, slot: 2, loaded: stored), stored)
        XCTAssertNil(AddonsViewModel.stampOnStart(current: nil, currentSlot: nil, slot: 1, loaded: nil))
    }
}
