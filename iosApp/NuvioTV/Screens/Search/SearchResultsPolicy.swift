import Foundation
import SharedCore

/// Search & Discover batch 2026-10-06 (B2): turns a shared `SearchUiState` into what the Search
/// page draws. Pure; `SearchViewModel` decides WHEN to apply it (the rows hold), this decides WHAT.
///
/// Grouped mode (the default) reads Kotlin's `groups` (C2): the Top result, then one row per media
/// type, merged across add-ons. Per-add-on mode (`SearchRowsMode.perAddon`) passes `sections`
/// through untouched, which is what Search showed before the batch. Both come from the same
/// outcomes on every publish, so switching modes never refetches.
nonisolated enum SearchResultsAdapter {
    /// Kotlin's key for the Top result group (`SearchResultGrouping.kt`).
    static let topGroupKey = "top"
    /// Prefix of a grouped row's `HomeCatalogSection.key` (accessibility id `search.group.<key>`).
    static let rowKeyPrefix = "search.group."

    /// The rows for `mode`: one `HomeCatalogSection` per type group, or the per-add-on sections.
    static func rows(from state: SearchUiState, mode: SearchRowsMode) -> [HomeCatalogSection] {
        rows(groups: state.groups, sections: state.sections, mode: mode)
    }

    static func rows(groups: [SearchResultGroup], sections: [HomeCatalogSection], mode: SearchRowsMode) -> [HomeCatalogSection] {
        switch mode {
        case .perAddon:
            return sections
        case .grouped:
            return groups.filter(isTypeGroup).compactMap(section(for:))
        }
    }

    /// A type group as a `HomeCatalogSection` for `CatalogRowView`, built like
    /// `FolderRowsPlan.section(...)`. Title "Movies · 12"; empty subtitle and add-on name (a merged
    /// row has no one add-on, and an empty name keeps the Stage heading's "· add-on" suffix off);
    /// `hasMore` false, so no See All (a merged row has no single catalog to page).
    static func section(for group: SearchResultGroup) -> HomeCatalogSection? {
        let items = group.hits.map(\.item)
        guard !items.isEmpty else { return nil }
        return HomeCatalogSection(
            key: rowKeyPrefix + group.key,
            title: "\(group.title) · \(items.count)",
            subtitle: "",
            addonName: "",
            target: group.representativeTarget,
            items: items,
            availableItemCount: Int32(items.count),
            hasMore: false
        )
    }

    /// `type:id` (Kotlin `MetaPreview.stableKey()`) → the add-ons that returned it, metadata
    /// add-ons first. Grouped mode only: per-add-on rows already say where each card came from.
    static func foundIn(from state: SearchUiState, mode: SearchRowsMode) -> [String: [String]] {
        foundIn(groups: state.groups, mode: mode)
    }

    static func foundIn(groups: [SearchResultGroup], mode: SearchRowsMode) -> [String: [String]] {
        guard mode == .grouped else { return [:] }
        var map: [String: [String]] = [:]
        for group in groups {
            for hit in group.hits where !hit.foundIn.isEmpty {
                let key = hit.item.stableKey()
                if map[key] == nil { map[key] = hit.foundIn }
            }
        }
        return map
    }

    /// The first hit of the `"top"` group, else the first item of the first non-empty group. Nil in
    /// per-add-on mode (that layout has no Top result card).
    static func topResult(from state: SearchUiState, mode: SearchRowsMode) -> MetaPreview? {
        topResult(groups: state.groups, mode: mode)
    }

    static func topResult(groups: [SearchResultGroup], mode: SearchRowsMode) -> MetaPreview? {
        guard mode == .grouped else { return nil }
        if let top = groups.first(where: { $0.key == topGroupKey })?.hits.first {
            return top.item
        }
        return groups.first(where: { !$0.hits.isEmpty })?.hits.first?.item
    }

    /// TMDB people (C3) as `MetaPerson`s for `CastCard`: the department ("Acting", "Directing")
    /// stands in for the cast role line. Both modes.
    static func people(from state: SearchUiState) -> [MetaPerson] {
        people(state.people)
    }

    static func people(_ previews: [PersonPreview]) -> [MetaPerson] {
        previews.map { person in
            MetaPerson(
                name: person.name,
                role: person.knownForDepartment,
                photo: person.profileUrl,
                tmdbId: KotlinInt(int: person.tmdbId)
            )
        }
    }

    /// Completion candidates for `SearchSuggestionPolicy`: Kotlin's `suggestions` when it has any,
    /// else the result titles in row order (grouped hits, then per-add-on items).
    static func suggestionCandidates(from state: SearchUiState) -> [String] {
        suggestionCandidates(suggestions: state.suggestions, groups: state.groups, sections: state.sections)
    }

    static func suggestionCandidates(suggestions: [String], groups: [SearchResultGroup], sections: [HomeCatalogSection]) -> [String] {
        if !suggestions.isEmpty { return suggestions }
        let grouped = groups.flatMap { $0.hits.map(\.item.name) }
        if !grouped.isEmpty { return grouped }
        return sections.flatMap { $0.items.map(\.name) }
    }

    /// Kind `.type` (Kotlin `SearchResultGroupKind.Type`). Compared against `.topresult` so the
    /// Swift side never has to spell the `type` member.
    private static func isTypeGroup(_ group: SearchResultGroup) -> Bool {
        group.kind != SearchResultGroupKind.topresult && group.key != topGroupKey
    }
}

