import SwiftUI
import Combine
import AVFoundation
import AVKit
import SharedCore

/// A looping, controls-free trailer surface behind the Detail hero, backed by **AVPlayer**. Starts
/// muted and follows the shared `HeroTrailerAudioState` (same singleton the mobile app's hero
/// trailer uses) from then on, so the user's mute/unmute choice persists across titles for the
/// session. The Siri Remote's play/pause button controls mute/unmute.
///
/// This replaced an earlier libmpv/Vulkan implementation: a second Vulkan (MoltenVK) context running
/// alongside an interactive SwiftUI screen asserts on the tvOS simulator whenever Detail re-renders
/// (e.g. toggling "In Library"). AVPlayer renders through Metal/CoreAnimation natively, coexists with
/// SwiftUI, and simply shows nothing (never crashes) if a stream fails. It needs an AVPlayer-friendly
/// URL — the shared resolver now provides `TrailerPlaybackSource.progressiveUrl` (H.264/MP4 or HLS).
///
/// `onFailure` fires if the trailer can't start, so the host removes it and keeps the static backdrop.
/// It carries a `TrailerFailureReport` (BUG-46/B2) so the host can tell a transient playback failure
/// from "this title genuinely has nothing to play" when it decides what to remember.

/// A UIView whose backing layer is an `AVPlayerLayer` (so it resizes with SwiftUI layout for free).
final class TrailerPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// Phase 0 (BUG-46): ground truth for the live-pipeline leak probe, independent of the
    /// `Coordinator.attach`/`teardown()` bookkeeping — a `liveViews` count that climbs while
    /// browsing proves the leak even if some future attach/teardown accounting drifts.
    override init(frame: CGRect) {
        super.init(frame: frame)
        if TrailerProbe.enabled {
            let snap = TrailerPipelineCounters.shared.viewCreated()
            NSLog("[TrailerPipeline] view created live=%d players=%d", snap.liveViews, snap.livePlayers)
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        if TrailerProbe.enabled {
            let snap = TrailerPipelineCounters.shared.viewCreated()
            NSLog("[TrailerPipeline] view created live=%d players=%d", snap.liveViews, snap.livePlayers)
        }
    }

    deinit {
        if TrailerProbe.enabled {
            let snap = TrailerPipelineCounters.shared.viewDestroyed()
            NSLog("[TrailerPipeline] view destroyed live=%d players=%d", snap.liveViews, snap.livePlayers)
        }
    }
}

/// What a failing trailer surface hands its host (BUG-46/B2).
///
/// The Phase 0 `TrailerFailureCause` alone can't answer the two questions the inline card's negative
/// cache has to ask — "was this an HTTP 404?" and "was it OUR loopback playlist server that 404'd?"
/// — because the status code lives in `AVPlayerItem.errorLog()`, never on the `NSError` for HLS
/// playback. Rather than reshape the Phase 0 enum (whose classification is deliberately
/// observation-only, and whose `logSuffix` output the soak harness greps), the coordinator reports
/// the cause *together with* the two extra facts it already reads for the `[TrailerPipeline] fail`
/// line.
struct TrailerFailureReport {
    let cause: TrailerFailureCause
    /// `AVPlayerItemErrorLogEvent.errorStatusCode` of the last error-log event, when there was one.
    let httpStatus: Int?
    /// The URL this surface was attached to — the raw string, so it is present even for `.badURL`.
    let urlString: String?
}

struct TrailerHeroPlayer: UIViewRepresentable {
    let urlString: String
    var onFailure: (TrailerFailureReport) -> Void = { _ in }
    /// `true` (the default, and what the Detail hero uses) keeps the endless `AVPlayerLooper` this
    /// view was written for. `false` plays the item exactly once and reports the end through
    /// `onPlaybackEnded` — the inline catalog card uses that to collapse itself back to a poster
    /// instead of looping a trailer under the user's focus forever.
    var loops: Bool = true
    /// Only ever fires when `loops == false`; main-queue.
    var onPlaybackEnded: (() -> Void)? = nil

