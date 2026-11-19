import Foundation
import CoreGraphics

// GitHub #33: the seek preview card on skips (clicks, holds, swipe scrub), one decision for both
// engines. Everything in this file is pure: no UIKit, no engine, no clock of its own.
// `SeekPreviewCoordinator` owns the state these types decide over and executes their effects.

// MARK: - Gesture

/// What the remote is doing, as far as the preview card cares. `TransportPreview.previewGesture`
/// maps the transport mode to this; the coordinator turns `.none` / `.pending` into `.landing`
/// while a click's latch is active.
nonisolated enum SeekPreviewGesture: Equatable, Sendable {
    /// Idle, or a hold / scrub commit waiting to land.
    case none
    /// A key is down but is not a hold yet (a Step press before its first tick, a scan-armed or a
    /// chapter-click press): no new request; an earlier click's card stays.
    case pending
    case hold(targetSec: Double)
    case scrub(targetSec: Double)
    /// 2x and up: the video itself is the moving preview, no card.
    case scan
    /// A click's card at its resolved, clamped seek target (`ClickPreviewLatch`).
    case landing(targetSec: Double, generation: Int)
}

// MARK: - Capability

/// What the engine's still source can fill for this playback: ground already played (mpv harvest,
/// Aether's loaded video) and ground not played yet (mpv keyframe decode, Aether's loaded video).
nonisolated struct SeekPreviewCapability: Equatable, Sendable {
    var fillsWatched: Bool
    var fillsUnwatched: Bool

    static let none = Self(fillsWatched: false, fillsUnwatched: false)

    var any: Bool { fillsWatched || fillsUnwatched }

    /// mpv: watched ground needs the mode's harvest and a running harvest interval (after the crash,
    /// simulator and synthetic rules, `SeekPreviewHarvestResolution`); unwatched ground is the
    /// decoder's. Off is `.none` whatever the interval (the DEBUG synthetic harvest included).
    static func mpv(mode: SeekPreviewMode, effectiveHarvestIntervalSec: Double) -> Self {
        Self(fillsWatched: mode.allowsHarvest && effectiveHarvestIntervalSec > 0,
             fillsUnwatched: mode.allowsDecode)
    }

    /// Aether: its stills come from video it already loaded, so Watched Parts and Whole Video are
    /// the same there; Off is `.none` (no still source at all).
    static func aether(mode: SeekPreviewMode, supportsStills: Bool) -> Self {
        guard mode != .off else { return .none }
        return Self(fillsWatched: supportsStills, fillsUnwatched: supportsStills)
    }
}

/// The one owner of the mpv harvest interval (it used to be four rules applied in sequence in the
/// controller): the DEBUG synthetic source bypasses the crash sentinel and the simulator (it never
/// calls `screenshot-raw`); otherwise either turns the harvest off. The mode is applied after this,
/// by `SeekPreviewCapability.mpv`, so Off still wins over a synthetic harvest.
nonisolated enum SeekPreviewHarvestResolution {
    /// `setting`: the parsed `debug.harvestIntervalSec` (`HarvestScheduler.interval(fromSetting:)`).
    static func effectiveIntervalSec(setting: Double, sentinelDisabled: Bool, synthetic: Bool,
                                     isSimulator: Bool) -> Double {
        if synthetic { return setting }
        if sentinelDisabled || isSimulator { return 0 }
        return setting
    }
}

// MARK: - Plan