/// Search & Discover batch 2026-10-06 (B3 d): the suggestion chips under the search band.
///
/// Chip 0 is the typed text in curly quotes (selecting it records the query to Recent, the Search
/// key the inline keyboard lacks); then up to `limit` completions: titles that START with the
/// query, then titles that CONTAIN it, case-insensitive, deduplicated, never the query itself.
nonisolated enum SearchSuggestionPolicy {
    static let limit = 8

    /// The full chip row, quoted query first. Empty for a blank query.
    static func chips(query: String?, candidates: [String], limit: Int = limit) -> [String] {
        let typed = trimmed(query)
        guard !typed.isEmpty else { return [] }
        return [quoted(typed)] + completions(query: typed, candidates: candidates, limit: limit)
    }

    /// `“dune”`: how chip 0 shows the typed text.
    static func quoted(_ query: String) -> String {
        "\u{201C}\(trimmed(query))\u{201D}"
    }

    /// The completions alone (no quoted chip), prefix matches before contains matches.
    static func completions(query: String, candidates: [String], limit: Int = limit) -> [String] {
        let needle = folded(query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var seen: Set<String> = [needle]
        var prefix: [String] = []
        var contains: [String] = []
        for candidate in candidates {
            let title = trimmed(candidate)
            let key = folded(title)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            if key.hasPrefix(needle) {
                seen.insert(key)
                prefix.append(title)
            } else if key.contains(needle) {
                seen.insert(key)
                contains.append(title)
            }
        }
        return Array((prefix + contains).prefix(limit))
    }

    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case-insensitive, whitespace collapsed (Kotlin's `normalize`).
    private static func folded(_ text: String) -> String {
        trimmed(text)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// Search & Discover batch 2026-10-06 (B3 g): what a settled search with nothing to show says.
/// Replaces S1's `emptyMessage` + `searchError` pair.
nonisolated enum SearchEmptyState: Equatable, Sendable {
    /// Nothing could be searched: every enabled add-on's manifest failed to load, or (manifests
    /// cached, e.g. a Wi-Fi drop) every search catalog's request failed. Action: Retry
    /// (`SearchViewModel.retrySearch`: manifests refreshed and the query searched again).
    case manifestFailure(String)
    /// No add-on offers a search catalog at all.
    case noneCanSearch
    /// Search catalogs exist and every one is switched off in Settings > Sources > Search Sources.
    /// Action: open that page.
    case allSourcesOff
    /// The search ran and found nothing.
    case noResults(String)

    /// Precedence top-down (the plan's B3 g table). `reason` is Kotlin's `SearchEmptyStateReason`
    /// (Swift sees `.noactiveaddons / .nosearchcatalogs / .noresults / .requestfailed`); nil →
    /// nil. "All sources off" is Swift-side: Kotlin only knows the fan-out was empty.
    /// `errorMessage` is the state's `errorMessage` (the first manifest error, or the first catalog
    /// failure when all of them failed), used for the failure copy.
    ///
    /// Review r1 P3-1: `.requestfailed` is a failure whatever the manifest state. Kotlin emits it
    /// only when a manifest failed with none loaded, or when EVERY catalog of the fan-out failed
    /// (`resolveEmptyState`); an empty page is `Empty`, so a real "nothing matched" never gets
    /// here. Reading it as "No results" hid a dropped connection behind a wrong message with no
    /// Retry.
    static func resolve(
        reason: SearchEmptyStateReason?,
        hasEnabledAddons: Bool,
        anyManifestLoaded: Bool,
        searchOptionCount: Int,
        disabledOptionCount: Int,
        query: String,
        errorMessage: String? = nil
    ) -> SearchEmptyState? {
        guard let reason else { return nil }
        if reason == SearchEmptyStateReason.requestfailed {
            let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .manifestFailure(
                (message?.isEmpty == false ? message : nil) ?? String(localized: "Couldn't load your add-ons.")
            )
        }
        if reason == SearchEmptyStateReason.noactiveaddons
            || (reason == SearchEmptyStateReason.nosearchcatalogs && searchOptionCount == 0) {
            return .noneCanSearch
        }
        if searchOptionCount > 0 && disabledOptionCount >= searchOptionCount {
            return .allSourcesOff
        }
        return .noResults(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var copy: String {
        switch self {
        case .manifestFailure(let message): return message
        case .noneCanSearch: return String(localized: "None of your add-ons can search")
        case .allSourcesOff: return String(localized: "All search sources are off")
        case .noResults(let query): return String(localized: "No results for \u{2018}\(query)\u{2019}")
        }
    }

    /// The button under the copy, if any: Retry for a manifest failure, "Open Search Sources" when
    /// every source is off.
    var actionTitle: String? {
        switch self {
        case .manifestFailure: return String(localized: "Retry")
        case .allSourcesOff: return String(localized: "Open Search Sources")
        case .noneCanSearch, .noResults: return nil
        }
    }
}