    /// UX-9: our YouTube trailer encodes bake letterboxing directly into the frame (2.39:1 film
    /// inside a 16:9 container), so `.resizeAspectFill` alone still shows black bars — it fills the
    /// *container* while the bars stay part of the *image*. Upstream Compose hides them with a flat
    /// parity scale on the trailer surface (DetailHero.kt:145–153, `scaleX = scaleY = 1.08f`), and
    /// this constant mirrors it exactly.
    ///
    /// It is now the **floor**, not the answer: a flat 1.08 leaves most of a 2.39:1 bar on screen,
    /// while the ~1.33 crop that would undo one exactly would eat >20% of a genuinely-16:9 trailer.
    /// Neither was ever knowable from metadata (innertube's coded dimensions, our synthesized
    /// `RESOLUTION=`, and `presentationSize` all read 1920x1080 for a bars-baked-into-16:9 encode —
    /// the bars *are* the picture as far as AVFoundation is concerned), so `TrailerLetterboxProbe`
    /// measures the decoded luma instead and every surface renders at `max(measured, parityZoom)`.
    /// A source with no bars therefore still renders byte-identically to what shipped before.
    static let parityZoom: CGFloat = 1.08

    func makeUIView(context: Context) -> TrailerPlayerUIView {
        let view = TrailerPlayerUIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        // Never set before UX-9: once the trailer surface is scaled past fill (see `parityZoom`
        // above) to hide baked-in letterbox bars, the overscaled edges must not bleed past this
        // view's bounds into whatever sits around it. Note the zoom itself now lives on the player
        // LAYER's affine transform, which `masksToBounds` cannot contain (a layer masks its content
        // *before* its own transform applies) — the effective clip is the host's, i.e. the inline
        // tile's `.clipShape` (InlineTrailerCard) or the screen edges (Detail hero / full-screen).
        // This stays set anyway: it is what keeps the un-zoomed aspect-fill crop honest.
        view.clipsToBounds = true
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view, urlString: urlString, loops: loops)
        return view
    }

    func updateUIView(_ uiView: TrailerPlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: TrailerPlayerUIView, coordinator: Coordinator) {
        coordinator.teardown()
        // BUG-46/B1 belt-and-braces: `teardown()` detaches through its own weak handle on the view,
        // which is already nil on the deinit-driven path. The layer is right here on this one, so
        // detach it directly too — an AVPlayerLayer still pointing at a player is a live decode
        // pipeline no matter who else let go.
        uiView.playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure, onPlaybackEnded: onPlaybackEnded)
    }

    /// Owns the AVPlayer, looping, and failure detection.
    final class Coordinator {
        private let onFailure: (TrailerFailureReport) -> Void
        private let onPlaybackEnded: (() -> Void)?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var statusObservation: NSKeyValueObservation?
        private var failureObserver: NSObjectProtocol?
        private var endObserver: NSObjectProtocol?
        private var watchdog: Timer?
        private var audioWatcher: FlowWatcher?
        private var started = false
        private var failed = false
        private var ended = false
        /// The URL `attach()` was handed. Phase 0 logs it (redacted) in `teardown()`; B2 reports it
        /// with a failure so the host can tell a loopback-repack URL from a direct googlevideo one.
        private var attachedURLString: String?
        /// BUG-46/B1: the view whose `AVPlayerLayer` this coordinator's player is wired into, so
        /// `teardown()` can unwire it. Weak — the view owns nothing here and outlives nothing.
        private weak var attachedView: TrailerPlayerUIView?
        /// UX-9: measures the baked-in letterbox bars off the decoded frames and drives the layer's
        /// zoom. Lives for exactly one attach, like everything else here.
        private var letterboxProbe: TrailerLetterboxProbe?
        /// Instrumentation pairing guard: `teardown()` runs twice per lifecycle (explicit
        /// `dismantleUIView` + `deinit`), so the counter must decrement exactly once per counted
        /// `attach()` or the live-pipeline gauge undercounts (Codex round 1).
        private var attachCounted = false

        init(onFailure: @escaping (TrailerFailureReport) -> Void, onPlaybackEnded: (() -> Void)? = nil) {
            self.onFailure = onFailure
            self.onPlaybackEnded = onPlaybackEnded
        }

        func attach(to view: TrailerPlayerUIView, urlString: String, loops: Bool = true) {
            attachedURLString = urlString
            attachedView = view
            guard let url = URL(string: urlString) else { fail(.badURL); return }

            if TrailerProbe.enabled {
                attachCounted = true
                let snap = TrailerPipelineCounters.shared.attach()
                NSLog("[TrailerPipeline] attach live=%d views=%d url=%@", snap.livePlayers, snap.liveViews, TrailerProbe.redactedHost(urlString))
            }

            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.allowsExternalPlayback = false

            // Seed with the shared preference's current value (rather than always hardcoding muted)
            // so re-attaching (e.g. returning to a title after unmuting) doesn't flash muted first.
            let audioState = HeroTrailerAudioState.shared
            queue.isMuted = (audioState.muted.value_ as? KotlinBoolean)?.boolValue ?? true
            audioWatcher = FlowWatcherKt.watch(audioState.muted) { [weak self] emitted in
                guard let self, let boxed = emitted as? KotlinBoolean else { return }
                self.player?.isMuted = boxed.boolValue
            }

            if loops {
                looper = AVPlayerLooper(player: queue, templateItem: item)
            } else {
                // Single pass: no looper, and the end-of-item notification is the signal the host
                // waits on. (`AVPlayerLooper` swallows this notification by design, which is why
                // the two paths can't share an install.)
                queue.insert(item, after: nil)
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in self?.finish() }
            }
            view.playerLayer.player = queue
            player = queue

            statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
                switch observed.status {
                case .failed: self?.fail(.itemFailed(observed.error as NSError?), item: observed)
                case .readyToPlay:
                    self?.started = true
                    #if DEBUG
                    // UX-4c verification: log the actual resolved stream resolution. With the
                    // master-playlist bug the presentationSize sat at ~854x480; the pinned
                    // top-resolution variant should report ~1920x1080. presentationSize can be
                    // .zero at the readyToPlay edge, so log a beat later.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak observed] in
                        guard let item = observed else { return }
                        let size = item.presentationSize
                        // NSLog (not print): lands in unified logging, so `log show` can read it
                        // even when no console pty is attached.
                        NSLog("[TrailerQuality] presentationSize=%dx%d", Int(size.width), Int(size.height))
                    }
                    #endif
                default: break
                }
            }
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                self?.fail(.failedToPlayToEnd(error), item: item)
            }

            queue.play()

            // UX-9: start measuring the baked-in bars. Anchored to `play()`, not `readyToPlay`, for
            // the same reason the presentationSize probe below is — and the probe reads
            // `player.currentItem` on every sample rather than capturing `item`, so the `loops`
            // path measures the copies `AVPlayerLooper` actually plays.
            letterboxProbe = TrailerLetterboxProbe(view: view, player: queue, urlString: urlString, surface: "hero")
            letterboxProbe?.start()

            #if DEBUG
            // UX-4c verification: log the resolved stream's actual resolution. Anchored to
            // play() rather than the readyToPlay KVO case above, because that observation
            // (options: [.new]) demonstrably never fires for this item (the watchdog below
            // only survives via timeControlStatus) — see BUG notes in the beta.9 batch.
            // Read the QUEUE's current item, not the template `item`: with loops == true the
            // AVPlayerLooper plays copies of the template, whose own presentationSize stays 0x0.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak queue] in
                guard let current = queue?.currentItem else { return }
                let size = current.presentationSize
                NSLog("[TrailerQuality] presentationSize=%dx%d", Int(size.width), Int(size.height))
            }
            #endif

            // Insurance: if nothing is playing within a few seconds, give up (static fallback).
            let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
                guard let self else { return }
                if !self.started && self.player?.timeControlStatus != .playing {
                    self.fail(.watchdogTimeout)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        }

        /// Phase 0 classified the failure so the log line reads as a diagnosis; B2 now also *reports*
        /// it, so the host's negative cache can distinguish "this stream broke" from "this title has
        /// nothing to play". The HTTP status is read unconditionally now (it used to be probe-gated):
        /// it is the only channel that surfaces an evicted-token 404 from the loopback repack server,
        /// and B2's invalidation has to work on a tester's release sideload with the knob off.
        private func fail(_ cause: TrailerFailureCause, item: AVPlayerItem? = nil) {
            guard !failed, !ended else { return }
            failed = true
            let httpStatus = item?.errorLog()?.events.last?.errorStatusCode
            if TrailerProbe.enabled {
                let snap = TrailerPipelineCounters.shared.failure(cause: cause.tag)
                NSLog("[TrailerPipeline] fail cause=%@ %@ live=%d", cause.tag, cause.logSuffix(httpStatus: httpStatus), snap.livePlayers)
            }
            let report = TrailerFailureReport(cause: cause, httpStatus: httpStatus, urlString: attachedURLString)
            DispatchQueue.main.async { self.onFailure(report) }
        }

        /// Non-looping playback reached the end of the item — once only, and never after a failure.
        private func finish() {
            guard !failed, !ended else { return }
            ended = true
            guard let onPlaybackEnded else { return }
            DispatchQueue.main.async { onPlaybackEnded() }
        }

        func teardown() {
            if TrailerProbe.enabled, attachCounted {
                attachCounted = false
                let snap = TrailerPipelineCounters.shared.teardown()
                NSLog("[TrailerPipeline] teardown live=%d views=%d url=%@", snap.livePlayers, snap.liveViews, attachedURLString.map(TrailerProbe.redactedHost) ?? "-")
            }
            watchdog?.invalidate()
            watchdog = nil
            statusObservation?.invalidate()
            statusObservation = nil
            if let failureObserver {
                NotificationCenter.default.removeObserver(failureObserver)
                self.failureObserver = nil
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            audioWatcher?.cancel()
            audioWatcher = nil
            letterboxProbe?.stop()
            letterboxProbe = nil
            player?.pause()
            // BUG-46/B1: pausing and dropping our reference is NOT enough to end the decode
            // pipeline. The queue still holds its items, the looper still holds its copies of the
            // template, and — the one that actually keeps the pipeline alive — the view's
            // AVPlayerLayer still points at the player. `FullScreenTrailerSurface.dismantleUIView`
            // has always done the layer detach, and it has never leaked; this is exact parity with
            // it. Order matters: disable the looper first (it re-enqueues items as they drain, so
            // draining the queue underneath a live looper is a race), then empty the queue, then
            // unwire the layer.
            looper?.disableLooping()
            looper = nil
            player?.removeAllItems()
            attachedView?.playerLayer.player = nil
            attachedView = nil
            player = nil
        }

        deinit { teardown() }
    }
}

