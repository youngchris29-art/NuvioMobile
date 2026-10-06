import Foundation
import SharedCore

/// One skip-segment policy for both player engines (tvOS half of upstream cbe4dc0a..77ce8a73:
/// IntroDB movie segments + unified skip controls). Pure value type — no UIKit/SwiftUI state, no
/// clock of its own (callers pass `now`); each engine owns one, feeds it the fetched intervals, its
/// seeks and its position ticks, and renders the answer with its existing chip (mpv:
/// `PlayerActionChip`; AVPlayer: a contextual action).
///
/// Rules (upstream `PlayerScreenRuntimeEffects` / `SkipIntroButton`, shared semantics in
/// `features/player/skip/`):
///  - The chip is offered for the interval the playhead is in, when that interval has an internal
///    skip action — so never for a `post-credits` interval (kept in the list only as a skip target
///    and for the up-next hold). The last second is excluded so the chip leaves cleanly (tvOS rule).
///  - The seek target is `internalSkipAction(...).targetMs`: "Skip Credits" lands on the start of a
///    following post-credits scene when there is one.
///  - Auto-skip fires ONCE per interval per playback, only for selected segment types, only while
///    playing, and never for an interval the user entered deliberately (a user seek whose start or
///    end lies inside it, or the resume seek landing inside it).
///
/// Seeks are an explicit state machine, `idle` ⇄ `seeking`. The engine calls `beginSeek` right
/// before it issues ANY seek and `seekCompleted` when the ENGINE confirms the seek finished (mpv:
/// `MPV_EVENT_PLAYBACK_RESTART`; AVPlayer: the seek's completion), with the real position. While
/// seeking, the reported position is not trusted: no chip, no auto-skip. Nothing is inferred from
/// reported positions except the post-timeout stale guard and the AVPlayer scrub detector.
struct SkipSegmentPlanner {
    /// What the engine should do on this tick.
    struct Decision: Equatable {
        /// Chip to show (nil = none). Its `targetSec` is already clamped for the engine.
        var prompt: SkipPrompt?
        /// Seek here now (auto-skip); nil = no auto-skip this tick.
        var autoSkipTargetSec: Double?
    }

    enum SeekKind: Equatable {
        /// The resume seek at playback start: an interval it lands in counts as deliberately entered.
        case resume
        /// "Play Again": re-arms every interval (done in `beginSeek`).
        case replay
        /// The planner's own auto-skip.
        case auto
        /// The user pressed the skip chip.
        case chip
        /// A user seek (arrow, scrub, transport skip): its start and landing count as deliberate.
        case user
    }

    struct Seek: Equatable {
        let kind: SeekKind
        /// Where the seek is going, when known (nil: mpv percentage resume with unknown duration).
        let targetSec: Double?
        /// `.user` only: where the gesture started (nil = unknown; only the landing is then used).
        let fromSec: Double?
        let startedAt: TimeInterval
    }

    enum SeekState: Equatable {
        case idle
        case seeking(Seek)
    }

    /// No engine confirmation after this long: the seek is abandoned (see `evaluate`).
    static let seekTimeoutSec: TimeInterval = 10
    /// An abandoned seek's late confirmation still counts within this window from its start.
    static let lateCompletionWindowSec: TimeInterval = 60
    /// After an abandoned seek, ticks within this distance of the last pre-timeout position are
    /// treated as the leftover of the seek that never confirmed.
    static let staleTolerance: Double = 1
    /// AVPlayer: a position jump larger than this between ticks, with no app seek involved, is a
    /// user scrub (the system transport's scrubs are otherwise invisible). Same rule as the stall budget.
    static let userJumpThresholdSec: Double = 10

