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
