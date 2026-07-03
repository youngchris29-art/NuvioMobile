import SwiftUI
import AVFoundation
import AVKit

/// A muted, looping, controls-free trailer surface behind the Detail hero, backed by **AVPlayer**.
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
        private var started = false
        private var failed = false

        init(onFailure: @escaping () -> Void) {
            self.onFailure = onFailure
        }

        func attach(to view: TrailerPlayerUIView, urlString: String) {
            guard let url = URL(string: urlString) else { fail(); return }

            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.allowsExternalPlayback = false
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
            player?.pause()
            player = nil
            looper = nil
        }

        deinit { teardown() }
    }
}

/// Full-screen trailer playback with sound and transport controls (from the Detail "Trailers &
/// Extras" row). `AVPlayerViewController` supplies the standard tvOS player UI; the presenting
/// `fullScreenCover` handles Menu-to-dismiss.
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
