import XCTest
import SharedCore
import class SharedCore.LibraryItem
@testable import NuvioTV

/// W5 (upstream 2da28d707): the Library view model's list, type, genre, year and smart filters over
/// the DEBUG fixture (`LibraryFilterFixture`, no repository reads or writes). `start()` derives
/// synchronously in fixture mode, so every assertion reads the published state straight after the
/// action.
///
/// Fixture facts: 14 titles (8 movies, 4 series, 2 anime). Comedy: Paddington 2 (2017), Knives Out
/// (2019), Fleabag ("comedy", 2016, watched), The Bear (2022), Mob Psycho 100 (anime, 2016). Heat
/// (1995) is watched and not a comedy; Nope is the one Horror title, unwatched.
@MainActor
final class LibraryViewModelFilterTests: XCTestCase {

    /// Records every remembered list or type pick written, with its source.
    private final class PickSpy {
        var writes: [String] = []
        var store: LibraryPickStore {
            LibraryPickStore(
                writeSection: { [unowned self] key, source in self.writes.append("list:\(key)@\(source.name)") },
                writeType: { [unowned self] type, source in self.writes.append("type:\(type ?? "-")@\(source.name)") }
            )
        }
    }

    private let spy = PickSpy()

    private func model(_ fixture: LibraryDebugFlags.Fixture = .local) -> LibraryViewModel {
        let model = LibraryViewModel(fixture: fixture, pickStore: spy.store)
        model.start()
        return model
    }

    private func names(_ model: LibraryViewModel) -> [String] { model.entries.map { $0.item.name } }

    func testFixtureStartsWithEveryTitle() {
        let m = model()
        XCTAssertEqual(m.entries.count, 14)
        XCTAssertEqual(m.content, .grid)
        XCTAssertNil(m.selectedGenre)
        XCTAssertNil(m.selectedYear)
        XCTAssertFalse(m.filtersActive)
        XCTAssertEqual(m.allTypesCount, 14)
    }

    func testGenreNarrowsAndFacetsTheYears() {
        let m = model()
        m.selectGenre("Comedy")
        XCTAssertEqual(m.selectedGenre, "Comedy")
        XCTAssertEqual(m.entries.count, 5)
        XCTAssertTrue(m.entries.allSatisfy { $0.item.genres.contains { $0.lowercased() == "comedy" } }, "\(names(m))")
        XCTAssertEqual(m.years.map(\.key), ["2022", "2019", "2017", "2016"])
        XCTAssertEqual(m.years.first { $0.key == "2016" }?.count, 2)
    }

    func testGenrePickResolvesToTheOptionKey() {
        let m = model()
        m.selectGenre("comedy")
        XCTAssertEqual(m.selectedGenre, "Comedy")
        XCTAssertEqual(m.entries.count, 5)
    }

    func testGenreAndYearTogether() {
        let m = model()
        m.selectGenre("Comedy")
        m.selectYear("2022")
        XCTAssertEqual(names(m), ["The Bear"])
        XCTAssertEqual(m.selectedYear, "2022")
    }

    func testTypeKeepsTheGenreAndNarrows() {
        let m = model()
        m.selectGenre("Comedy")
        m.selectType("series")
        XCTAssertEqual(m.selectedType, "series")
        // The option key is the first spelling met in the narrowed list (spec 2.4): among the series
        // that is Fleabag's "comedy". Same genre, so the pick holds; the pill still reads "Comedy".
        XCTAssertEqual(m.selectedGenre?.lowercased(), "comedy")
        XCTAssertEqual(Set(names(m)), ["Fleabag", "The Bear"])
    }

    func testWatchedFilterWithAGenre() {
        let m = model()
        m.selectGenre("Comedy")
        m.toggleSmartFilter(.watched)
        XCTAssertEqual(names(m), ["Fleabag"])
        XCTAssertTrue(m.filtersActive)
    }

    func testAYearTheListLacksFallsBackToAll() {
        let m = model()
        m.selectYear("1980")
        XCTAssertNil(m.selectedYear)
        XCTAssertEqual(m.entries.count, 14)
        XCTAssertEqual(m.content, .grid)
    }

