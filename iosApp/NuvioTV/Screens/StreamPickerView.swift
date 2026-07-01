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
                VStack(alignment: .leading, spacing: 32) {
                    if model.isLoading {
                        HStack(spacing: 16) {
                            ProgressView()
                            Text("Finding streams\u{2026}").foregroundStyle(.secondary)
                        }
                    }

                    ForEach(model.groups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.addonName).font(.title3).bold()
                            ForEach(Array(group.streams.enumerated()), id: \.offset) { _, stream in
                                streamRow(stream)
                            }
                        }
                    }

                    if let reason = model.emptyReason {
                        Text(reason).foregroundStyle(.secondary).padding(.top, 8)
                    }

                    // Dev/verification affordance — always available.
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Test").font(.title3).bold()
                        Button {
                            selected = context(url: testStreamURL, stream: nil)
                        } label: {
                            Label("Play test stream (Apple HLS sample)", systemImage: "play.circle")
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 24)
                }
                .padding(60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title)
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
        return Button {
            if let urlString, let url = URL(string: urlString) {
                selected = context(url: url, stream: stream)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).lineLimit(2)
                if let desc, !desc.isEmpty {
                    Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
    }
}

