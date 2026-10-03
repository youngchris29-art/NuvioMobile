import Combine
import CryptoKit
import Foundation
import Network
import SharedCore
import UIKit

// UX-4c SABR follow-up: YouTube's SABR rollout means many videos (recent uploads especially) come
// back from innertube with NO hlsManifestUrl and NO muxed formats beyond the 360p progressive —
// only demuxed adaptiveFormats with direct URLs + initRange/indexRange. AVPlayer can't consume bare
// DASH adaptive streams, but it plays byte-range fMP4 HLS (v7) natively. So when the shared
// extractor surfaces an AVPlayer-decodable demuxed pair (H.264 fMP4 + AAC fMP4, in
// `TrailerPlaybackSource.adaptiveVideo/adaptiveAudio`), this repackages it into a local HLS
// playlist set: fetch the two sidx boxes (a few KB), turn their segment tables into
// EXT-X-BYTERANGE media playlists that point AVPlayer straight at googlevideo, and serve the
// playlists (playlists ONLY — no media bytes are proxied) from a loopback NWListener.
//
// Every failure path falls back to `progressiveUrl` (the pre-existing 360p behavior), so this can
// only ever upgrade quality. Server pattern mirrors RemoteSetupServer/LocalHLSServer; ports 8230+
// so an active remux session (8190+) or setup server (8080+) never collides.

// MARK: - Listener seam (beta.19-rc1 verdict, B2 / BUG-131)

/// beta.19-rc1 verdict (B2): what a loopback listener reports. A plain mirror of `NWListener.State`
/// so the lifecycle logic below can be driven by a fake in unit tests.
nonisolated enum TrailerListenerState: Equatable, Sendable {
    case setup
    case waiting(String)
    case ready
    case failed(String)
    case cancelled
}

/// beta.19-rc1 verdict (B2): the listener the server binds on 127.0.0.1. A protocol with methods (not
/// settable handler properties) to stay clear of the SDK's `@Sendable` handler signatures. Callbacks
/// arrive on `queue`, whatever thread the implementation uses internally.
nonisolated protocol TrailerLoopbackListening: AnyObject, Sendable {
    func start(queue: DispatchQueue,
               onState: @escaping @Sendable (TrailerListenerState) -> Void,
               onConnection: @escaping @Sendable (NWConnection) -> Void)
    func cancel()
}

nonisolated enum NWTrailerLoopbackListenerError: Error {
    case invalidPort
}

/// beta.19-rc1 verdict (B2): the real adapter, a thin `NWListener` wrapper bound to 127.0.0.1:port.
/// `allowLocalEndpointReuse` is SO_REUSEADDR-class only (it does NOT allow a second LISTENING socket
/// on a port), which is why a rebuild waits for the old listener's `.cancelled` and retries the same
/// port a few times instead of assuming the bind succeeds at once.
nonisolated final class NWTrailerLoopbackListener: TrailerLoopbackListening, @unchecked Sendable {
    private let listener: NWListener

    init(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NWTrailerLoopbackListenerError.invalidPort
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start(queue: DispatchQueue,
               onState: @escaping @Sendable (TrailerListenerState) -> Void,
               onConnection: @escaping @Sendable (NWConnection) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .setup: onState(.setup)
            case let .waiting(error): onState(.waiting(String(describing: error)))
            case .ready: onState(.ready)
            case let .failed(error): onState(.failed(String(describing: error)))
            case .cancelled: onState(.cancelled)
            @unknown default: onState(.setup)
            }
        }
        listener.newConnectionHandler = { connection in onConnection(connection) }
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
    }

    #if DEBUG
    /// beta.19-rc1 verdict (B2) DEBUG fault knob: cancels the underlying `NWListener` with both
    /// handlers detached, so the owner never hears about it. This is what H1 (silent socket
    /// reclaim while suspended) looks like from the server's side.
    func cancelSilently() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }
    #endif
}

/// beta.19-rc1 verdict (B2): the three answers a trailer playback-URL request can come back with.
/// `timedOut` is a transient (the URL is slow, not wrong): callers fall back to `progressive` when
/// there is one and NEVER mark the title unavailable.
nonisolated enum TrailerPlaybackURLOutcome: Equatable, Sendable {
    /// Local repack master, or the progressive/HLS URL.
    case playable(String)
    /// No repack and no progressive URL for this source.
    case nothingPlayable
    /// No answer in time.
    case timedOut(progressive: String?)

    /// The legacy `String?` shape (Detail): a playable URL or nil.
    var legacyURL: String? {
        if case let .playable(url) = self { return url }
        return nil
    }
}

/// One-shot latch used by the outcome race and the health ping: the first `fire()` wins.
nonisolated final class TrailerOneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// `true` for exactly one caller.
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }

    var isFired: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}

/// Per-connection bookkeeping for the live-connection counter and the header idle timeout.
nonisolated final class TrailerConnectionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var headerSeen = false

    /// `true` for the first call only (decrement the live counter exactly once).
    func markClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if closed { return false }
        closed = true
        return true
    }

    func markHeaderComplete() {
        lock.lock(); headerSeen = true; lock.unlock()
    }

    var headerComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return headerSeen
    }
}

#if DEBUG
/// beta.19-rc1 verdict (B2): `-debug.trailerListenerFault <mode>` (read once).
nonisolated enum TrailerListenerFault: String, Sendable {
    case off
    /// On background, silently cancel the live `NWListener` (the class keeps its `port`). Reproduces H1;
    /// the `.active` health ping must find it dead and the rebuild must recover.
    case silent
    /// As `silent`, but `.active` skips verification. Proves the knob reproduces the symptom.
    case silentNoRebuild = "silent-norebuild"
    /// As `silent`, and EVERY listener created after the background reports `.waiting` and never
    /// `.ready`. Reproduces H2 and drives the attempt deadline.
    case waiting
}
#endif

