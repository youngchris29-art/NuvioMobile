import Foundation
import SharedCore

// Home Stage & Strip (P1 §5): the stage's meta line and synopsis, as pure functions of the focused
// title (and, from W2-A, its Continue Watching progress).

/// What the stage's text column shows under the logo: one meta line and the synopsis.
nonisolated struct StageCopy: Equatable {
    let meta: String
    let synopsis: String
}

extension StageCopy {
    /// W1-A: `progress` is ignored — the meta line is Classic's (`HomeHeroForeground.metaLine`:
    /// release · up to three genres) and the synopsis is the item's description. A collection
    /// folder's preview carries its collection title as `releaseInfo` and
    /// `HomeView.folderHeroDescription` as its description, so a folder reads through the same
    /// three slots. W2-A makes this Continue-Watching-aware (`StageController.progressLookup`).
    static func make(item: MetaPreview, progress: WatchProgressEntry?) -> StageCopy {
        let description: String? = item.description_
        return StageCopy(meta: classicMeta(item), synopsis: description ?? "")
    }

    /// `HomeHeroForeground.metaLine`, duplicated (that one is private to the hero foreground):
    /// release, then the first three genres joined by U+00B7, the two groups joined by a spaced dot.
    static func classicMeta(_ item: MetaPreview) -> String {
        var parts: [String] = []
        let release: String? = item.releaseInfo
        if let release, !release.isEmpty { parts.append(release) }
        let genres = item.genres.prefix(3)
        if !genres.isEmpty { parts.append(genres.joined(separator: " \u{00B7} ")) }
        return parts.joined(separator: "  \u{00B7}  ")
    }

    /// A Continue Watching entry as the stage's preview: `HomeRowPreviews.entry` plus the entry's
    /// own logo, so the stage can draw the wordmark without a lookup.
    static func preview(from entry: WatchProgressEntry) -> MetaPreview {
        let logo: String? = entry.logo
        let usable = (logo?.isEmpty ?? true) ? nil : logo
        return HomeRowPreviews.entry(entry, logo: usable)
    }

    /// "45m left" / "1h 5m left" for a resume position, or nil when the duration is unknown
    /// (`durationMs ≤ 0`: Trakt/Simkl percent-only rows) or under a minute is left.
    static func remainingLabel(positionMs: Int64, durationMs: Int64) -> String? {
        guard durationMs > 0 else { return nil }
        let remaining = durationMs - max(0, positionMs)
        guard remaining >= 60_000 else { return nil }
        // `Int` for the interpolation: `String(localized:)` keys it as "%lld…" either way.
        let totalMinutes = Int(remaining / 60_000)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return String(localized: "\(hours)h \(minutes)m left")
        }
        return String(localized: "\(totalMinutes)m left")
    }
}
