import AVFoundation
import Combine
import Foundation

// Phase 3 of the hybrid player: ties Phase 2's remux + loopback server to an AVPlayer for one
// PlaybackContext. Starts the remux, begins playback progressively as soon as the first segment is
// available (rather than waiting for the whole file), and owns the AVPlayer lifecycle — resume seek,
// periodic watch-progress save, and Trakt scrobbling via the shared PlaybackProgressRecorder.
// See docs/tvos-hybrid-player-plan.md.
@MainActor
final class NativePlaybackCoordinator: ObservableObject {
    enum Phase: Equatable {
        case preparing            // remux spinning up / waiting for the first segment
        case playing
        case failed(String)       // pre-playback failure → dispatcher falls back to mpv
    }

    @Published private(set) var phase: Phase = .preparing
    private(set) var player: AVPlayer?

    /// Fired ~every few seconds with (position, duration) while playing — the screen forwards it to
    /// the next-episode engine.
    var onTick: ((Double, Double) -> Void)?

    /// Last observed position/duration, used when falling back to mpv.
    private(set) var lastPositionSec: Double = 0
    private var lastDurationSec: Double = 0

    private let context: PlaybackContext
    private let recorder: PlaybackProgressRecorder
    private var remux: RemuxSession?
    private var server: LocalHLSServer?
    private var playerItem: AVPlayerItem?
    private var pollTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?

    init(context: PlaybackContext) {
        self.context = context
        self.recorder = PlaybackProgressRecorder(context: context)
    }

    // MARK: - Lifecycle

    func start() {
        guard remux == nil else { return }
        let remux = RemuxSession(config: .init(url: context.url, segmentDurationSec: 6))
        self.remux = remux
        remux.start { state in
            guard case .failed(let stage) = state else { return }
            Task { @MainActor [weak self] in self?.failIfPreplayback(stage) }
        }
        pollForFirstSegment(remux: remux)
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        observeTask?.cancel(); observeTask = nil
        if lastDurationSec > 0 {
            recorder.record(positionSec: lastPositionSec, durationSec: lastDurationSec, isPaused: true, speed: 1, flush: true)
        }
        recorder.stopTrakt(positionSec: lastPositionSec, durationSec: lastDurationSec)
        player?.pause()
        server?.stop(); server = nil
        remux?.stop()
        let dir = remux?.outputDir
        remux = nil
        player = nil
        playerItem = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Progressive startup

    /// Poll the remux output for the init segment + first media segment, then start serving/playing.
    private func pollForFirstSegment(remux: RemuxSession) {
        pollTask = Task { @MainActor [weak self] in
            let fm = FileManager.default
            let dir = remux.outputDir
            for _ in 0..<160 {                          // ~40s ceiling
                if Task.isCancelled { return }
                if case .failed(let stage) = remux.state { self?.failIfPreplayback(stage); return }
                let hasCore = fm.fileExists(atPath: dir.appendingPathComponent("master.m3u8").path)
                    && fm.fileExists(atPath: dir.appendingPathComponent("media_0.m3u8").path)
                    && fm.fileExists(atPath: dir.appendingPathComponent("init-0.mp4").path)
                let hasSegment = ((try? fm.contentsOfDirectory(atPath: dir.path))?.contains { $0.hasPrefix("seg-0-") }) ?? false
                if hasCore && hasSegment { self?.beginPlayback(remux: remux); return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.failIfPreplayback("no segments produced")
        }
    }

    private func beginPlayback(remux: RemuxSession) {
        guard phase == .preparing, player == nil else { return }
        let server = LocalHLSServer(rootDir: remux.outputDir, videoCodecToken: remux.videoToken)
        self.server = server
        server.start(masterName: remux.masterPlaylistName) { [weak self] url in
            guard let self else { return }
            guard let url else { self.failIfPreplayback("server bind failed"); return }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            self.playerItem = item
            self.player = player
            self.phase = .playing
            self.observePlayback(player: player, item: item)
        }
    }

    // MARK: - AVPlayer observation (resume + progress + Trakt)

    private func observePlayback(player: AVPlayer, item: AVPlayerItem) {
        observeTask = Task { @MainActor [weak self] in
            var readied = false
            while !Task.isCancelled {
                guard let self, self.player === player else { return }

                if !readied, item.status == .readyToPlay {
                    readied = true
                    let duration = CMTimeGetSeconds(item.duration)
                    if let resume = self.recorder.resumePositionSec() {
                        await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                        self.lastPositionSec = resume
                    }
                    player.play()
                    self.recorder.startTrakt(positionSec: self.lastPositionSec, durationSec: duration.isFinite ? duration : 0)
                } else if item.status == .failed {
                    // Item failed before we ever played → treat as pre-playback fallback.
                    if self.phase != .playing || self.lastDurationSec == 0 {
                        self.failIfPreplayback(item.error?.localizedDescription ?? "item failed")
                        return
                    }
                }

                if readied {
                    let pos = CMTimeGetSeconds(player.currentTime())
                    let dur = CMTimeGetSeconds(item.duration)
                    if pos.isFinite, dur.isFinite, dur > 0 {
                        let paused = player.timeControlStatus != .playing
                        self.lastPositionSec = pos
                        self.lastDurationSec = dur
                        self.recorder.record(positionSec: pos, durationSec: dur, isPaused: paused, speed: 1, flush: false)
                        self.onTick?(pos, dur)
                    }
                }
                try? await Task.sleep(nanoseconds: readied ? 3_000_000_000 : 200_000_000)
            }
        }
    }

    private func failIfPreplayback(_ stage: String) {
        guard phase != .playing else { return }
        if case .failed = phase { return }
        print("[NativePlayer] pre-playback failure: \(stage) — falling back to mpv")
        phase = .failed(stage)
    }
}
