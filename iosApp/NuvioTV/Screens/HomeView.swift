import Combine
import SwiftUI
import SharedCore

/// First real content screen for tvOS: a focus-navigable grid of catalog rows, fed entirely by the
/// shared Kotlin `HomeRepository`. Tapping a poster pushes the detail screen.
struct HomeView: View {
    @StateObject private var model = HomeViewModel()
    @State private var resume: ResumeTarget?

    // Hero rotation state, hoisted here so the full-bleed backdrop (behind the scroll) and the
    // focusable text overlay (inside the scroll) share the same index.
    @State private var heroIndex = 0
    @FocusState private var heroFocused: Bool
    private let heroTimer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    private var heroItems: [MetaPreview] { Array(model.heroItems.prefix(8)) }
    private var currentHero: MetaPreview? {
        guard !heroItems.isEmpty else { return nil }
        return heroItems[min(heroIndex, heroItems.count - 1)]
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.Palette.background.ignoresSafeArea()

                // Full-bleed hero backdrop runs to every edge (and under the floating glass tab
                // bar); the rows scroll over it, Detail-style.
                // Only show the artwork while the hero itself is highlighted; once focus moves
                // down into Continue Watching / the catalogs, fade to the flat dark background.
                if let hero = currentHero {
                    Group {
                        HomeHeroBackdrop(item: hero)
                        HomeHeroScrim()
                    }
                    .opacity(heroFocused ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: heroFocused)
                }

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
                        if let hero = currentHero {
                            HomeHeroForeground(
                                item: hero,
                                pageCount: heroItems.count,
                                index: min(heroIndex, heroItems.count - 1)
                            )
                            .focused($heroFocused)
                            .focusSection()
                            .padding(.top, Theme.Size.heroForegroundTopPad)
                        }

                        if model.rows.isEmpty {
                            placeholder
                        }

                        if !model.continueWatching.isEmpty {
                            ContinueWatchingRow(
                                entries: model.continueWatching,
                                onSelect: { resume = ResumeTarget(entry: $0) },
                                onRemove: { WatchProgressRepository.shared.clearProgress(videoId: $0.videoId) }
                            )
                        }

                        // Catalog sections and collection folder-tile rows, interleaved per the
                        // user's Home Rows settings order.
                        ForEach(model.rows) { row in
                            switch row {
                            case .catalog(let section):
                                CatalogRowView(section: section)
                            case .collection(let collection):
                                CollectionRowView(collection: collection)
                            }
                        }
                    }
                    .padding(Theme.Spacing.screen)
                }
                .scrollClipDisabled()
            }
            .onReceive(heroTimer) { _ in
                guard heroItems.count > 1, !heroFocused else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    heroIndex = (min(heroIndex, heroItems.count - 1) + 1) % heroItems.count
                }
            }
            .onChange(of: heroItems.count) { _, newCount in
                if heroIndex >= newCount { heroIndex = 0 }
            }
            .navigationDestination(for: TitleRoute.self) { route in
                DetailView(preview: route.preview)
            }
            .navigationDestination(for: CatalogRoute.self) { route in
                CatalogGridView(route: route)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonDetailView(personId: route.id, personName: route.name)
            }
            .navigationDestination(for: EntityRoute.self) { route in
                EntityBrowseView(route: route)
            }
            .navigationDestination(for: FolderRoute.self) { route in
                FolderDetailView(route: route)
            }
            .fullScreenCover(item: $resume) { target in
                StreamPickerView(
                    type: target.entry.parentMetaType,
                    videoId: target.entry.videoId,
                    title: target.entry.title,
                    parentMetaId: target.entry.parentMetaId,
                    season: target.entry.seasonNumber?.value,
                    episode: target.entry.episodeNumber?.value
                )
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.isLoading {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Loading catalogs\u{2026}")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.vertical, Theme.Spacing.xl)
        } else if let message = model.errorMessage {
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.vertical, Theme.Spacing.xl)
        } else {
            Text("Setting up your catalogs\u{2026}")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.vertical, Theme.Spacing.xl)
        }
    }
}