    /// Review r1 finding 2: a year the genre lacks (reachable only programmatically; the Year menu
    /// is faceted) is forgotten, not kept as an empty filter.
    func testAYearTheGenreLacksIsForgotten() {
        let m = model()
        m.selectGenre("Comedy")
        m.selectYear("1995")
        XCTAssertEqual(m.selectedGenre, "Comedy")
        XCTAssertNil(m.selectedYear)
        XCTAssertEqual(m.entries.count, 5)
        XCTAssertEqual(m.content, .grid)
        m.selectGenre(nil)
        XCTAssertNil(m.selectedYear, "the forgotten year must not come back when Heat is listed again")
        XCTAssertEqual(m.entries.count, 14)
    }

    /// A Show choice that leaves the genre without titles drops the genre.
    func testAShowChoiceThatEmptiesTheGenreForgetsIt() {
        let m = model()
        m.selectGenre("Horror")
        XCTAssertEqual(names(m), ["Nope"])
        m.toggleSmartFilter(.watched)
        XCTAssertNil(m.selectedGenre)
        XCTAssertEqual(Set(names(m)), ["Heat", "Fleabag"])
        XCTAssertEqual(m.content, .grid)
    }

    /// Review r1 finding 2: Horror, then a type without Horror, then All types: Horror stays gone.
    func testAGenreForgottenByATypeDoesNotComeBack() {
        let m = model()
        m.selectGenre("Horror")
        m.selectType("series")
        XCTAssertNil(m.selectedGenre)
        XCTAssertEqual(m.entries.count, 4)
        m.selectType(nil)
        XCTAssertNil(m.selectedGenre)
        XCTAssertEqual(m.entries.count, 14)
    }

    /// Review r1 finding 3: with Show = Watched (Heat, Fleabag) every menu counts those two only.
    func testCountsFollowTheShowChoice() {
        let m = model()
        m.selectWatchChoice(.watched)
        XCTAssertEqual(m.allTypesCount, 2)
        XCTAssertEqual(m.types.map(\.key), ["movie", "series"])
        XCTAssertEqual(m.types.map(\.count), [1, 1])
        XCTAssertFalse(m.genres.contains { $0.key == "Horror" }, "\(m.genres)")
        XCTAssertEqual(Set(m.genres.map { $0.key.lowercased() }), ["crime", "drama", "comedy"])
        XCTAssertEqual(Set(m.years.map(\.key)), ["1995", "2016"])
        m.selectWatchChoice(.inProgress)
        XCTAssertEqual(Set(names(m)), ["Dune", "Severance"])
        XCTAssertEqual(m.allTypesCount, 2)
        XCTAssertEqual(Set(m.years.map(\.key)), ["2021", "2022"])
    }

    func testClearFiltersKeepsTheType() {
        let m = model()
        m.selectType("movie")
        m.selectGenre("Comedy")
        m.selectYear("2019")
        m.toggleSmartFilter(.unwatched)
        XCTAssertTrue(m.filtersActive)
        m.clearFilters()
        XCTAssertNil(m.selectedGenre)
        XCTAssertNil(m.selectedYear)
        XCTAssertTrue(m.activeSmartFilters.isEmpty)
        XCTAssertFalse(m.filtersActive)
        XCTAssertEqual(m.selectedType, "movie")
        XCTAssertEqual(m.entries.count, 8)
    }

    func testProviderListPickResetsTheTypeAndFacetsItsGenres() {
        let m = model(.provider)
        XCTAssertEqual(m.sections.count, 2)
        m.selectType("series")
        XCTAssertEqual(m.selectedType, "series")
        m.selectSection("fx-list-weekend")
        XCTAssertEqual(m.selectedSectionKey, "fx-list-weekend")
        XCTAssertNil(m.selectedType)
        XCTAssertEqual(m.entries.count, 8)
        XCTAssertTrue(m.entries.allSatisfy { $0.item.type == "movie" })
        let genres = Set(m.genres.map(\.key))
        XCTAssertFalse(genres.contains("Fantasy"), "\(genres)")
        XCTAssertEqual(m.genres.first { $0.key == "Comedy" }?.count, 2)
    }

