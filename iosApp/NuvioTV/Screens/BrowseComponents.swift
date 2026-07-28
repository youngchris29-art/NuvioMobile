import SwiftUI
import UIKit
import SharedCore

/// Swift-side navigation value. Kotlin data classes don't conform to Swift `Hashable`, so we wrap the
/// `MetaPreview` and hash on its stable identity (type + id) while still carrying all its fields for
/// the destination's initial render. Shared by Home, Search, and detail "more like this".
struct TitleRoute: Hashable {
    let preview: MetaPreview

    static func == (lhs: TitleRoute, rhs: TitleRoute) -> Bool {
        lhs.preview.id == rhs.preview.id && lhs.preview.type == rhs.preview.type
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(preview.id)
        hasher.combine(preview.type)
    }
}

/// Navigation value for the full-grid "See All" screen. `CatalogTarget` is a Kotlin sealed interface
/// and can't be a `NavigationStack` value directly, so we wrap it — hashing on the section's stable
/// `key` while carrying the title + target for the destination (same approach as `TitleRoute`).
struct CatalogRoute: Hashable {
    let key: String
    let title: String
    let target: any CatalogTarget

    init(section: HomeCatalogSection) {
        self.key = section.key
        self.title = section.title
        self.target = section.target
    }

    static func == (lhs: CatalogRoute, rhs: CatalogRoute) -> Bool { lhs.key == rhs.key }

    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Navigation value for a cast/crew member's detail page (TMDB person id + name for the initial
/// render). Only produced when a `MetaPerson` has a `tmdbId`. Hashes on the id.
struct PersonRoute: Hashable {
    let id: Int
    let name: String

    static func == (lhs: PersonRoute, rhs: PersonRoute) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Navigation value for a studio/network browse page (TMDB discover-by-company/network). Only
/// produced when a `MetaCompany` has a `tmdbId`. `isNetwork` picks the TMDB entity kind (networks
/// come from `meta.networks`, studios from `meta.productionCompanies`); `sourceType` is the origin
/// title's type ("movie"/"series"), which orders the rails. Hashes on kind + id.
struct EntityRoute: Hashable {
    let id: Int
    let name: String
    let isNetwork: Bool
    let sourceType: String

    static func == (lhs: EntityRoute, rhs: EntityRoute) -> Bool {
        lhs.id == rhs.id && lhs.isNetwork == rhs.isNetwork
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(isNetwork)
    }
}

/// One horizontal catalog (e.g. "Popular Movies", or a search-result group) as a focus-scrollable row
/// of poster cards.
///
/// By default each card is a `NavigationLink` to the title's detail screen (used on Home). Pass
/// `onSelect` to instead handle taps manually — Search uses this to dismiss the keyboard before
/// navigating.
struct CatalogRowView: View {
    /// BUG-13: the Home fetch trims each row to `HOME_CATALOG_PREVIEW_FETCH_LIMIT` items
    /// (HomeRepository.kt) while `availableItemCount` keeps the addon's real first-page count. Rows
    /// built that way must pass this limit so the "See All" gate can spot a truncated catalog.
    static let homePreviewLimit = 18

    let section: HomeCatalogSection
    /// Number of items the producing repository kept for this row, or `nil` when the row already
    /// renders everything it fetched (Search) — then only `hasMore` can open the full grid.
    var previewLimit: Int? = nil
    var onSelect: ((MetaPreview) -> Void)? = nil

    /// Inline trailer previews on focus dwell (see `InlineTrailerCard`). Device-local on purpose —
    /// whether a living-room Apple TV should autoplay trailers is a per-device call, not a synced
    /// account preference. On by default; Settings owns the toggle UI.
    @AppStorage("inline_trailers_enabled") private var inlineTrailersEnabled = true

    /// Which card holds focus. Needed here (rather than inside the card) because tvOS delivers
    /// remote commands to the *focused view chain* — the `Button`/`NavigationLink` below, never its
    /// label — so the play/pause mute toggle has to be attached at this level and gated on "this is
    /// the focused item, and it is the one playing".
    @FocusState private var focusedItemId: String?

    /// Which card currently owns the single inline `AVPlayer`, published by the shared coordinator.
    @ObservedObject private var trailerCoordinator = InlineTrailerCoordinator.shared

    /// tvOS Accessibility ▸ Motion ▸ Auto-Play Video Previews. When the user has turned previews off
    /// system-wide, the row must render exactly as it did before this feature existed.
    private var inlineTrailersActive: Bool {
        inlineTrailersEnabled && UIAccessibility.isVideoAutoplayEnabled
    }

    /// BUG-13: an addon whose manifest declares no `skip` extra always reports `hasMore == false`,
    /// even when its single response carried far more titles than the row kept — gating on `hasMore`
    /// alone made those catalogs a dead end. Mirrors composeApp's Home gate, which uses the same
    /// shared `canOpenCatalog(previewLimit:)` (HomeModels.kt: availableItemCount > previewLimit || hasMore).
    private var canOpenFullCatalog: Bool {
        guard let previewLimit else { return section.hasMore }
        return section.canOpenCatalog(previewLimit: Int32(previewLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Spacer()

                // Only when the full catalog holds more than this row shows (see `canOpenFullCatalog`).
                if canOpenFullCatalog {
                    NavigationLink(value: CatalogRoute(section: section)) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text("See All")
                            Image(systemName: "chevron.right")
                        }
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                    .buttonStyle(.glass)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Spacing.rowGap) {
                    ForEach(section.items, id: \.id) { item in
                        Group {
                            if let onSelect {
                                Button { onSelect(item) } label: { card(for: item) }
                                    .buttonStyle(.poster)
                            } else {
                                NavigationLink(value: TitleRoute(preview: item)) {
                                    card(for: item)
                                }
                                .buttonStyle(.poster)
                            }
                        }
                        .focused($focusedItemId, equals: item.id)
                        // Mirrors Detail's hero trailer: the card's mute glyph isn't reachable by
                        // the focus engine, so play/pause is the toggle. Nil unless *this* focused
                        // card is the one playing — an unconditional handler would swallow
                        // play/pause from everything else that wants it (Home's hero).
                        .onPlayPauseCommand(perform: muteToggle(for: item))
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    /// Portrait poster by default; a 16:9 landscape card when the user enables landscape catalog
    /// rows — both rendered by `InlineTrailerCard`, which also grows the muted trailer preview once
    /// focus rests on the card. With inline trailers off it is a straight pass-through to the same
    /// two cards, so the row is unchanged.
    private func card(for item: MetaPreview) -> some View {
        InlineTrailerCard(item: item, enabled: inlineTrailersActive)
    }

    /// Play/pause handler for `item`'s focusable button, or `nil` when this card isn't the focused,
    /// currently-playing one — `.onPlayPauseCommand(perform: nil)` leaves the command to whoever
    /// else is listening instead of consuming it.
    private func muteToggle(for item: MetaPreview) -> (() -> Void)? {
        guard focusedItemId == item.id,
              trailerCoordinator.playingKey == TrailerResolutionCache.key(type: item.type, id: item.id)
        else { return nil }
        return { HeroTrailerAudioState.shared.toggleMuted() }
    }
}

/// A single poster tile, now backed by the shared `PosterCard` design-system component
/// (cached artwork, shimmer, brand focus ring, focus-aware title).
struct PosterCardView: View {
    let item: MetaPreview

    var body: some View {
        PosterCard(title: item.name, imageURL: item.poster)
    }
}
