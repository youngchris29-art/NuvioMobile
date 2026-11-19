import XCTest
@testable import NuvioTV

/// GitHub #33: `SeekPreviewPlan.decide` over every gesture and capability, the card content rule
/// and the refresh rule.
final class SeekPreviewPlanTests: XCTestCase {
    typealias Plan = SeekPreviewPlan
    typealias Cap = SeekPreviewCapability

    private static let t = 300.0
    private static let watched = Cap(fillsWatched: true, fillsUnwatched: false)
    private static let unwatched = Cap(fillsWatched: false, fillsUnwatched: true)
    private static let both = Cap(fillsWatched: true, fillsUnwatched: true)
    private static let caps: [(String, Cap)] = [("none", .none), ("watched", watched),
                                                ("unwatched", unwatched), ("both", both)]
    private static let gestures: [(String, SeekPreviewGesture)] = [
        ("none", .none), ("pending", .pending), ("scan", .scan),
        ("landing", .landing(targetSec: t, generation: 7)), ("hold", .hold(targetSec: t)),
        ("scrub", .scrub(targetSec: t)),
    ]

    /// The spec's table, all three outputs, 6 gestures × 4 capabilities.
    func testDecideTruthTable() {
        let t = Self.t
        for (gName, g) in Self.gestures {
            for (cName, c) in Self.caps {
                let p = Plan.decide(g, c)
                let label = "\(gName) × \(cName)"
                XCTAssertEqual(p.placeholderAllowed, c.any, label)
                switch (gName, c.any) {
                case ("none", _), ("pending", _), ("scan", _):
                    XCTAssertNil(p.requestTargetSec, label)
                    XCTAssertNil(p.cardTargetSec, label)
                case ("landing", false), ("scrub", false):
                    XCTAssertNil(p.requestTargetSec, label)
                    XCTAssertEqual(p.cardTargetSec, t, label)
                case ("hold", false):
                    XCTAssertNil(p.requestTargetSec, label)
                    XCTAssertNil(p.cardTargetSec, label)
                case ("landing", true), ("hold", true), ("scrub", true):
                    XCTAssertEqual(p.requestTargetSec, t, label)
                    XCTAssertEqual(p.cardTargetSec, t, label)
                default:
                    XCTFail("unhandled \(label)")
                }
            }
        }
    }

    func testDecideCaseCount() {
        XCTAssertEqual(Self.gestures.count * Self.caps.count, 24)
    }

    func testNoCapabilityLandingAndScrubAreTimeOnly() {
        XCTAssertEqual(Plan.decide(.landing(targetSec: 50, generation: 1), .none).content(frameSec: nil), .timeOnly)
        XCTAssertEqual(Plan.decide(.scrub(targetSec: 50), .none).content(frameSec: nil), .timeOnly)
        XCTAssertEqual(Plan.decide(.hold(targetSec: 50), .none).content(frameSec: nil), .none)
    }

    // MARK: content(frameSec:)

    private let withPlaceholder = Plan(requestTargetSec: 1000, cardTargetSec: 1000, placeholderAllowed: true)
    private let timeOnly = Plan(requestTargetSec: nil, cardTargetSec: 1000, placeholderAllowed: false)

    func testContentReachBoundaries() {
        // Distances 0, 119.999, 120 are within reach; 120.001 is not.
        for (sec, inReach) in [(1000.0, true), (1119.999, true), (880.001, true), (1120.0, true),
                               (880.0, true), (1120.001, false), (879.999, false)] {
            XCTAssertEqual(withPlaceholder.content(frameSec: sec), inReach ? .frame : .placeholder, "\(sec)")
            XCTAssertEqual(timeOnly.content(frameSec: sec), inReach ? .frame : .timeOnly, "\(sec)")
        }
    }

    func testContentWithoutAFrame() {
        XCTAssertEqual(withPlaceholder.content(frameSec: nil), .placeholder)
        XCTAssertEqual(timeOnly.content(frameSec: nil), .timeOnly)
        XCTAssertEqual(withPlaceholder.content(frameSec: .nan), .placeholder)
        XCTAssertEqual(timeOnly.content(frameSec: .nan), .timeOnly)
        XCTAssertEqual(withPlaceholder.content(frameSec: .infinity), .placeholder)
    }

    func testContentWithNoCardTarget() {
        let p = Plan(requestTargetSec: nil, cardTargetSec: nil, placeholderAllowed: true)
        XCTAssertEqual(p.content(frameSec: nil), .none)
        XCTAssertEqual(p.content(frameSec: 0), .none)
        XCTAssertEqual(Plan.none.content(frameSec: 12), .none)
    }

    func testContentProbeCodes() {
        XCTAssertEqual([Plan.Content.frame, .placeholder, .timeOnly, .none].map(\.probeCode), ["f", "p", "t", "n"])
    }

    func testAcceptReachMatchesTheStoreNearestReach() {
        XCTAssertEqual(Plan.acceptReachSec, 120)
    }

    // MARK: wantsRefresh

    func testWantsRefresh() {
        let p = Plan(requestTargetSec: 600, cardTargetSec: 600, placeholderAllowed: true)
        XCTAssertTrue(p.wantsRefresh(atSec: 600, toleranceSec: 5))
        XCTAssertTrue(p.wantsRefresh(atSec: 595, toleranceSec: 5))
        XCTAssertTrue(p.wantsRefresh(atSec: 605, toleranceSec: 5))
        XCTAssertFalse(p.wantsRefresh(atSec: 605.01, toleranceSec: 5))
        XCTAssertFalse(p.wantsRefresh(atSec: 500, toleranceSec: 5))
        XCTAssertFalse(p.wantsRefresh(atSec: .nan, toleranceSec: 5))
    }

    func testNoRefreshWithoutARequestTarget() {
        XCTAssertFalse(timeOnly.wantsRefresh(atSec: 1000, toleranceSec: 10))
        XCTAssertFalse(Plan.none.wantsRefresh(atSec: 0, toleranceSec: 10))
    }

    // MARK: Render

    func testRenderNoneAndCardShown() {
        XCTAssertFalse(SeekPreviewRender.none.cardShown)
        var r = SeekPreviewRender.none
        r.content = .placeholder
        XCTAssertTrue(r.cardShown)
        r.content = .timeOnly
        XCTAssertFalse(r.cardShown)
        XCTAssertNotEqual(r, .none)
    }
}