/// The one decision every consumer reads: where to look a frame up, where to draw the card, and
/// whether a dark placeholder may stand in for a missing picture.
nonisolated struct SeekPreviewPlan: Equatable, Sendable {
    /// Where the coordinator asks the source for a frame; nil = no lookups.
    let requestTargetSec: Double?
    /// Where the bar draws the card (and the chapter title); nil = no card.
    let cardTargetSec: Double?
    /// BUG-181's rule, stated once: a placeholder only when something can fill the card.
    let placeholderAllowed: Bool

    static let none = Self(requestTargetSec: nil, cardTargetSec: nil, placeholderAllowed: false)

    /// A frame up to this far from the target may show (`SeekPreviewStore`'s nearest reach). A
    /// 60 s/tick hold ramp or a fast scrub can show a frame that far back; that is BUG-181's reach,
    /// kept so a sparse Dolby Vision store still shows something. It also bounds Aether's
    /// unbounded `nearest`.
    static let acceptReachSec: Double = 120

    static func decide(_ gesture: SeekPreviewGesture, _ capability: SeekPreviewCapability) -> Self {
        let any = capability.any
        switch gesture {
        case .none, .pending, .scan:
            return Self(requestTargetSec: nil, cardTargetSec: nil, placeholderAllowed: any)
        case .landing(let t, _), .scrub(let t):
            // No capability: the time (and chapter title) over the landing point, like today's scrub.
            return Self(requestTargetSec: any ? t : nil, cardTargetSec: t, placeholderAllowed: any)
        case .hold(let t):
            // No capability: nothing (the track's own preview head already shows the time).
            return any ? Self(requestTargetSec: t, cardTargetSec: t, placeholderAllowed: true)
                       : Self(requestTargetSec: nil, cardTargetSec: nil, placeholderAllowed: false)
        }
    }

    enum Content: Equatable, Sendable {
        case frame, placeholder, timeOnly, none

        /// The probe's `card=` letter.
        var probeCode: String {
            switch self {
            case .frame: return "f"
            case .placeholder: return "p"
            case .timeOnly: return "t"
            case .none: return "n"
            }
        }
    }

    /// What the card shows given the accepted frame's stamp: a frame only within reach of the card
    /// target (a stale frame is hidden, never drawn), else the placeholder when allowed.
    func content(frameSec: Double?) -> Content {
        guard let card = cardTargetSec else { return .none }
        if let f = frameSec, f.isFinite, abs(f - card) <= Self.acceptReachSec { return .frame }
        return placeholderAllowed ? .placeholder : .timeOnly
    }

    /// The source gained a frame at `atSec` (a decode or a harvest insert): the current target
    /// wants a fresh lookup when that frame is one the card would accept (within `acceptReachSec`,
    /// not just the store's lookup tolerance, review r1-1) and it improves what is shown: no
    /// accepted frame within reach yet (`shownSec` nil, not finite or out of reach), or the new frame
    /// is strictly closer to the target than the accepted one. A stationary hold, scrub or landing
    /// card turns from placeholder to picture this way; a pre-warm insert far off, or no closer than
    /// the current frame, causes no lookup.
    func wantsRefresh(atSec: Double, shownSec: Double?) -> Bool {
        guard let t = requestTargetSec, atSec.isFinite else { return false }
        let distance = abs(atSec - t)
        guard distance <= Self.acceptReachSec else { return false }
        guard let s = shownSec, s.isFinite, abs(s - t) <= Self.acceptReachSec else { return true }
        return distance < abs(s - t)
    }
}

// MARK: - Click latch

