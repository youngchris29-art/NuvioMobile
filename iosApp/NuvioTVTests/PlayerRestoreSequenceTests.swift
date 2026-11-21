import XCTest
@testable import NuvioTV

/// Return from background, 4.8: the one ordered restore operation (pure orchestration, injected closures).
@MainActor
final class PlayerRestoreSequenceTests: XCTestCase {

    private final class Recorder {
        var calls: [String] = []
        var reports: [PlayerReturnEvent] = []
    }

    /// Returns only when cancelled (the sequence cancels its work after the race), so nothing leaks.
    private static let hangsUntilCancelled: () async -> Void = {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
    }
    private static let neverFires: (Double) async throws -> Void = { _ in
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
    private static let firesAtOnce: (Double) async throws -> Void = { _ in }

    private func run(_ rec: Recorder, token: Int = 7,
                     sleep: @escaping (Double) async throws -> Void = PlayerRestoreSequenceTests.neverFires,
                     preconditions: (() async -> Void)? = nil,
                     gate: PlayerRestoreGate) async {
        await PlayerRestoreSequence.run(
            token: token,
            sleep: sleep,
            preconditions: preconditions ?? { rec.calls.append("preconditions") },
            stillCurrent: { rec.calls.append("stillCurrent"); return gate },
            armWatchdog: { rec.calls.append("armWatchdog") },
            report: { rec.calls.append("report"); rec.reports.append($0) },
            invoke: { rec.calls.append("invoke") })
    }

    func testProceedRunsPreconditionsRecheckArmReportInvokeInThatOrder() async {
        let rec = Recorder()
        await run(rec, gate: .proceed)
        XCTAssertEqual(rec.calls, ["preconditions", "stillCurrent", "armWatchdog", "report", "invoke"])
        XCTAssertEqual(rec.reports, [.sequenceArmed(token: 7)])
    }

    func testDroppedArmsNothingAndInvokesNothing() async {
        let rec = Recorder()
        await run(rec, gate: .dropped)
        XCTAssertEqual(rec.calls, ["preconditions", "stillCurrent", "report"])
        XCTAssertEqual(rec.reports, [.sequenceDropped(token: 7, .dropped)])
    }

    func testNotNeededArmsNothingAndInvokesNothing() async {
        let rec = Recorder()
        await run(rec, gate: .notNeeded)
        XCTAssertEqual(rec.calls, ["preconditions", "stillCurrent", "report"])
        XCTAssertEqual(rec.reports, [.sequenceDropped(token: 7, .notNeeded)])
    }

    func testARecheckThatAnswersPreconditionTimedOutIsADrop() async {
        let rec = Recorder()
        await run(rec, gate: .preconditionTimedOut)
        XCTAssertEqual(rec.reports, [.sequenceDropped(token: 7, .dropped)])
        XCTAssertFalse(rec.calls.contains("armWatchdog"))
        XCTAssertFalse(rec.calls.contains("invoke"))
    }

    func testAPreconditionThatNeverReturnsNeverArmsAndEndsInPreconditionTimedOut() async {
        let rec = Recorder()
        await run(rec, sleep: Self.firesAtOnce, preconditions: Self.hangsUntilCancelled, gate: .proceed)
        XCTAssertEqual(rec.reports, [.sequenceDropped(token: 7, .preconditionTimedOut)])
        XCTAssertEqual(rec.calls, ["report"], "no re-check, no watchdog, no engine call")
    }

    func testTheBoundIsPassedTheLimit() async {
        let rec = Recorder()
        var seen: Double?
        await PlayerRestoreSequence.run(
            token: 1,
            preconditionLimitSec: 5,
            sleep: { seen = $0 },
            preconditions: Self.hangsUntilCancelled,
            stillCurrent: { .proceed },
            armWatchdog: { rec.calls.append("arm") },
            report: { rec.reports.append($0) },
            invoke: { rec.calls.append("invoke") })
        XCTAssertEqual(seen, 5)
        XCTAssertEqual(PlayerRestoreSequence.preconditionLimitSec, 5)
        XCTAssertEqual(rec.reports, [.sequenceDropped(token: 1, .preconditionTimedOut)])
    }

    func testCancellingTheSequenceDuringTheWaitReportsOneDropAndCancelsTheBound() async {
        let rec = Recorder()
        let task = Task { @MainActor in
            await self.run(rec, preconditions: Self.hangsUntilCancelled, gate: .proceed)
        }
        // Let the sequence reach its wait, then cancel it as a background trip does.
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await task.value
        XCTAssertEqual(rec.reports, [.sequenceDropped(token: 7, .dropped)])
        XCTAssertEqual(rec.calls, ["report"])
    }

    func testEveryPathReportsExactlyOnce() async {
        for gate in [PlayerRestoreGate.proceed, .notNeeded, .dropped, .preconditionTimedOut] {
            let rec = Recorder()
            await run(rec, gate: gate)
            XCTAssertEqual(rec.reports.count, 1, "\(gate)")
        }
    }
}
