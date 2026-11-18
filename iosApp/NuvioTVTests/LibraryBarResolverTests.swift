import XCTest
@testable import NuvioTV

/// W5 review r1 (findings 2–4): `LibraryBarResolver`, the one pure function behind the Library
/// filter bar's menus, selections, shown titles and forgotten requests.
final class LibraryBarResolverTests: XCTestCase {
    private typealias R = LibraryBarResolver
    private typealias T = LibraryBarResolver.Title
    private typealias State = LibraryGridPolicy.WatchState
    private typealias Facet = LibraryGridPolicy.FacetOption

    private let fresh = State(isWatched: false, progress: nil)
    private let watched = State(isWatched: true, progress: nil)
    private let halfway = State(isWatched: false, progress: 0.5)

    /// 0 Drama/Crime movie 2001 (unwatched) · 1 drama movie 2005 (watched) · 2 Comedy series 2005
    /// (in progress) · 3 Drama series, no year (watched) · 4 anime, no genre, 2010 (unwatched).
    private var titles: [T] {
        [
            T(typeKey: "movie", genres: ["Drama", "Crime"], year: "2001", state: fresh),
            T(typeKey: "movie", genres: ["drama"], year: "2005", state: watched),
            T(typeKey: "series", genres: ["Comedy"], year: "2005", state: halfway),
            T(typeKey: "Series ", genres: [" Drama ", ""], year: nil, state: watched),
            T(typeKey: "anime", genres: [], year: "2010", state: fresh),
        ]
    }

    private func resolve(_ request: R.Request, _ titles: [T]? = nil) -> R.Output {
        R.resolve(titles: titles ?? self.titles, request: request)
    }

    // MARK: - No request

    func testNoRequestShowsEverythingWithCounts() {
        let out = resolve(.init())
        XCTAssertEqual(out.shown, [0, 1, 2, 3, 4])
        XCTAssertEqual(out.types, [Facet(key: "movie", count: 2), Facet(key: "series", count: 2), Facet(key: "anime", count: 1)])
        XCTAssertEqual(out.allTypesCount, 5)
        // Genres group case-insensitively, keyed by the first spelling met, a title counted once.
        XCTAssertEqual(out.genres, [Facet(key: "Comedy", count: 1), Facet(key: "Crime", count: 1), Facet(key: "Drama", count: 3)])
        XCTAssertEqual(out.years, [Facet(key: "2010", count: 1), Facet(key: "2005", count: 2), Facet(key: "2001", count: 1)])
        XCTAssertEqual(out.visibleSmartFilters, [.unwatched, .inProgress, .watched])
        XCTAssertTrue(out.showsType && out.showsGenre && out.showsYear && out.showsShow)
        XCTAssertEqual(out.unavailable, [])
    }

    func testTheCallersTypeOrderWins() {
        let out = R.resolve(titles: titles, request: .init(), typeOrder: ["anime", "series", "movie"])
        XCTAssertEqual(out.types.map(\.key), ["anime", "series", "movie"])
    }

    // MARK: - Counts under each Show choice (finding 3)

    func testCountsHonourTheShowChoice() {
        let watchedOut = resolve(.init(smartFilters: [.watched]))
        XCTAssertEqual(watchedOut.shown, [1, 3])
        XCTAssertEqual(watchedOut.allTypesCount, 2)
        XCTAssertEqual(watchedOut.types, [Facet(key: "movie", count: 1), Facet(key: "series", count: 1)])
        XCTAssertEqual(watchedOut.genres, [Facet(key: "drama", count: 2)])
        XCTAssertEqual(watchedOut.years, [Facet(key: "2005", count: 1)])

        let inProgress = resolve(.init(smartFilters: [.inProgress]))
        XCTAssertEqual(inProgress.shown, [2])
        XCTAssertEqual(inProgress.types, [Facet(key: "series", count: 1)])
        XCTAssertEqual(inProgress.genres, [Facet(key: "Comedy", count: 1)])
        XCTAssertEqual(inProgress.years, [Facet(key: "2005", count: 1)])
        XCTAssertFalse(inProgress.showsType, "one type, every title carries it")

        let unwatched = resolve(.init(smartFilters: [.unwatched]))
        XCTAssertEqual(unwatched.shown, [0, 2, 4])
        XCTAssertEqual(unwatched.allTypesCount, 3)
        XCTAssertEqual(unwatched.genres.map(\.key), ["Comedy", "Crime", "Drama"])

        // Show's own choices ignore the Show filter (each facet ignores itself).
        XCTAssertEqual(watchedOut.visibleSmartFilters, [.unwatched, .inProgress, .watched])
    }

