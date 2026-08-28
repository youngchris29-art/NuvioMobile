import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

// Playback models (PlaybackContext, PlayerTuning, PlayerTrack, SkipSegment/SkipPrompt,
// StreamInfoSnapshot, SubtitleFile) now live in PlaybackModels.swift so every engine shares them.

/// CAMetalLayer subclass that ignores degenerate drawable sizes (mirrors the iOS player's MetalLayer).
final class TVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

/// Observable playback state the SwiftUI controls overlay binds to. The player controller polls libmpv
/// (~2x/sec) and pushes updates here on the main thread.
@MainActor
final class MPVPlaybackState: ObservableObject {
    @Published var positionSec: Double = 0
    @Published var durationSec: Double = 0
    @Published var isPaused: Bool = false
    @Published var isBuffering: Bool = true
    @Published var controlsVisible: Bool = false

    @Published var audioTracks: [PlayerTrack] = []
    @Published var subtitleTracks: [PlayerTrack] = []
    /// The swipe-down top panel (Info · Subtitles · Audio · Playback) is presented.
    @Published var panelOpen: Bool = false
    /// Addon subtitle fetch in flight — the picker shows "Searching…" instead of hiding the row.
    @Published var subtitleSearchInFlight: Bool = false

    /// Active skip prompt ("Skip Intro"/"Skip Outro") when playback is inside a known segment.
    @Published var skipPrompt: SkipPrompt?

    /// Playback-settings panel state (speed, subtitle/audio delay, diagnostics).
    @Published var playbackSpeed: Double = 1.0
    @Published var subtitleDelaySec: Double = 0
    @Published var audioDelaySec: Double = 0
    @Published var showStreamInfo: Bool = false
    @Published var streamInfo: StreamInfoSnapshot?
    /// Engine routing decision from `PlayerEngineRouter`, shown as the Stream Info "Engine" row.
    /// Diagnostic only in Phase 1 — playback still runs through libmpv regardless.
    @Published var routingNote: String = ""

    /// True once playback hit end-of-file (keep-open holds the last frame; drives the post-play cover).
    @Published var isEnded: Bool = false

    /// Wired by the controller so the SwiftUI track picker can drive libmpv.
    var selectAudio: ((Int) -> Void)?
    var selectSubtitle: ((Int) -> Void)?
    var setSpeed: ((Double) -> Void)?
    var setSubtitleDelay: ((Double) -> Void)?
    var setAudioDelay: ((Double) -> Void)?
    var replay: (() -> Void)?
    var reclaimFocus: (() -> Void)?

    /// Wired by `NextEpisodeEngine`: down-press plays the ready next episode (returns true when
    /// consumed, so the skip pill doesn't also fire); backward seek cancels the countdown.
    var upNextPlayNow: (() -> Bool)?
    var upNextCancel: (() -> Void)?

    let title: String
    init(title: String) { self.title = title }

    var fraction: Double {
        durationSec > 0 ? min(max(positionSec / durationSec, 0), 1) : 0
    }
    var hasTracks: Bool { !audioTracks.isEmpty || !subtitleTracks.isEmpty }
}

/// libmpv-backed player for tvOS. Siri-remote transport: select/play-pause toggles, left/right seek
/// ±10s, down (or a down swipe) opens the top panel, Menu exits. Publishes position/duration/paused/buffering and
/// track lists to `state`, and records watch progress (resume position) via `WatchProgressRepository`.
final class MPVTVPlayerViewController: UIViewController {

    private var metalLayer = TVMetalLayer()
    private var mpv: OpaquePointer?
    private var lastDrawableSize: CGSize = .zero
    private let eventQueue = DispatchQueue(label: "mpv-events", qos: .userInitiated)
    private let context: PlaybackContext
    private let state: MPVPlaybackState
    private var didLoad = false
    private var pollTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private var lastSaveUptime: TimeInterval = 0
    private var pendingResumeSec: Double?
    private var seekTimer: Timer?
    private var seekDirection: Double = 0
    private var seekHoldCount = 0
    private var subtitleWatcher: FlowWatcher?
    private var subtitleLoadingWatcher: FlowWatcher?
    private var playerSettingsWatcher: FlowWatcher?
    private var playerSettings: PlayerSettingsUiState?
    private var didAutoSelectTracks = false
    private var addedSubtitleUrls = Set<String>()
    private var fileLoaded = false
    /// Trakt scrobbling (no-ops while Trakt is disconnected — the shared repo checks auth).
    private var traktScrobbleItem: TraktScrobbleItem?
    private var traktScrobbleRequested = false
    /// Set once the player is going away. `buildItem` completes asynchronously — if the user backs
    /// out before it returns, the late completion must not start a scrobble that nothing will ever
    /// stop (ME-004).
    private var traktSessionClosed = false
    private var skipSegments: [SkipSegment] = []
    /// Last raw eof-reached value (edge detection for the post-play cover).
    private var lastEofFlag = false

    // MARK: Event-driven property cache
    //
    // The main thread must NEVER call mpv_get_property: synchronous reads contend on the core
    // lock, which is busiest during the first minute of playback (demuxer cache fill, decoder
    // spin-up) — that contention was the beta-reported "player laggy at first" / "swipe-up menu
    // slow to appear" (tracker BUG-2/BUG-3). Values arrive as MPV_EVENT_PROPERTY_CHANGE payloads
    // on `eventQueue` and land in this lock-guarded snapshot; the UI timer only reads the cache.
    private struct PropSnapshot {
        var position: Double = 0
        var duration: Double = 0
        var paused = false
        var coreIdle = false
        var cacheWait = false
        var eof = false
        var videoW: Int64 = 0
        var videoH: Int64 = 0
    }
    private let propLock = NSLock()
    private var propSnapshot = PropSnapshot()
    /// Coalesces track-list refresh requests (many property events can arrive in a burst).
    private var trackRefreshPending = false
    /// Uptime when FILE_LOADED fired — drives the first-90s `[MPVStats]` diagnostics.
    private var fileLoadedUptime: TimeInterval = 0
    /// Times playback entered paused-for-cache (buffering underruns), for diagnostics.
    private var cacheWaitCount = 0

    /// Observation ids for mpv_observe_property (arrive back as `reply_userdata`).
    private enum ObservedProp: UInt64 {
        case timePos = 1, duration, pause, coreIdle, pausedForCache, eofReached, trackCount
        case videoW, videoH
    }

    private func cachedProps() -> PropSnapshot {
        propLock.lock(); defer { propLock.unlock() }
        return propSnapshot
    }

    private func updateProps(_ mutate: (inout PropSnapshot) -> Void) {
        propLock.lock(); defer { propLock.unlock() }
        mutate(&propSnapshot)
    }

    /// Called when the user presses Menu, so the SwiftUI cover can dismiss.
    var onExit: (() -> Void)?
    /// Open the swipe-down top panel (D-pad Down with nothing else to do, or a down swipe).
    var onOpenPanel: (() -> Void)?

