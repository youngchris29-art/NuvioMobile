import Foundation

/// Everything the mpv seek preview holds that belongs to one preview timeline, in one value
/// (review r3 P2 #2). A live reconnect can restart the stream's timeline: a timestamp from before
/// it names a different picture after it. `beginNewTimeline()` is the one reset for that, and
/// `decodeBelongs` the one test a returned decode passes before it may touch the store or the
/// scheduler. The controller owns the side effects around it (the store, the thumbnailer object,
/// the coordinator) in `MPVTVPlayerViewController.beginPreviewTimeline`. Pure; main-thread owned.
///
/// The byte accounting is the playback's, not the timeline's: a reconnect never refunds the
/// download budget.
nonisolated struct SeekPreviewTimeline {
    /// The source generation the transport's coordinator fences on; moves with every new timeline.
    private(set) var generation = 0
    var thumbs: ThumbScheduler
    var harvest: HarvestScheduler
    /// What the thumbnailer's open learned about this timeline (keyframe index, duration); nil
    /// until an open reports. An idle reopen on the same timeline reuses it.
    private(set) var facts: ThumbFileFacts?
    /// Bytes charged by thumbnailers already closed (idle closes and reconnects).
    private(set) var bytesClosed: Int64 = 0
    private(set) var byteBudget: Int64 = ThumbScheduler.byteBudget(fileSize: nil)
    /// The first open fixed the budget; no later open (idle reopen, new timeline) changes it.
    private(set) var budgetFixed = false

    init(thumbs: ThumbScheduler, harvest: HarvestScheduler) {
        self.thumbs = thumbs
        self.harvest = harvest
    }

    /// The timeline restarted. Called after the old thumbnailer was closed (`noteThumbnailerClosed`
    /// took its bytes): drops every time-keyed field of both schedulers and the facts the old
    /// open learned, and moves the generation. Keeps the bytes and the budget.
    mutating func beginNewTimeline() {
        generation += 1
        thumbs.resetForNewTimeline()
        harvest.resetForNewTimeline()
        facts = nil
    }

    /// A thumbnailer closed (idle close, stop, reconnect, teardown): its charge stays counted.
    mutating func noteThumbnailerClosed(charged: Int64) {
        bytesClosed += max(charged, 0)
    }

    /// What the budget has charged so far: every closed thumbnailer plus the open one.
    func bytesCharged(openThumbnailer: Int64?) -> Int64 {
        bytesClosed + max(openThumbnailer ?? 0, 0)
    }

    /// A thumbnailer opened with `facts`. The first open of the playback fixes the budget
    /// (`budget`); the first open of a timeline learns its facts. Returns true when the facts are
    /// new to this timeline: the controller then hands the keyframe index to the scheduler and
    /// the spacing to the store.
    mutating func opened(_ newFacts: ThumbFileFacts, budget: Int64) -> Bool {
        if !budgetFixed {
            byteBudget = budget
            budgetFixed = true
        }
        guard facts == nil else { return false }
        facts = newFacts
        thumbs.setKeyframeIndex(newFacts.keyframeIndex)
        return true
    }

    /// A decode job may insert its frame and be counted (tried, decoded) only when it started on
    /// the current timeline and the thumbnailer that ran it is still the open one. A job from
    /// before a reconnect fails the generation; one from a thumbnailer since closed fails the
    /// identity. (A job's object is held by its own task while this runs, so its identifier
    /// cannot be reused by the open one.)
    static func decodeBelongs(jobGeneration: Int, jobThumbnailer: ObjectIdentifier,
                              currentGeneration: Int, currentThumbnailer: ObjectIdentifier?) -> Bool {
        jobGeneration == currentGeneration && jobThumbnailer == currentThumbnailer
    }
}
