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

    /// Every transport publish, last in its main-thread turn.
    func gestureChanged(_ g: SeekPreviewGesture) {
        guard g != gesture else { return }
        update { gesture = g }
    }

    /// A Left/Right click issued seek `generation` that lands at `targetSec` (resolved and clamped).
    func clickIssued(targetSec: Double, generation: Int) {
        update { latch.clicked(targetSec: targetSec, generation: generation, now: now()) }
    }

    /// Seek `generation` landed (newest or not).
    func seekLanded(generation: Int) {
        guard latch.active != nil else { return }
        update { latch.landed(generation: generation, now: now()) }
    }

    func seekRejected(generation: Int) {
        guard latch.active != nil else { return }
        update { latch.rejected(generation: generation) }
    }

    /// Menu / Up / Down / Select / Play on a landing card, a chapter-tab seek (review r2-4), the
    /// player going off screen: the click's card goes without a new one.
    func dismissClick() {
        guard latch.active != nil else { return }
        update { latch.clear() }
    }

    /// The engine's still source changed (mpv: once at load, and on a live reconnect's new store).
    func setSource(capability c: SeekPreviewCapability, generation: Int) {
        guard c != capability || generation != sourceGeneration else { return }
        update {
            capability = c
            sourceGeneration = generation
        }
    }

    /// The engine may have changed what `liveSource` reports (a load started or returned, a
    /// handoff): re-read it now instead of at the next input.
    func sourceMayHaveChanged() {
        guard liveSourceDiffers else { return }
        update {}
    }

    /// The source gained a frame at `atSec` (an mpv decode or harvest insert): the current target
    /// asks again if the card would accept that frame and it beats the accepted one
    /// (`SeekPreviewPlan.wantsRefresh`), through the same throttle and generation checks.
    func sourceContentChanged(atSec: Double) {
        if liveSourceDiffers { update {} }
        guard alive, plan.wantsRefresh(atSec: atSec, shownSec: frame?.sec) else { return }
        handle(throttle.sample(now: now()))
        publish()
    }

    /// The controller's teardown (`PlayerTransportInput.invalidate`): every request, frame, timer
    /// and the latch go; nothing runs after this.
    func teardown() {
        guard alive else { return }
        update { alive = false }
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

    /// One input: mutate, read the live source, fold the latch in, derive the plan, run the
    /// lifecycle's effects from the old state to the new one, re-arm the latch timer, publish.
    private func update(_ change: () -> Void) {
        let old = lifecycleKey
        change()
        if alive, let live = liveSource?() {
            capability = live.capability
            sourceGeneration = live.generation
        }
        latch.tick(now: now())
        recompute()
        apply(SeekPreviewLifecycle.effects(from: old, to: lifecycleKey))
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
        if effects.contains(.clearFrame) { frame = nil }
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
            self.update { self.latch.tick(now: max(self.now(), deadline)) }
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
                frame = nil
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
        if liveSourceDiffers { update {} }
        let d = SeekPreviewCompletion.decide(requestGeneration: generation, currentGeneration: requestGeneration,
                                             requestTargetSec: targetSec, currentPlan: plan,
                                             shownSec: shown?.sec)
        guard d.finishThrottle else { return }
        switch d.frame {
        case .publish: frame = shown
        case .clear: frame = nil
        case .keep: break
        }
        publish()
        // P3: no frame, or one more than the tolerance off: the decoder may fetch the keyframe
        // (the tolerance-bounded `match`, as before BUG-181).
        if let refine = d.refineTargetSec { sink?.refine(targetSec: refine, matchSec: match?.sec) }
        handle(throttle.finished(now: now()))
        publish()
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
