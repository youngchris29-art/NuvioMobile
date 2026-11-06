import XCTest
@testable import NuvioTV

/// A4.4 (C10): the Cast row continues into crew; cards keep a stable focus key.
final class DetailCreditRowTests: XCTestCase {
    private func cast(_ name: String, _ role: String?, id: Int? = nil, photo: String? = nil) -> DetailCastCredit {
        DetailCastCredit(name: name, role: role, photo: photo, tmdbId: id)
    }

    private func crew(_ name: String, _ job: String, _ category: DetailCreditCategory, id: Int? = nil) -> DetailCrewCredit {
        let person = id.map { "tmdb:\($0)" } ?? "name:\(name.lowercased())"
        return DetailCrewCredit(name: name, job: job, category: category, photo: nil, tmdbId: id,
                                creditKey: "\(person)|\(job.lowercased())")
    }

    /// Cast first, in order, then crew in the order given; the job is the crew card's role line.
    func testCastThenCrewWithJobAsSubtitle() {
        let items = DetailCreditRow.items(
            cast: [cast("Actor A", "Hero", id: 1), cast("Actor B", "Villain", id: 2)],
            crew: [crew("Writer W", "Screenplay", .writer, id: 10), crew("Producer P", "Executive Producer", .producer, id: 11)]
        )
        XCTAssertEqual(items.map(\.name), ["Actor A", "Actor B", "Writer W", "Producer P"])
        XCTAssertEqual(items.map(\.subtitle), ["Hero", "Villain", "Screenplay", "Executive Producer"])
        XCTAssertEqual(items.map(\.kind), [.cast, .cast, .crew(.writer), .crew(.producer)])
    }

    /// The director TMDB prepends to `cast` as a pseudo-entry is not shown again as crew.
    func testPseudoCastDirectorIsNotRepeated() {
        let items = DetailCreditRow.items(
            cast: [cast("Dir D", "Director", id: 5), cast("Actor A", "Hero", id: 1)],
            crew: [crew("Dir D", "Director", .director, id: 5), crew("Writer W", "Writer", .writer, id: 10)]
        )
        XCTAssertEqual(items.map(\.name), ["Dir D", "Actor A", "Writer W"])
        XCTAssertEqual(items.first?.kind, .cast)
    }

    /// A localized pseudo-role ("Réalisateur") matches through the labels the caller supplies.
    func testLocalizedPseudoRoleMatches() {
        let items = DetailCreditRow.items(
            cast: [cast("Dir D", "Réalisateur", id: 5)],
            crew: [crew("Dir D", "Director", .director, id: 5)],
            pseudoRoleLabels: { $0 == .director ? ["Director", "Réalisateur"] : [] }
        )
        XCTAssertEqual(items.count, 1)
    }

    /// A director who also acts keeps both cards: the actor credit is not a pseudo-entry.
    func testActorDirectorKeepsBothCards() {
        let items = DetailCreditRow.items(
            cast: [cast("Clint E", "Walt", id: 7)],
            crew: [crew("Clint E", "Director", .director, id: 7)]
        )
        XCTAssertEqual(items.map(\.kind), [.cast, .crew(.director)])
    }

    /// Series creators prepended to cast are not repeated; other crew still follows.
    func testPseudoCastCreatorIsNotRepeated() {
        let items = DetailCreditRow.items(
            cast: [cast("Creator C", "Creator", id: 9), cast("Actor A", "Hero", id: 1)],
            crew: [crew("Creator C", "Creator", .creator, id: 9), crew("Dir D", "Director", .director, id: 5)]
        )
        XCTAssertEqual(items.map(\.name), ["Creator C", "Actor A", "Dir D"])
    }

    /// Without ids (add-on data), the same name counts as the same person.
    func testNameMatchWithoutIds() {
        let items = DetailCreditRow.items(
            cast: [cast("Dir D", "Director")],
            crew: [crew("dir d", "Director", .director)]
        )
        XCTAssertEqual(items.count, 1)
    }

    /// Crew is deduped by `creditKey`; the same person under two jobs keeps two cards.
    func testCrewDedupedByCreditKey() {
        let items = DetailCreditRow.items(
            cast: [cast("Actor A", "Hero", id: 1)],
            crew: [crew("Dir D", "Director", .director, id: 5), crew("Dir D", "Director", .director, id: 5),
                   crew("Dir D", "Writer", .writer, id: 5)]
        )
        XCTAssertEqual(items.map(\.subtitle), ["Hero", "Director", "Writer"])
        XCTAssertEqual(Set(items.map(\.key)).count, items.count)
    }

    /// Only cards with a TMDB id open a person page; the id rides on the item.
    func testTmdbIdCarried() {
        let items = DetailCreditRow.items(
            cast: [cast("Actor A", "Hero", id: 1), cast("Actor B", nil)],
            crew: [crew("Writer W", "Writer", .writer)]
        )
        XCTAssertEqual(items.map(\.tmdbId), [1, nil, nil])
        XCTAssertNil(items[1].subtitle)
    }

    // MARK: Keys

