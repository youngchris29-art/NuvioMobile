import Foundation

/// W4 review r1–r3: the stream picker's bookkeeping of the viewer's own choices against its
/// automatic walks (the first-play failover and the in-player episode walk), and the single owner
/// of "there is an unhandled failure for the source on screen". `StreamPickerView` keeps one in
/// `@State` and its handlers are thin calls into it, so the tests drive the code the view runs.
///
/// **The open failure.** A failure of the presented context is opened here the instant the player
/// reports it (`failureArrived`), before anything routes it, and stays open through every phase of
/// its handling: held for a pending choice, a candidate load, a refresh, the resolve of a
/// replacement. It closes only on a terminal outcome (`failureHandled`: a replacement swapped in,
/// the walk gave up and the player closed, the alert or the episode picker opened), or is dropped
/// when another context takes the screen or the player closes (`contextPresented`). No step can run
/// for a failure the ledger does not know, and every exit of every step either closes it or leaves
/// it open, where a viewer choice holds it (`choiceBegan`) and an abandoned choice hands it back to
/// be routed from scratch (`choiceAbandoned`). A link rejection deferred for a refresh travels with
/// it: every close or drop where the refresh did not settle it hands the failure back to apply it.
///
/// **Choices.** One that takes over (or closes) at once (`viewerActed`: a list pick, a hand-off,
/// Menu), or one made in the player that may still fail (`choiceBegan(id)`): pending until it
/// reaches the screen (`contextPresented`) or the player abandons it (`choiceAbandoned(id)`). A
/// newer choice supersedes an older one. Every choice stales the walk tickets taken before it
/// (`AutoWalkIntentGate`), so nothing an old walk does changes the screen afterwards.
struct PlayerChoiceLedger {
    /// An unhandled failure of one presented context.
    struct OpenFailure {
        let context: PlaybackContext
        var failure: PlaybackFailure
        /// The link's 8-hour rejection waits for a refresh (2b.7); applied on every exit where
        /// the refresh did not settle it.
        var rejectionDeferred: Bool
        /// Held for a pending viewer choice (no step runs for it until the choice ends).
        var held: Bool
        var contextId: String { context.id }
    }

    enum Walk: Equatable { case autoFailover, episode }

    /// What an abandoned choice hands back to be handled from scratch (Stage B review finding 3):
    /// the held failure, or else a start-up limit that passed while the choice was pending.
    enum Replay {
        case failure(OpenFailure)
        case startupLimit(contextId: String)

        var contextId: String {
            switch self {
            case let .failure(open): open.contextId
            case let .startupLimit(id): id
            }
        }
        /// The held failure, nil for a start-up limit.
        var failure: PlaybackFailure? {
            if case let .failure(open) = self { return open.failure }
            return nil
        }
    }

    enum FailureVerdict: Equatable {
        /// Route it now (alert, picker or a walk).
        case route
        /// A choice of the viewer's is pending: held until it ends.
        case hold
    }

    private(set) var gate = AutoWalkIntentGate()
    /// The in-player choice still on its way (nil: none pending).
    private(set) var pendingChoice: UUID?
    private(set) var openFailure: OpenFailure?
    /// Finding 3: the context whose start-up limit passed while a choice was pending (the clock
    /// fires once, so the limit is held here and replayed if the choice is abandoned). Slow is not
    /// failed: it never opens a failure, and a real failure of the same context supersedes it.
    private(set) var heldStartupLimit: String?
    private(set) var autoFailoverTicket: Int?
    private(set) var episodeWalkTicket: Int?

    var choicePending: Bool { pendingChoice != nil }
    var failureHeld: Bool { openFailure?.held ?? false }

    // MARK: Viewer choices

    /// A choice that takes over the screen, or closes the player, at once. Earlier walks go stale;
    /// nothing is pending afterwards. The screen change that follows drops an open failure
    /// (`contextPresented`).
    mutating func viewerActed() {
        gate.viewerChose()
        gate.contextPresented()
        pendingChoice = nil
        heldStartupLimit = nil
        clearTickets()
    }

    /// An in-player choice began (it may still fail). Earlier walks go stale; an open failure of
    /// the context on screen, in whatever phase its handling was, is held for the choice.
    mutating func choiceBegan(_ id: UUID) {
        gate.viewerChose()
        pendingChoice = id
        openFailure?.held = true
        clearTickets()
    }

    /// `presentedId` is on screen now (nil: the player closed). A pending choice is done; an open
    /// failure of a context that left the screen is dropped and returned when its deferred link
    /// rejection must still be applied.
    @discardableResult
    mutating func contextPresented(_ presentedId: String?) -> OpenFailure? {
        gate.contextPresented()
        pendingChoice = nil
        if heldStartupLimit != presentedId { heldStartupLimit = nil }
        guard let open = openFailure, open.contextId != presentedId else { return nil }
        openFailure = nil
        return open.rejectionDeferred ? open : nil
    }