/// Full-screen trailer playback with sound — presented from either the Detail action row's
/// "Watch Trailer" button (the hero trailer, already resolved for the muted background loop) or a
/// "Trailers & Extras" row item (resolved on demand). The presenting `fullScreenCover` handles
/// Menu-to-dismiss; the Siri Remote's play/pause button toggles pause; playback end reports out so
/// the host can dismiss instead of resting on a black end frame.
///
/// UX-9: this replaced an `AVPlayerViewController`. Our YouTube encodes bake letterbox bars into
/// the frame (see `TrailerHeroPlayer.parityZoom`), and the standard controller exposes no way to
/// overscale its video layer without also scaling the transport chrome — so full-screen trailers
/// were the one surface that still showed bars. A raw `AVPlayerLayer` gets the same
/// aspect-fill + measured-zoom treatment as every other trailer surface (`TrailerLetterboxProbe`
/// drives the layer transform; full-screen and ignoring the safe area, the screen edges do the
/// clipping). Trade-off, accepted deliberately: no scrub
/// bar — trailers are 1-2 minute clips and Back already exits. The controller swap also retires
/// BUG-18's display-criteria workaround by construction: a bare layer never renegotiates HDMI.
/// Deliberately a separate `AVPlayer` instance from `TrailerHeroPlayer` above (always unmuted —
/// FEAT-11's default only governs the background loop) — the two never run concurrently, so
/// there's no doubled decode/audio, and each keeps its own simple, single-purpose lifecycle.
struct FullScreenTrailerPlayer: View {
    let urlString: String
    var onPlaybackEnded: () -> Void = {}