    func testSciFiAndTheSlugAreTwoGenreOptions() {
        let m = model()
        let keys = m.genres.map(\.key)
        XCTAssertTrue(keys.contains("Sci-Fi"), "\(keys)")
        XCTAssertTrue(keys.contains("science-fiction"), "\(keys)")
    }

    func testShowChoiceMapsOntoTheSmartFilters() {
        let m = model()
        m.selectWatchChoice(.watched)
        XCTAssertEqual(m.activeSmartFilters, [.watched])
        XCTAssertEqual(Set(names(m)), ["Heat", "Fleabag"])
        m.selectWatchChoice(.all)
        XCTAssertTrue(m.activeSmartFilters.isEmpty)
        XCTAssertEqual(m.entries.count, 14)
    }

    func testFiltersActiveTruthTable() {
        let m = model()
        XCTAssertFalse(m.filtersActive)
        m.selectType("movie")
        XCTAssertFalse(m.filtersActive, "a type is not a filter")
        m.selectGenre("Comedy")
        XCTAssertTrue(m.filtersActive)
        m.selectGenre(nil)
        m.selectYear("2022")
        XCTAssertTrue(m.filtersActive)
        m.selectYear(nil)
        m.toggleSmartFilter(.unwatched)
        XCTAssertTrue(m.filtersActive)
        m.toggleSmartFilter(.unwatched)
        XCTAssertFalse(m.filtersActive)
    }

    func testStopAndStartKeepTheSessionFilters() {
        let m = model()
        m.selectGenre("Comedy")
        m.toggleSmartFilter(.unwatched)
        let before = m.entries
        m.stop()
        m.start()
        XCTAssertEqual(m.entries, before)
        XCTAssertEqual(m.selectedGenre, "Comedy")
    }

    // MARK: - Partial provider snapshots (review r2)

    /// The fixture's provider library re-cut: a watchlist of `watchlist` and a personal list of
    /// `personal`, as a Trakt-style snapshot.
    private func snapshot(
        watchlist: [LibraryItem],
        personal: [LibraryItem]?,
        isLoading: Bool,
        errorMessage: String? = nil
    ) -> LibraryUiState {
        let base = LibraryFilterFixture.shared.uiState(provider: true)
        var sections = [LibrarySection(type: "watchlist", displayTitle: "Watchlist", items: watchlist)]
        if let personal { sections.append(LibrarySection(type: "fx-personal", displayTitle: "Personal", items: personal)) }
        return base.doCopy(
            sourceMode: base.sourceMode,
            items: watchlist + (personal ?? []),
            sections: sections,
            isLoaded: true,
            isLoading: isLoading,
            errorMessage: errorMessage
        )
    }

    private var fixtureItems: [LibraryItem] { LibraryFilterFixture.shared.uiState(provider: false).items }
    private var movies: [LibraryItem] { fixtureItems.filter { $0.type == "movie" } }
    /// Series and anime (Severance, Fleabag, Dark, The Bear, Frieren, Mob Psycho 100).
    private var shows: [LibraryItem] { fixtureItems.filter { $0.type == "series" } }

