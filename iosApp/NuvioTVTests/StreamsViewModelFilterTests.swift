import XCTest
import SharedCore
@testable import NuvioTV

/// Stream picker A, P2: `StreamsViewModel.apply(_:)` under the shared per-add-on filter. The chips
/// span every add-on of the fan-out (loading, failed, empty ones included) with listable counts;
/// `groups` holds only the selected add-on; the info pane's progress counts the whole fan-out; and
/// a selected add-on with nothing listable gets its own empty-state line.
@MainActor
final class StreamsViewModelFilterTests: XCTestCase {

    private let hints = StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                            filename: nil, proxyHeaders: nil, audioDelayMs: nil)

    private func stream(_ name: String, url: String? = nil, infoHash: String? = nil, addonId: String) -> StreamItem {
        StreamItem(
            name: name, title: nil, description: "\(name).release", url: url, infoHash: infoHash, fileIdx: nil,
            externalUrl: nil, ytId: nil, sources: [], sourceName: nil, addonName: "Add-on", addonId: addonId,
            addonLogo: nil, streamType: nil, behaviorHints: hints,
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
        )
    }

    private func group(_ name: String, id: String, streams: [StreamItem], loading: Bool = false, error: String? = nil) -> AddonStreamGroup {
        AddonStreamGroup(addonName: name, addonId: id, streams: streams, isLoading: loading, error: error)
    }

    private func state(_ groups: [AddonStreamGroup], filter: String?, loading: Bool) -> StreamsUiState {
        StreamsUiState(
            requestToken: "t", groups: groups, activeAddonIds: [], installedAddonIds: [],
            selectedFilter: filter, isAnyLoading: loading, emptyStateReason: nil, autoPlayStream: nil,
            autoPlayCandidates: [], isDirectAutoPlayFlow: false, showDirectAutoPlayOverlay: false,
            overlayMessage: nil
        )
    }

    private func fanOut(loading torrentioLoading: Bool = false) -> [AddonStreamGroup] {
        [
            group("Comet", id: "addon:comet", streams: [
                stream("C1", url: "https://cdn.example.com/c1.mkv", addonId: "addon:comet"),
                stream("C2", url: "https://cdn.example.com/c2.mkv", addonId: "addon:comet"),
                // A torrent with debrid off: not listable, so it must not count.
                stream("C3", infoHash: "feedface", addonId: "addon:comet"),
            ]),
            group("Torrentio", id: "addon:torrentio", streams: torrentioLoading ? [] : [
                stream("T1", url: "https://cdn.example.com/t1.mkv", addonId: "addon:torrentio"),
            ], loading: torrentioLoading),
            group("AIO", id: "addon:aio", streams: [], error: "HTTP 502"),
        ]
    }

    func testChipsSpanEveryAddonWithListableCounts() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state(fanOut(loading: true), filter: nil, loading: true))

        XCTAssertEqual(vm.sourceChips.map(\.id), ["addon:comet", "addon:torrentio", "addon:aio"])
        XCTAssertEqual(vm.sourceChips.map(\.count), [2, 0, 0])
        XCTAssertEqual(vm.sourceChips.map(\.isLoading), [false, true, false])
        XCTAssertEqual(vm.sourceChips.map(\.hasError), [false, false, true])
        XCTAssertEqual(vm.sourceChips[2].error, "HTTP 502")
        XCTAssertNil(vm.selectedFilter)
        // "All": every listable group is in the list, empty and failed ones are not.
        XCTAssertEqual(vm.groups.map(\.id), ["addon:comet"])
    }

    func testSelectedAddonFiltersTheListNotTheChipsOrTheProgress() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state(fanOut(), filter: "addon:torrentio", loading: false))

        XCTAssertEqual(vm.selectedFilter, "addon:torrentio")
        XCTAssertEqual(vm.groups.map(\.id), ["addon:torrentio"])
        XCTAssertEqual(vm.groups.first?.rows.count, 1)
        XCTAssertEqual(vm.firstRowKey, vm.groups.first?.rowKeys.first)
        XCTAssertEqual(vm.sourceChips.count, 3, "the chips still show every add-on")
        // The info pane keeps counting the whole fan-out: 3 listable sources from 2 add-ons.
        XCTAssertEqual(vm.fanOut.sources, 3)
        XCTAssertEqual(vm.fanOut.addonsWithSources, 2)
        XCTAssertEqual(vm.fanOut.expected, 3)
        XCTAssertEqual(vm.fanOut.answered, 3)
        XCTAssertNil(vm.emptyReason)
    }

    func testFailedAddonSelectedExplainsItself() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state(fanOut(), filter: "addon:aio", loading: false))

        XCTAssertEqual(vm.groups, [])
        XCTAssertEqual(vm.emptyReason, "AIO couldn\u{2019}t be reached.")
        XCTAssertEqual(vm.emptyReasonHint, "HTTP 502")
    }

    func testEmptyAddonSelectedExplainsItself() {
        let empty = group("Quiet", id: "addon:quiet", streams: [])
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state(fanOut() + [empty], filter: "addon:quiet", loading: false))

        XCTAssertEqual(vm.groups, [])
        XCTAssertEqual(vm.emptyReason, "Quiet returned no playable sources.")
        XCTAssertNil(vm.emptyReasonHint)
    }

    func testCachedOnlyHidingEverythingExplainsItself() {
        let hidden = AddonStreamGroup(
            addonName: "AIO", addonId: "addon:aio", streams: [], isLoading: false, error: nil,
            cachedOnlyHiddenCount: 3
        )
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state([hidden], filter: nil, loading: false))

        XCTAssertEqual(vm.groups, [])
        XCTAssertEqual(vm.emptyReason, "3 uncached sources hidden by Cached Sources Only.")
        XCTAssertEqual(vm.emptyReasonHint, "Turn it off in Settings \u{2192} Sources to see them.")
    }

    func testCachedOnlyReasonIsSingularForOne() {
        let (reason, hint) = StreamsViewModel.describeCachedOnlyHidden(count: 1)
        XCTAssertEqual(reason, "1 uncached source hidden by Cached Sources Only.")
        XCTAssertNotNil(hint)
    }

    func testTheReloadFrameHasNoReason() {
        // A reload first emits an empty, non-loading state (no groups, no reason): not a verdict.
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state([], filter: nil, loading: false))

        XCTAssertEqual(vm.groups, [])
        XCTAssertNil(vm.emptyReason)
        XCTAssertFalse(vm.fanOut.hasOutcome)
    }

    func testLoadingAddonSelectedShowsNoReasonYet() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state(fanOut(loading: true), filter: "addon:torrentio", loading: true))

        XCTAssertEqual(vm.groups, [])
        XCTAssertNil(vm.emptyReason)
        XCTAssertTrue(vm.isLoading)
    }

    // MARK: - P5: chip labels and order

    func testChipLabelsFollowTheFanOut() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state(fanOut(loading: true), filter: nil, loading: true))

        // The loading chip leaves its count out, and so does a failed chip with nothing listable
        // (review r1 Q2: "AIO · 0" beside a spoken "failed" was wrong; it reads "AIO" on its
        // error tint for the linger).
        XCTAssertEqual(vm.sourceChips.map(SourceChipRow.label(for:)),
                       ["Comet \u{00B7} 2", "Torrentio", "AIO"])
        // `chipsToDrop` is pure: it names the failed empty chip in either state. The settle gate
        // (drop only once the fan-out has finished) is `StreamPickerView.scheduleErrorChipDrop`.
        XCTAssertEqual(SourceChipRow.chipsToDrop(vm.sourceChips), ["addon:aio"])

        vm.apply(state(fanOut(), filter: nil, loading: false))

        XCTAssertEqual(vm.sourceChips.map(SourceChipRow.label(for:)),
                       ["Comet \u{00B7} 2", "Torrentio \u{00B7} 1", "AIO"])
        XCTAssertEqual(SourceChipRow.chipsToDrop(vm.sourceChips), ["addon:aio"])
    }

    func testChipOrderIsGroupOrder() {
        let torrentio = group("Torrentio", id: "addon:torrentio", streams: [
            stream("T1", url: "https://cdn.example.com/t1.mkv", addonId: "addon:torrentio"),
        ])
        let aio = group("AIO", id: "addon:aio", streams: [], error: "HTTP 502")
        let comet = group("Comet", id: "addon:comet", streams: [
            stream("C1", url: "https://cdn.example.com/c1.mkv", addonId: "addon:comet"),
        ])
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        // Not alphabetical (review r1 P2), so a name sort could not pass this.
        vm.apply(state([torrentio, aio, comet], filter: nil, loading: false))

        XCTAssertEqual(vm.sourceChips.map(\.id), ["addon:torrentio", "addon:aio", "addon:comet"])
        // Under "All" only the listable groups are listed, in that same order.
        XCTAssertEqual(vm.groups.map(\.id), ["addon:torrentio", "addon:comet"])
    }
}