    /// Stable across body re-evals (@State keeps the instance); bridges the play/pause command
    /// to the representable's player without making the surface observable.
    @State private var control = FullScreenTrailerControl()

    var body: some View {
        // UX-9: no `.scaleEffect` any more — the zoom is measured per stream and applied to the
        // player layer itself (`TrailerLetterboxProbe`), with `parityZoom` as its floor, so this
        // surface still renders exactly as before for a bar-free 16:9 source.
        FullScreenTrailerSurface(urlString: urlString, control: control, onPlaybackEnded: onPlaybackEnded)
            .ignoresSafeArea()
            .onPlayPauseCommand { control.togglePause() }
    }
}

/// Holds a weak handle to the full-screen player so the SwiftUI layer can toggle pause.
final class FullScreenTrailerControl {
    weak var player: AVPlayer?

    func togglePause() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
    }
}

private struct FullScreenTrailerSurface: UIViewRepresentable {
    let urlString: String
    let control: FullScreenTrailerControl
    let onPlaybackEnded: () -> Void

    func makeUIView(context: Context) -> TrailerPlayerUIView {
        let view = TrailerPlayerUIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        // UX-9: matches the inline/hero representable. The screen edges are what actually clip the
        // measured zoom here (a layer masks its content before its own transform applies — see the
        // note in `TrailerHeroPlayer.makeUIView`); this is set so the surface never *depends* on
        // being full-screen for its aspect-fill crop to stay inside its own bounds.
        view.clipsToBounds = true
        view.playerLayer.videoGravity = .resizeAspectFill
        if let url = URL(string: urlString) {
            let player = AVPlayer(url: url)
            player.isMuted = false
            view.playerLayer.player = player
            control.player = player
            context.coordinator.observeEnd(of: player, onEnded: onPlaybackEnded)
            context.coordinator.startLetterboxProbe(view: view, player: player, urlString: urlString)
            // Phase 0 (BUG-46): full-screen plays share `TrailerPipelineCounters` with the
            // inline/hero surfaces (`TrailerHeroPlayer.Coordinator`) so a full-screen "Watch
            // Trailer" doesn't misread as a leak in the inline/hero attach/teardown numbers.
            if TrailerProbe.enabled {
                let snap = TrailerPipelineCounters.shared.attach()
                NSLog("[TrailerPipeline] attach(full) live=%d views=%d url=%@", snap.livePlayers, snap.liveViews, TrailerProbe.redactedHost(urlString))
            }
            player.play()
        }
        return view
    }

