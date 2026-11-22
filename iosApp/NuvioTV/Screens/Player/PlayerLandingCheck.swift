import Foundation

/// Return from background (spec-mpv-return §6.2): did a restart seek land where it was sent? One
/// rule for the native restart machine and the mpv fresh start after a return. Pure; durations and
/// positions are passed in. Steps run in the spec's order (finding r2-8): the target, then the
/// landing (before any band), then the duration, the tolerance, the end clamp, the normal band.
nonisolated enum PlayerLandingCheck {
    enum Verdict: Sendable, Equatable {
        /// Landed on the target (within the tolerance, or inside the end band).
        case confirmed
        /// Missed, and no correction was used yet: issue one corrective exact seek.
        case correct
        /// Missed after the correction (or the landing is unusable after it).
        case offTarget
        /// The target itself is unusable (not finite, or below 0).
        case invalidTarget
    }

    /// Normal tolerance cap and the end band cap, in seconds.
    static let maxToleranceSec = 0.5
    static let maxEndToleranceSec = 2.0

    /// A duration is usable when finite and above 0.
    static func validDuration(_ d: Double?) -> Double? {
        guard let d, d.isFinite, d > 0 else { return nil }
        return d
    }

    static func verdict(target: Double, landed: Double?, durationAtIssue: Double?, durationNow: Double?,
                        correctionUsed: Bool) -> Verdict {
        let miss: Verdict = correctionUsed ? .offTarget : .correct
        // 1. Target.
        guard target.isFinite, target >= 0 else { return .invalidTarget }
        // 2. Landing, before any band check.
        guard let landed, landed.isFinite, landed >= 0 else { return miss }
        // 3. Duration validity: a change of more than max(1 s, 1 %) between issue and now is a miss.
        let atIssue = validDuration(durationAtIssue)
        let now = validDuration(durationNow)
        if let atIssue, let now, abs(atIssue - now) > max(1, atIssue * 0.01) { return miss }
        let d = now ?? atIssue
        // 4. Tolerance.
        let tol = d.map { min(maxToleranceSec, $0 / 8) } ?? maxToleranceSec
        // 5. End clamp (only with a known duration).
        if let d, target > d - tol {
            let endTol = min(maxEndToleranceSec, d / 4)
            let low = max(0, d - endTol)
            return (landed >= low && landed <= d + tol) ? .confirmed : miss
        }
        // 6. Normal case. Past `D + tol` never confirms.
        if let d, landed > d + tol { return miss }
        if abs(landed - target) <= tol { return .confirmed }
        // 7. Otherwise.
        return miss
    }
}
