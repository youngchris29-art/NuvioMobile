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
//  - "Play Next Episode" / "Continue Watching" are contextual actions too; the countdown is a small
//    app-drawn caption (`PlayerChipCaption`, shared with the mpv screen) above them.
//  - Info · Subtitles · Audio live in an app-drawn swipe-down top panel (Infuse-style) presented by
//    `NativePlayerHostController` over the system player — tvOS 26 has no system swipe-down panel
//    (a `customInfoViewControllers` tab would render as an "Info" pill under the seek bar). The
//    native transport-bar Subtitles/Audio popovers stay (Enhance Dialogue etc. have no public API).
struct NativePlayerScreen: View {
    let context: PlaybackContext
    var onPlayNext: ((PlaybackContext) -> Void)?
    /// Called with the last known position when the native path can't play — dispatcher → mpv.
    var onFallback: ((Double) -> Void)?
    /// Router decision label (e.g. "Native · DV P7 FEL → 8.1") for the Info tab.
    var routingNote: String?

    @StateObject private var coordinator: NativePlaybackCoordinator
    @StateObject private var upNext: NextEpisodeEngine
    @StateObject private var panelModel: PlayerTopPanelModel
    @State private var panelAdapter: NativePlayerPanelAdapter?
    @State private var skipSegments: [SkipSegment] = []
    @State private var skipPrompt: SkipPrompt?
    /// "Swipe down for info" hint (start + after a pause); hidden while the panel is open.
    @State private var showSwipeHint = false
    @State private var swipeHintTask: Task<Void, Never>?
    @State private var swipeHintReason: SwipeHintReason?
    @State private var panelOpen = false
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
        _panelModel = StateObject(wrappedValue: PlayerTopPanelModel(
            info: PlayerPanelInfo(header: NativeInfoHeader(context: context))))
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
                        upNextAction: upNextAction,
                        allowedSubtitleLanguages: coordinator.languagePlan.onlyPreferredLanguages
                            ? coordinator.languagePlan.subtitleFilterLanguages : nil,
                        panelModel: panelModel,
                        onSkip: { [weak coordinator] target in
                            coordinator?.player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                        },
                        onPlayNow: { [weak upNext] in _ = upNext?.playNow() },
                        onPanelOpenChanged: { open in panelOpen = open }
                    )
                    .ignoresSafeArea()
                }
            case .failed:
                // Hand back to the dispatcher, which re-presents the mpv player for this context.
                Color.clear.onAppear {
                    if let onFallback { onFallback(coordinator.lastPositionSec) } else { dismiss() }
                }
            }

            // Up-next status/countdown caption (visual only). The interactive part is the
            // "Play Next Episode" contextual action the container installs — its title stays static
            // (a per-second UIAction title change re-animates the transport bar), so the countdown
            // lives here, in the shared chip caption both engines draw. Inset above the system's
            // contextual-action pill; the extra bottom offset is device-tuned for tvOS 26.
            if showSwipeHint, !panelOpen, coordinator.phase == .playing {
                PlayerSwipeHint().transition(.opacity)
            }

            if let caption = upNext.phase.chipCaption(nextTitle: upNext.nextEpisodeTitle) {
                PlayerChipCaption(text: caption.text, symbol: caption.symbol, showsProgress: caption.progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, PlayerChipStyle.edgePadding)
                    .padding(.bottom, PlayerChipStyle.edgePadding + Self.contextualActionClearance)
                    .transition(.opacity)
            }
        }
        .animation(PlayerChipStyle.animation, value: upNext.phase)
        .animation(PlayerChipStyle.animation, value: showSwipeHint)
        .onChange(of: coordinator.phase) { _, phase in
            if phase == .playing { flashSwipeHint(after: 1, reason: .start) }
        }
        .onChange(of: coordinator.isPaused) { _, paused in
            // Re-show the hint once per pause (after the pause has settled), like Infuse. Resuming
            // only cancels a PAUSE hint — the start hint must survive the initial paused→playing
            // transition, which happens right after readyToPlay.
            if paused {
                if coordinator.phase == .playing { flashSwipeHint(after: 1.5, reason: .pause) }
            } else if swipeHintReason == .pause {
                hideSwipeHint()
            }
        }
        .onAppear {
            let adapter = NativePlayerPanelAdapter(coordinator: coordinator, model: panelModel,
                                                   context: context, routingNote: routingNote)
            panelAdapter = adapter
            coordinator.onTick = { [weak upNext, weak adapter] position, duration in
                upNext?.onProgress(positionSec: position, durationSec: duration)
                updateSkipPrompt(position: position)
                adapter?.onTick()
            }
            coordinator.start()
            // Only orchestrate up-next when a presenter can swap contexts (series autoplay).
            if onPlayNext != nil { upNext.startNative() }
            fetchSkipSegments()
        }
        .onDisappear {
            swipeHintTask?.cancel()
            coordinator.stop()
            upNext.stop()
        }
    }

    private enum SwipeHintReason { case start, pause }

    private func flashSwipeHint(after delay: Double, reason: SwipeHintReason) {
        swipeHintTask?.cancel()
        swipeHintReason = reason
        swipeHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            showSwipeHint = true
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            showSwipeHint = false
        }
    }

    private func hideSwipeHint() {
        swipeHintTask?.cancel()
        showSwipeHint = false
    }

    /// Vertical room the system contextual-action pill occupies above the bottom inset on tvOS 26,
    /// so the caption sits above it rather than on top of it. Device-tuned.
    private static let contextualActionClearance: CGFloat = 96

    /// Which up-next contextual action to offer: "Play Next Episode" during the countdown,
    /// "Continue Watching" once the still-watching guard has paused autoplay, none otherwise.
    private var upNextAction: UpNextAction? {
        switch upNext.phase {
        case .counting: return .playNext
        case .stillWatching: return .continueWatching
        default: return nil
        }
    }

    // MARK: - Skip intro/outro segments (shared repository, same rules as the mpv screen)

    /// Fetch intro/recap/outro segments for a series episode (no-op for movies / missing episode
    /// numbers). Respects the Settings > Playback "Skip Intro" toggle.
    private func fetchSkipSegments() {
        guard let season = context.season, let episode = context.episode else { return }
        SkipIntroRepository.shared.getSkipIntervalsForContentId(
            // Routes kitsu:/mal: anime ids to the anime providers (same rules as the mpv screen).
            contentId: context.parentMetaId,
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
        let active = skipSegments.first { position >= $0.start && position < $0.end - PlayerChipStyle.lastSecondExclusion }
        let prompt = active.map { SkipPrompt(label: Self.skipLabel(for: $0.type), targetSec: $0.end) }
        if prompt != skipPrompt { skipPrompt = prompt }
    }

    private static func skipLabel(for type: String) -> String {
        switch type.lowercased() {
        case "outro", "ed", "credits": return String(localized: "Skip Outro")
        case "recap": return String(localized: "Skip Recap")
        default: return String(localized: "Skip Intro")
        }
    }
}