    func updateUIView(_ uiView: TrailerPlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: TrailerPlayerUIView, coordinator: Coordinator) {
        coordinator.teardown()
        uiView.playerLayer.player?.pause()
        uiView.playerLayer.player = nil
        if TrailerProbe.enabled {
            let snap = TrailerPipelineCounters.shared.teardown()
            NSLog("[TrailerPipeline] teardown(full) live=%d views=%d", snap.livePlayers, snap.liveViews)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var endObserver: NSObjectProtocol?
        private var letterboxProbe: TrailerLetterboxProbe?

        func observeEnd(of player: AVPlayer, onEnded: @escaping () -> Void) {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in onEnded() }
        }

        /// UX-9: same probe the inline/hero surfaces use, so all three get their zoom from one
        /// implementation (and share its per-URL session cache — a title watched full-screen right
        /// after its inline preview starts already measured).
        func startLetterboxProbe(view: TrailerPlayerUIView, player: AVPlayer, urlString: String) {
            letterboxProbe = TrailerLetterboxProbe(view: view, player: player, urlString: urlString, surface: "full")
            letterboxProbe?.start()
        }

        func teardown() {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            letterboxProbe?.stop()
            letterboxProbe = nil
        }

        deinit { teardown() }
    }
}

// MARK: - UX-9: measured letterbox zoom

