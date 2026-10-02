import Foundation
import AVFoundation
import CoreGraphics

/// BUG-128: KVO-only playback-health monitor for trailer surfaces. No timers, no per-frame work.
/// Arming (KVO registration) is unconditional in every build; only EMISSION is gated, exactly like
/// `TrailerZoomProbe.log`: `[TrailerHealth]` NSLog when `TrailerProbe.enabled`, pane lines through
/// `TrailerZoomProbe.log(...)` (About > Trailer Diagnostics buffer, gated on its own toggle).

// MARK: - Source classification

struct TrailerHealthSource: Equatable {
    /// repack | hls | progressive | other
    var kind: String
    var height: Int
    var fps: Int
    var itag: String?
    var throttledN: Bool

    nonisolated static func classify(urlString: String) -> TrailerHealthSource {
        guard let comps = URLComponents(string: urlString) else {
            return TrailerHealthSource(kind: "other", height: 0, fps: 0, itag: nil, throttledN: false)
        }
        if comps.host == "127.0.0.1" {
            var height = 0, fps = 0
            var itag: String?
            var throttled = false
            if let token = TrailerLocalHLS.token(inPlaybackURL: urlString),
               let s = TrailerLocalHLS.trackSummary(forToken: token) {
                height = s.height
                fps = s.fps
                itag = s.itag
                throttled = s.throttledN
            }
            return TrailerHealthSource(kind: "repack", height: height, fps: fps, itag: itag, throttledN: throttled)
        }
        let items = comps.queryItems ?? []
        let itag = items.first(where: { $0.name == "itag" })?.value
        let hasN = items.contains(where: { $0.name == "n" })
        let isHLS = comps.path.contains(".m3u8") || items.contains(where: { $0.name == "manifest" })
        return TrailerHealthSource(kind: isHLS ? "hls" : "progressive", height: 0, fps: 0, itag: itag, throttledN: hasN)
    }
}

// MARK: - Detail hitch snapshot

/// Written by DetailView's `HitchCounter`, read by the health monitor at `stop()`. MAIN-THREAD ONLY
/// (both writer and reader run on the main thread); `nonisolated(unsafe)` just lets nonisolated
/// callers touch it without an actor hop.
enum DetailHitchSnapshot {
    struct Value: Equatable {
        var hitches: Int
        var frames: Int
        var maxGapMs: Double
    }

    nonisolated(unsafe) static var latest: Value?

    nonisolated static func reset() { latest = nil }
    nonisolated static func update(_ value: Value) { latest = value }
}

// MARK: - Summary

struct TrailerHealthSummary {
    var surface: String
    var source: TrailerHealthSource
    var startupMs: Int?
    var playedSeconds: Double
    var waits: Int
    var waitMs: Int
    var stalls: Int
    var empties: Int
    var accessStalls: Int
    var droppedFrames: Int
    var indicatedMbps: Double?
    var observedMbps: Double?
    var presentation: CGSize
    var errorStatus: Int?
    var errorComment: String?
    var hitches: DetailHitchSnapshot.Value?

    private nonisolated var sourceLabel: String {
        var s = source.kind
        if source.height > 0 { s += " \(source.height)p" + (source.fps > 0 ? "\(source.fps)" : "") }
        return s
    }

    private nonisolated static func mbps(_ v: Double?, suffix: String = "") -> String {
        guard let v else { return "-" }
        return String(format: "%.1f", v) + suffix
    }

    nonisolated func consoleLine() -> String {
        let err: String
        if let status = errorStatus {
            let comment = (errorComment ?? "").replacingOccurrences(of: " ", with: "_")
            err = comment.isEmpty ? "\(status)" : "\(status):\(comment)"
        } else {
            err = "-"
        }
        let hitch = hitches.map { "\($0.hitches)/\($0.frames)" } ?? "-"
        let gap = hitches.map { String(format: "%dms", Int($0.maxGapMs.rounded())) } ?? "-"
        return "end surface=\(surface) src=\(sourceLabel) itag=\(source.itag ?? "-") n=\(source.throttledN ? 1 : 0)"
            + " startup=\(startupMs.map { "\($0)ms" } ?? "-") played=\(String(format: "%.1f", playedSeconds))s"
            + " waits=\(waits) waitMs=\(waitMs) stalls=\(stalls) empties=\(empties) accStalls=\(accessStalls)"
            + " dropped=\(droppedFrames) ind=\(Self.mbps(indicatedMbps, suffix: "Mb")) obs=\(Self.mbps(observedMbps, suffix: "Mb"))"
            + " size=\(Int(presentation.width))x\(Int(presentation.height)) err=\(err) hitches=\(hitch) maxGap=\(gap)"
    }