    /// Keys are prefixed, lowercased and whitespace-free (the probe's `idx=` stays one token).
    func testKeyShapes() {
        XCTAssertEqual(DetailCreditRow.castKey(name: "Actor A", role: "Tony Stark", tmdbId: 3), "cast:tmdb:3|tony_stark")
        XCTAssertEqual(DetailCreditRow.castKey(name: "Actor A", role: nil, tmdbId: nil), "cast:name:actor_a|")
        XCTAssertEqual(DetailCreditRow.focusKey("tmdb:1|executive  producer"), "tmdb:1|executive_producer")
        let items = DetailCreditRow.items(cast: [cast("Actor A", "Hero", id: 1)],
                                          crew: [crew("Producer P", "Executive Producer", .producer, id: 11)])
        XCTAssertEqual(items.map(\.key), ["cast:tmdb:1|hero", "tmdb:11|executive_producer"])
        XCTAssertFalse(items.contains(where: { $0.key.contains(" ") }))
    }

    /// Two identical cast entries still get distinct keys (the row's `ForEach` identity).
    func testDuplicateCastKeysAreMadeUnique() {
        let items = DetailCreditRow.items(cast: [cast("Actor A", "Hero", id: 1), cast("Actor A", "Hero", id: 1)],
                                          crew: [crew("Dir D", "Director", .director, id: 5)])
        XCTAssertEqual(items.map(\.key), ["cast:tmdb:1|hero", "cast:tmdb:1|hero#2", "tmdb:5|director"])
    }

    /// The return-focus point of A4.4: the remembered card's key survives the row content shifting
    /// (crew appended after enrichment, a cast member inserted ahead), where its index would not.
    func testKeyIsStableWhenTheRowShifts() {
        let before = DetailCreditRow.items(cast: [cast("Actor A", "Hero", id: 1), cast("Actor B", "Villain", id: 2)],
                                           crew: [crew("Dir D", "Director", .director, id: 5)])
        let remembered = before[1].key
        let after = DetailCreditRow.items(
            cast: [cast("Dir D", "Director", id: 5), cast("Actor A", "Hero", id: 1), cast("Actor B", "Villain", id: 2)],
            crew: [crew("Dir D", "Director", .director, id: 5), crew("Writer W", "Writer", .writer, id: 10)]
        )
        XCTAssertEqual(after.firstIndex(where: { $0.key == remembered }), 2)
        XCTAssertEqual(after.first(where: { $0.key == remembered })?.name, "Actor B")
        let directorCrewKey = before[2].key
        XCTAssertNil(after.first(where: { $0.key == directorCrewKey }),
                     "the director's crew card folds into the pseudo-cast entry once TMDB prepends it")
    }

    /// The English pseudo-role words match Kotlin's inline fallbacks.
    func testEnglishPseudoRoleLabels() {
        XCTAssertEqual(DetailCreditRow.englishPseudoRoleLabels(.creator), ["Creator"])
        XCTAssertEqual(DetailCreditRow.englishPseudoRoleLabels(.director), ["Director"])
        XCTAssertEqual(DetailCreditRow.englishPseudoRoleLabels(.writer), ["Writer"])
        XCTAssertEqual(DetailCreditRow.englishPseudoRoleLabels(.producer), [])
    }

    // MARK: - Crew job labels

    private static let mappedJobs = ["Director", "Writer", "Screenplay", "Story", "Novel", "Characters",
                                     "Creator", "Producer", "Executive Producer", "Original Music Composer",
                                     "Director of Photography", "Editor", "Casting"]

    /// The common TMDB jobs map to their catalog labels (English, the test run's language, is the
    /// key itself), whatever the case or surrounding spaces.
    func testCommonJobsMapToLocalizedLabels() {
        for job in Self.mappedJobs {
            XCTAssertEqual(DetailCreditRow.jobLabel(job), job)
            XCTAssertEqual(DetailCreditRow.jobLabel("  \(job.uppercased()) "), job, job)
        }
    }

    /// Every mapped job has a French entry in the catalog (the build carries fr.lproj).
    func testMappedJobsAreTranslated() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let fr = try XCTUnwrap(Bundle(path: path))
        for job in Self.mappedJobs {
            let value = fr.localizedString(forKey: job, value: "\u{1}", table: nil)
            XCTAssertNotEqual(value, "\u{1}", "\(job) missing from the fr catalog")
        }
        XCTAssertEqual(fr.localizedString(forKey: "Screenplay", value: nil, table: nil), "Scénario")
    }

    /// Anything else is shown as TMDB sent it, trimmed.
    func testUnknownJobFallsBackToRawJob() {
        XCTAssertEqual(DetailCreditRow.jobLabel(" Visual Effects Supervisor "), "Visual Effects Supervisor")
        XCTAssertEqual(DetailCreditRow.jobLabel("Gaffer"), "Gaffer")
        XCTAssertEqual(DetailCreditRow.jobLabel(""), "")
    }

    /// The card shows the label; the key (and dedup) keep the raw job.
    func testCrewSubtitleUsesLabelAndKeyKeepsRawJob() {
        let items = DetailCreditRow.items(
            cast: [],
            crew: [crew("Cam C", "Director of Photography", .producer, id: 20),
                   crew("Cam C", "Director of Photography", .producer, id: 20),
                   crew("Grip G", "Key Grip", .producer, id: 21)]
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].subtitle, DetailCreditRow.jobLabel("Director of Photography"))
        XCTAssertEqual(items[0].key, "tmdb:20|director_of_photography")
        XCTAssertEqual(items[1].subtitle, "Key Grip")
    }
}
