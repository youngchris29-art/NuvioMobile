import XCTest
@testable import NuvioTV

/// Aether Phase 1, W3-C (W1-B 4.4): the once-only bookkeeping of the Aether to mpv handoff.
@MainActor
final class PlaybackHandoffLedgerTests: XCTestCase {
    typealias Effect = PlaybackHandoffLedger.Effect

    func testAFallbackAfterPlaybackFlushesOnceThenStopsThenHandsOff() {
        var ledger = PlaybackHandoffLedger()
        let effects = ledger.handOff(positionSec: 312.4, secondsPlayed: 95, durationSec: 7_200, everShowedFrame: true)
        XCTAssertEqual(effects, [
            .flushResume(positionSec: 312.4),
            .stopTrakt(positionSec: 312.4),
            .stopTrackers(positionSec: 312.4),
            .handOff(PlaybackHandoff(positionSec: 312.4, secondsPlayed: 95, startedPlaying: true, kind: .local)),
        ])
    }

    func testTeardownAndDeinitAfterTheHandoffEmitNothing() {
        var ledger = PlaybackHandoffLedger()
        _ = ledger.handOff(positionSec: 100, secondsPlayed: 50, durationSec: 3_000, everShowedFrame: true)
        // viewDidDisappear, then deinit: one flush per handoff, never a second.
        XCTAssertEqual(ledger.finishTracking(positionSec: 100, durationSec: 3_000, everShowedFrame: true), [])
        XCTAssertEqual(ledger.finishTracking(positionSec: 140, durationSec: 3_000, everShowedFrame: true), [])
        XCTAssertTrue(ledger.trackingFinished)
    }

    func testASecondFailureVerdictEmitsNothing() {
        var ledger = PlaybackHandoffLedger()
        XCTAssertFalse(ledger.handOff(positionSec: 100, secondsPlayed: 50, durationSec: 3_000, everShowedFrame: true).isEmpty)
        XCTAssertEqual(ledger.handOff(positionSec: 120, secondsPlayed: 60, durationSec: 3_000, everShowedFrame: true), [])
        XCTAssertTrue(ledger.handedOff)
    }

    func testNothingIsFlushedBeforeAFrameOrWithAnUnknownDuration() {
        var early = PlaybackHandoffLedger()
        let before = early.handOff(positionSec: 0, secondsPlayed: 0, durationSec: 0, everShowedFrame: false)
        XCTAssertEqual(before, [
            .stopTrakt(positionSec: 0),
            .stopTrackers(positionSec: 0),
            .handOff(PlaybackHandoff(positionSec: 0, secondsPlayed: 0, startedPlaying: false, kind: .local)),
        ])
        var noDuration = PlaybackHandoffLedger()
        XCTAssertFalse(noDuration.finishTracking(positionSec: 30, durationSec: 0, everShowedFrame: true)
            .contains(.flushResume(positionSec: 30)))
        var noFrame = PlaybackHandoffLedger()
        XCTAssertFalse(noFrame.finishTracking(positionSec: 30, durationSec: 600, everShowedFrame: false)
            .contains(.flushResume(positionSec: 30)))
    }

    func testALiveStreamWritesNoResume() {
        var ledger = PlaybackHandoffLedger()
        let effects = ledger.finishTracking(positionSec: 30, durationSec: 600, everShowedFrame: true, isLive: true)
        XCTAssertEqual(effects, [.stopTrakt(positionSec: 30), .stopTrackers(positionSec: 30)])
    }

    func testTheTrackerStopsPrecedeTheHandoffSoSessionsNeverOverlap() {
        var ledger = PlaybackHandoffLedger()
        let effects = ledger.handOff(positionSec: 61, secondsPlayed: 20, durationSec: 900, everShowedFrame: true)
        let handOffIndex = effects.firstIndex { if case .handOff = $0 { return true } else { return false } }
        let stopIndexes = effects.indices.filter {
            switch effects[$0] { case .stopTrakt, .stopTrackers: return true; default: return false }
        }
        XCTAssertEqual(stopIndexes.count, 2)
        XCTAssertTrue(stopIndexes.allSatisfy { $0 < (handOffIndex ?? -1) })
        XCTAssertEqual(effects.filter { if case .flushResume = $0 { return true } else { return false } }.count, 1)
    }

    func testThePositionIsSanitisedAndTheClockFieldsPassThrough() {
        var ledger = PlaybackHandoffLedger()
        let effects = ledger.handOff(positionSec: .nan, secondsPlayed: 12.5, durationSec: 600, everShowedFrame: true)
        XCTAssertEqual(effects.last, .handOff(PlaybackHandoff(positionSec: 0, secondsPlayed: 12.5, startedPlaying: true, kind: .local)))
    }
}