/// A click's card (finding 1): from the click until its own landing ends it at
/// `max(shown + minDwell, landed + postLandingDwell)`, or the fallback (`shown + fallback`) with no
/// landing. The post-landing dwell (review r7) gives a slow seek (Aether into an uncached segment,
/// mpv whose thumbnail jobs wait for the seek in flight) time for the landing retry
/// (`SeekPreviewLifecycle.landingEffects`) to find and publish the now-resident picture before the
/// card goes. Bound: a landing is only accepted before the fallback, so a card lives at most
/// `fallbackSec + postLandingDwellSec` (4.8 s) after it was shown, and exactly `fallbackSec` when
/// its seek never lands. Only the first own landing moves the deadline; a repeated report never
/// extends it. Keyed to the seek generation the click issued, so an older landing never ends a
/// newer click's card and a newer seek's landing supersedes it. A newer click, a rejection and
/// `clear` (hold, scrub, scan, key dismissals) end it at once. No clock: the caller passes `now`
/// and arms one timer for `nextDeadline`.
nonisolated struct ClickPreviewLatch: Equatable, Sendable {
    /// Long enough for a decode (0.4-0.8 s on the box) to still land on the card.
    static let minDwellSec: Double = 1.2
    /// The longest commit hand-back (`PlayerTransportInput.exactDeadlineFired`'s 4 s).
    static let fallbackSec: Double = 4.0
    /// After the click's own landing: room for the landing retry's lookup (the throttle's 66 ms
    /// floor plus a store read, or a decode of 0.4-0.8 s on the box) to land on the card.
    static let postLandingDwellSec: Double = 0.8

    struct Active: Equatable, Sendable {
        let targetSec: Double
        let generation: Int
        let shownAt: Double
        /// When the card goes: the fallback until the landing is seen, then the dwell rule.
        var deadline: Double
        /// When the click's own seek landed; nil until then.
        var landedAt: Double?
    }

    private(set) var active: Active?

    /// A click was issued: replaces any active latch.
    mutating func clicked(targetSec: Double, generation: Int, now: Double) {
        active = Active(targetSec: targetSec, generation: generation, shownAt: now,
                        deadline: now + Self.fallbackSec, landedAt: nil)
    }

    /// What a landing report did to the latch (review r5: the coordinator asks for the click's
    /// picture again on its own landing, `SeekPreviewLifecycle.landingEffects`).
    enum Landing: Equatable, Sendable {
        /// No click, or an older seek's landing: nothing changed.
        case ignored
        /// The click's own seek landed: the deadline moved to the dwell rule (first report only).
        case own
        /// A newer seek landed: the click's card went.
        case superseded
    }

    /// Seek `generation` landed: this click's landing ends the card at
    /// `max(shown + minDwell, landed + postLandingDwell)`; a newer seek's landing supersedes the
    /// click at once; an older one is ignored. A card already past its deadline (the fallback ran
    /// out before the report) goes, and the report is ignored.
    @discardableResult
    mutating func landed(generation: Int, now: Double) -> Landing {
        tick(now: now)
        guard let a = active else { return .ignored }
        if generation == a.generation {
            if a.landedAt == nil {
                active?.landedAt = now
                active?.deadline = max(a.shownAt + Self.minDwellSec, now + Self.postLandingDwellSec)
            }
            return .own
        } else if generation > a.generation {
            active = nil
            return .superseded
        }
        return .ignored
    }

    /// Seek `generation` was refused: this click's card goes; another generation's refusal is ignored.
    mutating func rejected(generation: Int) {
        if active?.generation == generation { active = nil }
    }

    mutating func tick(now: Double) {
        if let a = active, now >= a.deadline { active = nil }
    }

    /// Hold, scrub, scan, Menu / Up / Down / Select / Play, a chapter-tab seek, teardown.
    mutating func clear() { active = nil }

    var nextDeadline: Double? { active?.deadline }
}

// MARK: - Click landing

/// How an engine turns a Left/Right click into a landing point (review r3 P2 #1). The two engines
/// differ at the end of the file, so the landing decision takes this as an input.
nonisolated enum SeekLandingSemantics: Equatable, Sendable {
    /// mpv: the click goes to mpv as `seek <delta> relative`, and mpv adds the delta to its own
    /// playback time. While an earlier seek is still in flight that time is the earlier seek's
    /// target clamped to [0, duration] (`mp_seek` stores the target in `last_seek_pts`;
    /// `get_playback_time` clamps it, and never returns less than 0). A seek before 0 lands on the
    /// start; a seek past the end runs into the end of the file (keep-open: the last frame), so
    /// the upper bound is the duration itself.
    case mpvRelative
    /// Aether: the transport sends an absolute target and the engine clamps it to
    /// [0, duration - 0.5] (`AetherSeekPlan.clamp`: a seek onto the last frame would end the file).
    case aetherAbsolute

    /// How far before the end the engine stops a click.
    var endMarginSec: Double {
        switch self {
        case .mpvRelative: return 0
        case .aetherAbsolute: return 0.5
        }
    }
}

