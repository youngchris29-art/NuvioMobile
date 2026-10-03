import Combine
import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (M3, BUG-133 / BUG-126; M4/FEAT-52): the trailer start gate's pure planner,
/// the Trailer Start Delay setting read, the rest-source identity, the horizontal-only morph-scroll
/// target, the per-row playing-key filter and the coordinator's subject.
final class TrailerStartGateTests: XCTestCase {

    // MARK: TrailerStartGate.step

    func testAutomaticWaitsForRestThenOneSecond() {
        XCTAssertEqual(TrailerStartGate.step(delay: .automatic, focusAge: 0.5, restAge: nil), .wait(0.05))
        XCTAssertEqual(TrailerStartGate.step(delay: .automatic, focusAge: 1.6, restAge: 0.4), .wait(0.05))
        XCTAssertEqual(TrailerStartGate.step(delay: .automatic, focusAge: 2.6, restAge: 1.0), .start(via: "rest"))
    }

    func testFixedDelayCountsFromFocusButNeverBeforeRest() {
        if case .start = TrailerStartGate.step(delay: .twoSeconds, focusAge: 2.5, restAge: nil) {
            XCTFail("a fixed delay must never start before the rows rest")
        }
        XCTAssertEqual(TrailerStartGate.step(delay: .twoSeconds, focusAge: 2.5, restAge: 0), .start(via: "rest"))
        XCTAssertEqual(TrailerStartGate.step(delay: .oneSecond, focusAge: 0.6, restAge: 0.3), .wait(0.05))
        guard case .wait(let remaining) = TrailerStartGate.step(delay: .threeSeconds, focusAge: 2.98, restAge: 1.5) else {
            return XCTFail("expected a wait")
        }
        XCTAssertEqual(remaining, 0.02, accuracy: 1e-9)
    }

    func testCeilingStartsWithoutRest() {
        for delay in TrailerStartDelay.allCases {
            XCTAssertEqual(TrailerStartGate.step(delay: delay, focusAge: 3.0, restAge: nil), .start(via: "ceiling"),
                           "delay \(delay.rawValue)")
        }
    }

    func testIsAtRest() {
        XCTAssertTrue(TrailerStartGate.isAtRest(sinceMotion: 0.2, restPending: false))
        XCTAssertFalse(TrailerStartGate.isAtRest(sinceMotion: 0.05, restPending: false))
        XCTAssertFalse(TrailerStartGate.isAtRest(sinceMotion: 10, restPending: true))
        XCTAssertTrue(TrailerStartGate.isAtRest(sinceMotion: .greatestFiniteMagnitude, restPending: false))
    }

    // MARK: TrailerStartDelay

    func testDelayCurrentFallsBack() throws {
        let suite = "TrailerStartGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(TrailerStartDelay.current(defaults), .automatic)
        defaults.set("bogus", forKey: TrailerStartDelay.storageKey)
        XCTAssertEqual(TrailerStartDelay.current(defaults), .automatic)
        defaults.set("2", forKey: TrailerStartDelay.storageKey)
        XCTAssertEqual(TrailerStartDelay.current(defaults), .twoSeconds)
        XCTAssertEqual(TrailerStartDelay.storageKey, "trailer_start_delay")
        XCTAssertEqual(TrailerStartDelay.automatic.rawValue, "auto")
        XCTAssertNil(TrailerStartDelay.automatic.fixedSeconds)
        XCTAssertEqual(TrailerStartDelay.threeSeconds.fixedSeconds, 3)
    }

    // MARK: RowRestSource

    @MainActor
    func testRestSourceCustomEquality() {
        let a = FakeRestSignal()
        let b = FakeRestSignal()
        XCTAssertEqual(RowRestSource.custom(a), RowRestSource.custom(a))
        XCTAssertNotEqual(RowRestSource.custom(a), RowRestSource.custom(b))
        XCTAssertEqual(RowRestSource.motionClock, RowRestSource.motionClock)
        XCTAssertEqual(RowRestSource.pinnedHome, RowRestSource.pinnedHome)
        XCTAssertNotEqual(RowRestSource.motionClock, RowRestSource.pinnedHome)
        XCTAssertNotEqual(RowRestSource.custom(a), RowRestSource.motionClock)

        a.secondsSinceMotion = 1
        a.restPending = false
        XCTAssertTrue(RowRestSource.custom(a).isAtRest())
        a.restPending = true
        XCTAssertFalse(RowRestSource.custom(a).isAtRest())
        a.restPending = false
        a.secondsSinceMotion = 0.01
        XCTAssertFalse(RowRestSource.custom(a).isAtRest())
    }

