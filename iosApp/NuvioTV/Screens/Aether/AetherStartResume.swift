import Foundation

/// The Aether start's resume (W5 r4, r6): planned once with `PlayerResumePosition.plan`, a percentage
/// owed until its seek can be issued (never while a return holds the transport) and done once that seek
/// finished. Every value arrives as an argument: the controller passes what a publisher delivered, so
/// nothing here can read a `@Published` property back inside its own willSet.
@MainActor
final class AetherStartResume {
    private(set) var state: PlayerStartResume = .unresolved
    private var seekGeneration: Int?
    private var probeDurationSec: Double?
    private var liveDurationSec: Double?

    /// The start position in seconds for the first load request, or nil.
    func plan(retryResumeSec: Double?, startFromBeginning: Bool,
              savedResumeSec: (Double) -> Double?, pendingPercent: () -> Double?) -> Double? {
        let plan = PlayerResumePosition.plan(retryResumeSec: retryResumeSec, startFromBeginning: startFromBeginning,
                                             durationSec: 0, savedResumeSec: savedResumeSec,
                                             pendingPercent: pendingPercent)
        state = PlayerResumePosition.state(after: plan)
        if case .seek(let sec) = plan { return sec }
        return nil
    }

    /// The first load returned. A start at a saved position in seconds is reached with it.
    func loadReturned(probeDurationSec: Double?, liveDurationSec: Double?) {
        self.probeDurationSec = probeDurationSec
        if let live = liveDurationSec { self.liveDurationSec = live }
        if case .seeking = state, seekGeneration == nil { state = .done }
    }

    /// The clock's published duration (the delivered value).
    func durationChanged(_ sec: Double) {
        liveDurationSec = sec
    }

    var isOwed: Bool {
        if case .awaitingDuration = state { return true }
        return false
    }

    /// Issues the owed percentage seek when it can be issued now. `issue` returns the seek generation,
    /// or nil when the seek was not sent (it stays owed).
    func apply(mediaReady: Bool, transportHeld: Bool, positionSec: Double, issue: (Double) -> Int?) {
        let duration = PlayerResumePosition.knownDuration(probeSec: probeDurationSec, liveSec: liveDurationSec)
        switch PlayerResumePosition.owedStep(state, mediaReady: mediaReady, transportHeld: transportHeld,
                                             positionSec: positionSec, durationSec: duration) {
        case .keep:
            if transportHeld, isOwed { print("[Return] start resume owed: the return holds the transport") }
        case .done:
            state = .done
        case .seek(let target):
            guard let generation = issue(target) else { return }
            state = .seeking(target)
            seekGeneration = generation
        }
    }

    /// A seek finished (landed, superseded or rejected): the start's own percentage seek ends the resume.
    func seekFinished(generation: Int) {
        guard seekGeneration == generation else { return }
        seekGeneration = nil
        state = .done
    }
}
