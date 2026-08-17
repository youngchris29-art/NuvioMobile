import AVFoundation
import Combine
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

    init(state: MPVPlaybackState, model: PlayerTopPanelModel, context: PlaybackContext) {
        self.state = state
        self.model = model
        self.context = context

        model.onSelectSubtitle = { [weak state] option in
            state?.selectSubtitle?(option.flatMap { Int($0.id) } ?? -1)
        }
        model.onSelectAudio = { [weak state] option in
            if let id = Int(option.id) { state?.selectAudio?(id) }
        }

        Publishers.Merge3(
            state.$audioTracks.map { _ in () }.eraseToAnyPublisher(),
            state.$subtitleTracks.map { _ in () }.eraseToAnyPublisher(),
            state.$subtitleSearchInFlight.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildSelections() }
        .store(in: &cancellables)

        Publishers.Merge3(
            state.$streamInfo.map { _ in () }.eraseToAnyPublisher(),
            state.$durationSec.map { _ in () }.eraseToAnyPublisher(),
            state.$routingNote.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildInfo() }
        .store(in: &cancellables)

        rebuildSelections()
        rebuildInfo()
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

    private func rebuildSelections() {
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

    private func rebuildInfo() {
        var rows: [NativeInfoRow] = []
        if let info = state.streamInfo {
            rows = info.rows.map { NativeInfoRow(label: $0.0, value: $0.1) }
        }
        if !rows.contains(where: { $0.label == String(localized: "Engine") }) {
            rows.insert(NativeInfoRow(label: String(localized: "Engine"),
                                      value: state.routingNote.isEmpty ? "mpv" : state.routingNote), at: 0)
        }
        if model.info.rows != rows { model.info.rows = rows }

        var chips: [PlayerPanelChip] = []
        if let year = context.meta?.year { chips.append(PlayerPanelChip(text: year)) }
        if let rating = context.meta?.imdbRating { chips.append(PlayerPanelChip(text: rating, symbol: "star.fill")) }
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

    private static func runtimeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? String(localized: "\(h) h \(m) min") : String(localized: "\(m) min")
    }
}
