import AVKit
import Combine
import SharedCore
import UIKit

// Insights wave 1c: the native route's round tool buttons. Every `transportBarCustomMenuItems`
// entry that is a `UIMenu` renders on tvOS 26 as a round transport-bar button opening a popover.
// Subtitles, Audio and Speed stay the system's own buttons; these add Episodes, Sources, subtitle
// Timing, Sync Line and Remember Speed.
//
// Device fix (2026-11-01): `transportBarCustomMenuItems` takes `UIAction` and `UIMenu` only (one
// inline level). A `UIDeferredMenuElement` is dropped there: Episodes and Sources (whose only
// child was a deferred element) were never drawn, and Timing's deferred "Delay …" row never
// rendered. Every menu is now an eager `UIMenu`/`UIAction` tree built from `Inputs`, and
// `NativeTransportMenusInstaller` rebuilds and reassigns the whole array whenever an input
// changes (episode list, source list and its loading state, the current delay, Remember, the
// selected subtitle turning Timing on or off). AVKit also ignores `.keepsMenuPresented` there, so
// each Timing press closes the popover; reopening it shows the new delay in its first row.
@MainActor
enum NativeTransportMenus {
    struct EpisodeRow: Equatable {
        /// Lookup key for the tap (the episode's video id).
        let key: String
        /// "S1E5 · Title".
        let title: String
        let isCurrent: Bool
    }

    struct SourceRow: Equatable {
        /// Lookup key for the tap (position + listed-stream key, unique within one list).
        let key: String
        let title: String
        let subtitle: String?
        let isCurrent: Bool
    }

    /// What the Sources popover lists.
    enum SourcesState: Equatable {
        /// The list is loading (or has not been asked for yet).
        case loading
        /// An up-next search (or an episode jump's) owns the stream flow; the list loads after it.
        case blocked(jump: Bool)
        case empty
        case rows([SourceRow])
    }

    struct Inputs: Equatable {
        /// A presenter can swap playback contexts (episode jump / source switch).
        var canSwitchStreams: Bool
        /// The series' episodes in order; empty hides Episodes.
        var episodes: [EpisodeRow]
        var sources: SourcesState
        /// `PlayerTopPanelModel.supportsSubtitleDelay` (an add-on rendition is showing).
        var timing: Bool
        /// `PlayerTopPanelModel.subtitleDelayMs`, shown as Timing's first row.
        var delayMs: Int
        /// `PlayerTopPanelModel.syncLineAvailable`.
        var syncLine: Bool
        /// Series only: "Remember Speed for This Show" is offered.
        var rememberAvailable: Bool
        var remember: Bool
    }

    struct Actions {
        var onEpisode: (String) -> Void = { _ in }
        var onSource: (String) -> Void = { _ in }
        /// A Timing step: a delta in ms, nil = Reset.
        var onDelayStep: (Int?) -> Void = { _ in }
        /// Sync Line pressed: the host captures the position and presents the sheet.
        var onSyncLine: () -> Void = {}
        var onRemember: (Bool) -> Void = { _ in }
    }

    /// Accessibility / test identifiers of the round buttons.
    enum Item: String {
        case episodes, sources, timing, syncLine, rememberSpeed
    }

