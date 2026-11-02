import SharedCore
import SwiftUI

/// The pieces of the player's "Playback" panel tab that both engines share (P4 A8): the speed
/// row, the episode jump list and the alternate-sources list. `MPVPlaybackTab` composes them
/// with its mpv-only Timing and Diagnostics sections; `NativePlaybackTab` composes them alone.
/// Moved unchanged (look, copy and accessibility ids) out of `MPVPlaybackTab`.
enum PlayerPlaybackColumns {
    /// The one speed list, shared by the panel row and the native player's system speed pill.
    static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
}

// MARK: - Speed

/// One row of speed buttons. The selected one carries a checkmark and, for UI legs,
/// `accessibilityValue("selected")`. A rate outside the list shows no checkmark.
struct PlayerSpeedRow: View {
    let current: Double
    let onSelect: (Double) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(PlayerPlaybackColumns.speeds, id: \.self) { speed in
                Button { onSelect(speed) } label: {
                    HStack(spacing: Theme.Spacing.xxs) {
                        if current == speed { Image(systemName: "checkmark") }
                        Text(String(format: "%g\u{00D7}", speed))
                    }
                    .font(Theme.Font.meta)
                }
                .accessibilityIdentifier("player.panel.speed.\(speed)")
                .accessibilityValue(current == speed ? "selected" : "")
            }
        }
    }
}

/// "Remember Speed for This Show" (P5 B23): one toggle under the speed row, series only.
struct PlayerRememberSpeedRow: View {
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                Text("Remember Speed for This Show")
            }
            .font(Theme.Font.meta)
        }
        .accessibilityIdentifier("player.panel.speed.remember")
        .accessibilityValue(Text(verbatim: isOn ? "on" : "off"))
    }
}

// MARK: - Episodes (jump to any aired episode)

struct PlayerEpisodesColumn: View {
    @ObservedObject var engine: NextEpisodeEngine
    let onClose: () -> Void
    /// Optional: bound to the first row so a host can move focus into this column (the native
    /// transport bar's Episodes item). nil (mpv) leaves focus entirely to the engine.
    var firstRowFocus: FocusState<Bool>.Binding? = nil
    /// Called when the first rows arrive in a column that had none (mpv: the overlay asks the
    /// focus engine to move in again, its open-time retries having ended before the rows loaded).
    var onFirstRowsAppear: (() -> Void)? = nil

    /// The engine's episodes with a season and number, in season/episode order. Shared with the
    /// tabs so they can hide the column when it would be empty.
    static func sortedEpisodes(_ engine: NextEpisodeEngine) -> [MetaVideo] {
        engine.episodes
            .compactMap { video -> (MetaVideo, Int, Int)? in
                guard let s = video.season?.value, let e = video.episode?.value else { return nil }
                return (video, s, e)
            }
            .sorted { a, b in a.1 == b.1 ? a.2 < b.2 : a.1 < b.1 }
            .map { $0.0 }
    }

    var body: some View {
        let watched = watchedEpisodeKeys
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            PlayerPanelSectionCaption(text: String(localized: "Episodes"))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(Array(sortedEpisodes.enumerated()), id: \.offset) { index, episode in
                        let isCurrent = isCurrentEpisode(episode)
                        Button {
                            guard !isCurrent else { return }
                            engine.jumpToEpisode(episode)
                            onClose()
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: isCurrent ? "play.fill" : "checkmark")
                                    .font(Theme.Font.caption.weight(.semibold))
                                    .opacity(isCurrent || watched.contains(episodeKey(episode)) ? 1 : 0)
                                    .frame(width: 28)
                                Text(episodeChipLabel(episode)).font(Theme.Font.meta).frame(width: 90, alignment: .leading)
                                Text(episode.title).font(Theme.Font.body).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .focusedIfBound(index == 0 ? firstRowFocus : nil)
                    }
                }
            }
            Text("Jumping finds a stream automatically and switches playback.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .onChange(of: sortedEpisodes.count) { old, new in
            if PlayerOverlayRowFocus.shouldRefocus(oldRowCount: old, newRowCount: new) { onFirstRowsAppear?() }
        }
    }

    private var sortedEpisodes: [MetaVideo] { Self.sortedEpisodes(engine) }

    /// "season:episode" keys for episodes to mark watched — explicit Watched marks OR
    /// effectively-completed progress (same rule as the Detail screen's badges).
    private var watchedEpisodeKeys: Set<String> {
        WatchedRepository.shared.ensureLoaded()
        WatchProgressRepository.shared.ensureLoaded()
        var keys: Set<String> = []
        for episode in sortedEpisodes {
            guard let s = episode.season?.value, let e = episode.episode?.value else { continue }
            let season = KotlinInt(int: Int32(s)), number = KotlinInt(int: Int32(e))
            let marked = WatchedRepository.shared.isWatched(
                id: engine.parentMetaId, type: engine.contentType, season: season, episode: number)
            let completed = WatchProgressRepository.shared.progressForVideo(
                videoId: "\(engine.parentMetaId):\(s):\(e)", parentMetaId: engine.parentMetaId,
                seasonNumber: season, episodeNumber: number)?.isEffectivelyCompleted == true
            if marked || completed { keys.insert("\(s):\(e)") }
        }
        return keys
    }

    private func episodeKey(_ episode: MetaVideo) -> String {
        guard let s = episode.season?.value, let e = episode.episode?.value else { return episode.id }
        return "\(s):\(e)"
    }

    private func isCurrentEpisode(_ episode: MetaVideo) -> Bool {
        guard let s = episode.season?.value, let e = episode.episode?.value else { return false }
        return s == engine.currentSeason && e == engine.currentEpisode
    }

    private func episodeChipLabel(_ episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value { return "S\(s)E\(e)" }
        return episode.title
    }
}

