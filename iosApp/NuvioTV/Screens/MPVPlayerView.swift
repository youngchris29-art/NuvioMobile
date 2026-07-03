import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

/// UserDefaults keys for device-local player tuning (Settings > Playback). Device-specific
/// hardware knobs, deliberately NOT synced.
enum PlayerTuning {
    static let bufferMBKey = "player.bufferMB"
    static let readaheadSecKey = "player.readaheadSec"
    static let matchFrameRateKey = "player.matchFrameRate"
}

/// Everything the player needs to render a stream and record watch progress for it.
struct PlaybackContext: Identifiable {
    let url: URL
    let title: String
    let contentType: String      // "movie" / "series"
    let parentMetaId: String
    let videoId: String
    let season: Int?
    let episode: Int?
    let poster: String?
    let background: String?
    let providerName: String?
    let providerAddonId: String?
    let streamTitle: String?
    let streamSubtitle: String?
    let externalSubtitles: [SubtitleFile]
    /// Binge group of the playing stream (steers next-episode auto-select toward the same release).
    var bingeGroup: String? = nil
    /// All episodes of the parent series (empty for movies) — enables next-episode autoplay.
    var episodes: [MetaVideo] = []

    var id: String { "\(videoId)|\(url.absoluteString)" }
}

/// An external subtitle file to side-load into the player.
struct SubtitleFile {
    let url: String
    let language: String
    let name: String?
}

/// One selectable audio or subtitle track.
struct PlayerTrack: Identifiable {
    let id: Int          // mpv track id; -1 means "off" (subtitles)
    let label: String
    let isSelected: Bool
}

/// A skippable segment (intro/recap/outro) resolved from `SkipIntroRepository`.
struct SkipSegment {
    let start: Double
    let end: Double
    let type: String
}

/// The currently-offered skip action (shown while playback is inside a `SkipSegment`).
struct SkipPrompt: Equatable {
    let label: String      // e.g. "Skip Intro"
    let targetSec: Double   // absolute seek target (segment end)
}

/// Live stream diagnostics read from libmpv properties (shown by the Stream Info overlay).
struct StreamInfoSnapshot: Equatable {
    var videoCodec = ""
    var resolution = ""
    var fps = ""
    var hwdec = ""
    var videoBitrate = ""
    var audio = ""
    var cache = ""

