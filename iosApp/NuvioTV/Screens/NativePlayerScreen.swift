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
    /// Called with the last known position and the seconds the native path actually played when it
    /// can't play — dispatcher → mpv.
    var onFallback: ((Double, Double, Bool) -> Void)?
    /// Failover hook, set by `PlayerScreen`. Fired when the native path fails and there is NO
    /// `onFallback` to hand the context to (mpv already tried, or no fallback wired): the host then
    /// moves to the next source. With a fallback wired, the dispatcher owns the handoff instead.
    var onPlaybackFailed: ((PlaybackFailure) -> Void)?
    /// Fired once, when the item has played for 5 minutes (`NativePlaybackCoordinator.onPlaybackHealthy`).
    var onPlaybackHealthy: ((Double) -> Void)?
    /// Router decision label (e.g. "Native · DV P7 FEL → 8.1") for the Info tab.
    var routingNote: String?
    /// P5 B22: set by presenters that can push a Detail page after the player closes; enables the
    /// post-play More Like This row.
    var onOpenTitle: ((MetaPreview) -> Void)? = nil

    @StateObject private var coordinator: NativePlaybackCoordinator
    @StateObject private var moreLikeThisLoader = PostPlayMoreLikeThisLoader()
    @StateObject private var upNext: NextEpisodeEngine
    @StateObject private var panelModel: PlayerTopPanelModel
    @State private var panelAdapter: NativePlayerPanelAdapter?
    /// Skip chip + auto-skip policy shared with the mpv screen.
    @State private var skipPlanner = SkipSegmentPlanner()
    @State private var skipPrompt: SkipPrompt?
    /// "Swipe down for info" hint (start + after a pause); hidden while the panel is open.
    @State private var showSwipeHint = false
    @State private var swipeHintTask: Task<Void, Never>?
    @State private var swipeHintReason: SwipeHintReason?
    @State private var panelOpen = false
    // P4 B16: the pause info card (rule in `NativePauseCardRule`).
    /// Settings › Playback › Pause Info Card, read once in `onAppear` (as on mpv).
    @State private var pauseCardEnabled = true
    /// The transport bar's last delegate report was `visible=false` (unknown = visible, [C-5]; P4-F2).
    @State private var barKnownHidden = false
    /// Last transport-bar report from the host delegate (nil = none yet); for the probe.
    @State private var barVisible: Bool?
    @State private var pausedSince: TimeInterval?
    @State private var showPauseCard = false
    @State private var pauseCardTask: Task<Void, Never>?
    /// P4 B24: Settings › Playback › Loading Screen, read in `init` (not `onAppear`, which runs
    /// after the first frame and would flash the overlay when the setting is off — critique C17).
    @State private var loadingOverlayOn: Bool
    @Environment(\.dismiss) private var dismiss

    init(context: PlaybackContext,
         onPlayNext: ((PlaybackContext) -> Void)? = nil,
         onFallback: ((Double, Double, Bool) -> Void)? = nil,
         routingNote: String? = nil,
         onPlaybackFailed: ((PlaybackFailure) -> Void)? = nil,
         onPlaybackHealthy: ((Double) -> Void)? = nil,
         onOpenTitle: ((MetaPreview) -> Void)? = nil) {
        self.context = context
        self.onOpenTitle = onOpenTitle
        self.onPlayNext = onPlayNext
        self.onFallback = onFallback
        self.routingNote = routingNote
        self.onPlaybackFailed = onPlaybackFailed
        self.onPlaybackHealthy = onPlaybackHealthy
        _loadingOverlayOn = State(initialValue: PlayerLoadingOverlaySetting.enabled)
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
                // With the loading screen on, the overlay below draws this phase (B24); the bare
                // spinner + caption stay for the setting-off branch only.
                if !loadingOverlayOn {
                    VStack(spacing: 20) {
                        ProgressView().scaleEffect(1.6)
                        Text(coordinator.preparingLabel)
                            .font(Theme.Font.body)
                            .foregroundStyle(.white.opacity(0.7))
                    }
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
                        onSkip: { target in skipSeek(to: target, kind: .chip) },
                        onPlayNow: { [weak upNext] in _ = upNext?.playNow() },
                        onDismissUpNext: { [weak upNext] in upNext?.dismissIfVisible() ?? false },
                        onPanelOpenChanged: { open in panelOpen = open },
                        engine: upNext,
                        canSwitchStreams: onPlayNext != nil,
                        hasEpisodes: !context.episodes.isEmpty && context.season != nil,
                        rememberSpeedShowId: (context.season != nil || context.episode != nil) ? context.parentMetaId : nil,
                        onBarVisibility: { visible in barVisibilityChanged(visible) },
                        onAnyPress: { hidePauseCard(reason: "press") }
                    )
                    .ignoresSafeArea()
                }
            case .failed(let reason):
                // Hand back to the dispatcher, which re-presents the mpv player for this context.
                // With no fallback to hand to, report the failure (failover) before dismissing.
                Color.clear.onAppear {
                    if let onFallback {
                        // Review r2 #1: "started" comes from readiness, not from the play clock —
                        // a mid-play fallback inside the first tick, or while paused/buffering,
                        // reads 0 played seconds yet the link demonstrably worked.
                        onFallback(coordinator.lastPositionSec, coordinator.secondsPlayed, coordinator.readyUptime != nil)
                    } else {
                        if let onPlaybackFailed {
                            print("[Failover] native failure: \(reason) pos=\(Int(coordinator.lastPositionSec)) played=\(Int(coordinator.secondsPlayed)) started=\(coordinator.readyUptime != nil)")
                            onPlaybackFailed(PlaybackFailure(
                                reason: reason, positionSec: coordinator.lastPositionSec,
                                secondsPlayed: coordinator.secondsPlayed,
                                startedPlaying: coordinator.readyUptime != nil,
                                kind: coordinator.failureKind ?? .unknown,
                                httpStatus: coordinator.failureHTTPStatus))
                        }
                        dismiss()
                    }
                }
            }

            // P4 B24: one overlay from the first `.preparing` frame until `loadingStage == .started`,
            // over the mounted `AVPlayerContainer` once playing, so AVKit's own spinner is covered
            // and there is no bare-spinner frame. Never focusable or hit-tested (the remote still
            // reaches the system player underneath).
            if showsLoadingOverlay {
                PlayerLoadingOverlay(context: context, stage: coordinator.loadingStage)
                    .transition(.opacity)
            }

            // Up-next status/countdown caption (visual only). The interactive part is the
            // "Play Next Episode" contextual action the container installs — its title stays static
            // (a per-second UIAction title change re-animates the transport bar), so the countdown
            // lives here, in the shared chip caption both engines draw. Inset above the system's
            // contextual-action pill; the extra bottom offset is device-tuned for tvOS 26.
            if showSwipeHint, !panelOpen, coordinator.phase == .playing {
                PlayerSwipeHint().transition(.opacity)
            }

            // P4 B16: paused, the system bar known hidden, the panel closed. Above the player,
            // below the up-next caption; never focusable, never hit-tested.
            if showPauseCard, coordinator.phase == .playing {
                PauseInfoCard(context: context, positionSec: coordinator.lastPositionSec,
                              durationSec: coordinator.durationSec)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(60)
                    .allowsHitTesting(false)
                    .focusable(false)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            #if DEBUG
            // P4 legs' oracle (spec §10.2): 1 pt, top-trailing, like `SeekProbeLabel`.
            NativeProbeLabel(coordinator: coordinator, barVisible: barVisible, card: showPauseCard,
                             panel: panelOpen, barHidden: barKnownHidden, pausedSince: pausedSince)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            #endif

            if let caption = upNext.phase.chipCaption(nextTitle: upNext.nextEpisodeTitle) {
                PlayerChipCaption(text: caption.text, symbol: caption.symbol, showsProgress: caption.progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, PlayerChipStyle.edgePadding)
                    .padding(.bottom, PlayerChipStyle.edgePadding + Self.contextualActionClearance)
                    .transition(.opacity)
            } else if let failure = upNext.sourceSwitchFailure {
                // Batch D review r1: a Sources-tab switch that could not start (see the mpv screen).
                PlayerChipCaption(text: failure, symbol: "exclamationmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, PlayerChipStyle.edgePadding)
                    .padding(.bottom, PlayerChipStyle.edgePadding + Self.contextualActionClearance)
                    .transition(.opacity)
            }
        }
        .animation(PlayerChipStyle.animation, value: upNext.phase)
        .animation(PlayerChipStyle.animation, value: upNext.sourceSwitchFailure)
        .animation(PlayerChipStyle.animation, value: showSwipeHint)
        .animation(.easeInOut(duration: 0.25), value: showPauseCard)
        .animation(.easeInOut(duration: 0.25), value: showsLoadingOverlay)
        #if DEBUG
        // Every published value (not `onChange`, which coalesces two stages set in one turn).
        .onReceive(coordinator.$loadingStage) { stage in
            PlayerLoadingHistory.shared.note(stage, contextID: context.id)
        }
        #endif
        // P5 B22: the item played to its end with no Up Next hand-off pending (same gate as mpv).
        .fullScreenCover(
            isPresented: Binding(
                get: { coordinator.didPlayToEnd && upNext.phase == .hidden },
                set: { if !$0 { coordinator.clearEnded() } }
            )
        ) {
            PostPlayView(
                title: context.title,
                poster: context.poster,
                onReplay: { coordinator.replayFromStart() },
                onExit: { dismiss() },
                moreLikeThis: moreLikeThisLoader.items,
                onOpenTitle: onOpenTitle
            )
        }
        .onChange(of: coordinator.phase) { _, phase in
            if phase == .playing { flashSwipeHint(after: 1, reason: .start) }
            // P5 B22 review r1 (P3-2): load once playback runs, not while the stream opens.
            if phase == .playing, onOpenTitle != nil {
                moreLikeThisLoader.load(type: context.contentType, id: context.parentMetaId)
            }
            evaluatePauseCard()
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
            pauseChanged(paused)
        }
        .onChange(of: coordinator.isRebuildingItem) { _, _ in evaluatePauseCard() }
        // An offline Up Next card drops to `.hidden` at the end, so the post-play cover below
        // (gated on `.hidden`) can come up even when no tick landed inside the end-of-file slack.
        .onChange(of: coordinator.didPlayToEnd) { _, ended in
            if ended { upNext.playbackEnded() }
        }
        .onChange(of: panelOpen) { _, open in
            if open { hidePauseCard(reason: "panel") } else { evaluatePauseCard() }
        }
        .onAppear {
            pauseCardEnabled = (PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState)?
                .pauseOverlayEnabled != false
            let adapter = NativePlayerPanelAdapter(coordinator: coordinator, model: panelModel,
                                                   context: context, routingNote: routingNote)
            panelAdapter = adapter
            coordinator.onTick = { [weak upNext, weak adapter] position, duration in
                upNext?.onProgress(positionSec: position, durationSec: duration)
                updateSkipPrompt(position: position, duration: duration)
                adapter?.onTick()
            }
            // Deliberate entries (resume + transport scrubs) are never auto-skipped.
            coordinator.onPositionTick = { from, to in
                skipPlanner.observeTick(fromSec: from, toSec: to, now: ProcessInfo.processInfo.systemUptime)
            }
            coordinator.onResumeSeekBegin = { target in
                skipPlanner.beginSeek(kind: .resume, targetSec: target, now: ProcessInfo.processInfo.systemUptime)
            }
            coordinator.onResumeSeekCompleted = { landed in
                skipPlanner.seekCompleted(atSec: landed, now: ProcessInfo.processInfo.systemUptime)
            }
            coordinator.onPlaybackHealthy = onPlaybackHealthy
            coordinator.start()
            // Only orchestrate up-next when a presenter can swap contexts (series autoplay).
            if onPlayNext != nil { upNext.startNative() }
            fetchSkipSegments()
        }
        .onDisappear {
            swipeHintTask?.cancel()
            pauseCardTask?.cancel()
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

    // MARK: - Pause info card (P4 B16)

    /// A B17 item rebuild's transient pause is not a viewer pause.
    private var isRebuildingItem: Bool { coordinator.isRebuildingItem }

    private func pauseChanged(_ paused: Bool) {
        pauseCardTask?.cancel()
        if paused {
            pausedSince = ProcessInfo.processInfo.systemUptime
            // P4-F2: start from the delegate's last report (nil = unknown = visible, [C-5]).
            barKnownHidden = NativePauseCardRule.barKnownHiddenAtPause(lastReport: barVisible)
            pauseCardTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(NativePauseCardRule.delaySec))
                guard !Task.isCancelled else { return }
                evaluatePauseCard()
            }
        } else {
            pausedSince = nil
            hidePauseCard(reason: "resume")
        }
    }

    private func barVisibilityChanged(_ visible: Bool) {
        barVisible = visible
        barKnownHidden = !visible
        if visible { hidePauseCard(reason: "bar") } else { evaluatePauseCard() }
    }

    private func evaluatePauseCard() {
        let now = ProcessInfo.processInfo.systemUptime
        let visible = NativePauseCardRule.visible(
            pausedSince: pausedSince, now: now, barKnownHidden: barKnownHidden, panelOpen: panelOpen,
            enabled: pauseCardEnabled, isPlayingPhase: coordinator.phase == .playing,
            isRebuilding: isRebuildingItem)
        if visible, !showPauseCard {
            showPauseCard = true
            // The two would overlap at the top centre.
            if swipeHintReason == .pause { hideSwipeHint() }
            print("[NativePlayer] pause card shown after \(String(format: "%.1f", now - (pausedSince ?? now)))s")
        } else if !visible, showPauseCard {
            hidePauseCard(reason: isRebuildingItem ? "rebuild" : (panelOpen ? "panel" : "rule"))
        }
    }

    private func hidePauseCard(reason: String) {
        guard showPauseCard else { return }
        showPauseCard = false
        print("[NativePlayer] pause card hidden reason=\(reason)")
    }

    /// Vertical room the system contextual-action pill occupies above the bottom inset on tvOS 26,
    /// so the caption sits above it rather than on top of it. Device-tuned.
    private static let contextualActionClearance: CGFloat = 96

    /// B24: the loading screen covers every phase until the first play (or a ready-and-paused
    /// item). It stays up through a pre-start `.failed`, so a native → mpv fallback goes from this
    /// overlay straight to the mpv screen's (same poster, already in memory) with no spinner frame.
    private var showsLoadingOverlay: Bool {
        loadingOverlayOn && !coordinator.loadingStage.isStarted
    }

    /// Which up-next contextual action to offer (`UpNextAction(phase:)`, shared with mpv's chip).
    private var upNextAction: UpNextAction? { UpNextAction(phase: upNext.phase) }

    // MARK: - Skip intro/outro segments (shared repository, same rules as the mpv screen)

    /// Fetch intro/recap/outro segments for a series episode, or IntroDB credits/post-credits
    /// segments for a movie (upstream cbe4dc0a). Respects the Settings > Playback "Skip Intro"
    /// toggle. The full list (post-credits included) also feeds the up-next post-credits hold.
    private func fetchSkipSegments() {
        if let season = context.season, let episode = context.episode {
            SkipIntroRepository.shared.getSkipIntervalsForContentId(
                // Routes kitsu:/mal: anime ids to the anime providers (same rules as the mpv screen).
                contentId: context.parentMetaId,
                season: Int32(season),
                episode: Int32(episode),
                requireSkipIntroEnabled: true
            ) { intervals, _ in
                let list = intervals ?? []
                DispatchQueue.main.async { applySkipIntervals(list) }
            }
        } else if context.contentType.lowercased() == "movie" {
            SkipIntroRepository.shared.getMovieSkipIntervals(
                contentId: context.parentMetaId,
                videoId: context.videoId,
                requireSkipIntroEnabled: true
            ) { intervals, _ in
                let list = intervals ?? []
                DispatchQueue.main.async { applySkipIntervals(list) }
            }
        }
    }

    private func applySkipIntervals(_ intervals: [SkipInterval]) {
        print("[NativePlayer] skip segments: \(intervals.count)"
              + (intervals.isEmpty ? " (none in intro DB for this title)" : ""))
        guard !intervals.isEmpty else { return }
        skipPlanner.setIntervals(intervals)
        upNext.skipIntervals = intervals
    }

    /// Offer the skip while inside a segment (the last second is excluded so the action
    /// disappears cleanly at the end) and auto-skip the segment types chosen in Settings — same
    /// `SkipSegmentPlanner` rules as the mpv screen.
    private func updateSkipPrompt(position: Double, duration: Double) {
        // r2 P2: no chip and no auto-skip while a B17 rebuild swaps the item (the new item is not
        // ready for a seek). The planner is not evaluated either, so nothing is consumed; the
        // rebuild restores the playhead and the next tick after it decides as usual.
        if isRebuildingItem {
            if skipPrompt != nil { skipPrompt = nil }
            return
        }
        // Synchronous read (ticks are ~3 s apart); auto-skip also requires Skip Intro.
        let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState
        let autoSkipTypes: [AutoSkipSegmentType]? = settings.flatMap { $0.skipIntroEnabled ? Array($0.autoSkipSegmentTypes) : nil }
        let decision = skipPlanner.evaluate(positionSec: position, durationSec: duration,
                                            isPlaying: !coordinator.isPaused, autoSkipTypes: autoSkipTypes,
                                            now: ProcessInfo.processInfo.systemUptime)
        if let target = decision.autoSkipTargetSec { skipSeek(to: target, kind: .auto) }
        if decision.prompt != skipPrompt { skipPrompt = decision.prompt }
    }

    /// The screen's own skip seeks (auto-skip, chip): the planner is told first, and AVPlayer's
    /// completion reports where the seek really landed. Zero tolerance: land exactly on the target.
    private func skipSeek(to target: Double, kind: SkipSegmentPlanner.SeekKind) {
        guard let player = coordinator.player else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        skipPlanner.beginSeek(kind: kind, targetSec: target, fromSec: coordinator.lastPositionSec, now: startedAt)
        coordinator.noteUserSeek(to: target)   // r1 P3: wins over a B17 rebuild's corrective seek
        // The chip can't re-fire while this is in flight: the planner offers no chip until then.
        if skipPrompt != nil { skipPrompt = nil }
        // r2 P2: during a B17 rebuild the current item is the new one, not `readyToPlay` yet, and
        // a completion-handler seek on such an item has historically raised
        // NSInternalInconsistencyException. Don't issue it: `noteUserSeek` above already aims the
        // rebuild's corrective seek at this target. Tell the planner the seek will not complete as
        // issued (`seekInterrupted`: a chip press keeps its interval consumed, so the chip cannot
        // re-fire), and the next tick judges the landing like any other jump.
        if isRebuildingItem && player.currentItem?.status != .readyToPlay {
            print("[NativePlayer] skip seek → \(String(format: "%.1f", target))s deferred to the late rebuild")
            skipPlanner.seekInterrupted()
            return
        }
        Task { @MainActor in
            let finished = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
            // A newer app seek replaced this one in the planner: not ours to report.
            guard skipPlanner.seekInFlight?.startedAt == startedAt else { return }
            if finished {
                skipPlanner.seekCompleted(atSec: CMTimeGetSeconds(player.currentTime()),
                                          now: ProcessInfo.processInfo.systemUptime)
            } else {
                // Cancelled by a newer seek (a transport scrub): the position is the user's, not
                // ours — the next tick's jump must be judged as a scrub.
                skipPlanner.seekInterrupted()
            }
        }
    }
}

