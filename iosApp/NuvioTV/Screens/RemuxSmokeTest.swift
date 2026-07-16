#if DEBUG
import AVFoundation
import Foundation

// DEBUG-only headless harness for the native playback path. When the UserDefaults key
// `debug.remuxSmokeURL` holds a source URL, it drives a real `NativePlaybackCoordinator` (the exact
// orchestration the dispatcher's native branch runs) and logs when it reaches `playing` with the
// AVPlayer item ready — validating remux → progressive serve → AVPlayer end to end without any UI.
// See docs/tvos-hybrid-player-plan.md.
//
// Trigger (simulator):
//   xcrun simctl spawn <dev> defaults write com.nuvio.media.NuvioTV debug.remuxSmokeURL -string '<url>'
//   xcrun simctl launch --console-pty <dev> com.nuvio.media.NuvioTV
nonisolated enum RemuxSmokeTest {
    @MainActor private static var coordinator: NativePlaybackCoordinator?

    static func runIfRequested() {
        guard let raw = UserDefaults.standard.string(forKey: "debug.remuxSmokeURL"),
              let url = URL(string: raw) else { return }
        Task { @MainActor in
            print("[RemuxSmoke] start — \(raw)")
            let context = PlaybackContext(
                url: url, title: "Smoke Test", contentType: "movie",
                parentMetaId: "smoke", videoId: "smoke",
                season: nil, episode: nil, poster: nil, background: nil,
                providerName: nil, providerAddonId: nil,
                streamTitle: nil, streamSubtitle: nil, externalSubtitles: []
            )
            let coordinator = NativePlaybackCoordinator(context: context)
            self.coordinator = coordinator
            coordinator.start()
            observe(coordinator, attempt: 0)
        }
    }

    @MainActor
    private static func observe(_ coordinator: NativePlaybackCoordinator, attempt: Int) {
        switch coordinator.phase {
        case .playing:
            let status = coordinator.player?.currentItem?.status
            if status == .readyToPlay {
                let secs = coordinator.player?.currentItem.map { CMTimeGetSeconds($0.duration) } ?? .nan
                let text = secs.isFinite ? String(format: "%.1fs", secs) : "live"
                print("[RemuxSmoke] coordinator playing + AVPlayer readyToPlay \u{2705} duration=\(text)")
            } else if attempt < 40 {
                schedule(coordinator, attempt: attempt + 1)
            } else {
                print("[RemuxSmoke] playing but item not ready (status=\(String(describing: status)))")
            }
        case .failed(let stage):
            print("[RemuxSmoke] coordinator FAILED \u{274C} — \(stage)")
        case .preparing:
            if attempt < 200 {
                schedule(coordinator, attempt: attempt + 1)
            } else {
                print("[RemuxSmoke] still preparing after timeout")
            }
        }
    }

    @MainActor
    private static func schedule(_ coordinator: NativePlaybackCoordinator, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            observe(coordinator, attempt: attempt)
        }
    }
}
#endif
