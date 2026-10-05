import Combine
import SharedCore
import SwiftUI

// Home Stage & Strip (P1 §4): the stage swap state machine.
//
// The upstream pipeline is Classic's, reused unchanged (focus report → `HomeHeroFocusModel`'s 0.2 s
// commit → a sticky target → `HeroArtResolver.present` → `presented`). What is new is WHEN a newly
// presented title may replace the one on stage:
//
//  - a 450 ms pause anchored on the LAST raw focus report (D3), so "450 ms after you stop";
//  - never while the strip's page animation is in flight, and never within 0.05 s of rows motion
//    (#15), so a Down press is one motion at a time: the glide, then the swap;
//  - text out (0.15 s), swap while invisible, text in (0.20 s) — the M5 render contract
//    (`HeroTextSwap.swift`), so two titles are never on screen together;
//  - the ART follows the text: it is drawn from the same `shown` value, so it changes at the swap
//    point (its own 0.3 s cross-fade in `HeroCrossfadeImage`), never ahead of the text.
//
// `StageSwapCore` is the pure, clock-explicit machine (unit-tested case by case, §4.4);
// `StageSwapDriver` runs it on a real (or injected) clock and publishes the result.

// MARK: - Payload

/// What the core swaps. `swapIdentity` decides "same title" (a silent gap-fill) vs "new title" (a
/// swap). `HeroPresentation` in production; a plain struct in the tests.
nonisolated protocol StageSwapPayload: Equatable {
    var swapIdentity: String { get }
}

extension HeroPresentation: StageSwapPayload {
    var swapIdentity: String { identity }
}

/// The curve for the core's latest opacity write.
nonisolated enum StageSwapFade: Equatable, Sendable {
    /// Instant (seed, Reduce Motion, clear).
    case instant
    /// Ease-out toward 0 over the fade-out.
    case fadeOut(TimeInterval)
    /// Ease-in toward 1 over the fade-in.
    case fadeIn(TimeInterval)
}

// MARK: - Core