/// The one decision for where a Left/Right click lands (review r2 P2 #1, r3 P2 #1). It returns,
/// from one clamped value, both what the engine records as the click's in-flight target (the base
/// the next click starts from) and where the card goes, so the two can never disagree and the
/// recorded target never leaves the file. Nil for both when the landing cannot be known: a
/// relative click while a seek with an unknown target is in flight (mpv's percentage resume), or
/// a forward click with no known duration (the file may end first). The seek itself is still
/// issued then, and the engine resolves it on its own.
enum ClickLanding {
    /// The seek the skip planner holds in flight when the click is pressed.
    enum InFlight: Equatable, Sendable {
        case none
        case target(Double)
        case unknownTarget

        init(hasSeekInFlight: Bool, targetSec: Double?) {
            if !hasSeekInFlight {
                self = .none
            } else if let targetSec, targetSec.isFinite {
                self = .target(targetSec)
            } else {
                self = .unknownTarget
            }
        }
    }

    struct Outcome: Equatable, Sendable {
        /// The in-flight target the engine records for this click's seek; nil = unknown.
        let recordedTargetSec: Double?
        /// Where the card goes; nil = no card. Always equal to `recordedTargetSec`.
        let cardTargetSec: Double?
        /// The position the click starts from (the planner's `fromSec`); nil = unknown.
        let fromSec: Double?

        fileprivate init(landingSec: Double?, fromSec: Double?) {
            recordedTargetSec = landingSec
            cardTargetSec = landingSec
            self.fromSec = fromSec
        }
    }

    /// Where the engine stands for the next seek: the cached position when nothing is in flight,
    /// else the in-flight target clamped the way mpv clamps its playback time during a seek
    /// ([0, duration], or >= 0 with no known duration); nil when that target is unknown or the
    /// numbers are not finite.
    static func base(positionSec: Double, inFlight: InFlight, durationSec: Double) -> Double? {
        switch inFlight {
        case .none:
            return positionSec.isFinite ? positionSec : nil
        case .unknownTarget:
            return nil
        case .target(let t):
            guard t.isFinite else { return nil }
            return durationKnown(durationSec) ? min(max(t, 0), durationSec) : max(t, 0)
        }
    }

    /// The starting point for gestures that need a number even when the base is unknown: a hold
    /// or scrub origin and the chapter choice (their seeks are absolute, so an unknown base only
    /// moves where the preview starts), a chapter seek's `fromSec`. The base, else the cached
    /// position.
    static func originSec(positionSec: Double, inFlight: InFlight, durationSec: Double) -> Double {
        base(positionSec: positionSec, inFlight: inFlight, durationSec: durationSec)
            ?? (positionSec.isFinite ? max(positionSec, 0) : 0)
    }

    /// The landing of `action` pressed now. A relative click lands at base + delta; a chapter jump
    /// at the chapter start (`PlayerChapters.clampedSeek`, known whatever the base: it is a point
    /// in the file). Then the engine's own clamp, once, here.
    static func decide(_ action: EdgeClickAction, positionSec: Double, inFlight: InFlight,
                       durationSec: Double, semantics: SeekLandingSemantics) -> Outcome {
        let from = base(positionSec: positionSec, inFlight: inFlight, durationSec: durationSec)
        let raw: Double
        switch action {
        case .absolute(let sec):
            guard sec.isFinite else { return Outcome(landingSec: nil, fromSec: from) }
            raw = PlayerChapters.clampedSeek(sec, durationSec: durationSec)
        case .relative(let delta):
            guard let from, delta.isFinite else { return Outcome(landingSec: nil, fromSec: from) }
            // A forward click with no known end may run past it: where it stops is unknown.
            if delta > 0, !durationKnown(durationSec) { return Outcome(landingSec: nil, fromSec: from) }
            raw = from + delta
        }
        return Outcome(landingSec: clamp(raw, durationSec: durationSec, semantics: semantics), fromSec: from)
    }

