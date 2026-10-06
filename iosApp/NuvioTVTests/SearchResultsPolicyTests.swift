import XCTest
import SharedCore
@testable import NuvioTV

/// Search & Discover batch 2026-10-06 (B2): the pure `SearchResultsPolicy` pieces: the grouped /
/// per-add-on adapter, the suggestion chips and the four empty states.
final class SearchResultsAdapterTests: XCTestCase {

    // MARK: - Fixtures

    private func item(_ id: String, type: String = "movie", name: String? = nil) -> MetaPreview {
        MetaPreview(
            id: id, type: type, name: name ?? "Title \(id)",
            poster: nil, banner: nil, logo: nil,
            posterShape: .poster,
            description: nil, releaseInfo: nil, rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: [],
            rawPosterUrl: nil,
            landscapePoster: nil,
            rawLandscapePosterUrl: nil,
            customPosterApplied: false
        )
    }

    private func target(_ type: String) -> CatalogTarget {
        CatalogTargetAddon(manifestUrl: "https://addon.test/manifest.json",
                           contentType: type,
                           catalogId: "search",
                           genre: nil,
                           search: "dune",
                           supportsPagination: false)
    }

    private func group(_ key: String, kind: SearchResultGroupKind, type: String, title: String,
                       _ hits: [(MetaPreview, [String])]) -> SearchResultGroup {
        SearchResultGroup(key: key, kind: kind, type: type, title: title,
                          hits: hits.map { SearchHit(item: $0.0, foundIn: $0.1) },
                          representativeTarget: target(type))
    }

    private lazy var dune = item("tt1", name: "Dune")
    private lazy var duneTwo = item("tt2", name: "Dune: Part Two")
    private lazy var duneSeries = item("tt3", type: "series", name: "Dune: Prophecy")

    private var groups: [SearchResultGroup] {
        [
            group("top", kind: .topresult, type: "movie", title: "Top Result", [(dune, ["Cinemeta", "Torrentio"])]),
            group("type:movie", kind: SearchResultGroupKind.`type`, type: "movie", title: "Movies",
                  [(dune, ["Cinemeta", "Torrentio"]), (duneTwo, ["Cinemeta"])]),
            group("type:series", kind: SearchResultGroupKind.`type`, type: "series", title: "Series",
                  [(duneSeries, ["Cinemeta"])]),
        ]
    }

    private var perAddonSection: HomeCatalogSection {
        HomeCatalogSection(key: "cinemeta.movie.search", title: "Cinemeta", subtitle: "Movies",
                           addonName: "Cinemeta", target: target("movie"),
                           items: [dune], availableItemCount: 1, hasMore: true)
    }

    // MARK: - Rows

    func testDefaultModeIsGrouped() {
        XCTAssertEqual(SearchRowsMode.defaultValue, .grouped)
    }

    func testGroupedRowsAreTheTypeGroupsWithCounts() {
        let rows = SearchResultsAdapter.rows(groups: groups, sections: [perAddonSection], mode: .grouped)
        XCTAssertEqual(rows.map(\.key), ["search.group.type:movie", "search.group.type:series"])
        XCTAssertEqual(rows.map(\.title), ["Movies · 2", "Series · 1"])
        XCTAssertEqual(rows[0].items.map(\.id), ["tt1", "tt2"])
        XCTAssertEqual(rows[0].availableItemCount, 2)
        XCTAssertFalse(rows[0].hasMore)
        XCTAssertEqual(rows[0].addonName, "")
        XCTAssertEqual(rows[0].subtitle, "")
        XCTAssertEqual((rows[1].target as? CatalogTargetAddon)?.contentType, "series")
    }

    func testPerAddonModePassesTheSectionsThrough() {
        let rows = SearchResultsAdapter.rows(groups: groups, sections: [perAddonSection], mode: .perAddon)
        XCTAssertEqual(rows.map(\.key), ["cinemeta.movie.search"])
    }

    func testEmptyGroupsAreDropped() {
        let empty = group("type:anime", kind: SearchResultGroupKind.`type`, type: "anime", title: "Anime", [])
        XCTAssertTrue(SearchResultsAdapter.rows(groups: [empty], sections: [], mode: .grouped).isEmpty)
    }

    // MARK: - Top result, Found in, People

    func testTopResultIsTheTopGroupsHit() {
        XCTAssertEqual(SearchResultsAdapter.topResult(groups: groups, mode: .grouped)?.id, "tt1")
        XCTAssertNil(SearchResultsAdapter.topResult(groups: groups, mode: .perAddon))
    }

    func testWithoutATopGroupTheFirstNonEmptyGroupLeads() {
        let rest = Array(groups.dropFirst())
        XCTAssertEqual(SearchResultsAdapter.topResult(groups: rest, mode: .grouped)?.id, "tt1")
        XCTAssertNil(SearchResultsAdapter.topResult(groups: [], mode: .grouped))
    }

    func testFoundInIsKeyedByTypeAndId() {
        let map = SearchResultsAdapter.foundIn(groups: groups, mode: .grouped)
        XCTAssertEqual(map["movie:tt1"], ["Cinemeta", "Torrentio"])
        XCTAssertEqual(map["series:tt3"], ["Cinemeta"])
        XCTAssertEqual(dune.stableKey(), "movie:tt1")
        XCTAssertTrue(SearchResultsAdapter.foundIn(groups: groups, mode: .perAddon).isEmpty)
    }

