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
//  - Info is a `customInfoViewControllers` tab in the swipe-down panel: what's-playing header plus
//    router decision, remux signaling, segment map shape, and live access-log stats. The system Info
//    tab is left unpopulated (no `externalMetadata`) so it hides and this one is the only Info tab.
struct NativePlayerScreen: View {
    let context: PlaybackContext
    var onPlayNext: ((PlaybackContext) -> Void)?
    /// Called with the last known position when the native path can't play — dispatcher → mpv.
    var onFallback: ((Double) -> Void)?
    /// Router decision label (e.g. "Native · DV P7 FEL → 8.1") for the Info tab.
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
                        allowedSubtitleLanguages: coordinator.languagePlan.onlyPreferredLanguages
                            ? coordinator.languagePlan.subtitleFilterLanguages : nil,
                        infoHeader: NativeInfoHeader(context: context),
                        infoModel: info,
                        onSkip: { [weak coordinator] target in
                            coordinator?.player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                        },
                        onPlayNow: { [weak upNext] in _ = upNext?.playNow() }
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
        let active = skipSegments.first { position >= $0.start && position < $0.end - 1 }
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

/// One label/value row of the Info tab.
struct NativeInfoRow: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

/// Backing model for the Info tab — refreshed on playback ticks while the panel may be open.
@MainActor
final class NativeStreamInfoModel: ObservableObject {
    @Published var rows: [NativeInfoRow] = []
}

/// AVPlayerViewController wrapper: full native tvOS player UI plus our integrations — contextual
/// actions (skip intro / play next) and the Info panel tab.
private struct AVPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let skipPrompt: SkipPrompt?
    let upNextReady: Bool
    /// "Show only preferred languages" (Settings → Playback → Subtitles): restrict the panel's
    /// Subtitles list to these BCP-47 tags. nil = show every rendition.
    let allowedSubtitleLanguages: [String]?
    let infoHeader: NativeInfoHeader
    let infoModel: NativeStreamInfoModel
    let onSkip: (Double) -> Void
    let onPlayNow: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        // The info tab is installed once — its SwiftUI content observes `infoModel` and stays live.
        let host = UIHostingController(rootView: NativeStreamInfoView(header: infoHeader, model: infoModel))
        host.title = String(localized: "Info")
        // AVPlayerViewController sizes the panel from the hosted SwiftUI content's measured height
        // (preferredContentSize is ignored) — so the content must measure eagerly: no ScrollView,
        // no LazyVGrid (see NativeStreamInfoView).
        controller.customInfoViewControllers = [host]
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
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
        let signature = "\(skipPrompt.map { "\($0.label)@\($0.targetSec)" } ?? "-")|\(upNextReady)"
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
            actions.append(UIAction(title: String(localized: "Play Next Episode"),
                                    image: UIImage(systemName: "forward.end.fill")) { _ in playNow() })
        }
        controller.contextualActions = actions
    }

    final class Coordinator {
        var actionsSignature = ""
        var allowedSubtitleLanguages: [String]?
    }
}

/// Static header data for the Info tab (what's playing), captured once from the PlaybackContext.
struct NativeInfoHeader {
    let title: String
    /// "S1 · E4 · Episode name" for series, else the stream's own label (release name / addon line).
    let subtitle: String?
    let synopsis: String?
    let poster: String?
    /// True when `poster` is an episode still (16:9) rather than a 2:3 poster.
    let landscapeArtwork: Bool

    init(context: PlaybackContext) {
        title = context.title
        var parts: [String] = []
        if let s = context.season, let e = context.episode {
            parts.append(String(localized: "S\(s) · E\(e)"))
        }
        if let st = context.streamTitle, !st.isEmpty { parts.append(st) }
        subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        synopsis = context.synopsis.flatMap { $0.isEmpty ? nil : $0 }
        let still = context.episodeStill.flatMap { $0.isEmpty ? nil : $0 }
        poster = still ?? context.poster.flatMap { $0.isEmpty ? nil : $0 }
        landscapeArtwork = still != nil
    }
}

/// Content of the Info tab (AVPlayerViewController swipe-down panel — the system Info tab is
/// deliberately not populated via `externalMetadata`, so this is THE Info tab; see
/// docs/tvos-native-player-info-panel-plan.md §5b). What's-playing header on top, then the
/// live stream rows. Sized for 10-foot reading; the panel chrome is Apple's.
private struct NativeStreamInfoView: View {
    let header: NativeInfoHeader
    @ObservedObject var model: NativeStreamInfoModel


    var body: some View {
        // Eagerly-measured layout on purpose: AVPlayerViewController takes the panel height from
        // this view's measured size at presentation. A ScrollView/LazyVGrid measures short (lazy
        // rows don't exist yet) and the panel then clips the bottom rows.
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            headerView
            Divider().overlay(Theme.Palette.outline)
            rowsView
        }
        .padding(.horizontal, Theme.Spacing.sectionGap)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Header art height; poster (2:3) or episode still (16:9) scale into it. Kept small — the panel
    /// has a fixed height, and the header must leave room for the two-column rows below.
    private static let artHeight: CGFloat = 140

    private var headerView: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            if header.poster != nil {
                CachedAsyncImage(string: header.poster, contentMode: .fill)
                    .frame(width: header.landscapeArtwork ? Self.artHeight * 16 / 9 : Self.artHeight * 2 / 3,
                           height: Self.artHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(header.title)
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle = header.subtitle {
                    Text(subtitle)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                if let synopsis = header.synopsis {
                    Text(synopsis)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)   // measure both lines
                        .padding(.top, Theme.Spacing.xxs)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Two columns of label/value pairs — the row count (a dozen live diagnostics) doesn't fit the
    /// panel's height in one column once the header is above it. Non-lazy `Grid` so the height
    /// measures correctly (see `body`).
    private var rowsView: some View {
        let rows = model.rows
        let half = (rows.count + 1) / 2
        return Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.xl, verticalSpacing: Theme.Spacing.xs) {
            ForEach(0..<max(half, 1), id: \.self) { i in
                GridRow {
                    if i < rows.count { rowView(rows[i]) } else { Color.clear.frame(height: 1) }
                    if i + half < rows.count { rowView(rows[i + half]) } else { Color.clear.frame(height: 1) }
                }
            }
            if rows.isEmpty {
                GridRow {
                    Text("No stream details yet.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .gridCellColumns(2)
                }
            }
        }
    }

    private func rowView(_ row: NativeInfoRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(row.label)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 260, alignment: .leading)
            Text(row.value)
                .font(Theme.Font.body.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