    /// [0, duration - the engine's end margin] once the duration is known, else >= 0. A file
    /// shorter than the margin pins to 0: `AetherSeekPlan.clamp` would not bound it at all, and
    /// re-clamping this value there leaves it as it is, so the engine still sends it.
    static func clamp(_ sec: Double, durationSec: Double, semantics: SeekLandingSemantics) -> Double {
        guard durationKnown(durationSec) else { return max(sec, 0) }
        return min(max(sec, 0), max(durationSec - semantics.endMarginSec, 0))
    }

    private static func durationKnown(_ durationSec: Double) -> Bool {
        durationSec.isFinite && durationSec > 0
    }
}

// MARK: - Preview-request lifecycle

/// Finding 4 / R2-2: the preview-request side (request generation, throttle, accepted frame,
/// decoder) is cleaned up by composed rules over (old, new); the scrub-gesture side stays on the
/// real scrub exit in `PlayerTransportInput.publishTransport`.
nonisolated enum SeekPreviewLifecycle {
    struct Key: Equatable, Sendable {
        var requestTargetSec: Double?
        var capability: SeekPreviewCapability
        var sourceGeneration: Int
        var alive: Bool
    }

    struct Effects: OptionSet, Equatable, Sendable {
        let rawValue: Int
        /// The request generation moves: a lookup still running is dropped when it returns.
        static let invalidate = Effects(rawValue: 1 << 0)
        static let resetThrottle = Effects(rawValue: 1 << 1)
        static let clearFrame = Effects(rawValue: 1 << 2)
        /// The engine's own preview work stops (mpv: the keyframe thumbnailer's pending miss).
        static let endDecoderActivity = Effects(rawValue: 1 << 3)
        /// A throttled lookup for the final target.
        static let requestNow = Effects(rawValue: 1 << 4)
        static let clearLatch = Effects(rawValue: 1 << 5)

        static let cleanup: Effects = [.invalidate, .resetThrottle, .clearFrame, .endDecoderActivity]
    }

    /// Independent predicates, not a first match: a source change, a capability loss and a target
    /// exit each clean up whatever else changed in the same update; `requestNow` is then decided
    /// from the final state. Teardown dominates: all cleanup, never a request.
    static func effects(from old: Key, to new: Key) -> Effects {
        guard new.alive else { return old.alive ? Effects.cleanup.union(.clearLatch) : [] }
        let sourceChanged = old.sourceGeneration != new.sourceGeneration
        let capabilityLost = (old.capability.any && !new.capability.any)
            || (old.capability.fillsUnwatched && !new.capability.fillsUnwatched)
        let capabilityGained = (!old.capability.any && new.capability.any)
            || (!old.capability.fillsUnwatched && new.capability.fillsUnwatched)
        let targetExit = old.requestTargetSec != nil && new.requestTargetSec == nil
        let cleanup = sourceChanged || capabilityLost || targetExit
        var out: Effects = cleanup ? .cleanup : []
        if new.requestTargetSec != nil,
           cleanup || capabilityGained || old.requestTargetSec != new.requestTargetSec {
            out.insert(.requestNow)
        }
        return out
    }

    /// Review r5: a click's own seek landed. Aether's still cache fills only once the seek's
    /// segments are resident, and it has no content-change event, so a lookup that missed when the
    /// seek was issued would never be asked again. On the latch's own landing (never an older or a
    /// newer seek's) the current target asks once more through the throttle, under the same rule
    /// as a content-change refresh: only when it could improve the card, that is when no frame the
    /// source returned as its tolerance-bounded match for this target is accepted
    /// (`matchedTargetSec`: the target the accepted frame matched, nil for none or for the
    /// `nearest` fallback). Evaluated on the state after the landing, so a landing that ends the
    /// dwell (no request target left) asks nothing. The latch and its deadline are not touched:
    /// the landing already gave the card `ClickPreviewLatch.postLandingDwellSec` for this lookup.
    static func landingEffects(_ landing: ClickPreviewLatch.Landing, plan: SeekPreviewPlan,
                               matchedTargetSec: Double?) -> Effects {
        guard landing == .own, let t = plan.requestTargetSec, matchedTargetSec != t else { return [] }
        return .requestNow
    }
}

