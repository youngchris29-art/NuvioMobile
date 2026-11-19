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

/// A click's card (finding 1): from the click until `max(landing, shown + minDwell)`, or the
/// fallback with no landing. Keyed to the seek generation the click issued, so an older landing
/// never ends a newer click's card and a newer seek's landing supersedes it. No clock: the caller
/// passes `now` and arms one timer for `nextDeadline`.
nonisolated struct ClickPreviewLatch: Equatable, Sendable {
    /// Long enough for a decode (0.4-0.8 s on the box) to still land on the card.
    static let minDwellSec: Double = 1.2
    /// The longest commit hand-back (`PlayerTransportInput.exactDeadlineFired`'s 4 s).
    static let fallbackSec: Double = 4.0

    struct Active: Equatable, Sendable {
        let targetSec: Double
        let generation: Int
        let shownAt: Double
        /// When the card goes: the fallback until the landing is seen, then the dwell rule.
        var deadline: Double
    }

    private(set) var active: Active?

    /// A click was issued: replaces any active latch.
    mutating func clicked(targetSec: Double, generation: Int, now: Double) {
        active = Active(targetSec: targetSec, generation: generation, shownAt: now,
                        deadline: now + Self.fallbackSec)
    }

    /// Seek `generation` landed: this click's landing ends the card once the dwell is over; a newer
    /// seek's landing supersedes the click at once; an older one is ignored.
    mutating func landed(generation: Int, now: Double) {
        guard let a = active else { return }
        if generation == a.generation {
            active?.deadline = min(a.deadline, max(now, a.shownAt + Self.minDwellSec))
        } else if generation > a.generation {
            active = nil
        }
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
