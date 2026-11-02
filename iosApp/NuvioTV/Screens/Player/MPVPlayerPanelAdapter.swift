import AVFoundation
import Combine
import SharedCore
import SwiftUI

/// Feeds the shared top panel from the mpv player: `MPVPlaybackState.audioTracks/subtitleTracks`
/// (mpv track ids; -1 = subtitles Off) → checkmark rows, the libmpv diagnostics snapshot → Info
/// rows/chips, AVAudioSession → output route name. Picks go back through the state's
/// `selectAudio/selectSubtitle` closures, exactly like the old swipe-up picker did.
@MainActor
final class MPVPlayerPanelAdapter {
    private let state: MPVPlaybackState
    private let model: PlayerTopPanelModel
    private let context: PlaybackContext
    private var cancellables: Set<AnyCancellable> = []
    private var routeObserver: NSObjectProtocol?
    /// The Cast pill's loader (Insights). Retained here: the model only holds it weakly.
    private var insights: PlayerInsightsLoader?

    init(state: MPVPlaybackState, model: PlayerTopPanelModel, context: PlaybackContext) {
        self.state = state
        self.model = model
        self.context = context
        // Cast pill: credits for what is playing, keyed on the title (never the stream).
        insights = PlayerInsightsLoader.attach(model: model, context: context)

        model.onSelectSubtitle = { [weak state] option in
            state?.selectSubtitle?(option.flatMap { Int($0.id) } ?? -1)
        }
        model.onSelectAudio = { [weak state] option in
            if let id = Int(option.id) { state?.selectAudio?(id) }
        }
        // mpv can always re-time subtitles (`sub-delay`); the native AVPlayer adapter leaves
        // `supportsSubtitleDelay` false until beta.15 §B3 lands a delay mechanism there.
        model.supportsSubtitleDelay = true
        model.subtitleDelayMs = Self.ms(fromSeconds: state.subtitleDelaySec)
        model.onSubtitleDelayChange = { [weak state] ms in
            state?.setSubtitleDelay?(Double(ms) / 1000.0)
        }
        // Sync Line (P5 B19): position captured at press time; cues from mpv's own external source.
        model.syncLineCapturePositionMs = { [weak state] in state?.captureSyncPositionMs?() ?? 0 }
        model.syncLineCues = { [weak state] in
            let (source, strip) = await MainActor.run { (state?.selectedExternalSubtitleSource, state?.syncLineStripSdh?() ?? false) }
            return await SyncLineCueLoader.load(source: source, stripSdh: strip)
        }

        Publishers.Merge4(
            state.$audioTracks.map { _ in () }.eraseToAnyPublisher(),
            state.$subtitleTracks.map { _ in () }.eraseToAnyPublisher(),
            state.$subtitleSearchInFlight.map { _ in () }.eraseToAnyPublisher(),
            state.$selectedExternalSubtitleSource.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildSelections() }
        .store(in: &cancellables)

        // Reflects the controller's applied delay back into the panel — covers both the
        // persisted-value-on-load case (controller sets it before the panel is ever opened) and
        // any future non-panel path that changes it.
        state.$subtitleDelaySec
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds in
                guard let self else { return }
                let ms = Self.ms(fromSeconds: seconds)
                if self.model.subtitleDelayMs != ms { self.model.subtitleDelayMs = ms }
            }
            .store(in: &cancellables)

        Publishers.Merge4(
            state.$streamInfo.map { _ in () }.eraseToAnyPublisher(),
            state.$durationSec.map { _ in () }.eraseToAnyPublisher(),
            state.$routingNote.map { _ in () }.eraseToAnyPublisher(),
            state.$previewStoreSummary.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildInfo() }
        .store(in: &cancellables)

        // Chapters tab (P2-C): rebuilt when the list arrives and on every panel open (the current
        // chapter follows the playhead). Select seeks and closes the panel.
        model.onSelectChapter = { [weak state, weak model] chapter in
            state?.seekToChapter?(chapter.sec)
            model?.onClose?()
        }
        Publishers.Merge(
            state.transport.$chapters.map { _ in () }.eraseToAnyPublisher(),
            state.$panelOpen.removeDuplicates().filter { $0 }.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildChapters() }
        .store(in: &cancellables)

