import Foundation

// Return from background on mpv (spec-mpv-return §3.3, §3.5, §3.6, §3.7): the small pure decisions
// the controller wiring runs through. No UIKit, no libmpv.

// MARK: - Command gate (§3.7, M7)

/// Queued work on a parked or stale controller: checked on `eventQueue` at execution (unpause,
/// load, seek) and on main (progress and tracker writes).
nonisolated enum MPVCommandGate {
    enum Command: String, Sendable, Equatable, CaseIterable { case unpause, load, seek, progressWrite, trackerWrite }

    /// A parked controller executes none of them; work issued under an older park generation is stale.
    static func allows(_ command: Command, parked: Bool, issuedGeneration: Int, currentGeneration: Int) -> Bool {
        !parked && issuedGeneration == currentGeneration
    }
}

/// The lock-guarded park state the controller's queue reads (`parked`, the park generation, the
/// snapshot's intent). Main writes, `eventQueue` reads.
final class MPVParkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _parked = false
    private var _generation = 0

    var parked: Bool { lock.lock(); defer { lock.unlock() }; return _parked }
    var generation: Int { lock.lock(); defer { lock.unlock() }; return _generation }

    /// Park: bumps the generation (every earlier queued block is stale) and returns the new one.
    @discardableResult
    func park() -> Int {
        lock.lock(); defer { lock.unlock() }
        _parked = true
        _generation &+= 1
        return _generation
    }

    /// A return-started controller continues the generation its payload was accepted under.
    func continueGeneration(from generation: Int) {
        lock.lock(); _generation = max(_generation, generation); lock.unlock()
    }

    /// A return that keeps this controller (`.nothing`): parked no more, the generation stays.
    func unpark() { lock.lock(); _parked = false; lock.unlock() }

    /// The gate's answer for work issued at `issuedGeneration`, read under one lock.
    func allows(_ command: MPVCommandGate.Command, issuedGeneration: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return MPVCommandGate.allows(command, parked: _parked, issuedGeneration: issuedGeneration,
                                     currentGeneration: _generation)
    }
}

// MARK: - Teardown latch (§3.6, M8; r3 findings 1-3)

nonisolated struct MPVTeardownStop: Sendable, Equatable {
    enum Disposition: Sendable, Equatable {
        case normal
        /// Replaced by a fresh controller: the writes use the held position.
        case replaced(positionSec: Double)
        /// The owner changed: nothing is written.
        case discard

        var logToken: String {
            switch self {
            case .normal: "normal"
            case .replaced(let p): "replaced(\(String(format: "%.1f", p)))"
            case .discard: "discard"
            }
        }
    }

    enum Call: Sendable, Equatable { case viewDidDisappear, deinitialize }

    enum Action: Sendable, Equatable {
        /// Flush progress and stop the trackers at exactly this position (`deinit` runs the stop half).
        case flushAndStop(atSec: Double)
        case none
    }

    private(set) var disposition: Disposition = .normal
    /// The current tracking session already flushed and stopped.
    private(set) var done = false

    /// `prepareForReplacement`: the disposition for the removal that follows. Ignored once
    /// discarded (a discard is final).
    mutating func prepare(_ disposition: Disposition) {
        if self.disposition == .discard { return }
        self.disposition = disposition
    }

    /// Replay after the post-play cover: a new tracking session on this controller. Only `.normal`.
    mutating func beginSession() {
        guard disposition == .normal else { return }
        done = false
    }

    /// `ownerValid` = the creation owner equals the current identity, read immediately before the
    /// writes. In `.replaced`, false turns the latch into `.discard`.
    mutating func next(_ call: Call, livePositionSec: Double, ownerValid: Bool) -> Action {
        switch disposition {
        case .discard:
            return .none
        case .replaced(let p):
            guard ownerValid else {
                disposition = .discard
                return .none
            }
            guard !done else { return .none }
            done = true
            return .flushAndStop(atSec: p)
        case .normal:
            guard !done else { return .none }
            done = true
            return .flushAndStop(atSec: livePositionSec)
        }
    }
}

// MARK: - Pending add-on subtitle pick (§3.3, M13; finding r2-7)

