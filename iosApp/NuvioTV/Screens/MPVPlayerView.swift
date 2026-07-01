import Combine
import SwiftUI
import UIKit
import Libmpv
import SharedCore

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

    /// Wired by the controller so the SwiftUI track picker can drive libmpv.
    var selectAudio: ((Int) -> Void)?
    var selectSubtitle: ((Int) -> Void)?
    var reclaimFocus: (() -> Void)?

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
    private var addedSubtitleUrls = Set<String>()
    private var fileLoaded = false
    private var skipSegments: [SkipSegment] = []

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
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
        endSeek()
        saveProgress(flush: true)
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
            ("ao", "audiounit"),
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
        fetchSkipSegments()
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
            requireSkipIntroEnabled: false
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
            playbackSpeed: 1.0
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
                if state.hasTracks { state.showTracks = true }
                handled = true
            case .downArrow:
                if let prompt = state.skipPrompt {
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
        if !handled { super.pressesBegan(presses, with: event) }
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

/// SwiftUI host for the libmpv player + transport overlay; presented full-screen over the stream picker.
struct MPVPlayerScreen: View {
    let context: PlaybackContext

    @StateObject private var state: MPVPlaybackState
    @Environment(\.dismiss) private var dismiss

    init(context: PlaybackContext) {
        self.context = context
        _state = StateObject(wrappedValue: MPVPlaybackState(title: context.title))
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

            if let prompt = state.skipPrompt {
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
        .fullScreenCover(isPresented: $state.showTracks, onDismiss: { state.reclaimFocus?() }) {
            TrackPickerView(state: state)
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

            if state.hasTracks {
                Label("Swipe up for audio & subtitles", systemImage: "chevron.up")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
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
        .background(Theme.Palette.accent, in: Capsule())
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}

/// Audio + subtitle track chooser, presented over the player. A normal SwiftUI focus context so its
/// buttons receive focus (unlike an overlay sibling to the UIKit player).
private struct TrackPickerView: View {
    @ObservedObject var state: MPVPlaybackState
    @Environment(\.dismiss) private var dismiss

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
            }
            .padding(60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
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
}