#if DEBUG
/// DEBUG probe for the P4 parity legs: `pos= speed= paused= bar= card= stage= chapters= subs= late=`.
/// `pos` is the player's live time and `speed` the live `player.rate` while playing (the default
/// rate while paused), re-read twice a second; `bar` is the last delegate report (`u` = none yet).
private struct NativeProbeLabel: View {
    @ObservedObject var coordinator: NativePlaybackCoordinator
    let barVisible: Bool?
    let card: Bool
    /// The pause-card rule's other screen-side inputs (P4-F2): panel open, bar known hidden, and
    /// whether a pause start is recorded.
    let panel: Bool
    let barHidden: Bool
    let pausedSince: TimeInterval?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(verbatim: text)
                .font(.system(size: 8))
                .opacity(0.011)
                .accessibilityIdentifier("debug_nativeProbe")
                .allowsHitTesting(false)
        }
    }

    private var text: String {
        let player = coordinator.player
        let pos = player.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
        let rate: Float = player.map { $0.timeControlStatus == .paused ? $0.defaultRate : $0.rate } ?? 0
        let bar = barVisible.map { $0 ? "1" : "0" } ?? "u"
        return "pos=\(String(format: "%.1f", pos.isFinite ? pos : 0)) speed=\(String(format: "%g", rate))"
            + " paused=\(coordinator.isPaused ? 1 : 0) bar=\(bar) card=\(card ? 1 : 0)"
            + " stage=\(coordinator.loadingStage.logToken) chapters=\(coordinator.chapters.count)"
            + " subs=\(coordinator.subtitleRenditionsByName.count) late=\(coordinator.lateState)"
            + " panel=\(panel ? 1 : 0) barHidden=\(barHidden ? 1 : 0) since=\(pausedSince == nil ? 0 : 1)"
            + " rebuilding=\(coordinator.isRebuildingItem ? 1 : 0)"
    }
}
#endif

