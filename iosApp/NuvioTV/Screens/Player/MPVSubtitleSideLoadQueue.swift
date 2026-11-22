import Foundation

/// The mpv queue stall (Batch E device pass 2026-10-18): the mpv engine's subtitle side-loads,
/// one at a time and OFF the player's `eventQueue`.
///
/// `sub-add <url>` downloads and parses the file before it returns. It used to run as a
/// synchronous `mpv_command` on `eventQueue`, once per add-on subtitle: Dune came back with 112
/// (OpenSubtitles v3 + an AIOStreams add-on), each about 1.2 s, so the serial queue was busy for
/// 130–150 s after FILE_LOADED. Every block queued behind them waited: the display criteria (HDR
/// arrived late or never), `[MPVStats]`, the seek-preview harvest, the unpause after the display
/// mode hold, the startup aspect, seeks. The controller now issues each `sub-add` through
/// `mpv_command_async` and starts the next one on its `MPV_EVENT_COMMAND_REPLY`.
///
/// Pure bookkeeping (no mpv calls), `eventQueue` only. One load in flight at a time, the same
/// network load as the synchronous chain it replaces, and it keeps the log ring's subtitle
/// attribution window (`MPVLogRing.subtitleLoadBegan` / `subtitleLoadDrained`) one load wide.
nonisolated struct MPVSubtitleSideLoadQueue {
    struct Job: Equatable {
        let source: String
        let title: String
        let lang: String
        /// Position of the first preferred subtitle language this file matches (0 = the top
        /// language), nil = none. Preferred jobs load ahead of the rest, by rank: a stream's own
        /// external subtitles (rank 0) and add-on subtitles in a preferred language, which is what
        /// the auto selection looks for, and it waits for them (`MPVSubtitleAutoSelectGate`).
        let rank: Int?
        /// spec-mpv-return §3.3: the add-on's own URL when `source` is not it (the credential path
        /// hands mpv a downloaded local file). A pending return pick matches on `original`.
        var originalSource: String? = nil
        var preferred: Bool { rank != nil }
        var original: String { originalSource ?? source }
    }

    /// `reply_userdata` for this queue's async commands: a tag in the high bits keeps them apart
    /// from any other async request on the handle.
    static let replyTag: UInt64 = 0x5355_4200_0000_0000   // "SUB"
    static func isReply(_ userdata: UInt64) -> Bool { userdata & 0xFFFF_FF00_0000_0000 == replyTag }

    /// A track walk after every this many finished loads while non-preferred jobs run, so the
    /// subtitle picker fills as they land without a 100-track walk per load.
    static let walkEvery = 10

    private(set) var pending: [Job] = []
    private(set) var inFlight: (id: UInt64, job: Job, startedAt: TimeInterval)?
    private(set) var finished = 0
    private var serial: UInt64 = 0

    /// Something is loading or waiting to load.
    var isActive: Bool { inFlight != nil || !pending.isEmpty }

    /// A preferred-language file is loading or waiting to load.
    var hasPreferredPending: Bool {
        inFlight?.job.preferred == true || pending.contains(where: \.preferred)
    }

    /// Preferred jobs go by rank, ahead of every non-preferred one; equal ranks (and the
    /// non-preferred jobs) keep their order of arrival.
    mutating func enqueue(_ job: Job) {
        guard let rank = job.rank else { pending.append(job); return }
        let at = pending.firstIndex { other in other.rank.map { $0 > rank } ?? true } ?? pending.endIndex
        pending.insert(job, at: at)
    }

    /// The next job to issue, with its reply id; nil while one is in flight or nothing waits.
    mutating func start(now: TimeInterval) -> (id: UInt64, job: Job)? {
        guard inFlight == nil, !pending.isEmpty else { return nil }
        serial += 1
        let id = Self.replyTag | serial
        let job = pending.removeFirst()
        inFlight = (id, job, now)
        return (id, job)
    }

    /// The issue failed (mpv refused the command): nothing is in flight any more.
    mutating func abandonInFlight() {
        inFlight = nil
    }

    struct Finish: Equatable {
        let job: Job
        let tookSec: TimeInterval
        /// Walk the track list now: a preferred subtitle landed (the auto-selection may be waiting
        /// for it), every `walkEvery` loads, and when the queue empties.
        let walkTracks: Bool
    }

    /// `MPV_EVENT_COMMAND_REPLY` for `replyId`. Nil when it is not the load in flight (a stale or
    /// foreign reply).
    mutating func finish(replyId: UInt64, now: TimeInterval) -> Finish? {
        guard let current = inFlight, current.id == replyId else { return nil }
        inFlight = nil
        finished += 1
        let walk = current.job.preferred || finished % Self.walkEvery == 0 || pending.isEmpty
        return Finish(job: current.job, tookSec: now - current.startedAt, walkTracks: walk)
    }
}

/// The mpv queue stall: the subtitle half of the mpv auto track selection, now that side-loads
/// land in the background instead of before the first track walk.
///
/// The old synchronous `sub-add` chain made the first walk run after every prefetched add-on
/// subtitle had loaded, so the shared matcher saw the whole set at once. The walk now runs
/// straight after FILE_LOADED, so a match on a partial set is taken only when more files cannot
/// change it: a match in the TOP preferred language (the matcher returns that language's first
/// full candidate in track order, and later loads only append; the caller works out `matchIsFinal`,
/// minus the pt/es tie-breaks and a forced candidate a full one could replace). Any other match
/// waits until the preferred-language files have loaded (review r1 P2: an embedded subtitle in the
/// second language must not win before the first language's add-on file arrives). Without a match
/// the decision stays open while anything still loads. Audio is unchanged: decided once, on the
/// first walk.
nonisolated enum MPVSubtitleAutoSelectGate {
    enum Decision: Equatable {
        /// Select this track and stop.
        case select(Int64)
        /// Turn subtitles off and keep watching while loads run, else stop: a forced-only plan
        /// with no forced track yet, or (always final) a plan with no target language at all.
        case off(final: Bool)
        /// Not decidable yet: decide again on the next walk.
        case wait
        /// No match and nothing left to load (or no plan): leave mpv's selection alone and stop.
        case done
    }

    /// `matchId` is the track the shared matcher picked among the tracks loaded so far (nil = none).
    ///
    /// `noTargets` (BUG-171): the plan has no target language ("No subtitles" with no secondary
    /// language). mpv runs with `subs-fallback=yes`, so at load it turns on some embedded
    /// subtitle by itself; this must turn it off, at once and for good, since no file arriving
    /// later can match an empty target list. Upstream's runtime and the native engine both treat
    /// an empty plan as "subtitles off".
    static func decide(matchId: Int64?, matchIsFinal: Bool, forcedOnly: Bool,
                       preferredLoadsPending: Bool, sideLoadActive: Bool,
                       noTargets: Bool = false) -> Decision {
        if noTargets { return .off(final: true) }
        if let matchId { return matchIsFinal || !preferredLoadsPending ? .select(matchId) : .wait }
        if forcedOnly { return .off(final: !sideLoadActive) }
        return sideLoadActive ? .wait : .done
    }
}