/// The pure swap machine (§4.2). Every input carries an explicit time; nothing here schedules.
///
/// Invariants (asserted by `StageSwapModelTests`):
///  - I1: `shown`'s identity changes only inside a swap, and only while `textOpacity == 0` or under
///    Reduce Motion.
///  - I2: `gateTime() ≥ lastActivity + timing.pause`.
///  - I3: no fade-out starts while a page is in flight, or within `quiet` of the last rows motion.
nonisolated struct StageSwapCore<P: StageSwapPayload>: Equatable {
    typealias Fade = StageSwapFade

    /// `.stage` (0.45 / 0.15 / 0.20) unless the launch knobs override it (#6).
    var timing: TextSwapTiming
    var reduceMotion: Bool

    /// Rows still this long before a fade-out may start (#15). A computed static: a generic type
    /// cannot hold a stored one.
    static var quiet: TimeInterval { 0.05 }

    /// `now` has reached `deadline`, with a microsecond of slack: sums like 0.45 + 0.15 are not
    /// exact in binary, and a wake scheduled for a deadline must find it reached.
    static func reached(_ now: TimeInterval, _ deadline: TimeInterval) -> Bool {
        now + 1e-6 >= deadline
    }

    private(set) var phase: TextSwapPhase = .idle
    /// What the text AND the art draw.
    private(set) var shown: P?
    /// The title waiting for the swap point.
    private(set) var pending: P?
    private(set) var textOpacity: Double = 1
    private(set) var fade: StageSwapFade = .instant
    private(set) var lastActivity: TimeInterval = -.infinity
    private(set) var pageInFlight = false
    private(set) var pageEndedAt: TimeInterval = -.infinity
    /// The last rows motion (`RowsMotionClock`), fed by the driver before every tick.
    private(set) var lastMotion: TimeInterval = -.infinity
    /// When the running fade ends (fadingOut → swap, fadingIn → done).
    private(set) var stepDue: TimeInterval?
    /// The identity that settled at or after the gate: the background trailer may arm on it (W2-A).
    private(set) var resting: String?
    /// Identity changes actually swapped in.
    private(set) var swaps = 0

    init(timing: TextSwapTiming = StageStripTuning.swapTiming, reduceMotion: Bool = false) {
        self.timing = timing
        self.reduceMotion = reduceMotion
    }

    /// When a fade-out (or the rest marker) may happen; nil while a page is in flight.
    func gateTime() -> TimeInterval? {
        guard !pageInFlight else { return nil }
        return max(lastActivity + timing.pause, pageEndedAt, lastMotion + Self.quiet)
    }

    /// The next moment `tick` has something to do, or nil.
    var nextDeadline: TimeInterval? {
        switch phase {
        case .pausing:
            return gateTime()
        case .fadingOut, .fadingIn:
            return stepDue
        case .idle:
            return (resting == nil && shown != nil) ? gateTime() : nil
        }
    }

    // MARK: Inputs

    /// First paint: shown at once, nothing in flight.
    mutating func seed(_ p: P?) {
        shown = p
        pending = nil
        resetToIdle()
        resting = nil
    }

    mutating func present(_ p: P?, now: TimeInterval) {
        guard let p else {
            clear()
            return
        }
        guard let current = shown else {
            // Nothing on stage yet: the seed path, no fade.
            shown = p
            pending = nil
            resetToIdle()
            resting = nil
            return
        }
        if p.swapIdentity == current.swapIdentity {
            // Same title: a silent gap-fill (a late synopsis, a sharpened backdrop). A swap that
            // was on its way to another title is dropped, and hidden text comes back.
            pending = nil
            shown = p
            switch phase {
            case .idle, .fadingIn:
                break
            case .pausing:
                if textOpacity < 1 { beginFadeIn(now: now) } else { enterIdle() }
            case .fadingOut:
                beginFadeIn(now: now)
            }
            return
        }
        // A new title: it waits for the gate. A fade-out in progress takes the newest pending; a
        // fade-in in progress finishes first and then pauses.
        pending = p
        if phase == .idle {
            phase = .pausing
            stepDue = nil
        }
        if phase == .pausing, let gate = gateTime(), Self.reached(now, gate) {
            tick(now: now)   // a cold arrival past the gate goes straight out
        }
    }

    /// A raw focus report (any row, nil included).
    mutating func focusActivity(now: TimeInterval) {
        lastActivity = now
        resting = nil
        cancelFadeOut()
    }

    mutating func pageStarted(now: TimeInterval) {
        pageInFlight = true
        resting = nil
        cancelFadeOut()
    }

    mutating func pageEnded(now: TimeInterval) {
        pageInFlight = false
        pageEndedAt = now
    }

    mutating func motion(at t: TimeInterval) {
        lastMotion = max(lastMotion, t)
    }

    /// Runs every step due at `now`, in order (bounded).
    mutating func tick(now: TimeInterval) {
        var steps = 0
        while steps < 8, step(now: now) {
            steps += 1
        }
    }

    // MARK: Steps

    private mutating func step(now: TimeInterval) -> Bool {
        switch phase {
        case .pausing:
            guard let gate = gateTime(), Self.reached(now, gate) else { return false }
            guard pending != nil else {
                if textOpacity < 1 { beginFadeIn(now: now) } else { enterIdle() }
                return true
            }
            if textOpacity == 0 || reduceMotion {
                swap(now: now)
            } else {
                phase = .fadingOut
                textOpacity = 0
                fade = .fadeOut(timing.fadeOut)
                stepDue = now + timing.fadeOut
            }
            return true
        case .fadingOut:
            guard let due = stepDue, Self.reached(now, due) else { return false }
            swap(now: now)
            return true
        case .fadingIn:
            guard let due = stepDue, Self.reached(now, due) else { return false }
            stepDue = nil
            phase = pending != nil ? .pausing : .idle
            return true
        case .idle:
            guard resting == nil, let current = shown, let gate = gateTime(), Self.reached(now, gate) else { return false }
            resting = current.swapIdentity
            return true
        }
    }

    /// The text is invisible (or Reduce Motion): replace it, then fade the newcomer in.
    private mutating func swap(now: TimeInterval) {
        shown = pending
        pending = nil
        swaps += 1
        resting = nil
        if reduceMotion {
            textOpacity = 1
            fade = .instant
            phase = .idle
            stepDue = nil
        } else {
            textOpacity = 1
            fade = .fadeIn(timing.fadeIn)
            phase = .fadingIn
            stepDue = now + timing.fadeIn
        }
    }

    /// Hidden text returns without a swap (the target came back to what is on stage).
    private mutating func beginFadeIn(now: TimeInterval) {
        if reduceMotion {
            textOpacity = 1
            fade = .instant
            phase = .idle
            stepDue = nil
            return
        }
        phase = .fadingIn
        textOpacity = 1
        fade = .fadeIn(timing.fadeIn)
        stepDue = now + timing.fadeIn
    }

    /// A focus move or a page start during a fade-out: the swap waits for the next gate and the
    /// text stays hidden (its opacity target is already 0).
    private mutating func cancelFadeOut() {
        guard phase == .fadingOut else { return }
        phase = .pausing
        stepDue = nil
    }

    /// Seed and clear: idle, visible, no curve.
    private mutating func resetToIdle() {
        phase = .idle
        textOpacity = 1
        fade = .instant
        stepDue = nil
    }

    /// Visible text with nothing left to do: idle, with no opacity write (the curve stays as it was).
    private mutating func enterIdle() {
        phase = .idle
        stepDue = nil
    }

    private mutating func clear() {
        shown = nil
        pending = nil
        resetToIdle()
        resting = nil
    }
}

