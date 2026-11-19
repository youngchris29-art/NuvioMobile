import Foundation

/// Why the keyframe thumbnailer stopped for a file (P3). `stop(_:)` with a file-level reason ends
/// everything; the budget, cap and store reasons end the pre-warm only (`prewarmStopped`), and the
/// scrub ceiling ends scrub jobs too. `reconnected` (review r4 #1, owner's call): a live reconnect
/// ended Whole Video's reads of unwatched parts for the rest of the playback
/// (`SeekPreviewTimeline.liveReconnected`).
nonisolated enum ThumbStopReason: String, Sendable {
    case frameCap, storeFull, byteBudget, httpRefused, openFailed, noIndex, container, dvProfile5, stalled, modeOff, reconnected
}

/// When the mpv keyframe thumbnailer decodes, and which keyframe (P3, spec §3 with critique C1,
/// C2). Pure and main-thread owned, like `HarvestScheduler`: the controller builds `Inputs` from
/// cached values on every `refreshState` (and after every finished job), and never reads the
/// store actor synchronously: `Inputs.store` is the last `SeekPreviewSnapshot` an insert returned.
///
/// Two kinds of job, one in flight at a time:
/// - **scrub**: the viewer scrubbed to a spot the store has no frame for (or only one more than
///   5 s away). Debounced 50 ms, last target wins; snapped to the keyframe at or before the target;
///   runs ahead of any queued pre-warm once the in-flight job ends. Ignores cache health and recent
///   input (the viewer is asking now), bounded by the scrub ceiling (budget + 50 MB).
/// - **prewarm**: fills unwatched ground coarse to fine (60 s, 30 s, target spacing), ahead of the
///   playhead first (behind counts double). At most `framesPerTick` per `tickSec` pass, back to
///   back. Needs a healthy cache (C2), no recent input, no scrub, quiet after seeks and scrubs,
///   room in the store, bytes under the budget. Runs while paused.
///
/// Both kinds wait for: no `paused-for-cache`, no seek in flight, no harvest capture in flight
/// (one heavy thing at a time), and an open thumbnailer.
nonisolated struct ThumbScheduler {
    struct Config: Equatable {
        var tickSec = 10.0, framesPerTick = 8, frameCap = 1500
        var scrubDebounceSec = 0.05, scrubRefineSec = 5.0
        var openAfterHealthySec = 20.0, healthyCacheSec = 15.0, healthyCacheFill = 0.6, cacheFallLimitSec = 2.0
        var quietAfterSeekSec = 3.0, quietAfterScrubSec = 2.0
        /// A stored stamp this close to a keyframe means that keyframe is already in the store.
        var duplicateWindowSec = 1.0
        /// Review r2 P2 #1: after a scrub session the thumbnailer stays open this long with no scrub
        /// activity before the idle close (a reopen costs a connect, the header and three requests).
        var idleCloseAfterScrubSec = 60.0
    }

    enum Job: Equatable {
        case scrub(Double)
        case prewarm(Double)
        var sec: Double { switch self { case .scrub(let s), .prewarm(let s): return s } }
        var isScrub: Bool { if case .scrub = self { return true } else { return false } }
        /// The probe/log word (`job=scrub|prewarm`).
        var name: String { isScrub ? "scrub" : "prewarm" }
    }

    /// What became of a job. The controller maps the thumbnailer result and the store insert:
    /// `Outcome(insert:keyframeSec:)` for a frame; `.failed` for a transient frame failure;
    /// `.aborted` for a closed thumbnailer. A file-level failure is `stop(_:)` plus `.failed`.
    enum Outcome: Equatable {
        case stored(keyframeSec: Double), duplicate(keyframeSec: Double), rejectedFull, failed, aborted

        init(insert: SeekPreviewInsertOutcome, keyframeSec: Double) {
            switch insert {
            case .stored, .replaced: self = .stored(keyframeSec: keyframeSec)
            case .keptExisting: self = .duplicate(keyframeSec: keyframeSec)
            case .rejectedFull: self = .rejectedFull
            case .invalid: self = .failed
            }
        }
    }

    struct Inputs {
        var now: TimeInterval
        var positionSec: Double
        var durationSec: Double
        /// mpv `pause` (pre-warm runs while paused; paused time does not count toward the open).
        var paused: Bool
        /// mpv `paused-for-cache`.
        var cacheWait: Bool
        /// `demuxer-cache-duration`.
        var cacheSec: Double
        /// Change of `cacheSec` over the last 10 s (`ThumbCacheTrend`).
        var cacheTrendSec: Double
        /// `ThumbScheduler.cacheReachesEnd(...)`.
        var cacheReachesEnd: Bool
        /// Forward cache bytes / `demuxer-max-bytes` (C2; `ThumbScheduler.cacheFill(...)`).
        var cacheFill: Double
        var seekInFlight: Bool
        /// Seek preview lookups are running (GitHub #33: a hold, a scrub or a click's card with a
        /// request target, `SeekPreviewCoordinator.previewActive`).
        var previewActive: Bool
        /// A press in the last `HarvestScheduler.recentInputSec`.
        var recentInput: Bool
        /// A harvest capture is in flight (P2 `harvest.inFlight`).
        var harvestInFlight: Bool
        /// The controller's mirror of the store (the last snapshot an insert returned, C1).
        var store: SeekPreviewSnapshot
        /// What the budget has charged so far, across reopens (`KeyframeThumbnailer.bytesCharged`
        /// plus every closed thumbnailer's, review r1 P1).
        var bytesRead: Int64
        var byteBudget: Int64
        var scrubCeiling: Int64
        /// The thumbnailer opened (`.ready`).
        var opened: Bool
        /// BUG-180 (Steven rc7): the transport bar or the top panel is on screen without a scrub.
        /// Pre-warm (and the pre-warm open) waits; a scrub job still runs (the bar is up for it).
        var overlayUp: Bool = false
    }

    // MARK: Budget and cache helpers (pure, for the controller)

    static let mib: Int64 = 1024 * 1024

    /// Decision 4 with review r2 P3 #2: 2 % of the file between 16 MB and 150 MB, never more than
    /// a tenth of the file; 40 MB when the size is unknown. The 16 MB floor pays one open (about
    /// 3 MB charged) and a pre-warm pass on a TV episode; the tenth keeps a tiny file from spending
    /// more on previews than on itself (the 116 MB smoke fixture gets 11.6 MB).
    static func byteBudget(fileSize: Int64?) -> Int64 {
        guard let size = fileSize, size > 0 else { return 40 * mib }
        return min(max(min(size / 50, 150 * mib), 16 * mib), size / 10)
    }

    /// Scrub jobs may overrun the pre-warm budget by 50 MB.
    static func scrubCeiling(budget: Int64) -> Int64 { budget + 50 * mib }

    /// `fw-bytes / demuxer-max-bytes`, 0 when either is unknown. `maxBytes` is what `setupMpv`
    /// applied (150 MiB when Streaming Buffer is unset).
    static func cacheFill(forwardBytes: Int64, maxBytes: Int64) -> Double {
        guard forwardBytes > 0, maxBytes > 0 else { return 0 }
        return min(Double(forwardBytes) / Double(maxBytes), 1)
    }

    static func cacheReachesEnd(positionSec: Double, cacheSec: Double, durationSec: Double) -> Bool {
        durationSec > 0 && positionSec + cacheSec >= durationSec - 1
    }

    /// Decision 6: 10 s up to two hours, `duration / 720` beyond.
    static func targetSpacing(duration: Double) -> Double {
        duration <= 7200 ? 10 : duration / 720
    }

    /// Median gap of a sorted keyframe index (nil with fewer than two entries). The controller
    /// hands it to `SeekPreviewStore.setKeyframeSpacing`.
    static func medianGap(_ index: [Double]) -> Double? {
        guard index.count >= 2 else { return nil }
        var gaps = zip(index.dropFirst(), index).map { $0 - $1 }.filter { $0 > 0 }
        guard !gaps.isEmpty else { return nil }
        gaps.sort()
        let mid = gaps.count / 2
        return gaps.count % 2 == 1 ? gaps[mid] : (gaps[mid - 1] + gaps[mid]) / 2
    }

    // MARK: State

    let config: Config
    let enabled: Bool
    private(set) var inFlight: Job?
    /// Pre-warm and scrub frames stored (the probe's `decoded=`).
    private(set) var decoded = 0
    /// File-level stop: nothing more runs.
    private(set) var stopped: ThumbStopReason?
    /// Pre-warm-only stop (budget, cap, store full); scrub jobs carry on to their ceiling.
    private(set) var prewarmStopped: ThumbStopReason?
    /// When the pending scrub becomes due (the controller arms a work item for it).
    var pendingScrubDueAt: TimeInterval? { pendingScrub?.dueAt }
    private(set) var openRequested = false
    private(set) var healthyPlaySec: Double = 0
    private(set) var keyframeIndex: [Double] = []
    /// Keyframes and slots already tried (sorted).
    private(set) var tried: [Double] = []

    private var pendingScrub: (target: Double, dueAt: TimeInterval)?
    private var lastScrubEnd: TimeInterval = -.infinity
    /// Review r2 P2 #1: the last scrub miss, scrub job start or finish, or scrub end (nil = none
    /// since the last idle close).
    private var lastScrubActivity: TimeInterval?
    private var lastSeekLanded: TimeInterval = -.infinity
    private var lastClock: TimeInterval?
    // Pre-warm pass.
    private var passActive = false
    private var passStartedAt: TimeInterval = -.infinity
    private var passIssued = 0
    private var passOrder: [Double] = []
    private var passEndedUnreported = false

    init(config: Config = .init(), enabled: Bool) {
        self.config = config
        self.enabled = enabled
        if !enabled { stopped = .modeOff }
    }

    // MARK: Events

    /// The thumbnailer's keyframe index (seconds on mpv's timeline). Empty = a uniform grid.
    mutating func setKeyframeIndex(_ secs: [Double]) {
        keyframeIndex = secs.filter(\.isFinite).sorted()
    }

    /// The scrub lookup missed (or hit further than `scrubRefineSec`): ask for the keyframe there.
    /// A newer miss replaces a pending one (last wins).
    mutating func noteScrubMiss(target: Double, now: TimeInterval) {
        guard enabled, stopped == nil, target.isFinite else { return }
        pendingScrub = (max(target, 0), now + config.scrubDebounceSec)
        lastScrubActivity = now
    }

    /// True when a scrub lookup result should ask the decoder: no frame, or one more than 5 s off.
    func lookupWantsRefine(target: Double, matchSec: Double?) -> Bool {
        guard enabled, stopped == nil else { return false }
        guard let matchSec else { return true }
        return abs(matchSec - target) > config.scrubRefineSec
    }

    mutating func noteScrubEnded(now: TimeInterval) {
        lastScrubEnd = now
        pendingScrub = nil
        lastScrubActivity = now
    }

    mutating func noteSeekLanded(now: TimeInterval) {
        lastSeekLanded = now
    }

    /// File-level stop (open refused, HTTP refusal, stall, live reconnect). Pre-warm-only reasons go through
    /// `noteFinished` and the gates.
    mutating func stop(_ reason: ThumbStopReason) {
        if stopped == nil { stopped = reason }
        pendingScrub = nil
        endPass()
    }

    /// Drops the in-flight job and any pending scrub and ends the pass; keeps `decoded`, `tried`
    /// and everything the store holds (a cancelled pass keeps its frames, decision 9).
    mutating func cancel() {
        inFlight = nil
        pendingScrub = nil
        endPass()
    }

    /// Review r1 P1, r2 P2 #1: nothing more will run until the viewer scrubs (the pre-warm
    /// stopped, no job, no pending scrub, no preview lookups running), and one of:
    /// - no scrub since the thumbnailer opened (the close that follows the pre-warm stop);
    /// - the last request is still open at the host (`requestLeftOpen`: 4K ranges, an open range);
    /// - `idleCloseAfterScrubSec` passed since the last scrub activity.
    /// So a viewer who scrubs, plays and scrubs again within a minute keeps the open thumbnailer.
    /// The controller then closes it and calls `noteIdleClosed`.
    func idleCloseWanted(now: TimeInterval, previewActive: Bool, requestLeftOpen: Bool) -> Bool {
        guard enabled, stopped == nil, prewarmStopped != nil, inFlight == nil, pendingScrub == nil, !previewActive else {
            return false
        }
        guard let last = lastScrubActivity else { return true }
        return requestLeftOpen || now - last >= config.idleCloseAfterScrubSec
    }

    /// The thumbnailer was closed while idle: the next scrub miss opens it again (with the facts
    /// the first open learned, so only the connect and the header are paid).
    mutating func noteIdleClosed() {
        openRequested = false
        lastScrubActivity = nil
    }

    /// True once per pass that issued at least one job, after it ended (release the decoder).
    mutating func takePassEnded() -> Bool {
        defer { passEndedUnreported = false }
        return passEndedUnreported
    }

    // MARK: Decisions

    /// True once: on the first pending scrub, or after `openAfterHealthySec` of healthy, unpaused
    /// playback. Never while `paused-for-cache` (it must not compete with buffering).
    mutating func shouldOpen(_ i: Inputs) -> Bool {
        advanceClock(i)
        guard enabled, stopped == nil, !openRequested, !i.opened, !i.cacheWait else { return false }
        // Once the pre-warm has stopped only a scrub opens (the reopen after an idle close).
        guard pendingScrub != nil
                || (prewarmStopped == nil && !i.overlayUp && healthyPlaySec >= config.openAfterHealthySec) else {
            return false
        }
        openRequested = true
        return true
    }

    /// The job to start now, or nil. The caller then calls `noteStarted`.
    mutating func next(_ i: Inputs) -> Job? {
        advanceClock(i)
        guard enabled, stopped == nil, inFlight == nil else { return nil }
        guard !i.cacheWait, !i.seekInFlight, !i.harvestInFlight, i.opened else {
            endPass()
            return nil
        }
        if let job = nextScrub(i) { return job }
        return nextPrewarm(i)
    }

    mutating func noteStarted(_ job: Job, now: TimeInterval) {
        inFlight = job
        if case .scrub = job { pendingScrub = nil; lastScrubActivity = now }
    }

    mutating func noteFinished(_ job: Job, result: Outcome, now: TimeInterval) {
        if inFlight == job { inFlight = nil }
        if job.isScrub { lastScrubActivity = now }
        switch result {
        case .stored(let kf):
            decoded += 1
            markTried(job.sec); markTried(kf)
        case .duplicate(let kf):
            markTried(job.sec); markTried(kf)
        case .rejectedFull:
            markTried(job.sec)
            stopPrewarm(.storeFull)
        case .failed:
            markTried(job.sec)
        case .aborted:
            break
        }
    }

    // MARK: Order

    /// Pre-warm slots in the order to decode them: levels 60, 30, `spacing` (coarse to fine);
    /// each level's slots are `k × level` in `[0, duration − 2]`, snapped to the keyframe index,
    /// minus slots within `level / 2` of a covered stamp or within 1 s of a tried one or of a slot
    /// an earlier level already holds; within a level, sorted by distance from `position` with
    /// behind counting double (ties: earlier first).
    static func prewarmOrder(position: Double, duration: Double, spacing: Double,
                             index: [Double], covered: [Double], tried: [Double]) -> [Double] {
        guard duration > 2, spacing > 0, spacing.isFinite else { return [] }
        let sparse = isSparse(index: index, spacing: spacing)
        let covered = covered.sorted(), tried = tried.sorted()
        let levels = ([60.0, 30.0].filter { $0 > spacing } + [spacing])
        var chosen: [Double] = []          // sorted, for the cross-level dedupe
        var out: [Double] = []
        for level in levels {
            var slots: [Double] = []
            var k = 0.0
            while k * level <= duration - 2 {
                let slot = snap(k * level, index: index, sparse: sparse)
                k += 1
                if nearest(slot, in: covered) <= level / 2 { continue }
                if nearest(slot, in: tried) <= 1 { continue }
                if nearest(slot, in: chosen) <= 1 { continue }
                if let last = slots.last, abs(last - slot) <= 1 { continue }
                slots.append(slot)
                chosen.insert(slot, at: insertionIndex(slot, in: chosen))
            }
            func weight(_ s: Double) -> Double { s >= position ? s - position : 2 * (position - s) }
            slots.sort { (weight($0), $0) < (weight($1), $1) }
            out += slots
        }
        return out
    }

    /// The greatest index entry ≤ `sec`; `sec` itself when the index is empty or sparse (its
    /// median gap exceeds 3 × the target spacing, so snapping would land far from the slot).
    static func snap(_ sec: Double, index: [Double], sparse: Bool) -> Double {
        guard !sparse, !index.isEmpty else { return sec }
        let i = insertionIndex(sec + 1e-9, in: index)
        return i == 0 ? index[0] : index[i - 1]
    }

    static func isSparse(index: [Double], spacing: Double) -> Bool {
        guard let gap = medianGap(index) else { return true }
        return gap > 3 * spacing
    }

    // MARK: - Private

    private mutating func nextScrub(_ i: Inputs) -> Job? {
        guard let pending = pendingScrub, i.now >= pending.dueAt else { return nil }
        if i.bytesRead >= i.scrubCeiling {
            stop(.byteBudget)
            return nil
        }
        let spacing = Self.targetSpacing(duration: i.durationSec)
        let target = i.durationSec > 0 ? min(pending.target, i.durationSec) : pending.target
        let snapped = Self.snap(target, index: keyframeIndex,
                                sparse: Self.isSparse(index: keyframeIndex, spacing: spacing))
        let isDuplicate = Self.nearest(snapped, in: tried) <= config.duplicateWindowSec
            || Self.nearest(snapped, in: i.store.stamps) <= config.duplicateWindowSec
        if isDuplicate {
            pendingScrub = nil          // dropped silently
            return nil
        }
        endPass()                       // a scrub breaks the pre-warm pass
        return .scrub(snapped)
    }

    private mutating func nextPrewarm(_ i: Inputs) -> Job? {
        guard prewarmStopped == nil else { return nil }
        if i.bytesRead >= i.byteBudget { stopPrewarm(.byteBudget); return nil }
        if decoded >= config.frameCap { stopPrewarm(.frameCap); return nil }
        if !i.store.acceptsDecode { stopPrewarm(.storeFull); return nil }
        let quiet = !i.previewActive && !i.recentInput && !i.overlayUp && pendingScrub == nil
            && i.now >= lastScrubEnd + config.quietAfterScrubSec
            && i.now >= lastSeekLanded + config.quietAfterSeekSec
        guard quiet, cacheHealthy(i) else { endPass(); return nil }
        if !passActive {
            guard i.now >= passStartedAt + config.tickSec else { return nil }
            passActive = true
            passStartedAt = i.now
            passIssued = 0
            passOrder = Self.prewarmOrder(position: i.positionSec, duration: i.durationSec,
                                          spacing: Self.targetSpacing(duration: i.durationSec),
                                          index: keyframeIndex, covered: i.store.stamps, tried: tried)
        }
        guard passIssued < config.framesPerTick else { endPass(); return nil }
        // Merge, never assign: skip anything the store or the tried set gained since the pass began.
        while let slot = passOrder.first {
            passOrder.removeFirst()
            if Self.nearest(slot, in: tried) <= config.duplicateWindowSec { continue }
            if Self.nearest(slot, in: i.store.stamps) <= config.duplicateWindowSec { continue }
            passIssued += 1
            return .prewarm(slot)
        }
        endPass()
        return nil
    }

    /// C2: the end of the file is cached, or 15 s are, or the forward cache holds 60 % of
    /// `demuxer-max-bytes` (a 4K remux tops out near 12–21 s at 150 MiB); and the cache did not
    /// fall more than 2 s over the last 10 s.
    func cacheHealthy(_ i: Inputs) -> Bool {
        if i.cacheReachesEnd { return true }
        let enough = i.cacheSec >= config.healthyCacheSec || i.cacheFill >= config.healthyCacheFill
        return enough && i.cacheTrendSec >= -config.cacheFallLimitSec
    }

    private mutating func advanceClock(_ i: Inputs) {
        let dt = lastClock.map { min(max(i.now - $0, 0), 1.0) } ?? 0
        lastClock = i.now
        if !i.paused && !i.cacheWait && cacheHealthy(i) { healthyPlaySec += dt }
    }

    private mutating func endPass() {
        if passActive && passIssued > 0 { passEndedUnreported = true }
        passActive = false
        passOrder = []
    }

    private mutating func stopPrewarm(_ reason: ThumbStopReason) {
        if prewarmStopped == nil { prewarmStopped = reason }
        endPass()
    }

    private mutating func markTried(_ sec: Double) {
        guard sec.isFinite, Self.nearest(sec, in: tried) > 1e-6 else { return }
        tried.insert(sec, at: Self.insertionIndex(sec, in: tried))
    }

    /// First index whose value is ≥ `x` in a sorted array.
    static func insertionIndex(_ x: Double, in a: [Double]) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Distance from `x` to the nearest value of a sorted array (infinity when empty).
    static func nearest(_ x: Double, in a: [Double]) -> Double {
        guard !a.isEmpty else { return .infinity }
        let i = insertionIndex(x, in: a)
        var d = Double.infinity
        if i < a.count { d = a[i] - x }
        if i > 0 { d = min(d, x - a[i - 1]) }
        return d
    }
}

/// `cacheTrendSec`: the change of `demuxer-cache-duration` over the last `windowSec`, from the
/// controller's 2 s cache reads. Main-thread owned, pure.
nonisolated struct ThumbCacheTrend {
    let windowSec: Double
    private var samples: [(t: TimeInterval, sec: Double)] = []

    init(windowSec: Double = 10) { self.windowSec = windowSec }

    mutating func record(now: TimeInterval, cacheSec: Double) {
        guard cacheSec.isFinite else { return }
        samples.append((now, cacheSec))
        // Keep one sample at or before the window start so the trend spans the whole window.
        while samples.count > 2, samples[1].t <= now - windowSec { samples.removeFirst() }
    }

    /// Latest minus the sample at (or just before) `now − windowSec`; 0 with fewer than two.
    func trendSec(now: TimeInterval) -> Double {
        guard samples.count >= 2, let last = samples.last else { return 0 }
        let base = samples.last(where: { $0.t <= now - windowSec }) ?? samples[0]
        return last.sec - base.sec
    }

    mutating func reset() { samples.removeAll() }
}
