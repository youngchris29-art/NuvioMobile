import XCTest
@testable import NuvioTV

/// A4.4 (C10): the Cast row continues into crew; cards keep a stable focus key.
final class DetailCreditRowTests: XCTestCase {
    private func cast(_ name: String, _ role: String?, id: Int? = nil, photo: String? = nil,
                      marked: DetailCreditCategory? = nil) -> DetailCastCredit {
        DetailCastCredit(name: name, role: role, photo: photo, tmdbId: id, creditCategory: marked)
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
        XCTAssertEqual(items.map(\.name), ["Actor A", "Dir D", "Writer W"])
        XCTAssertEqual(items[1].kind, .cast)
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
        XCTAssertEqual(items.map(\.name), ["Actor A", "Creator C", "Dir D"])
    }

    /// Actors lead, then the creator(s), then the other prepended entries, then the remaining crew.
    func testActorsThenCreatorsThenRestOfCrew() {
        let items = DetailCreditRow.items(
            cast: [cast("Dir D", "Director", id: 5), cast("Creator C", "Creator", id: 9),
                   cast("Actor A", "Hero", id: 1), cast("Actor B", "Villain", id: 2)],
            crew: [crew("Creator C", "Creator", .creator, id: 9), crew("Dir D", "Director", .director, id: 5),
                   crew("Writer W", "Writer", .writer, id: 10)]
        )
        XCTAssertEqual(items.map(\.name), ["Actor A", "Actor B", "Creator C", "Dir D", "Writer W"])
    }

    /// An actor whose character is merely "Director", with no directing credit, stays in actor order
    /// (also when listed first, where a prepended block would sit).
    func testActorCreditedAsDirectorStaysWithActors() {
        let middle = DetailCreditRow.items(
            cast: [cast("Actor A", "Hero", id: 1), cast("Actor X", "Director", id: 8), cast("Actor B", "Villain", id: 2)],
            crew: [crew("Writer W", "Writer", .writer, id: 10)]
        )
        XCTAssertEqual(middle.map(\.name), ["Actor A", "Actor X", "Actor B", "Writer W"])
        let first = DetailCreditRow.items(
            cast: [cast("Actor X", "Director", id: 8), cast("Actor A", "Hero", id: 1)],
            crew: [crew("Dir D", "Director", .director, id: 5)]
        )
        XCTAssertEqual(first.map(\.name), ["Actor X", "Actor A", "Dir D"])
        XCTAssertEqual(first.map(\.kind), [.cast, .cast, .crew(.director)])
    }

    /// A real pseudo "Director" that matches crew still groups after the actors, while an actor
    /// credited as "Director" in the same cast keeps its place among them.
    func testCorroboratedPseudoDirectorGroupsWithCrew() {
        let items = DetailCreditRow.items(
            cast: [cast("Dir D", "Director", id: 5), cast("Actor A", "Hero", id: 1),
                   cast("Actor X", "Director", id: 8), cast("Actor B", "Villain", id: 2)],
            crew: [crew("Dir D", "Director", .director, id: 5), crew("Producer P", "Producer", .producer, id: 11)]
        )
        XCTAssertEqual(items.map(\.name), ["Actor A", "Actor X", "Actor B", "Dir D", "Producer P"])
    }

    /// Unmarked cast (add-on or older cached meta) only groups crew-backed entries: an unbacked
    /// "Writer" is an actor there, with no inferred block.
    func testUnmarkedCastGroupsOnlyCrewBackedEntries() {
        let items = DetailCreditRow.items(
            cast: [cast("Writer W", "Writer", id: 10), cast("Writer V", "Writer", id: 12), cast("Actor A", "Hero", id: 1)],
            crew: [crew("Writer W", "Writer", .writer, id: 10)]
        )
        XCTAssertEqual(items.map(\.name), ["Writer V", "Actor A", "Writer W"])
    }

    // MARK: Producer marker (`MetaPerson.creditCategory`)

    /// A wholly unbacked marked writer block (crew dropped "Staff Writer", or the category cap is
    /// full) still follows the actors.
    func testMarkedWriterBlockGroupsWithoutCrew() {
        let items = DetailCreditRow.items(
            cast: [cast("Stu Staff", "Writer", id: 12, marked: .writer), cast("Wes W", "Writer", id: 13, marked: .writer),
                   cast("Actor A", "Hero", id: 1)],
            crew: [crew("Pat P", "Producer", .producer, id: 11)]
        )
        XCTAssertEqual(items.map(\.name), ["Actor A", "Stu Staff", "Wes W", "Pat P"])
        XCTAssertEqual(items.map(\.kind), [.cast, .cast, .cast, .crew(.producer)])
    }

