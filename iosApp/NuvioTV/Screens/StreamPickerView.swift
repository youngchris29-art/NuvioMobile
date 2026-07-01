import SwiftUI
import SharedCore

/// Presented when the user taps Play. Resolves streams for the title, lists the playable ones grouped
/// by addon, and opens the native player on selection.
///
/// Includes one clearly-marked "test stream" (Apple's public HLS sample) so the AVPlayer path can be
/// verified on the simulator even before a real streaming addon is installed. Remove `testStreamURL`
/// once a direct-link / debrid addon is wired in.
struct StreamPickerView: View {
    let type: String
    let videoId: String
    let title: String

    let parentMetaId: String
    let season: Int?
    let episode: Int?

    @StateObject private var model: StreamsViewModel
    @State private var selected: PlaybackContext?
    @Environment(\.dismiss) private var dismiss

    private let testStreamURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!

    init(type: String, videoId: String, title: String, parentMetaId: String? = nil, season: Int? = nil, episode: Int? = nil) {
        self.type = type
        self.videoId = videoId
        self.title = title
        self.parentMetaId = parentMetaId ?? videoId
        self.season = season
        self.episode = episode
        _model = StateObject(wrappedValue: StreamsViewModel(
            type: type, videoId: videoId, parentMetaId: parentMetaId, season: season, episode: episode
        ))
    }

    private func context(url: URL, stream: StreamItem?) -> PlaybackContext {
        PlaybackContext(
            url: url,
            title: title,
            contentType: type,
            parentMetaId: parentMetaId,
            videoId: videoId,
            season: season,
            episode: episode,
            poster: nil,
            background: nil,
            providerName: stream?.addonName,
            providerAddonId: stream?.addonId,
            streamTitle: stream.map { $0.streamLabel },
            streamSubtitle: { let s: String? = stream?.description_; return s }(),
            externalSubtitles: (stream?.externalSubtitles ?? []).map { sub in
                SubtitleFile(url: sub.url, language: sub.language, name: { let n: String? = sub.name; return n }())
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl - Theme.Spacing.xs) {
                    Text(title)
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    if model.isLoading {
                        HStack(spacing: Theme.Spacing.md) {
                            ProgressView()
                            Text("Finding streams\u{2026}").foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }

                    ForEach(model.groups) { group in
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text(group.addonName)
                                .font(Theme.Font.sectionTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            ForEach(Array(group.streams.enumerated()), id: \.offset) { _, stream in
                                streamRow(stream)
                            }
                        }
                    }

                    if let reason = model.emptyReason {
                        Text(reason)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.top, Theme.Spacing.xs)
                    }

                    // Dev/verification affordance — always available.
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Test")
                            .font(Theme.Font.sectionTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Button {
                            selected = context(url: testStreamURL, stream: nil)
                        } label: {
                            Label("Play test stream (Apple HLS sample)", systemImage: "play.circle")
                                .padding(.vertical, Theme.Spacing.xs)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, Theme.Spacing.lg)
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Palette.background.ignoresSafeArea())
            .onAppear { model.start() }
            .onDisappear { model.stop() }
            .fullScreenCover(item: $selected) { ctx in
                MPVPlayerScreen(context: ctx)
                    .ignoresSafeArea()
            }
        }
    }

    private func streamRow(_ stream: StreamItem) -> some View {
        // Kotlin nullable Strings surface as non-optional Swift String, so widen explicitly to String?.
        let urlString: String? = stream.playableDirectUrl
        let title: String = stream.streamLabel
        let desc: String? = stream.description_
        let badges: [StreamBadge] = stream.badges
        return Button {
            if let urlString, let url = URL(string: urlString) {
                selected = context(url: url, stream: stream)
            }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                if !badges.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(Array(badges.prefix(6).enumerated()), id: \.offset) { _, badge in
                            StreamBadgeChip(badge: badge)
                        }
                    }
                }
                if let desc, !desc.isEmpty {
                    Text(desc)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.Spacing.xs + 2)
        }
        .buttonStyle(.bordered)
    }
}

/// A single quality/source chip derived from a shared `StreamBadge` (resolution, HDR, cached, etc.).
/// Uses the badge's own hex colors when present, falling back to design-system defaults.
private struct StreamBadgeChip: View {
    let badge: StreamBadge

    var body: some View {
        let background = Color(hexString: badge.tagColor) ?? Theme.Palette.surfaceElevated
        let foreground = Color(hexString: badge.textColor) ?? Theme.Palette.textPrimary
        let border = Color(hexString: badge.borderColor)

        Text(badge.name)
            .font(Theme.Font.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(background, in: Capsule())
            .overlay(
                Capsule().stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1)
            )
    }
}

