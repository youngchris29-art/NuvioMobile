import SwiftUI
import Combine
import AVFoundation
import AVKit
import SharedCore

/// A looping, controls-free trailer surface behind the Detail hero, backed by **AVPlayer**. Starts
/// muted and follows the shared `HeroTrailerAudioState` (same singleton the mobile app's hero
/// trailer uses) from then on, so the user's mute/unmute choice persists across titles for the
/// session. `HeroTrailerMuteButton` below is the affordance that flips it.
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

    func makeUIView(context: Context) -> TrailerPlayerUIView {
        let view = TrailerPlayerUIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view, urlString: urlString)
        return view
    }

    func updateUIView(_ uiView: TrailerPlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: TrailerPlayerUIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure)
    }

    /// Owns the AVPlayer, looping, and failure detection.
    final class Coordinator {
        private let onFailure: () -> Void
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var statusObservation: NSKeyValueObservation?
        private var failureObserver: NSObjectProtocol?
        private var watchdog: Timer?
        private var audioWatcher: FlowWatcher?
        private var started = false
        private var failed = false

        init(onFailure: @escaping () -> Void) {
            self.onFailure = onFailure
        }

        func attach(to view: TrailerPlayerUIView, urlString: String) {
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

            looper = AVPlayerLooper(player: queue, templateItem: item)
            view.playerLayer.player = queue
            player = queue

            statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
                switch observed.status {
                case .failed: self?.fail()
                case .readyToPlay: self?.started = true
                default: break
                }
            }
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in self?.fail() }

            queue.play()

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
            guard !failed else { return }
            failed = true
            DispatchQueue.main.async { self.onFailure() }
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
            audioWatcher?.cancel()
            audioWatcher = nil
            player?.pause()
            player = nil
            looper = nil
        }

        deinit { teardown() }
    }
}

/// Full-screen trailer playback with sound and transport controls — presented from either the
/// Detail action row's "Watch Trailer" button (the hero trailer, already resolved for the muted
/// background loop) or a "Trailers & Extras" row item (resolved on demand). `AVPlayerViewController`
/// supplies the standard tvOS player UI; the presenting `fullScreenCover` handles Menu-to-dismiss.
/// Deliberately a separate `AVPlayer` instance from `TrailerHeroPlayer` above — the two never run
/// concurrently (Detail hides/dismantles the background player while `trailerPlayback` is non-nil),
/// so there's no doubled decode/audio, and each keeps its own simple, single-purpose lifecycle.
struct FullScreenTrailerPlayer: UIViewControllerRepresentable {
    let urlString: String

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        if let url = URL(string: urlString) {
            let player = AVPlayer(url: url)
            controller.player = player
            player.play()
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

/// Bridges `HeroTrailerAudioState.muted` (Kotlin `StateFlow<Boolean>`) to SwiftUI, the same way
/// `StateFlowObserver` bridges the UiState repositories — but scoped to a bare `Boolean`, which KMP
/// boxes as `KotlinBoolean` rather than a data-class UiState, so it doesn't fit that generic type.
@MainActor
private final class HeroTrailerAudioObserver: ObservableObject {
    @Published private(set) var isMuted: Bool

    private var watcher: FlowWatcher?

    init() {
        let flow = HeroTrailerAudioState.shared.muted
        self.isMuted = (flow.value_ as? KotlinBoolean)?.boolValue ?? true
        self.watcher = FlowWatcherKt.watch(flow) { [weak self] emitted in
            guard let self, let boxed = emitted as? KotlinBoolean else { return }
            self.isMuted = boxed.boolValue
        }
    }

    deinit { watcher?.cancel() }
}

/// Mute-state indicator for the hero trailer. Not focusable: the overlay sits above the detail
/// ScrollView where the focus engine routes Up presses to the tab bar, so the actual toggle is the
/// Siri Remote's play/pause button (`.onPlayPauseCommand` in `DetailView`) — this just shows the
/// current state plus the ⏯ hint. Toggling flips the shared `HeroTrailerAudioState` preference the
/// mobile app also reads, so the choice persists across titles for the session.
struct HeroTrailerMuteButton: View {
    @StateObject private var audio = HeroTrailerAudioObserver()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "playpause.fill")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .accessibilityLabel(audio.isMuted ? "Trailer muted — press play/pause to unmute" : "Trailer sound on — press play/pause to mute")
    }
}