        // mpv audio effects (P5 B20): the native adapter never sets `audioEffects`, so its Audio
        // tab hides the rows.
        model.audioEffects = state.audioEffects
        state.$audioEffects
            .receive(on: RunLoop.main)
            .sink { [weak self] fx in
                guard let self, self.model.audioEffects != fx else { return }
                self.model.audioEffects = fx
            }
            .store(in: &cancellables)
        model.onAudioBoostChange = { [weak state] db in state?.setAudioBoost?(db) }
        model.onAudioModeChange = { [weak state] mode in state?.setAudioMode?(mode) }

        // Player badges (upstream 344117e73): the controller publishes the facts from its track-list
        // walk and again on an audio-track or video-params change, never per tick. It reads them only
        // while "Show Badges in Player" is on.
        model.onBadgesShowInPlayerChange = { [weak state] on in state?.badgesInPlayer = on }
        model.watchBadgeSettings()
        state.badgesInPlayer = model.badgesShowInPlayer
        state.$badgeFacts
            .receive(on: RunLoop.main)
            .sink { [weak model] facts in model?.setBadgeFacts(facts) }
            .store(in: &cancellables)

        // Insights (2026-11-01): the popovers and shelves read this model; "close" means close the
        // open popover or shelf (a chapter seek, an episode jump, Play Now).
        state.panelModel = model
        model.onClose = { [weak state] in state?.closeOverlay?() }
        // The text pill row follows the model (Cast once someone is known, Chapters once the list
        // lands, Up Next while there is a next episode). On the next main turn: `@Published`
        // emits before the value is stored.
        Publishers.Merge4(
            model.$people.map { _ in () }.eraseToAnyPublisher(),
            model.$castEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$chapters.map { _ in () }.eraseToAnyPublisher(),
            model.$upNext.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildInfoPills() }
        .store(in: &cancellables)

