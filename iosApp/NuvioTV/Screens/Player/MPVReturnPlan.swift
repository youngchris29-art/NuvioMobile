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
        /// Seconds played over the whole viewing (code r3-4): what the controller was handed plus its own.
        var playedSec: Double = 0
    }

    /// The park snapshot's picks and tuning: intent first, observed state where intent is silent
    /// (the picks have no observed fallback: the fresh controller's own automatic choice reproduces
    /// an unpicked track). `observedAudioDelaySec` nil = the file never loaded.
    /// `carriedPlayedSec`: what the engines and controllers before this one played (the handoff's, or
    /// the native/Aether seconds), counted from the start, not from this controller's FILE_LOADED;
    /// `ownPlayedSec`: this controller's play clock (0 before its load).
    func parked(observedSpeed: Double, observedAudioDelaySec: Double?, carriedPlayedSec: Double = 0,
                ownPlayedSec: Double = 0) -> Parked {
        func clean(_ v: Double) -> Double { v.isFinite && v > 0 ? v : 0 }
        return Parked(audio: audio, subtitle: subtitle,
                      speed: speed ?? (observedSpeed.isFinite && observedSpeed > 0 ? observedSpeed : 1),
                      audioDelaySec: audioDelaySec ?? observedAudioDelaySec,
                      playedSec: clean(carriedPlayedSec) + clean(ownPlayedSec))
    }
}

// MARK: - First-frame-safe paused start (code review W7 r3-1)

/// How a return-started controller honours a paused intent. On `gpu-next` a file held paused before
/// its first frame wedged that player's mpv queue (Batch E device pass 10-18, DV P5 MP4; the reason
/// the display-mode hold is skipped there), so that route loads playing and muted, and pauses once
/// the first frame is out. Pure.
nonisolated enum MPVReturnStartMode: Sendable, Equatable {
    case loadPaused
    case loadPlaying
    /// Load playing with audio muted; at the first frame apply `pause = !desiredPlaying`, then unmute.
    case pauseAfterFirstFrame

    static func decide(usesGpuNext: Bool, startsPaused: Bool) -> MPVReturnStartMode {
        guard startsPaused else { return .loadPlaying }
        return usesGpuNext ? .pauseAfterFirstFrame : .loadPaused
    }

    /// At the first frame of `.pauseAfterFirstFrame`: the pause is applied before the unmute, so no
    /// audio is heard unless a press during the window asked for play.
    static func atFirstFrame(desiredPlaying: Bool) -> (pause: Bool, unmute: Bool) {
        (pause: !desiredPlaying, unmute: true)
    }
}

// MARK: - Who owns a start's failure (code review W7 r3-2, r5-4/5)

/// Every mpv start `PlayerScreen` creates has exactly one failure owner (r5-4/5): the host's callback
/// when it has one, else `PlayerScreen`'s own alert. `.none` only for a controller with neither (not
/// built by `PlayerScreen`). Pure.
nonisolated enum PlayerReturnFailureOwner: Sendable, Equatable {
    case host, local, none

    static func decide(hostHasCallback: Bool, localOwnerAvailable: Bool) -> PlayerReturnFailureOwner {
        if hostHasCallback { return .host }
        return localOwnerAvailable ? .local : .none
    }

    /// The local alert's "Try with mpv" start: a return failure's held start; else where an ordinary
    /// start that played had got to; else a normal start.
    static func localRetryStart(for failure: PlaybackFailure) -> PlayerReturnHandoff.Start {
        if let r = failure.returnRecovery { return r }
        if failure.startedPlaying, failure.positionSec.isFinite, failure.positionSec > 0 { return .position(failure.positionSec) }
        return .normalStart
    }
}

// MARK: - One bounded end for a return start (code review W7 r5-4)