nonisolated struct MPVPendingSubtitlePick: Sendable, Equatable {
    enum Event: Sendable, Equatable {
        /// A walk saw an external track whose source maps to `originalURL`.
        case trackAppeared(originalURL: String, trackID: Int)
        case sideLoadFailed(originalURL: String)
        /// The fresh controller's own side-load list is known: the URLs it will load.
        case searchEnded(urls: Set<String>)
        case userPicked
        /// 20 s after `FILE_LOADED`.
        case deadline
    }

    enum FallbackReason: String, Sendable, Equatable { case missing, failed, deadline }

    enum Outcome: Sendable, Equatable {
        case select(trackID: Int)
        case fallbackAuto(FallbackReason)
        /// The viewer chose meanwhile: the pick is dropped, their choice stands.
        case dropped

        var logToken: String {
            switch self {
            case .select(let id): "select(\(id))"
            case .fallbackAuto(let r): "fallbackAuto reason=\(r.rawValue)"
            case .dropped: "dropped user"
            }
        }
    }

    static let deadlineSec: TimeInterval = 20

    let originalURL: String
    private(set) var outcome: Outcome?

    init(originalURL: String) { self.originalURL = originalURL }

    /// While pending, the automatic subtitle choice keeps waiting.
    var isPending: Bool { outcome == nil }

    /// Returns the outcome exactly once, on the event that resolves it; nil otherwise.
    mutating func handle(_ event: Event) -> Outcome? {
        guard outcome == nil else { return nil }
        let resolved: Outcome?
        switch event {
        case let .trackAppeared(url, id): resolved = url == originalURL ? .select(trackID: id) : nil
        case let .sideLoadFailed(url): resolved = url == originalURL ? .fallbackAuto(.failed) : nil
        case let .searchEnded(urls): resolved = urls.contains(originalURL) ? nil : .fallbackAuto(.missing)
        case .userPicked: resolved = .dropped
        case .deadline: resolved = .fallbackAuto(.deadline)
        }
        outcome = resolved
        return resolved
    }
}

// MARK: - Landing completion (§3.5, M3/M15; finding r3-4)

/// The fresh controller's `.position` return: the resume seek's landing, one corrective exact seek,
/// then exactly one completion. Pure; the controller feeds landings by seek generation.
nonisolated struct MPVReturnLanding: Sendable, Equatable {
    enum Completion: Sendable, Equatable {
        case settled(landedSec: Double)
        case offTarget(landedSec: Double?)
        /// A viewer seek superseded the return seek (code review W7 r1-1): the viewer's seek
        /// completes the start; nothing is checked against the held target any more.
        case cancelled(bySeekGeneration: Int)
    }

    enum Step: Sendable, Equatable {
        /// Nothing to do (stale generation, or already complete).
        case none
        /// Issue one `absolute+exact` seek to the target; report its generation with `correctionIssued`.
        case correct(toSec: Double)
        case complete(Completion)
    }

    let targetSec: Double
    private(set) var awaitingGeneration: Int?
    private(set) var correctionUsed = false
    private(set) var completion: Completion?
    private var firstLanding: Double?

    init(targetSec: Double) { self.targetSec = targetSec }

    var isPending: Bool { completion == nil }

    /// The resume seek (or the correction) went out under `generation`.
    mutating func seekIssued(generation: Int) {
        guard completion == nil else { return }
        awaitingGeneration = generation
    }

    /// The `PLAYBACK_RESTART` that completed seek `generation`, with mpv's `time-pos` (NaN = unread).
    mutating func landed(generation: Int, atSec landed: Double?, durationAtIssue: Double?, durationNow: Double?) -> Step {
        guard completion == nil, generation == awaitingGeneration else { return .none }
        awaitingGeneration = nil
        let usable = landed.flatMap { $0.isFinite ? $0 : nil }
        if firstLanding == nil { firstLanding = usable }
        switch PlayerLandingCheck.verdict(target: targetSec, landed: usable, durationAtIssue: durationAtIssue,
                                          durationNow: durationNow, correctionUsed: correctionUsed) {
        case .confirmed:
            return finish(.settled(landedSec: usable ?? targetSec))
        case .correct:
            correctionUsed = true
            return .correct(toSec: targetSec)
        case .offTarget, .invalidTarget:
            return finish(.offTarget(landedSec: usable ?? firstLanding))
        }
    }

    /// A viewer seek went out while this landing waits: it is over, the viewer's seek stands.
    mutating func cancel(bySeekGeneration generation: Int) -> Step {
        guard completion == nil else { return .none }
        awaitingGeneration = nil
        return finish(.cancelled(bySeekGeneration: generation))
    }

    /// mpv rejected the seek in flight: with the correction used (or none possible) it is the second miss.
    mutating func seekRejected(generation: Int) -> Step {
        guard completion == nil, generation == awaitingGeneration else { return .none }
        awaitingGeneration = nil
        return finish(.offTarget(landedSec: firstLanding))
    }

    private mutating func finish(_ c: Completion) -> Step {
        completion = c
        return .complete(c)
    }
}

