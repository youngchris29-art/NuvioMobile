#if DEBUG
import Foundation
import AVFoundation

// DEBUG-only headless harness for Phase 2. When the UserDefaults key `debug.remuxSmokeURL` holds a
// source URL, it runs a full RemuxSession on it and serves the result via LocalHLSServer, logging the
// output directory (to ffprobe the emitted fMP4) and the loopback playlist URL (to curl / feed a bare
// AVPlayer). Lets the remux + server be validated without any player UI. See docs/tvos-hybrid-player-plan.md.
//
// Trigger (simulator):
//   xcrun simctl spawn <dev> defaults write com.nuvio.media.NuvioTV debug.remuxSmokeURL -string '<url>'
//   xcrun simctl launch --console <dev> com.nuvio.media.NuvioTV
nonisolated enum RemuxSmokeTest {
    private static let lock = NSLock()
    private static var session: RemuxSession?
    private static var server: LocalHLSServer?
    private static var player: AVPlayer?

    static func runIfRequested() {
        guard let raw = UserDefaults.standard.string(forKey: "debug.remuxSmokeURL"),
              let url = URL(string: raw) else { return }
        print("[RemuxSmoke] start — \(raw)")

        let session = RemuxSession(config: .init(url: url, segmentDurationSec: 4))
        lock.lock(); self.session = session; lock.unlock()

        session.start { state in
            switch state {
            case .running:
                print("[RemuxSmoke] remuxing…")
            case .ready:
                print("[RemuxSmoke] ready — outputDir: \(session.outputDir.path)")
                let server = LocalHLSServer(rootDir: session.outputDir)
                lock.lock(); self.server = server; lock.unlock()
                server.start(masterName: session.masterPlaylistName) { playlistURL in
                    print("[RemuxSmoke] serving — \(playlistURL?.absoluteString ?? "no port")")
                    if let playlistURL { probeWithAVPlayer(playlistURL) }
                }
            case .failed(let stage):
                print("[RemuxSmoke] FAILED at \(stage)")
            case .idle:
                break
            }
        }
    }

    /// Final proof that AVPlayer actually accepts the remuxed stream (not just ffprobe/curl): load
    /// the served master playlist and log when the item becomes ready (or the error if it fails).
    private static func probeWithAVPlayer(_ url: URL) {
        DispatchQueue.main.async {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            lock.lock(); self.player = player; lock.unlock()
            player.play()
            pollStatus(item, attempt: 0)
        }
    }

    private static func pollStatus(_ item: AVPlayerItem, attempt: Int) {
        switch item.status {
        case .readyToPlay:
            let secs = CMTimeGetSeconds(item.duration)
            print("[RemuxSmoke] AVPlayer readyToPlay \u{2705} duration=\(secs.isFinite ? String(format: "%.1fs", secs) : "live")")
        case .failed:
            print("[RemuxSmoke] AVPlayer FAILED \u{274C} — \(item.error?.localizedDescription ?? "unknown")")
        default:
            if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pollStatus(item, attempt: attempt + 1) }
            } else {
                print("[RemuxSmoke] AVPlayer status unknown after timeout")
            }
        }
    }
}
#endif
