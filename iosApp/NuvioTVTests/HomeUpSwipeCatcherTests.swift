import XCTest
@testable import NuvioTV

/// rc13 (BUG-112 swipe half) — `HomeUpSwipeDecision`, the one question the window-level swipe
/// catcher asks: did the focus engine resolve this Up swipe, or did it give up on it?
///
/// Pure-value tests on purpose. The thing being proven is an ORDERING property — that a focus
/// update which lands BEFORE the recognizer's own callback is still seen — and the simulator
/// cannot stage it: its focus engine resolves every Up, and the DEBUG proxy (Play/Pause) moves no
/// focus at all, so there is no engine update to arrive early. What these tests pin is the
/// decision; the device pass is what says the baseline is taken at the right moment.
final class HomeUpSwipeCatcherTests: XCTestCase {

    /// Stand-ins for focusable items. Identity is all the decision reads.
    private let cardA = NSObject()
    private let cardB = NSObject()

    private func baseline(generation: Int, item: NSObject?) -> HomeUpSwipeDecision.Baseline {
        HomeUpSwipeDecision.Baseline(focusGeneration: generation,
                                     focusedItem: item.map { ObjectIdentifier($0) })
    }

    /// The case the feature exists for: the user flicks Up at the top of the shelf, the engine
    /// finds no candidate, nothing moves. Both readings — the recognizer's callback and the settle
    /// deadline — see the same focus state the finger went down on, so the fallback runs.
    func testASwipeThatMovesNoFocusFallsBack() {
        let touchDown = baseline(generation: 7, item: cardA)

        XCTAssertEqual(
            HomeUpSwipeDecision.verdict(phase: .callback, baseline: touchDown,
                                        focusGeneration: 7, focusedItem: ObjectIdentifier(cardA)),
            .fallBack
        )
        XCTAssertEqual(
            HomeUpSwipeDecision.verdict(phase: .deadline, baseline: touchDown,
                                        focusGeneration: 7, focusedItem: ObjectIdentifier(cardA)),
            .fallBack
        )
    }

    /// The Codex round-1 defect. `UIFocusSystem.didUpdateNotification` for the swipe is delivered
    /// BEFORE the recognizer's target callback: the engine resolved the move and merely reported
    /// later than it applied. The old code snapshotted focus inside that callback, so it recorded
    /// the DESTINATION and 150 ms later agreed with itself that nothing had happened — a second,
    /// unasked-for move. Against a touch-down baseline the generation has already advanced, and the
    /// evaluation declines before the settle window is even scheduled.
    func testFocusMovedBeforeTheCallbackReadsAsEngineConsumed() {
        let touchDown = baseline(generation: 7, item: cardA)

        XCTAssertEqual(
            HomeUpSwipeDecision.verdict(phase: .callback, baseline: touchDown,
                                        focusGeneration: 8, focusedItem: ObjectIdentifier(cardB)),
            .consumedBeforeCallback
        )
    }

    /// The ordinary case the settle window was built for: at the callback nothing has moved yet,
    /// and the engine's update lands during the window. Same answer, different name — the phase is
    /// what separates "the engine beat us to it" from "the engine was slower than us".
    func testFocusMovedInsideTheSettleWindowDeclines() {
        let touchDown = baseline(generation: 7, item: cardA)

        XCTAssertEqual(
            HomeUpSwipeDecision.verdict(phase: .callback, baseline: touchDown,
                                        focusGeneration: 7, focusedItem: ObjectIdentifier(cardA)),
            .fallBack
        )
        XCTAssertEqual(
            HomeUpSwipeDecision.verdict(phase: .deadline, baseline: touchDown,
                                        focusGeneration: 8, focusedItem: ObjectIdentifier(cardB)),
            .movedInWindow
        )
    }

    /// Belt and braces: a focused item that changed identity without the generation moving still
    /// declines. The counter is the primary signal (focus cannot change without posting an update),
    /// so this should be unreachable — which is exactly why it is worth pinning that it fails
    /// closed rather than open.
    func testAChangedFocusedItemDeclinesEvenWithTheGenerationUnmoved() {
        let touchDown = baseline(generation: 7, item: cardA)

        XCTAssertEqual(
            HomeUpSwipeDecision.verdict(phase: .callback, baseline: touchDown,
                                        focusGeneration: 7, focusedItem: ObjectIdentifier(cardB)),
            .consumedBeforeCallback
        )
        XCTAssertEqual(
            HomeUpSwipeDecision.verdict(phase: .deadline, baseline: touchDown,
                                        focusGeneration: 7, focusedItem: nil),
            .movedInWindow
        )
    }

    /// No touch sequence recorded — the catcher was installed mid-gesture, or (in DEBUG) the proxy
    /// trigger was called without seeding a baseline. Nothing to compare against, so it declines:
    /// a missed fallback leaves today's behaviour, a spurious one moves focus.
    func testNoBaselineDeclines() {
        XCTAssertEqual(
            HomeUpSwipeDecision.verdict(phase: .callback, baseline: nil,
                                        focusGeneration: 7, focusedItem: ObjectIdentifier(cardA)),
            .noBaseline
        )
        XCTAssertEqual(
            HomeUpSwipeDecision.verdict(phase: .deadline, baseline: nil,
                                        focusGeneration: 7, focusedItem: nil),
            .noBaseline
        )
    }

    /// Nothing focused at either end is still "focus did not move". The catcher's own callback
    /// guards (`HomeView.handleUpSwipe`) decline in that state anyway — neither `focusedRowKey` nor
    /// `heroFocused` is set — but the decision itself should not invent a difference.
    func testNothingFocusedAtEitherEndIsStillNoMovement() {
        let touchDown = baseline(generation: 3, item: nil)

        XCTAssertEqual(
            HomeUpSwipeDecision.verdict(phase: .deadline, baseline: touchDown,
                                        focusGeneration: 3, focusedItem: nil),
            .fallBack
        )
    }
}