    /// <= 110 chars (the About pane truncates in the middle); verdict tokens at both ends.
    nonisolated func paneLine() -> String {
        let kind = source.kind == "progressive" ? "prog" : source.kind
        var label = kind
        if source.height > 0 { label += " \(source.height)p" + (source.fps > 0 ? "\(min(source.fps, 999))" : "") }
        let start = startupMs.map { String(format: "%.1fs", min(Double($0) / 1000, 99.9)) } ?? "-"
        let play = "\(min(Int(playedSeconds.rounded()), 999))s"
        let wait = "\(min(waits, 99))/" + String(format: "%.1fs", min(Double(waitMs) / 1000, 99.9))
        let line = "health \(String(surface.prefix(12))) \(label) n=\(source.throttledN ? 1 : 0) start=\(start) play=\(play)"
            + " wait=\(wait) stall=\(min(stalls, 99)) drop=\(min(droppedFrames, 999))"
            + " obs=\(Self.mbps(observedMbps.map { min($0, 99.9) })) ind=\(Self.mbps(indicatedMbps.map { min($0, 99.9) }))"
        return String(line.prefix(110))
    }
}

// MARK: - Monitor

/// One monitor per `AVPlayer` attach. KVO + one notification per item; `start()`/`stop()` idempotent,
/// the summary is emitted exactly once (on the first `stop()`).
final class TrailerPlaybackHealthMonitor: @unchecked Sendable {
    private let player: AVPlayer
    private let surface: String
    private let urlString: String
    private let lock = NSLock()

    private var started = false
    private var stopped = false
    private var startWall: CFAbsoluteTime = 0
    private var startupMs: Int?
    private var hasPlayed = false
    private var waitOpenedAt: CFAbsoluteTime?
    private var waitReason: String?
    private var waitAt: Double = 0
    private var waits = 0
    private var waitMs = 0
    private var stalls = 0
    private var empties = 0

    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var stallObserver: NSObjectProtocol?
    private var lastItem: AVPlayerItem?

    init(player: AVPlayer, surface: String, urlString: String) {
        self.player = player
        self.surface = surface
        self.urlString = urlString
    }

