import Foundation
import SharedCore

/// One skip-segment policy for both player engines (tvOS half of upstream cbe4dc0a..77ce8a73:
/// IntroDB movie segments + unified skip controls). Pure value type — no UIKit/SwiftUI state; each
/// engine owns one, feeds it the fetched intervals, its seeks and its position ticks, and renders
/// the answer with its existing chip (mpv: `PlayerActionChip`; AVPlayer: a contextual action).
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
struct SkipSegmentPlanner {
    /// What the engine should do on this tick.
    struct Decision: Equatable {
        /// Chip to show (nil = none). Its `targetSec` is already clamped for the engine.
        var prompt: SkipPrompt?
        /// Seek here now (auto-skip); nil = no auto-skip this tick.
        var autoSkipTargetSec: Double?
    }

    /// The full fetched list, `post-credits` intervals included.
    private(set) var intervals: [SkipInterval] = []
    /// Indices into `intervals` that must not auto-skip (already auto-skipped, or entered deliberately).
    private var consumed = Set<Int>()
    /// Every deliberate seek so far (ms). Re-applied when the intervals arrive after the seek.
    private var deliberateSeeks: [(fromMs: Int64, toMs: Int64)] = []
    /// The resume seek is issued before the position the engine reports reflects it (mpv's property
    /// cache lags the `seek` command), so auto-skip waits until the playhead has landed — otherwise
    /// a stale position of 0 inside an intro would auto-skip and override the resume.
    private var landing: Landing?
    private var landingTicks = 0
    /// The interval just auto-skipped: no chip for it until the playhead has left it once, so the
    /// engine's pre-seek position doesn't flash the chip (upstream dismisses it after an auto-skip).
    private var chipSuppressedIndex: Int?

    private enum Landing {
        case at(Double)
        /// Percentage resume with no known duration: the first real position is the landing.
        case unknown
    }

    static let landingTolerance: Double = 5
    /// Give up waiting for a landing that never shows (failed seek) after this many ticks.
    static let maxLandingTicks = 20

    // MARK: - Inputs

    mutating func setIntervals(_ newIntervals: [SkipInterval]) {
        intervals = newIntervals
        consumed = []
        for seek in deliberateSeeks { markDeliberate(fromMs: seek.fromMs, toMs: seek.toMs) }
    }

    /// A user seek (scrub, arrow, transport skip) from `fromSec` to `toSec`.
    mutating func noteUserSeek(fromSec: Double, toSec: Double) {
        let seek = (fromMs: Self.ms(fromSec), toMs: Self.ms(toSec))
        deliberateSeeks.append(seek)
        markDeliberate(fromMs: seek.fromMs, toMs: seek.toMs)
    }

    /// The resume seek. `toSec` nil = target unknown (mpv `absolute-percent` resume).
    mutating func noteResumeSeek(toSec: Double?) {
        landingTicks = 0
        if let toSec {
            noteUserSeek(fromSec: toSec, toSec: toSec)
            landing = .at(toSec)
        } else {
            landing = .unknown
        }
    }

    /// "Play Again": the playhead returns to 0, so every interval must be armed again — auto-skipped
    /// or deliberately entered earlier must not keep the replay from skipping. Keeps the intervals.
    mutating func resetForReplay() {
        consumed = []
        deliberateSeeks = []
        chipSuppressedIndex = nil
        // Hold auto-skip and the chip until the playhead is back near 0: the seek is async and the
        // cached position may still be the end-of-file one, inside a re-armed outro. Not
        // `noteResumeSeek(0)`: that would record a deliberate 0 -> 0 seek and consume an intro at 0.
        landing = .at(0)
        landingTicks = 0
    }

    // MARK: - Evaluation

    /// Call on every position tick. `autoSkipTypes` nil = auto-skip off (Skip Intro disabled).
    mutating func evaluate(positionSec: Double, durationSec: Double, isPlaying: Bool,
                           autoSkipTypes: [AutoSkipSegmentType]?) -> Decision {
        updateLanding(positionSec: positionSec)
        let durationMs = durationSec > 0 ? Self.ms(durationSec) : 0
        guard let index = intervals.firstIndex(where: { interval in
            positionSec >= interval.startTime && positionSec < interval.endTime &&
                interval.internalSkipAction(intervals: intervals, durationMs: durationMs) != nil
        }), let action = intervals[index].internalSkipAction(intervals: intervals, durationMs: durationMs)
        else {
            chipSuppressedIndex = nil
            return Decision()
        }
        if chipSuppressedIndex != index { chipSuppressedIndex = nil }

        let interval = intervals[index]
        let target = Self.clamp(Double(action.targetMs) / 1000.0, durationSec: durationSec)

        if let types = autoSkipTypes, !types.isEmpty, isPlaying, landing == nil,
           !consumed.contains(index), interval.shouldAutoSkipForTypes(selectedTypes: types) {
            consumed.insert(index)
            chipSuppressedIndex = index
            return Decision(prompt: nil, autoSkipTargetSec: target)
        }

        guard chipSuppressedIndex != index, landing == nil,
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

    private mutating func updateLanding(positionSec: Double) {
        guard let pending = landing else { return }
        landingTicks += 1
        switch pending {
        case .at(let target):
            if abs(positionSec - target) <= Self.landingTolerance { landing = nil }
        case .unknown:
            if positionSec > 1 {
                noteUserSeek(fromSec: positionSec, toSec: positionSec)
                landing = nil
            }
        }
        if landing != nil, landingTicks >= Self.maxLandingTicks { landing = nil }
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

/// Tells the AVPlayer tick loop's "position jumped" detector which jumps are the app's own skip
/// seeks, so only genuine user scrubs reach `SkipSegmentPlanner.noteUserSeek`. Ticks are ~3 s apart
/// and the tick right after a seek may still report the pre-seek position. While a programmatic
/// seek is pending: a tick in `[target - 5, target + 5 + 3.5 * ticksWaited]` is the landing (playback
/// only moves forward from the target, ~one tick per wait); a tick in `[from - 0.5, from + 4]` is a
/// stale pre-seek reading (max `maxPendingTicks` ticks). Anything else is judged by the normal jump rule.
struct ProgrammaticSeekFilter {
    static let jumpThresholdSec: Double = 10
    static let landingToleranceSec: Double = 5
    static let tickAllowanceSec: Double = 3.5
    static let staleForwardSec: Double = 4
    static let staleBackSec: Double = 0.5
    static let maxPendingTicks = 4

    private var pending: (from: Double, target: Double, ticks: Int)?

    /// The app is about to seek from `fromSec` to `targetSec`.
    mutating func noteProgrammaticSeek(from fromSec: Double, to targetSec: Double) {
        pending = (fromSec, targetSec, 0)
    }

    /// True when the move from `last` to `new` is a user seek.
    mutating func isUserSeek(last: Double, new: Double) -> Bool {
        if var p = pending {
            p.ticks += 1
            let upper = p.target + Self.landingToleranceSec + Self.tickAllowanceSec * Double(p.ticks)
            if new >= p.target - Self.landingToleranceSec, new <= upper {
                pending = nil
                return false
            }
            if new >= p.from - Self.staleBackSec, new <= p.from + Self.staleForwardSec,
               p.ticks < Self.maxPendingTicks {
                pending = p   // stale pre-seek tick: keep waiting for the landing
                return false
            }
            pending = nil
        }
        return new.isFinite && abs(new - last) > Self.jumpThresholdSec
    }
}