    /// Trakt publishes the watchlist before the personal lists (and omits a list still empty). A
    /// personal-list type pick must survive that partial snapshot.
    func testATypePickSurvivesAPartialSnapshotWithoutItsList() {
        let m = model(.provider)
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        m.selectSection("fx-personal")
        m.selectType("series")
        XCTAssertEqual(m.selectedType, "series")
        XCTAssertEqual(m.entries.count, 4)

        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: nil, isLoading: true))
        XCTAssertEqual(m.selectedSectionKey, "watchlist", "the projection falls back while the list is missing")

        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        XCTAssertEqual(m.selectedSectionKey, "fx-personal")
        XCTAssertEqual(m.selectedType, "series", "the type pick was forgotten against the fallback list")
        XCTAssertEqual(m.entries.count, 4)
    }

    func testGenreAndYearPicksSurviveAPartialSnapshotWithoutTheirList() {
        let m = model(.provider)
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        m.selectSection("fx-personal")
        m.selectGenre("Fantasy")
        m.selectYear("2023")
        XCTAssertEqual(names(m), ["Frieren"])

        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: nil, isLoading: true))
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        XCTAssertEqual(m.selectedGenre, "Fantasy", "the genre pick was forgotten against the fallback list")
        XCTAssertEqual(m.selectedYear, "2023", "the year pick was forgotten against the fallback list")
        XCTAssertEqual(names(m), ["Frieren"])
    }

    /// The list itself present but mid-refresh, or a failed refresh, is not authoritative either.
    func testPicksSurviveALoadingOrFailedSnapshotOfTheirOwnList() {
        let m = model(.provider)
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        m.selectSection("fx-personal")
        m.selectGenre("Fantasy")
        let partial = shows.filter { $0.name != "Frieren" }
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: partial, isLoading: true))
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: partial, isLoading: false, errorMessage: "HTTP 500"))
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        XCTAssertEqual(m.selectedGenre, "Fantasy")
        XCTAssertEqual(names(m), ["Frieren"])
    }

    /// Review r3: even a complete snapshot of the list never forgets a pick: it shows All for it
    /// while the list lacks its titles, and the pick applies again when they return.
    func testASnapshotShowsAllForAMissingPickAndItReturns() {
        let m = model(.provider)
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        m.selectSection("fx-personal")
        m.selectGenre("Fantasy")
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows.filter { $0.name != "Frieren" }, isLoading: false))
        XCTAssertNil(m.selectedGenre, "the menu shows All genres")
        XCTAssertEqual(m.entries.count, 5, "and the drawn titles match: all five")
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        XCTAssertEqual(m.selectedGenre, "Fantasy")
        XCTAssertEqual(names(m), ["Frieren"])
    }

    // MARK: - Data never forgets a pick (review r3)

    /// Finding 1: a cold start publishes the older cache first (the personal list with only movies)
    /// before the refresh brings the series. The remembered Series pick survives, nothing is written.
    func testACachedSnapshotNeverClearsTheRememberedType() {
        let m = model(.provider)
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        m.selectSection("fx-personal")
        m.selectType("series")
        let writes = spy.writes
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: movies, isLoading: false))
        XCTAssertNil(m.selectedType, "no series in the cache: the menu shows All types for now")
        XCTAssertEqual(m.entries.count, movies.count, "the drawn titles match the shown selection")
        XCTAssertEqual(spy.writes, writes, "a snapshot must never write a pick")
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        XCTAssertEqual(m.selectedType, "series", "the remembered pick applies again")
        XCTAssertEqual(m.entries.count, 4)
        XCTAssertEqual(spy.writes, writes)
    }

    /// Finding 2: a failed partial refresh (watchlist only), then Trakt's optimistic rebuild publishes
    /// the picked list with one movie, flagged loaded and idle. The Series pick survives.
    func testAnOptimisticRebuildNeverClearsTheRememberedType() {
        let m = model(.provider)
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        m.selectSection("fx-personal")
        m.selectType("series")
        let writes = spy.writes
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: nil, isLoading: false, errorMessage: "HTTP 502"))
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: [movies[0]], isLoading: false))
        XCTAssertEqual(spy.writes, writes, "a snapshot must never write a pick")
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows + [movies[0]], isLoading: false))
        XCTAssertEqual(m.selectedType, "series")
    }

    /// Finding 3: the remembered list is missing (settled), the bar shows the watchlist. Horror, then
    /// a type without Horror, then All types: Horror is gone for good (dropped at the type change).
    func testAViewerActionDropsAnUnsatisfiablePickOnTheFallbackList() {
        let m = model(.provider)
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        m.selectSection("fx-personal")
        m.replaceFixtureLibrary(snapshot(watchlist: fixtureItems, personal: nil, isLoading: false))
        XCTAssertEqual(m.selectedSectionKey, "watchlist")
        m.selectGenre("Horror")
        XCTAssertEqual(names(m), ["Nope"])
        m.selectType("series")
        XCTAssertNil(m.selectedGenre)
        m.selectType(nil)
        XCTAssertNil(m.selectedGenre, "Horror must not come back")
        XCTAssertEqual(m.entries.count, 14)
    }

    /// No snapshot of any kind writes a pick: cached, partial, failed, optimistic, empty, complete.
    func testNoSnapshotWritesAPick() {
        let m = model(.provider)
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: shows, isLoading: false))
        m.selectSection("fx-personal")
        m.selectType("anime")
        m.selectGenre("Fantasy")
        let writes = spy.writes
        for state in [
            snapshot(watchlist: movies, personal: nil, isLoading: true),
            snapshot(watchlist: movies, personal: nil, isLoading: false, errorMessage: "x"),
            snapshot(watchlist: movies, personal: movies, isLoading: false),
            snapshot(watchlist: [], personal: nil, isLoading: false),
            snapshot(watchlist: movies, personal: shows, isLoading: false),
        ] {
            m.replaceFixtureLibrary(state)
            XCTAssertEqual(spy.writes, writes)
        }
        XCTAssertEqual(m.selectedType, "anime")
        XCTAssertEqual(m.selectedGenre, "Fantasy")
        XCTAssertEqual(names(m), ["Frieren"])
    }

    // MARK: - Narrow check

    /// Item 1: an action while the library has not loaded is not carried into the first snapshot.
    func testAnActionBeforeTheLibraryLoadsDropsNothingLater() {
        let m = LibraryViewModel(fixture: .provider, pickStore: spy.store)
        m.selectGenre("Fantasy")
        m.selectYear("2023")
        m.replaceFixtureLibrary(snapshot(watchlist: movies, personal: nil, isLoading: true))
        XCTAssertNil(m.selectedGenre, "no Fantasy among the movies: All for now")
        m.replaceFixtureLibrary(snapshot(watchlist: fixtureItems, personal: nil, isLoading: false))
        XCTAssertEqual(m.selectedGenre, "Fantasy", "the first snapshot must not have dropped the pick")
        XCTAssertEqual(m.selectedYear, "2023")
        XCTAssertEqual(names(m), ["Frieren"])
    }

    /// Item 3: a Show choice dropped at a viewer action stays gone when its titles return.
    func testAShowChoiceDroppedAtAnActionStaysGone() {
        let m = model()
        m.selectWatchChoice(.watched)
        XCTAssertEqual(m.activeSmartFilters, [.watched])
        m.selectType("anime")
        XCTAssertTrue(m.activeSmartFilters.isEmpty, "no watched anime: the type pick drops Show")
        XCTAssertEqual(m.entries.count, 2)
        m.selectType(nil)
        XCTAssertTrue(m.activeSmartFilters.isEmpty, "Watched must not come back")
        XCTAssertEqual(m.entries.count, 14)
    }

    /// The remembered-pick wiring: one write per list or type pick, tagged with the source; a list
    /// pick resets the type to All; picks apply only in their source.
    func testListAndTypePicksWriteOnceToTheirSource() {
        let m = model(.provider)
        m.selectType("series")
        XCTAssertEqual(spy.writes, ["type:series@TRAKT"])
        m.selectSection("fx-list-weekend")
        XCTAssertEqual(spy.writes, ["type:series@TRAKT", "list:fx-list-weekend@TRAKT"])
        XCTAssertNil(m.selectedType, "a new list starts on All types")
        XCTAssertEqual(m.selectedSectionKey, "fx-list-weekend")
        m.selectType("movie")
        XCTAssertEqual(spy.writes.last, "type:movie@TRAKT")
        XCTAssertEqual(spy.writes.count, 3)

        // Another source (the local library): Trakt's picks do not apply; back on Trakt they do.
        let local = LibraryFilterFixture.shared.uiState(provider: false)
        m.replaceFixtureLibrary(local)
        XCTAssertNil(m.selectedType)
        XCTAssertEqual(m.entries.count, 14)
        m.replaceFixtureLibrary(LibraryFilterFixture.shared.uiState(provider: true))
        XCTAssertEqual(m.selectedSectionKey, "fx-list-weekend")
        XCTAssertEqual(m.selectedType, "movie")
        XCTAssertEqual(spy.writes.count, 3, "snapshots and source switches write nothing")
    }

    // MARK: - The menu the viewer is on (device pass attempt 3)

    /// Series + Drama + In Progress leaves Severance; "All types" picked in the Type menu keeps the
    /// menu drawn while focus is on it (or in its closing picker), and it hides once focus moves on.
    func testAllTypesKeepsTheTypeMenuUntilFocusMovesOn() {
        let m = model()
        m.selectType("series")
        m.selectGenre("Drama")
        m.selectWatchChoice(.inProgress)
        XCTAssertEqual(names(m), ["Severance"])
        m.barFocusChanged(.type)
        m.barFocusChanged(nil)          // the picker is open
        m.selectType(nil)
        XCTAssertNil(m.selectedType)
        XCTAssertTrue(m.showsType, "the menu the viewer is on must stay")
        XCTAssertEqual(m.types.map(\.key), ["series"])
        m.barFocusChanged(nil)          // still closing
        XCTAssertTrue(m.showsType)
        m.barFocusChanged(.type)        // focus back on the menu
        XCTAssertTrue(m.showsType)
        m.barFocusChanged(.genre)       // Right
        XCTAssertFalse(m.showsType, "the menu the viewer left hides, as it always did")
        XCTAssertEqual(names(m), ["Severance"])
        XCTAssertEqual(m.selectedGenre, "Drama", "a focus move drops nothing")
        XCTAssertEqual(m.activeSmartFilters, [.inProgress])
    }

    /// Anime + 2016 + Comedy leaves Mob Psycho 100; "All" in Year keeps the Year menu.
    func testAllYearsKeepsTheYearMenu() {
        let m = model()
        m.selectType("anime")
        m.selectYear("2016")
        m.selectGenre("Comedy")
        m.barFocusChanged(.year)
        m.selectYear(nil)
        XCTAssertTrue(m.showsYear)
        XCTAssertEqual(m.years.map(\.key), ["2016"])
        m.barFocusChanged(nil)          // Down into the grid
        XCTAssertTrue(m.showsYear, "focus outside the bar never releases the kept menu")
        m.barFocusChanged(.genre)       // back to the bar on another control
        XCTAssertFalse(m.showsYear)
    }

    /// The screen stopping releases the keep; the restart derive draws by the rule alone.
    func testStopReleasesTheKeptMenu() {
        let m = model()
        m.selectType("anime")
        m.selectYear("2016")
        m.selectGenre("Comedy")
        m.barFocusChanged(.year)
        m.selectYear(nil)
        XCTAssertEqual(m.barKeep.menu, .year)
        XCTAssertTrue(m.showsYear)
        m.stop()
        XCTAssertNil(m.barKeep.menu)
        m.start()
        XCTAssertFalse(m.showsYear, "no stale kept menu after a restart")
        XCTAssertEqual(m.selectedGenre, "Comedy", "the session picks stay")
        XCTAssertEqual(names(m), ["Mob Psycho 100"])
    }

    /// Clear Filters on a list where every menu has one value: focus goes to Sort.
    func testClearFiltersFallsBackToSort() {
        let m = model(.provider)
        m.selectGenre("Horror")
        let nope = fixtureItems.filter { $0.id == "fx-7" }
        m.replaceFixtureLibrary(snapshot(watchlist: nope, personal: nil, isLoading: false))
        XCTAssertEqual(m.selectedGenre, "Horror")
        m.clearFilters()
        XCTAssertFalse(m.showsGenre || m.showsYear || m.showsShow || m.showsType, "one title: nothing to split")
        XCTAssertFalse(m.filtersActive, "Clear Filters itself goes")
        XCTAssertEqual(m.focusAfterClear, .sort)
        XCTAssertNil(m.barKeep.menu)
    }
}
