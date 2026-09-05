package com.nuvio.app.core.sync

import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Observable state of the FULL profile pull [SyncManager] runs right after a profile is selected
 * (`pullAllForProfile` → `startFullProfilePull`) — the "launch sync burst" that lands seconds after
 * cold-launch Home paints. K1's hero-commit gate needs to know whether that burst is still in
 * flight before it will freeze the hero's payload, or the burst's mid-flight `applyFromRemote` /
 * `syncCollections` calls can reorder or reshape Home under a hero that already committed.
 *
 * Deliberately narrow: this tracks ONLY the full profile-select pull, never a foreground
 * (`requestForegroundPull`) or periodic (`startPeriodicNuvioSyncPull`) pull — those can legitimately
 * run minutes after launch, long after the hero has settled, and must not resurrect [Running].
 *
 * [LaunchSyncState.Idle] is the pre-launch default (nothing has happened yet — distinct from
 * [LaunchSyncState.NotApplicable], which is a definite "this profile does not get a launch sync",
 * e.g. signed out or anonymous).
 */
object LaunchSyncSignal {
    enum class LaunchSyncState { Idle, NotApplicable, Running, Settled }

    private val _state = MutableStateFlow(LaunchSyncState.Idle)
    val state: StateFlow<LaunchSyncState> = _state.asStateFlow()

    // The profile a Running/Settled transition applies to — guards against a STALE cancelled
    // pull's finally-block settle overwriting a NEWER profile's Running state (ProfileSyncRequestGate
    // can cancel-and-replace a full pull for a different profile; the cancelled job's finally still
    // runs, and would otherwise report Settled for a profile nothing is waiting on any more).
    //
    // Guarded by [lock]: the tracked profile and the published state are ONE decision, and the
    // writers sit on different threads (the gate's request site on main, a cancelled pull's
    // finally on the sync dispatcher). Reading `trackedProfileId` and writing `_state` without
    // holding a lock between them is the same staleness hole the field exists to close.
    private val lock = SynchronizedObject()
    private var trackedProfileId: Int? = null

    /** This profile will not get a launch sync at all (signed out, anonymous, wrong profile, or a
     * recent full pull already covered it) — the hero gate should not wait on this signal.
     *
     * Unconditional on purpose: this is called from the REQUEST site, before any tracking is
     * claimed, and its verdict ("the profile now in front gets no launch burst") supersedes
     * whatever an older profile's pull left behind. Work running INSIDE a pull block must use
     * [markNotApplicableFor] instead. */
    fun markNotApplicable() = synchronized(lock) {
        trackedProfileId = null
        _state.value = LaunchSyncState.NotApplicable
    }

    /**
     * [markNotApplicable] reported from work that belongs to [profileId]: a launch pull's own
     * block discovering, after it was dispatched, that it has nothing to do (auth dropped, or the
     * active profile moved on).
     *
     * Ignored when the signal has since moved to another profile: a superseded block still runs up
     * to its first suspension point after the gate cancels it, and must never release the gate the
     * REPLACEMENT profile is waiting on.
     */
    fun markNotApplicableFor(profileId: Int) = synchronized(lock) {
        if (trackedProfileId != profileId) return@synchronized
        trackedProfileId = null
        _state.value = LaunchSyncState.NotApplicable
    }

    /** The ordered full profile sync is about to start for [profileId]. */
    fun markRunning(profileId: Int) = synchronized(lock) {
        trackedProfileId = profileId
        _state.value = LaunchSyncState.Running
    }

    /** The ordered full profile sync for [profileId] has finished — regardless of whether any of
     * its steps failed. A stale settle for a profile this signal is no longer tracking is ignored. */
    fun markSettled(profileId: Int) = synchronized(lock) {
        if (trackedProfileId != profileId) return@synchronized
        _state.value = LaunchSyncState.Settled
    }

    /** Account-scope teardown (sign-out, account switch): nothing is tracked any more. */
    fun reset() = synchronized(lock) {
        trackedProfileId = null
        _state.value = LaunchSyncState.Idle
    }
}