    init(context: PlaybackContext, state: MPVPlaybackState) {
        self.context = context
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.masksToBounds = true

        metalLayer.contentsGravity = .resizeAspect
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        layoutMetalLayer()

        state.selectAudio = { [weak self] id in self?.selectAudio(id) }
        state.selectSubtitle = { [weak self] id in self?.selectSubtitle(id) }
        state.setSpeed = { [weak self] speed in self?.setSpeed(speed) }
        state.setSubtitleDelay = { [weak self] seconds in self?.setSubtitleDelay(seconds) }
        state.setAudioDelay = { [weak self] seconds in self?.setAudioDelay(seconds) }
        state.replay = { [weak self] in self?.replay() }
        state.reclaimFocus = { [weak self] in self?.becomeFirstResponder() }
        view.accessibilityIdentifier = "player.mpv"

        // Touch-surface swipe down → top panel (presses arrive as `.downArrow`; real swipes don't).
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown))
        swipeDown.direction = .down
        view.addGestureRecognizer(swipeDown)

        setupMpv()
    }

    @objc private func handleSwipeDown() {
        guard presentedViewController == nil else { return }
        onOpenPanel?()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutMetalLayer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if !didLoad {
            didLoad = true
            computeResumePosition()
            applyRequestHeaders(context.requestHeaders)
            command("loadfile", args: [context.url.absoluteString, "replace"])
            startPolling()
            flashControls()

            // Side-load subtitles fetched from installed subtitle addons (OpenSubtitles etc.).
            subtitleWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.addonSubtitles) { [weak self] emitted in
                guard let self, let subs = emitted as? [AddonSubtitle] else { return }
                self.addAddonSubtitles(subs)
            }
            subtitleLoadingWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.isLoading) { [weak self] emitted in
                guard let self, let loading = (emitted as? NSNumber)?.boolValue else { return }
                DispatchQueue.main.async { self.state.subtitleSearchInFlight = loading }
            }

            // Subtitle appearance from Settings (color/size/bold/outline/background). The watcher
            // emits the current value immediately; re-apply live if the style changes mid-playback.
            PlayerSettingsRepository.shared.ensureLoaded()
            playerSettingsWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
                guard let self, let settings = emitted as? PlayerSettingsUiState else { return }
                self.playerSettings = settings
                if self.fileLoaded { self.applySubtitleStyle() }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
        endSeek()
        saveProgress(flush: true)
        stopTraktScrobble()
        clearDisplayCriteria()
    }

    override var canBecomeFirstResponder: Bool { true }

    private func layoutMetalLayer() {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = UIScreen.main.nativeScale
        let drawable = CGSize(
            width: (bounds.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (bounds.height * scale).rounded(.toNearestOrAwayFromZero)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        metalLayer.contentsScale = scale
        if drawable != lastDrawableSize {
            metalLayer.drawableSize = drawable
            lastDrawableSize = drawable
        }
        CATransaction.commit()
    }

    // MARK: - MPV setup (proven option set from the iOS player)

    private func setupMpv() {
        // On REAL tvOS hardware no audio routes to HDMI unless the AVAudioSession is active
        // BEFORE the audio unit initializes — and with audio-fallback-to-null=yes a failed
        // audiounit init silently plays video with no sound (the simulator doesn't enforce
        // this, which is why audio worked there). The app-startup activation is async on a
        // background queue, so re-activate synchronously here (idempotent, cheap) and LOG
        // failures instead of swallowing them.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("[MPV] AVAudioSession activation FAILED: \(error)")
        }

        mpv = mpv_create()
        guard mpv != nil else { print("[MPV] Failed to create mpv instance"); return }

        checkError(mpv_request_log_messages(mpv, "warn"))
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer))

        // Video output: default `gpu` (stable). On REAL Apple TV hardware the user can opt into
        // `gpu-next` (libplacebo) via Settings → Playback → Enhanced Video Renderer for better HDR
        // tone-mapping (dynamic peak detection, DV/HDR10+). Never on the simulator, where
        // libplacebo's vo asserts ("vo: hit program assert").
        var videoOutput = "gpu"
        #if !targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: PlayerTuning.enhancedRendererKey) {
            videoOutput = "gpu-next"
        }
        #endif

        let options: [(String, String)] = [
            ("vo", videoOutput),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            // On REAL Apple TV hardware ao_audiounit fails to init entirely: its channel-layout
            // query returns kAudioUnitErr_InvalidProperty (-10879) → ao=null → silence (the sim
            // worked because the Mac's stereo output answers the query). ao_avfoundation
            // (AVSampleBufferAudioRenderer, Apple-native) doesn't need that query — use it first,
            // fall back to audiounit. Requires MPVKit >= 0.41.0-n8.1.2 (PR #73 enabled the
            // avfoundation ao for tvOS; PROVEN working on Apple TV 4K 3rd gen 2026-07-02).
            ("ao", "avfoundation,audiounit"),
            ("audio-channels", "auto"),
            ("audio-fallback-to-null", "yes"),
            ("vulkan-swap-mode", "fifo"),
            ("vulkan-queue-count", "1"),
            ("vulkan-async-compute", "no"),
            ("vulkan-async-transfer", "no"),
            ("vulkan-disable-interop", "yes"),
            ("video-rotate", "no"),
            ("keep-open", "yes"),
            ("target-colorspace-hint", "yes"),
            ("tone-mapping", "auto"),
            ("hdr-compute-peak", "yes"),
            ("subs-fallback", "yes"),
        ]
        for (key, value) in options {
            checkError(mpv_set_option_string(mpv, key, value))
        }

        // User-tunable streaming buffer (Settings > Playback > Streaming Buffer). 0 = mpv defaults.
        let bufferMB = UserDefaults.standard.integer(forKey: PlayerTuning.bufferMBKey)
        if bufferMB > 0 {
            checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "\(bufferMB)MiB"))
            checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", "\(max(bufferMB / 2, 16))MiB"))
        }
        let readaheadSec = UserDefaults.standard.integer(forKey: PlayerTuning.readaheadSecKey)
        if readaheadSec > 0 {
            checkError(mpv_set_option_string(mpv, "cache", "yes"))
            checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "\(readaheadSec)"))
            checkError(mpv_set_option_string(mpv, "cache-secs", "\(readaheadSec)"))
        }

        checkError(mpv_initialize(mpv))
        // Everything the UI needs is observed with a data payload so state flows to us on the
        // event queue — the main thread never issues a synchronous property read (see PropSnapshot).
        mpv_observe_property(mpv, ObservedProp.timePos.rawValue, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, ObservedProp.duration.rawValue, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, ObservedProp.pause.rawValue, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.coreIdle.rawValue, "core-idle", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.pausedForCache.rawValue, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.eofReached.rawValue, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.trackCount.rawValue, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, ObservedProp.videoW.rawValue, "video-params/w", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, ObservedProp.videoH.rawValue, "video-params/h", MPV_FORMAT_INT64)

        mpv_set_wakeup_callback(mpv, { ctx in
            let vc = unsafeBitCast(ctx, to: MPVTVPlayerViewController.self)
            vc.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    /// Addon-declared stream headers (`context.requestHeaders`, already sanitized by the shared
    /// `sanitizePlaybackHeaders`) → mpv's `http-header-fields`, applied to every HTTP request this
    /// handle makes (media, HLS segments, addon subtitle side-loads — matching mobile). The
    /// serialization mirrors upstream `MPVPlayerBridge.applyRequestHeaders` exactly: sorted keys,
    /// `Key: Value` pairs comma-joined, `\` and `,` escaped in values, and an explicit "" clear
    /// when there are no headers so a header-free load can never inherit a previous stream's
    /// headers should this handle ever load more than one file. Called before `loadfile`.
    /// Credential-class header names (lowercased). When the stream carries any of these, mpv's
    /// GLOBAL `http-header-fields` would also send them to every `sub-add` URL — i.e. leak the
    /// media host's credentials to unrelated subtitle providers (Codex 2026-08-20 round 4, P1).
    /// `subAdd` checks this flag and side-loads such subtitles through its own credential-free
    /// download instead of letting the core fetch them.
    private static let credentialHeaderNames: Set<String> = ["authorization", "cookie", "proxy-authorization"]
    private var streamHeadersCarryCredentials = false

    private func applyRequestHeaders(_ headers: [String: String]) {
        guard mpv != nil else { return }
        streamHeadersCarryCredentials = headers.keys.contains {
            Self.credentialHeaderNames.contains($0.lowercased())
        }
        if headers.isEmpty {
            setMpvString("http-header-fields", "")
            return
        }

        let serialized = headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { key, value in
                let escapedValue = value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: ",", with: "\\,")
                return "\(key): \(escapedValue)"
            }
            .joined(separator: ",")
        setMpvString("http-header-fields", serialized)
    }

    // MARK: - Tracks

    private struct TrackInfo {
        let id: Int; let lang: String; let title: String; let forced: Bool; let selected: Bool
    }

    /// Schedule a track-list walk on `eventQueue`. The walk is dozens of synchronous property
    /// reads — cheap at steady state but seconds-slow while the core is starting up, so it must
    /// never run on the main thread (beta BUG-3: swipe-up menu slow to appear early in playback).
    /// Coalesced: a burst of track events settles into one walk.
    private func refreshTracksAsync() {
        eventQueue.async { [weak self] in
            guard let self, !self.trackRefreshPending, self.mpv != nil else { return }
            self.trackRefreshPending = true
            self.eventQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.trackRefreshPending = false
                self.walkAndPublishTracks()
            }
        }
    }

    /// Runs on `eventQueue`: one pass over track-list building both the UI rows and the raw
    /// infos the auto-selection logic needs, then publishes on main.
    private func walkAndPublishTracks() {
        guard mpv != nil else { return }
        let count = getInt("track-list/count")
        var audio: [PlayerTrack] = []
        var subs: [PlayerTrack] = [PlayerTrack(id: -1, label: String(localized: "Off"), isSelected: getString("sid") == "no")]
        var audioInfos: [TrackInfo] = []
        var subInfos: [TrackInfo] = []

        for i in 0..<count {
            let type = getString("track-list/\(i)/type") ?? ""
            guard type == "audio" || type == "sub" else { continue }
            let id = getInt("track-list/\(i)/id")
            let selected = getFlag("track-list/\(i)/selected")
            let label = trackLabel(index: i, fallbackId: id)
            let info = TrackInfo(
                id: id,
                lang: getString("track-list/\(i)/lang") ?? "",
                title: getString("track-list/\(i)/title") ?? "",
                forced: getFlag("track-list/\(i)/forced"),
                selected: selected
            )
            if type == "audio" {
                audio.append(PlayerTrack(id: id, label: label, isSelected: selected))
                audioInfos.append(info)
            } else {
                subs.append(PlayerTrack(id: id, label: label, isSelected: selected))
                subInfos.append(info)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let newSubs = subs.count > 1 ? subs : []
            // Don't rebuild the lists while the picker is open — reassigning them rebuilds the
            // SwiftUI list and snaps focus back to the top. Exception: the picker is showing its
            // empty state (first open raced the walk), where populating beats focus preservation.
            // The panel diffs its rows by stable ids, so refreshing while it is open is safe.
            if self.state.audioTracks != audio { self.state.audioTracks = audio }
            if self.state.subtitleTracks != newSubs { self.state.subtitleTracks = newSubs }
            self.autoSelectPreferredTracks(audioInfos: audioInfos, subInfos: subInfos)
        }
    }

    /// Once, on first load: pick the audio track matching the user's preferred languages, then run
    /// the shared audio-aware subtitle auto-selection plan (upstream v0.3.0 parity). With "Use
    /// forced subtitles" on and the audio already in your preferred language, only a FORCED track
    /// in that language is selected (none -> subtitles off); otherwise non-forced tracks in the
    /// preferred languages are considered. No plan (e.g. forced-subs on but audio language
    /// undeterminable) -> leave mpv's own defaults untouched.
    private func autoSelectPreferredTracks(audioInfos: [TrackInfo], subInfos: [TrackInfo]) {
        guard !didAutoSelectTracks, let settings = playerSettings, mpv != nil else { return }
        guard !audioInfos.isEmpty || !subInfos.isEmpty else { return }
        didAutoSelectTracks = true

        let deviceLanguages = DeviceLanguagePreferences.shared.preferredLanguageCodes()
        let audioTargets = PlayerLanguagePreferencesKt.resolvePreferredAudioLanguageTargets(
            preferredAudioLanguage: settings.preferredAudioLanguage,
            secondaryPreferredAudioLanguage: settings.secondaryPreferredAudioLanguage,
            deviceLanguages: deviceLanguages,
            contentOriginalLanguage: nil
        )

        // Audio: only worth switching when there's more than one option.
        var pickedAudioId: Int?
        if audioInfos.count > 1,
           let id = firstTrackId(matching: audioTargets, in: audioInfos.map { (id: $0.id, lang: $0.lang) }) {
            eventQueue.async { [weak self] in self?.setMpvInt("aid", Int64(id)) }
            pickedAudioId = id
        }

        // The audio the viewer will actually hear: picked above, else mpv's selection, else first.
        let effectiveAudio = audioInfos.first { $0.id == pickedAudioId }
            ?? audioInfos.first { $0.selected }
            ?? audioInfos.first
        let selectedAudioLanguage = effectiveAudio.flatMap { info -> String? in
            PlayerTrackSelectionKt.resolveAudioTrackLanguageTarget(
                track: AudioTrack(
                    index: 0,
                    id: String(info.id),
                    label: info.title.isEmpty ? info.lang : info.title,
                    language: info.lang.isEmpty ? nil : info.lang,
                    isSelected: true
                )
            )
        }

        // Subtitles: shared plan decides targets + forced/normal mode.
        let subTargets = PlayerLanguagePreferencesKt.resolvePreferredSubtitleLanguageTargets(
            preferredSubtitleLanguage: settings.preferredSubtitleLanguage,
            secondaryPreferredSubtitleLanguage: settings.secondaryPreferredSubtitleLanguage,
            deviceLanguages: deviceLanguages
        )
        guard !subInfos.isEmpty,
              let plan = PlayerTrackSelectionKt.resolveSubtitleAutoSelectionPlan(
                  selectedAudioLanguage: selectedAudioLanguage,
                  preferredAudioTargets: audioTargets,
                  preferredSubtitleTargets: subTargets,
                  useForcedSubtitles: settings.subtitleStyle.useForcedSubtitles
              )
        else { return }

        let sharedSubs = subInfos.enumerated().map { index, info in
            SubtitleTrack(
                index: Int32(index),
                id: String(info.id),
                label: info.title.isEmpty ? info.lang : info.title,
                language: info.lang.isEmpty ? nil : info.lang,
                isSelected: info.selected,
                isForced: info.forced
            )
        }
        let match = PlayerTrackSelectionKt.findPreferredSubtitleTrackIndex(
            tracks: sharedSubs, targets: plan.targets, mode: plan.mode
        )
        if match >= 0 {
            let sid = Int64(subInfos[Int(match)].id)
            eventQueue.async { [weak self] in self?.setMpvInt("sid", sid) }
        } else if plan.mode == .forcedOnly {
            // Forced-only plan with no forced track in that language: keep subtitles off.
            eventQueue.async { [weak self] in self?.setMpvString("sid", "no") }
        }
    }

    /// First track (in track order) whose language matches the highest-priority target with any hit.
    private func firstTrackId(matching targets: [String], in tracks: [(id: Int, lang: String)]) -> Int? {
        for target in targets {
            for track in tracks where PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: track.lang, targetLanguage: target) {
                return track.id
            }
        }
        return nil
    }

    private func trackLabel(index: Int, fallbackId: Int) -> String {
        let lang = (getString("track-list/\(index)/lang") ?? "").trimmingCharacters(in: .whitespaces)
        let title = (getString("track-list/\(index)/title") ?? "").trimmingCharacters(in: .whitespaces)
        let codec = (getString("track-list/\(index)/codec") ?? "").trimmingCharacters(in: .whitespaces)
        var parts = [lang, title].filter { !$0.isEmpty }
        var label = parts.isEmpty ? String(localized: "Track \(fallbackId)") : parts.joined(separator: " \u{00B7} ")
        if !codec.isEmpty { label += " (\(codec))" }
        return label
    }

    private func selectAudio(_ id: Int) {
        guard mpv != nil else { return }
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            var v = Int64(id)
            mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &v)
        }
        refreshTracksAsync()
    }

    /// Once the file is loaded: side-load stream-provided subtitles and kick off an addon subtitle fetch.
    private func onFileLoaded() {
        guard !fileLoaded else { return }
        fileLoaded = true
        // Restore any subtitle delay saved for this exact video (per title/episode, per profile —
        // beta.15 §B2). `setSubtitleDelay` re-saves the same value, which is a harmless no-op.
        if let storedMs = PlayerTrackPreferenceStorage.shared.loadSubtitleDelayMs(videoId: context.videoId) {
            setSubtitleDelay(Double(storedMs.intValue) / 1000.0)
        }
        for sub in context.externalSubtitles {
            subAdd(url: sub.url, title: sub.name ?? sub.language, lang: sub.language)
        }
        SubtitleRepository.shared.fetchAddonSubtitles(type: context.contentType, videoId: context.videoId)
        // A stream-picker prefetch may already have completed (the fetch call above then no-ops,
        // and the flow watcher's replay fired before fileLoaded was set) — side-load what's there.
        // Key check: never side-load a lingering list that belongs to a different title.
        if (SubtitleRepository.shared.completedRequest.value_ as? String)
            == SubtitleRepository.shared.requestKey(type: context.contentType, videoId: context.videoId),
           let prefetched = SubtitleRepository.shared.addonSubtitles.value_ as? [AddonSubtitle], !prefetched.isEmpty {
            addAddonSubtitles(prefetched)
        }
        applySubtitleStyle()
        applyDisplayCriteriaIfEnabled()
        fetchSkipSegments()
        startTraktScrobble()
    }

    // MARK: - Match content frame rate (AVDisplayManager)

    /// Window whose display criteria we set — cleared on teardown so the display mode reverts.
    private weak var displayCriteriaWindow: UIWindow?

    /// Ask tvOS to switch the display mode to the content's native frame rate (and dynamic range,
    /// when mpv reports BT.2020/PQ/HLG). Public-API path for non-AVAsset players: build a
    /// `CMVideoFormatDescription` from mpv's reported params and use
    /// `AVDisplayCriteria(refreshRate:formatDescription:)`. Requires the user's tvOS
    /// Settings > Video and Audio > Match Content to allow frame-rate matching.
    private func applyDisplayCriteriaIfEnabled() {
        guard UserDefaults.standard.bool(forKey: PlayerTuning.matchFrameRateKey) else { return }
        // Property reads off-main (this runs at file-load, when the core is busiest), then back
        // to main for the UIWindow / AVDisplayManager application.
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            let fps = self.getDouble("container-fps")
            let width = self.getInt("video-params/w")
            let height = self.getInt("video-params/h")
            let codecName = (self.getString("video-codec") ?? "").lowercased()
            let primaries = (self.getString("video-params/primaries") ?? "").lowercased()
            let gamma = (self.getString("video-params/gamma") ?? "").lowercased()
            DispatchQueue.main.async {
                self.applyDisplayCriteria(
                    fps: fps, width: width, height: height,
                    codecName: codecName, primaries: primaries, gamma: gamma
                )
            }
        }
    }

    private func applyDisplayCriteria(
        fps: Double, width: Int, height: Int, codecName: String, primaries: String, gamma: String
    ) {
        guard fps > 10, let window = view.window else { return }
        guard width > 0, height > 0 else { return }

        let codecType: CMVideoCodecType =
            (codecName.contains("hevc") || codecName.contains("265")) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        var extensions: [CFString: Any] = [:]
        if primaries.contains("2020") {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        }
        if gamma.contains("pq") {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        } else if gamma.contains("hlg") {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }

        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { return }

        displayCriteriaWindow = window
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(fps),
            formatDescription: formatDescription
        )
    }

    private func clearDisplayCriteria() {
        displayCriteriaWindow?.avDisplayManager.preferredDisplayCriteria = nil
        displayCriteriaWindow = nil
    }

    // MARK: - Trakt scrobbling
    //
    // Simplified vs. mobile: scrobble "start" once when the file loads, "stop" once with the final
    // progress when the player goes away (Trakt marks the item watched at >= 80%). The shared repo
    // resolves IMDB/TMDB ids itself and silently no-ops when Trakt isn't connected.

    private func startTraktScrobble() {
        guard !traktScrobbleRequested else { return }
        // Error/placeholder clips (debrid cache-sync stubs, error videos) must not
        // open a Trakt session — mirrors the shared short-placeholder guard.
        if WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(state.durationSec * 1000)) { return }
        traktScrobbleRequested = true
        TraktScrobbleRepository.shared.buildItem(
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            title: context.title,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: nil,
            releaseInfo: nil
        ) { [weak self] item, _ in
            // Suspend completions can land off-main; hop before touching controller state.
            DispatchQueue.main.async {
                guard let self, let item, !self.traktSessionClosed else { return }
                self.traktScrobbleItem = item
                TraktScrobbleRepository.shared.scrobbleStart(
                    profileId: ActiveProfileProvider.shared.activeProfileId,
                    item: item,
                    progressPercent: self.currentProgressPercent()
                ) { _ in }
            }
        }
    }

    private func stopTraktScrobble() {
        traktSessionClosed = true
        guard let item = traktScrobbleItem else { return }
        traktScrobbleItem = nil
        // A session can open before a placeholder's short duration is known; close
        // it at 0% so Trakt never marks the stub watched.
        let short = WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(state.durationSec * 1000))
        TraktScrobbleRepository.shared.scrobbleStop(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            item: item,
            progressPercent: short ? 0 : currentProgressPercent()
        ) { _ in }
    }

    private func currentProgressPercent() -> Float {
        let duration = state.durationSec
        guard duration > 0 else { return 0 }
        return Float(min(100, max(0, state.positionSec / duration * 100)))
    }

    // MARK: - Subtitle appearance (mirrors the mobile libmpv mapping)

    /// Push the user's subtitle style into libmpv. Colors are `SubtitleColor` argb longs (0xAARRGGBB);
    /// the size/outline/border-style formulas match `PlayerEngine.android`'s `applySubtitleStyle`.
    private func applySubtitleStyle() {
        guard mpv != nil, let style = playerSettings?.subtitleStyle else { return }
        setMpvString("sub-ass-override", "no")
        setMpvString("sub-color", mpvColorString(style.textColor))
        setMpvString("sub-back-color", mpvColorString(style.backgroundColor))
        setMpvString("sub-outline-color", mpvColorString(style.outlineColor))
        setMpvString("sub-border-color", mpvColorString(style.outlineColor))
        setMpvString("sub-border-style", subtitleBorderStyle(style))
        setMpvString("sub-bold", style.bold ? "yes" : "no")
        setMpvInt("sub-font-size", subtitleFontSize(style))
        let outline = subtitleOutlineSize(style)
        setMpvInt("sub-outline-size", outline)
        setMpvInt("sub-border-size", outline)
        setMpvInt("sub-pos", Int64(max(0, min(100, 100 - Int(style.bottomOffset) / 10))))
        setMpvString("sub-filter-sdh", style.stripSdh ? "yes" : "no")
        setMpvString("sub-filter-sdh-harder", style.stripSdh ? "yes" : "no")
    }

    private func mpvColorString(_ argb: Int64) -> String {
        let a = (argb >> 24) & 0xFF, r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF
        return String(format: "#%02X%02X%02X%02X", a, r, g, b)
    }

    private func subtitleFontSize(_ s: SubtitleStyleState) -> Int64 {
        let scaled = Int(Double(s.fontSizeSp) * (55.0 / 18.0))
        return Int64(max(36, min(122, scaled)))
    }

    private func subtitleOutlineSize(_ s: SubtitleStyleState) -> Int64 {
        guard s.outlineEnabled else { return 0 }
        return Int64(max(1, Int(Double(s.outlineWidth) * 1.5)))
    }

    private func subtitleBorderStyle(_ s: SubtitleStyleState) -> String {
        if s.outlineEnabled { return "outline-and-shadow" }
        let backgroundAlpha = (s.backgroundColor >> 24) & 0xFF
        return backgroundAlpha > 0 ? "opaque-box" : "outline-and-shadow"
    }

    private func setMpvString(_ name: String, _ value: String) {
        guard let mpv else { return }
        checkError(mpv_set_property_string(mpv, name, value))
    }

    private func setMpvInt(_ name: String, _ value: Int64) {
        guard let mpv else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_INT64, &v)
    }

    /// Fetch intro/recap/outro segments for a series episode (no-op for movies / missing episode
    /// numbers). Works for anime out of the box (AniSkip/AnimeSkip); other content needs an
    /// `INTRO_DB_URL` configured. `requireSkipIntroEnabled: false` bypasses the mobile settings gate.
    private func fetchSkipSegments() {
        guard let season = context.season, let episode = context.episode else { return }
        SkipIntroRepository.shared.getSkipIntervalsForContentId(
            // Routes kitsu:/mal: anime ids to the anime providers; everything else keeps the
            // IMDB path. parentMetaId carries the prefix for addon-sourced anime.
            contentId: context.parentMetaId,
            season: Int32(season),
            episode: Int32(episode),
            // Respect the Settings > Playback "Skip Intro" toggle (skipIntroEnabled).
            requireSkipIntroEnabled: true
        ) { [weak self] intervals, _ in
            guard let intervals else { return }
            let segments = intervals.map { SkipSegment(start: $0.startTime, end: $0.endTime, type: $0.type) }
            DispatchQueue.main.async { self?.skipSegments = segments }
        }
    }

    private func addAddonSubtitles(_ subs: [AddonSubtitle]) {
        guard fileLoaded else { return }
        // PREFERRED_ONLY / "Show only preferred languages": same shared filter the native path and
        // the mobile runtime apply, so the settings aren't engine-dependent.
        let kept = playerSettings.map {
            PlayerTrackSelectionKt.filterAddonSubtitlesForSettings(subtitles: subs, settings: $0)
        } ?? subs
        var added = false
        for sub in kept where !addedSubtitleUrls.contains(sub.url) {
            subAdd(url: sub.url, title: sub.display, lang: sub.language)
            added = true
        }
        if added { refreshTracksAsync() }
    }

    private func subAdd(url: String, title: String, lang: String) {
        guard mpv != nil, !addedSubtitleUrls.contains(url) else { return }
        addedSubtitleUrls.insert(url)
        // Credential leak guard (Codex round 4, P1): with credential-class stream headers set
        // globally on this handle, an in-core `sub-add <http url>` would send them to the
        // subtitle host. Download the file ourselves WITHOUT those headers and hand mpv a local
        // path instead. Only this rare credential case takes the new path — header-free and
        // benign-header (Referer/UA) streams keep the exact in-core behavior below.
        if streamHeadersCarryCredentials,
           let remote = URL(string: url), remote.scheme == "http" || remote.scheme == "https" {
            URLSession.shared.dataTask(with: remote) { [weak self] data, _, error in
                guard let self, let data, error == nil, !data.isEmpty else {
                    NSLog("[MPVPlayer] credential-scoped subtitle fetch failed for %@ — skipping side-load", url)
                    return
                }
                let ext = remote.pathExtension.isEmpty ? "srt" : remote.pathExtension
                let local = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mpv-sub-\(UUID().uuidString).\(ext)")
                do {
                    try data.write(to: local)
                } catch {
                    NSLog("[MPVPlayer] credential-scoped subtitle write failed — skipping side-load")
                    return
                }
                self.eventQueue.async { [weak self] in
                    self?.command("sub-add", args: [local.path, "auto", title, lang])
                }
            }.resume()
            return
        }
        // sub-add downloads/probes the file synchronously inside the core — never on main.
        eventQueue.async { [weak self] in
            self?.command("sub-add", args: [url, "auto", title, lang])
        }
    }

    private func selectSubtitle(_ id: Int) {
        guard mpv != nil else { return }
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            if id < 0 {
                self.checkError(mpv_set_property_string(mpv, "sid", "no"))
            } else {
                var v = Int64(id)
                mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &v)
            }
        }
        refreshTracksAsync()
    }

    // MARK: - Playback speed & A/V-subtitle timing

    private func setSpeed(_ speed: Double) {
        guard mpv != nil else { return }
        setMpvDouble("speed", speed)
        state.playbackSpeed = speed
    }

    /// Single source of truth for subtitle re-timing on the mpv path: applies to the running core,
    /// updates the UI state, and persists per title/profile (beta.15 §B1/B2). Called both for user
    /// chip presses and for the persisted-value replay in `onFileLoaded()` — the redundant save on
    /// replay is a same-value no-op.
    private func setSubtitleDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        setMpvDouble("sub-delay", seconds)
        state.subtitleDelaySec = seconds
        let delayMs = Int32((seconds * 1000).rounded())
        PlayerTrackPreferenceStorage.shared.saveSubtitleDelayMs(videoId: context.videoId, delayMs: delayMs)
    }

    private func setAudioDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        setMpvDouble("audio-delay", seconds)
        state.audioDelaySec = seconds
    }

    private func setMpvDouble(_ name: String, _ value: Double) {
        guard mpv != nil else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
    }

    // MARK: - Stream info (diagnostics overlay)

    /// Runs on `eventQueue` (many synchronous property reads). `engine` is passed in because
    /// `state` is main-actor.
    private func buildStreamInfo(engine: String, subtitleDelaySec: Double) -> StreamInfoSnapshot {
        var info = StreamInfoSnapshot()
        // Append the active subtitle delay to the Engine row so a device pass can read it without
        // opening the panel (beta.15 §B2) — e.g. "mpv · subs +1.50 s".
        if subtitleDelaySec != 0 {
            let suffix = String(format: "subs %+.2f s", subtitleDelaySec)
            info.engine = engine.isEmpty ? suffix : "\(engine) \u{00B7} \(suffix)"
        } else {
            info.engine = engine
        }
        let w = getInt("video-params/w"), h = getInt("video-params/h")
        if w > 0, h > 0 { info.resolution = "\(w)\u{00D7}\(h)" }
        info.videoCodec = getString("video-codec") ?? ""
        let fps = getDouble("container-fps")
        if fps > 0 { info.fps = String(format: "%.3f fps", fps) }
        info.hwdec = getString("hwdec-current") ?? ""
        let vbr = getDouble("video-bitrate")
        if vbr > 0 { info.videoBitrate = String(format: "%.1f Mbps", vbr / 1_000_000) }
        let audioCodec = getString("audio-codec-name") ?? ""
        let channels = getInt("audio-params/channel-count")
        let sampleRate = getInt("audio-params/samplerate")
        var audioParts = [audioCodec]
        if channels > 0 { audioParts.append("\(channels)ch") }
        if sampleRate > 0 { audioParts.append("\(sampleRate / 1000) kHz") }
        info.audio = audioParts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        var cacheParts: [String] = []
        let cacheSec = getDouble("demuxer-cache-duration")
        if cacheSec > 0 { cacheParts.append(String(format: "%.0fs buffered", cacheSec)) }
        let cacheSpeed = getDouble("cache-speed")
        if cacheSpeed > 0 { cacheParts.append(String(format: "%.1f MB/s", cacheSpeed / 1_000_000)) }
        info.cache = cacheParts.joined(separator: " \u{00B7} ")
        return info
    }

    // MARK: - Watch progress (resume + save)

    private func computeResumePosition() {
        guard let entry = WatchProgressRepository.shared.progressForVideo(
            videoId: context.videoId,
            parentMetaId: context.parentMetaId,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) }
        ), !entry.isCompleted else { return }
        let seconds = Double(entry.lastPositionMs) / 1000.0
        if seconds > 10 { pendingResumeSec = seconds }
    }

    private lazy var session = WatchProgressPlaybackSession(
        profileId: ActiveProfileProvider.shared.activeProfileId,
        contentType: context.contentType,
        parentMetaId: context.parentMetaId,
        parentMetaType: context.contentType,
        videoId: context.videoId,
        title: context.title,
        logo: nil,
        poster: context.poster,
        background: context.background,
        seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
        episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
        episodeTitle: nil,
        episodeThumbnail: nil,
        providerName: context.providerName,
        providerAddonId: context.providerAddonId,
        lastStreamTitle: context.streamTitle,
        lastStreamSubtitle: context.streamSubtitle,
        pauseDescription: nil,
        lastSourceUrl: context.url.absoluteString
    )

    private func saveProgress(flush: Bool = false) {
        guard mpv != nil else { return }
        let duration = state.durationSec
        let position = state.positionSec
        guard duration > 0, position > 1 else { return }

        let snapshot = PlayerPlaybackSnapshot(
            isLoading: false,
            isPlaying: !state.isPaused,
            isEnded: false,
            durationMs: Int64(duration * 1000),
            positionMs: Int64(position * 1000),
            bufferedPositionMs: Int64(position * 1000),
            playbackSpeed: Float(state.playbackSpeed),
            videoWidth: Int32(truncatingIfNeeded: cachedProps().videoW),
            videoHeight: Int32(truncatingIfNeeded: cachedProps().videoH)
        )
        if flush {
            WatchProgressRepository.shared.flushPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        } else {
            WatchProgressRepository.shared.upsertPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        }
    }

    // MARK: - State polling

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refreshState() {
        guard mpv != nil else { return }
        // Cached values only — the mpv core is never touched from the main thread (BUG-2/BUG-3:
        // synchronous reads stall for seconds while the core fills its cache early in playback).
        let snap = cachedProps()

        state.durationSec = snap.duration
        state.positionSec = max(snap.position, 0)
        state.isPaused = snap.paused
        state.isBuffering = snap.cacheWait || (snap.coreIdle && !snap.paused)

        // Rising-edge detection: eof-reached STAYS true while keep-open holds the last frame, so
        // only propagate transitions — otherwise a dismissed post-play cover re-presents each tick.
        if snap.eof != lastEofFlag {
            lastEofFlag = snap.eof
            state.isEnded = snap.eof
        }

        if state.showStreamInfo || state.panelOpen {
            refreshStreamInfoAsync()
        }

        let now = ProcessInfo.processInfo.systemUptime
        if !snap.paused, now - lastSaveUptime > 5 {
            lastSaveUptime = now
            saveProgress()
            logStartupStatsIfNeeded()
        }

        updateSkipPrompt(position: snap.position)
    }

    /// First-90s diagnostics for the beta "laggy at first" report: one `[MPVStats]` line per
    /// progress-save tick (~5s) covering cache fill, network draw, and dropped frames. Reads run
    /// on `eventQueue`; grep the sysdiagnose/console output for `[MPVStats]`.
    private func logStartupStatsIfNeeded() {
        guard fileLoadedUptime > 0 else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - fileLoadedUptime
        guard elapsed < 90 else { return }
        let underruns = cacheWaitCount
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            let cacheSec = self.getDouble("demuxer-cache-duration")
            let cacheSpeed = self.getDouble("cache-speed")
            let voDropped = self.getInt("frame-drop-count")
            let decDropped = self.getInt("decoder-frame-drop-count")
            print(String(
                format: "[MPVStats] +%.0fs cache=%.1fs net=%.1f MB/s dropped=vo:%d dec:%d underruns=%d",
                elapsed, cacheSec, cacheSpeed / 1_000_000, voDropped, decDropped, underruns
            ))
        }
    }

    /// Rebuilds the Stream Info panel rows off-main (it reads a dozen mpv properties).
    private func refreshStreamInfoAsync() {
        let engine = state.routingNote
        let subtitleDelaySec = state.subtitleDelaySec
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            let info = self.buildStreamInfo(engine: engine, subtitleDelaySec: subtitleDelaySec)
            DispatchQueue.main.async {
                if info != self.state.streamInfo { self.state.streamInfo = info }
            }
        }
    }

    /// Show a skip prompt while the playhead is inside a segment (leaving a 1s tail so the button
    /// disappears cleanly at the end).
    private func updateSkipPrompt(position: Double) {
        let active = skipSegments.first { position >= $0.start && position < $0.end - PlayerChipStyle.lastSecondExclusion }
        let prompt = active.map { SkipPrompt(label: skipLabel(for: $0.type), targetSec: $0.end) }
        if prompt != state.skipPrompt { state.skipPrompt = prompt }
    }

    private func skipLabel(for type: String) -> String {
        switch type.lowercased() {
        case "outro", "ed", "credits": return String(localized: "Skip Outro")
        case "recap": return String(localized: "Skip Recap")
        default: return String(localized: "Skip Intro")
        }
    }

    // MARK: - Siri-remote transport

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .playPause, .select:
                togglePause(); flashControls(); handled = true
            case .leftArrow:
                beginSeek(-1); handled = true
            case .rightArrow:
                beginSeek(1); handled = true
            case .downArrow:
                if state.upNextPlayNow?() == true {
                    handled = true
                } else if let prompt = state.skipPrompt {
                    // Clamp against duration: a skip-outro target past EOF wedges mpv.
                    // durationSec is still 0 before the first duration event — seek unclamped then.
                    let target = state.durationSec > 0
                        ? min(prompt.targetSec, state.durationSec - 0.5)
                        : prompt.targetSec
                    seekAbsolute(target)
                    state.skipPrompt = nil
                    flashControls()
                    handled = true
                } else if presentedViewController == nil {
                    // Same gesture as the native player: Down opens the top panel. Track lists
                    // are refreshed on open (the async walk fills them if this raced the events).
                    refreshTracksAsync()
                    onOpenPanel?()
                    handled = true
                }
            case .menu:
                onExit?(); handled = true
            default:
                break
            }
        }
        if handled {
            // Any remote interaction proves someone's watching — reset the Still Watching counter.
            NextEpisodeEngine.consecutiveAutoPlays = 0
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses where press.type == .leftArrow || press.type == .rightArrow {
            endSeek(); handled = true
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    /// Start seeking in `dir` (±1). Immediate ±10s, then holds seek in accelerating steps.
    private func beginSeek(_ dir: Double) {
        // Seeking backward means the user is still watching — abandon next-episode autoplay.
        if dir < 0 { state.upNextCancel?() }
        endSeek()
        seekDirection = dir
        seekHoldCount = 0
        seekBy(dir * 10)
        flashControls()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.seekHoldCount += 1
            let step = Double(min(10 + self.seekHoldCount * 10, 60))  // 20s, 30s … up to 60s
            self.seekBy(self.seekDirection * step)
            self.flashControls()
        }
        RunLoop.main.add(timer, forMode: .common)
        seekTimer = timer
    }

    private func endSeek() {
        seekTimer?.invalidate()
        seekTimer = nil
        seekHoldCount = 0
    }

    private func togglePause() {
        guard mpv != nil else { return }
        let target = !cachedProps().paused
        // Optimistic UI: reflect the new state immediately; the pause property event confirms it.
        updateProps { $0.paused = target }
        eventQueue.async { [weak self] in self?.setFlag("pause", target) }
        refreshState()
    }

    /// Post-play "Play Again": back to the start and resume playing.
    private func replay() {
        guard mpv != nil else { return }
        seekAbsolute(0)
        setFlag("pause", false)
        state.isEnded = false
        flashControls()
        becomeFirstResponder()
    }

    private func seekBy(_ seconds: Double) {
        guard mpv != nil else { return }
        // Seeks issued from held-arrow timers must not park the main thread on the core lock.
        eventQueue.async { [weak self] in
            self?.command("seek", args: [String(format: "%.3f", seconds), "relative"])
        }
    }

    private func seekAbsolute(_ seconds: Double) {
        guard mpv != nil else { return }
        eventQueue.async { [weak self] in
            self?.command("seek", args: [String(format: "%.3f", seconds), "absolute"])
        }
    }

    private func flashControls() {
        state.controlsVisible = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.state.isPaused { self.state.controlsVisible = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    // MARK: - Teardown

    deinit {
        pollTimer?.invalidate()
        seekTimer?.invalidate()
        subtitleWatcher?.cancel()
        subtitleLoadingWatcher?.cancel()
        playerSettingsWatcher?.cancel()
        // Idempotent final scrobble stop — normally a no-op after viewDidDisappear, but covers
        // teardown paths where the disappearance callback never ran (ME-004).
        stopTraktScrobble()
        SubtitleRepository.shared.clear()
        destroyPlayer()
    }

    private func destroyPlayer() {
        guard let ctx = mpv else { return }
        mpv = nil
        mpv_terminate_destroy(ctx)
    }

    // MARK: - Event loop

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            while true {
                guard let ev = mpv_wait_event(mpv, 0) else { break }
                let id = ev.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                if id == MPV_EVENT_SHUTDOWN { return }
                if id == MPV_EVENT_FILE_LOADED {
                    self.fileLoadedUptime = ProcessInfo.processInfo.systemUptime
                    DispatchQueue.main.async {
                        self.applyPendingResume()
                        self.onFileLoaded()
                    }
                    self.refreshTracksAsync()
                }
                if id == MPV_EVENT_PROPERTY_CHANGE, let data = ev.pointee.data {
                    let prop = UnsafePointer<mpv_event_property>(OpaquePointer(data)).pointee
                    self.handlePropertyChange(userdata: ev.pointee.reply_userdata, prop: prop)
                }
                if id == MPV_EVENT_END_FILE, let data = ev.pointee.data {
                    let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                    if endFile.reason == MPV_END_FILE_REASON_ERROR {
                        print("[MPV] End file error: \(String(cString: mpv_error_string(endFile.error)))")
                    }
                }
                if id == MPV_EVENT_LOG_MESSAGE,
                   let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(ev.pointee.data)) {
                    let level = String(cString: msg.pointee.level!)
                    let text = String(cString: msg.pointee.text!)
                    print("[MPV] \(level): \(text)", terminator: "")
                }
            }
        }
    }

    /// Runs on `eventQueue`. Folds a property-change payload into the snapshot; only a
    /// track-count change escalates to the (also off-main) track-list walk.
    private func handlePropertyChange(userdata: UInt64, prop: mpv_event_property) {
        guard let observed = ObservedProp(rawValue: userdata) else { return }

        func asDouble() -> Double? {
            guard prop.format == MPV_FORMAT_DOUBLE, let d = prop.data else { return nil }
            return d.assumingMemoryBound(to: Double.self).pointee
        }
        func asFlag() -> Bool? {
            guard prop.format == MPV_FORMAT_FLAG, let d = prop.data else { return nil }
            return d.assumingMemoryBound(to: Int32.self).pointee != 0
        }
        func asInt() -> Int64? {
            guard prop.format == MPV_FORMAT_INT64, let d = prop.data else { return nil }
            return d.assumingMemoryBound(to: Int64.self).pointee
        }

        switch observed {
        case .timePos:
            if let v = asDouble() { updateProps { $0.position = v } }
        case .duration:
            if let v = asDouble() { updateProps { $0.duration = v } }
        case .pause:
            if let v = asFlag() { updateProps { $0.paused = v } }
        case .coreIdle:
            if let v = asFlag() { updateProps { $0.coreIdle = v } }
        case .pausedForCache:
            if let v = asFlag() {
                var rising = false
                updateProps { rising = v && !$0.cacheWait; $0.cacheWait = v }
                if rising { cacheWaitCount += 1 }
            }
        case .eofReached:
            if let v = asFlag() { updateProps { $0.eof = v } }
        case .trackCount:
            refreshTracksAsync()
        case .videoW:
            if let v = asInt() { updateProps { $0.videoW = v } }
        case .videoH:
            if let v = asInt() { updateProps { $0.videoH = v } }
        }
    }

    private func applyPendingResume() {
        guard let seconds = pendingResumeSec else { return }
        pendingResumeSec = nil
        command("seek", args: [String(format: "%.3f", seconds), "absolute"])
    }

    // MARK: - libmpv C-interop helpers

    private func command(_ command: String, args: [String?] = []) {
        guard mpv != nil else { return }
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        var cargs = strArgs.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
        checkError(mpv_command(mpv, &cargs))
    }

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    private func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
        let str = String(cString: cstr)
        mpv_free(cstr)
        return str
    }

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            print("[MPV] API error: \(String(cString: mpv_error_string(status)))")
        }
    }
}

