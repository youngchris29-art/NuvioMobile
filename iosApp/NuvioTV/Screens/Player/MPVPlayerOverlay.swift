import SwiftUI

// Insights (2026-11-01): the mpv route's popovers and content shelves (Rivulet / AVKit tvOS 26
// layout, no top panel). Drawn over the transport bar inside the player screen, never presented,
// so the video keeps playing under them. This is the one place the mpv controller hands focus to
// SwiftUI: a popover or a shelf with focusable rows takes system focus (the controller asks the
// focus engine for an update when it opens one and again once the overlay is drawn), and Menu inside comes back to the controller
// through `MPVPlaybackState.overlayMenu`, which resolves it with `MenuPrecedence`. A shelf with
// nothing focusable (Info) leaves the remote with the controller. Solid `PlayerSurface` fill
// (BUG-180: nothing re-samples the 4K/HDR video under it).

extension PillKind {
    /// The popover's size above its disc; nil = the disc opens none (Aspect cycles, More opens the
    /// Info shelf).
    var popoverSize: CGSize? {
        switch self {
        case .subtitles: return CGSize(width: 820, height: 560)
        case .audio: return CGSize(width: 820, height: 520)
        case .speed: return CGSize(width: 1180, height: 500)
        case .sources: return CGSize(width: 820, height: 560)
        case .episodes: return CGSize(width: 680, height: 560)
        case .aspect, .more: return nil
        }
    }
}

struct MPVPlayerOverlay: View {
    @ObservedObject var model: TransportBarModel
    let state: MPVPlaybackState
    let panelModel: PlayerTopPanelModel
    let engine: NextEpisodeEngine
    let canSwitchStreams: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let layout = TransportBarLayout(canvas: geo.size, pillCount: model.pills.count)
            ZStack(alignment: .topLeading) {
                if let pill = model.openPopover, let index = model.pills.firstIndex(of: pill),
                   let size = pill.popoverSize {
                    let frame = layout.popoverFrame(discIndex: index, size: size)
                    popoverContent(pill)
                        .id(pill)
                        .onAppear { state.requestOverlayFocus?() }
                        .padding(Theme.Spacing.lg)
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                        .playerSurface(in: RoundedRectangle(cornerRadius: TransportBarLayout.overlayCornerRadius,
                                                            style: .continuous))
                        .focusSection()
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("player.popover.\(pill.rawValue)")
                        .position(x: frame.midX, y: frame.midY)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
                if let pill = model.openInfoPill {
                    let frame = layout.shelfFrame
                    shelfContent(pill)
                        .id(pill)
                        .onAppear { state.requestOverlayFocus?() }
                        .padding(Theme.Spacing.lg)
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                        .playerSurface(in: RoundedRectangle(cornerRadius: TransportBarLayout.overlayCornerRadius,
                                                            style: .continuous))
                        .focusSection()
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("player.shelf.\(pill.rawValue)")
                        .position(x: frame.midX, y: frame.midY)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.2), value: model.openPopover)
            .animation(.easeInOut(duration: 0.2), value: model.openInfoPill)
        }
        .ignoresSafeArea()
        // Menu reaches here only while focus is inside a popover or shelf (nothing else in the
        // player is focusable); the controller decides the level.
        .onExitCommand { state.overlayMenu?() }
        // Same reason: Play/Pause from inside goes to the controller's toggle.
        .onPlayPauseCommand { state.togglePause?() }
    }

    @ViewBuilder
    private func popoverContent(_ pill: PillKind) -> some View {
        switch pill {
        case .subtitles:
            PlayerSubtitlesTab(model: panelModel)
        case .audio:
            PlayerAudioTab(model: panelModel)
        case .speed:
            MPVPlaybackTab(state: state, engine: engine, canSwitchStreams: canSwitchStreams, settingsOnly: true,
                           onClose: { state.closeOverlay?() })
        case .sources:
            PlayerSourcesColumn(engine: engine, onClose: { state.closeOverlay?() })
        case .episodes:
            PlayerEpisodesColumn(engine: engine, onClose: { state.closeOverlay?() })
        case .aspect, .more:
            EmptyView()
        }
    }

    @ViewBuilder
    private func shelfContent(_ pill: PlayerInfoPill) -> some View {
        switch pill {
        case .info:
            MPVInfoShelf(model: panelModel)
        case .cast:
            PlayerCastContent(model: panelModel)
        case .chapters:
            PlayerChaptersTab(model: panelModel)
        case .upNext:
            PlayerUpNextContent(model: panelModel)
        }
    }
}

/// The Info shelf observes the panel model itself, so the overlay above does not re-render on
/// every Stream Info refresh.
private struct MPVInfoShelf: View {
    @ObservedObject var model: PlayerTopPanelModel
    var body: some View { PlayerInfoTab(info: model.info) }
}
