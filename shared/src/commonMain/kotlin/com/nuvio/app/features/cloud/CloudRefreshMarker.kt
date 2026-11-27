package com.nuvio.app.features.cloud

/**
 * Fork (scope identity W3b review r2 #1/#2): the one owner of the Cloud "refreshing" marker. Pure
 * state, not thread-safe by itself: CloudLibraryRepository calls it under its own leaf lock.
 *
 * - [start] makes a new owner current. A newer start SUPERSEDES the previous owner: the superseded
 *   refresh is not cancelled (its request finishes) but it loses the right to publish and to clear.
 * - [publish] is true only for the current owner, and then ends the marker; the listing is written
 *   only on true, so an older refresh can neither hide a newer one's loading state nor overwrite
 *   its listing.
 * - [abandon] ends the marker only if [owner] is still current (a cancelled job, a refused final
 *   commit, a job that never started). It is idempotent and a no-op after [publish].
 * - [reset] (clear, disabled) ends any marker; every outstanding owner is superseded.
 */
internal class CloudRefreshMarker {
    data class Owner(val id: Long)

    private var lastIssued = 0L
    private var current: Long? = null

    val isRefreshing: Boolean get() = current != null

    fun start(): Owner {
        val owner = Owner(++lastIssued)
        current = owner.id
        return owner
    }

    fun publish(owner: Owner): Boolean = end(owner)

    fun abandon(owner: Owner): Boolean = end(owner)

    fun reset() {
        current = null
    }

    private fun end(owner: Owner): Boolean {
        if (current != owner.id) return false
        current = null
        return true
    }
}