    /// Each facet's counts cross-filter by the others, never by itself.
    func testFacetsCrossFilterByEachOther() {
        let out = resolve(.init(type: "movie", genre: "Drama"))
        XCTAssertEqual(out.shown, [0, 1])
        XCTAssertEqual(out.types, [Facet(key: "movie", count: 2), Facet(key: "series", count: 1)], "types under Drama")
        XCTAssertEqual(out.genres, [Facet(key: "Crime", count: 1), Facet(key: "Drama", count: 2)], "genres under movie")
        XCTAssertEqual(out.years, [Facet(key: "2005", count: 1), Facet(key: "2001", count: 1)], "years under movie + Drama")
        XCTAssertEqual(out.visibleSmartFilters, [.unwatched, .watched])
    }

    // MARK: - Unavailable picks are not applied (finding 2; review r3: only the viewer drops them)

    func testAGenreTheTypeLacksIsClearedNotKept() {
        let out = resolve(.init(type: "anime", genre: "Comedy"))
        XCTAssertNil(out.selectedGenre)
        XCTAssertEqual(out.unavailable, [.genre])
        XCTAssertEqual(out.shown, [4])
    }

    func testAYearOrTypeTheListLacksIsCleared() {
        XCTAssertEqual(resolve(.init(year: "1980")).unavailable, [.year])
        XCTAssertEqual(resolve(.init(type: "documentary")).unavailable, [.type])
        let both = resolve(.init(type: "documentary", genre: "Western", year: "1980"))
        XCTAssertEqual(both.unavailable, [.type, .genre, .year])
        XCTAssertEqual(both.shown.count, 5)
    }

    func testAYearTheGenreLacksIsCleared() {
        let out = resolve(.init(genre: "Comedy", year: "2001"))
        XCTAssertEqual(out.selectedGenre, "Comedy")
        XCTAssertNil(out.selectedYear)
        XCTAssertEqual(out.unavailable, [.year])
        XCTAssertEqual(out.shown, [2])
    }

    func testAGenreTheShowChoiceLeavesNoTitleForIsCleared() {
        let out = resolve(.init(genre: "Comedy", smartFilters: [.watched]))
        XCTAssertNil(out.selectedGenre)
        XCTAssertEqual(out.unavailable, [.genre])
        XCTAssertEqual(out.shown, [1, 3])
    }

    /// After a viewer action the caller drops an unavailable session pick; once dropped it never
    /// comes back on its own, even when the titles that carried it return.
    func testAClearedRequestStaysClearedWhenItBecomesAvailableAgain() {
        var request = R.Request(type: "anime", genre: "Comedy")
        let first = resolve(request)
        if R.picksToDrop(after: .type, unavailable: first.unavailable).contains(.genre) { request.genre = nil }
        request.type = nil
        let second = resolve(request)
        XCTAssertNil(second.selectedGenre)
        XCTAssertEqual(second.shown.count, 5)
        XCTAssertEqual(second.unavailable, [])
    }

    /// An empty list applies nothing; whether anything is dropped is `picksToDrop`'s call (nothing
    /// after a snapshot).
    func testAnEmptyListAppliesNothing() {
        let out = resolve(.init(type: "movie", genre: "Drama", year: "2001", smartFilters: [.watched]), [])
        XCTAssertEqual(out.unavailable, [.type, .show, .genre, .year])
        XCTAssertNil(out.selectedType)
        XCTAssertNil(out.selectedGenre)
        XCTAssertEqual(out.smartFilters, [])
        XCTAssertEqual(out.shown, [])
        XCTAssertFalse(out.showsType || out.showsGenre || out.showsYear || out.showsShow)
        XCTAssertEqual(out.allTypesCount, 0)
        XCTAssertEqual(R.picksToDrop(after: nil, unavailable: out.unavailable), [])
    }

    // MARK: - Spelling (finding 2's "keep the case-insensitive match")

    /// Narrowing to series makes the first spelling of Drama " Drama " (trimmed "Drama") instead of
    /// the list's; the request survives and names the row the menu shows.
    func testAGenreRequestSurvivesASpellingChange() {
        let list = [
            T(typeKey: "movie", genres: ["drama"], year: "2001", state: fresh),
            T(typeKey: "series", genres: ["Drama"], year: "2002", state: fresh),
            T(typeKey: "series", genres: ["Comedy"], year: "2003", state: fresh),
        ]
        let all = resolve(.init(genre: "DRAMA"), list)
        XCTAssertEqual(all.selectedGenre, "drama")
        XCTAssertEqual(all.genres.first { $0.key.lowercased() == "drama" }?.key, "drama")
        let series = resolve(.init(type: "series", genre: "DRAMA"), list)
        XCTAssertEqual(series.selectedGenre, "Drama")
        XCTAssertEqual(series.genres.first { $0.key.lowercased() == "drama" }?.key, "Drama")
        XCTAssertEqual(series.unavailable, [])
        XCTAssertEqual(series.shown, [1])
    }

    // MARK: - Showing a menu (finding 4)