    /// The full fetched list, `post-credits` intervals included.
    private(set) var intervals: [SkipInterval] = []
    private(set) var seekState: SeekState = .idle
    /// Indices into `intervals` that must not auto-skip (already skipped, or entered deliberately).
    private var consumed = Set<Int>()
    /// Every deliberate entry so far (ms). Re-applied when the intervals arrive after the seek.
    private var deliberateSeeks: [(fromMs: Int64, toMs: Int64)] = []
    /// The interval just skipped (auto or chip): no chip for it until the playhead has left it
    /// once, so a pre-seek position doesn't flash the chip (upstream dismisses it after a skip).
    private var chipSuppressedIndex: Int?
    /// Interval behind the chip returned by the last `evaluate` (what a chip press skips).
    private var promptIndex: Int?
    /// Position reported by the previous tick.
    private var lastTickPositionSec: Double?
    /// Set when a seek times out: the last position seen before the timeout. Ticks within
    /// `staleTolerance` of it produce nothing; the first different position clears it. A POSITION,
    /// not an interval, so it survives `setIntervals`.
    private var stalePositionSec: Double?
    /// The seek that timed out, kept so a late engine confirmation is still applied.
    private var abandonedSeek: Seek?
    /// An app seek completed since the last `observeTick` (AVPlayer scrub detector).
    private var seekCompletedSinceLastObservedTick = false

    /// Official `SkipIntroVisibilityRules`: the chip hides this long after it appeared.
    static let chipAutoHideSec: TimeInterval = 10
    /// mpv sets this true (it can bring the chip back on a press); the native engine keeps it false.
    var autoHidesChip = false
    private var chipShown: (index: Int, since: TimeInterval)?
    private var chipHiddenIndex: Int?

    /// The seek currently in flight, if any.
    var seekInFlight: Seek? {
        if case .seeking(let seek) = seekState { return seek }
        return nil
    }

    // MARK: - Inputs

    mutating func setIntervals(_ newIntervals: [SkipInterval]) {
        intervals = newIntervals
        consumed = []
        promptIndex = nil
        for seek in deliberateSeeks { markDeliberate(fromMs: seek.fromMs, toMs: seek.toMs) }
    }

    /// Call immediately BEFORE the engine issues a seek. The latest seek wins: a new one replaces
    /// any seek still in flight. `fromSec` is used for `.user` only (the pre-seek position); a user
    /// seek issued while another seek is in flight starts where that one was going.
    mutating func beginSeek(kind: SeekKind, targetSec: Double?, fromSec: Double? = nil, now: TimeInterval) {
        var from: Double?
        if kind == .user {
            // While a seek is in flight (or its leftover position is still reported) the engine's
            // position is stale: the gesture starts where that seek was going.
            if let prior = seekInFlight ?? (stalePositionSec != nil ? abandonedSeek : nil) {
                // Held arrows chain several seeks into one gesture: keep where it started.
                from = prior.kind == .user ? prior.fromSec : prior.targetSec
            } else {
                from = fromSec
            }
        }
        switch kind {
        case .replay:
            // The playhead returns to 0: everything is armed again for the second viewing.
            consumed = []
            deliberateSeeks = []
            chipSuppressedIndex = nil
        case .chip:
            if let index = promptIndex {
                consumed.insert(index)
                chipSuppressedIndex = index
            }
        case .resume, .auto, .user:
            break
        }
        promptIndex = nil
        stalePositionSec = nil
        abandonedSeek = nil
        seekState = .seeking(Seek(kind: kind, targetSec: targetSec, fromSec: from, startedAt: now))
    }

    /// The second stage of ONE user gesture (keyframes landing, then the exact seek). Replaces a
    /// `.user` seek still in flight (keeping its `fromSec`), or starts one when idle. Unlike
    /// `beginSeek` it leaves `promptIndex`, `consumed`, `chipSuppressedIndex` and `abandonedSeek`
    /// alone: the gesture's completion records the same span, and intervals it touched stay consumed.
    mutating func refineSeek(targetSec: Double, fromSec: Double, now: TimeInterval) {
        if let inFlight = seekInFlight, inFlight.kind == .user {
            seekState = .seeking(Seek(kind: .user, targetSec: targetSec, fromSec: inFlight.fromSec, startedAt: now))
        } else {
            seekState = .seeking(Seek(kind: .user, targetSec: targetSec, fromSec: fromSec, startedAt: now))
        }
    }

    /// A deliberate span the user covered without a seek (an in-place scan): intervals it touched
    /// stop auto-skipping. Same bookkeeping as a completed `.user` seek.
    mutating func recordUserSpan(fromSec: Double, toSec: Double) {
        recordDeliberate(fromSec: fromSec, toSec: toSec)
    }