// MARK: - Output

/// What the stage's text and art leaves draw (§4.3). Published by the driver only when it changes,
/// in an animation-free transaction.
struct StageSwapOutput: Equatable {
    /// The title the text column draws.
    var shown: HeroPresentation?
    var textOpacity: Double = 1
    /// The core's curve for the latest `textOpacity` change. Stored as the value-equatable fade
    /// (not an `Animation`), so "output unchanged" is decided by value and an input that moves
    /// nothing on screen never re-publishes `output`.
    var fade: StageSwapFade = .instant
    /// `StageSwapCore.resting`: the background trailer's arming key (W2-A).
    var restingKey: String?

    /// The curve the text's scoped opacity animation uses (`StageTextBlock`).
    var animation: Animation? { StageSwapDriver.animation(for: fade) }
    /// The art follows the text: the same value, by definition.
    var art: HeroPresentation? { shown }
}

// MARK: - Wash feed (S2, S8)

/// One title as the ambient wash sees it (P2 §1.4). `washFallback` is the folder page's cover for
/// its seeded folder (`StageController.seed(_:washFallback:)`), nil otherwise.
nonisolated struct StageFeedItem: Equatable {
    let item: MetaPreview
    let identity: String
    let washFallback: String?
}

/// The wash's inputs, kept OFF `StageSwapDriver.output` so a pending change never re-renders the
/// text or art leaves (#5). Only the wash observes this object.
@MainActor
final class StageWashFeed: ObservableObject {
    /// The swap core took a new pending identity (its pause began): the wash warms it.
    @Published private(set) var pending: StageFeedItem?
    /// The swap point (or the seed): the wash fades to it.
    @Published private(set) var displayed: StageFeedItem?

    /// Write-on-change. Internal so tests can drive a feed by hand.
    func setPending(_ value: StageFeedItem?) {
        if pending != value { pending = value }
    }

    func setDisplayed(_ value: StageFeedItem?) {
        if displayed != value { displayed = value }
    }
}

// MARK: - Driver

/// Runs `StageSwapCore<HeroPresentation>` on a clock (§4.3): ONE scheduled wake at the core's next
/// deadline (replaced, never stacked), `output` assigned only when it changes, every write in a fresh
/// transaction so the resolver's 0.3 s commit animation never leaks into the text (the M5 lesson).
@MainActor
final class StageSwapDriver: ObservableObject {
    typealias Schedule = StageScheduling.Schedule