    /// The eager menu tree for `inputs`. Pure: nothing deferred, nothing read later.
    static func build(_ inputs: Inputs, actions: Actions) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if inputs.canSwitchStreams, !inputs.episodes.isEmpty {
            items.append(UIMenu(title: String(localized: "Episodes"), image: UIImage(systemName: "list.number"),
                                identifier: identifier(.episodes),
                                children: episodeItems(inputs.episodes, onEpisode: actions.onEpisode)))
        }
        if inputs.canSwitchStreams {
            items.append(UIMenu(title: String(localized: "Sources"),
                                image: UIImage(systemName: "arrow.triangle.2.circlepath"),
                                identifier: identifier(.sources),
                                children: sourceItems(inputs.sources, onSource: actions.onSource)))
        }
        if inputs.timing {
            items.append(timingMenu(delayMs: inputs.delayMs, onStep: actions.onDelayStep))
        }
        if inputs.syncLine {
            let syncLine = actions.onSyncLine
            items.append(UIAction(title: String(localized: "Sync Line"),
                                  image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                                  identifier: UIAction.Identifier(identifier(.syncLine).rawValue)) { _ in syncLine() })
        }
        if inputs.rememberAvailable {
            items.append(rememberMenu(on: inputs.remember, onRemember: actions.onRemember))
        }
        return items
    }

    static func identifier(_ item: Item) -> UIMenu.Identifier {
        UIMenu.Identifier("nuvio.player.tool.\(item.rawValue)")
    }

    // MARK: Episodes

    /// One flat action per episode, in the order given (titles carry `S#E#`). Never nested:
    /// a submenu inside a transport-bar item is not drawn.
    static func episodeItems(_ rows: [EpisodeRow], onEpisode: @escaping (String) -> Void) -> [UIMenuElement] {
        rows.map { row in
            UIAction(title: row.title, state: row.isCurrent ? .on : .off) { _ in
                guard !row.isCurrent else { return }
                onEpisode(row.key)
            }
        }
    }

    /// Rows for `episodes` (already sorted), the playing one marked.
    static func episodeRows(_ episodes: [MetaVideo], currentSeason: Int?, currentEpisode: Int?) -> [EpisodeRow] {
        episodes.map { episode in
            let s = episode.season?.value ?? 0, e = episode.episode?.value ?? 0
            return EpisodeRow(key: episode.id, title: "S\(s)E\(e) · \(episode.title)",
                              isCurrent: Int(s) == currentSeason && Int(e) == currentEpisode)
        }
    }

    // MARK: Sources

    /// The most sources the popover lists.
    static let maxSources = 12

    static func sourceItems(_ state: SourcesState, onSource: @escaping (String) -> Void) -> [UIMenuElement] {
        switch state {
        case .loading: return [note(String(localized: "Loading sources…"))]
        case .blocked(let jump):
            return [note(jump ? String(localized: "Finding the episode's source…")
                              : String(localized: "Finding the next episode's source…"))]
        case .empty: return [note(String(localized: "No alternate sources found yet."))]
        case .rows(let rows):
            return rows.map { row in
                let action = UIAction(title: row.title, state: row.isCurrent ? .on : .off) { _ in
                    guard !row.isCurrent else { return }
                    onSource(row.key)
                }
                action.subtitle = row.subtitle
                return action
            }
        }
    }

    /// The Sources state the engine is in, plus the streams behind each row key.
    static func sourcesState(_ engine: NextEpisodeEngine) -> (SourcesState, [String: StreamItem]) {
        if engine.sourcesBlockedBySearch { return (.blocked(jump: engine.sourcesBlockedByJump), [:]) }
        if engine.sources.isEmpty { return (engine.sourcesLoading ? .loading : .empty, [:]) }
        var byKey: [String: StreamItem] = [:]
        let rows = engine.sources.prefix(maxSources).enumerated().map { i, stream -> SourceRow in
            let key = "\(i)|\(stream.playbackStreamKey)"
            byKey[key] = stream
            var subtitle = stream.addonName
            if StreamPickerView.isYouTubeResolved(stream) { subtitle += " · YouTube" }
            return SourceRow(key: key, title: stream.streamLabel, subtitle: subtitle.isEmpty ? nil : subtitle,
                             isCurrent: engine.isCurrentSource(stream))
        }
        return (.rows(rows), byKey)
    }

    /// An informational row. Enabled on purpose (a no-op): a disabled row is not guaranteed to be
    /// drawn in a transport-bar popover, and the text is the point.
    static func note(_ text: String) -> UIAction {
        UIAction(title: text) { _ in }
    }

    // MARK: Timing

    /// "Delay +0.5 s" (the current value) first, then −0.5 s / +0.5 s / Reset.
    static func timingMenu(delayMs: Int, onStep: @escaping (Int?) -> Void) -> UIMenu {
        let current = String(format: String(localized: "Delay %@"), NativeSubtitleTiming.label(delayMs))
        func step(_ title: String, _ delta: Int?) -> UIAction {
            // `.keepsMenuPresented` is honoured where AVKit supports it; where it does not, the
            // popover closes and the rebuilt menu shows the new delay when reopened.
            UIAction(title: title, attributes: .keepsMenuPresented) { _ in onStep(delta) }
        }
        let menu = UIMenu(title: String(localized: "Subtitle Timing"), image: UIImage(systemName: "timer"),
                          identifier: identifier(.timing), children: [
            note(current),
            step("\u{2212}0.5 s", -NativeSubtitleTiming.stepMs),
            step("+0.5 s", NativeSubtitleTiming.stepMs),
            step(String(localized: "Reset"), nil),
        ])
        menu.subtitle = NativeSubtitleTiming.label(delayMs)
        return menu
    }

    // MARK: Remember Speed

    /// A top-level `UIAction`'s `state` is not drawn on a round transport-bar button, so Remember
    /// is a menu with an On / Off pair (the checkmark shows the state) and a filled gauge while on.
    static func rememberMenu(on: Bool, onRemember: @escaping (Bool) -> Void) -> UIMenu {
        UIMenu(title: String(localized: "Remember Speed for This Show"),
               image: UIImage(systemName: on ? "gauge.with.needle.fill" : "gauge.with.needle"),
               identifier: identifier(.rememberSpeed), children: [
            UIAction(title: String(localized: "On"), state: on ? .on : .off) { _ in if !on { onRemember(true) } },
            UIAction(title: String(localized: "Off"), state: on ? .off : .on) { _ in if on { onRemember(false) } },
        ])
    }
}

