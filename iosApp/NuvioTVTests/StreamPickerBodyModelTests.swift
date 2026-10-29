import Combine
import XCTest
import SharedCore
@testable import NuvioTV

/// Direction C: the panel body (`StreamPickerBodyModel`) as `StreamsViewModel` publishes it: the
/// best-pick card, the alternatives, the folded tiers, the upgrade gate, expansion, rejection and
/// the Full List / Show all fallbacks. Most cases run through the view model with its test seams
/// (`listOpensWith`, `autoPlayCachedOnly`); a few call `build` on plain values.
@MainActor
final class StreamPickerBodyModelTests: XCTestCase {

    override func tearDown() {
        StreamsViewModel.bestPickUpgradePolicy = .perAnswer
        super.tearDown()
    }

    // MARK: - Builders

    private let hints = StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                            filename: nil, proxyHeaders: nil, audioDelayMs: nil)

    /// HTTP links; the name alone sets the resolution (`description: nil`).
    private func stream(_ name: String, addonId: String, addonName: String) -> StreamItem {
        let slug = name.replacingOccurrences(of: " ", with: "-")
        return StreamItem(
            name: name, title: nil, description: nil, url: "https://cdn.example.com/\(addonId)/\(slug).mkv",
            infoHash: nil, fileIdx: nil, externalUrl: nil, ytId: nil, sources: [], sourceName: nil,
            addonName: addonName, addonId: addonId, addonLogo: nil, streamType: nil, behaviorHints: hints,
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
        )
    }

    private func group(_ id: String, _ name: String, _ streams: [String], loading: Bool = false) -> AddonStreamGroup {
        AddonStreamGroup(addonName: name, addonId: id, streams: streams.map { stream($0, addonId: id, addonName: name) },
                         isLoading: loading, error: nil)
    }

    private func groupA(_ extra: [String] = []) -> AddonStreamGroup {
        group("a", "Add A", ["A 1080p", "A 1080p HEVC", "A 1080p x264", "A 720p"] + extra)
    }

    private func groupB() -> AddonStreamGroup { group("b", "Add B", ["B 2160p", "B 1080p"]) }

    private func state(_ groups: [AddonStreamGroup], filter: String? = nil, loading: Bool = false) -> StreamsUiState {
        StreamsUiState(
            requestToken: "t", groups: groups, activeAddonIds: [], installedAddonIds: [],
            selectedFilter: filter, isAnyLoading: loading, emptyStateReason: nil, autoPlayStream: nil,
            autoPlayCandidates: [], isDirectAutoPlayFlow: false, showDirectAutoPlayOverlay: false,
            overlayMessage: nil
        )
    }

    /// A view model in `.tiers` with a Cached Sources Only of `cachedOnly`, seams set before the first apply.
    private func tiersModel(cachedOnly: Bool = false) -> StreamsViewModel {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.listOpensWith = { .bestPick }
        vm.autoPlayCachedOnly = { cachedOnly }
        return vm
    }

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

    private func key(_ vm: StreamsViewModel, _ title: String) throws -> String {
        try XCTUnwrap(vm.groups.flatMap(\.rows).first { $0.title == title }?.key, "no row titled \(title)")
    }

    private func playbackKey(_ vm: StreamsViewModel, _ title: String) throws -> String {
        try XCTUnwrap(vm.groups.flatMap(\.rows).first { $0.title == title }?.playbackKey, "no row titled \(title)")
    }

    // MARK: - Fixture F, .tiers

    func testTheTiersBodyOfFixtureF() throws {
        let vm = tiersModel()
        vm.apply(state([groupA(), groupB()]))
        let body = vm.panelBody
        XCTAssertEqual(body.mode, .tiers)

        let card = try XCTUnwrap(body.card)
        XCTAssertEqual(card.rowKey, try key(vm, "B 2160p"))
        XCTAssertTrue(card.isSettled)
        XCTAssertEqual(card.considered, 6)
        XCTAssertEqual(card.rankLine, StreamPickerCopy.rankLine(considered: 6))

        XCTAssertEqual(body.alternatives.map(\.kind), [.bestFhd, .showAll], "the best is direct: no direct pill")
        XCTAssertEqual(body.alternatives[0].rowKey, try key(vm, "A 1080p"), "ties keep list order")
        XCTAssertEqual(body.alternatives.map(\.title), ["Best 1080p", "Show all 6"])

        XCTAssertEqual(body.sections.map(\.id), ["tier|UHD", "tier|FHD", "tier|HD"])
        XCTAssertEqual(body.sections.map(\.visibleRows.count), [1, 2, 1])
        XCTAssertEqual(body.sections.map(\.hiddenCount), [0, 2, 0])
        let fhd = body.sections[1]
        XCTAssertEqual(fhd.visibleRows.map(\.title), ["A 1080p", "A 1080p HEVC"], "the first two in list order")
        XCTAssertEqual(fhd.firstHiddenKey, try key(vm, "A 1080p x264"))
        XCTAssertNil(body.sections[0].firstHiddenKey)
        XCTAssertFalse(fhd.isExpanded)
        XCTAssertEqual(fhd.moreFocusKey, "more:tier|FHD")

        let ids = body.items.map(\.id)
        XCTAssertEqual(ids, [
            "bestpick", "alternatives", "header|tier|UHD", try key(vm, "B 2160p"),
            "header|tier|FHD", try key(vm, "A 1080p"), try key(vm, "A 1080p HEVC"), "more:tier|FHD",
            "header|tier|HD", try key(vm, "A 720p"),
        ])
        XCTAssertEqual(body.firstFocusKey, "bestpick")
        XCTAssertEqual(body.focusKeys, [
            "bestpick", "alt:fhd", "alt:all", try key(vm, "B 2160p"), try key(vm, "A 1080p"),
            try key(vm, "A 1080p HEVC"), try key(vm, "A 720p"), "more:tier|FHD",
        ])
    }

    func testTwoRowsHaveNoMoreRowAndThreeHaveOne() {
        func sections(_ count: Int) -> [StreamListSection] {
            let rows = (0..<count).map { i in
                StreamRowModel(key: "r\(i)", title: "r\(i)", description: nil, badges: [], sizeBytes: nil,
                               badgesOnTop: false, showsAddonColumn: false, showsAddonName: true, addonName: "A",
                               addonLogo: nil, isYouTube: false, playbackKey: "p\(i)", resolution: 1080,
                               headline: "1080p", hdrMark: nil, videoFacts: [], audioFacts: [], cachedState: nil)
            }
            return [StreamListSection(id: "tier|FHD", title: "1080p", count: count, isLoading: false,
                                      showsLabel: true, rows: rows)]
        }
        let two = StreamPickerBodyModel.build(mode: .tiers, sections: sections(2), firstRowKey: "r0",
                                              selection: .none, settled: true, expanded: [])
        XCTAssertEqual(two.sections[0].hiddenCount, 0)
        XCTAssertNil(two.sections[0].firstHiddenKey)
        XCTAssertFalse(two.items.contains { if case .more = $0 { return true } else { return false } })
        let three = StreamPickerBodyModel.build(mode: .tiers, sections: sections(3), firstRowKey: "r0",
                                                selection: .none, settled: true, expanded: [])
        XCTAssertEqual(three.sections[0].hiddenCount, 1)
        XCTAssertEqual(StreamPickerCopy.moreText(three.sections[0].hiddenCount), "1 more")
        XCTAssertEqual(three.sections[0].firstHiddenKey, "r2")
        XCTAssertTrue(three.items.contains { if case .more = $0 { return true } else { return false } })
        let expanded = StreamPickerBodyModel.build(mode: .tiers, sections: sections(3), firstRowKey: "r0",
                                                   selection: .none, settled: true, expanded: ["tier|FHD"])
        XCTAssertEqual(expanded.sections[0].visibleRows.count, 3)
        XCTAssertEqual(expanded.sections[0].hiddenCount, 0)
        XCTAssertTrue(expanded.sections[0].isExpanded)
    }

    // MARK: - firstFocusKey

    func testFirstFocusKeyIsTheFirstPillWhenNothingIsEligible() throws {
        let vm = tiersModel(cachedOnly: true)
        vm.apply(state([groupA(), groupB()]))
        XCTAssertNil(vm.panelBody.card, "plain HTTP links are never cached: nothing is eligible")
        XCTAssertEqual(vm.panelBody.alternatives.map(\.kind), [.bestDirect, .showAll])
        XCTAssertEqual(vm.panelBody.alternatives[0].rowKey, try key(vm, "B 2160p"), "bestDirect ignores Cached Only")
        XCTAssertEqual(vm.panelBody.firstFocusKey, "alt:direct")
    }

    func testFirstFocusKeyFromPlainValues() {
        let vm = tiersModel()
        vm.apply(state([groupA(), groupB()]))
        let sections = StreamListSection.build(groups: vm.groups, mode: .quality, selectedFilter: nil)
        let noPick = StreamPickerBodyModel.build(mode: .tiers, sections: sections, firstRowKey: vm.firstRowKey,
                                                 selection: .none, settled: true, expanded: [])
        XCTAssertNil(noPick.card)
        XCTAssertEqual(noPick.alternatives.map(\.kind), [.showAll])
        XCTAssertEqual(noPick.firstFocusKey, "alt:all")
        let empty = StreamPickerBodyModel.build(mode: .tiers, sections: [], firstRowKey: nil, selection: .none,
                                                settled: true, expanded: [])
        XCTAssertNil(empty.firstFocusKey)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertTrue(empty.alternatives.isEmpty)
    }

    // MARK: - The upgrade gate through the view model

    func testALoadingRepublishSwapsTheCardOnceAndKeepsItsKey() throws {
        let vm = tiersModel()
        var sends = 0
        let sub = vm.objectWillChange.sink { sends += 1 }
        defer { sub.cancel() }

        // 1: A answered, B still loading with nothing yet.
        vm.apply(state([group("a", "Add A", ["A 1080p"]), group("b", "Add B", [], loading: true)], loading: true))
        let first = try XCTUnwrap(vm.panelBody.card)
        XCTAssertEqual(first.rowKey, try key(vm, "A 1080p"))
        XCTAssertFalse(first.isSettled, "the fan-out is still answering: Best So Far")
        XCTAssertEqual(vm.panelBody.items.first?.id, "bestpick")

        // 2: A republishes with a better stream while B is still loading: no new answer, so held.
        let before = sends
        vm.apply(state([group("a", "Add A", ["A 1080p", "A 2160p"]), group("b", "Add B", [], loading: true)],
                       loading: true))
        XCTAssertGreaterThan(sends, before, "the sections changed, so the picker republishes")
        let held = try XCTUnwrap(vm.panelBody.card)
        XCTAssertEqual(held.rowKey, first.rowKey, "the card is held")
        XCTAssertFalse(held.isSettled)
        XCTAssertEqual(vm.panelBody.items.first?.id, "bestpick")

        // 3: B answers: the card swaps once, to the best of all, and the fan-out is settled.
        vm.apply(state([group("a", "Add A", ["A 1080p", "A 2160p"]), group("b", "Add B", ["B 2160p DV"])]))
        let swapped = try XCTUnwrap(vm.panelBody.card)
        XCTAssertEqual(swapped.rowKey, try key(vm, "B 2160p DV"))
        XCTAssertTrue(swapped.isSettled)
        XCTAssertEqual(vm.panelBody.items.first?.id, "bestpick", "the key never changes: focus stays put")
    }

    func testTheLastAddonAnsweringWithNothingListableFlipsTheKickerToBestPick() throws {
        let vm = tiersModel()
        vm.apply(state([group("a", "Add A", ["A 1080p"]), group("b", "Add B", [], loading: true)], loading: true))
        XCTAssertEqual(vm.panelBody.card?.isSettled, false, "Best So Far while B is still out")
        // B answers with nothing: the groups' rows are unchanged, only the answered / settled triggers differ.
        vm.apply(state([group("a", "Add A", ["A 1080p"]), group("b", "Add B", [])]))
        XCTAssertEqual(vm.panelBody.card?.isSettled, true, "settled: the kicker flips to Best Pick")
    }

    func testTheGateTreatsARestartedAnswerCountAsAnUpgradeMoment() {
        let shown = StreamBestPickSelection(bestKey: "old", fhdKey: nil, directKey: nil)
        let fresh = StreamBestPickSelection(bestKey: "new", fhdKey: nil, directKey: nil)
        let previous = StreamBestPickAnchor(selection: shown, answered: 3, settled: false, filter: nil)
        let result = StreamBestPickGate.resolve(
            previous: previous, fresh: fresh, eligibleKeys: ["old", "new"], availableKeys: ["old", "new"],
            answered: 1, settled: false, filter: nil, policy: .perAnswer)
        XCTAssertEqual(result.selection.bestKey, "new", "a lower count is a new fan-out, not a hold")
        let held = StreamBestPickGate.resolve(
            previous: previous, fresh: fresh, eligibleKeys: ["old", "new"], availableKeys: ["old", "new"],
            answered: 3, settled: false, filter: nil, policy: .perAnswer)
        XCTAssertEqual(held.selection.bestKey, "old", "the same count still holds")
    }

    func testOnCompletionPolicyHoldsUntilTheFanOutSettles() throws {
        StreamsViewModel.bestPickUpgradePolicy = .onCompletion
        let vm = tiersModel()
        vm.apply(state([group("a", "Add A", ["A 1080p"]), group("b", "Add B", [], loading: true)], loading: true))
        let first = try XCTUnwrap(vm.panelBody.card)
        vm.apply(state([group("a", "Add A", ["A 1080p", "A 2160p"]), group("b", "Add B", [], loading: true)],
                       loading: true))
        XCTAssertEqual(vm.panelBody.card?.rowKey, first.rowKey, "held")
        // B answers but C is still loading: with onCompletion that is not an upgrade moment either.
        vm.apply(state([group("a", "Add A", ["A 1080p", "A 2160p"]), group("b", "Add B", ["B 2160p DV"]),
                        group("c", "Add C", [], loading: true)], loading: true))
        XCTAssertEqual(vm.panelBody.card?.rowKey, first.rowKey, "still held while any add-on loads")
        vm.apply(state([group("a", "Add A", ["A 1080p", "A 2160p"]), group("b", "Add B", ["B 2160p DV"]),
                        group("c", "Add C", ["C 720p"])]))
        XCTAssertEqual(vm.panelBody.card?.rowKey, try key(vm, "B 2160p DV"), "settled: swapped once")
        XCTAssertTrue(vm.panelBody.card?.isSettled ?? false)
    }

    func testRejectingTheCardsStreamSwapsTheCard() throws {
        let vm = tiersModel()
        vm.apply(state([groupA(), groupB()]))
        let uhd = try playbackKey(vm, "B 2160p")
        vm.setRejectedKeys([uhd])
        let card = try XCTUnwrap(vm.panelBody.card)
        XCTAssertEqual(card.rowKey, try key(vm, "A 1080p"), "the four 1080p rows tie; list order puts A's first")
        XCTAssertFalse(vm.panelBody.alternatives.contains { $0.kind == .bestFhd }, "the best is FHD already")
        XCTAssertFalse(vm.panelBody.alternatives.contains { $0.kind == .bestDirect }, "the best is direct already")
        XCTAssertEqual(vm.panelBody.firstFocusKey, "bestpick")
        XCTAssertEqual(vm.panelBody.items.first?.id, "bestpick")
    }

    func testAnIdenticalRepublishOrRejectionPublishesNothing() {
        let vm = tiersModel()
        var sends = 0
        let sub = vm.objectWillChange.sink { sends += 1 }
        defer { sub.cancel() }
        vm.apply(state([groupA(), groupB()]))
        XCTAssertGreaterThan(sends, 0)
        let after = sends
        vm.apply(state([groupA(), groupB()]))
        XCTAssertEqual(sends, after, "an equal republish must not invalidate the picker")
        vm.setRejectedKeys([])
        XCTAssertEqual(sends, after, "the same (empty) rejected set is a no-op")
        vm.setRejectedKeys(["x"])
        let rejected = sends
        vm.setRejectedKeys(["x"])
        XCTAssertEqual(sends, rejected, "the same set again publishes nothing")
    }

    // MARK: - Chip change

    func testAChipChangeRecomputesThePickWithinTheFilter() throws {
        let vm = tiersModel()
        vm.apply(state([groupA(), groupB()]))
        XCTAssertEqual(vm.panelBody.card?.rowKey, try key(vm, "B 2160p"))
        vm.apply(state([groupA(), groupB()], filter: "a"))
        let body = vm.panelBody
        XCTAssertEqual(body.card?.rowKey, try key(vm, "A 1080p"))
        XCTAssertEqual(body.card?.considered, 4)
        XCTAssertEqual(body.alternatives.map(\.kind), [.showAll], "the best is FHD already")
        XCTAssertEqual(body.alternatives.map(\.title), ["Show all 4"])
        XCTAssertEqual(body.sections.map(\.id), ["tier|FHD", "tier|HD"])
        XCTAssertEqual(body.sections[0].visibleRows.count, 2)
        XCTAssertEqual(body.sections[0].hiddenCount, 1)
        XCTAssertEqual(body.sections[1].hiddenCount, 0)
    }

    // MARK: - Expansion

    func testExpansionSurvivesARepublishAndResetsOnANewLoadOrFilter() throws {
        let vm = tiersModel()
        vm.apply(state([groupA(), groupB()]))
        vm.expandSection("tier|FHD")
        var body = vm.panelBody
        let fhd = try XCTUnwrap(body.sections.first { $0.id == "tier|FHD" })
        XCTAssertTrue(fhd.isExpanded)
        XCTAssertEqual(fhd.visibleRows.count, 4)
        XCTAssertEqual(fhd.hiddenCount, 0)
        XCTAssertFalse(body.items.contains { if case .more = $0 { return true } else { return false } })
        XCTAssertTrue(body.focusKeys.contains(try key(vm, "A 1080p x264")))
        XCTAssertFalse(body.focusKeys.contains("more:tier|FHD"))

        vm.apply(state([groupA(), groupB()]))
        XCTAssertEqual(vm.panelBody.sections.first { $0.id == "tier|FHD" }?.visibleRows.count, 4,
                       "the same groups keep the expansion")

        vm.expandSection("tier|NOPE")
        XCTAssertEqual(vm.panelBody, body, "an unknown id is a no-op")

        // A new load collapses again. (`reload()` calls the repository, so the reset is called directly.)
        vm.resetForNewLoad()
        vm.apply(state([groupA(), groupB()]))
        body = vm.panelBody
        XCTAssertEqual(body.sections.first { $0.id == "tier|FHD" }?.visibleRows.count, 2)
        XCTAssertEqual(body.sections.first { $0.id == "tier|FHD" }?.hiddenCount, 2)

        // A different filter is a different list.
        vm.expandSection("tier|FHD")
        XCTAssertEqual(vm.panelBody.sections.first { $0.id == "tier|FHD" }?.hiddenCount, 0)
        vm.apply(state([groupA(), groupB()], filter: "a"))
        XCTAssertEqual(vm.panelBody.sections.first { $0.id == "tier|FHD" }?.hiddenCount, 1, "collapsed again")
    }

    // MARK: - Grouping

    func testAddonGroupingCollapsesPerAddonSection() throws {
        let vm = tiersModel()
        vm.receive(badgeSettings: try settings(.addon))
        vm.receive(state([groupA(), groupB()]))
        let body = vm.panelBody
        XCTAssertEqual(body.mode, .tiers)
        XCTAssertEqual(body.sections.map(\.id), ["addon|a", "addon|b"])
        XCTAssertEqual(body.sections.map(\.visibleRows.count), [2, 2])
        XCTAssertEqual(body.sections.map(\.hiddenCount), [2, 0])
        XCTAssertEqual(body.sections.map(\.showsLabel), [true, true], "labels shown under All")
        XCTAssertEqual(body.sections.map(\.title), ["Add A", "Add B"])
        XCTAssertEqual(body.sections[0].moreFocusKey, "more:addon|a")
        XCTAssertNotNil(body.card)
    }

    // MARK: - Full List and Show all

    func testFullListIsTheAListWithTheASectionsUntouched() {
        let tiers = tiersModel()
        tiers.apply(state([groupA(), groupB()]))

        let full = StreamsViewModel(type: "movie", videoId: "tt1")
        full.listOpensWith = { .fullList }
        full.autoPlayCachedOnly = { false }
        full.apply(state([groupA(), groupB()]))
        XCTAssertEqual(full.panelBody.mode, .list)
        XCTAssertNil(full.panelBody.card)
        XCTAssertTrue(full.panelBody.items.isEmpty)
        XCTAssertTrue(full.panelBody.alternatives.isEmpty)
        XCTAssertEqual(full.panelBody.firstFocusKey, full.firstRowKey)
        XCTAssertNotNil(full.firstRowKey)
        XCTAssertEqual(full.sections, tiers.sections, "the A batch's sections are the same in both modes")
    }

    func testShowAllSwapsToTheListAndStays() {
        let vm = tiersModel()
        vm.apply(state([groupA(), groupB()]))
        XCTAssertEqual(vm.panelBody.mode, .tiers)
        vm.showAll()
        XCTAssertEqual(vm.panelBody.mode, .list)
        XCTAssertNil(vm.panelBody.card)
        XCTAssertEqual(vm.panelBody.firstFocusKey, vm.firstRowKey)
        vm.apply(state([groupA(["A 480p"]), groupB()]))
        XCTAssertEqual(vm.panelBody.mode, .list, "a further apply stays in the list")
        XCTAssertEqual(vm.panelBody.firstFocusKey, vm.firstRowKey)
    }

    func testMoreFocusKeyCarriesTheSectionId() {
        let section = StreamTierPreviewSection(id: "tier|FHD", title: "1080p", count: 3, isLoading: false,
                                               showsLabel: true, visibleRows: [], hiddenCount: 1,
                                               firstHiddenKey: nil, isExpanded: false)
        XCTAssertEqual(section.moreFocusKey, "more:tier|FHD")
    }
}