// MARK: - Every app seek around a return (code review W7 r1: one decision)

/// The outcome of every mpv seek the app issues, as one pure decision (code review W7 r1, findings
/// 1-3): which seek it is (the start's resume, the return's correction, or the viewer's), its
/// generation, and how it ended (landed, rejected; a superseded seek never reports and is resolved
/// by the issue that superseded it). It owns the newest targeted seek in flight (the park's held
/// target) and the return landing, so neither can outlive its seek:
/// - a viewer seek during the landing cancels it (the viewer's seek completes the start);
/// - a rejected start resume tells the start-up reducer the resume is over (no restart will come),
///   and a return landing waiting on it completes `offTarget`;
/// - a rejected seek clears the in-flight target when it is the newest one;
/// - a result with a stale generation changes nothing.
nonisolated struct MPVReturnSeeks: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case resume, correction, viewer }
    enum Result: Sendable, Equatable {
        case landed(atSec: Double?)
        case rejected
    }

    struct Seek: Sendable, Equatable {
        let generation: Int
        let targetSec: Double
    }

    struct Outcome: Sendable, Equatable {
        /// Issue the one corrective exact seek to this target (kind `.correction`).
        var correctToSec: Double?
        /// The return landing ended (settled, offTarget or cancelled).
        var completion: MPVReturnLanding.Completion?
        /// The seek the start waits on will never restart playback (the newest seek was rejected while
        /// the start is pending, r1-2 / r2-3): the start-up reducer completes now.
        var startupResumeRejected = false
    }

    /// The newest app seek with a target that has not ended (nil after it landed or was rejected,
    /// or when the newest seek had no target).
    private(set) var inFlight: Seek?
    private(set) var landing: MPVReturnLanding?
    private(set) var landingDurationAtIssue: Double?
    /// The generation of the start's resume seek (return or not), and the newest issued generation.
    private(set) var resumeGeneration: Int?
    private(set) var latestGeneration = 0
    /// The start waits on a seek of ours (from the resume's issue until the newest seek after it ends).
    /// Invariant (r2-3): whenever the newest seek ends, landed or rejected, this is false.
    private(set) var startupPending = false

    /// The start-up reducer reached `.started` on its own (its restart or the position backstop).
    mutating func startupCompleted() { startupPending = false }

    /// The return landing still waits: the loading screen stays up.
    var landingPending: Bool { landing?.isPending ?? false }
    var hasLanding: Bool { landing != nil }

    /// The payload's `.position` start: its landing is checked (before the resume seek is issued).
    mutating func beginReturnLanding(targetSec: Double, durationAtIssue: Double?) {
        landing = MPVReturnLanding(targetSec: targetSec)
        landingDurationAtIssue = durationAtIssue
    }

    mutating func issued(_ kind: Kind, generation: Int, targetSec: Double?) -> Outcome {
        var out = Outcome()
        latestGeneration = max(latestGeneration, generation)
        inFlight = targetSec.flatMap { $0.isFinite ? Seek(generation: generation, targetSec: $0) : nil }
        switch kind {
        case .resume:
            resumeGeneration = generation
            startupPending = true
            landing?.seekIssued(generation: generation)
        case .correction:
            landing?.seekIssued(generation: generation)
        case .viewer:
            if var l = landing, l.isPending, case .complete(let c) = l.cancel(bySeekGeneration: generation) {
                landing = l
                out.completion = c
            }
        }
        return out
    }

    mutating func finished(generation: Int, result: Result, durationNow: Double?) -> Outcome {
        var out = Outcome()
        if inFlight?.generation == generation { inFlight = nil }
        switch result {
        case .landed(let at):
            // The newest seek's restart completes the start (the reducer counts any generation at or
            // after the resume).
            if generation == latestGeneration { startupPending = false }
            if var l = landing {
                let step = l.landed(generation: generation, atSec: at, durationAtIssue: landingDurationAtIssue,
                                    durationNow: durationNow)
                landing = l
                apply(step, to: &out)
            }
        case .rejected:
            if var l = landing {
                let step = l.seekRejected(generation: generation)
                landing = l
                apply(step, to: &out)
            }
            // Only the newest seek: a later seek's restart completes the start itself. Whichever seek
            // it is (the resume, a viewer seek that superseded it, the correction), r2-3.
            if startupPending, generation == latestGeneration {
                startupPending = false
                out.startupResumeRejected = true
            }
        }
        return out
    }

    private func apply(_ step: MPVReturnLanding.Step, to out: inout Outcome) {
        switch step {
        case .none: break
        case .correct(let t): out.correctToSec = t
        case .complete(let c): out.completion = c
        }
    }
}
