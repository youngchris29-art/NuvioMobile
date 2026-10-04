import XCTest
@testable import NuvioTV

/// BUG-41 (beta.18, Wave W6): unit coverage for the two pure pieces behind the Detail page's scroll
/// diagnostics and chip glass — `ScrollingLatch` (the debounce arithmetic behind
/// `ScrollDimModel.isScrolling`, `DetailView.swift`) and `DetailView.chipGlassFlat(...)` (the truth
/// table deciding whether `metaChip`/parental-guide chips render flat material instead of
/// `.glassEffect`).
///
/// beta.19-rc1 verdict (D2, BUG-140): the page no longer flattens glass while it scrolls, so
/// `ScrollingLatch` now only feeds the `debug_ux6` probe's `scrolling=` token and `chipGlassFlat`
/// has two inputs (a live background trailer, the `DetailScrollAB` glass legs).
///
/// Both are exercised as pure functions of fabricated inputs — no `Task.sleep`, no `DetailView`
/// instance, no simulator. `ScrollDimModel` itself (the stateful `Task`-based timer wiring that
/// calls into `ScrollingLatch`) is `private` to `DetailView.swift` and deliberately not exposed
/// here; the evidence run proving the actual on-screen debounce behavior is the main session's
/// `-debug.detailScrollProbe YES` device/simulator pass, not this file.
final class DetailScrollProbeTests: XCTestCase {

    // MARK: - ScrollingLatch

    /// A brand-new change (`now == lastChange`) must read as scrolling regardless of `idle`.
    func testFreshChangeIsScrolling() {
        XCTAssertTrue(ScrollingLatch.isScrolling(now: 0, lastChange: 0, idle: 0.15))
    }

    /// Comfortably inside the 150ms window — still latched.
    func testWithinIdleWindowIsScrolling() {
        XCTAssertTrue(ScrollingLatch.isScrolling(now: 0.10, lastChange: 0, idle: 0.15),
                      "100ms after the last change, still within the 150ms idle window, must read as scrolling")
    }

    /// Exactly at the 150ms boundary — the ask is "cleared AFTER ~150ms of no change", so the
    /// boundary itself must already read as idle (closed lower bound / open upper bound: `now -
    /// lastChange < idle`, not `<=`).
    func testExactlyAtIdleBoundaryIsNotScrolling() {
        XCTAssertFalse(ScrollingLatch.isScrolling(now: 0.15, lastChange: 0, idle: 0.15),
                       "150ms after the last change (the idle threshold itself) must read as idle")
    }

    /// Comfortably past the idle window.
    func testWellPastIdleWindowIsNotScrolling() {
        XCTAssertFalse(ScrollingLatch.isScrolling(now: 1.0, lastChange: 0, idle: 0.15))
    }

    /// The debounce "extends" behavior: a change that lands inside the current window must push
    /// the idle deadline out from that change's own timestamp, not the original one. Modeled here
    /// as two `lastChange` candidates checked against the same later `now` — the whole point of
    /// `ScrollDimModel.noteScrollChange()` re-arming `lastChangeTime` on every call rather than
    /// only on the first.
    func testChangeInsideWindowExtendsTheLatch() {
        // Original change at t=0. A second change lands at t=0.10 (inside the first change's
        // 150ms window). By t=0.20, the ORIGINAL change alone would have gone idle (0.20 - 0 =
        // 0.20 >= 0.15)...
        XCTAssertFalse(ScrollingLatch.isScrolling(now: 0.20, lastChange: 0, idle: 0.15),
                       "sanity check: without the extension, 200ms past the original change is idle")
        // ...but the SECOND change (the one `noteScrollChange` would have recorded as the new
        // `lastChangeTime`) keeps it latched, since only 100ms have passed since that one.
        XCTAssertTrue(ScrollingLatch.isScrolling(now: 0.20, lastChange: 0.10, idle: 0.15),
                      "a change inside the window must extend the latch past where the original change's window would have expired")
    }

    /// A non-default `idle` is honored end to end (not a hardcoded 0.15 anywhere in the math).
    func testCustomIdleWindow() {
        XCTAssertTrue(ScrollingLatch.isScrolling(now: 0.4, lastChange: 0, idle: 0.5))
        XCTAssertFalse(ScrollingLatch.isScrolling(now: 0.5, lastChange: 0, idle: 0.5))
    }

    func testDefaultIdleIs150Milliseconds() {
        XCTAssertEqual(ScrollingLatch.defaultIdle, 0.15, accuracy: 0.0001)
    }

    // MARK: - DetailView.chipGlassFlat truth table

    /// All 4 combinations of the two inputs — `chipGlassFlat` is a plain OR, but this pins the exact
    /// truth table down (not just "at least one true → true") so a future edit that accidentally
    /// ANDs one branch, or drops one entirely, fails loudly here instead of only showing up as a
    /// subtle on-device glass/flat mismatch.
    ///
    /// beta.19-rc1 verdict (D2, BUG-140): scrolling is not an input any more. The old
    /// scrolling-only row is deleted rather than replaced by a signature check (which would prove
    /// nothing); the glass-stays-constant-while-scrolling proof is the test33 Classic leg, which
    /// reads `debug_ux6`'s `glass=` before, during and after a scroll.
    func testChipGlassFlatTruthTable() {
        let cases: [(trailerActive: Bool, glassDisabled: Bool, expected: Bool)] = [
            (false, false, false),
            (true,  false, true),
            (false, true,  true),
            (true,  true,  true),
        ]
        for testCase in cases {
            let actual = DetailView.chipGlassFlat(
                trailerActive: testCase.trailerActive,
                glassDisabled: testCase.glassDisabled
            )
            XCTAssertEqual(
                actual, testCase.expected,
                "chipGlassFlat(trailerActive: \(testCase.trailerActive), glassDisabled: \(testCase.glassDisabled)) should be \(testCase.expected), was \(actual)"
            )
        }
    }

    /// The rest state this whole rule cares about: nothing active, glass stays glass.
    func testRestStateKeepsGlass() {
        XCTAssertFalse(DetailView.chipGlassFlat(trailerActive: false, glassDisabled: false))
    }

    /// A live background trailer is the one steady state that flattens the chips (BUG-41 item 4).
    func testBackgroundTrailerFlattensChips() {
        XCTAssertTrue(DetailView.chipGlassFlat(trailerActive: true, glassDisabled: false))
    }
}
