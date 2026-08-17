import AVFoundation
import Combine
import Foundation
import SharedCore

// Phase 3 of the hybrid player: ties Phase 2's remux + loopback server to an AVPlayer for one
// PlaybackContext. Starts the remux, begins playback progressively as soon as the first segment is
// available (rather than waiting for the whole file), and owns the AVPlayer lifecycle — resume seek,
// periodic watch-progress save, and Trakt scrobbling via the shared PlaybackProgressRecorder.
// See docs/tvos-hybrid-player-plan.md.

/// One entry of the native player's Audio menu (D4): a source audio track with a 10-foot display
/// name. `streamIndex` is the avformat stream index handed back to the rebuilt RemuxSession when the
/// user picks this track.
struct NativeAudioTrack: Identifiable, Equatable {
    let streamIndex: Int
    let name: String
    let playable: Bool
    let selected: Bool
    var id: Int { streamIndex }
}

@MainActor
final class NativePlaybackCoordinator: ObservableObject {
    enum Phase: Equatable {
        case preparing            // remux spinning up / waiting for the first segment
        case playing
        case failed(String)       // pre-playback failure → dispatcher falls back to mpv
    }

    @Published private(set) var phase: Phase = .preparing
    /// Source audio tracks for the player's Audio menu (D4) — populated once the remux inspects the
    /// streams, emptied during an audio-switch rebuild.
    @Published private(set) var audioTracks: [NativeAudioTrack] = []
    /// Caption under the preparing spinner — first spin-up vs an audio-switch rebuild.
    @Published private(set) var preparingLabel = String(localized: "Preparing Dolby Vision\u{2026}")
    private(set) var player: AVPlayer?

    /// Fired ~every few seconds with (position, duration) while playing — the screen forwards it to
    /// the next-episode engine.
    var onTick: ((Double, Double) -> Void)?

    /// Last observed position/duration, used when falling back to mpv.
    private(set) var lastPositionSec: Double = 0
    private var lastDurationSec: Double = 0

    private let context: PlaybackContext
    private let recorder: PlaybackProgressRecorder
    private var remux: RemuxSession?
    private var server: LocalHLSServer?
    private var playerItem: AVPlayerItem?
    private var pollTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var servedURL: URL?
    /// 0 = full signaling (RFC 6381 + DV supplemental + range); 1 = minimal (bare sample-entry tag).
    /// A strict AVPlayer that rejects the full form at the master stage gets one retry at minimal.
    private var signalingAttempt = 0
    /// Resume target for the next readyToPlay — set by an audio-switch rebuild so playback continues
    /// where it was; takes precedence over the saved watch progress.
    private var pendingResumeSec: Double?
    /// Subtitle selection carried across an audio-switch rebuild (media selection dies with the item).
    private var pendingSubtitleName: String?
    /// The viewer had subtitles OFF when the rebuild started — re-assert Off after the new item's
    /// legible group loads, otherwise the language criteria would auto-enable them again.
    private var pendingSubtitleOff = false

    /// Language preferences (Settings → Playback → Preferred Audio/Subtitle Language + the
    /// forced/only-preferred subtitle options), resolved through the shared KMP helpers so the
    /// native and mpv engines agree. Drives AVPlayer's media-selection criteria, the master's
    /// AUTOSELECT/DEFAULT flags, and the panel's `allowedSubtitleOptionLanguages`.
    struct LanguagePlan: Equatable {
        var audioTargets: [String] = []
        var subtitleTargets: [String] = []
        /// The full preferred-subtitle list (primary + secondary + device), before the shared
        /// plan narrows it for forced-only auto-selection — this is what "Show only preferred
        /// languages" filters the panel's Subtitles list by.
        var subtitleFilterLanguages: [String] = []
        /// Preferred Subtitle Language is "none": never auto-enable subtitles.
        var subtitlesOff = false
        /// Shared plan says forced-only (audio already in a preferred language + "Use forced subtitles").
        var forcedOnly = false
        /// "Use forced subtitles" is on but the audio language is unknown: the shared plan returns
        /// nil to leave player defaults untouched (mpv parity) — no DEFAULT rendition, no legible
        /// criteria; the system's own behaviour + the user decide.
        var leaveToPlayer = false
        /// "Show only preferred languages" — restrict the panel's Subtitles list.
        var onlyPreferredLanguages = false
    }
    @Published private(set) var languagePlan = LanguagePlan()
    /// Shared player settings snapshot behind the plan (also drives the addon-subtitle startup mode).
    private var playerSettings: PlayerSettingsUiState?
    /// The current item's legible selection group, cached async after readyToPlay so the switch
    /// teardown can capture the active subtitle synchronously.
    private var legibleGroup: AVMediaSelectionGroup?
    /// Trakt scrobble sessions span audio-switch rebuilds — start once, stop once.
    private var traktStarted = false
    /// Subtitles fetched from installed subtitle addons (OpenSubtitles etc.) — the same source the
    /// mpv player side-loads. Fetched at start(); playback start is gated (briefly, capped) on the
    /// fetch completing, because the VOD master is rendered exactly once — renditions that arrive
    /// after it are invisible to AVPlayer. Streams rarely attach their own subtitles.
    private var addonSubtitles: [SubtitleFile] = []
    private var addonSubsWatcher: FlowWatcher?
    /// Fetch lifecycle: done when the repo's `completedRequest` state matches this content's
    /// request key (state, not an edge — a fetch that finished before we looked, or was
    /// deduplicated against the stream picker's prefetch, still reads as complete), or when a
    /// non-empty list arrives (results and completion are equivalent for gating).
    private var subsFetchDone = false
    private var subsRequestKey = ""
    /// Embedded text tracks offered as renditions this session (Info tab row).
    private var embeddedSubtitleCount = 0

