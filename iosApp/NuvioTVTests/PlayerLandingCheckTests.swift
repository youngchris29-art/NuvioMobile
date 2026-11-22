import XCTest
@testable import NuvioTV

/// spec-mpv-return §6.2: the landing verdict shared by the native restart machine and the mpv
/// fresh start, row by row, plus the two properties the table promises.
final class PlayerLandingCheckTests: XCTestCase {

    private typealias V = PlayerLandingCheck.Verdict

    private struct Row {
        let n: Int
        let target: Double
        let landed: Double?
        let atIssue: Double?
        let now: Double?
        let used: Bool
        let expected: V
    }

    private func row(_ n: Int, _ target: Double, _ landed: Double?, _ d: Double?, now: Double? = .infinity,
                     used: Bool = false, _ expected: V) -> Row {
        // `now: .infinity` is the marker for "same as at issue" (an infinite duration is never used here).
        Row(n: n, target: target, landed: landed, atIssue: d, now: now == .infinity ? d : now, used: used, expected: expected)
    }

    private var table: [Row] {
        [
            row(1, 1265.781, 1265.78, 7000, .confirmed),
            row(2, 1265.781, 1252.209, 7000, .correct),
            row(3, 1265.781, 1252.209, 7000, used: true, .offTarget),
            row(4, 0, 0, 7000, .confirmed),
            row(5, 0, 0.4, 7000, .confirmed),
            row(6, 6, 6.2, 7000, .confirmed),
            row(7, -1, 0, 7000, .invalidTarget),
            row(8, .nan, 5, 7000, .invalidTarget),
            row(9, 100, nil, 7000, .correct),
            row(10, 100, -0.5, 7000, .correct),
            row(11, 100, .nan, 7000, used: true, .offTarget),
            row(12, 7000, 6999.2, 7000, .confirmed),
            row(13, 7000, 6990, 7000, .correct),
            row(14, 9000, 6999.5, 7000, .confirmed),
            row(15, 0.9, 0.8, 1, .confirmed),
            row(16, 0.9, -0.5, 1, .correct),
            row(17, 0.9, 0, 1, .correct),
            row(18, 0.5, 0.45, 1, .confirmed),
            row(19, 0.5, 0, 1, .correct),
            row(20, 100, 100.1, nil, .confirmed),
            row(21, 100, 100.1, 0, .confirmed),
            row(22, 100, 100.0, 7000, now: 3600, .correct),
            row(23, 100, 100.0, 7000, now: 7040, .confirmed),
            row(24, 7000, 7000.7, 7000, .correct),
        ]
    }

    func testTheSpecTableRowByRow() {
        XCTAssertEqual(table.count, 24)
        for r in table {
            let v = PlayerLandingCheck.verdict(target: r.target, landed: r.landed, durationAtIssue: r.atIssue,
                                               durationNow: r.now, correctionUsed: r.used)
            XCTAssertEqual(v, r.expected, "row \(r.n)")
        }
    }

    /// Every miss row flips to `.offTarget` once the correction was used; confirmed and invalid stay.
    func testTheCorrectionFlagOnlyTurnsAMissIntoOffTarget() {
        for r in table {
            let v = PlayerLandingCheck.verdict(target: r.target, landed: r.landed, durationAtIssue: r.atIssue,
                                               durationNow: r.now, correctionUsed: true)
            switch r.expected {
            case .correct, .offTarget: XCTAssertEqual(v, .offTarget, "row \(r.n)")
            case .confirmed, .invalidTarget: XCTAssertEqual(v, r.expected, "row \(r.n)")
            }
        }
    }

    /// Never `.confirmed` for a landing below 0, or above `D + tol` with a valid `D`.
    func testPropertyNeverConfirmsAnImpossibleLanding() {
        let durations: [Double?] = [nil, 0, .nan, 0.2, 1, 4, 30, 7000]
        let targets: [Double] = [0, 0.05, 0.5, 0.9, 1, 3, 6, 100, 6999, 7000, 9000]
        var landings: [Double] = [-10, -0.5, -0.0001, 0, 0.1, 0.5, 0.9, 1, 1.2, 5, 99.6, 100, 6998, 7000.4, 7000.6, 7003, 9000]
        landings += stride(from: -1.0, through: 8.0, by: 0.25)
        for d in durations {
            for t in targets {
                for l in landings {
                    for used in [false, true] {
                        let v = PlayerLandingCheck.verdict(target: t, landed: l, durationAtIssue: d, durationNow: d,
                                                           correctionUsed: used)
                        guard v == .confirmed else { continue }
                        XCTAssertGreaterThanOrEqual(l, 0, "t=\(t) l=\(l) d=\(String(describing: d))")
                        if let valid = PlayerLandingCheck.validDuration(d) {
                            let tol = min(0.5, valid / 8)
                            XCTAssertLessThanOrEqual(l, valid + tol, "t=\(t) l=\(l) d=\(valid)")
                            // The end band never covers more than a quarter of the item.
                            if t > valid - tol { XCTAssertGreaterThanOrEqual(l, valid - min(2, valid / 4)) }
                        }
                    }
                }
            }
        }
    }

    func testAnInfiniteLandingOrTargetIsNeverConfirmed() {
        XCTAssertEqual(PlayerLandingCheck.verdict(target: .infinity, landed: 5, durationAtIssue: nil, durationNow: nil,
                                                  correctionUsed: false), .invalidTarget)
        XCTAssertEqual(PlayerLandingCheck.verdict(target: 5, landed: .infinity, durationAtIssue: nil, durationNow: nil,
                                                  correctionUsed: false), .correct)
    }
}