    /// Call when the ENGINE confirms the seek finished, with the actual position. No seek in flight
    /// (e.g. mpv's playback-restart at start of playback or after a track switch) = no-op, except
    /// for the late confirmation of a seek that timed out.
    mutating func seekCompleted(atSec: Double, now: TimeInterval) {
        let seek: Seek
        if let inFlight = seekInFlight {
            seek = inFlight
        } else if let late = abandonedSeek, now - late.startedAt <= Self.lateCompletionWindowSec {
            seek = late
        } else {
            abandonedSeek = nil
            return
        }
        seekState = .idle
        abandonedSeek = nil
        stalePositionSec = nil
        seekCompletedSinceLastObservedTick = true
        guard atSec.isFinite else { return }
        switch seek.kind {
        case .resume:
            recordDeliberate(fromSec: atSec, toSec: atSec)
        case .user:
            recordDeliberate(fromSec: seek.fromSec ?? atSec, toSec: atSec)
        case .replay, .auto, .chip:
            // Replay re-armed everything up front. A skip's landing is not a deliberate entry:
            // recap → intro, the intro must still auto-skip.
            break
        }
    }

    /// The seek in flight will never complete as issued: AVPlayer superseded it (a transport scrub
    /// cancelled it: `seek` returned false) or mpv rejected the command. Back to `idle` with NO
    /// side effect: nothing marked or consumed, no stale guard, no late-completion record, and the
    /// completed-since-last-tick flag untouched — so the next `observeTick` judges the jump the
    /// user made as a scrub. No seek in flight = no-op. (A chip press already consumed its interval
    /// in `beginSeek`; that stays.)
    mutating func seekInterrupted() {
        guard seekInFlight != nil else { return }
        seekState = .idle
    }

    /// AVPlayer only, once per tick BEFORE `evaluate`: the move from `fromSec` (previous tick) to
    /// `toSec`. A jump larger than `userJumpThresholdSec` with no app seek in flight and none
    /// completed since the previous tick is a user scrub: recorded as a completed `.user` seek.
    /// Returns true when it was one.
    mutating func observeTick(fromSec: Double, toSec: Double, now: TimeInterval) -> Bool {
        let appSeekInvolved = seekInFlight != nil || seekCompletedSinceLastObservedTick
        seekCompletedSinceLastObservedTick = false
        guard !appSeekInvolved, fromSec.isFinite, toSec.isFinite,
              abs(toSec - fromSec) > Self.userJumpThresholdSec else { return false }
        beginSeek(kind: .user, targetSec: toSec, fromSec: fromSec, now: now)
        seekCompleted(atSec: toSec, now: now)
        seekCompletedSinceLastObservedTick = false
        return true
    }

    /// Any remote press: a chip hidden by the auto-hide comes back for another 10 s. True when it did.
    mutating func noteInput(now: TimeInterval) -> Bool {
        guard let index = chipHiddenIndex else { return false }
        chipShown = (index, now)
        chipHiddenIndex = nil
        return true
    }

    // MARK: - Evaluation