/// A return start (payload or a retry's held start) must end within a bound of active time, from its
/// load until it is complete (landing settled / offTarget / cancelled, or the start stage completed
/// when there is no landing). The start watchdog stands down at FILE_LOADED; this one does not. It
/// never counts time while suspended (backgrounded or parked). Pure; the clock is passed in.
nonisolated struct MPVStartDeadline: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case idle, running(since: Double, spent: Double), suspended(spent: Double), done }

    static let defaultLimitSec: Double = 45

    let limitSec: Double
    private(set) var phase: Phase = .idle

    init(limitSec: Double = MPVStartDeadline.defaultLimitSec) { self.limitSec = limitSec }

    var isRunning: Bool { if case .running = phase { return true }; return false }

    mutating func begin(now: Double) { if phase == .idle { phase = .running(since: now, spent: 0) } }

    mutating func suspend(now: Double) {
        if case .running(let since, let spent) = phase { phase = .suspended(spent: spent + max(0, now - since)) }
    }

    mutating func resume(now: Double) {
        if case .suspended(let spent) = phase { phase = .running(since: now, spent: spent) }
    }

    /// The start completed (or the controller is going away): never fires.
    mutating func complete() { phase = .done }

    /// True exactly once, when the active time passed the limit.
    mutating func poll(now: Double) -> Bool {
        guard case .running(let since, let spent) = phase, spent + max(0, now - since) >= limitSec else { return false }
        phase = .done
        return true
    }
}

// MARK: - The position a return start reports (code review W7 r4-1, r5-3)

/// The position every tracker start, progress save, Trakt note and stop reports (r4-1, r5-3). Pure:
/// - `.held`: until the held start is reached (the payload's landing completed, or a retry's start);
/// - `.landed(x)`: after that, the confirmed landing (or the latest seek landing) until the published
///   clock (a 0.5 s poll) has caught up with it, so an exit right after the landing never reports 0;
/// - `.clock`: the player's own position.
/// A start with no held start is `.clock` from the beginning (today's).
nonisolated struct MPVReturnReportedPosition: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case held(Double), landed(Double), clock }

    private(set) var phase: Phase

    /// A clock sample within this neighbourhood of the landing has caught up (paused: equal; playing:
    /// a little past; the window allows a slow first tick).
    static let catchUpBeforeSec = 1.0
    static let catchUpAfterSec = 60.0

    init(heldStartSec: Double?) {
        if let h = heldStartSec, h.isFinite, h >= 0 { phase = .held(h) } else { phase = .clock }
    }

    /// The held start was reached: at `landedSec` (nil = the held start itself).
    mutating func reached(landedSec: Double?) {
        guard case .held(let h) = phase else { return }
        phase = .landed(landedSec.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? h)
    }

    /// A later app seek landed: the reference moves there until the clock catches up again. Ignored
    /// while the held start has not been reached.
    mutating func seekLanded(atSec: Double) {
        if case .held = phase { return }
        if atSec.isFinite, atSec >= 0 { phase = .landed(atSec) }
    }

    /// A published clock sample (the poll).
    mutating func clockSample(_ live: Double) {
        guard case .landed(let x) = phase, live.isFinite else { return }
        if live >= x - Self.catchUpBeforeSec && live <= x + Self.catchUpAfterSec { phase = .clock }
    }

    func position(livePositionSec: Double) -> Double {
        switch phase {
        case .held(let h): return h
        case .landed(let x): return x
        case .clock: return livePositionSec.isFinite ? max(0, livePositionSec) : 0
        }
    }

    /// The held start of a controller: the payload's `.position`, else a retry's `returnStart` `.position`.
    static func heldStart(payload: PlayerReturnHandoff.Start?, contextReturnStart: PlayerReturnHandoff.Start?) -> Double? {
        if case .position(let p)? = payload { return p }
        if payload == nil, case .position(let p)? = contextReturnStart { return p }
        return nil
    }
}

// MARK: - One owner of the return generation (code review W7 r4-3)

/// `PlayerScreen`'s return epoch: the last accepted generation, and the base every mpv controller it
/// creates continues from (a payload start, a local retry, a plain fallback alike), so no creation path
/// can park with a generation the screen already accepted. Pure.
nonisolated struct PlayerReturnEpoch: Sendable, Equatable {
    private(set) var lastAccepted = 0

    /// What a new controller's park generation starts from.
    var baseForNextController: Int { lastAccepted }

    mutating func accept(_ payload: PlayerReturnHandoff, current: PlaybackIdentity, contextID: String) -> PlayerReturnHandoff.Validation {
        let v = payload.validate(current: current, contextID: contextID, lastGeneration: lastAccepted)
        if v == .accept { lastAccepted = payload.returnGeneration }
        return v
    }

    /// A new context starts over.
    mutating func reset() { lastAccepted = 0 }
}
