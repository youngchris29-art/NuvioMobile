import Combine
import XCTest
@testable import NuvioTV

/// W5 r6: which duration a start's percentage uses, and the Aether start-resume owner fed the way the
/// controller feeds it: the clock's `@Published` duration delivered in willSet order.
@MainActor
final class AetherStartResumeTests: XCTestCase {

    // MARK: knownDuration (probe nil/0/finite x live nil/0/finite, plus non-finite)

    func testKnownDurationOverProbeAndLive() {
        let values: [Double?] = [nil, 0, .nan, .infinity, 1800]
        for probe in values {
            for live in values {
                let got = PlayerResumePosition.knownDuration(probeSec: probe, liveSec: live)
                let probeOK = probe.map { $0.isFinite && $0 > 0 } ?? false
                let liveOK = live.map { $0.isFinite && $0 > 0 } ?? false
                let want: Double = probeOK ? probe! : (liveOK ? live! : 0)
                XCTAssertEqual(got, want, "probe=\(String(describing: probe)) live=\(String(describing: live))")
            }
        }
        XCTAssertEqual(PlayerResumePosition.knownDuration(probeSec: 1200, liveSec: 1800), 1200, "a valid probe wins")
        XCTAssertEqual(PlayerResumePosition.knownDuration(probeSec: 0, liveSec: 1800), 1800, "a zero probe never hides the live one")
    }

    // MARK: The owner, wired like the controller

    /// The clock's duration as the façade publishes it: subscribers run in willSet.
    final class FakeClock: ObservableObject {
        @Published var durationSec: Double = 0
    }

    private var bag: Set<AnyCancellable> = []

    func testADurationKnownAfterTheLoadAppliesThePercentWithTheDeliveredValue() {
        let owner = AetherStartResume()
        let clock = FakeClock()
        var seeks: [Double] = []
        var readBack: [Double] = []
        var generation = 0
        let issue: (Double) -> Int? = { target in
            seeks.append(target)
            generation += 1
            return generation
        }
        // The controller's sink: the delivered value goes in; the property itself still reads the old one.
        clock.$durationSec.dropFirst().sink { sec in
            readBack.append(clock.durationSec)
            owner.durationChanged(sec)
            if owner.isOwed { owner.apply(mediaReady: true, transportHeld: false, positionSec: 0.3, issue: issue) }
        }.store(in: &bag)

        XCTAssertNil(owner.plan(retryResumeSec: nil, startFromBeginning: false,
                                savedResumeSec: { _ in nil }, pendingPercent: { 40 }))
        XCTAssertEqual(owner.state, .awaitingDuration(percent: 40))
        // The load returns with a zero probe and no live duration yet: nothing to apply.
        owner.loadReturned(probeDurationSec: 0, liveDurationSec: 0)
        owner.apply(mediaReady: true, transportHeld: false, positionSec: 0.2, issue: issue)
        XCTAssertEqual(seeks, [])
        XCTAssertTrue(owner.isOwed)
        // The duration becomes known after the load.
        clock.durationSec = 1800
        XCTAssertEqual(readBack, [0], "inside the sink the published property still reads the old value")
        XCTAssertEqual(seeks, [720], "the delivered duration resolves the percentage")
        XCTAssertEqual(owner.state, .seeking(720))
        owner.seekFinished(generation: 1)
        XCTAssertEqual(owner.state, .done)
        clock.durationSec = 1801
        XCTAssertEqual(seeks, [720], "applied once")
    }

    func testWhileTheReturnHoldsTheTransportThePercentStaysOwedThenApplies() {
        let owner = AetherStartResume()
        _ = owner.plan(retryResumeSec: nil, startFromBeginning: false, savedResumeSec: { _ in nil }, pendingPercent: { 40 })
        owner.loadReturned(probeDurationSec: nil, liveDurationSec: nil)
        owner.durationChanged(1800)
        var seeks: [Double] = []
        owner.apply(mediaReady: true, transportHeld: true, positionSec: 0) { seeks.append($0); return 1 }
        XCTAssertEqual(seeks, [])
        owner.apply(mediaReady: true, transportHeld: false, positionSec: 0) { _ in nil }
        XCTAssertTrue(owner.isOwed, "a seek that was not sent stays owed")
        owner.apply(mediaReady: true, transportHeld: false, positionSec: 0) { seeks.append($0); return 7 }
        XCTAssertEqual(seeks, [720])
        owner.seekFinished(generation: 3)
        XCTAssertEqual(owner.state, .seeking(720), "another seek's outcome does not end it")
        owner.seekFinished(generation: 7)
        XCTAssertEqual(owner.state, .done)
    }

    func testASavedPositionInSecondsIsReachedWithTheLoad() {
        let owner = AetherStartResume()
        XCTAssertEqual(owner.plan(retryResumeSec: nil, startFromBeginning: false,
                                  savedResumeSec: { _ in 250 }, pendingPercent: { nil }), 250)
        XCTAssertEqual(owner.state, .seeking(250))
        owner.loadReturned(probeDurationSec: 1800, liveDurationSec: 1800)
        XCTAssertEqual(owner.state, .done)
    }
}
