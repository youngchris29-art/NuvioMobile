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
        /// Index of the last fetch whose key matches (for a key requested twice, with a settle in
        /// between so the first request is known to have arrived first).
        func lastIndex(where match: (Key) -> Bool) -> Int {
            lock.lock(); defer { lock.unlock() }
            return keys.lastIndex(where: match)!
        }
    }

    /// Records whether a fetch's Task saw cancellation (the Gate's continuation ignores it).
    private final class CancelFlags: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled: Set<String> = []
        func mark(_ key: String) { lock.lock(); cancelled.insert(key); lock.unlock() }
        func contains(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled.contains(key) }
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

    // (a) Pins the generation token. The Gate ignores cancellation, so A's fetch still returns
    // after B's load cancelled it and A's result reaches `applyCredits`; only the token check
    // (A's token is no longer `generation`) keeps A off the panel. Drop that guard and this fails.
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

    // (a2) The token again, stale first: A returns while B is still out; the panel stays empty
    // (no flash of A's cast) until B lands.
    func testStaleCreditsBeforeTheCurrentOneLeaveThePanelEmpty() async {
        let g = Gate<PlayerInsightsIdentity, PlayerInsightsCredits>()
        let (model, loader) = make(g)
        loader.load(identity: ident("a"))
        loader.load(identity: ident("b"))
        await settle()
        g.resume(g.index { $0.parentMetaId == "a" }, credits([1]))
        await settle()
        XCTAssertTrue(model.people.isEmpty, "a superseded result was applied")
        g.resume(g.index { $0.parentMetaId == "b" }, credits([2]))
        await settle()
        XCTAssertEqual(model.people.map(\.id), [2])
    }

    // (a3) Pins the cancel, which the token does not need: a superseded fetch's Task is cancelled,
    // so a cancellation-aware fetch (the live one could become one) can stop its network work.
    func testSupersededCreditsFetchIsCancelled() async {
        let g = Gate<PlayerInsightsIdentity, PlayerInsightsCredits>()
        let flags = CancelFlags()
        let model = PlayerTopPanelModel(info: PlayerPanelInfo(header: Self.header()))
        model.castEnabled = true
        let loader = PlayerInsightsLoader(
            model: model,
            fetchCredits: { identity in
                await withTaskCancellationHandler {
                    await g.fetch(identity)
                } onCancel: {
                    flags.mark(identity.parentMetaId)
                }
            },
            fetchPerson: { _ in nil })
        defer { withExtendedLifetime(loader) {} }
        loader.load(identity: ident("a"))
        await settle()
        loader.load(identity: ident("b"))
        await settle()
        XCTAssertTrue(flags.contains("a"), "the superseded fetch was not cancelled")
        XCTAssertFalse(flags.contains("b"))
        g.resume(g.index { $0.parentMetaId == "a" }, nil)
        g.resume(g.index { $0.parentMetaId == "b" }, credits([2]))
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

    // (e) Pins `personGeneration`. Person 1 is opened, then 2, then 1 again, so when the first
    // fetch for 1 returns (the Gate ignores cancellation) the actor view shows person 1 again and
    // the id check passes: only the token keeps the stale detail out. Drop that guard and this fails.
    func testPersonDetailStaleDiscard() async {
        let cg = Gate<PlayerInsightsIdentity, PlayerInsightsCredits>()
        let pg = Gate<Int, PlayerPanelPersonDetail>()
        let (model, loader) = make(cg, pg)
        defer { withExtendedLifetime(loader) {} }
        model.openPerson(person(1))
        await settle()
        model.openPerson(person(2))
        model.openPerson(person(1))
        await settle()
        XCTAssertEqual(pg.count, 3)
        let staleOne = pg.index { $0 == 1 }
        let freshOne = pg.lastIndex { $0 == 1 }
        XCTAssertNotEqual(staleOne, freshOne)
        pg.resume(staleOne, PlayerPanelPersonDetail(id: 1, name: "stale", photo: nil, knownForDepartment: nil,
                                                    lifeDates: nil, biography: nil, knownFor: []))
        await settle()
        XCTAssertNil(model.actorDetail, "a superseded detail for the same person was applied")
        pg.resume(pg.index { $0 == 2 }, detail(2))
        await settle()
        XCTAssertNil(model.actorDetail, "a detail for a card no longer open was applied")
        pg.resume(freshOne, detail(1))
        await settle()
        XCTAssertEqual(model.actorDetail?.name, "D1")
    }

    // Review r9 (P2): a failed detail fetch is flagged so the actor view can stop its spinner.
    func testFailedPersonDetailSetsFailedFlagAndReopenResetsIt() async {
        let cg = Gate<PlayerInsightsIdentity, PlayerInsightsCredits>()
        let pg = Gate<Int, PlayerPanelPersonDetail>()
        let (model, loader) = make(cg, pg)
        defer { withExtendedLifetime(loader) {} }
        XCTAssertFalse(model.actorDetailFailed)
        model.openPerson(person(1))
        await settle()
        XCTAssertFalse(model.actorDetailFailed, "loading is not failed")
        pg.resume(pg.index { $0 == 1 }, nil)
        await settle()
        XCTAssertNil(model.actorDetail)
        XCTAssertTrue(model.actorDetailFailed)
        model.openPerson(person(1))
        XCTAssertFalse(model.actorDetailFailed, "reopening resets the flag while loading")
        await settle()
        pg.resume(pg.lastIndex { $0 == 1 }, detail(1))
        await settle()
        XCTAssertEqual(model.actorDetail?.name, "D1")
        XCTAssertFalse(model.actorDetailFailed, "a successful fetch leaves it false")
        model.openPerson(person(2))
        await settle()
        pg.resume(pg.index { $0 == 2 }, nil)
        await settle()
        XCTAssertTrue(model.actorDetailFailed)
        XCTAssertTrue(model.menuBack())
        XCTAssertFalse(model.actorDetailFailed, "closing resets the flag")
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
