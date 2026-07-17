import AVKit
import Combine
import SharedCore
import SwiftUI

// Phase 3 of the hybrid player (+ post-Phase-5 polish): the native AVPlayer playback screen, chosen
// by `PlayerScreen` for Dolby-Vision-eligible files. Shows a preparing state while the on-device
// remux spins up, then a full AVPlayerViewController (native tvOS transport, scrubbing, Now Playing).
// Watch progress, resume, and Trakt live in `NativePlaybackCoordinator`; next-episode autoplay reuses
// `NextEpisodeEngine`. A pre-playback failure calls `onFallback` so the dispatcher can hand the same
// context to the mpv player. See docs/tvos-hybrid-player-plan.md.
//
// Unlike the mpv screen — which owns the remote and must draw its own pills — this screen integrates
// with the system player UI:
//  - Skip Intro/Outro/Recap ride `contextualActions` (the same system affordance TV+/Netflix use;
//    segments come from the shared `SkipIntroRepository`, evaluated against playback ticks).
//  - "Play Next Episode" appears as a contextual action while the up-next countdown card is showing
//    (the card itself stays non-focusable; the action is the interactive part).
//  - Stream Info is a `customInfoViewControllers` tab in the swipe-down panel: router decision,
//    remux signaling, segment map shape, and live access-log stats.
struct NativePlayerScreen: View {
    let context: PlaybackContext
    var onPlayNext: ((PlaybackContext) -> Void)?
    /// Called with the last known position when the native path can't play — dispatcher → mpv.
    var onFallback: ((Double) -> Void)?
    /// Router decision label (e.g. "Native · DV P7 FEL → 8.1") for the Stream Info tab.
    var routingNote: String?

    @StateObject private var coordinator: NativePlaybackCoordinator
    @StateObject private var upNext: NextEpisodeEngine
    @StateObject private var info = NativeStreamInfoModel()
    @State private var skipSegments: [SkipSegment] = []
    @State private var skipPrompt: SkipPrompt?
    @Environment(\.dismiss) private var dismiss

