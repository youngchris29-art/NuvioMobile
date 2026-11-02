import Foundation
import NuvioAether

// Aether (Phase 1), plan section 5: the cue store behind `AetherSubtitleOverlay`. Pure and value-typed,
// fork types only (`AetherCue` is the façade's own type; nothing here touches the engine), so every rule
// below is unit-tested in `SubtitleCueTimelineTests` without a player.
//
// Time axis: every cue carries raw source PTS (`AetherClock.sourceSec`). The host subtitle delay is applied
// here, never by the engine: the cue shown at clock time `t` is the one active at `t - delaySec`, so a
// positive delay shows the line later and a negative delay earlier (the mpv `sub-delay` sign).

/// What the overlay draws for the selected track.
nonisolated enum SubtitleOverlayMode: Equatable, Sendable {
    /// Nothing (no track, or Subtitles Off without the forced rule).
    case off
    /// Every cue of the selected track.
    case all
    /// Only forced cues: a cue flagged forced (PGS/DVB composition flag) or any cue of a forced track.
    case forcedOnly

    /// The fork's forced rule for the overlay, mirroring the mpv start path (`MPVPlayerView`'s subtitle
    /// auto-select over `resolveSubtitleAutoSelectionPlan`) and `SubtitleFallbackGuard`'s "Off stays Off":
    ///
    /// - no selected track: `.off`;
    /// - a track the user picked in the panel: `.all` (the user's pick always shows in full);
    /// - the start plan came back `FORCED_ONLY` (Use Forced Subtitles on and the audio matches the
    ///   subtitle target): `.forcedOnly`;
    /// - Subtitles Off (`SubtitleFallbackGuard.isOff`, so a blank value counts as Off) without that forced
    ///   plan: `.off`. Off empties the target list on mpv, so the only way forced cues show while Off is
    ///   the plan above (the audio matches a preferred audio language); a NORMAL_ONLY plan with no
    ///   targets, or no plan at all (audio unknown, BUG-171), leaves mpv on `sid=no`, and a fallback
    ///   language never turns a track on;
    /// - otherwise `.all`.
    static func resolve(primary: String, useForcedSubtitles: Bool, hasSelectedTrack: Bool,
                        userSelectedTrack: Bool, startPlanForcedOnly: Bool) -> SubtitleOverlayMode {
        guard hasSelectedTrack else { return .off }
        if userSelectedTrack { return .all }
        if useForcedSubtitles && startPlanForcedOnly { return .forcedOnly }
        if SubtitleFallbackGuard.isOff(primary: primary) { return .off }
        return .all
    }
}