    /// Call on every position tick. `autoSkipTypes` nil = auto-skip off (Skip Intro disabled).
    mutating func evaluate(positionSec: Double, durationSec: Double, isPlaying: Bool,
                           autoSkipTypes: [AutoSkipSegmentType]?, now: TimeInterval) -> Decision {
        let previousTick = lastTickPositionSec
        lastTickPositionSec = positionSec
        promptIndex = nil

        if let seek = seekInFlight {
            guard now - seek.startedAt > Self.seekTimeoutSec else { return Decision() }
            // Never confirmed: stop waiting, mark nothing, consume nothing. Until the position
            // moves away from where it sat before the timeout, it is the leftover of that seek.
            seekState = .idle
            abandonedSeek = seek
            stalePositionSec = previousTick ?? positionSec
        }
        if let stale = stalePositionSec {
            guard abs(positionSec - stale) > Self.staleTolerance else { return Decision() }
            stalePositionSec = nil
        }

        let durationMs = durationSec > 0 ? Self.ms(durationSec) : 0
        guard let index = intervals.firstIndex(where: { interval in
            positionSec >= interval.startTime && positionSec < interval.endTime &&
                interval.internalSkipAction(intervals: intervals, durationMs: durationMs) != nil
        }), let action = intervals[index].internalSkipAction(intervals: intervals, durationMs: durationMs)
        else {
            chipSuppressedIndex = nil
            chipShown = nil
            chipHiddenIndex = nil
            return Decision()
        }
        if chipSuppressedIndex != index { chipSuppressedIndex = nil }

        let interval = intervals[index]
        let target = Self.clamp(Double(action.targetMs) / 1000.0, durationSec: durationSec)

        if let types = autoSkipTypes, !types.isEmpty, isPlaying,
           !consumed.contains(index), interval.shouldAutoSkipForTypes(selectedTypes: types) {
            consumed.insert(index)
            chipSuppressedIndex = index
            return Decision(prompt: nil, autoSkipTargetSec: target)
        }

        guard chipSuppressedIndex != index,
              positionSec < interval.endTime - PlayerChipStyle.lastSecondExclusion else { return Decision() }
        // Fork deviation from upstream's label rule: upstream says "Skip to Post-Credits" whenever
        // `skipsToPostCredits` is set, which the shared heuristic also raises for any >5 s tail after
        // an outro (e.g. a next-episode preview). Only an EXPLICIT post-credits interval after this
        // one earns the label; the seek target still comes from `internalSkipAction`.
        // Mirrors the shared scene filter in `InternalSkipAction.kt`: valid times, after this
        // interval, and (duration known) starting before the end of the video.
        let explicitPostCredits = action.skipsToPostCredits && intervals.contains {
            $0.type.trimmingCharacters(in: .whitespaces).lowercased() == "post-credits" &&
                $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0 &&
                $0.endTime > $0.startTime && $0.endTime * 1000.0 < 9.2e18 &&
                $0.startTime >= interval.endTime &&
                (durationSec <= 0 || $0.startTime < durationSec)
        }
        let label = Self.label(for: interval.type, skipsToPostCredits: explicitPostCredits)
        if chipShown?.index != index { chipShown = (index, now) }
        if autoHidesChip, let shown = chipShown, now - shown.since >= Self.chipAutoHideSec {
            chipHiddenIndex = index
            return Decision()
        }
        promptIndex = index
        return Decision(prompt: SkipPrompt(label: label, targetSec: target), autoSkipTargetSec: nil)
    }

    /// Chip label (upstream `SkipIntroButton.skipLabel`). Unknown types keep tvOS's old "Skip Intro".
    static func label(for type: String, skipsToPostCredits: Bool) -> String {
        switch type.trimmingCharacters(in: .whitespaces).lowercased() {
        case "outro", "ed", "mixed-ed", "ending", "credits":
            return skipsToPostCredits ? String(localized: "Skip to Post-Credits") : String(localized: "Skip Outro")
        case "movie-credits":
            return skipsToPostCredits ? String(localized: "Skip to Post-Credits") : String(localized: "Skip Credits")
        case "recap":
            return String(localized: "Skip Recap")
        default:
            return String(localized: "Skip Intro")
        }
    }

    // MARK: - Helpers

    private mutating func recordDeliberate(fromSec: Double, toSec: Double) {
        let seek = (fromMs: Self.ms(fromSec), toMs: Self.ms(toSec))
        deliberateSeeks.append(seek)
        markDeliberate(fromMs: seek.fromMs, toMs: seek.toMs)
    }

    private mutating func markDeliberate(fromMs: Int64, toMs: Int64) {
        guard !intervals.isEmpty else { return }
        let hit = AutoSkipSegmentTypeKt.intervalsAtSeekPositions(intervals, fromMs: fromMs, toMs: toMs)
        for (index, interval) in intervals.enumerated() where hit.contains(interval) {
            consumed.insert(index)
        }
    }

    /// A skip target past EOF wedges mpv (and an open-ended outro's target is Long.MAX ms):
    /// stay half a second short of a known duration. Unknown duration seeks unclamped (old rule).
    private static func clamp(_ targetSec: Double, durationSec: Double) -> Double {
        durationSec > 0 ? min(targetSec, durationSec - 0.5) : targetSec
    }

    private static func ms(_ seconds: Double) -> Int64 {
        let value = max(0, seconds) * 1000   // NaN → 0; an open-ended end (Double.MAX) → inf
        guard value < 9.2e18 else { return Int64.max }
        return Int64(value)
    }
}
