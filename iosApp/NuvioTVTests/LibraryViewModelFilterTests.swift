import XCTest
import SharedCore
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

    private func model(_ fixture: LibraryDebugFlags.Fixture = .local) -> LibraryViewModel {
        let model = LibraryViewModel(fixture: fixture)
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

    /// Reachable only programmatically: the Year menu is faceted against the genre.
    func testAYearTheGenreLacksGivesNoMatches() {
        let m = model()
        m.selectGenre("Comedy")
        m.selectYear("1995")
        XCTAssertEqual(m.selectedGenre, "Comedy")
        XCTAssertEqual(m.selectedYear, "1995")
        XCTAssertTrue(m.entries.isEmpty)
        XCTAssertEqual(m.content, .noMatches)
    }

    func testGenreAndSmartFilterWithNothingLeftGivesNoMatches() {
        let m = model()
        m.selectGenre("Horror")
        XCTAssertEqual(names(m), ["Nope"])
        m.toggleSmartFilter(.watched)
        XCTAssertTrue(m.entries.isEmpty)
        XCTAssertEqual(m.content, .noMatches)
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
}