/// Session memo of measured zooms, keyed by the exact playback URL string.
///
/// Re-focusing a card (or opening the same trailer full-screen) starts at the measured zoom with no
/// ramp; only the first play of a stream in a session ever ramps. Capacity mirrors
/// `TrailerResolutionCache` for the same reason — a marathon browse touches far more titles than it
/// plays, and these entries are a `CGFloat` each.
///
/// NSLock-guarded rather than `@MainActor`, matching `TrailerPipelineCounters`: the probe reads it
/// from `TrailerHeroPlayer.Coordinator.attach`, which is not actor-isolated.
final class TrailerZoomCache: @unchecked Sendable {
    static let shared = TrailerZoomCache()

    private let lock = NSLock()
    private var values: [String: CGFloat] = [:]
    private var insertionOrder: [String] = []
    private static let capacity = 200

    private init() {}

    func zoom(for url: String) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        return values[url]
    }

    func store(_ zoom: CGFloat, for url: String) {
        lock.lock(); defer { lock.unlock() }
        if values[url] == nil { insertionOrder.append(url) }
        values[url] = zoom
        while insertionOrder.count > Self.capacity, let oldest = insertionOrder.first {
            values[oldest] = nil
            insertionOrder.removeFirst()
        }
    }
}

/// UX-9: measures the letterbox/pillarbox bars **baked into the decoded frames** of a trailer and
/// turns them into the zoom its player layer needs to crop them away.
///
/// Why pixels, and not metadata: a 2.39:1 film letterboxed inside a 16:9 encode reports 1920x1080
/// through every channel we have (innertube's `adaptiveFormats[].width/height`, the `RESOLUTION=` we
/// synthesize from them in `TrailerLocalHLS`, `AVPlayerItem.presentationSize`) — the bars *are* the
/// picture as far as AVFoundation is concerned. A natively 2.39:1-*coded* stream, meanwhile, already
/// fills a 16:9 layer under `.resizeAspectFill` and needs no zoom at all. The two cases are
/// indistinguishable except in the decoded luma, which is why this exists at all.
///
/// One-shot per stream: five samples, a measurement, the output detached, timer gone. Everything
/// after that is a cache read.
final class TrailerLetterboxProbe {
    /// Ceiling on the measured zoom. DERIVED, not tuned: the widest format anyone bakes into a 16:9
    /// container is ~2.55:1, and 2.55 / (16/9) = 1.435. (The 2.39:1 scope trailers UX-9 was filed
    /// over land at 1.344.) Anything past this is a measurement gone wrong, not a real bar.
    static let maxZoom: CGFloat = 1.45
    /// Every trailer surface is 16:9: the inline tile by construction (UX-4a sizes it
    /// `posterHeight * 16/9`), the Detail hero and full-screen surfaces because they are the screen.
    private static let cardAspect: Double = 16.0 / 9.0

    private static let sampleTarget = 5
    /// Trailers open on black, so sampling starts a beat in.
    private static let firstSampleSeconds: Double = 1.0
    private static let tickInterval: TimeInterval = 0.5
    /// Give up after this many ticks (12s) if playback never delivers enough frames — the surface
    /// simply keeps the `parityZoom` floor, and nothing is cached, so a later play measures again.
    private static let maxTicks = 24
    /// Mean 8-bit luma at or below this reads as a black bar. Well above sensor/encoder noise on a
    /// true black bar, well below any real picture content.
    private static let blackLuma: Double = 16
    /// No plausible baked bar eats more than a quarter of the frame per edge (the 2.55:1 worst case
    /// is ~15%), so the scan stops there rather than walking into the picture on a dark shot.
    private static let maxBarFraction: Double = 0.25
    /// Bars thinner than this are encoder rounding, not letterboxing.
    private static let minBarFraction: Double = 0.01

