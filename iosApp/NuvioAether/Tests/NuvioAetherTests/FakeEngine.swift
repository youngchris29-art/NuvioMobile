import Combine
import Foundation
import SwiftUI
@testable import NuvioAether

/// Scripted engine: records calls, publishes whatever a test sends, and lets a test decide how `load`,
/// `reloadAtCurrentPosition` and `seek` end.
@MainActor
final class FakeEngine: EngineDriving {
    let subject = PassthroughSubject<EngineEvent, Never>()
    var events: AnyPublisher<EngineEvent, Never> { subject.eraseToAnyPublisher() }

    // Recorded calls.
    var loads: [AetherLoadRequest] = []
    var stops: [(reset: Bool, final: Bool)] = []
    var reloads = 0
    var plays = 0
    var pauses = 0
    var toggles = 0
    var rates: [Float] = []
    var seeks: [(sec: Double, exact: Bool)] = []
    var selectedAudio: [Int] = []
    var selectedSubtitle: [Int] = []
    var clears = 0
    var delays: [Double] = []
    var shapings: [AetherAudioShaping] = []
    var headerUpdates: [[String: String]] = []

    // Scripts.
    /// Runs inside `load` before it returns or throws (publish events here to model the engine's order).
    var onLoad: ((FakeEngine) -> Void)?
    var loadResult: Result<AetherProbeSummary?, Error> = .success(nil)
    var reloadResult: Result<Void, Error> = .success(())
    /// Runs inside `seek` before it returns.
    var onSeek: ((FakeEngine, Double) -> Void)?

    var aspect: AetherAspect = .fit
    var canSeek = true
    var maxRate: Float = 2
    var supportsScrubStills = false
    var scrubStillsSourceGeneration = UUID()
    var audioDelaySec: Double = 0
    var audioShaping = AetherAudioShaping()
    var clockSample = AetherClockSample()
    var surface: AnyView { AnyView(EmptyView()) }

    func send(_ e: EngineEvent) { subject.send(e) }

    func load(_ request: AetherLoadRequest) async throws -> AetherProbeSummary? {
        loads.append(request)
        onLoad?(self)
        return try loadResult.get()
    }

    func stop(resetDisplayCriteria: Bool, finalTeardown: Bool) { stops.append((resetDisplayCriteria, finalTeardown)) }

    func reloadAtCurrentPosition() async throws {
        reloads += 1
        try reloadResult.get()
    }

    func play() { plays += 1 }
    func pause() { pauses += 1 }
    func togglePause() { toggles += 1 }
    func setRate(_ rate: Float) { rates.append(rate) }

    func seek(toSec: Double, exact: Bool) async {
        seeks.append((toSec, exact))
        onSeek?(self, toSec)
    }

    func selectAudio(id: Int) { selectedAudio.append(id) }
    func selectSubtitle(id: Int) { selectedSubtitle.append(id) }
    func clearSubtitle() { clears += 1 }

    func addExternalSubtitle(_ s: AetherExternalSubtitle) -> AetherTrack {
        AetherTrack(id: AetherTrack.externalTrackIDBase, name: s.name ?? "", codec: s.formatHint ?? "subrip",
                    language: s.language, isExternal: true)
    }

    func setAudioDelay(_ sec: Double) { delays.append(sec) }
    func setAudioShaping(_ s: AetherAudioShaping) { shapings.append(s) }

    func updateRequestHeaders(_ headers: [String: String]) -> Bool {
        headerUpdates.append(headers)
        return true
    }

    func scrubFrame(atSec: Double, refined: Bool, maxWidth: Int,
                    isCancelled: @escaping @Sendable () -> Bool) async -> AetherScrubFrame? { nil }
}

struct FakeError: Error {}

extension AetherFailure {
    static func sample(_ kind: AetherFailureKind, message: String = "m") -> AetherFailure {
        AetherFailure(kind: kind, message: message, atSec: 0, beforeFirstFrame: true)
    }
}