    @Published private(set) var output = StageSwapOutput()
    /// S2: observed only by the ambient wash.
    let washFeed = StageWashFeed()
    #if DEBUG
    /// The `debug_stage` readout's own source (phase/pending changes publish here, never on
    /// `output`). DEBUG only.
    let debug = StageDebugState()
    #endif

    private(set) var core: StageSwapCore<HeroPresentation>
    private let now: @MainActor () -> TimeInterval
    private let motionAge: @MainActor () -> TimeInterval
    private let schedule: Schedule
    private var wake: AnyCancellable?
    /// The last fire made no progress although a deadline was due (float noise, or a gate that
    /// moved): the next wake waits at least `retryFloor` instead of spinning.
    private var lastFireStalled = false
    private static let retryFloor: TimeInterval = 0.05
    private var seedFallback: (identity: String, url: String)?
    private var lastPendingIdentity: String?
    private var lastDisplayedIdentity: String?
    private var lastPageEndedByTimeout = false

    init(timing: TextSwapTiming = StageStripTuning.swapTiming,
         now: (@MainActor () -> TimeInterval)? = nil,
         motionAge: (@MainActor () -> TimeInterval)? = nil,
         schedule: Schedule? = nil) {
        core = StageSwapCore(timing: timing)
        self.now = now ?? { ProcessInfo.processInfo.systemUptime }
        self.motionAge = motionAge ?? { RowsMotionClock.secondsSinceMotion() }
        self.schedule = schedule ?? { after, work in StageScheduling.main(after, work) }
    }

    /// The transaction every published write runs in: animation-free (`Transaction().animation ==
    /// nil`), so no ambient animation reaches the stage leaves.
    static func writeTransaction() -> Transaction { Transaction() }

    /// The SwiftUI curve for a core fade.
    static func animation(for fade: StageSwapFade) -> Animation? {
        switch fade {
        case .instant: return nil
        case .fadeOut(let duration): return .easeOut(duration: duration)
        case .fadeIn(let duration): return .easeIn(duration: duration)
        }
    }

    // MARK: Inputs

    /// Every row focus report (`StageController.report`) and Menu's page-to-top.
    func noteFocusActivity() {
        mutate { core, t in core.focusActivity(now: t) }
    }

    func notePageStarted() {
        mutate { core, t in core.pageStarted(now: t) }
    }

    func notePageEnded(byTimeout: Bool = false) {
        lastPageEndedByTimeout = byTimeout
        mutate { core, t in core.pageEnded(now: t) }
    }

    /// `HeroArtResolver.presented`.
    func receive(_ presentation: HeroPresentation?) {
        mutate { core, t in core.present(presentation, now: t) }
    }

    /// The host's first paint (S2). The art still resolves through the resolver and arrives through
    /// `receive` (landing with no fade, since nothing is shown yet); this writes the wash feed's
    /// `displayed` at once and remembers `washFallback` for that identity (the folder page's cover).
    func seed(_ item: MetaPreview?, washFallback: String? = nil) {
        guard let item else { return }
        let identity = "\(item.type):\(item.id)"
        seedFallback = washFallback.map { (identity: identity, url: $0) }
        guard core.shown == nil else { return }
        lastDisplayedIdentity = identity
        washFeed.setDisplayed(feedItem(item, identity: identity))
    }

    func setReduceMotion(_ on: Bool) {
        guard core.reduceMotion != on else { return }
        mutate { core, _ in core.reduceMotion = on }
    }

    // MARK: Engine

    private func mutate(_ change: (inout StageSwapCore<HeroPresentation>, TimeInterval) -> Void) {
        let t = now()
        apply(change, now: t)
        lastFireStalled = false
        reschedule(now: t)
    }

