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
    private var servedURL: URL?
    /// 0 = full signaling (RFC 6381 + DV supplemental + range); 1 = minimal (bare sample-entry tag).
    /// A strict AVPlayer that rejects the full form at the master stage gets one retry at minimal.
    private var signalingAttempt = 0

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
        // debug.keepRemuxOutput=1 preserves the emitted files so they can be pulled off the device
        // (devicectl copy from the app container) and inspected with ffprobe on a Mac.
        if let dir, !UserDefaults.standard.bool(forKey: "debug.keepRemuxOutput") {
            try? FileManager.default.removeItem(at: dir)
        } else if let dir {
            print("[NativePlayer] kept remux output at \(dir.path)")
        }
    }

    // MARK: - Progressive startup

    /// Poll the remux output until playback can start: the segment map exists (else the source has no
    /// usable keyframe index → mpv), the init segment is written, and the first media segment is ready
    /// so AVPlayer's opening requests are instant. The playlist is a COMPLETE VOD list from the first
    /// fetch (the JIT server synthesizes it from the map), so there is no EVENT ≥3-segment join rule
    /// anymore; later segments simply block briefly on the JIT server until the remux produces them.
    private func pollForFirstSegment(remux: RemuxSession) {
        pollTask = Task { @MainActor [weak self] in
            let dir = remux.outputDir
            for _ in 0..<240 {                          // ~60s ceiling
                if Task.isCancelled { return }
                if case .failed(let stage) = remux.state { self?.failIfPreplayback(stage); return }
                let hasMap = remux.segmentMap != nil
                let hasInit = Self.fileSize(dir, "init.mp4") > 0
                // A finished remux (short clip that is a single segment) finalizes seg-00001 only at EOF.
                let hasFirst = Self.fileSize(dir, RemuxSession.segmentName(1)) > 0 || remux.state == .ready
                if hasMap && hasInit && hasFirst {
                    self?.beginPlayback(remux: remux)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.failIfPreplayback("no segments produced")
        }
    }

    private static func fileSize(_ dir: URL, _ name: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? Int) ?? 0
    }

    private func beginPlayback(remux: RemuxSession) {
        guard phase == .preparing, player == nil else { return }
        guard let map = remux.segmentMap else { failIfPreplayback("no segment map"); return }
        let server = LocalHLSServer(rootDir: remux.outputDir, map: map,
                                    signaling: remux.videoSignaling ?? VideoSignaling(codecs: ""),
                                    audioCodec: remux.audioCodecToken, bandwidth: remux.estimatedBandwidth)
        self.server = server
        server.start(masterName: remux.masterPlaylistName) { [weak self] url in
            guard let self else { return }
            guard let url else { self.failIfPreplayback("server bind failed"); return }
            print("[NativePlayer] serving \(url.absoluteString)")
            self.servedURL = url
            let item = AVPlayerItem(url: url)
            // Bound how far ahead AVPlayer prefetches: over the infinite-bandwidth loopback origin it
            // would otherwise race minutes past the ~realtime remux frontier and block on segments that
            // don't exist yet, tripping CFNetwork's request timeout.
            item.preferredForwardBufferDuration = 24
            let player = AVPlayer(playerItem: item)
            self.playerItem = item
            self.player = player
            self.phase = .playing
            self.observePlayback(player: player, item: item)
        }
    }

    /// Item failed before playback ever started. Attempt 0 → retry once with minimal signaling
    /// (some AVPlayer builds reject the full CODECS/SUPPLEMENTAL form at the master stage);
    /// attempt 1 → give up and hand the context to mpv.
    private func handlePrePlaybackItemFailure(player: AVPlayer) {
        for name in ["master.m3u8", "media.m3u8"] {
            guard let playlist = server?.renderedPlaylist(named: name) else { continue }
            // Prefix every line so console filters on "NativePlayer" keep the playlist content. The
            // media playlist can be long (one line per segment) — cap the dump.
            let prefixed = playlist.components(separatedBy: "\n").prefix(40)
                .map { "[NativePlayer] | \($0)" }.joined(separator: "\n")
            print("[NativePlayer] served \(name) (\(playlist.count) chars):\n\(prefixed)")
        }
        if let dir = remux?.outputDir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let listing = names.sorted().prefix(24).map { "\($0)=\(Self.fileSize(dir, $0))b" }.joined(separator: " ")
            print("[NativePlayer] output dir: \(listing)")
        }
        guard signalingAttempt == 0, let servedURL else {
            print("[NativePlayer] failing over to mpv (item failed before playback started)")
            phase = .failed("item failed before start")
            return
        }
        signalingAttempt = 1
        // Retry once with reduced signaling: drop only SUPPLEMENTAL-CODECS (some AVPlayer builds
        // reject the DV supplemental form at the master stage). The full RFC 6381 CODECS token and
        // VIDEO-RANGE MUST stay — bare tags are non-compliant, and PQ media without a declared
        // VIDEO-RANGE is itself rejected on tvOS 27 (the retry would fail for the wrong reason).
        var reduced = remux?.videoSignaling ?? VideoSignaling(codecs: "hvc1")
        reduced.supplementalCodecs = nil
        server?.setSignaling(reduced)
        print("[NativePlayer] retrying without SUPPLEMENTAL-CODECS (CODECS=\(reduced.codecs) RANGE=\(reduced.videoRange ?? "-"))")
        observeTask?.cancel()
        // Cache-bust so AVPlayer refetches the master (the server ignores query strings).
        let retryURL = URL(string: servedURL.absoluteString + "?r=1") ?? servedURL
        let item = AVPlayerItem(url: retryURL)
        item.preferredForwardBufferDuration = 24
        playerItem = item
        player.replaceCurrentItem(with: item)
        observePlayback(player: player, item: item)
    }

    // MARK: - AVPlayer observation (resume + progress + Trakt)

    private func observePlayback(player: AVPlayer, item: AVPlayerItem) {
        observeTask = Task { @MainActor [weak self] in
            var readied = false
            var waitingTicks = 0
            var notReadyTicks = 0
            while !Task.isCancelled {
                guard let self, self.player === player else { return }

                if !readied, item.status == .readyToPlay {
                    readied = true
                    print("[NativePlayer] item readyToPlay")
                    let duration = CMTimeGetSeconds(item.duration)
                    if let resume = self.recorder.resumePositionSec() {
                        await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                        self.lastPositionSec = resume
                    }
                    player.play()
                    self.recorder.startTrakt(positionSec: self.lastPositionSec, durationSec: duration.isFinite ? duration : 0)
                } else if item.status == .failed {
                    print("[NativePlayer] item FAILED — \(item.error?.localizedDescription ?? "unknown")")
                    Self.dumpItemLogs(item)
                    // Nothing ever rendered → retry with minimal signaling, then hand to mpv.
                    if self.lastDurationSec == 0 {
                        self.handlePrePlaybackItemFailure(player: player)
                    } else {
                        // Failed AFTER playback started — e.g. a forward seek past the linear remux
                        // frontier that the JIT server fast-503'd until AVPlayer gave up. Hand to mpv
                        // (which seeks anywhere via its own demuxer) at the current/target position.
                        self.fallbackMidPlay("item failed mid-play")
                    }
                    return
                } else if !readied {
                    // Blind-spot coverage: the item can sit in .unknown forever (bad playlist, codec
                    // rejection) with no state change to observe. Surface why every ~10s.
                    notReadyTicks += 1
                    if notReadyTicks % 50 == 0 {          // 50 ticks × 200ms ≈ 10s
                        print("[NativePlayer] item still not ready after ~\(notReadyTicks / 5)s (status=\(item.status.rawValue))")
                        Self.dumpItemLogs(item)
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

                    // Stall diagnostics: if the player sits in a waiting state across several ticks,
                    // dump why — the item's error log carries segment/format errors (decode
                    // rejections, 404s) that are otherwise invisible outside Xcode.
                    if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        waitingTicks += 1
                        if waitingTicks == 3 || waitingTicks % 10 == 3 {
                            let reason = player.reasonForWaitingToPlay?.rawValue ?? "?"
                            print("[NativePlayer] waiting (\(reason)) at \(String(format: "%.1f", CMTimeGetSeconds(player.currentTime())))s")
                            Self.dumpItemLogs(item)
                        }
                        // Sustained stall (~30s at 3s/tick) the JIT server can't resolve: a seek/resume
                        // past the linear remux frontier that will take minutes to reach, or a source
                        // slower than playback. Hand to mpv at the current position rather than spin.
                        if waitingTicks >= 10 {
                            self.fallbackMidPlay("stalled ~30s waiting for segments")
                            return
                        }
                    } else {
                        waitingTicks = 0
                    }
                }
                try? await Task.sleep(nanoseconds: readied ? 3_000_000_000 : 200_000_000)
            }
        }
    }

    /// Error + access logs from the item — names the exact URI/status/comment AVPlayer choked on.
    private static func dumpItemLogs(_ item: AVPlayerItem) {
        for event in item.errorLog()?.events ?? [] {
            print("[NativePlayer] errorLog: status=\(event.errorStatusCode) \(event.errorComment ?? "") uri=\(event.uri ?? "")")
        }
        if let access = item.accessLog()?.events.last {
            print("[NativePlayer] accessLog: uri=\(access.uri ?? "?") bytes=\(access.numberOfBytesTransferred) stalls=\(access.numberOfStalls)")
        }
    }

    private func failIfPreplayback(_ stage: String) {
        guard phase != .playing else {
            // Mid-play remux failure (e.g. a truncated debrid source): the remaining segments will
            // never appear, so JIT requests would block until playback stalls. Hand to mpv now rather
            // than wait for the stall watchdog.
            print("[NativePlayer] remux failed MID-PLAY at \(stage) — handing to mpv")
            fallbackMidPlay("remux failed mid-play: \(stage)")
            return
        }
        if case .failed = phase { return }
        print("[NativePlayer] pre-playback failure: \(stage) — falling back to mpv")
        phase = .failed(stage)
    }

    /// Mid-play escalation to mpv: the native path started but can no longer make progress (a seek past
    /// the linear remux frontier, or the source truncated). Flipping `phase` to `.failed` makes
    /// `NativePlayerScreen` call `onFallback(lastPositionSec)`, which re-presents mpv at the same
    /// position — mpv seeks anywhere via its own demuxer. No-op unless we are actually playing.
    private func fallbackMidPlay(_ reason: String) {
        guard phase == .playing else { return }
        observeTask?.cancel()
        print("[NativePlayer] mid-play fallback to mpv at \(String(format: "%.1f", lastPositionSec))s — \(reason)")
        phase = .failed(reason)
    }
}
