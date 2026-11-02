import Combine
import SharedCore
import UIKit

// Insights wave 1c: the native route's round tool buttons. Every `transportBarCustomMenuItems`
// entry that is a `UIMenu` renders on tvOS 26 as a round transport-bar button opening a popover.
// Subtitles, Audio and Speed stay the system's own buttons; these add Episodes, Sources, subtitle
// Timing, Sync Line and Remember Speed. Episodes and Sources are deferred (`.uncached`) so each
// open lists what the engine knows then.
@MainActor
enum NativeTransportMenus {
    struct Inputs: Equatable {
        /// A presenter can swap playback contexts (episode jump / source switch).
        var canSwitchStreams: Bool
        /// A series with an episode list.
        var hasEpisodes: Bool
        /// `PlayerTopPanelModel.supportsSubtitleDelay` (an add-on rendition is showing).
        var timing: Bool
        /// `PlayerTopPanelModel.syncLineAvailable`.
        var syncLine: Bool
        /// Series only: "Remember Speed for This Show" is offered.
        var rememberAvailable: Bool
        var remember: Bool
    }

    struct Actions {
        /// The Sources popover opened (FEAT-49: the host reports the list closed when the bar hides).
        let onSourcesOpened: () -> Void
        /// Sync Line pressed: the host captures the position and presents the sheet.
        let onSyncLine: () -> Void
        let onRememberToggle: () -> Void
    }