    init(context: PlaybackContext) {
        self.context = context
        self.recorder = PlaybackProgressRecorder(context: context)
    }

    // MARK: - Lifecycle

    func start() {
        guard remux == nil else { return }
        // Addon-subtitle results. The completion signal is polled from `completedRequest` in
        // pollForFirstSegment — no watcher races; this watcher only mirrors the list (its
        // StateFlow replay also delivers results prefetched before this coordinator existed).
        // Settings first: the addon-subtitle watcher below filters by them.
        resolveLanguagePlan(selectedAudioLanguage: nil)
        subsRequestKey = SubtitleRepository.shared.requestKey(type: context.contentType, videoId: context.videoId)
        addonSubsWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.addonSubtitles) { [weak self] emitted in
            guard let subs = emitted as? [AddonSubtitle] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // "Only preferred languages" / PREFERRED_ONLY startup mode (shared settings, the
                // latter cloud-synced from mobile): drop non-preferred renditions at the source with
                // the same shared filter the mobile runtime and the mpv screen apply. (FAST_STARTUP
                // is deliberately NOT honoured on tvOS — there is no manual subtitle search here, so
                // skipping the automatic fetch would mean no addon subtitles at all.)
                let kept = self.playerSettings.map {
                    PlayerTrackSelectionKt.filterAddonSubtitlesForSettings(subtitles: subs, settings: $0)
                } ?? subs
                self.addonSubtitles = kept.map {
                    SubtitleFile(url: $0.url, language: $0.language, name: $0.display)
                }
                if !subs.isEmpty {
                    self.subsFetchDone = true
                    print("[NativePlayer] addon subtitles arrived: \(subs.count)\(self.server == nil ? "" : " (after master — too late this session)")")
                }
            }
        }
        SubtitleRepository.shared.fetchAddonSubtitles(type: context.contentType, videoId: context.videoId)
        launchRemux(audioStreamIndex: nil)
    }

    /// Resolve the language plan from the shared player settings (same helpers + semantics as the
    /// mpv screen's `autoSelectPreferredTracks`). Called at start (audio unknown) and again once
    /// the remux has picked the audio track, because the forced-only decision depends on it.
    private func resolveLanguagePlan(selectedAudioLanguage: String?) {
        PlayerSettingsRepository.shared.ensureLoaded()
        guard let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState else { return }
        playerSettings = settings
        let deviceLanguages = DeviceLanguagePreferences.shared.preferredLanguageCodes()
        let audioTargets = PlayerLanguagePreferencesKt.resolvePreferredAudioLanguageTargets(
            preferredAudioLanguage: settings.preferredAudioLanguage,
            secondaryPreferredAudioLanguage: settings.secondaryPreferredAudioLanguage,
            deviceLanguages: deviceLanguages,
            contentOriginalLanguage: nil
        )
        let subTargets = PlayerLanguagePreferencesKt.resolvePreferredSubtitleLanguageTargets(
            preferredSubtitleLanguage: settings.preferredSubtitleLanguage,
            secondaryPreferredSubtitleLanguage: settings.secondaryPreferredSubtitleLanguage,
            deviceLanguages: deviceLanguages
        )
        var plan = LanguagePlan()
        plan.audioTargets = audioTargets
        plan.subtitleFilterLanguages = subTargets
        plan.onlyPreferredLanguages = settings.subtitleStyle.showOnlyPreferredLanguages
        // Always consult the shared plan: even with no subtitle targets (primary "none", no
        // secondary) it can yield a forced-only plan in the audio's language when "Use forced
        // subtitles" is on and the audio matches a preferred audio language (mpv parity).
        if let shared = PlayerTrackSelectionKt.resolveSubtitleAutoSelectionPlan(
            selectedAudioLanguage: selectedAudioLanguage,
            preferredAudioTargets: audioTargets,
            preferredSubtitleTargets: subTargets,
            useForcedSubtitles: settings.subtitleStyle.useForcedSubtitles
        ) {
            plan.subtitleTargets = shared.targets
            plan.forcedOnly = shared.mode == .forcedOnly
            plan.subtitlesOff = shared.targets.isEmpty   // nothing to auto-select → never auto-enable
        } else {
            // Forced on but audio language unknown: leave player defaults untouched (mpv parity).
            plan.leaveToPlayer = true
            plan.subtitleTargets = subTargets
        }
        if plan != languagePlan {
            languagePlan = plan
            print("[NativePlayer] language plan: audio=\(plan.audioTargets) subs=\(plan.subtitlesOff ? "off" : plan.subtitleTargets.description)"
                  + (plan.forcedOnly ? " forced-only" : "") + (plan.leaveToPlayer ? " player-default" : "")
                  + (plan.onlyPreferredLanguages ? " only-preferred" : ""))
        }
    }

    /// Install the plan on a player: AVPlayer applies these when the item's selection groups load
    /// (and again after an audio-switch rebuild). Empty preferred languages fall back to the
    /// system's own behaviour, so "subtitles off" is additionally enforced by the master's
    /// AUTOSELECT=NO flags (see `subtitleAutoselect`).
    private func applyLanguagePlan(to player: AVPlayer) {
        let plan = languagePlan
        if !plan.audioTargets.isEmpty {
            player.setMediaSelectionCriteria(
                AVPlayerMediaSelectionCriteria(preferredLanguages: plan.audioTargets, preferredMediaCharacteristics: nil),
                forMediaCharacteristic: .audible)
        }
        if plan.subtitlesOff || plan.leaveToPlayer {
            player.setMediaSelectionCriteria(nil, forMediaCharacteristic: .legible)
        } else {
            player.setMediaSelectionCriteria(
                AVPlayerMediaSelectionCriteria(
                    preferredLanguages: plan.subtitleTargets,
                    preferredMediaCharacteristics: plan.forcedOnly ? [.containsOnlyForcedSubtitles] : nil),
                forMediaCharacteristic: .legible)
        }
    }

    /// AUTOSELECT/DEFAULT decision for one subtitle rendition (master playlist flags).
    /// - subtitles off → nothing auto-selectable, so neither the system's accessibility prefs nor
    ///   AVPlayer's defaults can switch captions on;
    /// - otherwise renditions in a preferred language are AUTOSELECT=YES and the first match is
    ///   DEFAULT=YES (mpv parity: preferred subtitles start on), the rest AUTOSELECT=NO.
    private func subtitleFlags(for renditions: [SubtitleRendition]) -> [SubtitleRenditionFlags] {
        let plan = languagePlan
        // No DEFAULT when forced-only (addon subs carry no forced flag) or when the shared plan
        // deferred to player defaults; matches stay AUTOSELECT so the system may still pick them.
        var defaultTaken = plan.leaveToPlayer
        return renditions.map { rendition in
            // FORCED renditions are always auto-selectable: HLS requires AUTOSELECT=YES with
            // FORCED=YES (an invalid master is an admission failure), and forced tracks — foreign
            // dialogue / signs — are meant to show per the player's own rules even when the viewer
            // has no subtitle language preference (standard forced-subtitle behaviour). Never DEFAULT
            // outside a forced-only plan.
            guard !plan.subtitlesOff else { return SubtitleRenditionFlags(autoselect: rendition.forced, isDefault: false) }
            // Deferred to player defaults: every rendition stays auto-selectable, none is DEFAULT.
            guard !plan.leaveToPlayer else { return .legacy }
            let matches = plan.subtitleTargets.contains { target in
                PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: rendition.language ?? "", targetLanguage: target)
            }
            // Forced-only plan: only a FORCED rendition in the target language may start on
            // (embedded tracks carry the flag; addon files never do). Normal plan: only FULL
            // renditions — a forced (signs/foreign-dialogue-only) track must not win DEFAULT just
            // because it's listed first.
            let eligible = plan.forcedOnly ? rendition.forced : !rendition.forced
            let isDefault = matches && eligible && !defaultTaken
            if isDefault { defaultTaken = true }
            // Forced renditions stay auto-selectable (the player applies them per its own rules)
            // whenever subtitles aren't off outright.
            return SubtitleRenditionFlags(autoselect: matches || rendition.forced, isDefault: isDefault)
        }
    }

    /// True once the repo has completed the fetch for THIS content (deduplicated prefetches
    /// included). Read on the poll cadence; sticky via `subsFetchDone`.
    private func subsFetchCompleted() -> Bool {
        if subsFetchDone { return true }
        if (SubtitleRepository.shared.completedRequest.value_ as? String) == subsRequestKey {
            subsFetchDone = true
            print("[NativePlayer] addon subtitle fetch finished (\(addonSubtitles.count) found)")
            return true
        }
        return false
    }

    /// First playable track whose language matches the highest-priority target with any hit
    /// (same rule as the mpv screen's `firstTrackId(matching:)`). Pure — runs on the remux worker.
    nonisolated private static func preferredAudioStream(in tracks: [RemuxAudioTrack], targets: [String]) -> Int? {
        for target in targets {
            for track in tracks where track.playable {
                if PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: track.language ?? "",
                                                                          targetLanguage: target) {
                    return track.streamIndex
                }
            }
        }
        return nil
    }

    /// Spin up a remux session and the first-segment poll — the shared tail of `start()` and an
    /// audio-switch rebuild.
    private func launchRemux(audioStreamIndex: Int?) {
        // Initial session: let the worker pick the first playable track in a preferred language
        // (Settings → Playback → Preferred Audio Language) — the muxed stream carries exactly one
        // audio rendition, so AVPlayer's own audible criteria can't fix a wrong first pick.
        let audioTargets = languagePlan.audioTargets
        var config = RemuxSession.Config(url: context.url, segmentDurationSec: 6, audioStreamIndex: audioStreamIndex)
        if audioStreamIndex == nil, !audioTargets.isEmpty {
            config.preferredAudioPicker = { tracks in Self.preferredAudioStream(in: tracks, targets: audioTargets) }
        }
        let remux = RemuxSession(config: config)
        self.remux = remux
        remux.start { state in
            guard case .failed(let stage) = state else { return }
            Task { @MainActor [weak self] in self?.failIfPreplayback(stage) }
        }
        pollForFirstSegment(remux: remux)
    }

    // MARK: - Audio track switching (D4)

    /// Switch the muxed audio track: tear the player/server/remux pipeline down and rebuild it on the
    /// requested stream index, resuming at the current position (plan decision D4 — one audio track
    /// per session; muxing every track as parallel renditions would cost N segment pipelines for no
    /// gain). The subtitle selection is carried over; watch progress, the Trakt session, and the
    /// fetched addon-subtitle list survive. A rebuild failure lands in the normal pre-playback
    /// failure path → mpv at the same position.
    func selectAudioTrack(streamIndex: Int) {
        guard phase == .playing, let current = remux else { return }
        guard let track = audioTracks.first(where: { $0.streamIndex == streamIndex }),
              track.playable, !track.selected else { return }
        print("[NativePlayer] audio switch → stream \(streamIndex) (\(track.name)) at \(String(format: "%.1f", lastPositionSec))s")
        pendingResumeSec = lastPositionSec > 1 ? lastPositionSec : nil
        if let item = playerItem, let group = legibleGroup {
            pendingSubtitleName = item.currentMediaSelection.selectedMediaOption(in: group)?.displayName
            pendingSubtitleOff = pendingSubtitleName == nil
        }

        observeTask?.cancel(); observeTask = nil
        pollTask?.cancel(); pollTask = nil
        player?.pause()
        server?.stop(); server = nil
        current.stop()
        if UserDefaults.standard.bool(forKey: "debug.keepRemuxOutput") {
            print("[NativePlayer] kept remux output at \(current.outputDir.path)")
        } else {
            current.scheduleCleanup()
        }
        remux = nil
        player = nil
        playerItem = nil
        servedURL = nil
        legibleGroup = nil
        // signalingAttempt intentionally survives: if this device already proved it needs the
        // reduced (no SUPPLEMENTAL-CODECS) master form, the rebuilt server starts there directly.
        audioTracks = []
        preparingLabel = String(localized: "Switching Audio\u{2026}")
        phase = .preparing
        launchRemux(audioStreamIndex: streamIndex)
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        observeTask?.cancel(); observeTask = nil
        addonSubsWatcher?.cancel(); addonSubsWatcher = nil
        if lastDurationSec > 0 {
            recorder.record(positionSec: lastPositionSec, durationSec: lastDurationSec, isPaused: true, speed: 1, flush: true)
        }
        recorder.stopTrakt(positionSec: lastPositionSec, durationSec: lastDurationSec)
        player?.pause()
        server?.stop(); server = nil
        remux?.stop()
        // debug.keepRemuxOutput=1 preserves the emitted files so they can be pulled off the device
        // (devicectl copy from the app container) and inspected with ffprobe on a Mac. Cleanup is
        // scheduled on the remux worker's own queue so it runs strictly AFTER the worker exits —
        // a direct removal here can race a final in-flight segment write.
        if let remux {
            if UserDefaults.standard.bool(forKey: "debug.keepRemuxOutput") {
                print("[NativePlayer] kept remux output at \(remux.outputDir.path)")
            } else {
                remux.scheduleCleanup()
            }
        }
        remux = nil
        player = nil
        playerItem = nil
    }

    // MARK: - Progressive startup

    /// Poll the remux output until playback can start: the segment map exists (else the source has no
    /// usable keyframe index → mpv), the init segment is written, and the first media segment is ready
    /// so AVPlayer's opening requests are instant. The playlist is a COMPLETE VOD list from the first
    /// fetch (the JIT server synthesizes it from the map), so there is no EVENT ≥3-segment join rule
    /// anymore; later segments simply block briefly on the JIT server until the remux produces them.
    private func pollForFirstSegment(remux: RemuxSession) {
        pollTask = Task { @MainActor [weak self] in
            let dir = remux.outputDir
            // The VOD master is rendered exactly once — subtitle renditions must exist by then. Give
            // the addon fetch a bounded head start beyond remux readiness; never hold startup longer.
            let subsDeadline = Date().addingTimeInterval(8)
            let pollStart = Date()
            for _ in 0..<240 {                          // ~60s ceiling
                if Task.isCancelled { return }
                if case .failed(let stage) = remux.state { self?.failIfPreplayback(stage); return }
                let hasMap = remux.segmentMap != nil
                let hasInit = Self.fileSize(dir, "init.mp4") > 0
                // A finished remux (short clip that is a single segment) finalizes seg-00001 only at EOF.
                let hasFirst = Self.fileSize(dir, RemuxSession.segmentName(1)) > 0 || remux.state == .ready
                if hasMap && hasInit && hasFirst {
                    if let self, !self.subsFetchCompleted(), Date() < subsDeadline {
                        try? await Task.sleep(nanoseconds: 250_000_000)   // waiting only on subtitles now
                        continue
                    }
                    if let self, !self.subsFetchDone {
                        print("[NativePlayer] subs gate lapsed after \(String(format: "%.1f", Date().timeIntervalSince(pollStart)))s — starting without addon subtitles")
                    }
                    self?.beginPlayback(remux: remux)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.failIfPreplayback("no segments produced")
        }
    }

    private static func fileSize(_ dir: URL, _ name: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? Int) ?? 0
    }

    private func beginPlayback(remux: RemuxSession) {
        guard phase == .preparing, player == nil else { return }
        guard let map = remux.segmentMap else { failIfPreplayback("no segment map"); return }
        // Audio menu data (D4): the worker published the full track list with its selection when it
        // inspected the streams — always before the map exists, so it's complete here.
        audioTracks = remux.audioTracks.map {
            NativeAudioTrack(streamIndex: $0.streamIndex, name: Self.audioTrackDisplayName($0),
                             playable: $0.playable, selected: $0.selected)
        }
        // External subtitles (D5): stream-attached files plus the addon-fetched list (the same
        // source the mpv player side-loads — streams rarely attach their own), offered as WebVTT
        // renditions in the synthesized master. The server downloads/converts on first selection.
        // Embedded text tracks (info-panel W2) come first — they're the file's own — then addon files.
        let embeddedRenditions = SubtitleVTT.embeddedRenditions(tracks: remux.subtitleTracks,
                                                                availableSinks: remux.subtitleSinkIndices, after: [])
        let addonRenditions = SubtitleVTT.renditions(from: context.externalSubtitles + addonSubtitles)
            .map { r in SubtitleRendition(index: r.index + embeddedRenditions.count, name: r.name,
                                          language: r.language, source: r.source) }
        var subtitleRenditions = embeddedRenditions + addonRenditions
        // Names must be unique within the group (AVPlayer keys options by name) — addon names are
        // deduped among themselves; dedupe them against the embedded ones too.
        var seen = Set<String>()
        subtitleRenditions = subtitleRenditions.map { r in
            var name = r.name, n = 2
            while !seen.insert(name).inserted { name = "\(r.name) \(n)"; n += 1 }
            return name == r.name ? r : SubtitleRendition(index: r.index, name: name, language: r.language,
                                                          source: r.source, forced: r.forced, hearingImpaired: r.hearingImpaired)
        }
        embeddedSubtitleCount = embeddedRenditions.count
        print("[NativePlayer] subtitle renditions: \(subtitleRenditions.count) (\(embeddedRenditions.count) embedded)"
              + (subtitleRenditions.isEmpty ? "" : " — \(subtitleRenditions.prefix(6).map(\.name).joined(separator: ", "))\(subtitleRenditions.count > 6 ? ", …" : "")"))
        // A device that already fell back to the reduced master form keeps it across an
        // audio-switch rebuild (same video stream — the full form would just fail again).
        var signaling = remux.videoSignaling ?? VideoSignaling(codecs: "")
        if signalingAttempt > 0 { signaling.supplementalCodecs = nil }
        let selectedAudio = remux.audioTracks.first(where: \.selected)
        // The forced-only decision needs the audio the viewer will hear (shared plan semantics).
        resolveLanguagePlan(selectedAudioLanguage: selectedAudio.flatMap { track in
            PlayerTrackSelectionKt.resolveAudioTrackLanguageTarget(track: AudioTrack(
                index: 0, id: String(track.streamIndex),
                label: track.title ?? track.language ?? "",
                language: track.language, isSelected: true))
        })
        let server = LocalHLSServer(rootDir: remux.outputDir, map: map,
                                    signaling: signaling,
                                    audioCodec: remux.audioCodecToken,
                                    audioName: selectedAudio.map(Self.audioTrackDisplayName),
                                    audioLanguage: selectedAudio?.language,
                                    bandwidth: remux.estimatedBandwidth,
                                    subtitles: subtitleRenditions,
                                    subtitleFlags: subtitleFlags(for: subtitleRenditions),
                                    producingInfo: { remux.producingInfo },
                                    requestReposition: { remux.reposition(toSegment: $0) })
        self.server = server
        server.start(masterName: remux.masterPlaylistName) { [weak self] url in
            guard let self else { return }
            guard let url else { self.failIfPreplayback("server bind failed"); return }
            print("[NativePlayer] serving \(url.absoluteString)")
            self.servedURL = url
            let item = AVPlayerItem(url: url)
            // Bound how far ahead AVPlayer prefetches: over the infinite-bandwidth loopback origin it
            // would otherwise race minutes past the ~realtime remux frontier and block on segments that
            // don't exist yet, tripping CFNetwork's request timeout.
            item.preferredForwardBufferDuration = 24
            let player = AVPlayer(playerItem: item)
            self.applyLanguagePlan(to: player)
            self.playerItem = item
            self.player = player
            self.phase = .playing
            self.observePlayback(player: player, item: item)
        }
    }

    /// Item failed before playback ever started. Attempt 0 → retry once with minimal signaling
    /// (some AVPlayer builds reject the full CODECS/SUPPLEMENTAL form at the master stage);
    /// attempt 1 → give up and hand the context to mpv.
    private func handlePrePlaybackItemFailure(player: AVPlayer) {
        for name in ["master.m3u8", "media.m3u8"] {
            guard let playlist = server?.renderedPlaylist(named: name) else { continue }
            // Prefix every line so console filters on "NativePlayer" keep the playlist content. The
            // media playlist can be long (one line per segment) — cap the dump.
            let prefixed = playlist.components(separatedBy: "\n").prefix(40)
                .map { "[NativePlayer] | \($0)" }.joined(separator: "\n")
            print("[NativePlayer] served \(name) (\(playlist.count) chars):\n\(prefixed)")
        }
        if let dir = remux?.outputDir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let listing = names.sorted().prefix(24).map { "\($0)=\(Self.fileSize(dir, $0))b" }.joined(separator: " ")
            print("[NativePlayer] output dir: \(listing)")
        }
        guard signalingAttempt == 0, let servedURL else {
            print("[NativePlayer] failing over to mpv (item failed before playback started)")
            phase = .failed("item failed before start")
            return
        }
        signalingAttempt = 1
        // Retry once with reduced signaling: drop only SUPPLEMENTAL-CODECS (some AVPlayer builds
        // reject the DV supplemental form at the master stage). The full RFC 6381 CODECS token and
        // VIDEO-RANGE MUST stay — bare tags are non-compliant, and PQ media without a declared
        // VIDEO-RANGE is itself rejected on tvOS 27 (the retry would fail for the wrong reason).
        var reduced = remux?.videoSignaling ?? VideoSignaling(codecs: "hvc1")
        reduced.supplementalCodecs = nil
        server?.setSignaling(reduced)
        print("[NativePlayer] retrying without SUPPLEMENTAL-CODECS (CODECS=\(reduced.codecs) RANGE=\(reduced.videoRange ?? "-"))")
        observeTask?.cancel()
        // Cache-bust so AVPlayer refetches the master (the server ignores query strings).
        let retryURL = URL(string: servedURL.absoluteString + "?r=1") ?? servedURL
        let item = AVPlayerItem(url: retryURL)
        item.preferredForwardBufferDuration = 24
        playerItem = item
        player.replaceCurrentItem(with: item)
        observePlayback(player: player, item: item)
    }

    // MARK: - AVPlayer observation (resume + progress + Trakt)

    private func observePlayback(player: AVPlayer, item: AVPlayerItem) {
        observeTask = Task { @MainActor [weak self] in
            var readied = false
            var waitingTicks = 0
            var notReadyTicks = 0
            var lastProducingSeg = 0
            while !Task.isCancelled {
                guard let self, self.player === player else { return }

                if !readied, item.status == .readyToPlay {
                    readied = true
                    print("[NativePlayer] item readyToPlay")
                    let duration = CMTimeGetSeconds(item.duration)
                    // An audio-switch rebuild resumes exactly where it left off; otherwise the saved
                    // watch progress decides.
                    let resume = self.pendingResumeSec ?? self.recorder.resumePositionSec()
                    self.pendingResumeSec = nil
                    if let resume {
                        await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                        self.lastPositionSec = resume
                    }
                    player.play()
                    if !self.traktStarted {
                        self.traktStarted = true
                        self.recorder.startTrakt(positionSec: self.lastPositionSec, durationSec: duration.isFinite ? duration : 0)
                    }
                    self.loadLegibleSelection(item: item)
                } else if item.status == .failed {
                    print("[NativePlayer] item FAILED — \(item.error?.localizedDescription ?? "unknown")")
                    Self.dumpItemLogs(item)
                    // THIS item never became ready → retry with minimal signaling, then hand to mpv.
                    // (Keyed on the item, not lifetime state: after an audio-switch rebuild the
                    // coordinator has a duration from the previous item, but a pre-ready failure of
                    // the new one still belongs to the signaling retry path.)
                    if !readied {
                        self.handlePrePlaybackItemFailure(player: player)
                    } else {
                        // Failed AFTER playback started — e.g. a forward seek past the linear remux
                        // frontier that the JIT server fast-503'd until AVPlayer gave up. Hand to mpv
                        // (which seeks anywhere via its own demuxer) at the current/target position.
                        self.fallbackMidPlay("item failed mid-play")
                    }
                    return
                } else if !readied {
                    // Blind-spot coverage: the item can sit in .unknown forever (bad playlist, codec
                    // rejection) with no state change to observe. Surface why every ~10s.
                    notReadyTicks += 1
                    if notReadyTicks % 50 == 0 {          // 50 ticks × 200ms ≈ 10s
                        print("[NativePlayer] item still not ready after ~\(notReadyTicks / 5)s (status=\(item.status.rawValue))")
                        Self.dumpItemLogs(item)
                    }
                }

                if readied {
                    let pos = CMTimeGetSeconds(player.currentTime())
                    let dur = CMTimeGetSeconds(item.duration)
                    // A position jump = a user seek. Reset the stall budget so back-to-back scrubs
                    // (each costing a ~10s reposition) can't accumulate into a false mpv fallback.
                    if pos.isFinite, abs(pos - self.lastPositionSec) > 10 {
                        waitingTicks = 0
                    }
                    if pos.isFinite, dur.isFinite, dur > 0 {
                        let paused = player.timeControlStatus != .playing
                        self.lastPositionSec = pos
                        self.lastDurationSec = dur
                        self.recorder.record(positionSec: pos, durationSec: dur, isPaused: paused, speed: 1, flush: false)
                        self.onTick?(pos, dur)
                    }

                    // Stall diagnostics: if the player sits in a waiting state across several ticks,
                    // dump why — the item's error log carries segment/format errors (decode
                    // rejections, 404s) that are otherwise invisible outside Xcode.
                    if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        waitingTicks += 1
                        // A stall with the remux still ADVANCING is a seek being refilled at source
                        // speed, not a dead session — reset the budget on every producing-segment
                        // advance. Only a frozen remux (dead source) runs the clock out.
                        let producing = self.remux?.producingInfo.producing ?? 0
                        if producing != lastProducingSeg {
                            lastProducingSeg = producing
                            waitingTicks = 1
                        }
                        if waitingTicks == 3 || waitingTicks % 10 == 3 {
                            let reason = player.reasonForWaitingToPlay?.rawValue ?? "?"
                            print("[NativePlayer] waiting (\(reason)) at \(String(format: "%.1f", CMTimeGetSeconds(player.currentTime())))s")
                            Self.dumpItemLogs(item)
                        }
                        // Sustained stall (~30s at 3s/tick) with NO remux progress: dead/stalled
                        // source. Hand to mpv at the current position rather than spin forever.
                        if waitingTicks >= 10 {
                            self.fallbackMidPlay("stalled ~30s with no remux progress")
                            return
                        }
                    } else {
                        waitingTicks = 0
                    }
                }
                try? await Task.sleep(nanoseconds: readied ? 3_000_000_000 : 200_000_000)
            }
        }
    }

    /// Cache the item's legible media-selection group (so an audio-switch teardown can read the
    /// active subtitle synchronously) and restore a subtitle choice carried over from the previous
    /// item. Options are matched by display name — the rendition NAME we synthesized, unique enough
    /// within one session's master.
    private func loadLegibleSelection(item: AVPlayerItem) {
        Task { @MainActor [weak self] in
            let group = (try? await item.asset.loadMediaSelectionGroup(for: .legible)) ?? nil
            guard let self, self.playerItem === item else { return }
            self.legibleGroup = group
            if let want = self.pendingSubtitleName {
                self.pendingSubtitleName = nil
                if let group, let option = group.options.first(where: { $0.displayName == want }) {
                    item.select(option, in: group)
                    print("[NativePlayer] restored subtitle selection: \(want)")
                }
            } else if self.pendingSubtitleOff {
                self.pendingSubtitleOff = false
                if let group, item.currentMediaSelection.selectedMediaOption(in: group) != nil {
                    item.select(nil, in: group)
                    print("[NativePlayer] restored subtitle selection: Off")
                }
            }
        }
    }

    // MARK: - Audio track display names

    /// 10-foot menu label: localized language, codec + channel layout, then the container's track
    /// title when it adds information ("Commentary", "Atmos"). E.g. "English · TrueHD 7.1 · Atmos".
    private static func audioTrackDisplayName(_ track: RemuxAudioTrack) -> String {
        var parts: [String] = []
        if let tag = track.language?.lowercased(), tag != "und",
           let language = Locale.current.localizedString(forLanguageCode: Self.iso639BtoT[tag] ?? tag) {
            parts.append(language)
        }
        let codec = Self.audioCodecDisplay[track.codec] ?? track.codec.uppercased()
        parts.append("\(codec) \(Self.channelText(track.channels))")
        if let title = track.title, !title.isEmpty, title.count <= 42 { parts.append(title) }
        return parts.isEmpty ? String(localized: "Track \(track.streamIndex)") : parts.joined(separator: " \u{00B7} ")
    }

    /// MKV language tags are usually ISO 639-2/B; Locale wants /T for the codes where they differ.
    private static let iso639BtoT: [String: String] = [
        "fre": "fra", "ger": "deu", "dut": "nld", "chi": "zho", "cze": "ces", "gre": "ell",
        "ice": "isl", "per": "fas", "rum": "ron", "slo": "slk", "arm": "hye", "geo": "kat",
        "may": "msa", "alb": "sqi", "baq": "eus", "bur": "mya", "mac": "mkd", "tib": "bod",
        "wel": "cym",
    ]

    private static let audioCodecDisplay: [String: String] = [
        "aac": "AAC", "ac3": "Dolby Digital", "eac3": "Dolby Digital+", "truehd": "TrueHD",
        "dts": "DTS", "flac": "FLAC", "alac": "ALAC", "mp3": "MP3", "opus": "Opus",
        "vorbis": "Vorbis",
    ]

    private static func channelText(_ channels: Int) -> String {
        switch channels {
        case 1: return String(localized: "Mono")
        case 2: return String(localized: "Stereo")
        case 3: return "2.1"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    // MARK: - Stream Info tab

    /// Rows for the native player's Stream Info tab: routing decision, remux signaling, segment-map
    /// shape, and live transfer stats from the item's access log. Called on playback ticks.
    func streamInfoRows(routingNote: String?) -> [NativeInfoRow] {
        var rows: [NativeInfoRow] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append(NativeInfoRow(label: label, value: value)) }
        }
        add(String(localized: "Engine"), routingNote ?? String(localized: "Native"))
        if let s = remux?.videoSignaling {
            add(String(localized: "Video"), s.codecs)
            add("Dolby Vision", s.supplementalCodecs)
            add(String(localized: "Dynamic range"), s.videoRange)
            if s.width > 0, s.height > 0 {
                let fps = s.frameRate > 0 ? String(format: " · %.6g fps", s.frameRate) : ""
                add(String(localized: "Resolution"), "\(s.width)\u{00D7}\(s.height)\(fps)")
            }
        }
        // The display name already carries language · codec · layout · title; the RFC 6381 token
        // adds nothing a viewer needs and pushes the row onto a second line.
        add(String(localized: "Audio"), audioTracks.first(where: \.selected)?.name ?? remux?.audioCodecToken)
        // The transport-bar Audio menu only exists with >1 track — say so here, so a single-track
        // source doesn't read as a broken selector.
        if audioTracks.count == 1 {
            add(String(localized: "Audio tracks"), String(localized: "1 (this file has no alternate audio)"))
        } else if audioTracks.count > 1 {
            add(String(localized: "Audio tracks"), String(localized: "\(audioTracks.count) · Audio menu in the transport bar"))
        }
        // What the viewer currently sees: the item's legible selection (system Subtitles tab).
        if let item = playerItem, let group = legibleGroup {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            add(String(localized: "Subtitles"), selected?.displayName ?? String(localized: "Off"))
        }
        // Same self-explanation for subtitles: an empty system menu should read as "the addons
        // had nothing for this title", not as a broken selector.
        if subsFetchDone {
            add(String(localized: "Addon subtitles"), addonSubtitles.isEmpty
                ? String(localized: "none found for this title")
                : String(localized: "\(addonSubtitles.count) found"))
        } else {
            add(String(localized: "Addon subtitles"), String(localized: "searching…"))
        }
        // Subtitle tracks inside the file. Text tracks are offered as renditions (Subtitles tab);
        // bitmap tracks (PGS/VobSub) can't be shown by the native player — say so rather than look
        // broken.
        if let subs = remux?.subtitleTracks, !subs.isEmpty {
            let text = subs.filter(\.isText).count, bitmap = subs.count - text
            if text > 0 {
                add(String(localized: "Embedded subtitles"), embeddedSubtitleCount == text
                    ? String(localized: "\(text) · in the Subtitles tab")
                    : String(localized: "\(embeddedSubtitleCount) of \(text) · in the Subtitles tab"))
            }
            if bitmap > 0 {
                add(String(localized: "Bitmap subtitles"),
                    String(localized: "\(bitmap) PGS/VobSub · not shown natively"))
            }
        }
        if let map = remux?.segmentMap {
            add(String(localized: "Segments"), "\(map.count) \u{00D7} \(map.targetDurationSec)s \u{00B7} \(Self.timeString(map.totalDurationSec))")
        }
        // Bandwidth + transfer stats share rows: the Info tab has a fixed panel height, and the
        // two-column grid fits ten rows, not twelve.
        let event = playerItem?.accessLog()?.events.last
        var bitrate: [String] = []
        if let event, event.indicatedBitrate > 0 {
            bitrate.append(String(format: "%.1f Mb/s", event.indicatedBitrate / 1_000_000))
        }
        if let bandwidth = remux?.estimatedBandwidth, bandwidth > 0 {
            bitrate.append(String(localized: "declared \(String(format: "%.1f", Double(bandwidth) / 1_000_000)) Mb/s"))
        }
        add(String(localized: "Bitrate"), bitrate.joined(separator: " \u{00B7} "))
        if let event, event.numberOfBytesTransferred > 0 {
            var transfer = String(format: "%.0f MB", Double(event.numberOfBytesTransferred) / 1_048_576)
            if event.numberOfStalls > 0 {
                transfer += " \u{00B7} " + String(localized: "\(event.numberOfStalls) stall(s)")
            }
            add(String(localized: "Transferred"), transfer)
        }
        return rows
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Error + access logs from the item — names the exact URI/status/comment AVPlayer choked on.
    private static func dumpItemLogs(_ item: AVPlayerItem) {
        for event in item.errorLog()?.events ?? [] {
            print("[NativePlayer] errorLog: status=\(event.errorStatusCode) \(event.errorComment ?? "") uri=\(event.uri ?? "")")
        }
        if let access = item.accessLog()?.events.last {
            print("[NativePlayer] accessLog: uri=\(access.uri ?? "?") bytes=\(access.numberOfBytesTransferred) stalls=\(access.numberOfStalls)")
        }
    }

    private func failIfPreplayback(_ stage: String) {
        guard phase != .playing else {
            // Mid-play remux failure (e.g. a truncated debrid source): the remaining segments will
            // never appear, so JIT requests would block until playback stalls. Hand to mpv now rather
            // than wait for the stall watchdog.
            print("[NativePlayer] remux failed MID-PLAY at \(stage) — handing to mpv")
            fallbackMidPlay("remux failed mid-play: \(stage)")
            return
        }
        if case .failed = phase { return }
        print("[NativePlayer] pre-playback failure: \(stage) — falling back to mpv")
        phase = .failed(stage)
    }

    /// Mid-play escalation to mpv: the native path started but can no longer make progress (a seek past
    /// the linear remux frontier, or the source truncated). Flipping `phase` to `.failed` makes
    /// `NativePlayerScreen` call `onFallback(lastPositionSec)`, which re-presents mpv at the same
    /// position — mpv seeks anywhere via its own demuxer. No-op unless we are actually playing.
    private func fallbackMidPlay(_ reason: String) {
        guard phase == .playing else { return }
        observeTask?.cancel()
        print("[NativePlayer] mid-play fallback to mpv at \(String(format: "%.1f", lastPositionSec))s — \(reason)")
        phase = .failed(reason)
    }
}