/// Horizontal "Continue Watching" row of in-progress titles with a progress bar. Tapping a card opens
/// the stream picker for that exact video (the in-progress episode for series), and playback resumes
/// from the saved position.
struct ContinueWatchingRow: View {
    let entries: [WatchProgressEntry]
    let onSelect: (WatchProgressEntry) -> Void
    let onRemove: (WatchProgressEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Continue Watching")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Spacing.rowGap) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Button { onSelect(entry) } label: {
                            LandscapeCard(
                                title: entry.title,
                                imageURL: imageURL(entry),
                                progress: fraction(entry)
                            )
                        }
                        .buttonStyle(.poster)
                        .contextMenu {
                            Button(role: .destructive) {
                                onRemove(entry)
                            } label: {
                                Label("Remove from Continue Watching", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private func fraction(_ entry: WatchProgressEntry) -> Double? {
        entry.durationMs > 0 ? Double(entry.lastPositionMs) / Double(entry.durationMs) : nil
    }

    private func imageURL(_ entry: WatchProgressEntry) -> String? {
        let bg: String? = entry.background
        if let bg, !bg.isEmpty { return bg }
        let poster: String? = entry.poster
        return poster
    }
}

/// Identifiable wrapper so a progress entry can drive `.fullScreenCover(item:)` for direct resume.
struct ResumeTarget: Identifiable {
    let entry: WatchProgressEntry
    var id: String { entry.videoId }
}

/// Full-bleed hero backdrop drawn behind the scrolling rows (Detail-style): fills the top region
/// to every edge — no corner radius, no inset — and runs under the floating glass tab bar. The
/// image crossfades when the parent advances `item`.
struct HomeHeroBackdrop: View {
    let item: MetaPreview

    var body: some View {
        CachedAsyncImage(string: backdropURL)
            .frame(height: Theme.Size.heroBackdropHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .id(item.id)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.6), value: item.id)
    }

    private var backdropURL: String? {
        let banner: String? = item.banner
        if let banner, !banner.isEmpty { return banner }
        let poster: String? = item.poster
        return poster
    }
}

/// Gradient scrims over the hero backdrop: a subtle top darkening under the tab bar, and a bottom
/// fade to the app background so the backdrop blends into the rows region below.
struct HomeHeroScrim: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.55), location: 0.0),
                .init(color: .black.opacity(0.15), location: 0.18),
                .init(color: .clear, location: 0.42),
                .init(color: Theme.Palette.background.opacity(0.85), location: 0.82),
                .init(color: Theme.Palette.background, location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: Theme.Size.heroBackdropHeight)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The interactive hero: logo/title, metadata and a short synopsis, plus page dots — a single
/// focusable target that opens the detail screen. Sits in the scroll content (pushed down onto the
/// lower third of the backdrop by the parent's top padding), so it scrolls away with the rows.
struct HomeHeroForeground: View {
    let item: MetaPreview
    let pageCount: Int
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            NavigationLink(value: TitleRoute(preview: item)) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    logo

                    if !metaLine.isEmpty {
                        Text(metaLine)
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                    }

                    if let synopsis, !synopsis.isEmpty {
                        Text(synopsis)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))
                            .lineLimit(2)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.card)

            if pageCount > 1 {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Capsule()
                            .fill(i == index
                                  ? Theme.Palette.textPrimary
                                  : Theme.Palette.textSecondary.opacity(0.45))
                            .frame(width: i == index ? 34 : 10, height: 10)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .glassEffect(.regular, in: .capsule)
                .padding(.leading, Theme.Spacing.lg)
                .animation(.easeInOut(duration: 0.3), value: index)
            }
        }
    }

    @ViewBuilder
    private var logo: some View {
        if let logoURL {
            AsyncImage(url: URL(string: logoURL)) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text(item.name).font(Theme.Font.hero).foregroundStyle(Theme.Palette.textPrimary)
                }
            }
            .frame(maxWidth: 520, maxHeight: 150, alignment: .leading)
        } else {
            Text(item.name).font(Theme.Font.hero).foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    private var logoURL: String? {
        let logo: String? = item.logo
        return (logo?.isEmpty == false) ? logo : nil
    }

    private var synopsis: String? { item.description_ }

    private var metaLine: String {
        var parts: [String] = []
        let release: String? = item.releaseInfo
        if let release, !release.isEmpty { parts.append(release) }
        let genres = item.genres.prefix(3)
        if !genres.isEmpty { parts.append(genres.joined(separator: " \u{00B7} ")) }
        return parts.joined(separator: "  \u{00B7}  ")
    }
}
