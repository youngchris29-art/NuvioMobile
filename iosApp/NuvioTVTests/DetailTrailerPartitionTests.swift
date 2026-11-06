import XCTest
import SharedCore
@testable import NuvioTV

final class DetailTrailerPartitionTests: XCTestCase {
    private struct Clip: Equatable {
        let id: Int
        let type: String?
        let name: String?
    }

    private func split(_ clips: [Clip]) -> (trailers: [Clip], bonus: [Clip]) {
        DetailTrailerPartition.split(clips, type: { $0.type }, name: { $0.name })
    }

    func testTrailerAndTeaserGoToTrailersCaseInsensitive() {
        let r = split([
            Clip(id: 1, type: "Trailer", name: "x"),
            Clip(id: 2, type: "teaser", name: "x"),
            Clip(id: 3, type: " TRAILER ", name: "x"),
        ])
        XCTAssertEqual(r.trailers.map(\.id), [1, 2, 3])
        XCTAssertTrue(r.bonus.isEmpty)
    }

    func testOtherTypesGoToBonusEvenWhenNameSaysTrailer() {
        let r = split([
            Clip(id: 1, type: "Clip", name: "a"),
            Clip(id: 2, type: "Featurette", name: "a"),
            Clip(id: 3, type: "Behind the Scenes", name: "a"),
            Clip(id: 4, type: "Bloopers", name: "a"),
            Clip(id: 5, type: "Opening Credits", name: "a"),
            Clip(id: 6, type: "Whatever", name: "Official Trailer"),
        ])
        XCTAssertTrue(r.trailers.isEmpty)
        XCTAssertEqual(r.bonus.map(\.id), [1, 2, 3, 4, 5, 6])
    }

    func testFallbackByNameWhenTypeMissingOrBlank() {
        let r = split([
            Clip(id: 1, type: nil, name: "Official TRAILER 2"),
            Clip(id: 2, type: "", name: "Teaser"),
            Clip(id: 3, type: nil, name: "Making of"),
            Clip(id: 4, type: nil, name: nil),
        ])
        XCTAssertEqual(r.trailers.map(\.id), [1, 2])
        XCTAssertEqual(r.bonus.map(\.id), [3, 4])
    }

    func testOrderKeptWithinEachGroup() {
        let r = split([
            Clip(id: 1, type: "Clip", name: nil),
            Clip(id: 2, type: "Trailer", name: nil),
            Clip(id: 3, type: "Featurette", name: nil),
            Clip(id: 4, type: "Teaser", name: nil),
        ])
        XCTAssertEqual(r.trailers.map(\.id), [2, 4])
        XCTAssertEqual(r.bonus.map(\.id), [1, 3])
    }

    func testCapAppliesPerGroupAfterSplit() {
        XCTAssertEqual(DetailTrailerPartition.perRowCap, 10)
        var clips: [Clip] = []
        for i in 0..<15 { clips.append(Clip(id: i, type: "Trailer", name: nil)) }
        for i in 100..<115 { clips.append(Clip(id: i, type: "Clip", name: nil)) }
        let r = split(clips)
        XCTAssertEqual(r.trailers.map(\.id), Array(0..<10))
        XCTAssertEqual(r.bonus.map(\.id), Array(100..<110))
    }

    func testEmptyTrailersGroupDoesNotPromoteBonus() {
        let r = split([Clip(id: 1, type: "Clip", name: nil)])
        XCTAssertTrue(r.trailers.isEmpty)
        XCTAssertEqual(r.bonus.map(\.id), [1])
    }

    func testEmptyInput() {
        let r = split([])
        XCTAssertTrue(r.trailers.isEmpty)
        XCTAssertTrue(r.bonus.isEmpty)
    }

    /// A2.4: Kotlin fills a missing type with the localized "Trailer" (`generic_trailer`, e.g.
    /// "Bande-annonce" in French); that word counts as a trailer type, case-insensitively.
    func testLocalizedTrailerWordCountsAsTrailer() {
        let clips = [
            Clip(id: 1, type: "Bande-annonce", name: "Official"),
            Clip(id: 2, type: " bande-ANNONCE ", name: nil),
            Clip(id: 3, type: "Featurette", name: "Trailer breakdown"),
        ]
        let r = DetailTrailerPartition.split(clips, type: { $0.type }, name: { $0.name },
                                             localizedTrailer: "Bande-annonce")
        XCTAssertEqual(r.trailers.map(\.id), [1, 2])
        XCTAssertEqual(r.bonus.map(\.id), [3])
        // Without the word (or with a blank one) the old rule stands.
        XCTAssertEqual(split(clips).trailers.map(\.id), [])
        XCTAssertFalse(DetailTrailerPartition.isTrailer(type: "Bande-annonce", name: nil, localizedTrailer: " "))
        XCTAssertTrue(DetailTrailerPartition.isTrailer(type: "Teaser", name: nil, localizedTrailer: "Bande-annonce"))
    }

    /// The word is read from the same "Shared" catalog entry the Kotlin side reads.
    func testSharedTrailerWordIsTheCatalogEntry() {
        XCTAssertEqual(DetailTrailerPartition.sharedTrailerWord,
                       Bundle.main.localizedString(forKey: "generic_trailer", value: "Trailer", table: "Shared"))
        XCTAssertFalse(DetailTrailerPartition.sharedTrailerWord.isEmpty)
    }

