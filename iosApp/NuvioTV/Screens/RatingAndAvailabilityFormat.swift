import Foundation
import SharedCore

// Port batch 2026-10-31 (upstream Mobile 96061025 and 2f0185ce): two pure rules the Swift render
// sites share. `nonisolated` so the NuvioTVTests cases can call them synchronously.

/// IMDb rating text. TMDB, Trakt and Library ratings are already rounded to one decimal in
/// `shared/`; add-on `imdbRating` values pass through raw ("8.123456", "8", " 7.5 "), so the four
/// Swift render sites (Detail hero, Detail meta chip, both player info chips) run them through this.
nonisolated enum RatingFormat {
    /// Mirrors upstream `formatOneDecimal`: round half up to tenths, always one decimal digit, a
    /// `.` separator whatever the device locale (the rating is an IMDb score, not a localised
    /// number). A value that is not a number is returned trimmed and otherwise untouched, so the
    /// fork's existing show/hide gates keep their behavior.
    static func oneDecimal(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Add-on metadata is untrusted: `Int(_:)` traps past Int.max, so anything whose scaled value
        // is not safely Int-representable (1e18, "inf", "nan") is returned as written.
        guard let value = Double(trimmed), value.isFinite, abs(value) < 1e15 else { return trimmed }
        let tenths = Int((value * 10 + 0.5).rounded(.down)) // Kotlin roundToInt: half toward +infinity
        let whole = tenths / 10
        let decimal = abs(tenths % 10)
        // `-0.4` rounds to tenths -4: whole 0 would lose the sign, so keep it explicitly.
        let sign = tenths < 0 && whole == 0 ? "-" : ""
        return "\(sign)\(whole).\(decimal)"
    }
}

/// The "Unavailable" pill on an episode card: the add-on flagged the video unavailable, or its
/// release date has not aired yet. Mirrors upstream `EpisodeAvailabilityBadge`
/// (`!video.available || isEpisodeReleaseAired(video.released) == false`); a missing or
/// unparseable date counts as aired, like `NextEpisodeAutoPlay.hasAired`.
nonisolated enum EpisodeAvailability {
    static func isUnavailable(available: Bool, released: String?, nowEpochMs: Int64) -> Bool {
        if !available { return true }
        return EpisodeReleaseDateParserKt.isEpisodeReleaseAired(raw: released, nowEpochMs: nowEpochMs)?.boolValue == false
    }

    static func isUnavailable(_ video: MetaVideo, now: Date = Date()) -> Bool {
        let released: String? = video.released
        return isUnavailable(available: video.available, released: released,
                             nowEpochMs: Int64(now.timeIntervalSince1970 * 1000))
    }
}
