import AVKit
import SwiftUI

/// Reusable native tvOS video player. Wraps `AVPlayerViewController` (which gives the full Apple TV
/// transport UI, scrubbing, and Siri-remote gestures for free) and plays a single stream URL.
struct PlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        controller.player = player
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // Swap the item if the URL changed (e.g. user picked a different stream).
        if (controller.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            controller.player = AVPlayer(url: url)
            controller.player?.play()
        }
    }
}

/// Full-screen player container presented over the picker. Owns a dismiss affordance via the
/// environment so the Menu button / Done returns to the stream list.
struct PlayerScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlayerView(url: url)
            .ignoresSafeArea()
    }
}
