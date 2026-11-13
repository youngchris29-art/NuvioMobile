import XCTest
@testable import NuvioTV

/// Home Watchlist row (FEAT-92), W3 review r1: the release rule of `HomeWatchlistReleaseGate`.
@MainActor
final class HomeWatchlistReleaseGateTests: XCTestCase {
    typealias Inputs = HomeWatchlistReleaseGate.Inputs

    private var current = Inputs(subscribed: true, settled: true, covered: false, rowDrawn: true, nothingToDraw: false)
    private var pending: [@MainActor () -> Void] = []
    private var releases = 0
    private var gate: HomeWatchlistReleaseGate!

    override func setUp() {
        super.setUp()
        current = Inputs(subscribed: true, settled: true, covered: false, rowDrawn: true, nothingToDraw: false)
        pending = []
        releases = 0
        gate = HomeWatchlistReleaseGate(
            inputs: { [unowned self] in self.current },
            schedule: { [unowned self] _, block in self.pending.append(block) },
            release: { [unowned self] in self.releases += 1 })
    }

    private func runPending() {
        let blocks = pending
        pending = []
        for block in blocks { block() }
    }

    func testAllowsNeedsEveryCondition() {
        let all = Inputs(subscribed: true, settled: true, covered: false, rowDrawn: true, nothingToDraw: false)
        XCTAssertTrue(HomeWatchlistReleaseGate.allows(all))
        var v = all; v.subscribed = false
        XCTAssertFalse(HomeWatchlistReleaseGate.allows(v))
        v = all; v.settled = false
        XCTAssertFalse(HomeWatchlistReleaseGate.allows(v))
        v = all; v.rowDrawn = false
        XCTAssertFalse(HomeWatchlistReleaseGate.allows(v))
        v = all; v.covered = true
        XCTAssertFalse(HomeWatchlistReleaseGate.allows(v))
    }

    func testNothingToDrawStandsInForADrawnRow() {
        var v = Inputs(subscribed: true, settled: true, covered: false, rowDrawn: false, nothingToDraw: true)
        XCTAssertTrue(HomeWatchlistReleaseGate.allows(v))
        v.covered = true
        XCTAssertFalse(HomeWatchlistReleaseGate.allows(v))
    }

    func testReleasesOnceAfterTheDelay() {
        gate.evaluate()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(releases, 0)
        runPending()
        XCTAssertEqual(releases, 1)
        gate.evaluate()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(releases, 1)
    }

    func testCoverDuringTheDelayDoesNotRelease() {
        gate.evaluate()
        current.covered = true
        runPending()
        XCTAssertEqual(releases, 0)
        current.covered = false
        gate.evaluate()
        runPending()
        XCTAssertEqual(releases, 1)
    }

    func testSettleWhileCoveredWaitsForUncover() {
        current.covered = true
        gate.evaluate()
        XCTAssertTrue(pending.isEmpty)
        current.covered = false
        gate.evaluate()
        runPending()
        XCTAssertEqual(releases, 1)
    }

    func testNoRowDrawnWaitsForTheFirstRow() {
        current.rowDrawn = false
        gate.evaluate()
        XCTAssertTrue(pending.isEmpty)
        current.rowDrawn = true
        gate.evaluate()
        runPending()
        XCTAssertEqual(releases, 1)
    }

    func testResetDropsAPendingReleaseAndRearms() {
        gate.evaluate()
        XCTAssertEqual(pending.count, 1)
        gate.reset()
        runPending()
        XCTAssertEqual(releases, 0)
        gate.evaluate()
        runPending()
        XCTAssertEqual(releases, 1)
        gate.reset()
        gate.evaluate()
        runPending()
        XCTAssertEqual(releases, 2)
    }

    func testSeedPathNeverReleases() {
        current.subscribed = false
        gate.evaluate()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(releases, 0)
    }

    func testLaterEvaluateSupersedesAnEarlierPendingOne() {
        gate.evaluate()
        gate.evaluate()
        XCTAssertEqual(pending.count, 2)
        runPending()
        XCTAssertEqual(releases, 1)
    }
}