    init(context: PlaybackContext,
         onPlayNext: ((PlaybackContext) -> Void)? = nil,
         onFallback: ((Double) -> Void)? = nil,
         routingNote: String? = nil) {
        self.context = context
        self.onPlayNext = onPlayNext
        self.onFallback = onFallback
        self.routingNote = routingNote
        _coordinator = StateObject(wrappedValue: NativePlaybackCoordinator(context: context))
        _upNext = StateObject(wrappedValue: NextEpisodeEngine(context: context, onPlayNext: onPlayNext ?? { _ in }))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch coordinator.phase {
            case .preparing:
                VStack(spacing: 20) {
                    ProgressView().scaleEffect(1.6)
                    Text(coordinator.preparingLabel)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
            case .playing:
                if let player = coordinator.player {
                    AVPlayerContainer(
                        player: player,
                        skipPrompt: skipPrompt,
                        upNextReady: upNextActionAvailable,
                        audioTracks: coordinator.audioTracks,
                        infoModel: info,
                        onSkip: { [weak coordinator] target in
                            coordinator?.player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                        },
                        onPlayNow: { [weak upNext] in _ = upNext?.playNow() },
                        onSelectAudio: { [weak coordinator] streamIndex in
                            coordinator?.selectAudioTrack(streamIndex: streamIndex)
                        }
                    )
                    .ignoresSafeArea()
                }
            case .failed:
                // Hand back to the dispatcher, which re-presents the mpv player for this context.
                Color.clear.onAppear {
                    if let onFallback { onFallback(coordinator.lastPositionSec) } else { dismiss() }
                }
            }

            // Countdown card (visual). The interactive part is the "Play Next Episode" contextual
            // action the container installs while this is showing.
            if upNext.phase != .hidden {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        UpNextCard(engine: upNext).padding(60)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: upNext.phase)
        .onAppear {
            let note = routingNote
            coordinator.onTick = { [weak coordinator, weak upNext, weak info] position, duration in
                upNext?.onProgress(positionSec: position, durationSec: duration)
                updateSkipPrompt(position: position)
                if let coordinator, let info {
                    info.rows = coordinator.streamInfoRows(routingNote: note)
                }
            }
            coordinator.start()
            // Only orchestrate up-next when a presenter can swap contexts (series autoplay).
            if onPlayNext != nil { upNext.startNative() }
            fetchSkipSegments()
        }
        .onDisappear {
            coordinator.stop()
            upNext.stop()
        }
    }

    private var upNextActionAvailable: Bool {
        switch upNext.phase {
        case .counting, .stillWatching: return true
        default: return false
        }
    }

    // MARK: - Skip intro/outro segments (shared repository, same rules as the mpv screen)

    /// Fetch intro/recap/outro segments for a series episode (no-op for movies / missing episode
    /// numbers). Respects the Settings > Playback "Skip Intro" toggle.
    private func fetchSkipSegments() {
        guard let season = context.season, let episode = context.episode else { return }
        SkipIntroRepository.shared.getSkipIntervals(
            imdbId: context.parentMetaId,
            season: Int32(season),
            episode: Int32(episode),
            requireSkipIntroEnabled: true
        ) { intervals, _ in
            let segments = (intervals ?? []).map { SkipSegment(start: $0.startTime, end: $0.endTime, type: $0.type) }
            print("[NativePlayer] skip segments: \(segments.count)"
                  + (segments.isEmpty ? " (none in intro DB for this episode)" : ""))
            guard !segments.isEmpty else { return }
            DispatchQueue.main.async { self.skipSegments = segments }
        }
    }

    /// Offer the skip while inside a segment; the last second is excluded so the action
    /// disappears cleanly at the end (same rule as the mpv screen).
    private func updateSkipPrompt(position: Double) {
        let active = skipSegments.first { position >= $0.start && position < $0.end - 1 }
        let prompt = active.map { SkipPrompt(label: Self.skipLabel(for: $0.type), targetSec: $0.end) }
        if prompt != skipPrompt { skipPrompt = prompt }
    }

    private static func skipLabel(for type: String) -> String {
        switch type.lowercased() {
        case "outro", "ed", "credits": return "Skip Outro"
        case "recap": return "Skip Recap"
        default: return "Skip Intro"
        }
    }
}

/// One label/value row of the Stream Info tab.
struct NativeInfoRow: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

/// Backing model for the Stream Info tab — refreshed on playback ticks while the panel may be open.
@MainActor
final class NativeStreamInfoModel: ObservableObject {
    @Published var rows: [NativeInfoRow] = []
}

/// AVPlayerViewController wrapper: full native tvOS player UI plus our integrations — contextual
/// actions (skip intro / play next) and the Stream Info panel tab.
private struct AVPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let skipPrompt: SkipPrompt?
    let upNextReady: Bool
    let audioTracks: [NativeAudioTrack]
    let infoModel: NativeStreamInfoModel
    let onSkip: (Double) -> Void
    let onPlayNow: () -> Void
    let onSelectAudio: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        // The info tab is installed once — its SwiftUI content observes `infoModel` and stays live.
        let host = UIHostingController(rootView: NativeStreamInfoView(model: infoModel))
        host.title = "Stream Info"
        controller.customInfoViewControllers = [host]
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        // Reinstall contextual actions only when their meaning changes — reassigning identical
        // actions every SwiftUI update makes the transport bar re-animate them. The skip target is
        // part of the signature so back-to-back segments with the same label still refresh the
        // captured seek position.
        let audioSignature = audioTracks.map {
            "\($0.streamIndex)\($0.selected ? "+" : "-")\($0.playable ? "" : "!")"
        }.joined(separator: ",")
        let signature = "\(skipPrompt.map { "\($0.label)@\($0.targetSec)" } ?? "-")|\(upNextReady)|\(audioSignature)"
        guard signature != context.coordinator.actionsSignature else { return }
        context.coordinator.actionsSignature = signature

        var actions: [UIAction] = []
        if let prompt = skipPrompt {
            let target = prompt.targetSec
            let skip = onSkip
            actions.append(UIAction(title: prompt.label,
                                    image: UIImage(systemName: "forward.frame.fill")) { _ in skip(target) })
        }
        if upNextReady {
            let playNow = onPlayNow
            actions.append(UIAction(title: "Play Next Episode",
                                    image: UIImage(systemName: "forward.end.fill")) { _ in playNow() })
        }
        controller.contextualActions = actions

        // Audio menu (D4): our HLS stream carries exactly ONE audio rendition, so the system audio
        // panel can't offer the source's other tracks — a transport-bar menu lists them all and a
        // pick rebuilds the session on that track (NativePlaybackCoordinator.selectAudioTrack).
        // Unplayable tracks (e.g. PCM) stay visible but disabled, so it's clear why they're absent.
        if audioTracks.count > 1 {
            let select = onSelectAudio
            let items = audioTracks.map { track in
                UIAction(title: track.name,
                         attributes: track.playable ? [] : .disabled,
                         state: track.selected ? .on : .off) { _ in select(track.streamIndex) }
            }
            controller.transportBarCustomMenuItems = [
                UIMenu(title: "Audio", image: UIImage(systemName: "waveform"), children: items),
            ]
        } else if !controller.transportBarCustomMenuItems.isEmpty {
            controller.transportBarCustomMenuItems = []
        }
    }

    final class Coordinator {
        var actionsSignature = ""
    }
}

/// Content of the Stream Info tab (AVPlayerViewController swipe-down panel). Plain label/value
/// rows, sized for 10-foot reading.
private struct NativeStreamInfoView: View {
    @ObservedObject var model: NativeStreamInfoModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 28) {
                        Text(row.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 340, alignment: .leading)
                        Text(row.value)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                }
                if model.rows.isEmpty {
                    Text("No stream details yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 36)
        }
    }
}