/// The cues of the selected subtitle track, sorted by start then id, and the questions the overlay asks.
///
/// - `active(atSourceSec:delaySec:)` answers the cues on screen; overlapping cues all show, gaps show
///   nothing, and a seek back is just an earlier question (no cursor state, so nothing to rewind).
/// - `replace(cues:keepingActiveAtSourceSec:delaySec:)` adopts the engine's window (`session.cues`). A cue
///   that is on screen right now but missing from the new window (the engine slid its 300 s window, or a
///   cue was re-emitted late) is kept until its own end, so the line never blinks. An unchanged window
///   changes nothing and returns false, so SwiftUI sees the same identities and no publish happens.
/// - `evict(atSourceSec:delaySec:)` drops cues that ended more than `retentionSec` before the effective
///   time, then the oldest-ending cues beyond `maxCues`. It never drops a cue that is active at that time.
nonisolated struct SubtitleCueTimeline: Sendable {
    /// The engine keeps 300 s behind the playhead (W2-A hand-over); the timeline matches it.
    static let defaultRetentionSec: Double = 300
    /// A hard cap so a pathological source (a cue per frame) cannot grow the store without bound.
    static let defaultMaxCues = 4_000

    let retentionSec: Double
    let maxCues: Int

    /// Sorted by `(startSec, id)`, ids unique.
    private(set) var cues: [AetherCue] = []
    /// What the overlay draws (see `SubtitleOverlayMode.resolve`).
    var mode: SubtitleOverlayMode = .all
    /// The selected track's `AetherTrack.isForced`. Text cues never carry their own forced flag, so in
    /// `.forcedOnly` a forced track shows all of its cues.
    var trackIsForced = false
    /// The longest cue duration in `cues`, so `active` can stop scanning backwards early.
    private var maxDurationSec: Double = 0

    init(cues: [AetherCue] = [], retentionSec: Double = defaultRetentionSec, maxCues: Int = defaultMaxCues) {
        self.retentionSec = retentionSec
        self.maxCues = max(1, maxCues)
        self.cues = Self.normalized(cues)
        self.maxDurationSec = Self.longestDuration(self.cues)
    }

    /// The time on the cue axis that the clock time `sourceSec` shows: `sourceSec - delaySec`. nil when
    /// either value is not finite.
    static func effectiveTime(sourceSec: Double, delaySec: Double) -> Double? {
        guard sourceSec.isFinite, delaySec.isFinite else { return nil }
        return sourceSec - delaySec
    }

    /// Whether `cue` is on screen at the cue-axis time `t`: `startSec <= t < endSec`. A cue whose end is
    /// not after its start never shows.
    static func isActive(_ cue: AetherCue, at t: Double) -> Bool {
        cue.startSec <= t && t < cue.endSec
    }

    /// The cues to draw at clock time `sourceSec` with the host `delaySec`, in `(startSec, id)` order and
    /// filtered by `mode`. Empty when the mode is `.off` or a time is not finite.
    func active(atSourceSec sourceSec: Double, delaySec: Double) -> [AetherCue] {
        guard mode != .off, let t = Self.effectiveTime(sourceSec: sourceSec, delaySec: delaySec) else { return [] }
        return activeUnfiltered(at: t).filter(passesMode)
    }

    /// Adopts `newCues` (any order, duplicates by id resolved to the last one). With
    /// `keepingActiveAtSourceSec`, a cue active at that time (after the delay) that `newCues` no longer
    /// holds is carried over, then eviction runs at that time. Returns whether `cues` changed.
    @discardableResult
    mutating func replace(cues newCues: [AetherCue], keepingActiveAtSourceSec sourceSec: Double? = nil,
                          delaySec: Double = 0) -> Bool {
        var next = Self.normalized(newCues)
        let t = sourceSec.flatMap { Self.effectiveTime(sourceSec: $0, delaySec: delaySec) }
        if let t {
            let ids = Set(next.map(\.id))
            let carried = activeUnfiltered(at: t).filter { !ids.contains($0.id) }
            if !carried.isEmpty { next = Self.normalized(next + carried) }
        }
        var candidate = SubtitleCueTimeline(retentionSec: retentionSec, maxCues: maxCues)
        candidate.cues = next
        candidate.maxDurationSec = Self.longestDuration(next)
        if let t { candidate.evict(atEffectiveTime: t) }
        guard candidate.cues != cues else { return false }
        cues = candidate.cues
        maxDurationSec = candidate.maxDurationSec
        return true
    }

    /// Drops cues ended more than `retentionSec` before the effective time, then the oldest-ending cues
    /// beyond `maxCues`; a cue active at the effective time is never dropped. Returns whether `cues` changed.
    @discardableResult
    mutating func evict(atSourceSec sourceSec: Double, delaySec: Double) -> Bool {
        guard let t = Self.effectiveTime(sourceSec: sourceSec, delaySec: delaySec) else { return false }
        return evict(atEffectiveTime: t)
    }

    /// Empties the store (a new source, or a track switch whose old lines must go at once).
    mutating func removeAll() {
        cues = []
        maxDurationSec = 0
    }

    // MARK: - Private

    @discardableResult
    private mutating func evict(atEffectiveTime t: Double) -> Bool {
        let before = cues.count
        let horizon = t - retentionSec
        var kept = cues.filter { Self.isActive($0, at: t) || $0.endSec >= horizon }
        if kept.count > maxCues {
            // Oldest-ending first, never an active one; ties go to the lower id (the older cue).
            let removable = kept.enumerated()
                .filter { !Self.isActive($0.element, at: t) }
                .sorted { a, b in
                    a.element.endSec != b.element.endSec ? a.element.endSec < b.element.endSec
                        : a.element.id < b.element.id
                }
            let drop = Set(removable.prefix(kept.count - maxCues).map(\.element.id))
            kept.removeAll { drop.contains($0.id) }
        }
        guard kept.count != before else { return false }
        cues = kept
        maxDurationSec = Self.longestDuration(kept)
        return true
    }

    private func passesMode(_ cue: AetherCue) -> Bool {
        switch mode {
        case .off: return false
        case .all: return true
        case .forcedOnly: return cue.isForced || trackIsForced
        }
    }

    /// Every cue active at the cue-axis time `t`, in `(startSec, id)` order. Binary search for the first
    /// cue starting after `t`, then a backward scan that stops once no cue can still reach `t`.
    private func activeUnfiltered(at t: Double) -> [AetherCue] {
        guard !cues.isEmpty else { return [] }
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].startSec <= t { lo = mid + 1 } else { hi = mid }
        }
        var found: [AetherCue] = []
        var i = lo - 1
        while i >= 0 {
            let cue = cues[i]
            if maxDurationSec.isFinite, cue.startSec < t - maxDurationSec { break }
            if Self.isActive(cue, at: t) { found.append(cue) }
            i -= 1
        }
        return found.reversed()
    }

    /// Unique by id (the last occurrence wins), dropping non-finite starts, sorted by `(startSec, id)`.
    private static func normalized(_ input: [AetherCue]) -> [AetherCue] {
        var byID: [Int: AetherCue] = [:]
        byID.reserveCapacity(input.count)
        for cue in input where cue.startSec.isFinite && !cue.endSec.isNaN { byID[cue.id] = cue }
        return byID.values.sorted { a, b in a.startSec != b.startSec ? a.startSec < b.startSec : a.id < b.id }
    }

    private static func longestDuration(_ cues: [AetherCue]) -> Double {
        cues.reduce(0) { max($0, $1.endSec - $1.startSec) }
    }
}

/// The text a text cue draws: ASS/SSA arrives flattened from the engine, and this strips anything left
/// over. Override blocks containing a backslash (`{\an8}`, `{\i1}`, `{\pos(…)}`) are removed, `\N` and `\n`
/// become line breaks, `\h` a no-break space; each line is trimmed and blank lines are dropped. A cue that
/// cleans to nothing is not drawn.
nonisolated enum SubtitleCueText {
    static func display(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: #"\{[^{}]*\\[^{}]*\}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: "\u{00A0}")
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Whitespace without U+00A0, so an ASS `\h` at a line edge survives the trim.
    private static let trimSet = CharacterSet.whitespaces.subtracting(CharacterSet(charactersIn: "\u{00A0}"))

    /// ASS numpad alignment 7, 8 or 9 (`{\an8}` signs, top captions): the cue draws at the top.
    static func isTopAligned(_ alignment: Int?) -> Bool {
        guard let alignment else { return false }
        return (7...9).contains(alignment)
    }
}
