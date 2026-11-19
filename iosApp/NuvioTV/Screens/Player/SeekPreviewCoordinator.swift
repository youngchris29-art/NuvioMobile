import Foundation

/// What the coordinator drives (`PlayerTransportInput` in the app, a recorder in the tests).
@MainActor
protocol SeekPreviewSink: AnyObject {
    /// The one snapshot the bar draws (`TransportBarModel.previewRender`).
    func publish(_ render: SeekPreviewRender)
    /// A lookup for the still-current `targetSec` found no frame near it (or one too far off, the
    /// tolerance-bounded `matchSec`): the engine's decoder may fetch the keyframe there.
    func refine(targetSec: Double, matchSec: Double?)
    /// The requests ended: the engine's own preview work stops (mpv: the thumbnailer's pending miss).
    func endDecoderActivity()
}

/// GitHub #33: the single owner of the seek preview (spec 2.1). It holds the current gesture, the
/// still source's capability and generation, the click latch, the derived plan, the lookup
/// throttle, the request generation and the accepted frame, and publishes one
/// `SeekPreviewRender` per change. Its decisions are the pure types in `SeekPreviewPlan.swift`;
/// this class only executes their effects. No UIKit: the clock and the scheduler are injected, so
/// the async orchestration is unit-tested with fakes (`SeekPreviewCoordinatorTests`). Main only.
@MainActor
final class SeekPreviewCoordinator {
    /// `(capability, generation)` read synchronously from the engine controller (Aether, review
    /// r2-1). Read before every input-driven update, before a returned lookup is accepted and
    /// before a content-change refresh; a difference is applied as a source transition first.
    /// Accepted limitation: the engine has no change event, so a frame already on screen can stay
    /// until the next input or completion when it loses still support on its own. The card exists
    /// only during a gesture or a click's dwell (at most the 4 s fallback), which bounds that window.
    typealias LiveSource = () -> (capability: SeekPreviewCapability, generation: Int)
    /// Runs `body` on main after `delay` seconds; the returned closure cancels it.
    typealias Scheduler = @MainActor (_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> () -> Void

    private weak var sink: SeekPreviewSink?
    private let sourceProvider: () -> SeekPreviewSource?
    private let now: () -> TimeInterval
    private let schedule: Scheduler
    /// Set by an engine whose still support can change without telling anyone (Aether). nil: the
    /// engine pushes every change through `setSource` (mpv).
    var liveSource: LiveSource?

    /// The transport's gesture as last published (`PlayerTransportInput.publishTransport`).
    private(set) var gesture: SeekPreviewGesture = .none
    private(set) var latch = ClickPreviewLatch()
    private(set) var capability: SeekPreviewCapability = .none
    private(set) var sourceGeneration = 0
    private(set) var alive = true
    /// `gesture` with an active click latch folded in.
    private(set) var effectiveGesture: SeekPreviewGesture = .none
    private(set) var plan: SeekPreviewPlan = .none
    /// Bumped by every `invalidate` effect: a lookup that returns with an older one is dropped.
    private(set) var requestGeneration = 0
    private var throttle = PreviewFrameThrottle()
    private var cancelThrottleWait: (() -> Void)?
    private var frame: SeekPreviewMatch?
    /// The request target `frame` was the source's tolerance-bounded `match` for; nil when there is
    /// no frame or it came from the `nearest` fallback (review r5).
    private var frameMatchedTargetSec: Double?
    private var cancelLatchTimer: (() -> Void)?
    private var latchTimerDeadline: Double?
    private var kind: SeekPreviewRender.Kind = .none
    private var episodeKey: (kind: SeekPreviewRender.Kind, generation: Int?) = (.none, nil)
    private var episode = 0
    private(set) var render: SeekPreviewRender = .none

    init(sink: SeekPreviewSink, source: @escaping () -> SeekPreviewSource?,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Scheduler = SeekPreviewCoordinator.mainQueue) {
        self.sink = sink
        self.sourceProvider = source
        self.now = now
        self.schedule = schedule
    }

    /// The default scheduler: a cancellable work item on the main queue.
    static func mainQueue(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> () -> Void {
        let work = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }

    /// Frame requests run (mpv: `ThumbScheduler.Inputs.previewActive`).
    var previewActive: Bool { plan.requestTargetSec != nil }

    // MARK: Inputs
    //
    // Review r4: every entry point below (the public inputs, the lookup return and both timers)
    // goes through `input(_:_:)` first. Its "nothing changed" skip also asks the live source, so
    // no early return can skip the re-read: a hold pinned at the start or end (the same target
    // every tick) still notices Aether gaining or losing stills.

    /// Every transport publish, last in its main-thread turn.
    func gestureChanged(_ g: SeekPreviewGesture) {
        input(g != gesture) { gesture = g }
    }

    /// A Left/Right click issued seek `generation` that lands at `targetSec` (resolved and clamped).
    func clickIssued(targetSec: Double, generation: Int) {
        input(true) { latch.clicked(targetSec: targetSec, generation: generation, now: now()) }
    }

    /// Seek `generation` landed (newest or not). The click's own landing also retries its picture
    /// when the accepted frame is not the target's match (review r5, `landingEffects`).
    func seekLanded(generation: Int) {
        let active = latch.active != nil
        var landing = ClickPreviewLatch.Landing.ignored
        input(active, extra: { [self] in
            SeekPreviewLifecycle.landingEffects(landing, plan: plan, matchedTargetSec: frameMatchedTargetSec)
        }) {
            if active { landing = latch.landed(generation: generation, now: now()) }
        }
    }

    func seekRejected(generation: Int) {
        let active = latch.active != nil
        input(active) { if active { latch.rejected(generation: generation) } }
    }

    /// Menu / Up / Down / Select / Play on a landing card, a chapter-tab seek (review r2-4), the
    /// player going off screen: the click's card goes without a new one.
    func dismissClick() {
        let active = latch.active != nil
        input(active) { if active { latch.clear() } }
    }

    /// The engine's still source changed (mpv: once at load, and on a live reconnect's new store).
    func setSource(capability c: SeekPreviewCapability, generation: Int) {
        input(c != capability || generation != sourceGeneration) {
            capability = c
            sourceGeneration = generation
        }
    }

    /// The engine may have changed what `liveSource` reports (a load started or returned, a
    /// handoff): re-read it now instead of at the next input.
    func sourceMayHaveChanged() {
        input(false)
    }

    /// The source gained a frame at `atSec` (an mpv decode or harvest insert): the current target
    /// asks again if the card would accept that frame and it beats the accepted one
    /// (`SeekPreviewPlan.wantsRefresh`), through the same throttle and generation checks.
    func sourceContentChanged(atSec: Double) {
        input(false)
        guard alive, plan.wantsRefresh(atSec: atSec, shownSec: frame?.sec) else { return }
        handle(throttle.sample(now: now()))
        publish()
    }

    /// The controller's teardown (`PlayerTransportInput.invalidate`): every request, frame, timer
    /// and the latch go; nothing runs after this.
    func teardown() {
        guard alive else { return }
        input(true) { alive = false }
        cancelLatchTimer?()
        cancelLatchTimer = nil
        latchTimerDeadline = nil
    }

    // MARK: Update

    private var lifecycleKey: SeekPreviewLifecycle.Key {
        .init(requestTargetSec: plan.requestTargetSec, capability: capability,
              sourceGeneration: sourceGeneration, alive: alive)
    }

    private var liveSourceDiffers: Bool {
        guard alive, let live = liveSource?() else { return false }
        return live.capability != capability || live.generation != sourceGeneration
    }

    /// The funnel every entry point passes through first (review r4, spec r2-1). `changed` is the
    /// caller's own "my input changed something" test; the work is skipped only when that is
    /// false AND the live source matches the stored one. Otherwise one `update` runs: it applies
    /// `change`, re-reads the live source and runs `SeekPreviewLifecycle` once over the composed
    /// edge (r2-2), so a source transition with no input change still gets its effects.
    private func input(_ changed: Bool, _ change: () -> Void = {}) {
        input(changed, extra: { [] }, change)
    }

    /// `extra` adds effects decided on the state after the change (a click's own landing); they
    /// run in the same `apply` as the lifecycle's.
    private func input(_ changed: Bool, extra: () -> SeekPreviewLifecycle.Effects, _ change: () -> Void) {
        guard changed || liveSourceDiffers else { return }
        update(change, extra: extra)
    }

    /// One input: mutate, read the live source, fold the latch in, derive the plan, run the
    /// lifecycle's effects from the old state to the new one, re-arm the latch timer, publish.
    private func update(_ change: () -> Void, extra: () -> SeekPreviewLifecycle.Effects) {
        let old = lifecycleKey
        change()
        if alive, let live = liveSource?() {
            capability = live.capability
            sourceGeneration = live.generation
        }
        latch.tick(now: now())
        recompute()
        let effects = SeekPreviewLifecycle.effects(from: old, to: lifecycleKey)
        apply(alive ? effects.union(extra()) : effects)
        armLatchTimer()
        publish()
    }

    private func recompute() {
        guard alive else {
            latch.clear()
            effectiveGesture = .none
            plan = .none
            kind = .none
            return
        }
        switch gesture {
        case .hold, .scrub, .scan:
            // A hold, scrub or scan supersedes a click's card.
            latch.clear()
            effectiveGesture = gesture
        case .none, .pending:
            if let a = latch.active {
                effectiveGesture = .landing(targetSec: a.targetSec, generation: a.generation)
            } else {
                effectiveGesture = gesture
            }
        case .landing:
            effectiveGesture = gesture
        }
        plan = SeekPreviewPlan.decide(effectiveGesture, capability)
        let landingGeneration: Int?
        switch effectiveGesture {
        case .hold: kind = .hold; landingGeneration = nil
        case .scrub: kind = .scrub; landingGeneration = nil
        case .landing(_, let g): kind = .landing; landingGeneration = g
        case .none, .pending, .scan: kind = .none; landingGeneration = nil
        }
        if kind != episodeKey.kind || landingGeneration != episodeKey.generation {
            episodeKey = (kind, landingGeneration)
            if kind != .none { episode += 1 }
        }
    }

    private func apply(_ effects: SeekPreviewLifecycle.Effects) {
        if effects.contains(.invalidate) { requestGeneration += 1 }
        if effects.contains(.resetThrottle) {
            throttle.reset()
            cancelThrottleWait?()
            cancelThrottleWait = nil
        }
        if effects.contains(.clearFrame) { setFrame(nil) }
        if effects.contains(.clearLatch) { latch.clear() }
        if effects.contains(.endDecoderActivity) { sink?.endDecoderActivity() }
        if effects.contains(.requestNow) { handle(throttle.sample(now: now())) }
    }

    private func armLatchTimer() {
        let deadline = alive ? latch.nextDeadline : nil
        guard deadline != latchTimerDeadline else { return }
        cancelLatchTimer?()
        cancelLatchTimer = nil
        latchTimerDeadline = deadline
        guard let deadline else { return }
        cancelLatchTimer = schedule(max(0, deadline - now())) { [weak self] in
            guard let self else { return }
            self.cancelLatchTimer = nil
            self.latchTimerDeadline = nil
            // A timer may run a hair before the clock reads its deadline: tick at the deadline.
            self.input(true) { self.latch.tick(now: max(self.now(), deadline)) }
        }
    }

    // MARK: Lookups

    /// The throttle's decision (critique C17: one lookup in flight, 66 ms floor, always a
    /// trailing lookup). `.start` reads the plan's target, never the transport mode.
    private func handle(_ decision: PreviewFrameThrottle.Decision) {
        switch decision {
        case .none:
            break
        case .wait(let seconds):
            guard cancelThrottleWait == nil else { return }
            cancelThrottleWait = schedule(seconds) { [weak self] in
                guard let self else { return }
                self.cancelThrottleWait = nil
                // A transition applied here resets the throttle (and may start the lookup
                // itself), after which `timerFired` has nothing pending and returns `.none`.
                self.input(false)
                self.handle(self.throttle.timerFired(now: self.now()))
                self.publish()
            }
        case .start:
            guard alive, let target = plan.requestTargetSec else {
                throttle.reset()
                return
            }
            guard let source = sourceProvider() else {
                // No store: nothing runs, so the lookup is done at once (the card shows the
                // placeholder or the time).
                setFrame(nil)
                handle(throttle.finished(now: now()))
                return
            }
            let generation = requestGeneration
            Task { @MainActor [weak self] in
                let match = await source.match(near: target)
                // BUG-181 (Steven rc7): a miss shows the nearest stored frame within reach (DV P5
                // never decodes, so its store holds only harvested frames).
                let shown: SeekPreviewMatch?
                if let match { shown = match } else { shown = await source.nearest(to: target) }
                self?.lookupReturned(generation: generation, targetSec: target, match: match, shown: shown)
            }
        }
    }

    /// Review r2-5's order: accept or reject, then the refinement while its target is still the
    /// current one, then the throttle's `finished` and its trailing decision.
    private func lookupReturned(generation: Int, targetSec: Double, match: SeekPreviewMatch?,
                                shown: SeekPreviewMatch?) {
        // Review r2-1 (b): a source that changed under the await is applied first, so its
        // invalidation drops this result.
        input(false)
        let d = SeekPreviewCompletion.decide(requestGeneration: generation, currentGeneration: requestGeneration,
                                             requestTargetSec: targetSec, currentPlan: plan,
                                             shownSec: shown?.sec)
        guard d.finishThrottle else { return }
        switch d.frame {
        case .publish: setFrame(shown, matchedTargetSec: match != nil ? targetSec : nil)
        case .clear: setFrame(nil)
        case .keep: break
        }
        publish()
        // P3: no frame, or one more than the tolerance off: the decoder may fetch the keyframe
        // (the tolerance-bounded `match`, as before BUG-181).
        if let refine = d.refineTargetSec { sink?.refine(targetSec: refine, matchSec: match?.sec) }
        handle(throttle.finished(now: now()))
        publish()
    }

    private func setFrame(_ f: SeekPreviewMatch?, matchedTargetSec: Double? = nil) {
        frame = f
        frameMatchedTargetSec = f == nil ? nil : matchedTargetSec
    }

    // MARK: Render

    private func publish() {
        let content = plan.content(frameSec: frame?.sec)
        let next = SeekPreviewRender(cardTargetSec: plan.cardTargetSec, content: content,
                                     image: content == .frame ? frame?.image : nil, frameSec: frame?.sec,
                                     capabilityAny: capability.any, kind: kind, episode: episode)
        guard next != render else { return }
        render = next
        sink?.publish(next)
    }
}
