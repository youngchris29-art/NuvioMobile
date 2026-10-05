import Foundation
import SharedCore

// Home Stage & Strip (P1 §5): the stage's meta line and synopsis, as pure functions of the focused
// title and its Continue Watching progress, plus the strip's catalog-heading add-on rule.

/// What the stage's text column shows under the logo: one meta line and the synopsis.
nonisolated struct StageCopy: Equatable {
    let meta: String
    let synopsis: String
}

extension StageCopy {
    /// The stage's copy for `item`.
    ///
    /// No `progress` (the title is not in Continue Watching, or the host installed no lookup, e.g.
    /// the folder Rows page): Classic's meta line (`HomeHeroForeground.metaLine`: release · up to
    /// three genres) and the item's description. A collection folder's preview carries its
    /// collection title as `releaseInfo` and `HomeView.folderHeroDescription` as its description,
    /// so a folder reads through the same three slots.
    ///
    /// W2-A, Continue-Watching-aware: with `progress`, the meta line is
    /// `S1 E3 · <episode title> · 45m left` (each part only when it is known; nothing known falls
    /// back to Classic's line) and the synopsis is the progress entry's `pauseDescription` (the
    /// episode's own text) when it has one, else the item's description. A folder never gets this
    /// copy, whatever lookup the host installed.
    nonisolated static func make(item: MetaPreview, progress: WatchProgressEntry?) -> StageCopy {
        let plain = StageCopy(meta: classicMeta(item), synopsis: plainSynopsis(item))
        guard let progress, !isFolderPreview(item) else { return plain }
        let meta = continueWatchingMeta(progress, item: item)
        let pause: String? = progress.pauseDescription
        let synopsis = nonBlank(pause) ?? plain.synopsis
        return StageCopy(meta: meta.isEmpty ? plain.meta : meta, synopsis: synopsis)
    }

    /// `HomeHeroForeground.metaLine`, duplicated (that one is private to the hero foreground):
    /// release, then the first three genres joined by U+00B7, the two groups joined by a spaced dot.
    nonisolated static func classicMeta(_ item: MetaPreview) -> String {
        var parts: [String] = []
        let release: String? = item.releaseInfo
        if let release, !release.isEmpty { parts.append(release) }
        let genres = item.genres.prefix(3)
        if !genres.isEmpty { parts.append(genres.joined(separator: " \u{00B7} ")) }
        return parts.joined(separator: "  \u{00B7}  ")
    }

    /// The item's own description, or "" (Wave 1's rule, unchanged).
    nonisolated static func plainSynopsis(_ item: MetaPreview) -> String {
        let description: String? = item.description_
        return description ?? ""
    }

    /// The Continue Watching meta line: `S<s> E<e>` when both numbers are set, the episode title
    /// when it is non-blank and is not just the show's own name again (some add-ons repeat it), and
    /// the time left (`remainingLabel`), joined by " · ". Empty when none of them is known (a
    /// percent-only movie row), so the caller falls back to Classic's line.
    nonisolated static func continueWatchingMeta(_ progress: WatchProgressEntry, item: MetaPreview) -> String {
        var parts: [String] = []
        if let season = progress.seasonNumber?.value, let episode = progress.episodeNumber?.value {
            parts.append(episodeCode(season: season, episode: episode))
        }
        let episodeTitle: String? = progress.episodeTitle
        if let episodeTitle = nonBlank(episodeTitle),
           !sameText(episodeTitle, progress.title),
           !sameText(episodeTitle, item.name) {
            parts.append(episodeTitle)
        }
        if let left = remainingLabel(positionMs: progress.lastPositionMs, durationMs: progress.durationMs) {
            parts.append(left)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "S1 E3". Through `String(localized:)` ("S%lld E%lld"), so the string pass can give a
    /// language its own season/episode letters.
    nonisolated static func episodeCode(season: Int, episode: Int) -> String {
        String(localized: "S\(season) E\(episode)")
    }

    /// A Continue Watching entry as the stage's preview: `HomeRowPreviews.entry` plus the entry's
    /// own logo, so the stage can draw the wordmark without a lookup.
    nonisolated static func preview(from entry: WatchProgressEntry) -> MetaPreview {
        let logo: String? = entry.logo
        let usable = (logo?.isEmpty ?? true) ? nil : logo
        return HomeRowPreviews.entry(entry, logo: usable)
    }

    /// "45m left" / "1h 5m left" for a resume position, or nil when the duration is unknown
    /// (`durationMs ≤ 0`: Trakt/Simkl percent-only rows) or under a minute is left.
    nonisolated static func remainingLabel(positionMs: Int64, durationMs: Int64) -> String? {
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

    // MARK: Continue Watching index (W2-A)

    /// The key a title is looked up under: `"<type>:<id>"`. Continue Watching entries file under
    /// `parentMetaType:parentMetaId`, which is the type and id their own row previews carry
    /// (`HomeRowPreviews.entry`), so the same title focused in ANY Home row finds its progress.
    nonisolated static func progressKey(type: String, id: String) -> String {
        "\(type):\(id)"
    }

    /// Continue Watching entries by `progressKey`. The first entry for a title wins: the row lists
    /// the card it shows first, so a series with two in-progress episodes reads the one its Continue
    /// Watching card shows.
    nonisolated static func progressIndex(_ entries: [WatchProgressEntry]) -> [String: WatchProgressEntry] {
        var index: [String: WatchProgressEntry] = [:]
        for entry in entries {
            let key = progressKey(type: entry.parentMetaType, id: entry.parentMetaId)
            if index[key] == nil { index[key] = entry }
        }
        return index
    }

    /// The lookup `StageStripHome` installs as `StageController.progressLookup`: a snapshot of
    /// `progressIndex(entries)`, read by type and id. nil when there is nothing in progress (the
    /// plain copy, at no cost).
    nonisolated static func progressLookup(_ entries: [WatchProgressEntry]) -> ((MetaPreview) -> WatchProgressEntry?)? {
        guard !entries.isEmpty else { return nil }
        let index = progressIndex(entries)
        return { item in index[StageCopy.progressKey(type: item.type, id: item.id)] }
    }

    // MARK: Row headings (W2-A, Stage only)

    /// The add-on name the strip prints after a catalog row's heading ("Popular · Cinemeta"), or
    /// nil when the name is blank or the heading already carries it (case- and
    /// diacritic-insensitive: "Cinemeta Popular" stays as it is).
    nonisolated static func headingAddon(title: String, addonName: String) -> String? {
        let addon = addonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addon.isEmpty else { return nil }
        guard title.range(of: addon, options: [.caseInsensitive, .diacriticInsensitive]) == nil else { return nil }
        return addon
    }

    // MARK: Helpers

    /// `isCollectionHero`, restated for this nonisolated type (the global and its two constants
    /// default to the main actor). `StageCopyTests` pins both literals to `collectionHeroType` and
    /// `collectionHeroIdScheme`.
    nonisolated static let folderType = "nuvio.folder"
    nonisolated static let folderIdScheme = "nuvio-folder://"

    nonisolated static func isFolderPreview(_ item: MetaPreview) -> Bool {
        item.type == folderType && item.id.hasPrefix(folderIdScheme)
    }

    /// `value` trimmed, or nil when that leaves nothing.
    nonisolated static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The same text, ignoring case, diacritics and surrounding white space.
    nonisolated static func sameText(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(b.trimmingCharacters(in: .whitespacesAndNewlines),
                     options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
