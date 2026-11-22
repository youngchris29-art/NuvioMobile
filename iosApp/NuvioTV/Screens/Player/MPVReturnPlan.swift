import Foundation

/// Return from background on mpv (spec-mpv-return §3.2): what the controller held at park, from its
/// own cache, with no mpv call. The intent always starts `.pause` (decision A); only a Play/Pause
/// press after park changes it (`notePress`).
nonisolated struct MPVReturnSnapshot: Sendable, Equatable {
    /// The controller's creation owner (taken at `init`, or the payload's), never read at park.
    let owner: PlaybackIdentity
    /// The creation owner was still the current identity at park.
    let ownerValidAtPark: Bool
    let contextID: String
    let streamKey: String
    let start: PlayerReturnHandoff.Start
    private(set) var intent: PlayerReturnHandoff.Intent = .pause
    let audio: PlayerReturnHandoff.AudioPick
    let subtitle: PlayerReturnHandoff.SubtitlePick
    let playedSec: Double
    let healthyReported: Bool
    let audioDelaySec: Double?
    let speed: Double
    /// This park's generation (the controller's base plus one per park).
    let generation: Int
    /// Ended (post-play) or failed at park: only paused, never `vid=no` (build note §8.4).
    let terminalAtPark: Bool

    init(owner: PlaybackIdentity, ownerValidAtPark: Bool, contextID: String, streamKey: String,
         start: PlayerReturnHandoff.Start, audio: PlayerReturnHandoff.AudioPick = .auto,
         subtitle: PlayerReturnHandoff.SubtitlePick = .auto, playedSec: Double = 0, healthyReported: Bool = false,
         audioDelaySec: Double? = nil, speed: Double = 1, generation: Int, terminalAtPark: Bool = false) {
        self.owner = owner
        self.ownerValidAtPark = ownerValidAtPark
        self.contextID = contextID
        self.streamKey = streamKey
        self.start = start
        self.audio = audio
        self.subtitle = subtitle
        self.playedSec = playedSec
        self.healthyReported = healthyReported
        self.audioDelaySec = audioDelaySec
        self.speed = speed
        self.generation = generation
        self.terminalAtPark = terminalAtPark
    }

    /// A Play/Pause press after park: last press wins.
    mutating func notePress() { intent = intent.toggled }
}

/// What the controller sees at `didBecomeActive` (or at a deferred `viewDidAppear`).
nonisolated struct MPVReturnFacts: Sendable, Equatable {
    let currentIdentity: PlaybackIdentity
    let presence: PlayerPresence
    /// Ended, post-play or failed now.
    let terminal: Bool
    /// An Up Next / failover context swap is underway (`playbackFailoverSuppressed`).
    let contextSwapPending: Bool
}

/// spec-mpv-return §3.4. Pure; first match wins.
nonisolated enum MPVReturnPlan {
    enum NothingReason: String, Sendable, Equatable { case notBackgrounded, leaving, terminal, contextSwap }

    enum Decision: Sendable, Equatable {
        case nothing(NothingReason)
        /// The owner changed (before Home, or while away): exit, replaced teardown as `.discard`.
        case abandon
        /// Covered: decided again at `viewDidAppear` with the same rows.
        case deferUntilFront
        case replace(PlayerReturnHandoff)

        var logToken: String {
            switch self {
            case .nothing(let r): "nothing(\(r.rawValue))"
            case .abandon: "abandon reason=owner"
            case .deferUntilFront: "deferUntilFront"
            case .replace(let p): "replace start=\(p.start.logToken) intent=\(p.intent == .pause ? "pause" : "play")"
            }
        }
    }

    static func decide(snapshot: MPVReturnSnapshot?, facts: MPVReturnFacts) -> Decision {
        guard let snapshot else { return .nothing(.notBackgrounded) }
        if !snapshot.ownerValidAtPark || facts.currentIdentity != snapshot.owner { return .abandon }
        if facts.presence == .leaving { return .nothing(.leaving) }
        if facts.terminal || snapshot.terminalAtPark { return .nothing(.terminal) }
        if facts.contextSwapPending { return .nothing(.contextSwap) }
        if facts.presence == .covered { return .deferUntilFront }
        return .replace(payload(from: snapshot))
    }

    static func payload(from s: MPVReturnSnapshot) -> PlayerReturnHandoff {
        PlayerReturnHandoff(owner: s.owner, contextID: s.contextID, streamKey: s.streamKey, start: s.start,
                            intent: s.intent, playedSec: s.playedSec, healthyReported: s.healthyReported,
                            returnGeneration: s.generation, freshStartsLeft: 1, audio: s.audio,
                            subtitle: s.subtitle, audioDelaySec: s.audioDelaySec, speed: s.speed,
                            origin: .mpvReturn)
    }

    /// §3.2 start: a live stream returns live; a started player returns at the target of a seek in
    /// flight, else its position; a player not started yet returns at its own return start (a fresh
    /// controller backgrounded again), else at a known resume target, else as a normal start.
    static func start(isLive: Bool, started: Bool, positionSec: Double, seekInFlightTargetSec: Double?,
                      ownReturnStart: PlayerReturnHandoff.Start?, resumeTargetSec: Double?) -> PlayerReturnHandoff.Start {
        if isLive { return .live }
        if started {
            if let t = seekInFlightTargetSec, t.isFinite, t >= 0 { return .position(t) }
            return .position(positionSec.isFinite ? max(0, positionSec) : 0)
        }
        if let own = ownReturnStart { return own }
        if let r = resumeTargetSec, r.isFinite, r >= 0 { return .position(r) }
        return .normalStart
    }
}