/// Up-next contextual action variants (static titles — see the caption note in `NativePlayerScreen`).
enum UpNextAction: String {
    case playNext, continueWatching

    /// The action each up-next phase offers, on both engines (the native contextual action, the
    /// mpv Down-press chip): "Play Next Episode" during the countdown and on the offline card
    /// (selecting it starts the deferred search, `NextEpisodeEngine.playNow`), "Continue Watching"
    /// once the still-watching guard has paused autoplay, none otherwise.
    init?(phase: NextEpisodeEngine.Phase) {
        switch phase {
        case .counting, .offlineDeferred: self = .playNext
        case .stillWatching: self = .continueWatching
        case .hidden, .searching, .noStream: return nil
        }
    }

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
    /// Menu while the up-next chip is showing → dismiss it (returns true) instead of exiting.
    let onDismissUpNext: () -> Bool
    let onPanelOpenChanged: (Bool) -> Void
    /// The Playback tab's Episodes / Sources columns (P4 A8).
    let engine: NextEpisodeEngine
    /// The presenter can swap playback contexts (episode jump / source switching).
    let canSwitchStreams: Bool
    /// A series with an episode list: the transport bar offers "Episodes".
    let hasEpisodes: Bool
    /// P5 B23: the show id that "Remember Speed for This Show" saves under; nil (movies) hides the row.
    let rememberSpeedShowId: String?
    /// System transport bar about to show / hide (host delegate, P4 B16).
    let onBarVisibility: (Bool) -> Void
    /// Any remote press (P4 B16: hides the pause card).
    let onAnyPress: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> NativePlayerHostController {
        let host = NativePlayerHostController()
        host.loadViewIfNeeded()          // viewDidLoad wires the child + delegate before configuring
        host.playerVC.player = player
        // No `customInfoViewControllers`: on tvOS 26 that renders as pills under the seek bar and
        // would split the native player into two panels. Info · Subtitles · Audio · Playback live
        // in the app-drawn swipe-down panel presented by the host; the Playback tab (speed,
        // Episodes, Sources) and the transport bar's Episodes / Sources menu items replace the old
        // `customInfoViewControllers` idea (P4 A8, spec D1/D5).
        let model = panelModel
        let openChanged = onPanelOpenChanged
        let engine = engine
        let canSwitchStreams = canSwitchStreams

        // D4: one speed list, the same seven rates the panel row offers, so the system pill and the
        // tab stay in step through `selectSpeed`.
        host.playerVC.speeds = PlayerPlaybackColumns.speeds.map {
            AVPlaybackSpeed(rate: Float($0), localizedName: String(format: "%g\u{00D7}", $0))
        }
        let speedModel = context.coordinator.speedModel
        speedModel.onSelect = { [weak host, weak speedModel] value in
            guard let host, let speedModel else { return }
            NativeSpeedModel.apply(value, on: host.playerVC, model: speedModel)
            speedModel.saveIfRemembered(rate: speedModel.rate)
        }
        // P5 B23: Remember Speed for This Show (series only). A saved speed is applied before play.
        if let showId = rememberSpeedShowId {
            speedModel.showId = showId
            speedModel.rememberAvailable = true
            if let saved = PlayerTrackPreferenceStorage.shared.loadPlaybackSpeed(parentMetaId: showId)?.doubleValue {
                speedModel.remember = true
                NativeSpeedModel.apply(saved, on: host.playerVC, model: speedModel)
            }
            speedModel.onRememberChange = { [weak host, weak speedModel] on in
                guard let host, let speedModel else { return }
                speedModel.remember = on
                if on {
                    speedModel.saveIfRemembered(rate: Double(host.playerVC.selectedSpeed?.rate ?? Float(speedModel.rate)))
                } else {
                    PlayerTrackPreferenceStorage.shared.clearPlaybackSpeed(parentMetaId: showId)
                }
            }
        }

        // D5: Episodes (series with episodes) and Sources, each opening the panel on Playback with
        // that column focused. Installed once: their meaning never changes in a session.
        var menu: [UIMenuElement] = []
        if canSwitchStreams, hasEpisodes {
            menu.append(UIAction(title: String(localized: "Episodes"), image: UIImage(systemName: "list.number")) { [weak host] _ in
                host?.openPanel(tab: .playback, column: .episodes)
            })
        }
        if canSwitchStreams {
            menu.append(UIAction(title: String(localized: "Sources"),
                                 image: UIImage(systemName: "arrow.triangle.2.circlepath")) { [weak host] _ in
                host?.openPanel(tab: .playback, column: .sources)
            })
        }
        host.playerVC.transportBarCustomMenuItems = menu

        host.onOpenPanel = { [weak host] tab, column in
            guard let host else { return }
            // Catches a change made with the system speed pill, which bypasses `select`. Only when
            // the player reports a selection: a nil one must not overwrite the saved speed with 1.0.
            if let selected = host.playerVC.selectedSpeed {
                speedModel.rate = Double(selected.rate)
                speedModel.saveIfRemembered(rate: speedModel.rate)
            } else {
                speedModel.rate = 1
            }
            let extra = PlayerPanelExtraTab {
                NativePlaybackTab(engine: engine, speed: speedModel, canSwitchStreams: canSwitchStreams,
                                  initialColumn: column, onClose: { model.onClose?() })
            }
            let panel = PlayerPanelHostController(rootView: PlayerTopPanel(model: model, extraTab: extra, initialTab: tab))
            model.onClose = { [weak panel] in panel?.close(animated: true) }
            host.present(panel: panel)
            openChanged(true)
        }
        host.onPanelClosed = {
            openChanged(false)
            // FEAT-49 layer 2 on native: the Sources column may have clobbered a preload.
            engine.noteSourceListClosed()
        }
        host.onTransportBarVisibilityChange = onBarVisibility
        host.onAnyPress = onAnyPress
        let speedList = PlayerPlaybackColumns.speeds.map { String(format: "%g", $0) }.joined(separator: ",")
        let menuTitles = menu.compactMap { ($0 as? UIAction)?.title }.joined(separator: ",")
        print("[NativePlayer] avpvc speeds=\(speedList) menu=\(menuTitles.isEmpty ? "-" : menuTitles) delegate=\(host.playerVC.delegate === host ? 1 : 0)")
        // Set once, like `onOpenPanel`: the closure captures the screen's stable `@StateObject`.
        host.onMenuPress = onDismissUpNext
        return host
    }

    static func dismantleUIViewController(_ host: NativePlayerHostController, coordinator: Coordinator) {
        // P5 B23: persist a speed changed with the system pill since the panel last opened.
        MainActor.assumeIsolated {
            // Review r2: only a speed AVKit actually reports is saved; a nil selectedSpeed (the
            // player never exposed its pill) must not overwrite the remembered speed with 1.0.
            if let selected = host.playerVC.selectedSpeed {
                coordinator.speedModel.saveIfRemembered(rate: Double(selected.rate))
            }
        }
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
            // Discoverable twin of the Menu-press dismiss (transport-bar users never see a hint
            // that Menu backs out of the chip). Same signature key as the play-next action.
            let dismissUpNext = onDismissUpNext
            actions.append(UIAction(title: String(localized: "Dismiss"),
                                    image: UIImage(systemName: "xmark")) { _ in _ = dismissUpNext() })
        }
        controller.contextualActions = actions
    }

    @MainActor
    final class Coordinator {
        var actionsSignature = ""
        var allowedSubtitleLanguages: [String]?
        /// The Playback tab's speed model, alive as long as the container.
        let speedModel = NativeSpeedModel()
    }
}
