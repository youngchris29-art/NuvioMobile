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
    enum Item: String, CaseIterable {
        case episodes, sources, timing, syncLine, rememberSpeed

        /// The button's localized name: its menu title and its VoiceOver label (review r3: the
        /// round buttons draw image-only, and AVKit read them as "" without an explicit label).
        var title: String {
            switch self {
            case .episodes: return String(localized: "Episodes")
            case .sources: return String(localized: "Sources")
            case .timing: return String(localized: "Subtitle Timing")
            case .syncLine: return String(localized: "Sync Line")
            case .rememberSpeed: return String(localized: "Remember Speed for This Show")
            }
        }
    }

    /// Sets the round button's VoiceOver label to its name (`UIMenuElement.accessibilityLabel`).
    private static func labelled<Element: UIMenuElement>(_ element: Element, _ item: Item) -> Element {
        element.accessibilityLabel = item.title
        return element
    }

    /// The eager menu tree for `inputs`. Pure: nothing deferred, nothing read later.
    static func build(_ inputs: Inputs, actions: Actions) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if inputs.canSwitchStreams, !inputs.episodes.isEmpty {
            items.append(labelled(UIMenu(title: Item.episodes.title, image: UIImage(systemName: "list.number"),
                                         identifier: identifier(.episodes),
                                         children: episodeItems(inputs.episodes, onEpisode: actions.onEpisode)),
                                  .episodes))
        }
        if inputs.canSwitchStreams {
            items.append(labelled(UIMenu(title: Item.sources.title,
                                         image: UIImage(systemName: "arrow.triangle.2.circlepath"),
                                         identifier: identifier(.sources),
                                         children: sourceItems(inputs.sources, onSource: actions.onSource)),
                                  .sources))
        }
        if inputs.timing {
            items.append(timingMenu(delayMs: inputs.delayMs, onStep: actions.onDelayStep))
        }
        if inputs.syncLine {
            let syncLine = actions.onSyncLine
            items.append(labelled(UIAction(title: Item.syncLine.title,
                                           image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                                           identifier: UIAction.Identifier(identifier(.syncLine).rawValue)) { _ in syncLine() },
                                  .syncLine))
        }
        if inputs.rememberAvailable {
            items.append(rememberMenu(on: inputs.remember, onRemember: actions.onRemember))
        }
        return items
    }

    /// Which round buttons `build` draws for `inputs`, in order (C2: a change here moves the
    /// system pills right of them, so the installer puts the focus back by name).
    static func itemKinds(_ inputs: Inputs) -> [Item] {
        var kinds: [Item] = []
        if inputs.canSwitchStreams, !inputs.episodes.isEmpty { kinds.append(.episodes) }
        if inputs.canSwitchStreams { kinds.append(.sources) }
        if inputs.timing { kinds.append(.timing) }
        if inputs.syncLine { kinds.append(.syncLine) }
        if inputs.rememberAvailable { kinds.append(.rememberSpeed) }
        return kinds
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
            // Review r5: localized through the catalog's `S%lldE%lld · %@` (es "T1E5 · …").
            return EpisodeRow(key: episode.id, title: String(localized: "S\(Int(s))E\(Int(e)) · \(episode.title)"),
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
        let menu = UIMenu(title: Item.timing.title, image: UIImage(systemName: "timer"),
                          identifier: identifier(.timing), children: [
            note(current),
            step("\u{2212}0.5 s", -NativeSubtitleTiming.stepMs),
            step("+0.5 s", NativeSubtitleTiming.stepMs),
            step(String(localized: "Reset"), nil),
        ])
        menu.subtitle = NativeSubtitleTiming.label(delayMs)
        return labelled(menu, .timing)
    }

    // MARK: Remember Speed

    /// A top-level `UIAction`'s `state` is not drawn on a round transport-bar button, so Remember
    /// is a menu with an On / Off pair (the checkmark shows the state) and a filled gauge while on.
    static func rememberMenu(on: Bool, onRemember: @escaping (Bool) -> Void) -> UIMenu {
        labelled(UIMenu(title: Item.rememberSpeed.title,
                        image: UIImage(systemName: on ? "gauge.with.needle.fill" : "gauge.with.needle"),
                        identifier: identifier(.rememberSpeed), children: [
            UIAction(title: String(localized: "On"), state: on ? .on : .off) { _ in if !on { onRemember(true) } },
            UIAction(title: String(localized: "Off"), state: on ? .off : .on) { _ in if on { onRemember(false) } },
        ]), .rememberSpeed)
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
    /// The source list has been asked for (the bar came up once). Latched for the playback:
    /// Insights review r4 (P2) — the list loads once and is not dropped when the bar hides.
    private var sourcesRequested = false
    private var cancellable: AnyCancellable?
    /// C2 re-pass (review r4): the name of the last transport-bar button that held the focus,
    /// tracked on every focus update. A tool-set change usually lands while the focus is inside a
    /// popover (an add-on subtitle picked in the Subtitles popover), where nothing in the bar is
    /// focused; this is the button the viewer came from.
    private var lastBarItemName: String?
    /// A refocus asked for while the focus was outside the bar: applied when it comes back.
    private var pendingRefocus: String?
    private var focusObserver: NSObjectProtocol?

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
        focusObserver = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] note in
            let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            let next = context?.nextFocusedItem as? UIView
            MainActor.assumeIsolated { self?.focusDidUpdate(to: next) }
        }
    }

    deinit {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
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

    /// Rebuilds and reassigns the buttons when what they show changed (never when nothing did).
    ///
    /// Device re-pass 2026-11-01 (C2): AVKit keeps the focus at the same position in the bar's row
    /// across a reassignment, not on the same button, and the system pills (Speed, Subtitles,
    /// Audio) sit right of the custom ones. Turning subtitles on adds Timing + Sync Line and the
    /// focus landed on Remember Speed instead of Subtitles. When the set of buttons changes, the
    /// focused button's name is read first and the focus is asked back onto the button with that
    /// name once AVKit has redrawn the row. A content-only change keeps the count, so the position
    /// AVKit keeps is the right button. (A Timing step still closes its popover: a `UIMenu`'s
    /// children cannot be changed in place, only a new menu assigned.)
    ///
    /// Review r4 (device, C2 still failing): the change usually lands while the focus is in the
    /// Subtitles popover, outside the bar, so nothing could be read at that moment. The name now
    /// comes from the focused bar button when there is one, else from the last bar button that
    /// had the focus (`lastBarItemName`); in that case the refocus waits until the focus is back
    /// in the bar (the popover closed, AVKit put it on the old position) and is applied then.
    func refresh() {
        guard let playerVC else { return }
        let inputs = currentInputs()
        guard inputs != installed else { return }
        let setChanged = installed.map(NativeTransportMenus.itemKinds) != NativeTransportMenus.itemKinds(inputs)
        var focusedName: String?
        var deferred = false
        if installed != nil, setChanged {
            if let now = focusedBarItemName(in: playerVC) {
                focusedName = now
            } else if let last = lastBarItemName {
                focusedName = last
                deferred = true
            }
        }
        installed = inputs
        playerVC.transportBarCustomMenuItems = NativeTransportMenus.build(inputs, actions: actions())
        print("[NativePlayer] tools=\(Self.summary(inputs))\(focusedName.map { " refocus=\($0)\(deferred ? " (deferred)" : "")" } ?? "")")
        guard let focusedName else { return }
        if deferred {
            pendingRefocus = focusedName
        } else {
            pendingRefocus = nil
            restoreFocus(to: focusedName, attempt: 0)
        }
    }

    /// Every focus update anywhere: remembers the bar button that got the focus, and applies a
    /// deferred refocus once the focus is back in the bar.
    private func focusDidUpdate(to view: UIView?) {
        guard let playerVC, let view, let name = barItemName(of: view, in: playerVC) else { return }
        lastBarItemName = name
        guard let pending = pendingRefocus else { return }
        pendingRefocus = nil
        if name == pending {
            print("[NativePlayer] tools: refocus \(pending) ok (focus back in the bar)")
            return
        }
        // Not from inside the focus update: ask once the engine has settled.
        restoreFocus(to: pending, attempt: 0)
    }

    /// The accessibility name of the focused item, when it is a transport-bar button.
    private func focusedBarItemName(in playerVC: AVPlayerViewController) -> String? {
        guard let view = UIFocusSystem.focusSystem(for: playerVC.view)?.focusedItem as? UIView else { return nil }
        return barItemName(of: view, in: playerVC)
    }

    /// `view`'s name (its own label or its nearest labelled ancestor's below the player's view)
    /// when it sits in the transport bar's button row: inside the player's view and level with the
    /// custom buttons (a popover's rows sit above the row). With no custom button on screen to
    /// compare against, any labelled item inside the player's view counts (the r3 behaviour).
    private func barItemName(of view: UIView, in playerVC: AVPlayerViewController) -> String? {
        let root = playerVC.view!
        guard view.isDescendant(of: root), let name = Self.labelledName(of: view, below: root) else { return nil }
        let titles = playerVC.transportBarCustomMenuItems.compactMap { element -> String? in
            (element as? UIMenu)?.title ?? (element as? UIAction)?.title
        }
        if titles.contains(name) { return name }
        guard let reference = titles.lazy.compactMap({ Self.focusableView(named: $0, in: root) }).first else {
            return name
        }
        let a = view.convert(view.bounds, to: root)
        let b = reference.convert(reference.bounds, to: root)
        let tolerance = max(a.height, b.height) * 0.75
        return abs(a.midY - b.midY) <= tolerance ? name : nil
    }

    private func restoreFocus(to name: String, attempt: Int) {
        let delays: [TimeInterval] = [0.05, 0.2, 0.45]
        guard attempt < delays.count else {
            print("[NativePlayer] tools: refocus \(name) gave up")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self, let playerVC = self.playerVC else { return }
            if self.focusedBarItemName(in: playerVC) == name {
                print("[NativePlayer] tools: refocus \(name) ok (attempt \(attempt))")
                return
            }
            let candidates = Self.focusableViews(named: name, in: playerVC.view)
            guard let target = candidates.first else {
                print("[NativePlayer] tools: refocus \(name) attempt \(attempt): no candidate")
                self.restoreFocus(to: name, attempt: attempt + 1)
                return
            }
            print("[NativePlayer] tools: refocus \(name) attempt \(attempt): candidates=\(candidates.count) target=\(type(of: target))")
            UIFocusSystem.focusSystem(for: playerVC.view)?.requestFocusUpdate(to: target)
            self.restoreFocus(to: name, attempt: attempt + 1)
        }
    }

    /// A view's accessibility name: its own label, else its nearest labelled ancestor's below
    /// `root` (AVKit's system buttons carry the label on a wrapper, not on the focusable view).
    private static func labelledName(of view: UIView, below root: UIView) -> String? {
        var candidate: UIView? = view
        while let v = candidate, v !== root {
            if let label = v.accessibilityLabel, !label.isEmpty { return label }
            candidate = v.superview
        }
        return nil
    }

    /// Device r4 (C2): the focusable views whose name is `name`, the same way `barItemName` reads
    /// it (own label or nearest labelled ancestor's), so a name read off a system button finds that
    /// button again. Views whose own label matches come first.
    private static func focusableViews(named name: String, in root: UIView) -> [UIView] {
        var own: [UIView] = []
        var inherited: [UIView] = []
        var stack: [UIView] = [root]
        while let v = stack.popLast() {
            if v.canBecomeFocused, labelledName(of: v, below: root) == name {
                if v.accessibilityLabel == name { own.append(v) } else { inherited.append(v) }
            }
            stack.append(contentsOf: v.subviews)
        }
        return own + inherited
    }

    private static func focusableView(named name: String, in root: UIView) -> UIView? {
        focusableViews(named: name, in: root).first
    }

    /// The transport bar came up. The Sources button is on screen from now on, so the list is
    /// asked for here (a deferred, load-on-open list is not possible in a transport-bar menu) and
    /// is usually in by the time the popover is opened; the menu rebuilds as rows arrive.
    /// Insights review r4 (P2): the engine loads the current episode's list at most once per
    /// playback (`transportBarSourcesShown`), so a pause, seek or Select that raises the bar never
    /// re-scrapes the add-ons, and a next-episode preload is never cleared for it.
    func transportBarShown() {
        guard canSwitchStreams else { return }
        sourcesRequested = true
        engine.transportBarSourcesShown()
        refresh()
    }

    /// The transport bar went away: the list is off screen (the popover closes with the bar). The
    /// list keeps its rows (Insights review r4: no `noteSourceListClosed`, which dropped them and
    /// made the next raise load them again); an idle list hands the stream flow to the FEAT-49
    /// preload by itself when the preload fires.
    func transportBarHidden() {
        if let pending = pendingRefocus {
            print("[NativePlayer] tools: refocus \(pending) gave up (bar hidden)")
        }
        pendingRefocus = nil
        lastBarItemName = nil
        guard canSwitchStreams else { return }
        engine.transportBarSourcesHidden()
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
