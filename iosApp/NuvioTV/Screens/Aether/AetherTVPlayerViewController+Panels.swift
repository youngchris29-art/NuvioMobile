import AVFoundation
import Combine
import NuvioAether
import SharedCore
import UIKit

// Aether Phase 1, W3-A: what the panels read from the Aether session. Track lists, the Info shelf and
// Stream Info rows (from `diagnostics`) and the player badges, published into `MPVPlaybackState` in
// the shapes `MPVPlayerPanelAdapter` already turns into rows.

extension AetherTVPlayerViewController {

    /// `viewDidLoad`: the state closures the panels call.
    func wirePanels() {
        state.onBadgesInPlayerChange = { [weak self] _ in self?.publishBadgeFacts() }
    }

    /// The session publishers the panels follow.
    func wireSessionPanels(_ s: AetherPlaybackSession) {
        Publishers.CombineLatest4(s.$audioTracks, s.$subtitleTracks, s.$activeAudioID, s.$activeSubtitleID)
            .receive(on: RunLoop.main)
            .sink { [weak self] audio, subtitles, activeAudio, activeSubtitle in
                self?.tracksChanged(audio: audio, subtitles: subtitles, activeAudio: activeAudio, activeSubtitle: activeSubtitle)
            }
            .store(in: &bag)
        s.$diagnostics
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.diagnosticsChanged() }
            .store(in: &bag)
    }

    /// `load()` returned the first time.
    func mediaOpened() {
        refreshStreamInfo()
    }

    // MARK: Tracks

    private func tracksChanged(audio: [AetherTrack], subtitles: [AetherTrack], activeAudio: Int?, activeSubtitle: Int?) {
        let audioRows = AetherTrackRows.audio(audio, activeID: activeAudio)
        let subtitleRows = AetherTrackRows.subtitles(subtitles, activeID: activeSubtitle)
        if state.audioTracks != audioRows { state.audioTracks = audioRows }
        if state.subtitleTracks != subtitleRows { state.subtitleTracks = subtitleRows }
        publishBadgeFacts()
    }

    var activeAudioTrack: AetherTrack? {
        guard let session else { return nil }
        return session.audioTracks.first { $0.id == session.activeAudioID }
    }

    // MARK: Info rows and badges

    private func diagnosticsChanged() {
        if let session { subtitleOverlay?.setPresentationSize(session.diagnostics.presentationSize) }
        publishBadgeFacts()
        if state.showStreamInfo || state.transport.openInfoPill == .info { refreshStreamInfo() }
    }

    /// The Info shelf rows and the Stream Info card, from `diagnostics` (equality-gated).
    func refreshStreamInfo() {
        guard let session else { return }
        let ahead = max(0, session.clock.bufferedSec - positionMirror)
        let info = AetherStreamInfo.snapshot(diagnostics: session.diagnostics, routingNote: state.routingNote,
                                             activeAudio: activeAudioTrack, bufferedAheadSec: ahead,
                                             subtitleDelaySec: state.subtitleDelaySec)
        if state.streamInfo != info { state.streamInfo = info }
    }

    /// "Show Badges in Player": the facts from the façade (nothing to read while it is off).
    func publishBadgeFacts() {
        guard state.badgesInPlayer, let session else { return }
        let facts = AetherBadgeFacts.facts(diagnostics: session.diagnostics, activeAudio: activeAudioTrack,
                                           metaCandidates: PlayerBadgeMatch.metaCandidates(context))
        if state.badgeFacts != facts { state.badgeFacts = facts }
    }
}
