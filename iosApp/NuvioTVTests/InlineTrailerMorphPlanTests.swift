import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (R2, BUG-133): the staged inline-trailer morph's two collapse decisions and
/// the tile-art candidate order. Timings: `revealDuration` 0.12 s, `morphDuration` 0.35 s,
/// `abortWindowIntoWide` 0.2 s.
final class InlineTrailerMorphPlanTests: XCTestCase {

    func testAbortDuringReveal() {
        XCTAssertEqual(InlineTrailerMorphPlan.collapseStyle(stage: .reveal, stageAge: 0.05), .abort)
        // `.reveal` aborts whatever its age: the width has not moved yet.
        XCTAssertEqual(InlineTrailerMorphPlan.collapseStyle(stage: .reveal, stageAge: 5), .abort)
    }

    func testAbortEarlyInWide() {
        XCTAssertEqual(InlineTrailerMorphPlan.collapseStyle(stage: .wide, stageAge: 0.1), .abort)
        XCTAssertEqual(InlineTrailerMorphPlan.collapseStyle(stage: .wide, stageAge: 0.25), .animated)
        // The DEBUG `-debug.trailerAbortWindowMs` override path (test86).
        XCTAssertEqual(InlineTrailerMorphPlan.collapseStyle(stage: .wide, stageAge: 1.0, abortWindow: 2.0), .abort)
    }

    func testNoneIsNoop() {
        let none = InlineTrailerCardModel.MorphStage.none
        XCTAssertEqual(InlineTrailerMorphPlan.collapseStyle(stage: none, stageAge: 0),
                       InlineTrailerMorphPlan.CollapseStyle.none)
        XCTAssertEqual(InlineTrailerMorphPlan.collapseStyle(stage: none, stageAge: .greatestFiniteMagnitude),
                       InlineTrailerMorphPlan.CollapseStyle.none)
        XCTAssertNil(InlineTrailerMorphPlan.deferredCollapseDelay(stage: none, stageAge: 0))
    }

    func testDeferredCollapseWaitsForExpansionEnd() throws {
        XCTAssertEqual(try XCTUnwrap(InlineTrailerMorphPlan.deferredCollapseDelay(stage: .wide, stageAge: 0.2)),
                       0.15, accuracy: 1e-9)
        XCTAssertNil(InlineTrailerMorphPlan.deferredCollapseDelay(stage: .wide, stageAge: 0.5))
        // The rest of the dissolve (0.07) plus the whole width stage (0.35).
        XCTAssertEqual(try XCTUnwrap(InlineTrailerMorphPlan.deferredCollapseDelay(stage: .reveal, stageAge: 0.05)),
                       0.42, accuracy: 1e-9)
        // A late stage 2 (main actor busy) still waits out the width stage.
        XCTAssertEqual(try XCTUnwrap(InlineTrailerMorphPlan.deferredCollapseDelay(stage: .reveal, stageAge: 0.3)),
                       0.35, accuracy: 1e-9)
    }

    func testArtCandidatesOrder() {
        XCTAssertEqual(InlineTileArtLoader.candidates(primary: "https://a/banner.jpg", fallback: "https://a/poster.jpg"),
                       ["https://a/banner.jpg", "https://a/poster.jpg"])
        // `landscapeArtworkURL` already falls back to the poster when there is no banner.
        XCTAssertEqual(InlineTileArtLoader.candidates(primary: "https://a/poster.jpg", fallback: "https://a/poster.jpg"),
                       ["https://a/poster.jpg"])
        XCTAssertEqual(InlineTileArtLoader.candidates(primary: nil, fallback: "https://a/poster.jpg"),
                       ["https://a/poster.jpg"])
        XCTAssertEqual(InlineTileArtLoader.candidates(primary: "", fallback: "https://a/poster.jpg"),
                       ["https://a/poster.jpg"])
        XCTAssertEqual(InlineTileArtLoader.candidates(primary: "   ", fallback: nil), [])
        XCTAssertEqual(InlineTileArtLoader.candidates(primary: nil, fallback: nil), [])
    }
}
