import XCTest
@testable import NuvioTV

/// Batch M Wave 1 (BUG-187, Steven rc9: back from a cast member lands on Play): the meta adoption
/// rule that keeps the rows mounted across the reload, and the fallback restore's memory box.
@MainActor
final class DetailFocusReturnTests: XCTestCase {
    /// A4.4: the Cast row remembers a card by its stable `DetailCreditItem.key`, not its index.
    static let castCard = DetailCreditRow.castKey(name: "Robert Downey Jr.", role: "Tony Stark", tmdbId: 3223)
    static let otherCastCard = DetailCreditRow.castKey(name: "Gwyneth Paltrow", role: "Pepper Potts", tmdbId: 12052)
    static let crewCard = DetailCreditRow.focusKey("tmdb:15277|executive producer")

    // MARK: DetailMetaAdoption

    /// The pop's reload emits `isLoading` with no meta first; a page that has one keeps it.
    func testLoadingEmissionKeepsTheMetaOnScreen() {
        XCTAssertTrue(DetailMetaAdoption.keepsCurrent(hasMeta: true, incomingMeta: false))
    }

    /// Review r1: a reload error with no meta keeps the page too (no full-page error over content).
    func testReloadErrorKeepsTheMetaOnScreen() {
        XCTAssertTrue(DetailMetaAdoption.keepsCurrent(hasMeta: true, incomingMeta: false))
    }

    /// A meta always lands.
    func testMetaAlwaysLands() {
        XCTAssertFalse(DetailMetaAdoption.keepsCurrent(hasMeta: true, incomingMeta: true))
    }

    /// A first load (nothing on screen yet) takes every emission: loading, meta and error.
    func testFirstLoadTakesEveryEmission() {
        XCTAssertFalse(DetailMetaAdoption.keepsCurrent(hasMeta: false, incomingMeta: false))
        XCTAssertFalse(DetailMetaAdoption.keepsCurrent(hasMeta: false, incomingMeta: true))
    }

    // MARK: DetailFocusMemory

    /// Push from a cast card (focus goes nil on the way out), pop: the card is the target, once.
    func testPushFromACardArmsItOnce() {
        let memory = DetailFocusMemory()
        memory.note(row: .cast, key: Self.castCard)
        memory.note(row: .cast, key: nil)
        memory.arm()
        let target = memory.takeArmedTarget()
        XCTAssertEqual(target?.row, .cast)
        XCTAssertEqual(target?.key, Self.castCard)
        XCTAssertNil(memory.takeArmedTarget(), "a later appearance without a new push restores nothing")
    }

    /// Focus moved to the hero (or an untracked row) before the page left: nothing to restore.
    func testClearForgetsTheCard() {
        let memory = DetailFocusMemory()
        memory.note(row: .moreLikeThis, key: "tt0111161")
        memory.clear()
        memory.arm()
        XCTAssertNil(memory.takeArmedTarget())
    }

    /// Review r1: the engine reports Play between `onDisappear` (arm) and `onAppear` (take);
    /// that report must not disarm or forget the card.
    func testClearWhileHiddenKeepsTheArmedCard() {
        let memory = DetailFocusMemory()
        memory.note(row: .cast, key: Self.castCard)
        memory.arm()
        XCTAssertFalse(memory.pageVisible)
        memory.clear()
        let target = memory.takeArmedTarget()
        XCTAssertTrue(memory.pageVisible)
        XCTAssertEqual(target?.row, .cast)
        XCTAssertEqual(target?.key, Self.castCard)
    }

    /// Once the page is visible again, a move to the hero forgets the card as before.
    func testClearAfterAppearanceForgetsTheCard() {
        let memory = DetailFocusMemory()
        memory.note(row: .logos, key: "1")
        memory.arm()
        _ = memory.takeArmedTarget()
        memory.clear()
        memory.arm()
        XCTAssertNil(memory.takeArmedTarget())
    }

    /// An appearance with nothing armed still marks the page visible.
    func testUnarmedAppearanceMarksThePageVisible() {
        let memory = DetailFocusMemory()
        memory.arm()
        XCTAssertNil(memory.takeArmedTarget())
        XCTAssertTrue(memory.pageVisible)
        memory.note(row: .cast, key: Self.otherCastCard)
        memory.clear()
        memory.arm()
        XCTAssertNil(memory.takeArmedTarget())
    }

    /// The first appearance (no push yet) and a page that never touched a tracked row restore nothing.
    func testNothingArmedWithoutARememberedCard() {
        let memory = DetailFocusMemory()
        XCTAssertNil(memory.takeArmedTarget())
        memory.arm()
        XCTAssertNil(memory.takeArmedTarget())
    }

    /// A newer restore retires the older one's pending rungs.
    func testNewerRestoreRetiresTheOlder() {
        let memory = DetailFocusMemory()
        let first = memory.beginRestore()
        let second = memory.beginRestore()
        XCTAssertFalse(memory.isCurrent(first))
        XCTAssertTrue(memory.isCurrent(second))
    }

    // MARK: DetailFocusRestore

    func testTrackedRows() {
        for row in [DetailRowID.cast, .logos, .collection, .moreLikeThis] {
            XCTAssertTrue(DetailFocusRestore.tracks(row), "\(row)")
        }
        for row in [DetailRowID.episodes, .trailers, .bonus, .parental, .comments, .about] {
            XCTAssertFalse(DetailFocusRestore.tracks(row), "\(row)")
        }
    }