private struct MPVPlayerRepresentable: UIViewControllerRepresentable {
    let context: PlaybackContext
    let state: MPVPlaybackState
    let panelModel: PlayerTopPanelModel
    /// Builds the engine-specific fourth tab at open time (its views observe live state).
    let makeExtraTab: () -> PlayerPanelExtraTab
    let onExit: () -> Void

    func makeUIViewController(context ctx: Context) -> MPVTVPlayerViewController {
        let controller = MPVTVPlayerViewController(context: context, state: state)
        controller.onExit = onExit
        let state = state, model = panelModel, makeExtraTab = makeExtraTab
        controller.onOpenPanel = { [weak controller] in
            guard let controller, controller.presentedViewController == nil else { return }
            let panel = PlayerPanelHostController(rootView: PlayerTopPanel(model: model, extraTab: makeExtraTab()))
            panel.modalPresentationStyle = .overFullScreen
            panel.modalTransitionStyle = .crossDissolve
            model.onClose = { [weak panel] in panel?.close(animated: true) }
            panel.onClosed = { [weak state] in
                state?.panelOpen = false
                state?.reclaimFocus?()     // libmpv's controller must be first responder again
            }
            state.panelOpen = true
            controller.present(panel, animated: !UIAccessibility.isReduceMotionEnabled)
        }
        return controller
    }

