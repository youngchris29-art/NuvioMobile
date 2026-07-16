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
        startProbeLoopIfRequested()
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
                samplePlayback(coordinator, sample: 0)
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

    // MARK: - Remote-controlled AVPlayer probe loop

    /// When `debug.avplayerProbeURL` holds a URL (typically a playlist served by a dev Mac on the
    /// LAN), probe it with a fresh AVPlayer every ~20s and POST each verdict to `<host>:<port>/report`
    /// on the same server. Lets playlist/media variants be A/B-tested against THIS device's actual
    /// AVFoundation without touching the app flow or relaying console output by hand: the Mac swaps
    /// what the URL serves between rounds and watches the reports arrive.
    @MainActor private static var probePlayer: AVPlayer?

    private static func startProbeLoopIfRequested() {
        guard let raw = UserDefaults.standard.string(forKey: "debug.avplayerProbeURL"),
              let base = URL(string: raw) else { return }
        print("[ProbeLoop] starting against \(raw)")
        Task { @MainActor in
            // Fresh AVPlayer(playerItem:) per round — empirically a single reused AVPlayer fails to
            // load MULTIVARIANT (master) playlists (-12927) while direct media plays. The slow
            // cadence below is what prevents decoder-session exhaustion.
            var round = 0
            while true {
                round += 1
                var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                comps.queryItems = [URLQueryItem(name: "round", value: String(round))]   // cache-bust
                let item = AVPlayerItem(url: comps.url!)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                probePlayer = player
                player.play()

                var verdict = "TIMEOUT(unknown)"
                for _ in 0..<60 {                                    // ≤15s per round
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if item.status == .readyToPlay {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        let pos = CMTimeGetSeconds(player.currentTime())
                        verdict = "READY pos=\(String(format: "%.1f", pos))"
                        break
                    }
                    if item.status == .failed {
                        let err = item.error.map { "\(($0 as NSError).domain)#\(($0 as NSError).code)" } ?? "?"
                        let logs = (item.errorLog()?.events ?? [])
                            .map { "\($0.errorStatusCode):\($0.errorComment ?? "")" }.joined(separator: "; ")
                        verdict = "FAILED \(err) [\(logs)]"
                        break
                    }
                }
                player.pause()
                player.replaceCurrentItem(with: nil)
                probePlayer = nil
                print("[ProbeLoop] round \(round): \(verdict)")
                report(base: base, message: "round=\(round) \(verdict)")
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
        }
    }

    private static func report(base: URL, message: String) {
        guard let host = base.host else { return }
        let port = base.port.map { ":\($0)" } ?? ""
        guard let url = URL(string: "http://\(host)\(port)/report") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(message.utf8)
        URLSession.shared.dataTask(with: req).resume()
    }

    /// After ready: sample position/rate every 2s so stalls (e.g. live-edge waiting on a growing
    /// playlist) are visible in the console.
    @MainActor
    private static func samplePlayback(_ coordinator: NativePlaybackCoordinator, sample: Int) {
        guard sample < 30, let player = coordinator.player, let item = player.currentItem else { return }
        let pos = CMTimeGetSeconds(player.currentTime())
        let dur = CMTimeGetSeconds(item.duration)
        let control: String
        switch player.timeControlStatus {
        case .playing: control = "playing"
        case .paused: control = "paused"
        case .waitingToPlayAtSpecifiedRate:
            control = "waiting(\(player.reasonForWaitingToPlay?.rawValue ?? "?"))"
        @unknown default: control = "?"
        }
        let durText = dur.isFinite ? String(format: "%.1f", dur) : "live"
        print("[RemuxSmoke] t=\(sample * 2)s pos=\(String(format: "%.1f", pos)) dur=\(durText) \(control) bufferEmpty=\(item.isPlaybackBufferEmpty) likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            samplePlayback(coordinator, sample: sample + 1)
        }
    }
}
#endif