    /// Forced rungs correct any other card; late rungs only pull focus back into the row.
    func testRungRule() {
        XCTAssertTrue(DetailFocusRestore.shouldApply(force: true, current: nil, target: "2"))
        XCTAssertTrue(DetailFocusRestore.shouldApply(force: true, current: "0", target: "2"))
        XCTAssertFalse(DetailFocusRestore.shouldApply(force: true, current: "2", target: "2"))
        XCTAssertTrue(DetailFocusRestore.shouldApply(force: false, current: nil, target: "2"))
        XCTAssertFalse(DetailFocusRestore.shouldApply(force: false, current: "0", target: "2"))
    }

    /// FEAT-79's rung ladder, retired after its last rung.
    func testRungsMatchFeat79() {
        XCTAssertEqual(DetailFocusRestore.rungs.map(\.delay), [0, 0.35, 0.8, 1.1])
        XCTAssertEqual(DetailFocusRestore.rungs.map(\.force), [true, true, false, false])
        XCTAssertGreaterThan(DetailFocusRestore.retireDelay, DetailFocusRestore.rungs.map(\.delay).max() ?? 0)
    }

    // MARK: DetailPopGate (Batch P, P7 / BUG-194)

    /// Focus on the hero holds, the target row AND card lands, viewer input releases.
    func testPopGateHoldsUntilTheCardLands() {
        let target: (row: DetailRowID, key: String) = (.cast, Self.castCard)
        XCTAssertEqual(DetailPopGate.decide(focusedRow: nil, focusedKey: nil, target: target, viewerInput: false, regrabs: 0, clockLive: false), .hold)
        XCTAssertEqual(DetailPopGate.decide(focusedRow: .cast, focusedKey: Self.otherCastCard, target: target, viewerInput: false, regrabs: 0, clockLive: false), .hold,
                       "right row, wrong card is not a landing")
        XCTAssertEqual(DetailPopGate.decide(focusedRow: .moreLikeThis, focusedKey: Self.castCard, target: target, viewerInput: false, regrabs: 0, clockLive: false), .hold,
                       "right key, wrong row is not a landing")
        XCTAssertEqual(DetailPopGate.decide(focusedRow: .cast, focusedKey: Self.castCard, target: target, viewerInput: false, regrabs: 0, clockLive: false), .landed)
        XCTAssertEqual(DetailPopGate.decide(focusedRow: .cast, focusedKey: Self.castCard, target: target, viewerInput: true, regrabs: 0, clockLive: false), .release)
        XCTAssertEqual(DetailPopGate.decide(focusedRow: nil, focusedKey: nil, target: target, viewerInput: true, regrabs: 0, clockLive: false), .release)
    }

    /// The decision is a pure function of row, card and input: call order changes nothing.
    func testPopGateIgnoresTimestamps() {
        let target: (row: DetailRowID, key: String) = (.cast, Self.castCard)
        let inputs: [(DetailRowID?, String?, Bool)] = [(nil, nil, false), (.cast, Self.castCard, false), (.cast, Self.crewCard, false), (.cast, Self.castCard, true)]
        let forward = inputs.map { DetailPopGate.decide(focusedRow: $0.0, focusedKey: $0.1, target: target, viewerInput: $0.2, regrabs: 0, clockLive: false) }
        let backward = inputs.reversed().map { DetailPopGate.decide(focusedRow: $0.0, focusedKey: $0.1, target: target, viewerInput: $0.2, regrabs: 0, clockLive: false) }
        XCTAssertEqual(forward, backward.reversed())
    }

    // Review r2 P3-1: the held change keeps the first `old` and the latest `new`; a landing drops it;
    // `endRestore` hands it over exactly once.
    func testHeldFocusChangeKeepsFirstOldAndLatestNew() {
        let memory = DetailFocusMemory()
        memory.goLive((.cast, Self.castCard), startedAt: 10)
        memory.holdFocusChange(old: .about, new: nil)
        memory.holdFocusChange(old: nil, new: .logos)
        XCTAssertEqual(memory.heldFocusChange?.old, .about)
        XCTAssertEqual(memory.heldFocusChange?.new, .logos)
        let held = memory.endRestore()
        XCTAssertEqual(held?.old, .about)
        XCTAssertEqual(held?.new, .logos)
        XCTAssertNil(memory.heldFocusChange)
        XCTAssertNil(memory.endRestore())
    }

    func testLandingDropsTheHeldChangeSoALaterHoldStartsFresh() {
        let memory = DetailFocusMemory()
        memory.goLive((.cast, Self.castCard), startedAt: 10)
        memory.holdFocusChange(old: .about, new: nil)
        memory.dropHeldFocusChange()
        XCTAssertNil(memory.heldFocusChange)
        memory.holdFocusChange(old: .cast, new: .logos)
        XCTAssertEqual(memory.heldFocusChange?.old, .cast)
        XCTAssertEqual(memory.popStartedAt, 10)
        XCTAssertEqual(memory.popMoves, 0)
    }

    func testMemoryLiveStateFollowsGoLiveAndEnd() {
        let memory = DetailFocusMemory()
        XCTAssertFalse(memory.restoreLive)
        memory.goLive((.cast, Self.castCard))
        XCTAssertTrue(memory.restoreLive)
        XCTAssertEqual(memory.liveTarget?.key, Self.castCard)
        memory.endRestore()
        XCTAssertFalse(memory.restoreLive)
        XCTAssertNil(memory.liveTarget)
    }
}
