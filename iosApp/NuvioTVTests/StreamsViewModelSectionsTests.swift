import Combine
import XCTest
import SharedCore
@testable import NuvioTV

/// Polish D4: `StreamListSection.build` (quality tiers or add-on groups over the same rows) and
/// `StreamsViewModel.sections` / `firstRowKey` as `apply(_:)` publishes them.
@MainActor
final class StreamsViewModelSectionsTests: XCTestCase {

    private let hints = StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                            filename: nil, proxyHeaders: nil, audioDelayMs: nil)

    /// The name alone sets the resolution (`description: nil`).
    private func stream(_ name: String, addonId: String, addonName: String) -> StreamItem {
        let slug = name.replacingOccurrences(of: " ", with: "-")
        return StreamItem(
            name: name, title: nil, description: nil, url: "https://cdn.example.com/\(addonId)/\(slug).mkv",
            infoHash: nil, fileIdx: nil, externalUrl: nil, ytId: nil, sources: [], sourceName: nil,
            addonName: addonName, addonId: addonId, addonLogo: nil, streamType: nil, behaviorHints: hints,
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
        )
    }

    private func groupA(loading: Bool = false) -> AddonStreamGroup {
        AddonStreamGroup(addonName: "Add A", addonId: "a", streams: [
            stream("A 1080p", addonId: "a", addonName: "Add A"),
            stream("A 2160p", addonId: "a", addonName: "Add A"),
            stream("A plain", addonId: "a", addonName: "Add A"),
        ], isLoading: loading, error: nil)
    }

    private func groupB() -> AddonStreamGroup {
        AddonStreamGroup(addonName: "Add B", addonId: "b", streams: [
            stream("B 1080p", addonId: "b", addonName: "Add B"),
            stream("B 720p", addonId: "b", addonName: "Add B"),
        ], isLoading: false, error: nil)
    }

    private func state(_ groups: [AddonStreamGroup], filter: String? = nil) -> StreamsUiState {
        StreamsUiState(
            requestToken: "t", groups: groups, activeAddonIds: [], installedAddonIds: [],
            selectedFilter: filter, isAnyLoading: false, emptyStateReason: nil, autoPlayStream: nil,
            autoPlayCandidates: [], isDirectAutoPlayFlow: false, showDirectAutoPlayOverlay: false,
            overlayMessage: nil
        )
    }

    private func applied(_ groups: [AddonStreamGroup], filter: String? = nil) -> StreamsViewModel {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state(groups, filter: filter))
        return vm
    }

    // MARK: - build, Quality

    func testQualityBuildGroupsRowsUnderTiers() {
        let vm = applied([groupA(), groupB()])
        let sections = StreamListSection.build(groups: vm.groups, mode: .quality, selectedFilter: nil)
        XCTAssertEqual(sections.map(\.title), ["4K", "1080p", "720p", "Other"])
        XCTAssertEqual(sections.map(\.count), [1, 2, 1, 1])
        XCTAssertEqual(sections[1].rows.map(\.title), ["A 1080p", "B 1080p"], "group order kept inside a tier")
        XCTAssertTrue(sections.allSatisfy(\.showsLabel))
        XCTAssertTrue(sections.allSatisfy { !$0.isLoading })
        XCTAssertEqual(sections.map(\.id), ["tier|UHD", "tier|FHD", "tier|HD", "tier|OTHER"])
    }

    func testQualityKeepsTierLabelsWithAChipSelected() {
        let vm = applied([groupA(), groupB()], filter: "a")
        XCTAssertEqual(vm.groups.map(\.id), ["a"])
        let sections = StreamListSection.build(groups: vm.groups, mode: .quality, selectedFilter: "a")
        XCTAssertEqual(sections.map(\.title), ["4K", "1080p", "Other"])
        XCTAssertTrue(sections.allSatisfy(\.showsLabel))
    }

    func testQualityBuildOfNothingIsEmpty() {
        XCTAssertEqual(StreamListSection.build(groups: [], mode: .quality, selectedFilter: nil), [])
    }

    // MARK: - build, Add-on

    func testAddonBuildIsOneSectionPerGroup() {
        let vm = applied([groupA(loading: true), groupB()])
        let sections = StreamListSection.build(groups: vm.groups, mode: .addon, selectedFilter: nil)
        XCTAssertEqual(sections.map(\.title), ["Add A", "Add B"])
        XCTAssertEqual(sections.map(\.id), ["addon|a", "addon|b"])
        XCTAssertEqual(sections.map(\.count), [nil, nil])
        XCTAssertEqual(sections.map(\.isLoading), [true, false])
        XCTAssertTrue(sections.allSatisfy(\.showsLabel))
        XCTAssertEqual(sections.map { $0.rows.count }, [3, 2])
    }

    func testAddonBuildHidesLabelsUnderAChip() {
        let vm = applied([groupA(), groupB()], filter: "a")
        let sections = StreamListSection.build(groups: vm.groups, mode: .addon, selectedFilter: "a")
        XCTAssertEqual(sections.count, 1)
        XCTAssertFalse(sections[0].showsLabel)
    }

    func testBothModesCarryTheSameRowKeys() {
        let vm = applied([groupA(), groupB()])
        let groupKeys = Set(vm.groups.flatMap(\.rowKeys))
        for mode in [StreamGroupingMode.quality, .addon] {
            let sections = StreamListSection.build(groups: vm.groups, mode: mode, selectedFilter: nil)
            let keys = sections.flatMap(\.rows).map(\.key)
            XCTAssertEqual(Set(keys), groupKeys, "\(mode)")
            XCTAssertEqual(keys.count, groupKeys.count, "\(mode): every row exactly once")
        }
    }

    // MARK: - apply

    func testApplyPublishesTierSectionsAndTheFirstTierRowKey() {
        let vm = applied([groupA(), groupB()])
        XCTAssertEqual(vm.groupingMode, .quality, "default before the repository emits")
        XCTAssertEqual(vm.sections.map(\.title), ["4K", "1080p", "720p", "Other"])
        let uhd = vm.groups[0].rows.first { $0.title == "A 2160p" }
        XCTAssertNotNil(uhd)
        XCTAssertEqual(vm.firstRowKey, uhd?.key, "the first row of the first tier, not the first in group order")
        XCTAssertNotEqual(vm.firstRowKey, vm.groups[0].rowKeys.first)
    }

    func testAnIdenticalRepublishPublishesNothing() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        var sends = 0
        let sub = vm.objectWillChange.sink { sends += 1 }
        defer { sub.cancel() }
        vm.apply(state([groupA(), groupB()]))
        XCTAssertGreaterThan(sends, 0)
        let after = sends
        vm.apply(state([groupA(), groupB()]))
        XCTAssertEqual(sends, after, "equal groups and sections must not invalidate the picker")
    }

    func testAnEmptyStateClearsSectionsAndFirstRowKey() {
        let vm = applied([groupA(), groupB()])
        XCTAssertFalse(vm.sections.isEmpty)
        XCTAssertNotNil(vm.firstRowKey)
        vm.apply(state([]))
        XCTAssertTrue(vm.sections.isEmpty)
        XCTAssertNil(vm.firstRowKey)
    }

    // MARK: - re-apply and rebuild paths (review r1)

    private func settings(_ mode: StreamGroupingMode) throws -> StreamBadgeSettingsUiState {
        StreamBadgeSettingsRepository.shared.ensureLoaded()
        let base = try XCTUnwrap(StreamBadgeSettingsRepository.shared.uiState.value_ as? StreamBadgeSettingsUiState)
        return StreamBadgeSettingsUiState(
            rules: base.rules, showFileSizeBadges: base.showFileSizeBadges, showAddonLogo: base.showAddonLogo,
            showInPlayer: base.showInPlayer, playerBadgeSource: base.playerBadgeSource,
            badgePlacement: base.badgePlacement, backgroundMode: base.backgroundMode, groupingMode: mode,
            listOpensWith: .bestPick
        )
    }

    func testAGroupingModeFlipReappliesTheLastState() throws {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.receive(badgeSettings: try settings(.quality))
        vm.receive(state([groupA(), groupB()]))
        XCTAssertEqual(vm.sections.map(\.title), ["4K", "1080p", "720p", "Other"])
        let groupsBefore = vm.groups
        vm.receive(badgeSettings: try settings(.addon))
        XCTAssertEqual(vm.groupingMode, .addon)
        XCTAssertEqual(vm.sections.map(\.title), ["Add A", "Add B"], "one section per add-on after the flip")
        XCTAssertEqual(vm.groups, groupsBefore, "only the sections moved; no row was rebuilt")
        XCTAssertEqual(vm.firstRowKey, vm.groups[0].rowKeys.first, "Add-on mode focuses the first add-on row")
        vm.receive(badgeSettings: try settings(.quality))
        XCTAssertEqual(vm.sections.map(\.title), ["4K", "1080p", "720p", "Other"], "and back")
    }

    func testAFilterChangeWithTheSameGroupsStillRebuildsTheSections() throws {
        // One add-on in the state either way, so the groups compare equal; only the filter differs.
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.receive(badgeSettings: try settings(.addon))
        let only = [groupA()]
        vm.receive(state(only, filter: nil))
        XCTAssertEqual(vm.sections.map(\.showsLabel), [true], "the All view labels the add-on")
        let groupsBefore = vm.groups
        vm.receive(state(only, filter: "a"))
        XCTAssertEqual(vm.groups, groupsBefore, "the group list is unchanged")
        XCTAssertEqual(vm.sections.map(\.showsLabel), [false], "a chip hides the add-on label")
        vm.receive(state(only, filter: nil))
        XCTAssertEqual(vm.sections.map(\.showsLabel), [true])
    }
}
