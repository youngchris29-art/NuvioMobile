import XCTest
@testable import NuvioTV

/// Episode shuffle sheet: which lower half the sheet shows. Every phase must map to exactly one
/// state, because each state carries its own focusable way out (the empty-state eject class).
final class EpisodeShuffleSheetPhaseTests: XCTestCase {
    private typealias Phase = EpisodeShuffleSheet.Phase

    func testOffWinsOverEverything() {
        XCTAssertEqual(Phase.resolve(enabled: false, hasPick: true, isLoading: true, caughtUp: true), .off)
        XCTAssertEqual(Phase.resolve(enabled: false, hasPick: false, isLoading: false, caughtUp: false), .off)
    }

    func testPickIsReadyEvenWhileMetadataStillLoading() {
        XCTAssertEqual(Phase.resolve(enabled: true, hasPick: true, isLoading: true, caughtUp: false), .ready)
    }

    func testNoPickWhileLoadingIsLoading() {
        XCTAssertEqual(Phase.resolve(enabled: true, hasPick: false, isLoading: true, caughtUp: true), .loading)
    }

    func testNoPickAfterLoadIsCaughtUpOrEmpty() {
        XCTAssertEqual(Phase.resolve(enabled: true, hasPick: false, isLoading: false, caughtUp: true), .caughtUp)
        XCTAssertEqual(Phase.resolve(enabled: true, hasPick: false, isLoading: false, caughtUp: false), .empty)
    }
}