/// Keeps `playerVC.transportBarCustomMenuItems` in step with the engine and the panel model: the
/// inputs are recomputed on every change of what the buttons show and the array is reassigned only
/// when they differ. Lives as long as the player container.
@MainActor
final class NativeTransportMenusInstaller {
    private weak var playerVC: AVPlayerViewController?
    private let engine: NextEpisodeEngine
    private let model: PlayerTopPanelModel
    private let speedModel: NativeSpeedModel
    private let canSwitchStreams: Bool
    private let isSeries: Bool
    private(set) var installed: NativeTransportMenus.Inputs?
    private var episodesByKey: [String: MetaVideo] = [:]
    private var sourcesByKey: [String: StreamItem] = [:]
    /// The source list was asked for while the transport bar is up (released when it hides).
    private var sourcesRequested = false
    private var cancellable: AnyCancellable?

    /// Sync Line pressed (the host captures the position and presents the sheet).
    var onSyncLine: () -> Void = {}

    init(playerVC: AVPlayerViewController, engine: NextEpisodeEngine, model: PlayerTopPanelModel,
         speedModel: NativeSpeedModel, canSwitchStreams: Bool, isSeries: Bool) {
        self.playerVC = playerVC
        self.engine = engine
        self.model = model
        self.speedModel = speedModel
        self.canSwitchStreams = canSwitchStreams
        self.isSeries = isSeries
        refresh()
        // `@Published` emits before the new value is stored: the main-queue hop lets `refresh`
        // read the values that triggered the emission.
        cancellable = Publishers.MergeMany([
            engine.$sources.map { _ in () }.eraseToAnyPublisher(),
            engine.$sourcesLoading.map { _ in () }.eraseToAnyPublisher(),
            engine.$sourcesBlockedBySearch.map { _ in () }.eraseToAnyPublisher(),
            engine.$sourcesBlockedByJump.map { _ in () }.eraseToAnyPublisher(),
            engine.$lateEpisodes.map { _ in () }.eraseToAnyPublisher(),
            model.$subtitleDelayMs.map { _ in () }.eraseToAnyPublisher(),
            model.$supportsSubtitleDelay.map { _ in () }.eraseToAnyPublisher(),
            model.$syncLineAvailable.map { _ in () }.eraseToAnyPublisher(),
            speedModel.$remember.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refresh() }
    }

    /// The inputs as they stand now (and the lookup tables behind the row keys).
    func currentInputs() -> NativeTransportMenus.Inputs {
        var episodeRows: [NativeTransportMenus.EpisodeRow] = []
        var sources = NativeTransportMenus.SourcesState.loading
        if canSwitchStreams {
            let sorted = isSeries ? PlayerEpisodesColumn.sortedEpisodes(engine) : []
            episodesByKey = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            episodeRows = NativeTransportMenus.episodeRows(sorted, currentSeason: engine.currentSeason,
                                                           currentEpisode: engine.currentEpisode)
            let (state, byKey) = NativeTransportMenus.sourcesState(engine)
            sources = (state == .empty && !sourcesRequested) ? .loading : state
            sourcesByKey = byKey
        }
        return NativeTransportMenus.Inputs(
            canSwitchStreams: canSwitchStreams,
            episodes: episodeRows,
            sources: sources,
            timing: model.supportsSubtitleDelay,
            delayMs: model.subtitleDelayMs,
            syncLine: model.syncLineAvailable,
            rememberAvailable: speedModel.rememberAvailable,
            remember: speedModel.remember)
    }

    /// Rebuilds and reassigns the buttons when what they show changed.
    func refresh() {
        guard let playerVC else { return }
        let inputs = currentInputs()
        guard inputs != installed else { return }
        installed = inputs
        playerVC.transportBarCustomMenuItems = NativeTransportMenus.build(inputs, actions: actions())
        print("[NativePlayer] tools=\(Self.summary(inputs))")
    }

    /// The transport bar came up. The Sources button is on screen from now on, so the list is
    /// asked for here (a deferred, load-on-open list is not possible in a transport-bar menu) and
    /// is usually in by the time the popover is opened; the menu rebuilds as rows arrive. This is
    /// the native twin of the mpv Sources popover opening (`sourceColumnAppeared` + `loadSources`).
    func transportBarShown() {
        guard canSwitchStreams, !sourcesRequested else { return }
        sourcesRequested = true
        // A list blocked by an up-next search reloads itself when the search ends while the list
        // is on screen.
        engine.sourceColumnAppeared()
        if engine.sources.isEmpty, !engine.sourcesLoading, !engine.sourcesBlockedBySearch {
            engine.loadSources()
        }
        refresh()
    }

    /// The transport bar went away: the list is off screen (the popover closes with the bar).
    /// FEAT-49 layer 2: with next-episode preload on, the list gives the shared stream flow back
    /// (`noteSourceListClosed` drops it), so the preload is never starved by an idle list; the
    /// next bar show loads it again. With preload off the list stays.
    func transportBarHidden() {
        guard canSwitchStreams, sourcesRequested else { return }
        sourcesRequested = false
        engine.sourceColumnDisappeared()
        engine.noteSourceListClosed()
        refresh()
    }

    private func actions() -> NativeTransportMenus.Actions {
        NativeTransportMenus.Actions(
            onEpisode: { [weak self] key in
                guard let self, let episode = self.episodesByKey[key] else { return }
                print("[NativePlayer] tools: episode → \(key)")
                self.engine.jumpToEpisode(episode)
            },
            onSource: { [weak self] key in
                guard let self, let stream = self.sourcesByKey[key] else { return }
                print("[NativePlayer] tools: source → \(stream.streamLabel)")
                _ = self.engine.playSource(stream)
            },
            onDelayStep: { [weak self] delta in
                guard let self else { return }
                // The live value, not the one the menu was built with.
                let current = self.model.subtitleDelayMs
                let next = delta.map { NativeSubtitleTiming.adjusted(current, by: $0) } ?? 0
                print("[NativePlayer] tools: subtitle delay \(current) → \(next) ms")
                guard next != current else { return }
                // → NativePlayerPanelAdapter → NativePlaybackCoordinator.setSubtitleDelay (persists,
                // re-times the served VTT, refetches); the coordinator's value flows back into
                // `model.subtitleDelayMs`, which rebuilds this menu with the new first row.
                self.model.onSubtitleDelayChange?(next)
            },
            onSyncLine: { [weak self] in self?.onSyncLine() },
            onRemember: { [weak self] on in
                guard let self else { return }
                print("[NativePlayer] tools: remember speed → \(on ? 1 : 0)")
                self.speedModel.onRememberChange?(on)
                self.refresh()
            })
    }

    static func summary(_ inputs: NativeTransportMenus.Inputs) -> String {
        var parts: [String] = []
        if inputs.canSwitchStreams, !inputs.episodes.isEmpty { parts.append("episodes(\(inputs.episodes.count))") }
        if inputs.canSwitchStreams {
            switch inputs.sources {
            case .loading: parts.append("sources(loading)")
            case .blocked: parts.append("sources(blocked)")
            case .empty: parts.append("sources(0)")
            case .rows(let rows): parts.append("sources(\(rows.count))")
            }
        }
        if inputs.timing { parts.append("timing(\(inputs.delayMs))") }
        if inputs.syncLine { parts.append("syncLine") }
        if inputs.rememberAvailable { parts.append("remember(\(inputs.remember ? 1 : 0))") }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }
}
