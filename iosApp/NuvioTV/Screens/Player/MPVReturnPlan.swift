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

    /// §3.2 start: a live stream returns live; then the target of the newest seek in flight (started
    /// or not, r2-2); a started player returns at its position; a player not started yet returns at its
    /// own return start (a fresh controller backgrounded again), else at a known resume target, else as
    /// a normal start.
    static func start(isLive: Bool, started: Bool, positionSec: Double, seekInFlightTargetSec: Double?,
                      ownReturnStart: PlayerReturnHandoff.Start?, resumeTargetSec: Double?) -> PlayerReturnHandoff.Start {
        if isLive { return .live }
        // Code review W7 r2-2: the newest targeted seek in flight wins even before the start completed
        // (a viewer seek during a return start; during a plain start it is the resume target itself).
        if let t = seekInFlightTargetSec, t.isFinite, t >= 0 { return .position(t) }
        if started { return .position(positionSec.isFinite ? max(0, positionSec) : 0) }
        if let own = ownReturnStart { return own }
        if let r = resumeTargetSec, r.isFinite, r >= 0 { return .position(r) }
        return .normalStart
    }
}

// MARK: - Viewer intent (code review W7 r2, findings 1, 2, 4)

/// What the viewer asked for, owned for the controller's lifetime (code review W7 r2): the requested
/// audio and subtitle picks (an add-on file still side-loading included), the speed and audio delay.
/// Seeded from the incoming handoff (so a second background mid-restoration carries the pending
/// choice), updated synchronously at the moment of each viewer action (so a pick just before Home is
/// what parks, not the last finished track walk), and resolved against observed state only where it
/// is silent. Pure. The position target lives in `MPVReturnSeeks` (the newest targeted seek in flight).
nonisolated struct MPVViewerIntent: Sendable, Equatable {
    private(set) var audio: PlayerReturnHandoff.AudioPick = .auto
    private(set) var subtitle: PlayerReturnHandoff.SubtitlePick = .auto
    /// nil = silent (the observed value parks).
    private(set) var speed: Double?
    private(set) var audioDelaySec: Double?

    init() {}

    /// A return-started controller: everything the payload carried is intent until the viewer changes it.
    init(handoff p: PlayerReturnHandoff) {
        audio = p.audio
        subtitle = p.subtitle
        speed = p.speed.isFinite && p.speed > 0 && abs(p.speed - 1) > 0.0005 ? p.speed : nil
        audioDelaySec = p.audioDelaySec.flatMap { $0.isFinite ? $0 : nil }
    }

    /// The viewer picked audio track `id` from the tracks the panel showed.
    mutating func viewerPickedAudio(id: Int, tracks: [MPVTrackSemantics]) {
        guard let t = tracks.first(where: { $0.id == id }),
              let ordinal = MPVSelectionRestore.ordinal(of: id, in: tracks) else { return }
        audio = .picked(lang: t.lang, title: t.title, ordinal: ordinal)
    }

    /// The viewer picked subtitle `id` (< 0 = Off). `externalSources`: mpv's source of each external
    /// track; `originalURL` maps a credential-path local file back to its add-on URL.
    mutating func viewerPickedSubtitle(id: Int, tracks: [MPVTrackSemantics], externalSources: [Int: String],
                                       originalURL: (String) -> String) {
        guard id >= 0 else { subtitle = .off; return }
        guard let t = tracks.first(where: { $0.id == id }) else { return }
        if let source = externalSources[id] {
            subtitle = .addon(originalURL: originalURL(source), lang: t.lang, title: t.title)
        } else if let ordinal = MPVSelectionRestore.ordinal(of: id, in: tracks) {
            subtitle = .embedded(lang: t.lang, title: t.title, ordinal: ordinal)
        }
    }

    mutating func viewerSetSpeed(_ s: Double) { if s.isFinite, s > 0 { speed = s } }
    mutating func viewerSetAudioDelay(_ sec: Double) { if sec.isFinite { audioDelaySec = sec } }

    struct Parked: Sendable, Equatable {
        let audio: PlayerReturnHandoff.AudioPick
        let subtitle: PlayerReturnHandoff.SubtitlePick
        let speed: Double
        let audioDelaySec: Double?
    }

    /// The park snapshot's picks and tuning: intent first, observed state where intent is silent
    /// (the picks have no observed fallback: the fresh controller's own automatic choice reproduces
    /// an unpicked track). `observedAudioDelaySec` nil = the file never loaded.
    func parked(observedSpeed: Double, observedAudioDelaySec: Double?) -> Parked {
        Parked(audio: audio, subtitle: subtitle,
               speed: speed ?? (observedSpeed.isFinite && observedSpeed > 0 ? observedSpeed : 1),
               audioDelaySec: audioDelaySec ?? observedAudioDelaySec)
    }
}
