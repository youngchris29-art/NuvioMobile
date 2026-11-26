package com.nuvio.app.features.addons

/*
 * Fork (scope identity W2, review r1 #2): who may publish the local add-on list, decided in one
 * pure place and executed by AddonRepository.initialize() under its profileLock.
 *
 * A bootstrap reserves under the current profile generation (AddonRepository.profileEpoch, bumped
 * by every profile change and account wipe, each of which also clears the reservation). It then
 * reads storage without writing anything shared, and at its end it publishes (and only then sets
 * the shared profile id) if it still holds the reservation, the generation has not moved and its
 * identity token still holds; it releases the reservation if it still holds it but may not
 * publish; and it touches nothing if the reservation is no longer its own (a newer bootstrap's
 * state, or a reset, must survive it).
 */
internal sealed interface BootstrapReserve {
    data object Skip : BootstrapReserve
    data class Reserve(val generation: Long) : BootstrapReserve
}

internal enum class BootstrapEnd { Publish, Release, Nothing }

internal object AddonBootstrapRule {
    /** [initialized]: a bootstrap began or completed for the current generation. */
    fun reserve(initialized: Boolean, generation: Long): BootstrapReserve =
        if (initialized) BootstrapReserve.Skip else BootstrapReserve.Reserve(generation)

    /** [holder]: the generation whose bootstrap holds the reservation now (null: none). */
    fun end(reservedGeneration: Long, currentGeneration: Long, holder: Long?, tokenHolds: Boolean): BootstrapEnd = when {
        holder != reservedGeneration -> BootstrapEnd.Nothing
        currentGeneration == reservedGeneration && tokenHolds -> BootstrapEnd.Publish
        else -> BootstrapEnd.Release
    }
}
