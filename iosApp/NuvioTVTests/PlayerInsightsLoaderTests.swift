import XCTest
@testable import NuvioTV

/// `PlayerInsightsLoader` (generation-token stale discard), `PlayerInsightsIdentity`, life-date
/// formatting and `PlayerInfoPill.visible(for:)`. Fakes are resumed by hand, no SharedCore.
@MainActor
final class PlayerInsightsLoaderTests: XCTestCase {

    /// A fetch the test resumes manually, one continuation per call.
    private final class Gate<Key: Sendable, Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var keys: [Key] = []
        private var conts: [CheckedContinuation<Value?, Never>] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return keys.count }
        func fetch(_ key: Key) async -> Value? {
            await withCheckedContinuation { c in
                lock.lock(); keys.append(key); conts.append(c); lock.unlock()
            }
        }
        func resume(_ index: Int, _ value: Value?) {
            lock.lock(); let c = conts[index]; lock.unlock()
            c.resume(returning: value)
        }
        /// Index of the first fetch whose key matches. Fetches run in unstructured Tasks, so their
        /// arrival order is not guaranteed; tests that start several resume by key, not by position.
        func index(where match: (Key) -> Bool) -> Int {
            lock.lock(); defer { lock.unlock() }
            return keys.firstIndex(where: match)!
        }
    }

    private func person(_ id: Int, _ name: String = "P") -> PlayerPanelPerson {
        PlayerPanelPerson(id: id, name: "\(name)\(id)", role: nil, photo: nil, isCrew: false)
    }
    private func credits(_ ids: [Int]) -> PlayerInsightsCredits {
        PlayerInsightsCredits(identityKey: "k", people: ids.map { person($0) })
    }
    private func ident(_ id: String, s: Int? = nil, e: Int? = nil) -> PlayerInsightsIdentity {
        PlayerInsightsIdentity(contentType: "series", parentMetaId: id, season: s, episode: e)
    }
    private func detail(_ id: Int) -> PlayerPanelPersonDetail {
        PlayerPanelPersonDetail(id: id, name: "D\(id)", photo: nil, knownForDepartment: nil,
                                lifeDates: nil, biography: nil, knownFor: [])
    }
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
    private func make(_ credits: Gate<PlayerInsightsIdentity, PlayerInsightsCredits>,
                      _ people: Gate<Int, PlayerPanelPersonDetail>? = nil,
                      castEnabled: Bool = true) -> (PlayerTopPanelModel, PlayerInsightsLoader) {
        let model = PlayerTopPanelModel(info: PlayerPanelInfo(header: Self.header()))
        model.castEnabled = castEnabled
        let pg = people ?? Gate<Int, PlayerPanelPersonDetail>()
        let loader = PlayerInsightsLoader(model: model,
                                          fetchCredits: { await credits.fetch($0) },
                                          fetchPerson: { await pg.fetch($0) })
        return (model, loader)
    }
    private static func header() -> NativeInfoHeader {
        NativeInfoHeader(context: context(season: nil, episode: nil))
    }
    private static func context(season: Int?, episode: Int?) -> PlaybackContext {
        PlaybackContext(url: URL(string: "https://x.test/v.mkv")!, title: "T", contentType: "series",
                        parentMetaId: "tt1", videoId: "tt1:2:3", season: season, episode: episode, poster: nil,
                        background: nil, providerName: nil, providerAddonId: nil, streamTitle: nil,
                        streamSubtitle: nil, externalSubtitles: [])
    }

    // (a)
    func testLoadAThenBBeforeAReturnsAppliesOnlyB() async {
        let g = Gate<PlayerInsightsIdentity, PlayerInsightsCredits>()
        let (model, loader) = make(g)
        loader.load(identity: ident("a"))
        loader.load(identity: ident("b"))
        await settle()
        XCTAssertEqual(g.count, 2)
        g.resume(g.index { $0.parentMetaId == "b" }, credits([2]))
        await settle()
        g.resume(g.index { $0.parentMetaId == "a" }, credits([1]))
        await settle()
        XCTAssertEqual(model.people.map(\.id), [2])
    }

    // (b)
    func testSameIdentityTwiceFetchesOnce() async {
        let g = Gate<PlayerInsightsIdentity, PlayerInsightsCredits>()
        let (model, loader) = make(g)
        loader.load(identity: ident("a", s: 1, e: 2))
        loader.load(identity: ident("a", s: 1, e: 2))
        await settle()
        XCTAssertEqual(g.count, 1)
        g.resume(0, credits([1, 2]))
        await settle()
        loader.load(identity: ident("a", s: 1, e: 2))
        await settle()
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(model.people.count, 2)
    }

    // (c)
    func testCastDisabledSkipsFetchAndClearsPeople() async {
        let g = Gate<PlayerInsightsIdentity, PlayerInsightsCredits>()
        let (model, loader) = make(g, castEnabled: false)
        model.people = [person(9)]
        loader.load(identity: ident("a"))
        await settle()
        XCTAssertEqual(g.count, 0)
        XCTAssertTrue(model.people.isEmpty)
    }

    // (d)
    func testNewIdentityClearsPeopleAndClosesActorView() async {
        let g = Gate<PlayerInsightsIdentity, PlayerInsightsCredits>()
        let (model, loader) = make(g)
        loader.load(identity: ident("a"))
        await settle()
        g.resume(0, credits([1]))
        await settle()
        model.openPerson(model.people[0])
        model.actorDetail = detail(1)
        loader.load(identity: ident("a", s: 1, e: 2))
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertNil(model.actorView)
        XCTAssertNil(model.actorDetail)
    }

    // (e)
    func testPersonDetailStaleDiscard() async {
        let cg = Gate<PlayerInsightsIdentity, PlayerInsightsCredits>()
        let pg = Gate<Int, PlayerPanelPersonDetail>()
        let (model, loader) = make(cg, pg)
        defer { withExtendedLifetime(loader) {} }
        model.openPerson(person(1))
        model.openPerson(person(2))
        await settle()
        XCTAssertEqual(pg.count, 2)
        pg.resume(pg.index { $0 == 1 }, detail(1))
        await settle()
        XCTAssertNil(model.actorDetail)
        pg.resume(pg.index { $0 == 2 }, detail(2))
        await settle()
        XCTAssertEqual(model.actorDetail?.id, 2)
    }

    // (f)
    func testClosingActorViewBeforeDetailReturnsKeepsDetailNil() async {
        let cg = Gate<PlayerInsightsIdentity, PlayerInsightsCredits>()
        let pg = Gate<Int, PlayerPanelPersonDetail>()
        let (model, loader) = make(cg, pg)
        defer { withExtendedLifetime(loader) {} }
        model.openPerson(person(1))
        await settle()
        XCTAssertTrue(model.menuBack())
        pg.resume(pg.index { $0 == 1 }, detail(1))
        await settle()
        XCTAssertNil(model.actorDetail)
        XCTAssertNil(model.actorView)
    }

    // (g)
    func testIdentityCopiesTheFourFields() {
        let ctx = Self.context(season: 2, episode: 3)
        XCTAssertEqual(PlayerInsightsIdentity(context: ctx),
                       PlayerInsightsIdentity(contentType: "series", parentMetaId: "tt1", season: 2, episode: 3))
    }

    // (h)
    func testLifeDatesFormatting() {
        XCTAssertEqual(PlayerInsightsLoader.lifeDates(birthday: "1956-03-04", deathday: "2024-01-09"), "1956 \u{2013} 2024")
        XCTAssertEqual(PlayerInsightsLoader.lifeDates(birthday: "1974-05-05", deathday: nil), "Born 1974")
        XCTAssertNil(PlayerInsightsLoader.lifeDates(birthday: nil, deathday: "2024-01-09"))
        XCTAssertNil(PlayerInsightsLoader.lifeDates(birthday: "", deathday: nil))
        XCTAssertNil(PlayerInsightsLoader.trimmedBiography("  \n "))
        XCTAssertEqual(PlayerInsightsLoader.trimmedBiography(" Hi \n"), "Hi")
    }

    // MARK: - Pill visibility

    func testPillVisibilityRules() {
        let model = PlayerTopPanelModel(info: PlayerPanelInfo(header: Self.header()))
        model.castEnabled = true
        XCTAssertEqual(PlayerInfoPill.visible(for: model), [.info])
        model.people = [person(1)]
        XCTAssertEqual(PlayerInfoPill.visible(for: model), [.info, .cast])
        model.castEnabled = false
        XCTAssertEqual(PlayerInfoPill.visible(for: model), [.info])
        model.castEnabled = true
        model.chapters = [PlayerPanelChapter(id: 0, title: "c", sec: 0, isCurrent: true)]
        model.upNext = PlayerPanelUpNext(title: "n", subtitle: nil, still: nil)
        XCTAssertEqual(PlayerInfoPill.visible(for: model), [.info, .cast, .chapters, .upNext])
    }
}
