import SwiftUI
import SharedCore

/// First real content screen for tvOS: a focus-navigable grid of catalog rows, fed entirely by the
/// shared Kotlin `HomeRepository`. Tapping a poster pushes the detail screen.
struct HomeView: View {
    @StateObject private var model = HomeViewModel()
    @State private var resume: ResumeTarget?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 48) {
                    Text("Nuvio")
                        .font(.largeTitle).bold()
                        .padding(.bottom, 8)

                    if let hero = model.heroItems.first {
                        HeroBanner(item: hero)
                    }

                    if model.sections.isEmpty {
                        placeholder
                    }

                    if !model.continueWatching.isEmpty {
                        ContinueWatchingRow(
                            entries: model.continueWatching,
                            onSelect: { resume = ResumeTarget(entry: $0) },
                            onRemove: { WatchProgressRepository.shared.clearProgress(videoId: $0.videoId) }
                        )
                    }

                    ForEach(model.sections, id: \.key) { section in
                        CatalogRowView(section: section)
                    }
                }
                .padding(60)
            }
            .navigationDestination(for: TitleRoute.self) { route in
                DetailView(preview: route.preview)
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
            HStack(spacing: 16) {
                ProgressView()
                Text("Loading catalogs\u{2026}").font(.title3).foregroundStyle(.secondary)
            }
            .padding(.vertical, 40)
        } else if let message = model.errorMessage {
            Text(message).font(.title3).foregroundStyle(.red).padding(.vertical, 40)
        } else {
            Text("Setting up your catalogs\u{2026}")
                .font(.title3).foregroundStyle(.secondary).padding(.vertical, 40)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Continue Watching")
                .font(.title2).bold()

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Button { onSelect(entry) } label: {
                            ContinueCard(entry: entry)
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
                .padding(.vertical, 12)
            }
        }
    }
}

/// Identifiable wrapper so a progress entry can drive `.fullScreenCover(item:)` for direct resume.
struct ResumeTarget: Identifiable {
    let entry: WatchProgressEntry
    var id: String { entry.videoId }
}

/// Large featured banner at the top of Home for the first hero item — backdrop, logo/title, a short
/// synopsis, and metadata. Tapping opens the detail screen.
struct HeroBanner: View {
    let item: MetaPreview

    var body: some View {
        NavigationLink(value: TitleRoute(preview: item)) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: backdropURL)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(height: 480)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.85), .black.opacity(0.2), .clear],
                        startPoint: .bottom, endPoint: .top
                    )
                )

                VStack(alignment: .leading, spacing: 14) {
                    if let logo = logoURL {
                        AsyncImage(url: URL(string: logo)) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Text(item.name).font(.system(size: 52, weight: .bold))
                            }
                        }
                        .frame(maxWidth: 520, maxHeight: 150, alignment: .leading)
                    } else {
                        Text(item.name).font(.system(size: 52, weight: .bold))
                    }

                    if !metaLine.isEmpty {
                        Text(metaLine).font(.headline).foregroundStyle(.white.opacity(0.85))
                    }

                    if let synopsis, !synopsis.isEmpty {
                        Text(synopsis)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                }
                .foregroundStyle(.white)
                .padding(40)
            }
            .frame(height: 480)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.card)
    }

    private var backdropURL: String {
        let banner: String? = item.banner
        if let banner, !banner.isEmpty { return banner }
        let poster: String? = item.poster
        return poster ?? ""
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

private struct ContinueCard: View {
    let entry: WatchProgressEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                AsyncImage(url: URL(string: imageURL)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 360, height: 203)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.3))
                        Rectangle().fill(.red).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }
            .frame(width: 360, height: 203)

            Text(entry.title)
                .font(.caption).lineLimit(1)
                .frame(width: 360, alignment: .leading)
        }
    }

    private var fraction: Double {
        entry.durationMs > 0 ? min(max(Double(entry.lastPositionMs) / Double(entry.durationMs), 0), 1) : 0
    }

    private var imageURL: String {
        let bg: String? = entry.background
        if let bg, !bg.isEmpty { return bg }
        let poster: String? = entry.poster
        return poster ?? ""
    }
}