    func updateUIViewController(_ controller: MPVTVPlayerViewController, context: Context) {}
}

/// SwiftUI host for the libmpv player + transport overlay; presented full-screen over the stream
/// picker. When `onPlayNext` is provided and the context carries the series episode list, a
/// next-episode autoplay card appears near the end of playback (`NextEpisodeEngine`).
///
/// NOTE for presenters: when swapping contexts for autoplay, apply `.id(context.id)` so SwiftUI
/// rebuilds this screen (and the libmpv controller) for the new episode.
struct MPVPlayerScreen: View {
    let context: PlaybackContext
    var onPlayNext: ((PlaybackContext) -> Void)? = nil
    /// Phase 1 routing diagnostic (from `PlayerEngineRouter`) surfaced in Stream Info; playback is
    /// unaffected — this screen always renders via libmpv.
    var routingNote: String? = nil

    @StateObject private var state: MPVPlaybackState
    @StateObject private var upNext: NextEpisodeEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showPauseInfo = false
    @State private var pauseInfoTask: Task<Void, Never>?
    @StateObject private var panelModel: PlayerTopPanelModel
    @State private var panelAdapter: MPVPlayerPanelAdapter?

    /// Up-next chip label (mirrors the native screen's `UpNextAction` titles); nil = no chip.
    private var upNextChipAction: String? {
        switch upNext.phase {
        case .counting: return UpNextAction.playNext.title
        case .stillWatching: return UpNextAction.continueWatching.title
        default: return nil
        }
    }