    /// The player gave up on choice `id`. When it is the pending one, pending ends with the old
    /// context still on screen, and a held failure is returned to be routed from scratch.
    mutating func choiceAbandoned(_ id: UUID) -> Replay? {
        guard pendingChoice == id else { return nil }
        pendingChoice = nil
        gate.contextPresented()
        let limit = heldStartupLimit
        heldStartupLimit = nil
        if var open = openFailure, open.held {
            open.held = false
            openFailure = open
            return .failure(open)
        }
        return limit.map { .startupLimit(contextId: $0) }
    }

    /// Finding 3: the start-up limit of `contextId` (on screen) passed. Held while a choice is
    /// pending; otherwise the host asks the walk whether another source could start.
    mutating func startupLimitReached(contextId: String) -> FailureVerdict {
        guard choicePending else { return .route }
        if openFailure?.contextId != contextId { heldStartupLimit = contextId }
        return .hold
    }

    // MARK: The open failure

    /// The player reported a failure of `context` (on screen). Opens it (a second report of the
    /// same context while it is open updates it and keeps a deferral); held while a choice is pending.
    mutating func failureArrived(context: PlaybackContext, failure: PlaybackFailure,
                                 rejectionDeferred: Bool) -> FailureVerdict {
        let deferred = rejectionDeferred || (openFailure?.contextId == context.id && openFailure?.rejectionDeferred == true)
        if heldStartupLimit == context.id { heldStartupLimit = nil }   // a real failure supersedes it
        openFailure = OpenFailure(context: context, failure: failure, rejectionDeferred: deferred,
                                  held: choicePending)
        return choicePending ? .hold : .route
    }

    /// Routing decided whether the refresh will run: when it will not, the deferred rejection is
    /// returned (to apply now) and no longer deferred.
    mutating func refreshDecided(willRefresh: Bool) -> OpenFailure? {
        guard var open = openFailure, open.rejectionDeferred, !willRefresh else { return nil }
        open.rejectionDeferred = false
        openFailure = open
        return open
    }

    /// The failure of `contextId` reached a terminal outcome. `rejectionSettled`: a replacement
    /// swapped in (a refresh that helped, or a walk that already remembered its link). Returns
    /// the failure when its deferred rejection must be applied now.
    @discardableResult
    mutating func failureHandled(contextId: String, rejectionSettled: Bool) -> OpenFailure? {
        guard let open = openFailure, open.contextId == contextId else { return nil }
        openFailure = nil
        return open.rejectionDeferred && !rejectionSettled ? open : nil
    }

    /// Finding 3: the source on screen showed its first frame: a held start-up limit is void.
    mutating func sourceStarted(contextId: String) {
        if heldStartupLimit == contextId { heldStartupLimit = nil }
    }

    /// May anything automatic start a walk now?
    var allowsAutomaticStart: Bool { !choicePending && gate.allowsAutomaticWalk }

    // MARK: Walk tickets

    /// A walk starts (or, `keepTicket`, a walk already resolving swallows a second report).
    mutating func walkStarted(_ walk: Walk, keepTicket: Bool = false) {
        guard !keepTicket || ticket(walk) == nil else { return }
        switch walk {
        case .autoFailover: autoFailoverTicket = gate.ticket
        case .episode: episodeWalkTicket = gate.ticket
        }
    }

    func ticket(_ walk: Walk) -> Int? {
        switch walk {
        case .autoFailover: autoFailoverTicket
        case .episode: episodeWalkTicket
        }
    }

    /// May `walk`'s `.play` swap `replacing` for its result while `presented` is on screen?
    func admitsSwap(_ walk: Walk, replacing: String?, presented: String?) -> Bool {
        gate.admitsSwap(ticket: ticket(walk), replacing: replacing, presented: presented)
    }

    /// May `walk`'s give-up close the player now?
    func admitsGiveUp(_ walk: Walk) -> Bool { gate.accepts(ticket(walk)) }

    /// May a load or other result asked for with `ticket` be used now?
    func accepts(_ ticket: Int?) -> Bool { gate.accepts(ticket) }

    mutating func walkEnded(_ walk: Walk) {
        switch walk {
        case .autoFailover: autoFailoverTicket = nil
        case .episode: episodeWalkTicket = nil
        }
    }

    private mutating func clearTickets() {
        autoFailoverTicket = nil
        episodeWalkTicket = nil
    }
}