/// Up-next contextual action variants (static titles — see the caption note in `NativePlayerScreen`).
enum UpNextAction: String {
    case playNext, continueWatching

    var title: String {
        switch self {
        case .playNext: return String(localized: "Play Next Episode")
        case .continueWatching: return String(localized: "Continue Watching")
        }
    }
}

private struct AVPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let skipPrompt: SkipPrompt?
    let upNextAction: UpNextAction?
    /// "Show only preferred languages" (Settings → Playback → Subtitles): restrict the panel's
    /// Subtitles list to these BCP-47 tags. nil = show every rendition.
    let allowedSubtitleLanguages: [String]?
    let panelModel: PlayerTopPanelModel
    let onSkip: (Double) -> Void
    let onPlayNow: () -> Void
    let onPanelOpenChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> NativePlayerHostController {
        let host = NativePlayerHostController()
        host.playerVC.player = player
        // No `customInfoViewControllers`: on tvOS 26 that renders as an "Info" pill under the seek
        // bar. Info lives in the app-drawn swipe-down panel presented by the host instead.
        let model = panelModel
        let openChanged = onPanelOpenChanged
        host.onOpenPanel = { [weak host] in
            guard let host else { return }
            let panel = PlayerPanelHostController(rootView: PlayerTopPanel(model: model))
            model.onClose = { [weak panel] in panel?.close(animated: true) }
            host.present(panel: panel)
            openChanged(true)
        }
        host.onPanelClosed = { openChanged(false) }
        return host
    }

    static func dismantleUIViewController(_ host: NativePlayerHostController, coordinator: Coordinator) {
        host.closePanel(animated: false)
    }

    func updateUIViewController(_ host: NativePlayerHostController, context: Context) {
        let controller = host.playerVC
        if controller.player !== player { controller.player = player }
        // Only assign on change — it's a panel-content property, not part of the transport-bar
        // signature below, and reassigning identical arrays each SwiftUI tick is pointless work.
        if context.coordinator.allowedSubtitleLanguages != allowedSubtitleLanguages {
            context.coordinator.allowedSubtitleLanguages = allowedSubtitleLanguages
            controller.allowedSubtitleOptionLanguages = allowedSubtitleLanguages
        }
        // Reinstall contextual actions only when their meaning changes — reassigning identical
        // actions every SwiftUI update makes the transport bar re-animate them. The skip target is
        // part of the signature so back-to-back segments with the same label still refresh the
        // captured seek position.
        let signature = "\(skipPrompt.map { "\($0.label)@\($0.targetSec)" } ?? "-")|\(upNextAction?.rawValue ?? "-")"
        guard signature != context.coordinator.actionsSignature else { return }
        context.coordinator.actionsSignature = signature

        var actions: [UIAction] = []
        if let prompt = skipPrompt {
            let target = prompt.targetSec
            let skip = onSkip
            actions.append(UIAction(title: prompt.label,
                                    image: UIImage(systemName: PlayerChipStyle.skipSymbol)) { _ in skip(target) })
        }
        if let upNextAction {
            let playNow = onPlayNow
            actions.append(UIAction(title: upNextAction.title,
                                    image: UIImage(systemName: PlayerChipStyle.nextSymbol)) { _ in playNow() })
        }
        controller.contextualActions = actions
    }

    final class Coordinator {
        var actionsSignature = ""
        var allowedSubtitleLanguages: [String]?
    }
}