    init(context: PlaybackContext, onPlayNext: ((PlaybackContext) -> Void)? = nil, routingNote: String? = nil) {
        self.context = context
        self.onPlayNext = onPlayNext
        self.routingNote = routingNote
        _state = StateObject(wrappedValue: MPVPlaybackState(title: context.title))
        _upNext = StateObject(wrappedValue: NextEpisodeEngine(
            context: context,
            onPlayNext: onPlayNext ?? { _ in }
        ))
        _panelModel = StateObject(wrappedValue: PlayerTopPanelModel(
            info: PlayerPanelInfo(header: NativeInfoHeader(context: context))))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MPVPlayerRepresentable(
                context: context, state: state, panelModel: panelModel,
                makeExtraTab: { [state, upNext, onPlayNext, panelModel] in
                    PlayerPanelExtraTab {
                        MPVPlaybackTab(state: state, engine: upNext, canSwitchStreams: onPlayNext != nil,
                                       onClose: { panelModel.onClose?() })
                    }
                },
                onExit: { dismiss() }
            )
            .ignoresSafeArea()

            if state.isBuffering {
                ProgressView()
                    .scaleEffect(1.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            PlayerControlsOverlay(state: state)
                .opacity(state.controlsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: state.controlsVisible)

            // Metadata card after a sustained pause (Android TV PauseOverlay parity).
            if showPauseInfo, state.isPaused, !state.isBuffering {
                PauseInfoCard(context: context, state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(60)
                    .transition(.opacity)
            }

            // Live diagnostics, toggled from the playback-settings panel.
            if state.showStreamInfo, let info = state.streamInfo {
                StreamInfoOverlayView(info: info)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(60)
                    .transition(.opacity)
            }

            // Transient prompts, bottom-trailing — same chip family as the native screen's
            // contextual actions (PlayerChipStyle). libmpv owns the remote, so these are drawn
            // non-focusable and fire on D-pad Down (see `pressesBegan`); up-next wins over a skip.
            if let caption = upNext.phase.chipCaption(nextTitle: upNext.nextEpisodeTitle) {
                VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                    PlayerChipCaption(text: caption.text, symbol: caption.symbol, showsProgress: caption.progress)
                    if let action = upNextChipAction {
                        PlayerActionChip(label: action, symbol: PlayerChipStyle.nextSymbol, showsPressHint: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(PlayerChipStyle.edgePadding)
                .transition(.opacity)
            } else if let prompt = state.skipPrompt {
                PlayerActionChip(label: prompt.label, symbol: PlayerChipStyle.skipSymbol, showsPressHint: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(PlayerChipStyle.edgePadding)
                    .transition(.opacity)
            }
        }
        .animation(PlayerChipStyle.animation, value: state.skipPrompt)
        .animation(PlayerChipStyle.animation, value: upNext.phase)
        .animation(.easeInOut(duration: 0.25), value: showPauseInfo)
        .animation(.easeInOut(duration: 0.25), value: state.showStreamInfo)
        .fullScreenCover(
            isPresented: Binding(
                get: { state.isEnded && upNext.phase == .hidden },
                set: { if !$0 { state.isEnded = false } }
            ),
            onDismiss: { state.reclaimFocus?() }
        ) {
            PostPlayView(
                title: context.title,
                poster: context.poster,
                onReplay: { state.replay?() },
                onExit: { dismiss() }
            )
        }
        .onAppear {
            if let routingNote { state.routingNote = routingNote }
            if panelAdapter == nil {
                panelAdapter = MPVPlayerPanelAdapter(state: state, model: panelModel, context: context)
            }
            // Start the orchestration whenever a presenter can swap contexts — autoplay needs
            // episodes, but source switching works for movies too (the engine no-ops the rest).
            if onPlayNext != nil {
                upNext.start(state: state)
            }
            // libmpv renders into a bare Metal layer, so tvOS doesn't know video is playing and
            // its idle timer fires the screensaver mid-movie (device report). Hold the idle timer
            // while playback is active — mirroring AVPlayerViewController, which does this
            // automatically — and release it on pause (screen protection) and on dismiss.
            UIApplication.shared.isIdleTimerDisabled = !state.isPaused
        }
        .onChange(of: routingNote) { _, note in state.routingNote = note ?? "" }
        .onDisappear {
            upNext.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: state.positionSec) { _, position in
            upNext.onProgress(positionSec: position, durationSec: state.durationSec)
        }
        .onChange(of: state.isPaused) { _, paused in
            // Paused → let the idle timer run again (a long-paused frame should be allowed to
            // hand off to the screensaver, same as the native player); playing → hold it.
            UIApplication.shared.isIdleTimerDisabled = !paused
            pauseInfoTask?.cancel()
            if paused {
                pauseInfoTask = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { return }
                    showPauseInfo = true
                }
            } else {
                showPauseInfo = false
            }
        }
    }
}

/// Bottom transport bar: title, scrubber, elapsed/remaining time, play/pause indicator.
private struct PlayerControlsOverlay: View {
    @ObservedObject var state: MPVPlaybackState

    var body: some View {
        // Floating glass transport bar (HIG revamp): mirrors the native AVPlayerViewController
        // tvOS 26 chrome — an inset Liquid Glass panel over the video instead of the old
        // full-width black gradient.
        VStack(alignment: .leading, spacing: 16) {
            Text(state.title)
                .font(.title3).bold()
                .lineLimit(1)

            HStack(spacing: 20) {
                Image(systemName: state.isPaused ? "pause.fill" : "play.fill")
                    .font(.title3)

                Text(timeString(state.positionSec))
                    .font(.callout).monospacedDigit()

                ProgressBar(fraction: state.fraction)
                    .frame(height: 10)

                Text("-\(timeString(max(state.durationSec - state.positionSec, 0)))")
                    .font(.callout).monospacedDigit()
            }

            Label("Swipe down for info", systemImage: "chevron.down")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.bottom, Theme.Spacing.xl)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
    }
}

/// Post-play screen shown when playback reaches the end without an autoplay hand-off
/// (Android TV `PostPlayOverlay` parity, simplified): replay or exit.
private struct PostPlayView: View {
    let title: String
    let poster: String?
    let onReplay: () -> Void
    let onExit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(alignment: .center, spacing: 48) {
                if let poster, !poster.isEmpty {
                    CachedAsyncImage(string: poster)
                        .frame(width: 260, height: 390)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 24) {
                    Text("That's the end of")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(title)
                        .font(.title).bold()
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .frame(maxWidth: 800, alignment: .leading)

                    Button {
                        dismiss()
                        onReplay()
                    } label: {
                        Label("Play Again", systemImage: "arrow.counterclockwise")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        // Dismissing the player screen tears the cover down with it —
                        // don't also dismiss the cover (competing transitions).
                        onExit()
                    } label: {
                        Label("Back to Details", systemImage: "chevron.backward")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(80)
        }
    }
}

/// Metadata card shown top-leading after playback has been paused for a moment: artwork, title,
/// episode line, stream/source info, and time remaining (Android TV `PauseOverlay` parity).
private struct PauseInfoCard: View {
    let context: PlaybackContext
    @ObservedObject var state: MPVPlaybackState

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            if let poster = context.poster, !poster.isEmpty {
                CachedAsyncImage(string: poster)
                    .frame(width: 140, height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Paused")
                    .font(.caption).bold()
                    .foregroundStyle(.white.opacity(0.7))
                Text(context.title)
                    .font(.title2).bold()
                    .lineLimit(2)
                if let season = context.season, let episode = context.episode {
                    Text("Season \(season) \u{00B7} Episode \(episode)")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                }
                if state.durationSec > 0 {
                    Text("\(remainingString) remaining")
                        .font(.callout).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }
                if let provider = context.providerName, !provider.isEmpty {
                    Text(provider)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: 860, alignment: .leading)
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private var remainingString: String {
        let total = Int(max(state.durationSec - state.positionSec, 0))
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

/// Top-trailing live diagnostics card (codec, resolution, fps, hwdec, bitrate, audio, cache).
private struct StreamInfoOverlayView: View {
    let info: StreamInfoSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stream Info")
                .font(.caption).bold()
                .foregroundStyle(.white.opacity(0.7))
            ForEach(info.rows, id: \.0) { row in
                HStack(alignment: .top, spacing: 12) {
                    Text(row.0)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 190, alignment: .leading)
                    Text(row.1)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding(24)
        .frame(maxWidth: 560, alignment: .leading)
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}

