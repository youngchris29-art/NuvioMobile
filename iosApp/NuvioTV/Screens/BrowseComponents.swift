import SwiftUI
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

/// One horizontal catalog (e.g. "Popular Movies", or a search-result group) as a focus-scrollable row
/// of poster cards.
///
/// By default each card is a `NavigationLink` to the title's detail screen (used on Home). Pass
/// `onSelect` to instead handle taps manually — Search uses this to dismiss the keyboard before
/// navigating.
struct CatalogRowView: View {
    let section: HomeCatalogSection
    var onSelect: ((MetaPreview) -> Void)? = nil

    @Environment(\.posterStyle) private var posterStyle

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Spacer()

                // Only when the catalog can actually page further (hasMore = supportsPagination && nextSkip != nil).
                if section.hasMore {
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
                        if let onSelect {
                            Button { onSelect(item) } label: { card(for: item) }
                                .buttonStyle(.card)
                        } else {
                            NavigationLink(value: TitleRoute(preview: item)) {
                                card(for: item)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
            }
        }
    }

    /// Portrait poster by default; a 16:9 landscape card when the user enables landscape catalog rows.
    @ViewBuilder
    private func card(for item: MetaPreview) -> some View {
        if posterStyle.landscapeCatalogRows {
            LandscapeCard(title: item.name, imageURL: landscapeImageURL(item))
        } else {
            PosterCardView(item: item)
        }
    }

    private func landscapeImageURL(_ item: MetaPreview) -> String? {
        let banner: String? = item.banner
        if let banner, !banner.isEmpty { return banner }
        let poster: String? = item.poster
        return poster
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
