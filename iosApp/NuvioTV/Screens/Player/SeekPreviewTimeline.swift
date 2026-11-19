import Foundation

/// Everything the mpv seek preview holds that belongs to one preview timeline, in one value
/// (review r3 P2 #2). A live reconnect can restart the stream's timeline: a timestamp from before
/// it names a different picture after it. `liveReconnected()` is the one transition for that, and
/// `decodeBelongs` the one test a returned decode passes before it may touch the store or the
/// scheduler. The controller owns the side effects around it (the store, the thumbnailer object,
/// the coordinator) in `MPVTVPlayerViewController.beginPreviewTimeline`. Pure; main-thread owned.
///
/// The byte accounting is the playback's, not the timeline's: a reconnect never refunds the
/// download budget.
nonisolated struct SeekPreviewTimeline {
    /// The source generation the transport's coordinator fences on; moves with every reconnect.
    private(set) var generation = 0
    /// What the store can fill for this playback, as the coordinator sees it (`setSource`).
    private(set) var capability: SeekPreviewCapability
    var thumbs: ThumbScheduler
    var harvest: HarvestScheduler
    /// What the thumbnailer's open learned (keyframe index, duration); nil until an open reports.
    /// An idle reopen reuses it.
    private(set) var facts: ThumbFileFacts?
    /// Bytes charged by thumbnailers already closed (idle closes and the reconnect).
    private(set) var bytesClosed: Int64 = 0
    private(set) var byteBudget: Int64 = ThumbScheduler.byteBudget(fileSize: nil)
    /// The first open fixed the budget; an idle reopen does not change it.
    private(set) var budgetFixed = false

    init(capability: SeekPreviewCapability, thumbs: ThumbScheduler, harvest: HarvestScheduler) {
        self.capability = capability
        self.thumbs = thumbs
        self.harvest = harvest
    }

    /// Review r4 #1, owner's call: after a live reconnect Whole Video stops reading unwatched
    /// parts for the rest of the playback; the harvest keeps filling the new store. Called after
    /// the old thumbnailer was closed (`noteThumbnailerClosed` took its bytes). The decode stop is
    /// sticky and file-level (`ThumbStopReason.reconnected`), so no open, scrub, refinement or
    /// pre-warm job starts again. The one operation in flight on the closed thumbnailer may still
    /// finish, but `decodeBelongs` drops its result and its late bytes are not counted: the budget
    /// can be exceeded by at most that single in-flight request. The coordinator sees harvest-only
    /// (`fillsUnwatched == false`) under a new generation.
    mutating func liveReconnected() {
        generation += 1
        thumbs.cancel()                     // the in-flight job never finishes here: free the slot
        thumbs.stop(.reconnected)
        harvest.resetForNewTimeline()
        capability.fillsUnwatched = false
    }

    /// A thumbnailer closed (idle close, stop, reconnect, teardown): its charge stays counted.
    mutating func noteThumbnailerClosed(charged: Int64) {
        bytesClosed += max(charged, 0)
    }

    /// What the budget has charged so far: every closed thumbnailer plus the open one.
    func bytesCharged(openThumbnailer: Int64?) -> Int64 {
        bytesClosed + max(openThumbnailer ?? 0, 0)
    }

    /// A thumbnailer opened with `facts`. The first open fixes the budget (`budget`) and learns
    /// the facts; returns true then: the controller hands the keyframe spacing to the store. An
    /// idle reopen returns false.
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
