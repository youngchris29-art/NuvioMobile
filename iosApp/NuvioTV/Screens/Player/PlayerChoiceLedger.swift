import Foundation

/// W4 review r2: the stream picker's bookkeeping of the viewer's own choices against its automatic
/// walks (the first-play failover and the in-player episode walk). `StreamPickerView` keeps one in
/// `@State` and its handlers are thin calls into it; every decision about "may this walk event or
/// this failure change the screen now" is made here, so the tests drive the same code the view runs.
///
/// Two kinds of choice:
/// - one that takes over (or closes) at once (`viewerActed`): a list pick, a player hand-off, Menu;
/// - one made in the player that may still fail (`choiceBegan(id)`): a Sources pick that resolves,
///   an episode jump, Play Next, the offline card. It is pending until it reaches the screen
///   (`contextPresented`) or the player reports it abandoned (`choiceAbandoned(id)`: resolve
///   failed, nothing found, cancelled). A newer choice supersedes an older one (its id no longer
///   matches, so its late abandon changes nothing).
///
/// Every choice stales the tickets of the walks running before it (`AutoWalkIntentGate`), so
/// nothing an old walk does can change the screen afterwards. While a choice is pending, a failure
/// of the context on screen is held; if the choice is abandoned, it is handed back to be routed by
/// the normal rules (`choiceAbandoned` returns it). A failure whose walk the choice interrupted is
/// handed back the same way: the walk itself never resumes on its own.
struct PlayerChoiceLedger: Equatable {
    /// A playback failure of one presented context (nil `failure`: none to replay).
    struct HeldFailure: Equatable {
        let contextId: String
        let failure: PlaybackFailure
    }

    enum Walk: Equatable { case autoFailover, episode }

    enum FailureVerdict: Equatable {
        /// Route it now (alert, picker or a walk).
        case route
        /// A choice of the viewer's is pending: held until it ends.
        case hold
    }

    private(set) var gate = AutoWalkIntentGate()
    /// The in-player choice still on its way (nil: none pending).
    private(set) var pendingChoice: UUID?
    /// The failure of the context on screen that waits for the pending choice to end.
    private(set) var heldFailure: HeldFailure?
    private(set) var autoFailoverTicket: Int?
    private(set) var episodeWalkTicket: Int?
    /// The failure each walk is handling now (nil for a walk the start-up limit began).
    private var walkFailure: [Walk: HeldFailure] = [:]

    var choicePending: Bool { pendingChoice != nil }

    // MARK: Viewer choices

    /// A choice that takes over the screen, or closes the player, at once. Earlier walks go stale;
    /// nothing is pending afterwards.
    mutating func viewerActed() {
        gate.viewerChose()
        gate.contextPresented()
        pendingChoice = nil
        heldFailure = nil
        clearWalks()
    }

    /// An in-player choice began (it may still fail). Earlier walks go stale. `walkInFlight` names
    /// the walk that was resolving for a failure of the context on screen: the choice interrupts it,
    /// and that failure is held, to be routed again from scratch if the choice is abandoned.
    mutating func choiceBegan(_ id: UUID, walkInFlight: Walk?) {
        if let walk = walkInFlight, let failure = walkFailure[walk], heldFailure == nil {
            heldFailure = failure
        }
        gate.viewerChose()
        pendingChoice = id
        clearWalks()
    }

    /// A context went on screen (or the player closed): the pending choice, if any, is done, and a
    /// failure held for the context that left is dropped with it.
    mutating func contextPresented() {
        gate.contextPresented()
        pendingChoice = nil
        heldFailure = nil
    }

    /// The player gave up on choice `id` (resolve failed, nothing found, cancelled). When it is
    /// the pending one, pending ends with the old context still on screen, and a failure held for
    /// that context is returned to be routed by the normal rules. A superseded or unknown id
    /// changes nothing.
    mutating func choiceAbandoned(_ id: UUID) -> HeldFailure? {
        guard pendingChoice == id else { return nil }
        pendingChoice = nil
        gate.contextPresented()
        let held = heldFailure
        heldFailure = nil
        return held
    }

    // MARK: Failures and the start-up limit

    /// A failure of the context on screen arrived.
    mutating func failureArrived(contextId: String, failure: PlaybackFailure) -> FailureVerdict {
        guard choicePending else { return .route }
        heldFailure = HeldFailure(contextId: contextId, failure: failure)
        return .hold
    }

    /// May the start-up limit (or anything else automatic) start a walk now?
    var allowsAutomaticStart: Bool { !choicePending && gate.allowsAutomaticWalk }

    // MARK: Walks

    /// A walk starts (or continues) for `failure` of `contextId` (nil: the start-up limit). A
    /// report that a walk already resolving swallows keeps that walk's ticket (`keepTicket`).
    mutating func walkStarted(_ walk: Walk, contextId: String, failure: PlaybackFailure?, keepTicket: Bool = false) {
        if !keepTicket || ticket(walk) == nil {
            switch walk {
            case .autoFailover: autoFailoverTicket = gate.ticket
            case .episode: episodeWalkTicket = gate.ticket
            }
        }
        if let failure {
            walkFailure[walk] = HeldFailure(contextId: contextId, failure: failure)
        } else if !keepTicket {
            walkFailure[walk] = nil
        }
    }

    /// The ticket of `walk`'s current run.
    func ticket(_ walk: Walk) -> Int? {
        switch walk {
        case .autoFailover: autoFailoverTicket
        case .episode: episodeWalkTicket
        }
    }

    /// May `walk`'s `.play` swap `replacing` (the context it set out to replace) for its result
    /// while `presented` is on screen?
    func admitsSwap(_ walk: Walk, replacing: String?, presented: String?) -> Bool {
        gate.admitsSwap(ticket: ticket(walk), replacing: replacing, presented: presented)
    }

    /// May `walk`'s give-up close the player now?
    func admitsGiveUp(_ walk: Walk) -> Bool {
        gate.accepts(ticket(walk))
    }

    /// May a load or other result the walk asked for with `ticket` be used now?
    func accepts(_ ticket: Int?) -> Bool { gate.accepts(ticket) }

    /// The walk's run ended (it swapped, gave up, or was dropped).
    mutating func walkEnded(_ walk: Walk) {
        switch walk {
        case .autoFailover: autoFailoverTicket = nil
        case .episode: episodeWalkTicket = nil
        }
        walkFailure[walk] = nil
    }

    private mutating func clearWalks() {
        autoFailoverTicket = nil
        episodeWalkTicket = nil
        walkFailure = [:]
    }
}