// MARK: - Sources (switch the current video's stream)

struct PlayerSourcesColumn: View {
    @ObservedObject var engine: NextEpisodeEngine
    let onClose: () -> Void
    /// Optional: bound to the first source row (see `PlayerEpisodesColumn.firstRowFocus`).
    var firstRowFocus: FocusState<Bool>.Binding? = nil
    /// See `PlayerEpisodesColumn.onFirstRowsAppear`.
    var onFirstRowsAppear: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.sm) {
                PlayerPanelSectionCaption(text: String(localized: "Sources"))
                if engine.sourcesLoading { ProgressView().scaleEffect(0.6) }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    if engine.sourcesBlockedBySearch {
                        // BUG-129: an up-next search (or an episode jump) owns the shared streams
                        // flow; the list loads by itself once it ends (r1 P3).
                        Text(engine.sourcesBlockedByJump
                             ? String(localized: "Finding the episode's source…")
                             : String(localized: "Finding the next episode's source…"))
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .accessibilityIdentifier("player.panel.sources.busy")
                    } else if engine.sources.isEmpty && !engine.sourcesLoading {
                        Text("No alternate sources found yet.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    ForEach(Array(engine.sources.prefix(12).enumerated()), id: \.offset) { index, stream in
                        sourceRow(stream)
                            .focusedIfBound(index == 0 ? firstRowFocus : nil)
                    }
                }
            }
            Text("Switching resumes from your last saved position.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .onAppear { engine.sourceColumnAppeared(); engine.loadSources() }
        .onChange(of: min(engine.sources.count, 12)) { old, new in
            if PlayerOverlayRowFocus.shouldRefocus(oldRowCount: old, newRowCount: new) { onFirstRowsAppear?() }
        }
        .onDisappear { engine.sourceColumnDisappeared() }
    }

    private func sourceRow(_ stream: StreamItem) -> some View {
        // Review r1: by listed-stream key (a ytId or debrid source never matches by URL).
        let isCurrent = engine.isCurrentSource(stream)
        return Button {
            guard !isCurrent else { return }
            if engine.playSource(stream) { onClose() }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: isCurrent ? "play.fill" : "arrow.triangle.2.circlepath")
                    .font(Theme.Font.caption.weight(.semibold))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stream.streamLabel).font(Theme.Font.body).lineLimit(1)
                    Text(stream.addonName).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    // Batch D U2: the add-on gave only a YouTube video id — the switch resolves it
                    // on the device first, so say where the video comes from (the picker's caption).
                    if StreamPickerView.isYouTubeResolved(stream) {
                        Text(verbatim: "YouTube").font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text("Playing").font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

/// mpv overlay focus (review r3): the overlay's open-time focus retries end after ~450 ms, and
/// Sources / Episodes rows can load later, leaving nothing focused until a press is spent. When a
/// column goes from no rows to some, the overlay asks again.
enum PlayerOverlayRowFocus {
    static func shouldRefocus(oldRowCount: Int, newRowCount: Int) -> Bool {
        oldRowCount == 0 && newRowCount > 0
    }
}

private extension View {
    /// `.focused(binding)` when a binding is given; the view untouched otherwise.
    @ViewBuilder
    func focusedIfBound(_ binding: FocusState<Bool>.Binding?) -> some View {
        if let binding { focused(binding) } else { self }
    }
}
