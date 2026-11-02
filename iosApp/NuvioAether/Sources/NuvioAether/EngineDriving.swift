import Combine
import Foundation
import SwiftUI

/// What the session needs from an engine, in fork types only. `LiveEngine` adapts AetherEngine to it; the
/// package tests drive the session with a scripted fake.
@MainActor
protocol EngineDriving: AnyObject {
    /// Every engine fact as it changes, delivered on the main actor in publication order.
    var events: AnyPublisher<EngineEvent, Never> { get }

    /// Throws `AetherFailure` (built from `errorInfo` when the engine published one, else `.thrown`) or
    /// `CancellationError` untouched.
    func load(_ request: AetherLoadRequest) async throws -> AetherProbeSummary?
    func stop(resetDisplayCriteria: Bool, finalTeardown: Bool)
    /// Throws like `load`.
    func reloadAtCurrentPosition() async throws

    func play()
    func pause()
    func togglePause()
    func setRate(_ rate: Float)
    func seek(toSec: Double, exact: Bool) async

    func selectAudio(id: Int)
    func selectSubtitle(id: Int)
    func clearSubtitle()
    func addExternalSubtitle(_ subtitle: AetherExternalSubtitle) -> AetherTrack

    func setAudioDelay(_ sec: Double)
    func setAudioShaping(_ shaping: AetherAudioShaping)
    func updateRequestHeaders(_ headers: [String: String]) -> Bool

    func scrubFrame(atSec: Double, refined: Bool, maxWidth: Int,
                    isCancelled: @escaping @Sendable () -> Bool) async -> AetherScrubFrame?

    var surface: AnyView { get }
    var aspect: AetherAspect { get set }
    var canSeek: Bool { get }
    var maxRate: Float { get }
    var supportsScrubStills: Bool { get }
    var scrubStillsSourceGeneration: UUID { get }
    var audioDelaySec: Double { get }
    var audioShaping: AetherAudioShaping { get }
    /// The current clock values (for failure timestamps between ticks).
    var clockSample: AetherClockSample { get }
}

/// One engine fact. Failures are separate from phases: the session's ledger owns the `.failed` phase.
enum EngineEvent: Sendable {
    /// `$state`: transport intent.
    case state(isPaused: Bool)
    /// `$playbackPhase`.
    case phase(AetherEnginePhase)
    /// `$errorInfo` turned non-nil.
    case failure(AetherFailure)
    /// `$hasFirstFrameReadyForDisplay`.
    case firstFrame(Bool)
    case clock(AetherClockSample)
    case cues([AetherCue])
    case chapters([AetherChapter])
    /// Coalesced telemetry, at most 2 Hz.
    case diagnostics(AetherDiagnostics)
    /// `$audioDelivery`, unthrottled (drives `onAudioDropped`).
    case audioDelivery(AetherAudioDelivery)
    case tracks(audio: [AetherTrack], subtitle: [AetherTrack], activeAudio: Int?, activeSubtitle: Int?)
    case seek(AetherSeekEventSample)
    case escalation(AetherEscalation)
    /// `sourceAuthorizationRefused` (401 or 403).
    case authorizationRefused(Int)
}