    // MARK: RowMorphScroll.target

    // Geometry for these cases: resting 200, expanded 356, gap 28 (one step = 228), 10 cards and no
    // See All, so the resting content is 10 × 200 + 9 × 28 = 2252 and the grown content 2408.

    func testRowMorphScroll() {
        func target(index: Int, gap: CGFloat = 28, visibleMinX: CGFloat = 0, viewport: CGFloat = 1400,
                    content: CGFloat = 2252, inset: CGFloat = 0, grown: Bool = false) -> CGFloat? {
            RowMorphScroll.target(index: index, restingWidth: 200, expandedWidth: 356, gap: gap,
                                  visibleMinX: visibleMinX, viewportWidth: viewport, contentWidth: content,
                                  insetLeading: inset, contentAlreadyGrown: grown)
        }

        // Card 2 (trailing 456 + 356 = 812) fits a 1400 viewport.
        XCTAssertNil(target(index: 2))
        // Card 5 (trailing 1140 + 356 = 1496) overflows by 96.
        XCTAssertEqual(target(index: 5), 96)
        // Already scrolled far enough: fits.
        XCTAssertNil(target(index: 5, visibleMinX: 100))
        // Last card: its trailing edge IS the grown content's end, so the target is the clamp bound
        // 2408 − 1400 = 1008; an over-estimated gap (40) asks for 1116 and is clamped to 1008.
        XCTAssertEqual(target(index: 9), 1008)
        XCTAssertEqual(target(index: 9, gap: 40), 1008)
        // No growth → nothing to do.
        XCTAssertNil(RowMorphScroll.target(index: 9, restingWidth: 200, expandedWidth: 200, gap: 28,
                                           visibleMinX: 0, viewportWidth: 1400, contentWidth: 2252,
                                           insetLeading: 0, contentAlreadyGrown: false))
        // Critique #24: a 60 pt leading inset shifts the decision by 60. Card 4 (trailing
        // 912 + 356 = 1268) fits a 1300 viewport without the inset and overflows by 28 with it.
        XCTAssertNil(target(index: 4, viewport: 1300))
        XCTAssertEqual(target(index: 4, viewport: 1300, content: 2252 + 60, inset: 60), 28)
        // `contentAlreadyGrown` uses the live width as-is: with the grown 2408 passed in, the clamp
        // bound is 1008 when it says so, 1164 (2408 + 156 − 1400) when it does not.
        XCTAssertEqual(target(index: 9, gap: 40, content: 2408, grown: true), 1008)
        XCTAssertEqual(target(index: 9, gap: 40, content: 2408, grown: false), 1116)
    }

    // MARK: CatalogRowView.rowPlayingKey

    func testRowPlayingKeyFilter() {
        let keys = ["movie:tt1", "series:tt2", "movie:tt3"]
        XCTAssertEqual(CatalogRowView.rowPlayingKey("series:tt2", itemKeys: keys), "series:tt2")
        XCTAssertNil(CatalogRowView.rowPlayingKey("movie:tt9", itemKeys: keys))
        XCTAssertNil(CatalogRowView.rowPlayingKey(nil, itemKeys: keys))
        XCTAssertEqual(CatalogRowView.rowPlayingKey("movie:tt1", itemKeys: keys + ["movie:tt1"]), "movie:tt1")
    }

    // MARK: InlineTrailerCoordinator subject

    @MainActor
    func testCoordinatorSubject() {
        let coordinator = InlineTrailerCoordinator.shared
        let owner = InlineTrailerCardModel()
        let stranger = InlineTrailerCardModel()
        var received: [String?] = []
        let subscription = coordinator.playingKeySubject.dropFirst().sink { received.append($0) }
        defer { subscription.cancel() }

        coordinator.claimPlayback(owner, key: "movie:tt1")
        XCTAssertEqual(received, ["movie:tt1"])
        XCTAssertEqual(coordinator.playingKey, "movie:tt1")

        // A release by a model that does not own the slot sends nothing.
        coordinator.releasePlayback(stranger)
        XCTAssertEqual(received, ["movie:tt1"])

        // Re-claiming the same key is not a change.
        coordinator.claimPlayback(owner, key: "movie:tt1")
        XCTAssertEqual(received, ["movie:tt1"])

        coordinator.releasePlayback(owner)
        XCTAssertEqual(received, ["movie:tt1", nil])
        XCTAssertNil(coordinator.playingKey)
    }
}

@MainActor
private final class FakeRestSignal: RowRestSignal {
    var restPending = false
    var secondsSinceMotion: TimeInterval = .greatestFiniteMagnitude
}
