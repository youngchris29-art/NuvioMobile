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
        _model = StateObject(wrappedValue: DetailViewModel(preview: preview))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdropImage
            // Tear the trailer's libmpv instance down while the stream player (also libmpv) is open,
            // so two GPU/Vulkan contexts never render at once; it resumes when the player dismisses.
            if let trailer = model.trailerVideoURL, !showStreams {
                TrailerHeroPlayer(videoURL: trailer, onFailure: { model.trailerFailed() })
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            scrimOverlay
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg + Theme.Spacing.sm) {
                    header
                    metaLine
                    actionRow
                    if !genres.isEmpty {
                        Text(genres.joined(separator: " \u{2022} "))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    if let overview, !overview.isEmpty {
                        Text(overview)
                            .font(Theme.Font.body)
                            .frame(maxWidth: 1100, alignment: .leading)
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    if let meta = model.meta, EpisodesSection.isSeriesLike(meta) {
                        EpisodesSection(meta: meta)
                    }
                    castRow
                    moreLikeThisRow
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: model.trailerVideoURL != nil)
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

    private var backdropImage: some View {
        GeometryReader { geo in
            CachedAsyncImage(string: backgroundUrl)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        .ignoresSafeArea()
    }

    /// Gradient scrims for text legibility, drawn over the backdrop (and the trailer, when present).
    private var scrimOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.95), .black.opacity(0.4), .black.opacity(0.85)],
                startPoint: .leading, endPoint: .trailing
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.9)],
                startPoint: .center, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var header: some View {
        if let logoUrl, !logoUrl.isEmpty {
            AsyncImage(url: URL(string: logoUrl)) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text(title).font(Theme.Font.hero).foregroundStyle(Theme.Palette.textPrimary)
                }
            }
            .frame(maxWidth: 600, maxHeight: 180, alignment: .leading)
        } else {
            Text(title).font(Theme.Font.hero).foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.md + 2) {
            if let year = model.meta?.releaseInfo ?? preview.releaseInfo, !year.isEmpty {
                label(year)
            }
            if let runtime = model.meta?.runtime, !runtime.isEmpty {
                label(runtime)
            }
            if let rating = model.meta?.imdbRating ?? preview.imdbRating, !rating.isEmpty {
                HStack(spacing: Theme.Spacing.xs - 2) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.star)
                    Text(rating)
                }
            }
            if let age = model.meta?.ageRating, !age.isEmpty {
                label(age).overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip - 2)
                        .stroke(Theme.Palette.textSecondary, lineWidth: 1).padding(-4)
                )
            }
            if model.isLoading { ProgressView() }
        }
        .font(Theme.Font.meta)
        .foregroundStyle(Theme.Palette.textSecondary)
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            if !isSeries {
                Button {
                    showStreams = true
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xxs + 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
            }

            Button {
                model.toggleWatched()
            } label: {
                Label(
                    model.isWatched ? "Watched" : "Mark Watched",
                    systemImage: model.isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                )
                .font(Theme.Font.meta)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xxs + 2)
            }
            .buttonStyle(.bordered)
            .tint(model.isWatched ? Theme.Palette.accent : nil)

            Button {
                model.toggleLibrary()
            } label: {
                Label(
                    model.isSaved ? "In Library" : "Add to Library",
                    systemImage: model.isSaved ? "checkmark" : "plus"
                )
                .font(Theme.Font.meta)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xxs + 2)
            }
            .buttonStyle(.bordered)
            .tint(model.isSaved ? Theme.Palette.accent : nil)
        }
    }

    @ViewBuilder
    private var castRow: some View {
        let cast = model.meta?.cast ?? []
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Cast")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.lg) {
                        ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
                            CastCard(person: person)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
    }

    @ViewBuilder
    private var moreLikeThisRow: some View {
        let items = model.meta?.moreLikeThis ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("More Like This")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.lg) {
                        ForEach(items, id: \.id) { item in
                            NavigationLink(value: TitleRoute(preview: item)) {
                                PosterCard(
                                    title: item.name,
                                    imageURL: item.poster,
                                    width: Theme.Size.miniPosterWidth,
                                    height: Theme.Size.miniPosterHeight
                                )
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
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
        VStack(spacing: Theme.Spacing.xs) {
            AsyncImage(url: URL(string: person.photo ?? "")) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Theme.Palette.surface
                        Image(systemName: "person.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            .frame(width: Theme.Size.castAvatar, height: Theme.Size.castAvatar)
            .clipShape(Circle())
            Text(person.name)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .frame(width: Theme.Size.castAvatar + 10)
            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .frame(width: Theme.Size.castAvatar + 10)
            }
        }
    }
}
