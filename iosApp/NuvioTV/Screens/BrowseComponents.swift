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

/// One horizontal catalog (e.g. "Popular Movies", or a search-result group) as a focus-scrollable row
/// of poster cards.
///
/// By default each card is a `NavigationLink` to the title's detail screen (used on Home). Pass
/// `onSelect` to instead handle taps manually — Search uses this to dismiss the keyboard before
/// navigating.
struct CatalogRowView: View {
    let section: HomeCatalogSection
    var onSelect: ((MetaPreview) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(section.title)
                .font(.title2).bold()

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(section.items, id: \.id) { item in
                        if let onSelect {
                            Button { onSelect(item) } label: { PosterCardView(item: item) }
                                .buttonStyle(.card)
                        } else {
                            NavigationLink(value: TitleRoute(preview: item)) {
                                PosterCardView(item: item)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}

/// A single poster tile. `.card` button style (applied to the enclosing NavigationLink) gives the
/// standard tvOS focus lift/parallax.
struct PosterCardView: View {
    let item: MetaPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: URL(string: item.poster ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty:
                    ZStack { Color.gray.opacity(0.2); ProgressView() }
                case .failure:
                    ZStack {
                        Color.gray.opacity(0.2)
                        Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                    }
                @unknown default:
                    Color.gray.opacity(0.2)
                }
            }
            .frame(width: 220, height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)
        }
    }
}