    func testASingleValueShowsOnlyWhenSomeTitlesLackIt() {
        let allDrama = [
            T(typeKey: "movie", genres: ["Drama"], year: "2001", state: fresh),
            T(typeKey: "movie", genres: ["Drama"], year: "2001", state: fresh),
        ]
        let full = resolve(.init(), allDrama)
        XCTAssertFalse(full.showsGenre, "every title is Drama: nothing to split")
        XCTAssertFalse(full.showsYear, "every title is 2001: nothing to split")
        XCTAssertFalse(full.showsType)

        let missing = allDrama + [T(typeKey: "movie", genres: [], year: nil, state: fresh)]
        let partial = resolve(.init(), missing)
        XCTAssertEqual(partial.genres, [Facet(key: "Drama", count: 2)])
        XCTAssertTrue(partial.showsGenre, "one genre, one title without genres: it splits")
        XCTAssertEqual(partial.years, [Facet(key: "2001", count: 2)])
        XCTAssertTrue(partial.showsYear, "one year, one undated title: it splits")
        let picked = resolve(.init(genre: "drama"), missing)
        XCTAssertEqual(picked.shown, [0, 1])
        XCTAssertTrue(picked.showsGenre)
    }

    /// Pre-cut follow-ups 2.1: `rule` is the five keep-dependent outputs of the same resolve with
    /// no kept menu, for every kept menu and none, over lists where a keep changes them.
    func testTheRuleValuesAreTheNoKeepDerive() {
        let one = [T(typeKey: "movie", genres: ["Horror"], year: "2022", state: fresh)]
        let sameState = [
            T(typeKey: "movie", genres: ["Drama"], year: "2001", state: watched),
            T(typeKey: "movie", genres: ["Drama"], year: "2001", state: watched),
        ]
        let lists: [[T]] = [titles, one, sameState, []]
        let requests: [R.Request] = [.init(), .init(type: "movie"), .init(smartFilters: [.watched]), .init(genre: "Drama", year: "2001")]
        var keptDiffered = false
        for list in lists {
            for base in requests {
                let plain = resolve(base, list)
                let expected = R.Rule(
                    showsType: plain.showsType,
                    showsGenre: plain.showsGenre,
                    showsYear: plain.showsYear,
                    showsShow: plain.showsShow,
                    visibleSmartFilters: plain.visibleSmartFilters
                )
                for kept in [nil] + R.Menu.allCases.map(Optional.some) {
                    var request = base
                    request.keepVisible = kept
                    let out = resolve(request, list)
                    XCTAssertEqual(out.rule, expected, "kept=\(kept.map(\.rawValue) ?? "-") request=\(base)")
                    let published = R.Rule(showsType: out.showsType, showsGenre: out.showsGenre, showsYear: out.showsYear,
                                           showsShow: out.showsShow, visibleSmartFilters: out.visibleSmartFilters)
                    if published != out.rule { keptDiffered = true }
                }
            }
        }
        XCTAssertTrue(keptDiffered, "some keep changes the published values, so the rule is not trivially equal")
    }

    func testShowsRule() {
        XCTAssertFalse(R.shows([], selected: nil, eligible: 0))
        XCTAssertFalse(R.shows([Facet(key: "a", count: 3)], selected: nil, eligible: 3))
        XCTAssertTrue(R.shows([Facet(key: "a", count: 2)], selected: nil, eligible: 3))
        XCTAssertTrue(R.shows([Facet(key: "a", count: 1), Facet(key: "b", count: 1)], selected: nil, eligible: 2))
        XCTAssertTrue(R.shows([], selected: "a", eligible: 0))
    }

    /// A Show choice no title passes is not applied: All Titles shows and every title is drawn.
    func testAnUnsatisfiableShowChoiceShowsAllTitles() {
        let out = resolve(.init(smartFilters: [.watched, .inProgress]))
        XCTAssertEqual(out.smartFilters, [])
        XCTAssertEqual(out.unavailable, [.show])
        XCTAssertEqual(out.shown, [0, 1, 2, 3, 4])
    }

    // MARK: - Parsing and cost

    func testReleaseYearIsTheFirstFourDigitRun() {
        XCTAssertEqual(R.releaseYear("2018-2021"), "2018")
        XCTAssertEqual(R.releaseYear("2018–"), "2018")
        XCTAssertEqual(R.releaseYear("Season 12, 1999"), "1999")
        XCTAssertNil(R.releaseYear("123"))
        XCTAssertNil(R.releaseYear(nil))
        XCTAssertNil(R.releaseYear(""))
    }