    static func build(inputs: Inputs, engine: NextEpisodeEngine, model: PlayerTopPanelModel,
                      actions: Actions) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if inputs.canSwitchStreams, inputs.hasEpisodes {
            items.append(UIMenu(title: String(localized: "Episodes"), image: UIImage(systemName: "list.number"),
                                children: [episodesElement(engine: engine)]))
        }
        if inputs.canSwitchStreams {
            items.append(UIMenu(title: String(localized: "Sources"),
                                image: UIImage(systemName: "arrow.triangle.2.circlepath"),
                                children: [sourcesElement(engine: engine, onOpened: actions.onSourcesOpened)]))
        }
        if inputs.timing {
            items.append(timingMenu(model: model))
        }
        if inputs.syncLine {
            let syncLine = actions.onSyncLine
            items.append(UIAction(title: String(localized: "Sync Line"),
                                  image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in syncLine() })
        }
        if inputs.rememberAvailable {
            let toggle = actions.onRememberToggle
            items.append(UIAction(title: String(localized: "Remember Speed for This Show"),
                                  image: UIImage(systemName: "gauge.with.needle"),
                                  state: inputs.remember ? .on : .off) { _ in toggle() })
        }
        return items
    }

    // MARK: Episodes

    private static func episodesElement(engine: NextEpisodeEngine) -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak engine] completion in
            guard let engine else { completion([]); return }
            let episodes = PlayerEpisodesColumn.sortedEpisodes(engine)
            let actions = episodes.map { episodeAction($0, engine: engine) }
            let seasons = Set(episodes.compactMap { $0.season?.value })
            guard seasons.count > 1 else { completion(actions); return }
            // Several seasons: one submenu each, in order.
            var bySeason: [(Int, [UIMenuElement])] = []
            for (episode, action) in zip(episodes, actions) {
                let season = episode.season?.value ?? 0
                if bySeason.last?.0 == season {
                    bySeason[bySeason.count - 1].1.append(action)
                } else {
                    bySeason.append((season, [action]))
                }
            }
            completion(bySeason.map { season, children in
                UIMenu(title: String(format: String(localized: "Season %d"), season), children: children)
            })
        }
    }

    private static func episodeAction(_ episode: MetaVideo, engine: NextEpisodeEngine) -> UIAction {
        let s = episode.season?.value ?? 0, e = episode.episode?.value ?? 0
        let isCurrent = s == engine.currentSeason && e == engine.currentEpisode
        return UIAction(title: "S\(s)E\(e) · \(episode.title)", state: isCurrent ? .on : .off) { [weak engine] _ in
            guard !isCurrent else { return }
            engine?.jumpToEpisode(episode)
        }
    }

    // MARK: Sources

    /// How long the popover waits for a source list still loading before showing what it has.
    static let sourcesWaitSec: Double = 8

    private static func sourcesElement(engine: NextEpisodeEngine, onOpened: @escaping () -> Void) -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak engine] completion in
            guard let engine else { completion([]); return }
            onOpened()
            engine.loadSources()
            guard engine.sourcesLoading else { completion(sourceItems(engine)); return }
            SourcesWait(engine: engine, timeoutSec: sourcesWaitSec) { [weak engine] in
                completion(engine.map(sourceItems) ?? [])
            }.start()
        }
    }

    private static func sourceItems(_ engine: NextEpisodeEngine) -> [UIMenuElement] {
        if engine.sourcesBlockedBySearch {
            return [note(engine.sourcesBlockedByJump
                         ? String(localized: "Finding the episode's source…")
                         : String(localized: "Finding the next episode's source…"))]
        }
        if engine.sources.isEmpty {
            return [note(engine.sourcesLoading
                         ? String(localized: "Loading sources…")
                         : String(localized: "No alternate sources found yet."))]
        }
        return engine.sources.prefix(12).map { stream in
            let isCurrent = engine.isCurrentSource(stream)
            var subtitle = stream.addonName
            if StreamPickerView.isYouTubeResolved(stream) { subtitle += " · YouTube" }
            let action = UIAction(title: stream.streamLabel, state: isCurrent ? .on : .off) { [weak engine] _ in
                guard !isCurrent else { return }
                _ = engine?.playSource(stream)
            }
            action.subtitle = subtitle
            return action
        }
    }

    private static func note(_ text: String) -> UIAction {
        UIAction(title: text, attributes: .disabled) { _ in }
    }

    // MARK: Timing

    private static func timingMenu(model: PlayerTopPanelModel) -> UIMenu {
        // The current delay as a disabled first row, re-read each time the popover is shown.
        let current = UIDeferredMenuElement.uncached { [weak model] completion in
            let ms = model?.subtitleDelayMs ?? 0
            completion([note(String(format: String(localized: "Delay %@"), NativeSubtitleTiming.label(ms)))])
        }
        func step(_ title: String, _ delta: Int?) -> UIAction {
            UIAction(title: title, attributes: .keepsMenuPresented) { [weak model] _ in
                guard let model else { return }
                let next = delta.map { NativeSubtitleTiming.adjusted(model.subtitleDelayMs, by: $0) } ?? 0
                guard next != model.subtitleDelayMs else { return }
                model.onSubtitleDelayChange?(next)
            }
        }
        return UIMenu(title: String(localized: "Subtitle Timing"), image: UIImage(systemName: "timer"), children: [
            current,
            step("\u{2212}0.5 s", -NativeSubtitleTiming.stepMs),
            step("+0.5 s", NativeSubtitleTiming.stepMs),
            step(String(localized: "Reset"), nil),
        ])
    }
}

/// Waits for `NextEpisodeEngine.sourcesLoading` to drop (or a timeout), then calls `done` once.
/// Retains itself through its subscription until it finishes.
@MainActor
private final class SourcesWait {
    private weak var engine: NextEpisodeEngine?
    private let timeoutSec: Double
    private var done: (() -> Void)?
    private var cancellable: AnyCancellable?
    private var keepAlive: SourcesWait?

    init(engine: NextEpisodeEngine, timeoutSec: Double, done: @escaping () -> Void) {
        self.engine = engine
        self.timeoutSec = timeoutSec
        self.done = done
    }

    func start() {
        keepAlive = self
        // Same `@Published` willSet caveat as the pill installer: finish on the next turn.
        cancellable = engine?.$sourcesLoading
            .filter { !$0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSec) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard let done else { return }
        self.done = nil
        cancellable?.cancel()
        done()
        keepAlive = nil
    }
}
