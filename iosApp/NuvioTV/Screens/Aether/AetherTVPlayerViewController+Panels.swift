import AVFoundation
import Combine
import NuvioAether
import SharedCore
import UIKit

// Aether Phase 1, W3-A: the panels on the Aether session. Track lists, the Info shelf and Stream Info
// rows (from `diagnostics`) and the player badges are published into `MPVPlaybackState` in the shapes
// `MPVPlayerPanelAdapter` already turns into rows; the panel's picks come back through the same state
// closures the mpv controller sets. Subtitles are drawn by the W3-B overlay: track, mode (the fork's
// forced rule), delay, style and picture size are fed here. Add-on subtitle files go in through
// `addExternalSubtitle` (overlay-only, which is all this route needs).

/// Per-player subtitle and side-load bookkeeping for the panels (main only), owned by the controller.
final class AetherPanelState {
    /// The start plan picked (or turned off) the subtitle track; later walks leave it alone.
    var didAutoSelectSubtitles = false
    /// The viewer picked a subtitle track in the panel; the start plan stops.
    var userSelectedSubtitle = false
    /// The start plan came back forced-only (`SubtitleOverlayMode.resolve`'s `startPlanForcedOnly`).
    var startPlanForcedOnly = false
    /// Add-on files handed to the engine (by URL), and the URL behind each external track id.
    var addedSubtitleURLs = Set<String>()
    var externalSourceByTrackID: [Int: String] = [:]
    var subtitleWatcher: FlowWatcher?
    var subtitleLoadingWatcher: FlowWatcher?
}

extension AetherTVPlayerViewController {