nonisolated final class TrailerLocalHLS: @unchecked Sendable {
    static let shared = TrailerLocalHLS()

    /// beta.19-rc1 verdict (B2): injectable time. `schedule(delay, work)` runs `work` once after
    /// `delay` seconds (default: `listenerQueue.asyncAfter`); tests pass a fake that fires on demand.
    typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    /// Calls `done(true)` when something on 127.0.0.1:port answers within 1 s, else `done(false)`.
    typealias HealthCheck = @Sendable (UInt16, @escaping @Sendable (Bool) -> Void) -> Void
    typealias Uptime = @Sendable () -> TimeInterval
    /// The repack leg of a playback request: calls `finish(localURL or nil)` exactly once.
    typealias RepackWork = (_ finish: @escaping @Sendable (String?) -> Void) -> Void

    enum LifecycleEvent {
        case background
        case active
    }

    /// Per-attempt bind deadline: a start that neither reports `.ready` nor `.failed` in this long
    /// resolves its waiters nil (progressive fallback) and moves on.
    static let startDeadline: TimeInterval = 2.0
    static let sameBindRetryDelay: TimeInterval = 0.1
    static let sameBindRetries = 3
    /// How long a rebuild waits for the retired listener's `.cancelled` before binding anyway.
    static let retireWait: TimeInterval = 0.5
    static let healthTimeout: TimeInterval = 1.0
    /// A connection with no complete request header after this long is cancelled.
    static let connectionHeaderTimeout: TimeInterval = 5.0
    static let eagerRebuildBudget = 3
    static let eagerRebuildWindow: TimeInterval = 60
    static let slowRepackSeconds: TimeInterval = 6
    /// ≥ 12 s: cuts only pathological repacks.
    static let inlinePlaybackURLTimeout: TimeInterval = 12
    static let portCount = 20

    private let listenerFactory: @Sendable (UInt16) throws -> TrailerLoopbackListening
    private let schedule: Scheduler
    private let healthCheck: HealthCheck
    private let uptime: Uptime
    private let basePort: UInt16
    private let observesLifecycle: Bool

    private let listenerQueue: DispatchQueue
    private let connQueue = DispatchQueue(label: "media.nuvio.trailer-hls-conn")
    private let lock = NSLock()

    // Everything below is guarded by `lock`. Never call out (listener, waiters, schedule, NSLog,
    // factory) while holding it; decide under the lock, act after unlocking.

    /// The current candidate while a start is in flight, the ready listener after.
    private var listener: TrailerLoopbackListening?
    /// Identity of `listener` for its callbacks (a stale listener's events are ignored).
    private var currentAttemptID: Int?
    private var attemptSerial = 0
    /// Non-nil only while the listener is `.ready`.
    private var port: UInt16?
    private var startWaiters: [@Sendable (UInt16?) -> Void] = []
    /// A start or rebuild is under way (replaces the old `!startWaiters.isEmpty` test).
    private var startInFlight = false
    /// Bumped at every start and every death; the log's `gen=`.
    private var startGeneration = 0
    private var portOrder: [UInt16] = []
    private var portIndex = 0
    private var preferredPort: UInt16?
    private var samePortRetries = 0
    /// The cancelled listener whose `.cancelled` a rebuild is waiting for.
    private var retiring: TrailerLoopbackListening?
    private var retiringID: Int?
    private var rebuildToken: Int?
    private var lastBoundPort: UInt16?
    private var backgroundedSinceActive = false
    private var eagerRebuilds: [TimeInterval] = []
    private var liveConnections = 0
    private var verifyInFlight = false
    private var lifecycleObserversInstalled = false
    private var cycleScheduled = false
    #if DEBUG
    private var faultWaitingArmed = false
    #endif

    /// token → {master.m3u8, video.m3u8, audio.m3u8}. Playlists are a few KB; the cap only exists
    /// so a marathon browsing session can't grow this forever.
    ///
    /// BUG-46/B3: this store and `TrailerResolutionCache` used to disagree about what a token is
    /// worth. The cache hands out a local URL for up to 3h, while a random per-repack token was
    /// evicted after 64 *repacks* — and because re-resolving a title minted a NEW token instead of
    /// overwriting its old one, browsing a few dozen titles could evict a token whose `.resolved`
    /// entry was still live. The player then got a 404 and the title read as broken until the app
    /// restarted. Two halves of the fix: tokens are now DERIVED from the track pair (re-resolving
    /// the same trailer overwrites its own entry, so the token count is bounded by distinct
    /// trailers, not by repacks), and `maxTokens` matches `TrailerResolutionCache.capacity` so the
    /// two stores evict on the same scale. `hasToken(_:)` lets a cache hit check before playing;
    /// the 404 path below stays as the backstop for googlevideo URL expiry inside the playlists.
    private var playlists: [String: [String: Data]] = [:]
    private var tokenOrder: [String] = []
    private static let maxTokens = 200

    /// token → content identity ("id=<videoId>"), captured at mint time in `repack()` from the
    /// same video URL `token(video:audio:)` hashed. Never derivable FROM the token itself (a
    /// one-way SHA256 digest with nothing to recover), so this is a lookup table, not a parser —
    /// evicted in lockstep with `playlists`/`tokenOrder` so an identity can never outlive the
    /// token it describes. See `contentIdentity(forToken:)`.
    private var contentIdentities: [String: String] = [:]
    /// Diagnostics: the video rung each token serves, kept in lockstep with `contentIdentities`.
    private var trackSummaries: [String: TrackSummary] = [:]

    #if DEBUG
    /// beta.19-rc1 verdict (B2): `-debug.trailerListenerFault silent|silent-norebuild|waiting`, read once.
    private static let debugFault: TrailerListenerFault = {
        let raw = UserDefaults.standard.string(forKey: "debug.trailerListenerFault")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fault = raw.flatMap(TrailerListenerFault.init(rawValue:)) ?? TrailerListenerFault.off
        if fault != .off { NSLog("[TrailerRepack] listener fault knob=%@", fault.rawValue) }
        return fault
    }()

    /// beta.19-rc1 verdict (B2): `-debug.trailerListenerLifecycleCycleAfterS <n>`, read once. n seconds
    /// after the first `.ready`, the server runs a background→active cycle in-process (no `press(.home)`).
    private static let debugCycleAfter: TimeInterval? = {
        let value = UserDefaults.standard.object(forKey: "debug.trailerListenerLifecycleCycleAfterS")
        let seconds: Double?
        if let number = value as? NSNumber { seconds = number.doubleValue }
        else if let text = value as? String { seconds = Double(text.trimmingCharacters(in: .whitespaces)) }
        else { seconds = nil }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        NSLog("[TrailerRepack] listener cycle knob after=%.1fs", seconds)
        return seconds
    }()
    #endif

    /// beta.19-rc1 verdict (B2): `private init()` became an injectable one so the lifecycle can be driven
    /// by fakes. The defaults are the real `NWListener` adapter, `listenerQueue.asyncAfter`, a real
    /// NWConnection ping and `systemUptime`; `observesLifecycle: false` keeps tests off the app's
    /// notification center (they call `noteLifecycle` themselves).
    init(listenerFactory: @escaping @Sendable (UInt16) throws -> TrailerLoopbackListening = { try NWTrailerLoopbackListener(port: $0) },
         schedule: Scheduler? = nil,
         healthCheck: HealthCheck? = nil,
         uptime: Uptime? = nil,
         basePort: UInt16 = 8230,
         observesLifecycle: Bool = true) {
        let queue = DispatchQueue(label: "media.nuvio.trailer-hls-listener")
        self.listenerQueue = queue
        self.listenerFactory = listenerFactory
        self.schedule = schedule ?? { delay, work in
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        self.healthCheck = healthCheck ?? { port, done in
            TrailerLocalHLS.pingLoopback(port: port, queue: queue, done: done)
        }
        self.uptime = uptime ?? { ProcessInfo.processInfo.systemUptime }
        self.basePort = basePort
        self.observesLifecycle = observesLifecycle
    }

    /// Sendable snapshot of a Kotlin `TrailerAdaptiveTrack` (KMP classes aren't Sendable; the
    /// repack pipeline hops queues).
    private struct Track: Sendable {
        let url: String
        let codecs: String
        let bitrate: Int64
        let width: Int
        let height: Int
        let fps: Int
        let initStart: Int64
        let initEnd: Int64
        let indexStart: Int64
        let indexEnd: Int64

        init(_ track: TrailerAdaptiveTrack) {
            url = track.url
            codecs = track.codecs
            bitrate = track.bitrate
            width = Int(track.width)
            height = Int(track.height)
            fps = Int(track.fps)
            initStart = track.initStart
            initEnd = track.initEnd
            indexStart = track.indexStart
            indexEnd = track.indexEnd
        }
    }

    /// Diagnostics snapshot of the video rung a repack token serves (trailer health line).
    struct TrackSummary: Sendable {
        let height: Int
        let width: Int
        let fps: Int
        let bitrate: Int64
        let codecs: String
        let itag: String?
        let throttledN: Bool
    }

    // MARK: - Public API

    /// The best AVPlayer URL for a resolved trailer source: a local byte-range HLS master when the
    /// extractor surfaced a repack-worthy demuxed pair (and the repack builds), else the
    /// progressive/HLS URL exactly as before, else nil. Completion on the main queue.
    ///
    /// beta.19-rc1 verdict (B2): the LEGACY shape, still used by Detail. It keeps its old semantics
    /// exactly: no outer timeout (a slow repack is waited out). What changed underneath is the
    /// loopback listener wait, which is now bounded by the 2 s attempt deadline, so a listener that
    /// never reports back (H2) falls back to progressive instead of hanging this call forever.
    func playbackURL(for source: TrailerPlaybackSource, completion: @escaping @Sendable (String?) -> Void) {
        let inputs = sourceInputs(of: source)
        resolveRaw(videoId: inputs.videoId, progressive: inputs.progressive, repack: inputs.repack) { outcome in
            DispatchQueue.main.async { completion(outcome.legacyURL) }
        }
    }

    func playbackURL(for source: TrailerPlaybackSource) async -> String? {
        await withCheckedContinuation { continuation in
            playbackURL(for: source) { continuation.resume(returning: $0) }
        }
    }

    /// beta.19-rc1 verdict (B2): the inline-trailer shape. Same URL as `playbackURL`, but with a
    /// 12 s race so a pathological repack comes back as `.timedOut(progressive:)` (a transient, never
    /// "unavailable") instead of parking the card's resolution forever. Completion on the main queue.
    func playbackOutcome(for source: TrailerPlaybackSource,
                         timeout: TimeInterval = TrailerLocalHLS.inlinePlaybackURLTimeout,
                         completion: @escaping @Sendable (TrailerPlaybackURLOutcome) -> Void) {
        let inputs = sourceInputs(of: source)
        resolveTimed(videoId: inputs.videoId, progressive: inputs.progressive, timeout: timeout, repack: inputs.repack) { outcome in
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    func playbackOutcome(for source: TrailerPlaybackSource) async -> TrailerPlaybackURLOutcome {
        await withCheckedContinuation { continuation in
            playbackOutcome(for: source) { continuation.resume(returning: $0) }
        }
    }

    /// Primitive view of a `TrailerPlaybackSource` (Kotlin types stay out of the testable core).
    private struct SourceInputs {
        let videoId: String?
        let progressive: String?
        let repack: RepackWork?
    }

    private func sourceInputs(of source: TrailerPlaybackSource) -> SourceInputs {
        let progressive: String? = (source.progressiveUrl?.isEmpty == false) ? source.progressiveUrl : nil
        var work: RepackWork?
        if let video = source.adaptiveVideo, let audio = source.adaptiveAudio {
            let videoTrack = Track(video)
            let audioTrack = Track(audio)
            work = { [self] finish in repack(video: videoTrack, audio: audioTrack, completion: finish) }
        }
        // BUG-81: this is the single choke point every trailer surface's playback URL comes out of,
        // so it is where the YouTube video id gets attached to that URL. See
        // `TrailerVideoIdRegistry` for why a side table rather than a threaded parameter.
        return SourceInputs(videoId: source.videoId, progressive: progressive, repack: work)
    }

    /// beta.19-rc1 verdict (B2): the core of both playback APIs, free of Kotlin types and of the
    /// main-queue hop (callers add it), so unit tests drive it directly. No timeout. `repack == nil`
    /// means the source has no repack-worthy demuxed pair.
    func resolveRaw(videoId: String?, progressive: String?, repack: RepackWork?,
                    completion: @escaping @Sendable (TrailerPlaybackURLOutcome) -> Void) {
        guard let repack else {
            TrailerVideoIdRegistry.register(videoId, forPlaybackURL: progressive)
            completion(progressive.map(TrailerPlaybackURLOutcome.playable) ?? .nothingPlayable)
            return
        }
        let uptime = self.uptime
        let started = uptime()
        repack { local in
            let url = local ?? progressive
            TrailerVideoIdRegistry.register(videoId, forPlaybackURL: url)
            let elapsed = uptime() - started
            if elapsed > TrailerLocalHLS.slowRepackSeconds {
                NSLog("[TrailerRepack] playbackURL slow ms=%d", Int(elapsed * 1000))
            }
            completion(url.map(TrailerPlaybackURLOutcome.playable) ?? .nothingPlayable)
        }
    }

    /// `resolveRaw` raced against `timeout`. The race is a one-shot latch: a repack that finishes
    /// after the timeout is dropped (its playlists stay stored, which only warms a later request).
    func resolveTimed(videoId: String?, progressive: String?, timeout: TimeInterval, repack: RepackWork?,
                      completion: @escaping @Sendable (TrailerPlaybackURLOutcome) -> Void) {
        Self.race(
            timeout: timeout,
            schedule: schedule,
            work: { finish in resolveRaw(videoId: videoId, progressive: progressive, repack: repack, completion: finish) },
            onTimeout: {
                NSLog("[TrailerRepack] playbackURL timeout after=%.1fs fallback=%@", timeout, progressive == nil ? "none" : "progressive")
                // The caller will play the progressive URL, so attach the video id to it now
                // (the late repack, if it ever lands, registers its own local URL).
                TrailerVideoIdRegistry.register(videoId, forPlaybackURL: progressive)
                return .timedOut(progressive: progressive)
            },
            completion: completion
        )
    }

    /// First of `work` (calls `finish` once) and the timeout wins; the loser is dropped. `work` runs
    /// first and the timer is only armed when it did not already finish, so a synchronous answer
    /// leaves no timer behind. Factored out so the race is testable with a fake scheduler.
    static func race<T: Sendable>(timeout: TimeInterval,
                                  schedule: Scheduler,
                                  work: (_ finish: @escaping @Sendable (T) -> Void) -> Void,
                                  onTimeout: @escaping @Sendable () -> T,
                                  completion: @escaping @Sendable (T) -> Void) {
        let latch = TrailerOneShotLatch()
        work { value in
            if latch.fire() { completion(value) }
        }
        guard !latch.isFired else { return }
        schedule(timeout) {
            if latch.fire() { completion(onTimeout()) }
        }
    }

    /// The loopback port bound for the listener, or nil when it could not be started. Bounded by the
    /// 2 s attempt deadline, never by a caller timeout.
    func readyPort() async -> UInt16? {
        await withCheckedContinuation { continuation in
            ensureStarted { continuation.resume(returning: $0) }
        }
    }

    /// beta.19-rc1 verdict (B2): the URL to play for a CACHED playback URL. A loopback URL whose port
    /// is the ready one comes back unchanged; one whose listener moved to a different port is REBASED
    /// to the ready port when its token is still stored, so a port drift never forces a YouTube
    /// re-extraction (BUG-46). nil when the token is gone or no listener is ready. Non-loopback URLs
    /// (a googlevideo progressive/HLS URL) return unchanged.
    func servableURL(_ urlString: String, readyPort: UInt16?) -> String? {
        guard let url = URL(string: urlString), url.host == "127.0.0.1" else { return urlString }
        guard let token = Self.token(inPlaybackURL: urlString), hasToken(token), let readyPort else { return nil }
        if let current = url.port, current == Int(readyPort) { return urlString }
        guard var components = URLComponents(string: urlString) else { return nil }
        components.port = Int(readyPort)
        return components.string
    }

    /// The port named in one of this server's playback URLs (loopback only).
    static func port(inPlaybackURL urlString: String) -> UInt16? {
        guard let url = URL(string: urlString), url.host == "127.0.0.1", let port = url.port else { return nil }
        return UInt16(exactly: port)
    }

    /// BUG-46/B3: the token embedded in one of this server's playback URLs, or nil when `urlString`
    /// isn't one (a direct progressive/HLS googlevideo URL — nothing here to check).
    static func token(inPlaybackURL urlString: String) -> String? {
        guard let url = URL(string: urlString), url.host == "127.0.0.1" else { return nil }
        let comps = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.count == 2 else { return nil }
        return comps[0]
    }

    /// `true` while this server can still serve `token`'s playlists. Lets a `TrailerResolutionCache`
    /// hit verify its local URL *before* handing it to AVPlayer, instead of learning about an
    /// eviction from a 404 the user sees as a dead card.
    func hasToken(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return playlists[token] != nil
    }

    /// BUG-81 investigation (Wave F item C follow-up): a stable identity for `token`'s VIDEO
    /// stream, or nil when `token` was never minted (evicted, never seen by this server instance,
    /// or its video URL carried no `id` query item — nothing content-stable to report, same as
    /// `stableIdentity`'s own no-id fallback).
    ///
    /// Deliberately excludes the itag. YouTube's H.264 format ladder for one video (itags like
    /// 133-137/160/298/299) is one continuously-cropped source encoded at different
    /// resolutions/bitrates — never a different picture — and `TrailerExtractionPlatform.apple.kt`
    /// always selects the highest-resolution AVC rung it finds, so a fresh extraction of the SAME
    /// trailer can legitimately land on a different itag than the one a persisted zoom was
    /// measured against. `stableIdentity`'s own `token(video:audio:)` hash treats that as a brand
    /// new stream (by design — see its doc), so on the repack path `TrailerLetterboxProbe` was
    /// never able to VERIFY a persisted zoom against a re-extraction that picked a different rung:
    /// `token=mismatch` on effectively every relaunch, cold re-measure at the parity floor every
    /// time, a persisted zoom never confirmed OR corrected. This identity is the crop-relevant
    /// subset of that hash's input — same video, itag-independent — so `streamIdentity(of:)` in
    /// `TrailerHeroPlayerView.swift` can key the VERIFY comparison on it instead.
    ///
    /// Byte-range offsets and signed-URL expiry were never part of `stableIdentity` either — both
    /// are per-extraction serving plumbing, not picture geometry.
    ///
    /// Crop-geometry risk: sharing identity across itags assumes every AVC rung of one video shares
    /// one crop/letterbox. That holds for YouTube's ladder (one encode pipeline per upload, same
    /// aspect ratio at every rung) but isn't a protocol guarantee. If it were ever violated —
    /// e.g. a rendition family mixing a 4:3 SD source with a 16:9 HD re-master — the practical
    /// exposure is bounded, not silent: `TrailerLetterboxProbe.start()`'s VERIFY branch always
    /// re-measures behind a token match and calls `finish()`, which corrects (re-persists) any
    /// drift over `0.02`. Worst case is one relaunch showing a stale-but-plausible crop for the
    /// ~0.5-1.5s until the interim/final measurement lands, not a permanently wrong one.
    ///
    /// EMPIRICAL CORRECTION (sim soak, 2026-09-04, `TrailerSoakTests.testColdStoreFirstDwellRevealProfile`
    /// harvested against `-debug.trailerSmokeVideoId` — one fixed YouTube video, extracted three
    /// separate times): `itag` stayed `137` on every extraction, but the googlevideo `id=` query
    /// item itself was a DIFFERENT value every time (`o-AJbEeBZ...`, `o-AMk-fCjYnp...`,
    /// `o-APyRTSGf...`, …) — none sharing even a prefix. So this function's itag-only unification
    /// does NOT resolve the `persisted-hit token=mismatch` symptom by itself: `id=` reads as a
    /// per-extraction-request token minted by the CDN, not a stable identifier of the source
    /// video, contrary to `stableIdentity`'s own doc comment (which this function otherwise
    /// mirrors). The itag-sharing this function does provide is still correct and still the right
    /// behavior when itag IS the only thing that changed — it just isn't sufficient on its own.
    /// A real fix needs a video-id-stable identity that doesn't round-trip through the signed
    /// googlevideo URL at all — e.g. the actual YouTube video id (`rNZ0xKaCdus`-shaped, visible in
    /// the shared Kotlin extractor's own `[TrailerExtract] video=…` logs) threaded through
    /// `TrailerAdaptiveTrack`/`TrailerPlaybackSource` (`shared/.../trailer/TrailerPlaybackSource.kt`)
    /// down to this Swift layer, which is outside this type's current inputs.
    ///
    /// SUPERSEDED (2026-09-04): that real fix now exists. `TrailerPlaybackSource.videoId` carries
    /// the YouTube video id from the shared extractor, `TrailerVideoIdRegistry` (below) attaches it
    /// to the playback URL, and `TrailerLetterboxProbe.streamIdentity(of:videoId:)` prefers a
    /// `yt:<videoId>` identity over anything derived from the googlevideo URL. This function stays
    /// as the fallback for a URL with no registered video id (a source that never came from the
    /// YouTube extractor, or a registry entry evicted mid-session) — it is still strictly better
    /// than the raw repack token, just no longer the primary identity.
    static func contentIdentity(forToken token: String) -> String? {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.contentIdentities[token]
    }

    /// Diagnostics: the video rung served under `token`, or nil when unknown/evicted.
    static func trackSummary(forToken token: String) -> TrackSummary? {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.trackSummaries[token]
    }

    /// Test seam: registers the token/content-identity pair `repack(...)` would produce for this
    /// URL pair, without the sidx network fetch a real repack needs (unit tests can't drive that).
    /// `contentIdentity(forToken:)` coverage needs a real minted entry to look up — this is the
    /// only way to get one outside the live extraction pipeline. Returns the minted token.
    static func registerContentIdentityForTesting(videoURL: String, audioURL: String) -> String {
        let token = Self.token(videoURL: videoURL, audioURL: audioURL)
        shared.lock.lock()
        shared.contentIdentities[token] = Self.contentIdentity(videoURL: videoURL)
        shared.lock.unlock()
        return token
    }

    // MARK: - Repackaging

    private func repack(video: Track, audio: Track,
                        completion: @escaping @Sendable (String?) -> Void) {
        fetchSidx(track: video) { [weak self] videoSidx in
            guard let self else { completion(nil); return }
            guard let videoSidx else {
                NSLog("[TrailerRepack] video sidx fetch/parse FAILED -> progressive fallback")
                completion(nil)
                return
            }
            self.fetchSidx(track: audio) { audioSidx in
                guard let audioSidx else {
                    NSLog("[TrailerRepack] audio sidx fetch/parse FAILED -> progressive fallback")
                    completion(nil)
                    return
                }
                let master = Self.masterPlaylist(video: video, audio: audio)
                let videoMedia = Self.mediaPlaylist(track: video, sidx: videoSidx)
                let audioMedia = Self.mediaPlaylist(track: audio, sidx: audioSidx)
                let token = Self.token(video: video, audio: audio)
                self.store(token: token, contentIdentity: Self.contentIdentity(videoURL: video.url), summary: Self.trackSummary(of: video), files: [
                    "master.m3u8": Data(master.utf8),
                    "video.m3u8": Data(videoMedia.utf8),
                    "audio.m3u8": Data(audioMedia.utf8),
                ])
                self.ensureStarted { port in
                    guard let port else {
                        NSLog("[TrailerRepack] loopback bind FAILED -> progressive fallback")
                        completion(nil)
                        return
                    }
                    let url = "http://127.0.0.1:\(port)/\(token)/master.m3u8"
                    let summary = Self.trackSummary(of: video)
                    NSLog("[TrailerRepack] serving %dx%d avc1+mp4a (%d+%d segments) at %@ fps=%d itag=%@ n=%d",
                          video.width, video.height, videoSidx.segments.count, audioSidx.segments.count, url,
                          summary.fps, summary.itag ?? "-", summary.throttledN ? 1 : 0)
                    completion(url)
                }
            }
        }
    }

    /// BUG-46/BUG-55 (beta.12): googlevideo fetches must not ride the app's PERSISTENT cookie
    /// jar. `URLSession.shared` attaches `NSHTTPCookieStorage` cookies, and a YouTube identity
    /// cookie that gets rate-flagged is exactly the state that survives an app restart, dies
    /// with the container (the reporter's uninstall+reinstall "fix"), and comes back the same
    /// evening — the persisted-state profile BUG-46's escalation described. Ephemeral: no cookie
    /// send/store, no disk cache; nothing in this pipeline depends on cookie continuity.
    private static let mediaFetchSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    /// Fetch a track's `indexRange` bytes (the sidx box) and parse the segment table.
    private func fetchSidx(track: Track, completion: @escaping @Sendable (SidxIndex?) -> Void) {
        guard let url = URL(string: track.url) else { completion(nil); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("bytes=\(track.indexStart)-\(track.indexEnd)", forHTTPHeaderField: "Range")
        Self.mediaFetchSession.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let data, !data.isEmpty else {
                NSLog("[TrailerRepack] sidx http %d (%d bytes)", status, data?.count ?? 0)
                completion(nil)
                return
            }
            completion(Self.parseSidx(data, indexEnd: track.indexEnd))
        }.resume()
    }

    // MARK: - sidx parsing

    struct SidxIndex: Sendable {
        /// (byte size, duration in seconds) per media segment, in timeline order.
        let segments: [(size: Int64, duration: Double)]
        /// Absolute file offset of the first segment's first byte.
        let firstSegmentOffset: Int64
    }

    /// Minimal ISO-BMFF sidx parser: exactly one top-level `sidx` box is expected in the
    /// indexRange slice. Returns nil (→ progressive fallback) on anything surprising, including
    /// hierarchical indexes (reference_type=1), which YouTube doesn't emit for these formats.
    private static func parseSidx(_ data: Data, indexEnd: Int64) -> SidxIndex? {
        let bytes = [UInt8](data)
        guard bytes.count >= 32 else { return nil }
        func u32(_ o: Int) -> UInt32 {
            (UInt32(bytes[o]) << 24) | (UInt32(bytes[o + 1]) << 16) | (UInt32(bytes[o + 2]) << 8) | UInt32(bytes[o + 3])
        }
        func u64(_ o: Int) -> UInt64 { (UInt64(u32(o)) << 32) | UInt64(u32(o + 4)) }

        let boxSize = Int(u32(0))
        guard boxSize >= 32, boxSize <= bytes.count,
              bytes[4] == 0x73, bytes[5] == 0x69, bytes[6] == 0x64, bytes[7] == 0x78 else { // "sidx"
            return nil
        }
        let version = bytes[8]
        let timescale = u32(16)
        guard timescale > 0 else { return nil }
        var offset: Int
        let firstOffset: UInt64
        if version == 0 {
            firstOffset = UInt64(u32(24))
            offset = 28
        } else {
            firstOffset = u64(28)
            offset = 36
        }
        offset += 2 // reserved
        guard offset + 2 <= boxSize else { return nil }
        let refCount = Int((UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1]))
        offset += 2
        guard refCount > 0, offset + refCount * 12 <= boxSize else { return nil }

        var segments: [(size: Int64, duration: Double)] = []
        segments.reserveCapacity(refCount)
        for _ in 0..<refCount {
            let first = u32(offset)
            let durationTicks = u32(offset + 4)
            offset += 12
            if first & 0x8000_0000 != 0 { return nil } // hierarchical index — bail
            segments.append((size: Int64(first & 0x7FFF_FFFF), duration: Double(durationTicks) / Double(timescale)))
        }
        // Segment data starts right after the index box (plus any declared gap).
        return SidxIndex(segments: segments, firstSegmentOffset: indexEnd + 1 + Int64(firstOffset))
    }

    // MARK: - Playlist synthesis

    private static func masterPlaylist(video: Track, audio: Track) -> String {
        let bandwidth = max(Int(video.bitrate + audio.bitrate), 1_000_000)
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"",
        ]
        var streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS=\"\(video.codecs),\(audio.codecs)\",AUDIO=\"aud\""
        if video.width > 0 && video.height > 0 {
            streamInf += ",RESOLUTION=\(video.width)x\(video.height)"
        }
        lines.append(streamInf)
        lines.append("video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func mediaPlaylist(track: Track, sidx: SidxIndex) -> String {
        let target = Int((sidx.segments.map(\.duration).max() ?? 1).rounded(.up))
        let initLength = track.initEnd - track.initStart + 1
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(target, 1))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(track.url)\",BYTERANGE=\"\(initLength)@\(track.initStart)\"",
        ]
        var offset = sidx.firstSegmentOffset
        for segment in sidx.segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(offset)")
            lines.append(track.url)
            offset += segment.size
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Playlist store

    /// BUG-46/B3: the token for a track pair, not for a repack. Deriving it from the tracks'
    /// STABLE identity means re-resolving a trailer overwrites its own playlists instead of
    /// minting a second entry that pushes somebody else's out — and it keeps a `.resolved` cache
    /// entry pointing at a token the next repack will simply refresh. Signed googlevideo URLs are
    /// NOT stable identity: every re-extraction re-signs them (fresh `expire`/`sig`/`n` params and
    /// often a different CDN host), so hashing the full URLs minted a new token per extraction and
    /// recreated exactly the eviction-404 churn this exists to prevent (Codex round 8). The stable
    /// part is the stream selection itself — the `id` + `itag` query items — with the full URL
    /// kept only as a fallback for URLs that carry neither.
    private static func token(video: Track, audio: Track) -> String {
        token(videoURL: video.url, audioURL: audio.url)
    }

    /// URL-string form of the derivation above, byte-identical to it (`token(video:audio:)` just
    /// delegates here) — factored out so `registerContentIdentityForTesting(videoURL:audioURL:)`
    /// can mint a real token without constructing a Kotlin `TrailerAdaptiveTrack`.
    private static func token(videoURL: String, audioURL: String) -> String {
        let digest = SHA256.hash(data: Data("\(stableIdentity(videoURL))\n\(stableIdentity(audioURL))".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The picture-geometry-relevant identity for a video URL: the `id` query item alone, itag and
    /// everything else `stableIdentity` keeps dropped. Nil when the URL carries no `id` (mirrors
    /// `stableIdentity`'s own no-id fallback) — nothing content-stable to report, so
    /// `contentIdentity(forToken:)` returns nil and callers fall back to the opaque per-mint token.
    private static func contentIdentity(videoURL: String) -> String? {
        guard let components = URLComponents(string: videoURL) else { return nil }
        guard let id = (components.queryItems ?? []).first(where: { $0.name == "id" })?.value, !id.isEmpty else {
            return nil
        }
        return "id=\(id)"
    }

    private static func stableIdentity(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString) else { return urlString }
        let items = components.queryItems ?? []
        // The CONTENT id is required: an itag alone names a format ladder rung, identical across
        // every video — accepting it without the id would collapse different trailers onto one
        // token (Codex round 11). No id → fall back to the full URL (per-extraction tokens, the
        // pre-B3 behavior, safe just less dedup-friendly).
        guard let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty else {
            return urlString
        }
        let itag = items.first(where: { $0.name == "itag" })?.value
        return "id=\(id)&itag=\(itag ?? "-")"
    }

    private static func trackSummary(of track: Track) -> TrackSummary {
        let items = URLComponents(string: track.url)?.queryItems ?? []
        return TrackSummary(
            height: track.height,
            width: track.width,
            fps: track.fps,
            bitrate: track.bitrate,
            codecs: track.codecs,
            itag: items.first(where: { $0.name == "itag" })?.value,
            throttledN: items.contains(where: { $0.name == "n" })
        )
    }

    /// Test seam: stores a placeholder playlist set under `token`, so `hasToken` / `servableURL` have a
    /// real stored token to answer for without the sidx fetch a real repack needs.
    func storeTokenForTesting(_ token: String) {
        store(token: token, contentIdentity: nil, summary: nil, files: ["master.m3u8": Data("#EXTM3U\n".utf8)])
    }

    private func store(token: String, contentIdentity: String?, summary: TrackSummary?, files: [String: Data]) {
        lock.lock()
        // A re-store is a refresh of an existing trailer, not a new entry: replace the files and
        // move the token to the back of the eviction line rather than double-listing it.
        if playlists[token] != nil {
            tokenOrder.removeAll { $0 == token }
        }
        playlists[token] = files
        if let contentIdentity {
            contentIdentities[token] = contentIdentity
        } else {
            contentIdentities.removeValue(forKey: token)
        }
        if let summary {
            trackSummaries[token] = summary
        } else {
            trackSummaries.removeValue(forKey: token)
        }
        tokenOrder.append(token)
        while tokenOrder.count > Self.maxTokens {
            let evicted = tokenOrder.removeFirst()
            playlists.removeValue(forKey: evicted)
            contentIdentities.removeValue(forKey: evicted)
            trackSummaries.removeValue(forKey: evicted)
            if TrailerProbe.enabled {
                NSLog("[TrailerRepack] token evict token=%@ stored=%d max=%d", evicted, tokenOrder.count, Self.maxTokens)
            }
        }
        let stored = tokenOrder.count
        lock.unlock()
        // Phase 0 (BUG-46 candidate #3): a `TrailerResolutionCache` `.resolved` entry can hand out
        // this URL for up to 3h, but `maxTokens` bounds how long the token itself survives — this
        // is the mint side of the "cache says resolved, token already evicted" mismatch that
        // shows up as a 404 in `handle()` below. B3 narrowed that window (stable tokens, matching
        // capacities), so a `token mint` line that keeps reporting the same token for the same
        // title is the fix working, not a repeat.
        if TrailerProbe.enabled {
            NSLog("[TrailerRepack] token mint token=%@ stored=%d max=%d", token, stored, Self.maxTokens)
        }
    }

    // MARK: - Loopback listener (playlists only; media bytes go straight to googlevideo)

    // beta.19-rc1 verdict (B2, BUG-131): the listener lifecycle. Before this the server cached `port`
    // with no liveness check and no deadline, ignored `.waiting`, and only noticed a death if a
    // `.failed`/`.cancelled` callback happened to arrive. Two shapes of the same symptom (Steven's
    // video: every inline trailer dead after a trip to Infuse, until relaunch):
    //   H1  silent death: the socket is reclaimed while the app is suspended, no callback, `port`
    //       stays set, repacks hand out URLs on a dead port (-1004 / start watchdog).
    //   H2  start hang: a (re)start goes `.waiting` or never reports, so the waiters never resolve.
    // Fix shape: a per-attempt start deadline (H2); verify-then-rebuild on foreground, on a
    // connection-class playback failure, and after any state event past `.ready` (H1); rebuilds wait
    // for the old socket to cancel and retry the SAME port, so cached loopback URLs stay valid; a
    // budgeted eager rebuild so a flapping listener cannot loop.

    /// Resolves with the bound port, or nil when no listener could be bound within the attempt
    /// deadline(s). A ready port answers at once; liveness is verified on foreground and after a
    /// connection-class playback failure, not per call.
    func ensureStarted(completion: @escaping @Sendable (UInt16?) -> Void) {
        lock.lock()
        if let ready = port {
            lock.unlock()
            completion(ready)
            return
        }
        startWaiters.append(completion)
        if startInFlight {
            lock.unlock()
            return
        }
        beginStartLocked()
        lock.unlock()
        installLifecycleObserversIfNeeded()
        attemptStart()
    }

    /// Caller holds `lock`.
    private func beginStartLocked() {
        startInFlight = true
        startGeneration += 1
        preferredPort = lastBoundPort
        portOrder = Self.portOrder(base: basePort, count: Self.portCount, preferred: preferredPort)
        portIndex = 0
        samePortRetries = 0
    }

    /// Bind order for one start: the last port this server was ready on first (cached loopback URLs
    /// name it), then the rest of the range in order.
    static func portOrder(base: UInt16, count: Int, preferred: UInt16?) -> [UInt16] {
        let all = (0..<count).map { UInt16(truncatingIfNeeded: Int(base) + $0) }
        guard let preferred, all.contains(preferred) else { return all }
        return [preferred] + all.filter { $0 != preferred }
    }

    /// Creates and starts the candidate at `portOrder[portIndex]`. Each candidate has its own 2 s
    /// deadline. Calls out only with `lock` released.
    private func attemptStart() {
        while true {
            lock.lock()
            guard startInFlight, currentAttemptID == nil, port == nil else {
                lock.unlock()
                return
            }
            guard portIndex < portOrder.count else {
                let waiters = startWaiters
                startWaiters = []
                startInFlight = false
                lock.unlock()
                logListener("exhausted")
                waiters.forEach { $0(nil) }
                return
            }
            let candidatePort = portOrder[portIndex]
            let generation = startGeneration
            attemptSerial += 1
            let attemptID = attemptSerial
            let prefer = preferredPort
            lock.unlock()

            let candidate: TrailerLoopbackListening
            do {
                candidate = try listenerFactory(candidatePort)
            } catch {
                lock.lock()
                if startGeneration == generation { portIndex += 1 }
                lock.unlock()
                logListener("failed", "port=\(candidatePort) err=factory retry=0")
                continue
            }

            lock.lock()
            guard startInFlight, startGeneration == generation, currentAttemptID == nil, port == nil else {
                lock.unlock()
                candidate.cancel()
                return
            }
            listener = candidate
            currentAttemptID = attemptID
            lock.unlock()

            logListener("start", "port=\(candidatePort) prefer=\(prefer.map { String($0) } ?? "-")")
            schedule(Self.startDeadline) { [weak self] in
                self?.attemptDeadlineFired(attemptID: attemptID, generation: generation)
            }
            startCandidate(candidate, attemptID: attemptID, port: candidatePort)
            return
        }
    }

    private func startCandidate(_ candidate: TrailerLoopbackListening, attemptID: Int, port candidatePort: UInt16) {
        #if DEBUG
        lock.lock()
        let waitingFault = faultWaitingArmed
        lock.unlock()
        if waitingFault {
            // `-debug.trailerListenerFault waiting`: the listener is never started and only ever
            // reports `.waiting`, so the attempt deadline is what decides.
            handleListenerState(.waiting("debug fault"), attemptID: attemptID, port: candidatePort)
            return
        }
        #endif
        candidate.start(
            queue: listenerQueue,
            onState: { [weak self] state in
                self?.handleListenerState(state, attemptID: attemptID, port: candidatePort)
            },
            onConnection: { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        )
    }

    /// Every state event of every listener this server ever created lands here. Stale listeners
    /// (replaced, timed out, retired) are ignored, except the retired listener's `.cancelled`,
    /// which releases a rebuild that is waiting on it.
    private func handleListenerState(_ state: TrailerListenerState, attemptID: Int, port boundPort: UInt16) {
        lock.lock()
        if retiringID == attemptID {
            if state == .cancelled {
                retiring = nil
                retiringID = nil
                let waitingToken = rebuildToken
                rebuildToken = nil
                lock.unlock()
                if waitingToken != nil { attemptStart() }
            } else {
                lock.unlock()
            }
            return
        }
        guard currentAttemptID == attemptID else {
            lock.unlock()
            return
        }
        let isReady = port != nil
        switch state {
        case .setup:
            lock.unlock()

        case .ready:
            if isReady {
                lock.unlock()
                return
            }
            port = boundPort
            lastBoundPort = boundPort
            samePortRetries = 0
            startInFlight = false
            let waiters = startWaiters
            startWaiters = []
            lock.unlock()
            logListener("ready", "port=\(boundPort) waiters=\(waiters.count)")
            waiters.forEach { $0(boundPort) }
            #if DEBUG
            scheduleDebugCycleIfNeeded()
            #endif

        case let .waiting(error):
            lock.unlock()
            if isReady {
                markDead(attemptID: attemptID, reason: "waiting")
            } else {
                // Before ready: path evaluation can still settle. The attempt deadline decides.
                logListener("waiting", "port=\(boundPort) err=\(error)")
            }

        case .failed, .cancelled:
            if isReady {
                lock.unlock()
                markDead(attemptID: attemptID, reason: state == .cancelled ? "cancelled" : "failed")
                return
            }
            // A bind failure (or an un-requested cancel) before ready. The preferred port is
            // retried a few times at 100 ms (an old socket can still be closing); anything else
            // moves to the next port at once.
            let failedCandidate = listener
            listener = nil
            currentAttemptID = nil
            let retryNumber: Int
            if boundPort == preferredPort, samePortRetries < Self.sameBindRetries {
                samePortRetries += 1
                retryNumber = samePortRetries
            } else {
                portIndex += 1
                retryNumber = 0
            }
            let generation = startGeneration
            lock.unlock()
            let reason: String
            if case let .failed(error) = state { reason = error } else { reason = "cancelled" }
            logListener("failed", "port=\(boundPort) err=\(reason) retry=\(retryNumber)")
            failedCandidate?.cancel()
            if retryNumber > 0 {
                schedule(Self.sameBindRetryDelay) { [weak self] in
                    self?.retrySamePort(generation: generation)
                }
            } else {
                attemptStart()
            }
        }
    }

    private func retrySamePort(generation: Int) {
        lock.lock()
        let proceed = startInFlight && startGeneration == generation && currentAttemptID == nil && port == nil
        lock.unlock()
        if proceed { attemptStart() }
    }

    /// The attempt deadline: the candidate neither bound nor failed in 2 s. Its CURRENT waiters get
    /// nil (their playback falls back to progressive at once); the next port is tried under a fresh
    /// deadline so a later caller still finds a listener. A late `.ready` from the cancelled
    /// candidate is ignored (its attempt ID is no longer current).
    private func attemptDeadlineFired(attemptID: Int, generation: Int) {
        lock.lock()
        guard startInFlight, startGeneration == generation, currentAttemptID == attemptID, port == nil else {
            lock.unlock()
            return
        }
        let stuck = listener
        let stuckPort = portIndex < portOrder.count ? portOrder[portIndex] : 0
        listener = nil
        currentAttemptID = nil
        portIndex += 1
        let waiters = startWaiters
        startWaiters = []
        lock.unlock()
        logListener("start-timeout", "port=\(stuckPort) waiters=\(waiters.count)")
        stuck?.cancel()
        waiters.forEach { $0(nil) }
        attemptStart()
    }

    /// The ready listener is dead (a state event past `.ready`, or a failed health check). Clears the
    /// port and, when the eager-rebuild budget allows (3 per 60 s), rebuilds at once, preferring the
    /// same port; otherwise the next `ensureStarted` starts lazily.
    /// `attemptID` pins the verdict to the listener it was reached for.
    private func markDead(attemptID: Int?, reason: String) {
        lock.lock()
        guard let current = currentAttemptID, attemptID == nil || attemptID == current, let deadPort = port else {
            lock.unlock()
            return
        }
        let dead = listener
        listener = nil
        port = nil
        currentAttemptID = nil
        let now = uptime()
        eagerRebuilds.removeAll { now - $0 > Self.eagerRebuildWindow }
        let eager = eagerRebuilds.count < Self.eagerRebuildBudget
        var rebuildTokenValue = 0
        if eager {
            eagerRebuilds.append(now)
            beginStartLocked()   // bumps the generation; the port order prefers `lastBoundPort`
            retiring = dead
            retiringID = current
            rebuildTokenValue = startGeneration
            rebuildToken = rebuildTokenValue
        } else {
            startGeneration += 1
        }
        let token = rebuildTokenValue
        lock.unlock()
        logListener("dead", "port=\(deadPort) reason=\(reason)")
        guard eager else {
            dead?.cancel()
            logListener("budget", "port=\(deadPort) rebuilds=\(Self.eagerRebuildBudget)/\(Int(Self.eagerRebuildWindow))s lazy=1")
            return
        }
        logListener("rebuild", "reason=\(reason) prefer=\(deadPort)")
        dead?.cancel()
        schedule(Self.retireWait) { [weak self] in
            self?.rebuildWaitElapsed(token: token)
        }
    }

    /// 0.5 s passed without the retired listener's `.cancelled`: bind anyway.
    private func rebuildWaitElapsed(token: Int) {
        lock.lock()
        guard rebuildToken == token else {
            lock.unlock()
            return
        }
        rebuildToken = nil
        retiring = nil
        retiringID = nil
        lock.unlock()
        logListener("retire-timeout")
        attemptStart()
    }

    /// Pings the ready listener (`HEAD /_ping`, any bytes back within 1 s = alive). Dead → the
    /// listener is marked dead and rebuilt. One check at a time.
    func verifyListener(reason: String) {
        lock.lock()
        guard let checkedPort = port, let attemptID = currentAttemptID, !verifyInFlight else {
            lock.unlock()
            return
        }
        verifyInFlight = true
        lock.unlock()
        let started = uptime()
        healthCheck(checkedPort) { [weak self] alive in
            guard let self else { return }
            self.lock.lock()
            self.verifyInFlight = false
            self.lock.unlock()
            let ms = Int((self.uptime() - started) * 1000)
            self.logListener("health", "port=\(checkedPort) alive=\(alive ? 1 : 0) ms=\(ms) reason=\(reason)")
            if !alive { self.markDead(attemptID: attemptID, reason: reason) }
        }
    }

    /// App lifecycle. `.active` after a background verifies the listener FIRST (the socket usually
    /// survives, and a needless rebuild is what could strand a cached loopback URL); only a dead
    /// verdict rebuilds. `.active` without a prior background does nothing.
    func noteLifecycle(_ event: LifecycleEvent) {
        switch event {
        case .background:
            lock.lock()
            backgroundedSinceActive = true
            lock.unlock()
            #if DEBUG
            applyDebugBackgroundFault(Self.debugFault)
            #endif
        case .active:
            lock.lock()
            let wasBackgrounded = backgroundedSinceActive
            backgroundedSinceActive = false
            let hasReadyPort = port != nil
            lock.unlock()
            guard wasBackgrounded, hasReadyPort else { return }
            #if DEBUG
            if Self.debugFault == .silentNoRebuild {
                logListener("verify-skipped", "reason=active fault=silent-norebuild")
                return
            }
            #endif
            verifyListener(reason: "active")
        }
    }

    /// Registers the foreground/background observers once, the first time the server starts.
    private func installLifecycleObserversIfNeeded() {
        guard observesLifecycle else { return }
        lock.lock()
        let first = !lifecycleObserversInstalled
        lifecycleObserversInstalled = true
        lock.unlock()
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { Self.addLifecycleObservers(for: self) }
        }
    }

    @MainActor
    private static func addLifecycleObservers(for server: TrailerLocalHLS?) {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak server] _ in
            server?.noteLifecycle(.background)
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak server] _ in
            server?.noteLifecycle(.active)
        }
    }

    /// Real health check: connect to 127.0.0.1:port, send `HEAD /_ping`, any reply = alive.
    static func pingLoopback(port: UInt16, queue: DispatchQueue, done: @escaping @Sendable (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            done(false)
            return
        }
        let connection = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
        let latch = TrailerOneShotLatch()
        let finish: @Sendable (Bool) -> Void = { alive in
            guard latch.fire() else { return }
            connection.cancel()
            done(alive)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = Data("HEAD /_ping HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
                connection.send(content: request, completion: .contentProcessed { error in
                    if error != nil { finish(false) }
                })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, error in
                    finish(error == nil && data?.isEmpty == false)
                }
            case .failed, .waiting, .cancelled:
                // A refused loopback connect parks in `.waiting` on NWConnection: nothing is listening.
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + TrailerLocalHLS.healthTimeout) { finish(false) }
    }

    // MARK: - Probe lines and DEBUG fault knobs

    /// `[TrailerRepack] listener <event> <detail> gen=N conns=N`. Unconditional (a device log must
    /// carry these without the probe knob). Never call with `lock` held.
    private func logListener(_ event: String, _ detail: String = "") {
        lock.lock()
        let generation = startGeneration
        let conns = liveConnections
        lock.unlock()
        let line = (detail.isEmpty ? event : "\(event) \(detail)") + " gen=\(generation) conns=\(conns)"
        NSLog("[TrailerRepack] listener %@", line)
        #if DEBUG
        let isRebuild = event == "rebuild"
        DispatchQueue.main.async {
            MainActor.assumeIsolated { TrailerListenerDebug.shared.note(line, isRebuild: isRebuild) }
        }
        #endif
    }

    #if DEBUG
    /// `silent` / `silent-norebuild` / `waiting` on a background: cancel the live `NWListener` with its
    /// handlers detached, keeping `port`. `waiting` also arms the never-ready fault for every listener
    /// created afterwards (without the kill, nothing would be created after the background at all).
    private func applyDebugBackgroundFault(_ fault: TrailerListenerFault) {
        guard fault != .off else { return }
        lock.lock()
        let live = port != nil ? listener : nil
        let livePort = port
        if fault == .waiting { faultWaitingArmed = true }
        lock.unlock()
        if let real = live as? NWTrailerLoopbackListener {
            real.cancelSilently()
            logListener("fault", "mode=\(fault.rawValue) silent-cancel port=\(livePort.map { String($0) } ?? "-")")
        } else {
            logListener("fault", "mode=\(fault.rawValue) no-real-listener")
        }
    }

    private func scheduleDebugCycleIfNeeded() {
        guard let after = Self.debugCycleAfter else { return }
        lock.lock()
        let first = !cycleScheduled
        cycleScheduled = true
        lock.unlock()
        guard first else { return }
        schedule(after) { [weak self] in
            self?.runDebugLifecycleCycle()
        }
    }

    /// In-process background→active cycle (`-debug.trailerListenerLifecycleCycleAfterS`), so a UI leg
    /// needs no `press(.home)` / `activate()`. With no fault knob it applies the `silent` fault itself.
    private func runDebugLifecycleCycle() {
        logListener("debug-cycle", "begin")
        noteLifecycle(.background)
        if Self.debugFault == .off { applyDebugBackgroundFault(.silent) }
        // The cancel lands asynchronously; let the socket actually close so the foreground ping sees
        // the death the way it would after a real suspend.
        schedule(0.5) { [weak self] in
            self?.noteLifecycle(.active)
        }
    }
    #endif

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        lock.lock()
        liveConnections += 1
        lock.unlock()
        let tracker = TrailerConnectionTracker()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed:
                connection.cancel()
                if tracker.markClosed() { self?.connectionClosed() }
            case .cancelled:
                if tracker.markClosed() { self?.connectionClosed() }
            default:
                break
            }
        }
        connection.start(queue: connQueue)
        receive(connection: connection, buffer: Data(), tracker: tracker)
        // A connection that never completes its request header is cancelled.
        schedule(Self.connectionHeaderTimeout) {
            if !tracker.headerComplete { connection.cancel() }
        }
    }

    private func connectionClosed() {
        lock.lock()
        liveConnections = max(0, liveConnections - 1)
        lock.unlock()
    }

    private func receive(connection: NWConnection, buffer: Data, tracker: TrailerConnectionTracker) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > 32 * 1024 { connection.cancel(); return }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.receive(connection: connection, buffer: buffer, tracker: tracker) }
                return
            }
            tracker.markHeaderComplete()
            guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
                self.send(status: "400 Bad Request", body: Data(), on: connection)
                return
            }
            self.handle(head: head, on: connection)
        }
    }

    private func handle(head: String, on connection: NWConnection) {
        let requestLine = head.components(separatedBy: "\r\n").first?.split(separator: " ").map(String.init) ?? []
        let method = requestLine.first?.uppercased() ?? ""
        guard requestLine.count >= 2, method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed", body: Data(), on: connection)
            return
        }
        let path = requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestLine[1]
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // beta.19-rc1 verdict (B2): the health ping answers before any playlist lookup.
        if comps.count == 1, comps[0] == "_ping" {
            send(status: "204 No Content", body: Data(), on: connection, isHead: true)
            return
        }
        lock.lock()
        let body = comps.count == 2 ? playlists[comps[0]]?[comps[1]] : nil
        let stored = tokenOrder.count
        lock.unlock()
        guard let body else {
            // Phase 0 (BUG-46 candidate #3 — the direct probe): a `TrailerResolutionCache`
            // `.resolved` entry can point at a token this loopback server no longer has (evicted
            // by `maxTokens`, or never minted). AVPlayer sees this 404, the item fails, and the
            // existing `onFailure` fail-soft (static backdrop / collapsed card) covers it.
            if TrailerProbe.enabled {
                let token = comps.first ?? "?"
                NSLog("[TrailerRepack] 404 token=%@ stored=%d", token, stored)
            }
            send(status: "404 Not Found", body: Data(), on: connection)
            return
        }
        send(status: "200 OK", body: body, on: connection, isHead: method == "HEAD")
    }

    private func send(status: String, body: Data, on connection: NWConnection, isHead: Bool = false) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/vnd.apple.mpegurl\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if !isHead { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// BUG-81: playback URL → YouTube video id, so `TrailerLetterboxProbe` can key a persisted zoom on
/// the one identifier that survives a re-extraction of the same trailer.
///
/// A side table rather than a parameter threaded through every surface, because the playback URL is
/// all some call sites have left: `TrailerResolutionCache` memoizes a *URL string* per title, so a
/// second dwell on a title inside one launch replays that URL with no `TrailerPlaybackSource`
/// anywhere in scope. Registering at `TrailerLocalHLS.playbackURL(for:)` — the single choke point
/// every surface's URL comes out of — covers the Detail hero, the Trailers row clips, the inline
/// catalog cards and the Home hero alike, cache hits included. Surfaces that DO still hold the
/// source pass the id explicitly instead (`TrailerHeroPlayer.videoId`), which wins over this table.
///
/// Process-local and bounded; nothing is persisted. A cold launch starts empty and re-extraction
/// re-registers, which is exactly the flow the persisted zoom cache is verified against.
nonisolated enum TrailerVideoIdRegistry {
    /// Matches `TrailerLocalHLS.maxTokens` / `TrailerResolutionCache.capacity`: one entry per
    /// distinct trailer URL, evicted on the same scale as the stores it shadows.
    private static let capacity = 200

    private static let lock = NSLock()
    nonisolated(unsafe) private static var ids: [String: String] = [:]
    nonisolated(unsafe) private static var order: [String] = []

    /// No-op for a nil/empty URL or video id — an unregistered URL simply falls back to the
    /// URL-derived identity, which is what shipped before.
    static func register(_ videoId: String?, forPlaybackURL url: String?) {
        guard let url, !url.isEmpty, let videoId, !videoId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if ids.updateValue(videoId, forKey: url) == nil {
            order.append(url)
            while order.count > capacity {
                ids.removeValue(forKey: order.removeFirst())
            }
        }
    }

    static func videoId(forPlaybackURL url: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return ids[url]
    }

    /// Test seam: unit tests share one process, so a registry left populated by one case would leak
    /// into the next.
    static func removeAllForTesting() {
        lock.lock()
        defer { lock.unlock() }
        ids.removeAll()
        order.removeAll()
    }
}

/// beta.19-rc1 verdict (B2): DEBUG harness sink for the listener lifecycle. Every `[TrailerRepack]
/// listener …` probe line is mirrored here (on the main queue) so a UI leg can read the lifecycle off
/// an accessibility label instead of a device log. A leaf view renders it (`debug_trailerListener`);
/// nothing in a release build writes to it.
///
/// `last` is the newest event, `recent` the newest few joined with " | " (a `rebuild` is usually
/// followed by `start`/`ready` lines within a second, so an oracle that wants "a rebuild happened"
/// reads `rebuilds` or `recent`, not `last`).
@MainActor
final class TrailerListenerDebug: ObservableObject {
    static let shared = TrailerListenerDebug()

    @Published private(set) var last = "-"
    @Published private(set) var recent = "-"
    private(set) var rebuilds = 0
    private var history: [String] = []

    func note(_ line: String, isRebuild: Bool) {
        // `rebuilds` first: `last` is the publisher a leaf view re-renders on.
        if isRebuild { rebuilds += 1 }
        history.append(line)
        if history.count > 6 { history.removeFirst() }
        recent = history.joined(separator: " | ")
        last = line
    }
}