    /// The scheduled wake: feed the motion clock and run whatever is due.
    private func fire() {
        wake = nil
        let t = now()
        let wasDue = core.nextDeadline.map { $0 <= t } ?? false
        let before = core
        apply({ _, _ in }, now: t)
        lastFireStalled = wasDue && core == before
        reschedule(now: t)
    }

    private func apply(_ change: (inout StageSwapCore<HeroPresentation>, TimeInterval) -> Void,
                       now t: TimeInterval) {
        feedMotion()
        let before = core
        change(&core, t)
        core.tick(now: t)
        logTransition(from: before, now: t)
        publishFeed()
        publishOutput()
        #if DEBUG
        publishDebug()
        #endif
    }

    private func feedMotion() {
        let age = motionAge()
        guard age.isFinite, age < 1e9 else { return }
        core.motion(at: now() - age)
    }

    private func reschedule(now t: TimeInterval) {
        wake?.cancel()
        wake = nil
        guard let deadline = core.nextDeadline else { return }
        var delay = deadline.isFinite ? max(0, deadline - t) : 0
        if lastFireStalled { delay = max(delay, Self.retryFloor) }
        wake = schedule(delay) { [weak self] in self?.fire() }
    }

    private func publishOutput() {
        let next = StageSwapOutput(shown: core.shown,
                                   textOpacity: core.textOpacity,
                                   fade: core.fade,
                                   restingKey: core.resting)
        guard next != output else { return }
        withTransaction(Self.writeTransaction()) { output = next }
    }

    private func publishFeed() {
        let pendingIdentity = core.pending?.identity
        if pendingIdentity != lastPendingIdentity {
            lastPendingIdentity = pendingIdentity
            if let pending = core.pending {
                washFeed.setPending(feedItem(pending.item, identity: pending.identity))
            }
        }
        let shownIdentity = core.shown?.identity
        if shownIdentity != lastDisplayedIdentity {
            lastDisplayedIdentity = shownIdentity
            washFeed.setDisplayed(core.shown.map { feedItem($0.item, identity: $0.identity) })
        }
    }

    private func feedItem(_ item: MetaPreview, identity: String) -> StageFeedItem {
        let fallback = seedFallback?.identity == identity ? seedFallback?.url : nil
        return StageFeedItem(item: item, identity: identity, washFallback: fallback)
    }

    /// `[StageStrip] swap phase=out|in|cancel|idle id= sinceAct=<ms> pageEnd=<ms|timeout>`.
    private func logTransition(from before: StageSwapCore<HeroPresentation>, now t: TimeInterval) {
        guard StageStripProbe.enabled else { return }
        let after = core
        let token: String
        if before.phase == .fadingOut && after.phase == .pausing {
            token = "cancel"
        } else if after.swaps != before.swaps {
            token = "in"
        } else if after.phase == .fadingOut && before.phase != .fadingOut {
            token = "out"
        } else if after.phase == .idle && before.phase != .idle {
            token = "idle"
        } else {
            return
        }
        let subject = (token == "out" || token == "cancel") ? after.pending : after.shown
        let sinceAct = after.lastActivity.isFinite ? "\(Int(((t - after.lastActivity) * 1000).rounded()))" : "-"
        let pageEnd: String
        if lastPageEndedByTimeout {
            pageEnd = "timeout"
        } else if after.pageEndedAt.isFinite {
            pageEnd = "\(Int(((t - after.pageEndedAt) * 1000).rounded()))"
        } else {
            pageEnd = "-"
        }
        StageStripProbe.shared.log("swap phase=\(token) id=\(subject?.identity ?? "-") sinceAct=\(sinceAct) pageEnd=\(pageEnd)")
    }

    #if DEBUG
    private func publishDebug() {
        let line = "phase=\(core.phase.token) shown=\(core.shown?.identity ?? "-") "
            + "pending=\(core.pending?.identity ?? "-") swaps=\(core.swaps)"
        debug.setSwap(line: line, rest: core.resting ?? "-", disp: core.shown?.identity ?? "-")
    }
    #endif
}
