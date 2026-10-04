import Combine
import SwiftUI

// beta.19-rc1 verdict (M5, BUG-138): the hero's text never shows two payloads at once.
//
// Steven's beta.19-rc1 video: on every hero change the title, meta line and synopsis of the OLD
// hero and the NEW one were on screen together for a moment. Root cause: `HeroArtResolver.commit`
// assigns `presented` inside a 0.3 s `withAnimation`, and `HomeHeroForeground` keyed its info
// block on `.id(identity)` + `.transition(.opacity)`, so for 0.3 s two blocks cross-dissolved in
// one slot. The text is now phased instead: fade the old text OUT, swap while it is invisible, fade
// the new text IN. The artwork's own cross-fade (`HeroCrossfadeImage`) is untouched.
//
// Generic on purpose: the Stage & Strip batch (`docs/home-stage-strip-plan-2026-10-03.md`) wraps
// `TextSwapModel(timing: .stage)` in its `StageSwapModel` (450 ms pause before the fade) and drives
// its stage ART from `shown`. Nothing in this file may depend on `HomeView`; the one Home-specific
// line is the `HeroTextSwapModel` alias, and the view that owns a hero model is `HeroTextLayer`
// (`HomeView.swift`, beside `HomeHeroForeground`, whose memberwise init is file-private).

/// Timing for one text swap. Top-level rather than nested in `TextSwapModel`: a type nested in a
/// generic class is itself generic and cannot hold the stored `static let`s below (critique #25).
nonisolated struct TextSwapTiming: Equatable, Sendable {
    /// Hold before the fade-out starts; restarted by every new identity that arrives during it.
    var pause: TimeInterval
    var fadeOut: TimeInterval
    var fadeIn: TimeInterval

    /// Classic Home hero: no pause, 0.12 s out, 0.12 s in. On a warm-cache commit the art
    /// cross-fades over t0 → t0 + 0.3 while the text is out by t0 + 0.12 and back by t0 + 0.24.
    static let classic = TextSwapTiming(pause: 0, fadeOut: 0.12, fadeIn: 0.12)
    /// Stage & Strip plan's numbers (official NuvioTV's `MODERN_HERO_FOCUS_DEBOUNCE_MS` = 450).
    static let stage = TextSwapTiming(pause: 0.45, fadeOut: 0.15, fadeIn: 0.20)
}

/// Where a `TextSwapModel` is in its swap. Top-level for the same reason as `TextSwapTiming`.
nonisolated enum TextSwapPhase: String, Equatable, Sendable {
    case idle, pausing, fadingOut, fadingIn

    /// Short spelling for the DEBUG `debug_heroText` label (`phase=idle|pause|out|in`).
    var token: String {
        switch self {
        case .idle: return "idle"
        case .pausing: return "pause"
        case .fadingOut: return "out"
        case .fadingIn: return "in"
        }
    }
}

