import SwiftUI
import SharedCore

/// Full detail screen for a single title, fed by the shared `MetaDetailsRepository`.
/// Constructed from a `MetaPreview` (the card the user focused), then enriched in place as the
/// repository resolves full metadata.
struct DetailView: View {
    let preview: MetaPreview

    @StateObject private var model: DetailViewModel
    @State private var showStreams = false

    init(preview: MetaPreview) {
        self.preview = preview
        _model = StateObject(wrappedValue: DetailViewModel(type: preview.type, id: preview.id))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundLayer
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 36) {
                    header
                    metaLine
                    if !isSeries {
                        Button {
                            showStreams = true
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.title3).bold()
                                .padding(.horizontal, 24).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if !genres.isEmpty {
                        Text(genres.joined(separator: " \u{2022} "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let overview, !overview.isEmpty {
                        Text(overview)
                            .font(.body)
                            .frame(maxWidth: 1100, alignment: .leading)
                            .foregroundStyle(.primary)
                    }
                    if let meta = model.meta, EpisodesSection.isSeriesLike(meta) {
                        EpisodesSection(meta: meta)
                    }
                    castRow
                    moreLikeThisRow
                }
                .padding(60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .fullScreenCover(isPresented: $showStreams) {
            StreamPickerView(type: preview.type, videoId: preview.id, title: title)
        }
    }

    // MARK: - Derived values (prefer enriched meta, fall back to the preview card)

    private var isSeries: Bool {
        if let meta = model.meta { return EpisodesSection.isSeriesLike(meta) }
        return preview.type == "series"
    }
    private var title: String { model.meta?.name ?? preview.name }
    // Kotlin `description` collides with NSObject.description, so KMP exposes it as `description_`.
    private var overview: String? { model.meta?.description_ ?? preview.description_ }
    private var genres: [String] { model.meta?.genres ?? preview.genres }
    private var backgroundUrl: String? { model.meta?.background ?? preview.banner ?? preview.poster }
    private var logoUrl: String? { model.meta?.logo ?? preview.logo }

    // MARK: - Sections

    private var backgroundLayer: some View {
        GeometryReader { geo in
            AsyncImage(url: URL(string: backgroundUrl ?? "")) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(
                LinearGradient(
                    colors: [.black.opacity(0.95), .black.opacity(0.4), .black.opacity(0.85)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .overlay(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.9)],
                    startPoint: .center, endPoint: .bottom
                )
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var header: some View {
        if let logoUrl, !logoUrl.isEmpty {
            AsyncImage(url: URL(string: logoUrl)) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text(title).font(.system(size: 64, weight: .bold))
                }
            }
            .frame(maxWidth: 600, maxHeight: 180, alignment: .leading)
        } else {
            Text(title).font(.system(size: 64, weight: .bold))
        }
    }

    private var metaLine: some View {
        HStack(spacing: 18) {
            if let year = model.meta?.releaseInfo ?? preview.releaseInfo, !year.isEmpty {
                label(year)
            }
            if let runtime = model.meta?.runtime, !runtime.isEmpty {
                label(runtime)
            }
            if let rating = model.meta?.imdbRating ?? preview.imdbRating, !rating.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(rating)
                }
                .font(.headline)
            }
            if let age = model.meta?.ageRating, !age.isEmpty {
                label(age).overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(.secondary, lineWidth: 1).padding(-4)
                )
            }
            if model.isLoading { ProgressView() }
        }
        .font(.headline)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var castRow: some View {
        let cast = model.meta?.cast ?? []
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cast").font(.title2).bold()
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
                            CastCard(person: person)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private var moreLikeThisRow: some View {
        let items = model.meta?.moreLikeThis ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("More Like This").font(.title2).bold()
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(items, id: \.id) { item in
                            NavigationLink(value: TitleRoute(preview: item)) {
                                MiniPoster(item: item)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
    }
}

private struct CastCard: View {
    let person: MetaPerson
    var body: some View {
        VStack(spacing: 8) {
            AsyncImage(url: URL(string: person.photo ?? "")) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.gray.opacity(0.25)
                        Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(Circle())
            Text(person.name).font(.caption).lineLimit(1).frame(width: 150)
            if let role = person.role, !role.isEmpty {
                Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 150)
            }
        }
    }
}

private struct MiniPoster: View {
    let item: MetaPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: URL(string: item.poster ?? "")) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(width: 180, height: 270)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.name).font(.caption).lineLimit(1).frame(width: 180, alignment: .leading)
        }
    }
}