    /// End to end: an add-on meta whose videos carry no `type` goes through the shared parser
    /// (which fills the type with the localized "Trailer") and is still classified by name, so
    /// "Behind the Scenes" is Bonus and cannot take a trailer slot. Typed videos keep their type.
    func testUntypedAddonVideosFromTheParserAreClassifiedByName() {
        let payload = """
        {"meta": {"id": "tt1", "type": "movie", "name": "Movie", "trailers": [
          {"source": "a", "name": "Behind the Scenes"},
          {"source": "b", "name": "Official Trailer"},
          {"source": "c", "type": "Trailer", "name": "Making Of"},
          {"source": "d", "type": "Featurette", "name": "Trailer Breakdown"}
        ]}}
        """
        let meta = MetaDetailsParser.shared.parse(payload: payload)
        XCTAssertEqual(meta.trailers.map(\.typeProvided), [false, false, true, true])
        let r = DetailTrailerPartition.split(meta.trailers)
        XCTAssertEqual(r.trailers.map(\.key), ["b", "c"])
        XCTAssertEqual(r.bonus.map(\.key), ["a", "d"])
    }

    /// fr and es: the shared parser names an untyped, unnamed video with the localized "Trailer"
    /// (`generic_trailer`: "Bande-annonce", "Tráiler"); read through the real `SharedStringProvider`
    /// on that locale's catalog, the name fallback keeps it in Trailers. A named untyped extra
    /// still goes to Bonus.
    func testUntypedUnnamedVideoIsATrailerInFrenchAndSpanish() throws {
        let saved = LocalizedStrings.shared.provider
        defer { LocalizedStrings.shared.provider = saved }
        let payload = """
        {"meta": {"id": "tt1", "type": "movie", "name": "Movie", "trailers": [
          {"source": "a"},
          {"source": "b", "name": "Behind the Scenes"}
        ]}}
        """
        for (locale, word) in [("fr", "Bande-annonce"), ("es", "Tráiler")] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"), locale)
            let bundle = try XCTUnwrap(Bundle(path: path), locale)
            XCTAssertEqual(DetailTrailerPartition.sharedTrailerWord(bundle: bundle), word)
            LocalizedStrings.shared.provider = SharedStringProvider(bundle: bundle)
            let meta = MetaDetailsParser.shared.parse(payload: payload)
            XCTAssertEqual(meta.trailers.first?.name, word, locale)
            XCTAssertEqual(meta.trailers.first?.typeProvided, false, locale)
            let r = DetailTrailerPartition.split(meta.trailers,
                                                 localizedTrailer: DetailTrailerPartition.sharedTrailerWord(bundle: bundle))
            XCTAssertEqual(r.trailers.map(\.key), ["a"], locale)
            XCTAssertEqual(r.bonus.map(\.key), ["b"], locale)
        }
    }

    /// The localized word matches in an untyped NAME, case- and accent-insensitively.
    func testNameFallbackMatchesLocalizedWord() {
        XCTAssertTrue(DetailTrailerPartition.isTrailer(type: nil, name: "Bande-annonce VF", localizedTrailer: "Bande-annonce"))
        XCTAssertTrue(DetailTrailerPartition.isTrailer(type: nil, name: "TRAILER oficial", localizedTrailer: "Tráiler"))
        XCTAssertTrue(DetailTrailerPartition.isTrailer(type: nil, name: "Tráiler final", localizedTrailer: "Tráiler"))
        XCTAssertFalse(DetailTrailerPartition.isTrailer(type: nil, name: "Making of", localizedTrailer: "Bande-annonce"))
        XCTAssertFalse(DetailTrailerPartition.isTrailer(type: nil, name: "Making of", localizedTrailer: " "))
    }

    /// An untyped video is a trailer when EITHER its source name or its display name says so: a
    /// display label must not mask "Official Trailer" or the parser's localized default name.
    /// Through the parser, English, French and Spanish.
    func testUntypedVideoNameOrDisplayNameMakesItATrailer() throws {
        let saved = LocalizedStrings.shared.provider
        defer { LocalizedStrings.shared.provider = saved }
        let payload = """
        {"meta": {"id": "tt1", "type": "series", "name": "Show", "trailers": [
          {"source": "a", "name": "Official Trailer", "displayName": "Season 1"},
          {"source": "b", "displayName": "Season 2"},
          {"source": "c", "name": "Inside the Episode", "displayName": "Season 1 Trailer"},
          {"source": "d", "name": "Behind the Scenes", "displayName": "Season 1"},
          {"source": "e", "type": "Featurette", "name": "Official Trailer", "displayName": "Season 1"}
        ]}}
        """
        var bundles: [(String, Bundle)] = [("en", .main)]
        for locale in ["fr", "es"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"), locale)
            bundles.append((locale, try XCTUnwrap(Bundle(path: path), locale)))
        }
        for (locale, bundle) in bundles {
            LocalizedStrings.shared.provider = SharedStringProvider(bundle: bundle)
            let meta = MetaDetailsParser.shared.parse(payload: payload)
            // "b" has no source name: the parser filled the localized "Trailer" under "Season 2".
            XCTAssertEqual(meta.trailers[1].name, DetailTrailerPartition.sharedTrailerWord(bundle: bundle), locale)
            XCTAssertEqual(meta.trailers[1].displayName, "Season 2", locale)
            let r = DetailTrailerPartition.split(meta.trailers,
                                                 localizedTrailer: DetailTrailerPartition.sharedTrailerWord(bundle: bundle))
            XCTAssertEqual(r.trailers.map(\.key), ["a", "b", "c"], locale)
            // A provided type still decides alone ("e" is a Featurette whatever its name says).
            XCTAssertEqual(r.bonus.map(\.key), ["d", "e"], locale)
        }
    }
}