/// beta.19-rc1 verdict (M5, BUG-138): a text block that never shows two payloads at once: fade OUT,
/// swap while invisible, fade IN.
///
/// **How a host renders it** (the contract the Stage batch also follows): read `shown ?? <live
/// payload>`, key the text block's `.id` on `shown`'s identity with `.transition(.identity)`, and
/// apply the opacity OUTSIDE that `.id`, through a scoped animation:
///
///     block.id(identity).transition(.identity)
///          .animation(model.opacityAnimation) { $0.opacity(model.textOpacity) }
///
/// Why the scoped `.animation(_:body:)` and not `withAnimation` around the writes: this is an
/// `ObservableObject`, so a body re-evaluation reads the LIVE values, not a per-transaction
/// snapshot. The swap changes `shown` and starts the fade-in in the same turn; under one animated
/// transaction the `.id` change would animate too (the removed block lingers through the fade-in,
/// i.e. two titles again), and splitting it into a non-animated swap plus an animated fade-in in the
/// same turn is not reliable either (the re-render reads opacity 1 already, under whichever
/// transaction SwiftUI picks). So every write here runs in a fresh, animation-free transaction (an
/// ambient one inherited through `.onChange` is dropped too), the `.id` change is a hard cut, and
/// only the opacity modifier animates, with the curve `opacityAnimation` names.
///
/// `receive` rules (all unit-tested, `HeroTextSwapModelTests`):
/// - `nil` → cleared at once, opacity 1, `.idle`.
/// - nothing shown yet → shown at once, no animation.
/// - same identity as `shown` → silent gap-fill: `shown` updated with no animation, a pending swap
///   dropped, hidden text faded back in. This covers spec B's post-commit hero sharpen (a
///   same-identity backdrop upgrade never touches the text).
/// - Reduce Motion → instant swap.
/// - `.idle`: pause > 0 → `.pausing`; else fade out now.
/// - `.pausing`: retarget, restart the pause.
/// - `.fadingOut`: retarget. With a pause the swap is cancelled and the pause restarts (the text
///   stays hidden); with none the scheduled swap takes the newest payload.
/// - `.fadingIn`: fade out again from the current opacity (full `fadeOut`), then as above.
@MainActor
final class TextSwapModel<Payload: Equatable>: ObservableObject {
    typealias Timing = TextSwapTiming
    typealias Phase = TextSwapPhase
    /// Runs `work` after `after` seconds; cancelling the returned token drops it. Injected so the
    /// unit tests drive a fake clock.
    typealias Schedule = @MainActor (_ after: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AnyCancellable

    /// The production schedule. A static FUNC, not a stored static: generic types cannot hold stored
    /// statics (critique #25).
    static func mainQueueSchedule(_ after: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, after), execute: item)
        return AnyCancellable { item.cancel() }
    }

    /// The payload the text block draws. nil until the first `seed`/`receive`; the host falls back
    /// to its live payload for that first frame.
    @Published private(set) var shown: Payload?
    /// The text block's opacity. Render through `opacityAnimation` (see the type doc).
    @Published private(set) var textOpacity: Double = 1
    /// The curve the host's scoped animation applies to the latest `textOpacity` change: ease-out
    /// over `fadeOut` toward 0, ease-in over `fadeIn` toward 1, nil for an instant change (seed,
    /// Reduce Motion, clear). Not published: it is only ever written together with `textOpacity`,
    /// so a render that sees the new opacity sees the matching curve.
    private(set) var opacityAnimation: Animation?
    private(set) var phase: Phase = .idle
    /// The payload waiting for the swap moment.
    private(set) var pending: Payload?
    /// Identity changes actually swapped in (instant Reduce Motion swaps included).
    private(set) var swaps = 0

    let timing: Timing
    private let identity: (Payload) -> String
    private let schedule: Schedule
    /// The one step in flight (pause end, swap, or fade-in end). Replaced, never stacked.
    private var scheduled: AnyCancellable?

    init(timing: Timing, identity: @escaping (Payload) -> String, schedule: Schedule? = nil) {
        self.timing = timing
        self.identity = identity
        self.schedule = schedule ?? { after, work in TextSwapModel.mainQueueSchedule(after, work) }
    }

    /// The host's first payload (its `.onAppear`): shown at once, nothing in flight.
    func seed(_ payload: Payload?) {
        cancelScheduled()
        pending = nil
        phase = .idle
        mutate {
            setShown(payload)
            setOpacity(1, animation: nil)
        }
    }

    func receive(_ next: Payload?, reduceMotion: Bool) {
        guard let next else {
            cancelScheduled()
            pending = nil
            phase = .idle
            mutate {
                setShown(nil)
                setOpacity(1, animation: nil)
            }
            return
        }
        guard let current = shown else {
            cancelScheduled()
            pending = nil
            phase = .idle
            mutate {
                setShown(next)
                setOpacity(1, animation: nil)
            }
            return
        }

        if identity(next) == identity(current) {
            // Silent gap-fill (a late synopsis, a sharpened backdrop): the text block keeps its
            // identity, so this is a content refresh with no motion. A swap that was on its way to
            // another payload is dropped: the target came back to what is on screen.
            pending = nil
            switch phase {
            case .idle, .fadingIn:
                mutate { setShown(next) }
            case .pausing, .fadingOut:
                cancelScheduled()
                phase = .idle
                mutate {
                    setShown(next)
                    // Hidden (or on its way out): bring it back. Visible: nothing to animate.
                    if textOpacity < 1 { setOpacity(1, animation: .easeIn(duration: timing.fadeIn)) }
                }
            }
            return
        }

        if reduceMotion {
            cancelScheduled()
            pending = nil
            phase = .idle
            swaps += 1
            mutate {
                setShown(next)
                setOpacity(1, animation: nil)
            }
            return
        }

        pending = next
        switch phase {
        case .idle:
            if timing.pause > 0 { startPause() } else { beginFadeOut() }
        case .pausing:
            startPause()
        case .fadingOut:
            // With a pause the text stays hidden and the pause restarts; with none the swap
            // already scheduled takes the newest payload.
            if timing.pause > 0 { startPause() }
        case .fadingIn:
            beginFadeOut()
        }
    }

    // MARK: - Steps

    private func startPause() {
        cancelScheduled()
        phase = .pausing
        scheduled = schedule(timing.pause) { [weak self] in self?.beginFadeOut() }
    }

    private func beginFadeOut() {
        cancelScheduled()
        guard pending != nil else {
            // Nothing left to swap to (cannot happen through `receive`, kept total).
            phase = .idle
            mutate { setOpacity(1, animation: .easeIn(duration: timing.fadeIn)) }
            return
        }
        // Already hidden: a fade-out that a pause interrupted finished long ago (the pause is
        // longer than any fade-out), so there is nothing to fade.
        if textOpacity == 0 {
            performSwap()
            return
        }
        phase = .fadingOut
        mutate { setOpacity(0, animation: .easeOut(duration: timing.fadeOut)) }
        scheduled = schedule(timing.fadeOut) { [weak self] in self?.performSwap() }
    }

    private func performSwap() {
        cancelScheduled()
        guard let next = pending else {
            phase = .idle
            mutate { setOpacity(1, animation: .easeIn(duration: timing.fadeIn)) }
            return
        }
        pending = nil
        swaps += 1
        phase = .fadingIn
        // One animation-free transaction: the `.id` change is a hard cut while the text is
        // invisible, and only the host's scoped opacity animation runs (see the type doc).
        mutate {
            setShown(next)
            setOpacity(1, animation: .easeIn(duration: timing.fadeIn))
        }
        scheduled = schedule(timing.fadeIn) { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            self.phase = .idle
        }
    }

    // MARK: - Writes

    private func cancelScheduled() {
        scheduled?.cancel()
        scheduled = nil
    }

    /// Every published write runs in a fresh transaction: no ambient animation (e.g. the hero
    /// commit's 0.3 s `withAnimation`, inherited through the host's `.onChange`) reaches the text.
    private func mutate(_ body: () -> Void) {
        withTransaction(Transaction(), body)
    }

    private func setShown(_ payload: Payload?) {
        if shown != payload { shown = payload }
    }

    private func setOpacity(_ value: Double, animation: Animation?) {
        opacityAnimation = animation
        if textOpacity != value { textOpacity = value }
    }

    #if DEBUG
    /// `phase=<idle|pause|out|in> shown=<id|-> pending=<id|-> swaps=N` — the host appends its own
    /// fields (Home's `HeroTextLayer` appends `maxLive=`).
    var debugLine: String {
        "phase=\(phase.token) shown=\(shown.map(identity) ?? "-") pending=\(pending.map(identity) ?? "-") swaps=\(swaps)"
    }
    #endif
}

/// The Home hero's text model (`HeroTextLayer`).
typealias HeroTextSwapModel = TextSwapModel<HeroPresentation>

#if DEBUG
/// beta.19-rc1 verdict (M5, critique #8): the real "two titles at once" oracle. The hero's info
/// block calls `appear()` from `.onAppear` and `disappear()` from `.onDisappear`, INSIDE its `.id`,
/// so every re-identification counts. SwiftUI calls `.onDisappear` only once a removal (and any
/// transition it runs) has finished, so a block that lingers while its successor is already on
/// screen raises `max` to 2; a clean swap keeps it at 1. Read by `debug_heroText … maxLive=`
/// (test89). Process-lifetime; DEBUG only.
enum HeroInfoLiveCounter {
    private(set) static var live = 0
    private(set) static var max = 0

    static func appear() {
        live += 1
        max = Swift.max(max, live)
    }

    static func disappear() {
        live = Swift.max(0, live - 1)
    }

    static func resetForTesting() {
        live = 0
        max = 0
    }
}
#endif