        rebuildSelections()
        rebuildInfo()
        rebuildInfoPills()
        refreshRoute()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRoute() }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    /// The Up Next pill from the screen's `NextEpisodeEngine`: the next episode's title, S/E and
    /// still; Play plays the ready stream when the countdown card has one, else jumps to it (search,
    /// then play, as the Episodes list does).
    func attachUpNext(engine: NextEpisodeEngine) {
        engine.$upNextEpisode
            .receive(on: RunLoop.main)
            .sink { [weak model] episode in
                guard let model else { return }
                let card = episode.map(Self.upNextCard(_:))
                if model.upNext != card { model.upNext = card }
            }
            .store(in: &cancellables)
        model.onPlayUpNext = { [weak engine, weak model] in
            guard let engine, let next = engine.upNextEpisode else { return }
            if !engine.playNow() { engine.jumpToEpisode(next) }
            model?.onClose?()
        }
    }

    static func upNextCard(_ episode: MetaVideo) -> PlayerPanelUpNext {
        let subtitle: String?
        if let s = episode.season?.intValue, let e = episode.episode?.intValue {
            subtitle = "S\(s) · E\(e)"
        } else {
            subtitle = nil
        }
        return PlayerPanelUpNext(title: episode.title, subtitle: subtitle,
                                 still: episode.thumbnail.flatMap { URL(string: $0) })
    }

    private func rebuildInfoPills() {
        let t = state.transport
        let pills = PlayerInfoPill.visible(for: model)
        guard pills != t.infoPills else { return }
        let fixed = PlayerInfoPill.reconcile(focused: t.focusedInfoPill, open: t.openInfoPill,
                                             old: t.infoPills, new: pills)
        t.infoPills = pills
        // Close first: closing hands the focus back to the open pill, which may be the one gone.
        if t.openInfoPill != nil, fixed.open == nil { state.closeOverlay?() }
        if t.focusedInfoPill != fixed.focused { t.focusedInfoPill = fixed.focused }
    }

    private func rebuildSelections() {
        let hasExternal = state.selectedExternalSubtitleSource != nil
        if model.syncLineAvailable != hasExternal { model.syncLineAvailable = hasExternal }
        // mpv's subtitle list already carries an "Off" entry (id -1) when there is anything to
        // pick; the panel puts Off first regardless of the engine's ordering.
        var subtitles: [PlayerPanelOption] = []
        let tracks = state.subtitleTracks
        if !tracks.isEmpty {
            let off = tracks.first { $0.id == -1 }
            subtitles.append(PlayerPanelOption(id: "off", title: String(localized: "Off"), group: .off,
                                               isSelected: off?.isSelected ?? !tracks.contains { $0.isSelected }))
            for track in tracks where track.id != -1 {
                subtitles.append(PlayerPanelOption(id: String(track.id), title: track.label,
                                                   group: .embedded, isSelected: track.isSelected))
            }
        }
        if model.subtitles != subtitles { model.subtitles = subtitles }
        if model.subtitlesSearching != state.subtitleSearchInFlight { model.subtitlesSearching = state.subtitleSearchInFlight }

        let audio = state.audioTracks.map {
            PlayerPanelOption(id: String($0.id), title: $0.label, group: .audio, isSelected: $0.isSelected)
        }
        if model.audio != audio { model.audio = audio }
    }

    private func rebuildChapters() {
        let list = state.transport.chapters
        let current = PlayerChapters.index(at: state.positionSec, in: list)
        let rows = list.enumerated().map { i, c in
            PlayerPanelChapter(id: i, title: PlayerChapters.displayTitle(c, index: i), sec: c.sec, isCurrent: i == current)
        }
        if model.chapters != rows { model.chapters = rows }
    }

    private func rebuildInfo() {
        var rows: [NativeInfoRow] = []
        if let info = state.streamInfo {
            rows = info.rows.map { NativeInfoRow(label: $0.0, value: $0.1) }
        }
        if !rows.contains(where: { $0.label == String(localized: "Engine") }) {
            rows.insert(NativeInfoRow(label: String(localized: "Engine"),
                                      value: state.routingNote.isEmpty ? "mpv" : state.routingNote), at: 0)
        }
        if !state.previewStoreSummary.isEmpty {
            rows.append(NativeInfoRow(label: String(localized: "Seek Previews"), value: state.previewStoreSummary))
        }
        if model.info.rows != rows { model.info.rows = rows }

        var chips: [PlayerPanelChip] = []
        if let year = context.meta?.year { chips.append(PlayerPanelChip(text: year)) }
        if let rating = context.meta?.imdbRating { chips.append(PlayerPanelChip(text: RatingFormat.oneDecimal(rating), symbol: "star.fill")) }
        if let age = context.meta?.ageRating { chips.append(PlayerPanelChip(text: age)) }
        if state.durationSec > 0 {
            chips.append(PlayerPanelChip(text: Self.runtimeString(state.durationSec), isRuntime: true))
        } else if let runtime = context.meta?.runtime {
            chips.append(PlayerPanelChip(text: runtime, isRuntime: true))
        }
        if let info = state.streamInfo {
            if !info.resolution.isEmpty { chips.append(PlayerPanelChip(text: info.resolution)) }
            // mpv's codec string is verbose ("H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10"); chip = first name.
            if let codec = info.videoCodec.components(separatedBy: " / ").first, !codec.isEmpty {
                chips.append(PlayerPanelChip(text: codec))
            }
            if !info.fps.isEmpty { chips.append(PlayerPanelChip(text: info.fps)) }
            if !info.audio.isEmpty { chips.append(PlayerPanelChip(text: info.audio)) }
            if !info.videoBitrate.isEmpty { chips.append(PlayerPanelChip(text: info.videoBitrate)) }
        }
        if let bytes = context.fileSizeBytes, bytes > 0 {
            chips.append(PlayerPanelChip(text: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        if let genres = context.meta?.genres, !genres.isEmpty {
            chips.append(PlayerPanelChip(text: genres.prefix(3).joined(separator: ", ")))
        }
        // Dedupe by text — chip ids are their text.
        var seen = Set<String>()
        chips = chips.filter { seen.insert($0.text).inserted }
        if model.info.chips != chips { model.info.chips = chips }
    }

    private func refreshRoute() {
        let names = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).filter { !$0.isEmpty }
        let name = names.isEmpty ? "Apple TV" : names.joined(separator: ", ")
        if model.outputRouteName != name { model.outputRouteName = name }
    }

    private static func ms(fromSeconds seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    private static func runtimeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? String(localized: "\(h) h \(m) min") : String(localized: "\(m) min")
    }
}