    /// `viewDidLoad`: the state closures the panels call.
    func wirePanels() {
        state.selectAudio = { [weak self] id in self?.selectAudio(id) }
        state.selectSubtitle = { [weak self] id in self?.selectSubtitle(id) }
        state.setSubtitleDelay = { [weak self] seconds in self?.setSubtitleDelay(seconds) }
        state.setAudioDelay = { [weak self] seconds in self?.setAudioDelay(seconds) }
        state.resetAudioDelay = { [weak self] in self?.resetAudioDelay() }
        state.setAudioBoost = { [weak self] db in self?.setAudioBoost(db) }
        state.setAudioMode = { [weak self] mode in self?.setAudioMode(mode) }
        state.onBadgesInPlayerChange = { [weak self] _ in self?.publishBadgeFacts() }
        // The request's sidecars become external tracks `externalTrackIDBase + ordinal` (request order).
        for (ordinal, sub) in context.externalSubtitles.enumerated() {
            panel.externalSourceByTrackID[AetherTrack.externalTrackIDBase + ordinal] = sub.url
            panel.addedSubtitleURLs.insert(sub.url)
        }
        // Per title/episode, per profile (beta.15 §B2): the overlay applies it host-side.
        if let storedMs = PlayerTrackPreferenceStorage.shared.loadSubtitleDelayMs(videoId: context.videoId) {
            setSubtitleDelay(Double(storedMs.intValue) / 1000.0)
        }
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

    /// `load()` returned the first time: remembered speed, the add-on subtitle fetch, the Info rows.
    func mediaOpened() {
        // P5 B23: a remembered speed for this show (series only).
        if context.season != nil || context.episode != nil {
            state.rememberSpeedAvailable = true
            if let saved = PlayerTrackPreferenceStorage.shared.loadPlaybackSpeed(parentMetaId: context.parentMetaId)?.doubleValue {
                state.rememberSpeed = true
                setSpeed(saved)
            }
        }
        startAddonSubtitles()
        refreshStreamInfo()
    }

    func settingsChangedPanels(_ settings: PlayerSettingsUiState) {
        subtitleOverlay?.setStyle(settings.subtitleStyle)
    }

    /// Leaving the player: the add-on watchers stop.
    func teardownPanels() {
        panel.subtitleWatcher?.cancel()
        panel.subtitleWatcher = nil
        panel.subtitleLoadingWatcher?.cancel()
        panel.subtitleLoadingWatcher = nil
    }

    /// The controller goes: the shared add-on list is cleared as the mpv controller's deinit does,
    /// except after a handoff (mpv plays the same title and reads that list).
    func deinitPanels() {
        teardownPanels()
        if !handedOff { SubtitleRepository.shared.clear() }
    }

    // MARK: Tracks

    private func tracksChanged(audio: [AetherTrack], subtitles: [AetherTrack], activeAudio: Int?, activeSubtitle: Int?) {
        let audioRows = AetherTrackRows.audio(audio, activeID: activeAudio)
        let subtitleRows = AetherTrackRows.subtitles(subtitles, activeID: activeSubtitle)
        if state.audioTracks != audioRows { state.audioTracks = audioRows }
        if state.subtitleTracks != subtitleRows { state.subtitleTracks = subtitleRows }
        let source = activeSubtitle.flatMap { panel.externalSourceByTrackID[$0] }
        if state.selectedExternalSubtitleSource != source { state.selectedExternalSubtitleSource = source }
        applySubtitleStartPlanIfNeeded(audio: audio, subtitles: subtitles, activeAudio: activeAudio)
        syncOverlayTrack(subtitles: subtitles, activeSubtitle: activeSubtitle)
        publishBadgeFacts()
    }

    var activeAudioTrack: AetherTrack? {
        guard let session else { return nil }
        return session.audioTracks.first { $0.id == session.activeAudioID }
    }

    private func selectAudio(_ id: Int) {
        guard let session, canTransport else { return }
        print("[AetherPlayer] select audio \(id)")
        session.selectAudio(id: id)
    }

    private func selectSubtitle(_ id: Int) {
        guard let session, canTransport else { return }
        panel.userSelectedSubtitle = true
        panel.didAutoSelectSubtitles = true
        print("[AetherPlayer] select subtitle \(id)")
        if id < 0 {
            session.clearSubtitle()
        } else {
            session.selectSubtitle(id: id)
        }
    }

    /// The overlay follows the engine's active track (the W3-B gate adopts the window the engine
    /// publishes for it), with the fork's forced rule as its mode.
    private func syncOverlayTrack(subtitles: [AetherTrack], activeSubtitle: Int?) {
        guard let overlay = subtitleOverlay else { return }
        let track = activeSubtitle.flatMap { id in subtitles.first { $0.id == id } }
        overlay.setTrack(id: activeSubtitle, isForced: track?.isForced ?? false)
        let settings = playerSettings
        let mode = SubtitleOverlayMode.resolve(primary: settings?.preferredSubtitleLanguage ?? "",
                                               useForcedSubtitles: settings?.subtitleStyle.useForcedSubtitles ?? false,
                                               hasSelectedTrack: activeSubtitle != nil,
                                               userSelectedTrack: panel.userSelectedSubtitle,
                                               startPlanForcedOnly: panel.startPlanForcedOnly)
        overlay.setMode(mode)
    }

    /// The mpv start pick on Aether: the shared audio-aware subtitle plan over the engine's tracks
    /// (`resolveSubtitleAutoSelectionPlan` + `findPreferredSubtitleTrackIndex`, FEAT-84 Off stays Off,
    /// BUG-171 no plan = Off). Decided once a match is found, or once no add-on file is still arriving.
    private func applySubtitleStartPlanIfNeeded(audio: [AetherTrack], subtitles: [AetherTrack], activeAudio: Int?) {
        guard !panel.didAutoSelectSubtitles, !panel.userSelectedSubtitle, mediaReady,
              let session, let settings = playerSettings else { return }
        let arriving = state.subtitleSearchInFlight
        guard !subtitles.isEmpty else {
            if !arriving { panel.didAutoSelectSubtitles = true }
            return
        }
        let device = DeviceLanguagePreferences.shared.preferredLanguageCodes()
        let audioTargets = PlayerLanguagePreferencesKt.resolvePreferredAudioLanguageTargets(
            preferredAudioLanguage: settings.preferredAudioLanguage,
            secondaryPreferredAudioLanguage: settings.secondaryPreferredAudioLanguage,
            deviceLanguages: device,
            contentOriginalLanguage: PlayerAudioLanguagePlan.originalLanguage(for: context))
        let playing = audio.first { $0.id == activeAudio } ?? audio.first
        let effectiveAudio: AudioTrack? = playing.map { t in
            AudioTrack(index: 0, id: String(t.id), label: t.name.isEmpty ? (t.language ?? "") : t.name,
                       language: (t.language?.isEmpty ?? true) ? nil : t.language, isSelected: true)
        }
        let subTargets = AetherSubtitleRouting.preferredTargets(primary: settings.preferredSubtitleLanguage,
                                                                secondary: settings.secondaryPreferredSubtitleLanguage,
                                                                deviceLanguages: device)
        guard let plan = PlayerTrackSelectionKt.resolveSubtitleAutoSelectionPlan(
            selectedAudioTrack: effectiveAudio,
            preferredAudioTargets: audioTargets,
            preferredSubtitleTargets: subTargets,
            useForcedSubtitles: settings.subtitleStyle.useForcedSubtitles)
        else {
            // "Use forced subtitles" on, audio language unknown (BUG-171): subtitles off.
            panel.didAutoSelectSubtitles = true
            print("[AetherPlayer] subtitle plan: none (forced, audio unknown) → off")
            if session.activeSubtitleID != nil { session.clearSubtitle() }
            return
        }
        panel.startPlanForcedOnly = plan.mode == .forcedOnly
        let shared = subtitles.enumerated().map { index, t in
            SubtitleTrack(index: Int32(index), id: String(t.id), label: t.name.isEmpty ? (t.language ?? "") : t.name,
                          language: (t.language?.isEmpty ?? true) ? nil : t.language,
                          isSelected: t.id == session.activeSubtitleID, isForced: t.isForced)
        }
        let match = PlayerTrackSelectionKt.findPreferredSubtitleTrackIndex(
            tracks: shared, targets: plan.targets, mode: plan.mode, selectedAudioTrack: effectiveAudio)
        if match >= 0, Int(match) < subtitles.count {
            panel.didAutoSelectSubtitles = true
            let id = subtitles[Int(match)].id
            print("[AetherPlayer] subtitle plan: \(plan.mode) → track \(id)")
            if session.activeSubtitleID != id { session.selectSubtitle(id: id) }
        } else if !arriving {
            panel.didAutoSelectSubtitles = true
            print("[AetherPlayer] subtitle plan: \(plan.mode), no match → off")
            if session.activeSubtitleID != nil { session.clearSubtitle() }
        }
    }

    // MARK: Add-on subtitles

    private func startAddonSubtitles() {
        guard panel.subtitleWatcher == nil else { return }
        panel.subtitleWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.addonSubtitles) { [weak self] emitted in
            guard let subs = emitted as? [AddonSubtitle] else { return }
            DispatchQueue.main.async { self?.addAddonSubtitles(subs) }
        }
        panel.subtitleLoadingWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.isLoading) { [weak self] emitted in
            guard let loading = (emitted as? NSNumber)?.boolValue else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let ended = self.state.subtitleSearchInFlight && !loading
                self.state.subtitleSearchInFlight = loading
                // A start pick that waited on the search is decided now.
                if ended, let session = self.session {
                    self.tracksChanged(audio: session.audioTracks, subtitles: session.subtitleTracks,
                                       activeAudio: session.activeAudioID, activeSubtitle: session.activeSubtitleID)
                }
            }
        }
        SubtitleRepository.shared.fetchAddonSubtitles(type: context.contentType, videoId: context.videoId)
        // A stream-picker prefetch may already have completed (the fetch then no-ops): side-load it,
        // never a lingering list that belongs to another title.
        if (SubtitleRepository.shared.completedRequest.value_ as? String)
            == SubtitleRepository.shared.requestKey(type: context.contentType, videoId: context.videoId),
           let prefetched = SubtitleRepository.shared.addonSubtitles.value_ as? [AddonSubtitle], !prefetched.isEmpty {
            addAddonSubtitles(prefetched)
        }
    }

    /// Add-on files through `addExternalSubtitle`, "Show only preferred languages" applied, preferred
    /// languages first. A stream whose headers carry credentials never forwards them to a subtitle host.
    private func addAddonSubtitles(_ subs: [AddonSubtitle]) {
        guard mediaReady, let session, canTransport else { return }
        let kept = playerSettings.map {
            PlayerTrackSelectionKt.filterAddonSubtitlesForSettings(subtitles: subs, settings: $0)
        } ?? subs
        let targets = playerSettings.map { PlayerTrackSelectionKt.preferredSubtitleTargetsForSettings(settings: $0) } ?? []
        let rank: (AddonSubtitle) -> Int = { sub in
            targets.firstIndex { SubtitleLanguageMatching.shared.matchesLanguageCode(language: sub.language, target: $0) }
                ?? Int.max
        }
        let credentialed = context.requestHeaders.keys.contains {
            ["authorization", "cookie", "proxy-authorization"].contains($0.lowercased())
        }
        var added = 0
        for sub in kept.sorted(by: { rank($0) < rank($1) }) where !panel.addedSubtitleURLs.contains(sub.url) {
            guard let url = URL(string: sub.url) else { continue }
            panel.addedSubtitleURLs.insert(sub.url)
            let external = AetherExternalSubtitle(url: url, name: sub.display, language: sub.language,
                                                  httpHeaders: credentialed ? [:] : nil)
            if let track = session.addExternalSubtitle(external) {
                panel.externalSourceByTrackID[track.id] = sub.url
                added += 1
            }
        }
        if added > 0 { print("[AetherPlayer] add-on subtitles added=\(added) total=\(panel.addedSubtitleURLs.count)") }
    }

    // MARK: Timing

    /// Host-side (the overlay draws `sourceSec - delay`); same persistence key and range as mpv.
    private func setSubtitleDelay(_ seconds: Double) {
        let value = seconds.isFinite ? seconds : 0
        subtitleOverlay?.setDelay(value)
        state.subtitleDelaySec = value
        PlayerTrackPreferenceStorage.shared.saveSubtitleDelayMs(videoId: context.videoId,
                                                                delayMs: Int32((value * 1000).rounded()))
    }

    /// P5 N1 on Aether: the user's new total, inside the engine's +/-2 s.
    private func setAudioDelay(_ seconds: Double) {
        guard let session else { return }
        let wanted = AetherAudioDelayPlan.clamped(seconds)
        audioDelayParts = StreamAudioDelay.shared.applyUserTotal(parts: audioDelayParts,
                                                                 newTotalMs: Int32((wanted * 1000).rounded()))
        let total = AetherAudioDelayPlan.clamped(Double(StreamAudioDelay.shared.totalMs(parts: audioDelayParts)) / 1000.0)
        session.setAudioDelay(total)
        state.audioDelaySec = total
        state.audioDelayLimitSec = AetherAudioDelayPlan.uiLimitSec(
            sharedLimitSec: Double(StreamAudioDelay.shared.uiLimitMs(parts: audioDelayParts)) / 1000.0)
        if let persist = StreamAudioDelay.shared.persistableMs(parts: audioDelayParts) {
            PlayerTrackPreferenceStorage.shared.saveAudioDelayMs(videoId: context.videoId, delayMs: persist.int32Value)
        }
    }

    /// With a stream hint active, Reset returns to the hint; without one it sets 0 (the mpv rule).
    private func resetAudioDelay() {
        guard let session else { return }
        guard let hint = audioDelayParts.streamMs else {
            if StreamAudioDelay.shared.totalMs(parts: audioDelayParts) != 0 { setAudioDelay(0) }
            return
        }
        audioDelayParts = AudioDelayParts(savedMs: audioDelayParts.savedMs, streamMs: hint, sessionAdjustMs: 0)
        let total = AetherAudioDelayPlan.clamped(Double(StreamAudioDelay.shared.totalMs(parts: audioDelayParts)) / 1000.0)
        session.setAudioDelay(total)
        state.audioDelaySec = total
    }

    // MARK: Audio effects (Boost and Dialogue → `AetherAudioShaping`)

    private func setAudioBoost(_ db: Int) {
        let boost = PlayerAudioEffects.clampBoost(db)
        UserDefaults.standard.set(boost, forKey: PlayerTuning.boostDbKey)
        state.audioEffects.boostDb = boost
        applyShaping()
    }

    private func setAudioMode(_ mode: PlayerAudioMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: PlayerTuning.audioModeKey)
        state.audioEffects.mode = mode
        applyShaping()
    }

    /// Each change is a session-preserving reload; any active shaping turns stream copy off.
    private func applyShaping() {
        guard let session else { return }
        let shaping = AetherShapingPlan.shaping(boostDb: state.audioEffects.boostDb, mode: state.audioEffects.mode)
        guard shaping != session.audioShaping else { return }
        print("[AudioFx] aether dialogue=\(shaping.dialogueLiftDB) dB boost=\(shaping.boostDB) dB")
        session.setAudioShaping(shaping)
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