    /// Bar thickness per edge, as a fraction of the frame.
    private struct Bars {
        let top: Double
        let bottom: Double
        let left: Double
        let right: Double
    }

    private weak var view: TrailerPlayerUIView?
    private weak var player: AVPlayer?
    private let urlString: String
    /// `hero` (inline card + Detail hero) or `full` — log disambiguation only.
    private let surface: String

    private var output: AVPlayerItemVideoOutput?
    private weak var sampledItem: AVPlayerItem?
    private var timer: Timer?
    private var ticks = 0
    private var samples: [Bars] = []
    private var frameSize: CGSize = .zero
    /// One measurement per probe: `tick()` can reach the sample target and the tick ceiling in the
    /// same pass, and a second `finish()` would re-log and re-animate an identical zoom.
    private var finished = false

    init(view: TrailerPlayerUIView, player: AVPlayer, urlString: String, surface: String) {
        self.view = view
        self.player = player
        self.urlString = urlString
        self.surface = surface
    }

    /// Applies the starting zoom (cached measurement, else the parity floor) and, when there is
    /// nothing cached, arms the sampler. Main-thread only.
    func start() {
        if let cached = TrailerZoomCache.shared.zoom(for: urlString) {
            apply(cached, animated: false)
            if TrailerProbe.enabled {
                NSLog("[TrailerZoom] cached applied=%.3f surface=%@ cardFrame=%@", cached, surface, cardFrameDescription())
            }
            return
        }
        // Parity floor first, un-animated: until the measurement lands, every surface renders
        // exactly what it rendered before UX-9.
        apply(TrailerHeroPlayer.parityZoom, animated: false)
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Idempotent: stops sampling and detaches the video output. Called from every teardown path.
    func stop() {
        timer?.invalidate()
        timer = nil
        detachOutput()
    }

    // MARK: Sampling

    private func tick() {
        ticks += 1
        defer { if ticks >= Self.maxTicks { finish() } }
        guard let player, let item = player.currentItem else { return }

        // Re-attach on item changes rather than capturing one item: with `loops == true` the
        // AVPlayerLooper plays *copies* of the template, so the item we were handed at attach
        // never produces a frame (same trap the `[TrailerQuality]` probe documents).
        if sampledItem !== item {
            detachOutput()
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
            item.add(output)
            self.output = output
            sampledItem = item
            samples.removeAll()
        }
        guard let output else { return }

        let time = item.currentTime()
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= Self.firstSampleSeconds else { return }
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }

        frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if let bars = Self.bars(in: buffer) { samples.append(bars) }
        if samples.count >= Self.sampleTarget { finish() }
    }

    /// Deliberately NOT requesting a downscaled (e.g. 160x90) output buffer: `AVPlayerItemVideoOutput`
    /// would fit the frame into whatever box we ask for, which for a natively-2.39:1 stream means
    /// *it* adds the very bars we are trying to detect. Native-size buffers with a sparse scan cost
    /// a few thousand byte reads per sample and are the only reading that can't lie.
    private static func bars(in buffer: CVPixelBuffer) -> Bars? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 32, height > 32, bytesPerRow >= width * 4 else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        // BGRA, Rec.709 luma coefficients.
        func luma(_ x: Int, _ y: Int) -> Double {
            let p = pixels + y * bytesPerRow + x * 4
            return 0.0722 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.2126 * Double(p[2])
        }
        func isBlackRow(_ y: Int) -> Bool {
            let step = max(1, width / 32)
            var sum = 0.0
            var count = 0
            var x = step / 2
            while x < width { sum += luma(x, y); count += 1; x += step }
            return count > 0 && sum / Double(count) <= Self.blackLuma
        }
        func isBlackColumn(_ x: Int) -> Bool {
            let step = max(1, height / 32)
            var sum = 0.0
            var count = 0
            var y = step / 2
            while y < height { sum += luma(x, y); count += 1; y += step }
            return count > 0 && sum / Double(count) <= Self.blackLuma
        }