    func testPeopleMapToMetaPerson() {
        let people = SearchResultsAdapter.people([
            PersonPreview(tmdbId: 1190668, name: "Timothée Chalamet",
                          profileUrl: "https://image.tmdb.org/t/p/w185/a.jpg",
                          knownForDepartment: "Acting", knownFor: ["Dune"]),
        ])
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].name, "Timothée Chalamet")
        XCTAssertEqual(people[0].role, "Acting")
        XCTAssertEqual(people[0].photo, "https://image.tmdb.org/t/p/w185/a.jpg")
        XCTAssertEqual(people[0].tmdbId?.int32Value, 1190668)
    }

    func testSuggestionCandidatesPreferKotlinsSuggestions() {
        XCTAssertEqual(
            SearchResultsAdapter.suggestionCandidates(suggestions: ["Dune Messiah"], groups: groups, sections: []),
            ["Dune Messiah"]
        )
        XCTAssertEqual(
            SearchResultsAdapter.suggestionCandidates(suggestions: [], groups: groups, sections: []).first,
            "Dune"
        )
        XCTAssertEqual(
            SearchResultsAdapter.suggestionCandidates(suggestions: [], groups: [], sections: [perAddonSection]),
            ["Dune"]
        )
    }
}

final class SearchSuggestionPolicyTests: XCTestCase {
    func testQuotedQueryComesFirst() {
        XCTAssertEqual(SearchSuggestionPolicy.chips(query: " dune ", candidates: []), ["\u{201C}dune\u{201D}"])
    }

    func testBlankQueryHasNoChips() {
        XCTAssertTrue(SearchSuggestionPolicy.chips(query: nil, candidates: ["Dune"]).isEmpty)
        XCTAssertTrue(SearchSuggestionPolicy.chips(query: "  ", candidates: ["Dune"]).isEmpty)
    }

    func testPrefixMatchesBeforeContainsMatches() {
        let chips = SearchSuggestionPolicy.completions(
            query: "dune",
            candidates: ["The Making of Dune", "Dune: Part Two", "Jodorowsky's Dune", "Dune Messiah"]
        )
        XCTAssertEqual(chips, ["Dune: Part Two", "Dune Messiah", "The Making of Dune", "Jodorowsky's Dune"])
    }

    func testDedupesCaseInsensitivelyAndDropsTheQueryAndNonMatches() {
        let chips = SearchSuggestionPolicy.completions(
            query: "Dune",
            candidates: ["dune", "DUNE", "Dune  Messiah", "dune messiah", "Arrival"]
        )
        XCTAssertEqual(chips, ["Dune  Messiah"])
    }

    func testAtMostEightCompletions() {
        let candidates = (1...20).map { "Dune \($0)" }
        let chips = SearchSuggestionPolicy.chips(query: "dune", candidates: candidates)
        XCTAssertEqual(chips.count, 1 + SearchSuggestionPolicy.limit)
        XCTAssertEqual(chips[1], "Dune 1")
    }
}

final class SearchEmptyStateTests: XCTestCase {
    private func resolve(
        _ reason: SearchEmptyStateReason?,
        enabled: Bool = true,
        manifests: Bool = true,
        options: Int = 3,
        disabled: Int = 0,
        error: String? = nil
    ) -> SearchEmptyState? {
        SearchEmptyState.resolve(reason: reason, hasEnabledAddons: enabled, anyManifestLoaded: manifests,
                                 searchOptionCount: options, disabledOptionCount: disabled,
                                 query: " dnue ", errorMessage: error)
    }

    func testNoReasonIsNoEmptyState() {
        XCTAssertNil(resolve(nil))
    }

    func testRequestFailedWithNoManifestIsAManifestFailure() {
        XCTAssertEqual(resolve(.requestfailed, manifests: false, error: "timeout"), .manifestFailure("timeout"))
        XCTAssertEqual(resolve(.requestfailed, manifests: false),
                       .manifestFailure(String(localized: "Couldn't load your add-ons.")))
        XCTAssertEqual(resolve(.requestfailed, manifests: false).flatMap(\.actionTitle), String(localized: "Retry"))
    }

    func testRequestFailedWithManifestsLoadedReadsNoResults() {
        XCTAssertEqual(resolve(.requestfailed), .noResults("dnue"))
    }

    func testNoAddonOrNoSearchCatalogIsNoneCanSearch() {
        XCTAssertEqual(resolve(.noactiveaddons, enabled: false, manifests: false, options: 0), .noneCanSearch)
        XCTAssertEqual(resolve(.nosearchcatalogs, options: 0), .noneCanSearch)
        XCTAssertNil(SearchEmptyState.noneCanSearch.actionTitle)
    }

    func testEveryOptionDisabledIsAllSourcesOff() {
        XCTAssertEqual(resolve(.nosearchcatalogs, options: 3, disabled: 3), .allSourcesOff)
        XCTAssertEqual(resolve(.noresults, options: 2, disabled: 2), .allSourcesOff)
        XCTAssertEqual(SearchEmptyState.allSourcesOff.actionTitle, String(localized: "Open Search Sources"))
    }

    func testOtherwiseNoResultsForTheQuery() {
        XCTAssertEqual(resolve(.noresults, options: 3, disabled: 2), .noResults("dnue"))
        XCTAssertEqual(SearchEmptyState.noResults("dnue").copy, String(localized: "No results for \u{2018}dnue\u{2019}"))
        XCTAssertNil(SearchEmptyState.noResults("dnue").actionTitle)
    }
}