    func start() {
        lock.lock()
        if started || stopped { lock.unlock(); return }
        started = true
        startWall = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        let tc = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            self?.timeControlChanged(p)
        }
        // MANDATORY: AVPlayerLooper plays COPIES of the template item, so item-level observers must
        // follow `currentItem`.
        let ci = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] p, _ in
            self?.registerItem(p.currentItem)
        }
        lock.lock()
        playerObservations = [tc, ci]
        lock.unlock()
    }

    private func timeControlChanged(_ p: AVPlayer) {
        let status = p.timeControlStatus
        let reason = p.reasonForWaitingToPlay?.rawValue
        let at = p.currentTime().seconds
        let now = CFAbsoluteTimeGetCurrent()
        var line: String?
        lock.lock()
        if stopped { lock.unlock(); return }
        switch status {
        case .playing:
            if !hasPlayed {
                hasPlayed = true
                startupMs = Int(((now - startWall) * 1000).rounded())
            }
            if let opened = waitOpenedAt {
                let dur = Int(((now - opened) * 1000).rounded())
                waits += 1
                waitMs += dur
                waitOpenedAt = nil
                line = "wait surface=\(surface) reason=\(waitReason ?? "-") at=\(String(format: "%.1f", waitAt))s dur=\(dur)ms"
            }
        case .waitingToPlayAtSpecifiedRate:
            if hasPlayed, waitOpenedAt == nil {
                waitOpenedAt = now
                waitReason = reason
                waitAt = at.isFinite ? at : 0
            }
        default: break
        }
        lock.unlock()
        if let line { Self.emit(line) }
    }

    private func registerItem(_ item: AVPlayerItem?) {
        lock.lock()
        if stopped { lock.unlock(); return }
        let old = itemObservations
        itemObservations = []
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = nil
        lastItem = item
        lock.unlock()
        old.forEach { $0.invalidate() }
        guard let item else { return }

        let empty = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] it, _ in
            guard let self, it.isPlaybackBufferEmpty else { return }
            self.lock.lock(); self.empties += 1; self.lock.unlock()
        }
        let keepUp = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] it, _ in
            guard let self, !it.isPlaybackLikelyToKeepUp else { return }
            self.lock.lock(); let played = self.hasPlayed; self.lock.unlock()
            guard played else { return }
            Self.emit("keepup-lost surface=\(self.surface) at=\(String(format: "%.1f", Self.safe(it.currentTime().seconds)))s")
        }
        let note = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: nil) { [weak self, weak item] _ in
            guard let self else { return }
            self.lock.lock(); self.stalls += 1; self.lock.unlock()
            Self.emit("stall surface=\(self.surface) at=\(String(format: "%.1f", Self.safe(item?.currentTime().seconds ?? 0)))s")
        }
        lock.lock()
        if stopped {
            lock.unlock()
            empty.invalidate(); keepUp.invalidate()
            NotificationCenter.default.removeObserver(note)
            return
        }
        itemObservations = [empty, keepUp]
        stallObserver = note
        lock.unlock()
    }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let wasStarted = started
        let po = playerObservations; playerObservations = []
        let io = itemObservations; itemObservations = []
        let so = stallObserver; stallObserver = nil
        let item = lastItem; lastItem = nil
        let snapshot = (startupMs, waits, waitMs, stalls, empties)
        lock.unlock()

        _ = wasStarted
        var accStalls = 0, dropped = 0
        var played = 0.0
        var ind: Double?, obs: Double?
        var errStatus: Int?, errComment: String?
        var size = CGSize.zero
        if let item {
            if let events = item.accessLog()?.events {
                for e in events {
                    accStalls += max(e.numberOfStalls, 0)
                    dropped += max(e.numberOfDroppedVideoFrames, 0)
                    if e.durationWatched > 0 { played += e.durationWatched }
                }
                if let last = events.last {
                    if last.indicatedBitrate > 0 { ind = last.indicatedBitrate / 1_000_000 }
                    if last.observedBitrate > 0 { obs = last.observedBitrate / 1_000_000 }
                }
            }
            if let e = item.errorLog()?.events.last {
                errStatus = e.errorStatusCode
                errComment = e.errorComment
            }
            size = item.presentationSize
        }
        let summary = TrailerHealthSummary(
            surface: surface,
            source: TrailerHealthSource.classify(urlString: urlString),
            startupMs: snapshot.0, playedSeconds: played, waits: snapshot.1, waitMs: snapshot.2,
            stalls: snapshot.3, empties: snapshot.4, accessStalls: accStalls, droppedFrames: dropped,
            indicatedMbps: ind, observedMbps: obs, presentation: size,
            errorStatus: errStatus, errorComment: errComment, hitches: DetailHitchSnapshot.latest)

        po.forEach { $0.invalidate() }
        io.forEach { $0.invalidate() }
        if let so { NotificationCenter.default.removeObserver(so) }

        // The long console line goes out once as `[TrailerHealth]`; the short pane line goes
        // through the zoom probe's buffer, which prints its own `[TrailerZoom]` copy under the
        // same knob, so it is not NSLogged here a second time.
        if TrailerProbe.enabled { NSLog("[TrailerHealth] %@", summary.consoleLine()) }
        TrailerZoomProbe.log(summary.paneLine())
    }

    private nonisolated static func safe(_ v: Double) -> Double { v.isFinite ? v : 0 }

    /// Per-event lines: console under `[TrailerHealth]` when the probe knob is on, pane buffer via
    /// `TrailerZoomProbe.log` (which also NSLogs a `[TrailerZoom]` copy under the same knob).
    private nonisolated static func emit(_ line: String) {
        // One console line per event: `TrailerZoomProbe.log` already NSLogs under `TrailerProbe.enabled`.
        TrailerZoomProbe.log(line)
    }
}
