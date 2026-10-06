import XCTest
import SharedCore
@testable import NuvioTV

/// Search & Discover batch 2026-10-06 (O3 Stage Discover, plan A1, A8): the stage Discover page's
/// pure plan — one row per genre, the no-genre fallback (one row per catalog of the type), unique
/// keys, each row's section (target, add-on name, See All gate), the Grid pill's section, the band
/// gate's position, the "no sources" states and the selection cache.
@MainActor
final class DiscoverRowsPlanTests: XCTestCase {

    // MARK: - Fixtures

    private func option(_ key: String,
                        type: String = "movie",
                        name: String = "Popular",
                        addon: String = "Cinemeta",
                        genres: [String] = [],
                        genreRequired: Bool = false,
                        paginates: Bool = true) -> DiscoverCatalogOption {
        DiscoverCatalogOption(key: key,
                              addonName: addon,
                              manifestUrl: "https://\(addon.lowercased()).example/manifest.json",
                              type: type,
                              catalogId: "cat-\(key)",
                              catalogName: name,
                              genreOptions: genres,
                              genreRequired: genreRequired,
                              supportsPagination: paginates)
    }

    private func item(_ id: String) -> MetaPreview {
        MetaPreview(
            id: id, type: "movie", name: "Title \(id)",
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

    private func items(_ count: Int) -> [MetaPreview] {
        (0..<count).map { item("i\($0)") }
    }

    // MARK: - Genre rows

    func testGenreCatalogGivesOneRowPerGenre() {
        let movies = option("m", genres: ["Action", "Sci-Fi", "Drama"])
        let specs = DiscoverRowsPlan.specs(for: movies, catalogs: [movies])
        XCTAssertEqual(specs.map(\.title), ["Action", "Sci-Fi", "Drama"])
        XCTAssertEqual(specs.map(\.genre), ["Action", "Sci-Fi", "Drama"])
        XCTAssertEqual(specs.map(\.order), [0, 1, 2])
        XCTAssertEqual(specs.map(\.key), ["discover|m|g0", "discover|m|g1", "discover|m|g2"])
    }

    func testGenreRowHeadingNamesTheAddon() {
        let movies = option("m", addon: "Cinemeta", genres: ["Sci-Fi"])
        let spec = DiscoverRowsPlan.specs(for: movies, catalogs: [movies])[0]
        XCTAssertEqual(spec.heading, "Sci-Fi \u{00B7} Cinemeta")
        XCTAssertEqual(spec.title, "Sci-Fi")
        XCTAssertEqual(spec.addonName, "Cinemeta")
        XCTAssertEqual(spec.subtitle, DiscoverRowsPlan.typeLabel("movie"))
    }

    func testHeadingSkipsABlankOrRepeatedAddon() {
        XCTAssertEqual(DiscoverRowsPlan.heading(title: "Sci-Fi", addonName: " "), "Sci-Fi")
        XCTAssertEqual(DiscoverRowsPlan.heading(title: "Cinemeta Popular", addonName: "Cinemeta"), "Cinemeta Popular")
    }

    func testBlankGenresAreDropped() {
        let movies = option("m", genres: ["Action", "  ", ""])
        XCTAssertEqual(DiscoverRowsPlan.specs(for: movies, catalogs: [movies]).map(\.title), ["Action"])
    }

    // MARK: - Fallback rows

    func testCatalogWithoutGenresFallsBackToOneRowPerCatalogOfTheType() {
        let popular = option("a", name: "Popular")
        let top = option("b", name: "Top Rated", addon: "TMDB")
        let series = option("c", type: "series", name: "Series Popular")
        let specs = DiscoverRowsPlan.specs(for: top,
                                           catalogs: DiscoverRowsPlan.catalogs(ofType: "movie", in: [popular, top, series]))
        // The selected catalog first, then the type's other catalogs in option order.
        XCTAssertEqual(specs.map(\.title), ["Top Rated", "Popular"])
        XCTAssertEqual(specs.map(\.key), ["discover|movie|c0", "discover|movie|c1"])
        XCTAssertEqual(specs.map(\.addonName), ["TMDB", "Cinemeta"])
        XCTAssertEqual(specs.map(\.genre), [nil, nil])
    }

    func testFallbackUsesTheRequiredGenreOfAGenreCatalog() {
        let plain = option("a", name: "Popular")
        let required = option("b", name: "By Genre", genres: ["Action", "Drama"], genreRequired: true)
        let optional = option("c", name: "Optional", genres: ["Comedy"])
        let specs = DiscoverRowsPlan.specs(for: plain, catalogs: [plain, required, optional])
        XCTAssertEqual(specs.map(\.genre), [nil, "Action", nil])
    }

    func testRowKeysAreUnique() {
        let movies = option("m", genres: (0..<30).map { "G\($0)" })
        let keys = DiscoverRowsPlan.specs(for: movies, catalogs: [movies]).map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        let fallback = DiscoverRowsPlan.specs(for: option("a"), catalogs: [option("a"), option("b"), option("c")])
        XCTAssertEqual(Set(fallback.map(\.key)).count, 3)
    }

    func testLoadingRowsCarryTheSpecs() {
        let movies = option("m", genres: ["Action", "Drama"])
        let rows = DiscoverRowsPlan.loadingRows(DiscoverRowsPlan.specs(for: movies, catalogs: [movies]))
        XCTAssertEqual(rows.map(\.status), [.loading, .loading])
        XCTAssertEqual(rows.map(\.order), [0, 1])
        XCTAssertEqual(rows.map(\.heading), ["Action \u{00B7} Cinemeta", "Drama \u{00B7} Cinemeta"])
        XCTAssertTrue(rows.allSatisfy { $0.section == nil })
    }

    // MARK: - Sections

    func testSectionTargetsTheGenrePage() throws {
        let movies = option("m", genres: ["Sci-Fi"], paginates: false)
        let spec = DiscoverRowsPlan.specs(for: movies, catalogs: [movies])[0]
        let section = try XCTUnwrap(DiscoverRowsPlan.section(spec, page: DiscoverRowPage(items: items(3), hasMore: true)))
        XCTAssertEqual(section.key, spec.key)
        XCTAssertEqual(section.title, "Sci-Fi")
        XCTAssertEqual(section.addonName, "Cinemeta")
        XCTAssertEqual(section.subtitle, DiscoverRowsPlan.typeLabel("movie"))
        XCTAssertTrue(section.hasMore)
        XCTAssertEqual(section.availableItemCount, 3)
        let target = try XCTUnwrap(section.target as? CatalogTargetAddon)
        XCTAssertEqual(target.manifestUrl, movies.manifestUrl)
        XCTAssertEqual(target.contentType, "movie")
        XCTAssertEqual(target.catalogId, movies.catalogId)
        XCTAssertEqual(target.genre, "Sci-Fi")
        XCTAssertNil(target.search)
        XCTAssertFalse(target.supportsPagination)
    }

    func testSectionShowsAtMostThePreviewLimit() throws {
        let movies = option("m", genres: ["Action"])
        let spec = DiscoverRowsPlan.specs(for: movies, catalogs: [movies])[0]
        let section = try XCTUnwrap(DiscoverRowsPlan.section(spec, page: DiscoverRowPage(items: items(25), hasMore: false)))
        XCTAssertEqual(section.items.count, StripRowsPlan.previewLimit)
        XCTAssertEqual(section.availableItemCount, 25)
        XCTAssertFalse(section.hasMore)
    }

    func testSettledRowStatus() {
        let movies = option("m", genres: ["Action"])
        let spec = DiscoverRowsPlan.specs(for: movies, catalogs: [movies])[0]
        let loaded = DiscoverRowsPlan.settledRow(spec, page: DiscoverRowPage(items: items(2), hasMore: false))
        XCTAssertEqual(loaded.status, .loaded)
        XCTAssertEqual(loaded.itemKeys.count, 2)
        XCTAssertNotNil(loaded.section)
        let empty = DiscoverRowsPlan.settledRow(spec, page: DiscoverRowPage(items: [], hasMore: true))
        XCTAssertEqual(empty.status, .empty)
        XCTAssertNil(empty.section)
        XCTAssertEqual(DiscoverRowsPlan.failedRow(spec).status, .failed)
        XCTAssertEqual(DiscoverRowsPlan.failedRow(spec).id, spec.key)
    }

    // MARK: - Grid pill and band gate

    private func rows(_ statuses: [StripRowStatus]) -> [StripRow] {
        let movies = option("m", genres: statuses.indices.map { "G\($0)" })
        let specs = DiscoverRowsPlan.specs(for: movies, catalogs: [movies])
        return zip(specs, statuses).map { spec, status in
            switch status {
            case .loaded: return DiscoverRowsPlan.settledRow(spec, page: DiscoverRowPage(items: items(2), hasMore: false))
            case .empty: return DiscoverRowsPlan.settledRow(spec, page: DiscoverRowPage(items: [], hasMore: false))
            case .failed: return DiscoverRowsPlan.failedRow(spec)
            case .loading: return DiscoverRowsPlan.loadingRows([spec])[0]
            }
        }
    }

    func testGridSectionIsTheFocusedLoadedRowElseTheFirst() {
        let strip = rows([.empty, .loaded, .loaded])
        XCTAssertEqual(DiscoverRowsPlan.gridSection(focusedRowKey: strip[2].id, rows: strip)?.key, strip[2].id)
        XCTAssertEqual(DiscoverRowsPlan.gridSection(focusedRowKey: nil, rows: strip)?.key, strip[1].id)
        // A focused failed row (its Retry chip) falls back to the first loaded row.
        let withFailed = rows([.loaded, .failed])
        XCTAssertEqual(DiscoverRowsPlan.gridSection(focusedRowKey: withFailed[1].id, rows: withFailed)?.key, withFailed[0].id)
        XCTAssertNil(DiscoverRowsPlan.gridSection(focusedRowKey: nil, rows: rows([.loading, .empty])))
    }

    func testFocusPositionCountsLoadedAndFailedRows() {
        let strip = rows([.empty, .failed, .loading, .loaded])
        XCTAssertEqual(DiscoverRowsPlan.focusPosition(of: strip[1].id, in: strip), 0)
        XCTAssertEqual(DiscoverRowsPlan.focusPosition(of: strip[3].id, in: strip), 1)
        XCTAssertNil(DiscoverRowsPlan.focusPosition(of: strip[0].id, in: strip))
        XCTAssertNil(DiscoverRowsPlan.focusPosition(of: strip[2].id, in: strip))
    }

    // MARK: - Labels and options

    func testCatalogLabelAddsTheAddonOnlyOnANameClash() {
        let a = option("a", name: "Popular", addon: "Cinemeta")
        let b = option("b", name: "popular", addon: "TMDB")
        let c = option("c", name: "Top Rated", addon: "TMDB")
        XCTAssertEqual(DiscoverRowsPlan.catalogLabel(a, among: [a, b, c]), "Popular \u{00B7} Cinemeta")
        XCTAssertEqual(DiscoverRowsPlan.catalogLabel(c, among: [a, b, c]), "Top Rated")
    }

    func testTypesAreDistinctInOptionOrder() {
        let options = [option("a", type: "series"), option("b", type: "movie"), option("c", type: "series")]
        XCTAssertEqual(DiscoverRowsPlan.types(options), ["series", "movie"])
    }

    func testSelectionKeyAndSignature() {
        XCTAssertEqual(DiscoverRowsPlan.selectionKey(type: "movie", catalogKey: "x:movie:top"), "movie|x:movie:top")
        let base = [option("a", genres: ["Action"])]
        XCTAssertEqual(DiscoverRowsPlan.optionsSignature(base), DiscoverRowsPlan.optionsSignature([option("a", genres: ["Action"])]))
        XCTAssertNotEqual(DiscoverRowsPlan.optionsSignature(base),
                          DiscoverRowsPlan.optionsSignature([option("a", genres: ["Action", "Drama"])]))
    }

    // MARK: - Sources state

    func testSourcesState() {
        XCTAssertEqual(DiscoverRowsPlan.sourcesState(isInitialized: true, hasEnabledAddons: true, manifestsPending: false,
                                                     manifestError: nil, hasEnabledManifest: true, optionCount: 2), .ready)
        XCTAssertEqual(DiscoverRowsPlan.sourcesState(isInitialized: false, hasEnabledAddons: false, manifestsPending: false,
                                                     manifestError: nil, hasEnabledManifest: false, optionCount: 0), .waiting)
        XCTAssertEqual(DiscoverRowsPlan.sourcesState(isInitialized: true, hasEnabledAddons: true, manifestsPending: true,
                                                     manifestError: nil, hasEnabledManifest: false, optionCount: 0), .waiting)
        XCTAssertEqual(DiscoverRowsPlan.sourcesState(isInitialized: true, hasEnabledAddons: false, manifestsPending: false,
                                                     manifestError: nil, hasEnabledManifest: false, optionCount: 0), .noAddons)
        XCTAssertEqual(DiscoverRowsPlan.sourcesState(isInitialized: true, hasEnabledAddons: true, manifestsPending: false,
                                                     manifestError: "HTTP 500", hasEnabledManifest: false, optionCount: 0),
                       .manifestFailure("HTTP 500"))
        // An error on one add-on while another has its manifest: the catalogs just aren't browsable.
        XCTAssertEqual(DiscoverRowsPlan.sourcesState(isInitialized: true, hasEnabledAddons: true, manifestsPending: false,
                                                     manifestError: "HTTP 500", hasEnabledManifest: true, optionCount: 0),
                       .noCatalogs)
    }

    // MARK: - Selection cache

    func testSelectionCacheKeepsTheLastFourLeastRecentlyUsedOut() {
        var cache = DiscoverSelectionCache<Int>(limit: 4)
        for (index, key) in ["a", "b", "c", "d"].enumerated() { cache.set(index, for: key) }
        XCTAssertEqual(cache.value(for: "a"), 0)   // a becomes most recent
        cache.set(4, for: "e")                     // evicts b, the least recent
        XCTAssertNil(cache.peek("b"))
        XCTAssertEqual(cache.keys, ["c", "d", "a", "e"])
        cache.set(9, for: "c")                     // overwrite keeps the count
        XCTAssertEqual(cache.peek("c"), 9)
        XCTAssertEqual(cache.keys.count, 4)
        cache.removeAll()
        XCTAssertTrue(cache.keys.isEmpty)
    }
}
