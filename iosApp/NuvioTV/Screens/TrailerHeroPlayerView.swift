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

/// A UIView whose backing layer is an `AVPlayerLayer` (so it resizes with SwiftUI layout for free).
final class TrailerPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct TrailerHeroPlayer: UIViewRepresentable {
    let urlString: String
    var onFailure: () -> Void = {}
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
    /// parity scale on the trailer surface (DetailHero.kt:145–153, `scaleX = scaleY = 1.08f`); this
    /// mirrors that constant exactly rather than re-deriving it. A computed ~1.33 crop (undoing a
    /// 2.39:1-in-16:9 letterbox exactly) was rejected: there's no signal that tells us a given
    /// trailer actually has bars, so it would just as happily eat >20% of a genuinely-16:9 trailer.
    static let parityZoom: CGFloat = 1.08

    func makeUIView(context: Context) -> TrailerPlayerUIView {
        let view = TrailerPlayerUIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        // Never set before UX-9: once the trailer surface is scaled past fill (see `parityZoom`
        // above) to hide baked-in letterbox bars, the overscaled edges must not bleed past this
        // view's bounds into whatever sits around it.
        view.clipsToBounds = true
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view, urlString: urlString, loops: loops)
        return view
    }

    func updateUIView(_ uiView: TrailerPlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: TrailerPlayerUIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure, onPlaybackEnded: onPlaybackEnded)
    }

    /// Owns the AVPlayer, looping, and failure detection.
    final class Coordinator {
        private let onFailure: () -> Void
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

        init(onFailure: @escaping () -> Void, onPlaybackEnded: (() -> Void)? = nil) {
            self.onFailure = onFailure
            self.onPlaybackEnded = onPlaybackEnded
        }

        func attach(to view: TrailerPlayerUIView, urlString: String, loops: Bool = true) {
            guard let url = URL(string: urlString) else { fail(); return }

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
                case .failed: self?.fail()
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
            ) { [weak self] _ in self?.fail() }

            queue.play()

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
                    self.fail()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        }

        private func fail() {
            guard !failed, !ended else { return }
            failed = true
            DispatchQueue.main.async { self.onFailure() }
        }

        /// Non-looping playback reached the end of the item — once only, and never after a failure.
        private func finish() {
            guard !failed, !ended else { return }
            ended = true
            guard let onPlaybackEnded else { return }
            DispatchQueue.main.async { onPlaybackEnded() }
        }

        func teardown() {
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
            player?.pause()
            player = nil
            looper = nil
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
/// aspect-fill + parity-zoom treatment as every other trailer surface (full-screen and ignoring
/// the safe area, the screen edges do the clipping). Trade-off, accepted deliberately: no scrub
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
        FullScreenTrailerSurface(urlString: urlString, control: control, onPlaybackEnded: onPlaybackEnded)
            .scaleEffect(TrailerHeroPlayer.parityZoom)
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
        view.playerLayer.videoGravity = .resizeAspectFill
        if let url = URL(string: urlString) {
            let player = AVPlayer(url: url)
            player.isMuted = false
            view.playerLayer.player = player
            control.player = player
            context.coordinator.observeEnd(of: player, onEnded: onPlaybackEnded)
            player.play()
        }
        return view
    }

    func updateUIView(_ uiView: TrailerPlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: TrailerPlayerUIView, coordinator: Coordinator) {
        coordinator.teardown()
        uiView.playerLayer.player?.pause()
        uiView.playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var endObserver: NSObjectProtocol?

        func observeEnd(of player: AVPlayer, onEnded: @escaping () -> Void) {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in onEnded() }
        }

        func teardown() {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
        }

        deinit { teardown() }
    }
}


