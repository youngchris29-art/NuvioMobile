import Combine
import SwiftUI
import SharedCore

/// First real content screen for tvOS: a focus-navigable grid of catalog rows, fed entirely by the
/// shared Kotlin `HomeRepository`. Tapping a poster pushes the detail screen.
struct HomeView: View {
    var activeProfile: NuvioProfile? = nil
    var onSwitchProfile: (() -> Void)? = nil
    @StateObject private var model = HomeViewModel()
    @State private var resume: ResumeTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
                        HStack(alignment: .center) {
                            Text("Nuvio")
                                .font(Theme.Font.screenTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Spacer()
                            if let profile = activeProfile, let onSwitchProfile {
                                Button { onSwitchProfile() } label: {
                                    ProfileAvatar(profile: profile, size: 64)
                                }
                                .buttonStyle(.card)
                            }
                        }
                        .padding(.bottom, Theme.Spacing.xs)

                        if !model.heroItems.isEmpty {
                            HeroPager(items: Array(model.heroItems.prefix(8)))
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
                        .buttonStyle(.card)
                        .contextMenu {
                            Button(role: .destructive) {
                                onRemove(entry)
                            } label: {
                                Label("Remove from Continue Watching", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
            }
        }
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

/// Auto-rotating hero carousel: cycles through the hero items every few seconds with a crossfade,
/// pausing while the banner is focused (so it doesn't swap out under the user). Page dots in a
/// Liquid Glass capsule track the position (mobile-reference look).
struct HeroPager: View {
    let items: [MetaPreview]

    @State private var index = 0
    @FocusState private var heroFocused: Bool
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        let safeIndex = min(index, items.count - 1)
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HeroBanner(item: items[safeIndex])
                .id(items[safeIndex].id)
                .focused($heroFocused)

            if items.count > 1 {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(0..<items.count, id: \.self) { i in
                        Capsule()
                            .fill(i == safeIndex
                                  ? Theme.Palette.textPrimary
                                  : Theme.Palette.textSecondary.opacity(0.45))
                            .frame(width: i == safeIndex ? 34 : 10, height: 10)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .glassEffect(.regular, in: .capsule)
                .padding(.leading, Theme.Spacing.xs)
                .animation(.easeInOut(duration: 0.3), value: safeIndex)
            }
        }
        .onReceive(timer) { _ in
            guard items.count > 1, !heroFocused else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                index = (safeIndex + 1) % items.count
            }
        }
        .onChange(of: items.count) { _, newCount in
            if index >= newCount { index = 0 }
        }
    }
}

/// Large featured banner at the top of Home for the first hero item — backdrop, logo/title, a short
/// synopsis, and metadata. Tapping opens the detail screen.
struct HeroBanner: View {
    let item: MetaPreview

    var body: some View {
        NavigationLink(value: TitleRoute(preview: item)) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(string: backdropURL)
                    .frame(height: Theme.Size.heroHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            colors: [.black.opacity(0.85), .black.opacity(0.2), .clear],
                            startPoint: .bottom, endPoint: .top
                        )
                    )

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
                .padding(Theme.Spacing.xl)
            }
            .frame(height: Theme.Size.heroHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero))
        }
        .buttonStyle(.card)
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

    private var backdropURL: String? {
        let banner: String? = item.banner
        if let banner, !banner.isEmpty { return banner }
        let poster: String? = item.poster
        return poster
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