        // A frame that is black through its own middle is a fade or a cut to black, not a
        // letterboxed picture — it can't tell us anything, so it isn't a sample.
        guard !isBlackRow(height / 2), !isBlackColumn(width / 2) else { return nil }

        let rowLimit = Int(Double(height) * Self.maxBarFraction)
        let columnLimit = Int(Double(width) * Self.maxBarFraction)
        var top = 0
        while top < rowLimit, isBlackRow(top) { top += 1 }
        var bottom = 0
        while bottom < rowLimit, isBlackRow(height - 1 - bottom) { bottom += 1 }
        var left = 0
        while left < columnLimit, isBlackColumn(left) { left += 1 }
        var right = 0
        while right < columnLimit, isBlackColumn(width - 1 - right) { right += 1 }

        return Bars(
            top: Double(top) / Double(height),
            bottom: Double(bottom) / Double(height),
            left: Double(left) / Double(width),
            right: Double(right) / Double(width)
        )
    }

    // MARK: Measurement

    private func finish() {
        guard !finished else { return }
        finished = true
        let collected = samples
        let size = frameSize
        stop()
        // Fewer than three usable samples is a stream that stalled or stayed dark; keep the floor
        // and cache nothing, so the next play of this URL measures again.
        guard collected.count >= 3, size.width > 0, size.height > 0 else { return }

        // A bar counts only if it is present in EVERY sample — hence `min`, not an average. A single
        // frame can be letterboxed by its own content (a black-bordered shot, a fade), and averaging
        // would let that fake a permanent bar.
        func edge(_ keyPath: KeyPath<Bars, Double>) -> Double {
            let value = collected.map { $0[keyPath: keyPath] }.min() ?? 0
            return value >= Self.minBarFraction ? value : 0
        }
        let top = edge(\.top), bottom = edge(\.bottom), left = edge(\.left), right = edge(\.right)

        let verticalContent = 1 - top - bottom
        let horizontalContent = 1 - left - right
        guard verticalContent > 0, horizontalContent > 0 else { return }

        // The zoom derives from the DETECTED BARS alone — never from the coded frame's aspect.
        // `.resizeAspectFill` already crops away any *native* aspect mismatch (a barless 1920×800
        // stream fills the card with zero help), so an aspect-ratio formula would over-crop
        // exactly those streams by up to ~35% (Codex round 3). Letterbox → 1/(1-top-bottom);
        // pillarbox → 1/(1-left-right); barless → 1.0 and the parity floor applies.
        let measured = max(1 / verticalContent, 1 / horizontalContent)
        let zoom = min(max(CGFloat(measured), TrailerHeroPlayer.parityZoom), Self.maxZoom)

        TrailerZoomCache.shared.store(zoom, for: urlString)
        apply(zoom, animated: true)

        if TrailerProbe.enabled {
            NSLog("[TrailerZoom] frame=%dx%d bars top=%.3f bottom=%.3f left=%.3f right=%.3f samples=%d measured=%.3f applied=%.3f surface=%@ cardFrame=%@",
                  Int(size.width), Int(size.height), top, bottom, left, right, collected.count,
                  measured, zoom, surface, cardFrameDescription())
        }
    }

    // MARK: Applying

    /// Render-only, by construction: an affine transform on the `AVPlayerLayer` scales what the
    /// layer draws and touches no layout — the same property `.scaleEffect` had, which is what makes
    /// this swap safe for UX-4a's morph geometry and BUG-29's expansion scroll.
    private func apply(_ zoom: CGFloat, animated: Bool) {
        guard let layer = view?.playerLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.25) }
        layer.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
        CATransaction.commit()
    }

    private func detachOutput() {
        if let output, let sampledItem { sampledItem.remove(output) }
        output = nil
        sampledItem = nil
    }

    /// Window coordinates of the surface, so the UX-9 measurement protocol's screenshot sampling
    /// knows exactly which rect to read.
    private func cardFrameDescription() -> String {
        guard let view else { return "{-}" }
        let rect = view.convert(view.bounds, to: nil)
        return String(format: "{%.0f,%.0f,%.0f,%.0f}", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    deinit { stop() }
}
