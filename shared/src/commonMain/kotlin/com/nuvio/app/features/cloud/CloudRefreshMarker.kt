package com.nuvio.app.features.cloud

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Fork (scope identity W3b review r2 #1/#2, r3 #1): the one owner of the Cloud "refreshing" marker.
 * The mutators are not thread-safe by themselves: CloudLibraryRepository calls them under its own
 * leaf lock. [awaitIdle] only reads a state flow and may be called from anywhere (never under a lock).
 *
 * - [start] makes a new owner current. A newer start SUPERSEDES the previous owner: the superseded
 *   refresh is not cancelled (its request finishes) but it loses the right to publish and to clear.
 * - [publish] is true only for the current owner, and then ends the marker; the listing is written
 *   only on true, so an older refresh can neither hide a newer one's loading state nor overwrite
 *   its listing.
 * - [abandon] ends the marker only if [owner] is still current (a cancelled job, a refused final
 *   commit, a job that never started, a throw). It is idempotent and a no-op after [publish].
 * - [reset] (clear, disabled) ends any marker; every outstanding owner is superseded.
 * - [publishedSince] says whether an owner started after [owner] published (r3 #1: a superseded
 *   lookup trusts that newer listing); [awaitIdle] waits, bounded, until no owner is current.
 */
internal class CloudRefreshMarker {
    data class Owner(val id: Long)

    private var lastIssued = 0L
    private var lastPublished = 0L
    private val current = MutableStateFlow<Long?>(null)

    val isRefreshing: Boolean get() = current.value != null

    fun start(): Owner {
        val owner = Owner(++lastIssued)
        current.value = owner.id
        return owner
    }

    fun publish(owner: Owner): Boolean = end(owner).also { if (it) lastPublished = owner.id }

    fun abandon(owner: Owner): Boolean = end(owner)

    fun reset() {
        current.value = null
    }

    fun publishedSince(owner: Owner): Boolean = lastPublished > owner.id

    /** True once no owner is current (published, abandoned or reset); false after [timeoutMs]. */
    suspend fun awaitIdle(timeoutMs: Long): Boolean =
        withTimeoutOrNull(timeoutMs) { current.first { it == null } } != null || current.value == null

    private fun end(owner: Owner): Boolean {
        if (current.value != owner.id) return false
        current.value = null
        return true
    }
}
