import XCTest
import SharedCore
@testable import NuvioTV

/// Search & Discover batch 2026-10-06 (O3 Stage Discover, plan A1, A8): which genre pages the stage
/// Discover page fetches and when — the cap of 5, the forward walk past empty first genres,
/// `allSettled` with lazily requested rows — and the view model's half: a selection change cancels
/// the fetches in flight (a late result never lands), and going back to a cached selection reuses
/// its rows, refetching only what was cancelled.
@MainActor
final class DiscoverLoadSchedulerTests: XCTestCase {

    // MARK: - Fixtures

    private func option(_ key: String, type: String = "movie", genres: [String]) -> DiscoverCatalogOption {
        DiscoverCatalogOption(key: key,
                              addonName: "Cinemeta",
                              manifestUrl: "https://cinemeta.example/manifest.json",
                              type: type,
                              catalogId: "cat-\(key)",
                              catalogName: "Popular \(key)",
                              genreOptions: genres,
                              genreRequired: false,
                              supportsPagination: true)
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

    private func loadingRows(_ count: Int) -> [StripRow] {
        let movies = option("m", genres: (0..<count).map { "G\($0)" })
        return DiscoverRowsPlan.loadingRows(DiscoverRowsPlan.specs(for: movies, catalogs: [movies]))
    }

    private func settle(_ rows: [StripRow], _ index: Int, as status: StripRowStatus) -> [StripRow] {
        var rows = rows
        let row = rows[index]
        rows[index] = StripRow(id: row.id, order: row.order, heading: row.heading, status: status,
                               section: nil, itemKeys: [], itemCount: 0, hasMore: false)
        return rows
    }

    // MARK: - Scheduler

    func testNothingRequestedStartsRowZeroByTheForwardWalk() {
        let rows = loadingRows(6)
        XCTAssertEqual(DiscoverLoadScheduler.next(rows: rows, requested: [], inFlight: []), [rows[0].id])
    }

    func testRequestedRowsStartInOrderUpToTheCap() {
        let rows = loadingRows(8)
        let requested = Set(rows.map(\.id))
        let start = DiscoverLoadScheduler.next(rows: rows, requested: requested, inFlight: [])
        XCTAssertEqual(start, rows.prefix(5).map(\.id))
        XCTAssertEqual(DiscoverLoadScheduler.next(rows: rows, requested: requested, inFlight: Set(start)), [])
        // Row 0 finishes: it leaves the in-flight set AND settles, so the freed slot goes to the
        // next requested row (a row that merely left in-flight while still `.loading` would be
        // restarted, which is the cancellation-resume path).
        let settled = settle(rows, 0, as: .loaded)
        let afterOne = Set(start.dropFirst())
        XCTAssertEqual(DiscoverLoadScheduler.next(rows: settled, requested: requested, inFlight: afterOne), [rows[5].id])
    }

    func testUnrequestedRowsWaitWhileARequestedRowIsLoading() {
        let rows = loadingRows(6)
        let requested: Set<String> = [rows[0].id, rows[1].id, rows[2].id]
        // Rows 0–2 mounted and in flight: nothing below them starts (lazy loading).
        XCTAssertEqual(DiscoverLoadScheduler.next(rows: rows, requested: requested, inFlight: requested), [])
    }

    func testForwardWalkPastEmptyFirstGenres() {
        var rows = loadingRows(6)
        let requested: Set<String> = [rows[0].id, rows[1].id, rows[2].id]
        rows = settle(rows, 0, as: .empty)
        rows = settle(rows, 1, as: .empty)
        rows = settle(rows, 2, as: .failed)
        // Every requested row settled without posters: the first unrequested row starts.
        XCTAssertTrue(DiscoverLoadScheduler.needsForwardWalk(rows: rows, requested: requested))
        XCTAssertEqual(DiscoverLoadScheduler.next(rows: rows, requested: requested, inFlight: []), [rows[3].id])
    }

    func testNoForwardWalkOnceARowHasLoaded() {
        var rows = loadingRows(6)
        let requested: Set<String> = [rows[0].id]
        rows = settle(rows, 0, as: .loaded)
        XCTAssertFalse(DiscoverLoadScheduler.needsForwardWalk(rows: rows, requested: requested))
        XCTAssertEqual(DiscoverLoadScheduler.next(rows: rows, requested: requested, inFlight: []), [])
    }

    func testAllSettledOnlyUpToTheDeepestRequestedRow() {
        var rows = loadingRows(6)
        XCTAssertFalse(DiscoverLoadScheduler.allSettled(rows: rows, requested: []))
        let requested: Set<String> = [rows[0].id, rows[1].id]
        XCTAssertFalse(DiscoverLoadScheduler.allSettled(rows: rows, requested: requested))
        rows = settle(rows, 0, as: .empty)
        XCTAssertFalse(DiscoverLoadScheduler.allSettled(rows: rows, requested: requested))
        rows = settle(rows, 1, as: .loaded)
        // Rows 2–5 are still loading but nobody asked for them yet.
        XCTAssertTrue(DiscoverLoadScheduler.allSettled(rows: rows, requested: requested))
    }

    // MARK: - View model: cancellation and cache

    /// A fetcher whose pages the test releases by hand.
    @MainActor
    private final class GatedFetcher {
        private var waiting: [String: [CheckedContinuation<DiscoverRowPage, Error>]] = [:]
        private(set) var calls: [String] = []

        func fetch(_ spec: DiscoverRowSpec) async throws -> DiscoverRowPage {
            calls.append(spec.key)
            return try await withCheckedThrowingContinuation { continuation in
                waiting[spec.key, default: []].append(continuation)
            }
        }

        func pending(_ key: String) -> Int { waiting[key]?.count ?? 0 }

        func release(_ key: String, page: DiscoverRowPage) {
            let continuations = waiting[key] ?? []
            waiting[key] = nil
            continuations.forEach { $0.resume(returning: page) }
        }

        func fail(_ key: String) {
            let continuations = waiting[key] ?? []
            waiting[key] = nil
            continuations.forEach { $0.resume(throwing: URLError(.notConnectedToInternet)) }
        }
    }

    private func makeModel(_ fetcher: GatedFetcher) -> (DiscoverRowsViewModel, () -> [String]) {
        var saved: [String] = []
        let services = DiscoverRowsServices(
            fetch: { spec, _ in try await fetcher.fetch(spec) },
            restoreCatalogKey: { _ in nil },
            save: { option in saved.append(option.key) }
        )
        return (DiscoverRowsViewModel(services: services), { saved })
    }

    private func drain() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func page(_ count: Int) -> DiscoverRowPage {
        DiscoverRowPage(items: (0..<count).map { item("i\($0)") }, hasMore: false)
    }

    func testFirstSelectionFetchesRowZeroAndPublishesItsPosters() async {
        let fetcher = GatedFetcher()
        let (model, _) = makeModel(fetcher)
        let movies = option("m", genres: ["Action", "Drama"])
        model.applySources(options: [movies], state: .ready)
        await drain()
        XCTAssertEqual(model.selectionKey, DiscoverRowsPlan.selectionKey(type: "movie", catalogKey: "m"))
        XCTAssertEqual(model.stripRows.map(\.status), [.loading, .loading])
        XCTAssertEqual(fetcher.calls, ["discover|m|g0"])
        XCTAssertEqual(model.inFlightCount, 1)

        fetcher.release("discover|m|g0", page: page(3))
        await drain()
        XCTAssertEqual(model.stripRows.map(\.status), [.loaded, .loading])
        XCTAssertEqual(model.inFlightCount, 0)
        XCTAssertTrue(model.hasLoadedRow)
        // Row 1 waits until the strip mounts it.
        XCTAssertEqual(fetcher.calls, ["discover|m|g0"])
        model.rowAppeared("discover|m|g1")
        await drain()
        XCTAssertEqual(fetcher.calls, ["discover|m|g0", "discover|m|g1"])
    }

    func testFailedRowRetries() async {
        let fetcher = GatedFetcher()
        let (model, _) = makeModel(fetcher)
        model.applySources(options: [option("m", genres: ["Action"])], state: .ready)
        await drain()
        fetcher.fail("discover|m|g0")
        await drain()
        XCTAssertEqual(model.stripRows.map(\.status), [.failed])
        XCTAssertTrue(model.allSettled)
        model.retry("discover|m|g0")
        await drain()
        XCTAssertEqual(model.stripRows.map(\.status), [.loading])
        XCTAssertEqual(fetcher.pending("discover|m|g0"), 1)
    }

    func testSelectionChangeCancelsAndALateResultNeverLands() async {
        let fetcher = GatedFetcher()
        let (model, saved) = makeModel(fetcher)
        let movies = option("m", genres: ["Action"])
        let series = option("s", type: "series", genres: ["Drama"])
        model.applySources(options: [movies, series], state: .ready)
        await drain()
        XCTAssertEqual(fetcher.calls, ["discover|m|g0"])

        model.select(type: "series")
        await drain()
        XCTAssertEqual(saved(), ["s"])
        XCTAssertEqual(model.selectedType, "series")
        XCTAssertEqual(model.stripRows.map(\.id), ["discover|s|g0"])

        // The cancelled Movies fetch resolves late: it must not touch the Series rows or count.
        fetcher.release("discover|m|g0", page: page(2))
        await drain()
        XCTAssertEqual(model.stripRows.map(\.id), ["discover|s|g0"])
        XCTAssertEqual(model.stripRows.map(\.status), [.loading])
        XCTAssertEqual(model.inFlightCount, 1)   // only Series row 0
    }

    func testGoingBackReusesTheCachedSelection() async {
        let fetcher = GatedFetcher()
        let (model, _) = makeModel(fetcher)
        let movies = option("m", genres: ["Action", "Drama"])
        let series = option("s", type: "series", genres: ["Comedy"])
        model.applySources(options: [movies, series], state: .ready)
        await drain()
        fetcher.release("discover|m|g0", page: page(2))
        await drain()
        model.rowAppeared("discover|m|g1")
        await drain()
        XCTAssertEqual(fetcher.pending("discover|m|g1"), 1)

        model.select(type: "series")
        await drain()
        model.select(type: "movie")
        await drain()
        // Row 0 comes back loaded without a refetch; row 1, cancelled mid-flight, starts again.
        XCTAssertEqual(model.stripRows.map(\.status), [.loaded, .loading])
        XCTAssertEqual(fetcher.calls.filter { $0 == "discover|m|g0" }.count, 1)
        XCTAssertEqual(fetcher.calls.filter { $0 == "discover|m|g1" }.count, 2)
    }

    func testUnchangedSourcesKeepTheRows() async {
        let fetcher = GatedFetcher()
        let (model, _) = makeModel(fetcher)
        let movies = option("m", genres: ["Action"])
        model.applySources(options: [movies], state: .ready)
        await drain()
        fetcher.release("discover|m|g0", page: page(2))
        await drain()
        // A new add-on snapshot with the same catalogs changes nothing.
        model.applySources(options: [option("m", genres: ["Action"])], state: .ready)
        await drain()
        XCTAssertEqual(model.stripRows.map(\.status), [.loaded])
        XCTAssertEqual(fetcher.calls, ["discover|m|g0"])
    }

    func testNoOptionsClearsTheSelection() async {
        let fetcher = GatedFetcher()
        let (model, _) = makeModel(fetcher)
        model.applySources(options: [option("m", genres: ["Action"])], state: .ready)
        await drain()
        model.applySources(options: [], state: .noCatalogs)
        await drain()
        XCTAssertEqual(model.selectionKey, "")
        XCTAssertTrue(model.stripRows.isEmpty)
        XCTAssertEqual(model.sourcesState, .noCatalogs)
        XCTAssertEqual(model.inFlightCount, 0)
    }
}