    var rows: [(String, String)] {
        [("Video", videoCodec), ("Resolution", resolution), ("Frame rate", fps),
         ("Hardware decode", hwdec), ("Video bitrate", videoBitrate),
         ("Audio", audio), ("Cache", cache)].filter { !$0.1.isEmpty }
    }
}

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
    @Published var showTracks: Bool = false

    /// Active skip prompt ("Skip Intro"/"Skip Outro") when playback is inside a known segment.
    @Published var skipPrompt: SkipPrompt?

    /// Playback-settings panel state (speed, subtitle/audio delay, diagnostics).
    @Published var playbackSpeed: Double = 1.0
    @Published var subtitleDelaySec: Double = 0
    @Published var audioDelaySec: Double = 0
    @Published var showStreamInfo: Bool = false
    @Published var streamInfo: StreamInfoSnapshot?

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
/// ±10s, up opens audio/subtitle tracks, Menu exits. Publishes position/duration/paused/buffering and
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
    private var playerSettingsWatcher: FlowWatcher?
    private var playerSettings: PlayerSettingsUiState?
    private var didAutoSelectTracks = false
    private var addedSubtitleUrls = Set<String>()
    private var fileLoaded = false
    /// Trakt scrobbling (no-ops while Trakt is disconnected — the shared repo checks auth).
    private var traktScrobbleItem: TraktScrobbleItem?
    private var traktScrobbleRequested = false
    private var skipSegments: [SkipSegment] = []
    /// Last raw eof-reached value (edge detection for the post-play cover).
    private var lastEofFlag = false

    /// Called when the user presses Menu, so the SwiftUI cover can dismiss.
    var onExit: (() -> Void)?

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

        setupMpv()
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
            command("loadfile", args: [context.url.absoluteString, "replace"])
            startPolling()
            flashControls()

            // Side-load subtitles fetched from installed subtitle addons (OpenSubtitles etc.).
            subtitleWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.addonSubtitles) { [weak self] emitted in
                guard let self, let subs = emitted as? [AddonSubtitle] else { return }
                self.addAddonSubtitles(subs)
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

        let options: [(String, String)] = [
            // Use the classic `gpu` output rather than `gpu-next` (libplacebo): on the tvOS
            // simulator libplacebo's vo asserts ("vo: hit program assert") on some streams. `gpu`
            // is the more stable backend (same fix that stabilized the trailer surface). Trade-off:
            // slightly less advanced HDR tone-mapping, in exchange for not crashing.
            ("vo", "gpu"),
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
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "track-list/count", MPV_FORMAT_INT64)

        mpv_set_wakeup_callback(mpv, { ctx in
            let vc = unsafeBitCast(ctx, to: MPVTVPlayerViewController.self)
            vc.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    // MARK: - Tracks

    private func refreshTracks() {
        guard mpv != nil else { return }
        // Don't mutate the track lists while the picker is open — reassigning them rebuilds the
        // SwiftUI list and snaps focus back to the top. New tracks are picked up on next open.
        guard !state.showTracks else { return }
        let count = getInt("track-list/count")
        var audio: [PlayerTrack] = []
        var subs: [PlayerTrack] = [PlayerTrack(id: -1, label: "Off", isSelected: getString("sid") == "no")]

        for i in 0..<count {
            let type = getString("track-list/\(i)/type") ?? ""
            let id = getInt("track-list/\(i)/id")
            let selected = getFlag("track-list/\(i)/selected")
            let label = trackLabel(index: i, fallbackId: id)
            if type == "audio" {
                audio.append(PlayerTrack(id: id, label: label, isSelected: selected))
            } else if type == "sub" {
                subs.append(PlayerTrack(id: id, label: label, isSelected: selected))
            }
        }
        state.audioTracks = audio
        state.subtitleTracks = subs.count > 1 ? subs : []
        autoSelectPreferredTracks()
    }

    /// Once, on first load: pick the audio/subtitle track matching the user's preferred languages
    /// (Settings > Audio & Subtitle Language) using the shared language matcher. Leaves mpv's own
    /// defaults when nothing matches or no preference is set.
    private func autoSelectPreferredTracks() {
        guard !didAutoSelectTracks, let settings = playerSettings, mpv != nil else { return }
        let count = getInt("track-list/count")
        guard count > 0 else { return }

        var audioTracks: [(id: Int, lang: String)] = []
        var subTracks: [(id: Int, lang: String)] = []
        for i in 0..<count {
            let type = getString("track-list/\(i)/type") ?? ""
            let id = getInt("track-list/\(i)/id")
            let lang = getString("track-list/\(i)/lang") ?? ""
            if type == "audio" { audioTracks.append((id, lang)) }
            else if type == "sub" { subTracks.append((id, lang)) }
        }
        guard !audioTracks.isEmpty || !subTracks.isEmpty else { return }
        didAutoSelectTracks = true

        let deviceLanguages = DeviceLanguagePreferences.shared.preferredLanguageCodes()

        // Audio: only worth switching when there's more than one option.
        if audioTracks.count > 1 {
            let targets = PlayerLanguagePreferencesKt.resolvePreferredAudioLanguageTargets(
                preferredAudioLanguage: settings.preferredAudioLanguage,
                secondaryPreferredAudioLanguage: settings.secondaryPreferredAudioLanguage,
                deviceLanguages: deviceLanguages,
                contentOriginalLanguage: nil
            )
            if let id = firstTrackId(matching: targets, in: audioTracks) {
                setMpvInt("aid", Int64(id))
            }
        }

        // Subtitles: enable the preferred-language track if one exists (targets empty for "Off").
        let subTargets = PlayerLanguagePreferencesKt.resolvePreferredSubtitleLanguageTargets(
            preferredSubtitleLanguage: settings.preferredSubtitleLanguage,
            secondaryPreferredSubtitleLanguage: settings.secondaryPreferredSubtitleLanguage,
            deviceLanguages: deviceLanguages
        )
        if !subTracks.isEmpty, let id = firstTrackId(matching: subTargets, in: subTracks) {
            setMpvInt("sid", Int64(id))
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
        var label = parts.isEmpty ? "Track \(fallbackId)" : parts.joined(separator: " \u{00B7} ")
        if !codec.isEmpty { label += " (\(codec))" }
        return label
    }

    private func selectAudio(_ id: Int) {
        guard mpv != nil else { return }
        var v = Int64(id)
        mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &v)
        refreshTracks()
    }

    /// Once the file is loaded: side-load stream-provided subtitles and kick off an addon subtitle fetch.
    private func onFileLoaded() {
        guard !fileLoaded else { return }
        fileLoaded = true
        for sub in context.externalSubtitles {
            subAdd(url: sub.url, title: sub.name ?? sub.language, lang: sub.language)
        }
        SubtitleRepository.shared.fetchAddonSubtitles(type: context.contentType, videoId: context.videoId)
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
        let fps = getDouble("container-fps")
        guard fps > 10, let window = view.window else { return }
        let width = getInt("video-params/w")
        let height = getInt("video-params/h")
        guard width > 0, height > 0 else { return }

        let codecName = (getString("video-codec") ?? "").lowercased()
        let codecType: CMVideoCodecType =
            (codecName.contains("hevc") || codecName.contains("265")) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        var extensions: [CFString: Any] = [:]
        let primaries = (getString("video-params/primaries") ?? "").lowercased()
        let gamma = (getString("video-params/gamma") ?? "").lowercased()
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
                guard let self, let item else { return }
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
        guard let item = traktScrobbleItem else { return }
        traktScrobbleItem = nil
        TraktScrobbleRepository.shared.scrobbleStop(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            item: item,
            progressPercent: currentProgressPercent()
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
        SkipIntroRepository.shared.getSkipIntervals(
            imdbId: context.parentMetaId,
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
        var added = false
        for sub in subs where !addedSubtitleUrls.contains(sub.url) {
            subAdd(url: sub.url, title: sub.display, lang: sub.language)
            added = true
        }
        if added { refreshTracks() }
    }

    private func subAdd(url: String, title: String, lang: String) {
        guard mpv != nil, !addedSubtitleUrls.contains(url) else { return }
        addedSubtitleUrls.insert(url)
        command("sub-add", args: [url, "auto", title, lang])
    }

    private func selectSubtitle(_ id: Int) {
        guard mpv != nil else { return }
        if id < 0 {
            checkError(mpv_set_property_string(mpv, "sid", "no"))
        } else {
            var v = Int64(id)
            mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &v)
        }
        refreshTracks()
    }

    // MARK: - Playback speed & A/V-subtitle timing

    private func setSpeed(_ speed: Double) {
        guard mpv != nil else { return }
        setMpvDouble("speed", speed)
        state.playbackSpeed = speed
    }

    private func setSubtitleDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        setMpvDouble("sub-delay", seconds)
        state.subtitleDelaySec = seconds
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

    private func buildStreamInfo() -> StreamInfoSnapshot {
        var info = StreamInfoSnapshot()
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
        guard let entry = WatchProgressRepository.shared.progressForVideo(videoId: context.videoId),
              !entry.isCompleted else { return }
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
            playbackSpeed: Float(state.playbackSpeed)
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
        let duration = getDouble("duration")
        let position = getDouble("time-pos")
        let paused = getFlag("pause")
        let coreIdle = getFlag("core-idle")
        let cacheWait = getFlag("paused-for-cache")

        state.durationSec = duration
        state.positionSec = max(position, 0)
        state.isPaused = paused
        state.isBuffering = cacheWait || (coreIdle && !paused)

        // Rising-edge detection: eof-reached STAYS true while keep-open holds the last frame, so
        // only propagate transitions — otherwise a dismissed post-play cover re-presents each tick.
        let ended = getFlag("eof-reached")
        if ended != lastEofFlag {
            lastEofFlag = ended
            state.isEnded = ended
        }

        if state.showStreamInfo {
            let info = buildStreamInfo()
            if info != state.streamInfo { state.streamInfo = info }
        }

        let now = ProcessInfo.processInfo.systemUptime
        if !paused, now - lastSaveUptime > 5 {
            lastSaveUptime = now
            saveProgress()
        }

        updateSkipPrompt(position: position)
    }

    /// Show a skip prompt while the playhead is inside a segment (leaving a 1s tail so the button
    /// disappears cleanly at the end).
    private func updateSkipPrompt(position: Double) {
        let active = skipSegments.first { position >= $0.start && position < $0.end - 1 }
        let prompt = active.map { SkipPrompt(label: skipLabel(for: $0.type), targetSec: $0.end) }
        if prompt != state.skipPrompt { state.skipPrompt = prompt }
    }

    private func skipLabel(for type: String) -> String {
        switch type.lowercased() {
        case "outro", "ed", "credits": return "Skip Outro"
        case "recap": return "Skip Recap"
        default: return "Skip Intro"
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
            case .upArrow:
                refreshTracks()
                state.showTracks = true
                handled = true
            case .downArrow:
                if state.upNextPlayNow?() == true {
                    handled = true
                } else if let prompt = state.skipPrompt {
                    seekAbsolute(prompt.targetSec)
                    state.skipPrompt = nil
                    flashControls()
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
        setFlag("pause", !getFlag("pause"))
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
        command("seek", args: [String(format: "%.3f", seconds), "relative"])
    }

    private func seekAbsolute(_ seconds: Double) {
        guard mpv != nil else { return }
        command("seek", args: [String(format: "%.3f", seconds), "absolute"])
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
        playerSettingsWatcher?.cancel()
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
                    DispatchQueue.main.async {
                        self.applyPendingResume()
                        self.onFileLoaded()
                        self.refreshTracks()
                    }
                }
                if id == MPV_EVENT_PROPERTY_CHANGE {
                    DispatchQueue.main.async { self.refreshTracks() }
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
    let onExit: () -> Void

    func makeUIViewController(context ctx: Context) -> MPVTVPlayerViewController {
        let controller = MPVTVPlayerViewController(context: context, state: state)
        controller.onExit = onExit
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

    @StateObject private var state: MPVPlaybackState
    @StateObject private var upNext: NextEpisodeEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showPauseInfo = false
    @State private var pauseInfoTask: Task<Void, Never>?

    init(context: PlaybackContext, onPlayNext: ((PlaybackContext) -> Void)? = nil) {
        self.context = context
        self.onPlayNext = onPlayNext
        _state = StateObject(wrappedValue: MPVPlaybackState(title: context.title))
        _upNext = StateObject(wrappedValue: NextEpisodeEngine(
            context: context,
            onPlayNext: onPlayNext ?? { _ in }
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MPVPlayerRepresentable(context: context, state: state) { dismiss() }
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

            if upNext.phase != .hidden {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        UpNextCard(engine: upNext)
                            .padding(60)
                    }
                }
                .transition(.opacity)
            } else if let prompt = state.skipPrompt {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        SkipPromptPill(label: prompt.label)
                            .padding(60)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.skipPrompt)
        .animation(.easeInOut(duration: 0.25), value: upNext.phase)
        .animation(.easeInOut(duration: 0.25), value: showPauseInfo)
        .animation(.easeInOut(duration: 0.25), value: state.showStreamInfo)
        .fullScreenCover(isPresented: $state.showTracks, onDismiss: { state.reclaimFocus?() }) {
            TrackPickerView(state: state, engine: upNext, canSwitchStreams: onPlayNext != nil)
        }
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
            // Start the orchestration whenever a presenter can swap contexts — autoplay needs
            // episodes, but source switching works for movies too (the engine no-ops the rest).
            if onPlayNext != nil {
                upNext.start(state: state)
            }
        }
        .onDisappear { upNext.stop() }
        .onChange(of: state.positionSec) { _, position in
            upNext.onProgress(positionSec: position, durationSec: state.durationSec)
        }
        .onChange(of: state.isPaused) { _, paused in
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
                    .frame(height: 8)

                Text("-\(timeString(max(state.durationSec - state.positionSec, 0)))")
                    .font(.callout).monospacedDigit()
            }

            Label("Swipe up for audio, subtitles & playback settings", systemImage: "chevron.up")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
        )
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

/// Bottom-trailing "Skip Intro/Outro" pill. The chevron hints the press-down gesture that triggers
/// the skip (the libmpv player owns the remote, so a focusable button would fight it).
private struct SkipPromptPill: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.title3).bold()
            Image(systemName: "chevron.down.circle.fill")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        // Accent-tinted Liquid Glass over the video (matches the up-next card treatment).
        .glassEffect(.regular.tint(Theme.Palette.accent.opacity(0.75)), in: .capsule)
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
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

/// Playback-settings panel presented over the player: audio/subtitle tracks, playback speed,
/// subtitle & audio delay, episode jump, source switching, and the stream-info toggle. A normal
/// SwiftUI focus context so its buttons receive focus (unlike an overlay sibling to the UIKit player).
private struct TrackPickerView: View {
    @ObservedObject var state: MPVPlaybackState
    @ObservedObject var engine: NextEpisodeEngine
    /// True when the presenter can swap playback contexts (episode jump / source switching).
    let canSwitchStreams: Bool
    @Environment(\.dismiss) private var dismiss

    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                if !state.audioTracks.isEmpty {
                    section(title: "Audio", tracks: state.audioTracks) { id in
                        state.selectAudio?(id)
                        dismiss()
                    }
                }
                if !state.subtitleTracks.isEmpty {
                    section(title: "Subtitles", tracks: state.subtitleTracks) { id in
                        state.selectSubtitle?(id)
                        dismiss()
                    }
                }
                speedSection
                timingSection
                if canSwitchStreams, !engine.episodes.isEmpty {
                    episodesSection
                }
                if canSwitchStreams {
                    sourcesSection
                }
                diagnosticsSection
            }
            .padding(60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }

    // MARK: - Episodes (jump to any aired episode)

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Episodes").font(.title2).bold().foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(sortedEpisodes.enumerated()), id: \.offset) { _, episode in
                        let isCurrent = isCurrentEpisode(episode)
                        Button {
                            guard !isCurrent else { return }
                            engine.jumpToEpisode(episode)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                if isCurrent {
                                    Image(systemName: "play.fill")
                                }
                                Text(episodeChipLabel(episode))
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
            Text("Jumping finds a stream automatically and switches playback.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var sortedEpisodes: [MetaVideo] {
        engine.episodes
            .compactMap { video -> (MetaVideo, Int, Int)? in
                guard let s = video.season?.value, let e = video.episode?.value else { return nil }
                return (video, s, e)
            }
            .sorted { a, b in a.1 == b.1 ? a.2 < b.2 : a.1 < b.1 }
            .map { $0.0 }
    }

    private func isCurrentEpisode(_ episode: MetaVideo) -> Bool {
        guard let s = episode.season?.value, let e = episode.episode?.value else { return false }
        return s == engine.currentSeason && e == engine.currentEpisode
    }

    private func episodeChipLabel(_ episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return "S\(s)E\(e)"
        }
        return episode.title
    }

    // MARK: - Sources (switch the current video's stream)

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text("Sources").font(.title2).bold().foregroundStyle(.white)
                if engine.sourcesLoading { ProgressView() }
            }
            if engine.sources.isEmpty && !engine.sourcesLoading {
                Text("No alternate sources found yet.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
            ForEach(Array(engine.sources.prefix(12).enumerated()), id: \.offset) { _, stream in
                sourceRow(stream)
            }
            Text("Switching resumes from your last saved position.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .onAppear { engine.loadSources() }
    }

    private func sourceRow(_ stream: StreamItem) -> some View {
        let urlString: String? = stream.playableDirectUrl
        let isCurrent = urlString == engine.currentUrlString
        return Button {
            guard !isCurrent else { return }
            if engine.playSource(stream) { dismiss() }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: isCurrent ? "play.circle.fill" : "arrow.triangle.2.circlepath")
                VStack(alignment: .leading, spacing: 2) {
                    Text(stream.streamLabel).lineLimit(1)
                    Text(stream.addonName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text("Playing")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    private func section(title: String, tracks: [PlayerTrack], onSelect: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2).bold().foregroundStyle(.white)
            ForEach(tracks) { track in
                Button { onSelect(track.id) } label: {
                    HStack(spacing: 16) {
                        Image(systemName: track.isSelected ? "checkmark.circle.fill" : "circle")
                        Text(track.label).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: 900, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Playback Speed").font(.title2).bold().foregroundStyle(.white)
            HStack(spacing: 12) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Button { state.setSpeed?(speed) } label: {
                        HStack(spacing: 8) {
                            if state.playbackSpeed == speed {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(String(format: "%g\u{00D7}", speed))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Timing").font(.title2).bold().foregroundStyle(.white)
            delayRow(title: "Subtitle Delay", value: state.subtitleDelaySec, step: 0.5, limit: 30) {
                state.setSubtitleDelay?($0)
            }
            delayRow(title: "Audio Delay", value: state.audioDelaySec, step: 0.25, limit: 10) {
                state.setAudioDelay?($0)
            }
            Text("Positive values delay the track; negative values play it earlier.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func delayRow(
        title: String, value: Double, step: Double, limit: Double,
        apply: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .foregroundStyle(.white)
                .frame(width: 320, alignment: .leading)
            Button { apply(max(-limit, value - step)) } label: { Image(systemName: "minus") }
            Text(value == 0 ? "0.00 s" : String(format: "%+.2f s", value))
                .foregroundStyle(.white)
                .monospacedDigit()
                .frame(width: 180)
            Button { apply(min(limit, value + step)) } label: { Image(systemName: "plus") }
            if value != 0 {
                Button("Reset") { apply(0) }
            }
        }
        .buttonStyle(.bordered)
        .font(.title3)
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diagnostics").font(.title2).bold().foregroundStyle(.white)
            Button {
                state.showStreamInfo.toggle()
                dismiss()
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: state.showStreamInfo ? "checkmark.circle.fill" : "info.circle")
                    Text(state.showStreamInfo ? "Hide Stream Info" : "Show Stream Info")
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
    }
}