// MARK: - Completion

/// Finding 5 / R2-5: what a returned lookup may do. The coordinator runs the outcome in this
/// order: publish or clear, then the refinement (while its target is still the current one), then
/// the throttle's `finished` and its trailing decision.
nonisolated enum SeekPreviewCompletion {
    enum FrameAction: Equatable, Sendable {
        /// Leave the accepted frame as it is (the render hides it if it is stale).
        case keep
        /// Accept the returned frame.
        case publish
        /// BUG-181: a finished lookup with nothing near shows the placeholder.
        case clear
    }

    struct Decision: Equatable, Sendable {
        var frame: FrameAction
        /// False only for a stale generation: the throttle was reset when the generation moved,
        /// and a stale `finished` would start a lookup out of turn.
        var finishThrottle: Bool
        /// Ask the engine's decoder for this target (nil = no refinement).
        var refineTargetSec: Double?

        static let stale = Decision(frame: .keep, finishThrottle: false, refineTargetSec: nil)
    }

    static func decide(requestGeneration: Int, currentGeneration: Int, requestTargetSec: Double,
                       currentPlan: SeekPreviewPlan, shownSec: Double?) -> Decision {
        guard requestGeneration == currentGeneration else { return .stale }
        guard let current = currentPlan.requestTargetSec else {
            return Decision(frame: .keep, finishThrottle: true, refineTargetSec: nil)
        }
        let sameTarget = requestTargetSec == current
        let frame: FrameAction
        if let s = shownSec {
            frame = s.isFinite && abs(s - current) <= SeekPreviewPlan.acceptReachSec ? .publish : .keep
        } else {
            frame = sameTarget ? .clear : .keep
        }
        // The thumbnailer is never sent to an obsolete target: the trailing lookup refines the new one.
        return Decision(frame: frame, finishThrottle: true, refineTargetSec: sameTarget ? requestTargetSec : nil)
    }
}

// MARK: - Render

/// The one snapshot the bar draws as-is (`TransportBarModel.previewRender`), written only by the
/// coordinator in the same main-thread turn as the transport's `mode` / `previewSec`.
nonisolated struct SeekPreviewRender: Equatable, @unchecked Sendable {
    /// Which gesture the card belongs to (the DEBUG probe counts holds and clicks by it).
    enum Kind: Equatable, Sendable { case none, hold, scrub, landing }

    var cardTargetSec: Double?
    var content: SeekPreviewPlan.Content
    /// Non-nil only for `.frame`.
    var image: CGImage?
    /// The accepted frame's stamp (probe `fsec=`), nil when none is held.
    var frameSec: Double?
    /// The source can fill the card for this playback (probe `cap=`).
    var capabilityAny: Bool
    var kind: Kind
    /// Bumped for every new hold, scrub and click, so the probe can count each one once.
    var episode: Int

    static let none = Self(cardTargetSec: nil, content: .none, image: nil, frameSec: nil,
                           capabilityAny: false, kind: .none, episode: 0)

    var cardShown: Bool { content == .frame || content == .placeholder }

    static func == (a: Self, b: Self) -> Bool {
        a.cardTargetSec == b.cardTargetSec && a.content == b.content && a.image === b.image
            && a.frameSec == b.frameSec && a.capabilityAny == b.capabilityAny && a.kind == b.kind
            && a.episode == b.episode
    }
}