    /// With markers present they are the only signal: an actor credited as "Director" right after a
    /// real prepended director stays with the actors, and one who also directs keeps both cards.
    func testMarkedCastLeavesUnmarkedDirectorRolesWithActors() {
        let items = DetailCreditRow.items(
            cast: [cast("Dir D", "Director", id: 5, marked: .director), cast("Actor X", "Director", id: 8),
                   cast("Clint E", "Director", id: 7), cast("Actor A", "Hero", id: 1)],
            crew: [crew("Dir D", "Director", .director, id: 5), crew("Clint E", "Director", .director, id: 7)]
        )
        XCTAssertEqual(items.map(\.name), ["Actor X", "Clint E", "Actor A", "Dir D", "Clint E"])
        XCTAssertEqual(items.map(\.kind), [.cast, .cast, .cast, .cast, .crew(.director)])
    }

    /// A marked entry hides the same person's crew card in its category only.
    func testMarkedEntryHidesOnlyItsCategoryCrewCard() {
        let items = DetailCreditRow.items(
            cast: [cast("Dir D", "Director", id: 5, marked: .director), cast("Actor A", "Hero", id: 1)],
            crew: [crew("Dir D", "Director", .director, id: 5), crew("Dir D", "Writer", .writer, id: 5)]
        )
        XCTAssertEqual(items.map(\.name), ["Actor A", "Dir D", "Dir D"])
        XCTAssertEqual(items.map(\.subtitle), ["Hero", "Director", "Writer"])
        XCTAssertEqual(items[2].kind, .crew(.writer))
    }

    /// Unmarked fallback: a lead actor credited as "Director" right after a backed creator stays with
    /// the actors, while a backed director still groups.
    func testLeadingBlockStopsAtAnotherCategory() {
        let items = DetailCreditRow.items(
            cast: [cast("Creator C", "Creator", id: 9), cast("Actor X", "Director", id: 8),
                   cast("Actor A", "Hero", id: 1)],
            crew: [crew("Creator C", "Creator", .creator, id: 9)]
        )
        XCTAssertEqual(items.map(\.name), ["Actor X", "Actor A", "Creator C"])
        let backed = DetailCreditRow.items(
            cast: [cast("Creator C", "Creator", id: 9), cast("Dir D", "Director", id: 5),
                   cast("Actor A", "Hero", id: 1)],
            crew: [crew("Creator C", "Creator", .creator, id: 9), crew("Dir D", "Director", .director, id: 5)]
        )
        XCTAssertEqual(backed.map(\.name), ["Actor A", "Creator C", "Dir D"])
    }

    /// A creator supplied only through crew lands with the creators, before a prepended writer.
    func testCrewOnlyCreatorPrecedesPrependedWriter() {
        let items = DetailCreditRow.items(
            cast: [cast("Writer W", "Writer", id: 10), cast("Actor A", "Hero", id: 1)],
            crew: [crew("Writer W", "Writer", .writer, id: 10), crew("Creator C", "Creator", .creator, id: 9),
                   crew("Producer P", "Producer", .producer, id: 11)]
        )
        XCTAssertEqual(items.map(\.name), ["Actor A", "Creator C", "Writer W", "Producer P"])
        XCTAssertEqual(items.map(\.kind), [.cast, .crew(.creator), .cast, .crew(.producer)])
        XCTAssertEqual(items[1].key, "tmdb:9|creator", "the creator crew card keeps its creditKey identity")
    }

    /// Severance's shape (TMDB tv/95396): `created_by` Dan Erickson is prepended to cast as "Creator"
    /// (marked `.creator`) and listed in `creators`, while `crew` carries him only as Writer and
    /// Executive Producer: actors, then Dan Erickson · Creator, then the crew.
    func testCreatorsListBacksPrependedCreator() {
        let items = DetailCreditRow.items(
            cast: [cast("Dan Erickson", "Creator", id: 3442409, marked: .creator), cast("Adam Scott", "Mark Scout", id: 1),
                   cast("Britt Lower", "Helly Riggs", id: 2), cast("Ben Stiller", "Kier Eagan (voice) (uncredited)", id: 7399)],
            crew: [crew("Ben Stiller", "Director", .director, id: 7399), crew("Dan Erickson", "Writer", .writer, id: 3442409),
                   crew("Ben Stiller", "Executive Producer", .producer, id: 7399),
                   crew("Dan Erickson", "Executive Producer", .producer, id: 3442409)],
            creators: [crew("Dan Erickson", "Creator", .creator, id: 3442409)]
        )
        XCTAssertEqual(items.map(\.name), ["Adam Scott", "Britt Lower", "Ben Stiller", "Dan Erickson",
                                           "Ben Stiller", "Dan Erickson", "Ben Stiller", "Dan Erickson"])
        XCTAssertEqual(items[3].subtitle, "Creator")
        XCTAssertEqual(items[3].kind, .cast)
        XCTAssertEqual(items.filter { $0.subtitle == "Creator" }.count, 1)
    }

