import SwiftUI
import SharedCore

// Search & Discover batch 2026-10-06 (O1 Dressed Search, plan B3): the pieces `SearchContent`
// (SearchView.swift) lays out under the system search field. Each is a leaf that takes plain values
// and callbacks; none observes the view model, so a results update re-renders them only through
// `SearchContent`.

// MARK: - d. Suggestion chips

/// B3 d: the first row under the system band. Chip 0 is the typed query in curly quotes (selecting
/// it records the query to Recent: the Search key the inline keyboard lacks); the rest are up to
/// eight completions (selecting one puts it in the field). One `.focusSection()`, so Down from the
/// keyboard lands here and a second Down reaches the results.
struct SearchSuggestionRow: View {
    let suggestions: [String]
    /// The typed query (trimmed), for chip 0's accessibility label.
    let query: String
    let onSelect: (_ index: Int, _ text: String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, text in
                    chip(index: index, text: text)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .scrollClipDisabled()
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Suggestions"))
        .accessibilityIdentifier("search.suggestions")
    }

    @ViewBuilder
    private func chip(index: Int, text: String) -> some View {
        let base = FilterChip(title: text,
                              systemImage: index == 0 ? "magnifyingglass" : nil,
                              isActive: false) {
            onSelect(index, text)
        }
        .accessibilityIdentifier("search.suggestion.\(index)")
        if index == 0 {
            base.accessibilityLabel(Text("Search for \(query)"))
        } else {
            base
        }
    }
}

// MARK: - c. Top result

/// B3 c: the search's first answer, bigger than a row card: the poster beside its name, a meta line
/// and where it was found. Grouped mode only (the view model has no Top result per add-on).
struct SearchTopResultCard: View {
    let item: MetaPreview
    /// "Found in Cinemeta and Torrentio", or nil.
    let foundIn: String?
    /// Focus took the card (drives the wash).
    let onFocus: (MetaPreview) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Top result")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            NavigationLink(value: TitleRoute(preview: item)) {
                HStack(alignment: .center, spacing: Theme.Spacing.xl) {
                    PosterCard(title: item.name,
                               imageURL: item.poster,
                               fallbackImageURL: item.rawPosterUrl,
                               showTitle: false)
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(item.name)
                            .font(Theme.Font.sectionTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2)
                        if let meta = Self.metaLine(item) {
                            Text(verbatim: meta)
                                .font(Theme.Font.meta)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                        }
                        if let foundIn {
                            Text(verbatim: foundIn)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                }
            }
            .cardFocusButtonStyle()
            .posterButtonShape()
            .titleHoldMenu(preview: item)
            .focused($focused)
            .onChange(of: focused) { _, isFocused in
                if isFocused { onFocus(item) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.topResult")
    }

    /// "Series · 2021 · IMDb 8.0": the type only when it isn't a movie (the poster says that much),
    /// then the year and a real IMDb rating (never "0.0" or "N/A", BUG-142).
    static func metaLine(_ item: MetaPreview) -> String? {
        var parts: [String] = []
        switch item.type.lowercased() {
        case "series": parts.append(String(localized: "Series"))
        case "anime": parts.append(String(localized: "Anime"))
        case "tv": parts.append(String(localized: "TV"))
        default: break
        }
        if let year = nonBlank(item.releaseInfo) { parts.append(year) }
        if let rating = nonBlank(item.imdbRating), let value = Double(rating), value > 0 {
            parts.append("IMDb \(rating)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - e. People

/// B3 e: TMDB people for the query, each opening the person page. Detail's cast-row idiom: the
/// row's `@FocusState` is the focus truth for the no-zoom still ring and the lifted card's zIndex.
struct SearchPeopleRow: View {
    let people: [MetaPerson]
    /// Focus took a person (the wash keeps what it shows).
    let onFocus: () -> Void

    @FocusState private var focusedIndex: Int?
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    @AppStorage("accent_focus_ring") private var accentFocusRing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("People")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Spacing.lg) {
                    ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                        if let personId = person.tmdbId?.value {
                            NavigationLink(value: PersonRoute(id: personId, name: person.name)) {
                                CastCard(person: person, stillFocused: focusedIndex == index)
                            }
                            // Same as Detail's cast row: the avatar owns its ring-mode lift, and no
                            // `.posterButtonShape()` (the avatar is a circle).
                            .cardFocusButtonStyle()
                            .focused($focusedIndex, equals: index)
                            .zIndex(liftedZIndex(index))
                        } else {
                            CastCard(person: person)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
            .scrollClipDisabled()
            .rowEdgeEffectStyle()
            .focusSection()
        }
        .onChange(of: focusedIndex) { _, index in
            if index != nil { onFocus() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.people")
    }

    private func liftedZIndex(_ index: Int) -> Double {
        let raises = CardFocusMode.resolve(accentFocusRing: accentFocusRing,
                                           noZoomOnFocus: noZoomOnFocus).raisesFocusedCard
        return raises && focusedIndex == index ? 1 : 0
    }
}

// MARK: - g. Empty states

/// B3 g: what a settled search with nothing to show says, with its one action when it has one
/// (Retry for a manifest failure, "Open Search Sources" when every source is off).
struct SearchEmptyStateView: View {
    let state: SearchEmptyState
    let onRetry: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(verbatim: state.copy)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityIdentifier("search.emptyState.copy")
            if let title = state.actionTitle {
                Button {
                    switch state {
                    case .manifestFailure: onRetry()
                    case .allSourcesOff: onOpenSettings()
                    case .noneCanSearch, .noResults: break
                    }
                } label: {
                    Label(title, systemImage: systemImage)
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.chip)
                .accessibilityIdentifier(actionID)
            }
        }
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.emptyState")
    }

    private var systemImage: String {
        if case .allSourcesOff = state { return "gearshape" }
        return "arrow.clockwise"
    }

    private var actionID: String {
        if case .allSourcesOff = state { return "search.emptyState.settings" }
        return "search.emptyState.retry"
    }
}

// MARK: - h. Discover entry (Under Search placement)

/// B3 h: the idle page's way into the stage Discover page when Discover lives under Search. Two
/// tiles, Movies and Series, both pushing `DiscoverRoute()` (the page's own Type pill picks the
/// rest). The tiles report nothing to the wash.
struct DiscoverEntryRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Discover")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Spacing.lg) {
                DiscoverEntryTile(title: String(localized: "Movies"), systemImage: "film")
                DiscoverEntryTile(title: String(localized: "Series"), systemImage: "tv")
            }
            .padding(.vertical, Theme.Spacing.xs)
            .focusSection()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.discoverEntry")
    }
}

/// One Discover entry tile, drawn like the rows' See All tile (`SeeAllCard`): a landscape surface
/// with the type glyph and name, lifting itself (`tileFocusLift`) under the plain card style.
private struct DiscoverEntryTile: View {
    let title: String
    let systemImage: String

    @Environment(\.posterStyle) private var style

    var body: some View {
        NavigationLink(value: DiscoverRoute()) {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .frame(width: Theme.Size.landscapeWidth, height: Theme.Size.landscapeHeight)
            .background(Theme.Palette.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: style.cornerRadius))
            .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: .posters)
            .tileFocusLift(cornerRadius: style.cornerRadius)
        }
        // As the See All tile: the label lifts itself, so ring mode keeps the native lift away.
        .cardFocusButtonStyle(lift: .plain)
        .posterButtonShape()
    }
}