    /// Finding 3's cost: the whole bar for a 500-title list, every request set. Prints the time.
    func testFiveHundredTitlesResolveQuickly() {
        let genres = ["Action", "Drama", "Comedy", "Crime", "Thriller", "Sci-Fi", "Horror", "Family"]
        let big = (0..<500).map { i in
            T(typeKey: ["movie", "series", "anime"][i % 3],
              genres: [genres[i % 8], genres[(i / 8) % 8]],
              year: String(1970 + i % 55),
              state: State(isWatched: i % 4 == 0, progress: i % 5 == 0 ? 0.3 : nil))
        }
        let request = R.Request(type: "movie", genre: "drama", year: "2001", smartFilters: [.unwatched])
        _ = R.resolve(titles: big, request: request)
        let start = Date()
        let runs = 20
        for _ in 0..<runs { _ = R.resolve(titles: big, request: request) }
        let ms = Date().timeIntervalSince(start) * 1000 / Double(runs)
        print("[LibraryBarResolverTests] 500 titles: \(String(format: "%.2f", ms)) ms per resolve")
        XCTAssertLessThan(ms, 50)
    }

    // MARK: - Data never forgets; only the viewer does (review r3)

    func testOnlyAViewerActionDropsAndOnlySessionPicks() {
        let all: R.Picks = [.type, .genre, .year, .show]
        XCTAssertEqual(R.picksToDrop(after: nil, unavailable: all), [], "a snapshot never drops a pick")
        for action: R.ViewerAction in [.list, .type, .show, .genre, .year, .clearFilters] {
            XCTAssertEqual(R.picksToDrop(after: action, unavailable: all), [.genre, .year, .show], "\(action)")
            XCTAssertEqual(R.picksToDrop(after: action, unavailable: [.type]), [], "the remembered type is never dropped by data")
        }
    }

    /// The invariant the bar keeps: the shown selection and the drawn titles always agree. Every
    /// drawn title passes the effective selections, every title that passes is drawn, and each
    /// effective selection is a row of its menu. Exhaustive over the fixture's picks.
    func testTheShownSelectionAndTheDrawnTitlesAlwaysAgree() {
        let types: [String?] = [nil, "movie", "series", "anime", "documentary"]
        let genres: [String?] = [nil, "drama", "Comedy", "Crime", "Western"]
        let years: [String?] = [nil, "2001", "2005", "2010", "1980"]
        let shows: [Set<LibraryGridPolicy.SmartFilter>] = [[], [.unwatched], [.inProgress], [.watched], [.watched, .inProgress]]
        // Three lists: the fixture; one where most titles lack genres and years; one type only.
        let sparse = [
            T(typeKey: "movie", genres: ["Drama"], year: "2001", state: watched),
            T(typeKey: "movie", genres: [], year: nil, state: fresh),
            T(typeKey: "series", genres: [], year: nil, state: halfway),
        ]
        let oneType = [
            T(typeKey: "movie", genres: ["Comedy"], year: "2005", state: fresh),
            T(typeKey: "movie", genres: ["comedy", "Crime"], year: "2010", state: watched),
        ]
        for list in [titles, sparse, oneType] {
        for type in types { for genre in genres { for year in years { for show in shows {
            let out = resolve(.init(type: type, genre: genre, year: year, smartFilters: show), list)
            let expected = list.indices.filter { i in
                let t = list[i]
                return (out.selectedType == nil || t.typeKey == out.selectedType)
                    && (out.selectedGenre == nil || t.genres.contains { $0.lowercased() == out.selectedGenre!.lowercased() })
                    && (out.selectedYear == nil || t.year == out.selectedYear)
                    && LibraryGridPolicy.passes(t.state, filters: out.smartFilters)
            }
            let tag = "\(String(describing: type)) \(String(describing: genre)) \(String(describing: year)) \(show)"
            XCTAssertEqual(out.shown, expected, tag)
            XCTAssertFalse(out.shown.isEmpty, "a non-empty list always draws something: \(tag)")
            if let g = out.selectedGenre { XCTAssertTrue(out.genres.contains { $0.key == g }, tag) }
            if let y = out.selectedYear { XCTAssertTrue(out.years.contains { $0.key == y }, tag) }
            if let t = out.selectedType { XCTAssertTrue(out.types.contains { $0.key == t }, tag) }
            XCTAssertEqual(out.unavailable.contains(.genre), genre != nil && out.selectedGenre == nil, tag)
            XCTAssertEqual(out.unavailable.contains(.year), year != nil && out.selectedYear == nil, tag)
            XCTAssertEqual(out.unavailable.contains(.type), type != nil && out.selectedType == nil, tag)
            XCTAssertEqual(out.unavailable.contains(.show), !show.isEmpty && out.smartFilters.isEmpty, tag)
            XCTAssertTrue(
                LibraryGridPolicy.watchChoices(visible: out.visibleSmartFilters)
                    .contains(LibraryGridPolicy.watchChoice(for: out.smartFilters)),
                "the effective Show is one of the Show menu's choices: \(tag)"
            )
        } } } }
        }
    }
}