    /// A creator only in `creators` (not prepended, not in crew) still gets a Creator card, after
    /// the actors and ahead of the other crew.
    func testCreatorsListWithoutPrependedEntryGivesCreatorCard() {
        let items = DetailCreditRow.items(
            cast: [cast("Adam Scott", "Mark Scout", id: 1)],
            crew: [crew("Ben Stiller", "Director", .director, id: 7399), crew("Dan Erickson", "Writer", .writer, id: 3442409)],
            creators: [crew("Dan Erickson", "Creator", .creator, id: 3442409)]
        )
        XCTAssertEqual(items.map(\.name), ["Adam Scott", "Dan Erickson", "Ben Stiller", "Dan Erickson"])
        XCTAssertEqual(items[1].kind, .crew(.creator))
        XCTAssertEqual(items[1].key, "tmdb:3442409|creator")
    }

    /// `creators` and a creator-category crew credit for the same person give one card.
    func testCreatorsListAndCreatorCrewAreOneCard() {
        let prepended = DetailCreditRow.items(
            cast: [cast("Dan Erickson", "Creator", id: 3442409), cast("Adam Scott", "Mark Scout", id: 1)],
            crew: [crew("Dan Erickson", "Creator", .creator, id: 3442409), crew("Ben Stiller", "Director", .director, id: 7399)],
            creators: [crew("Dan Erickson", "Creator", .creator, id: 3442409)]
        )
        XCTAssertEqual(prepended.map(\.name), ["Adam Scott", "Dan Erickson", "Ben Stiller"])
        let crewOnly = DetailCreditRow.items(
            cast: [cast("Adam Scott", "Mark Scout", id: 1)],
            crew: [crew("Dan Erickson", "Creator", .creator, id: 3442409)],
            creators: [crew("Dan Erickson", "Creator", .creator, id: 3442409)]
        )
        XCTAssertEqual(crewOnly.map(\.name), ["Adam Scott", "Dan Erickson"])
    }

    // MARK: Actor limit (Apple-style)

    private func actorCast(_ count: Int) -> [DetailCastCredit] {
        (1...count).map { cast("Actor \($0)", "Role \($0)", id: 100 + $0) }
    }

    /// `actorLimit` keeps the first N actors; the marked creator and the crew all follow, and the
    /// kept cards' keys match the uncapped row's.
    func testActorLimitCapsActorsOnly() {
        let castList = [cast("Dan Erickson", "Creator", id: 3442409, marked: .creator)] + actorCast(25)
        let crewList = [crew("Ben Stiller", "Director", .director, id: 7399), crew("Dan Erickson", "Writer", .writer, id: 3442409)]
        let capped = DetailCreditRow.items(cast: castList, crew: crewList, actorLimit: 20)
        let uncapped = DetailCreditRow.items(cast: castList, crew: crewList)
        XCTAssertEqual(capped.count, 23)
        XCTAssertEqual(capped.prefix(20).map(\.name), (1...20).map { "Actor \($0)" })
        XCTAssertEqual(capped.suffix(3).map(\.name), ["Dan Erickson", "Ben Stiller", "Dan Erickson"])
        XCTAssertEqual(capped[20].subtitle, "Creator")
        XCTAssertEqual(uncapped.count, 28)
        let uncappedKeys = Set(uncapped.map(\.key))
        XCTAssertTrue(capped.allSatisfy { uncappedKeys.contains($0.key) }, "capping must not change any kept card's key")
    }

    /// No limit (Cinematic, Classic) or a limit above the actor count keeps every actor.
    func testActorLimitNilOrLargeKeepsAllActors() {
        let castList = actorCast(5)
        let crewList = [crew("Ben Stiller", "Director", .director, id: 7399)]
        XCTAssertEqual(DetailCreditRow.items(cast: castList, crew: crewList).count, 6)
        XCTAssertEqual(DetailCreditRow.items(cast: castList, crew: crewList, actorLimit: 20).count, 6)
        XCTAssertEqual(DetailCreditRow.items(cast: castList, crew: crewList, actorLimit: 0).map(\.name), ["Ben Stiller"])
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
        XCTAssertEqual(after.firstIndex(where: { $0.key == remembered }), 1, "actors lead; the prepended director follows them")
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

    private static let mappedJobs = ["Director", "Writer", "Screenplay", "Teleplay", "Story", "Novel", "Characters",
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
