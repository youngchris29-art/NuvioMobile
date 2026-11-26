package com.nuvio.app.features.addons

/*
 * Fork (scope identity W2, review r1 #2, r3): who may publish the local add-on list, decided in one
 * pure place and executed by AddonRepository.initialize() under its profileLock.
 *
 * A bootstrap is keyed on the identity it runs under: the identity epoch of its token (every
 * barrier transition bumps it, a same-slot profile selection included) and the repository's
 * profile generation (every profile change or account wipe bumps it; on mobile, where no barrier
 * moves the epoch, this is what a profile switch changes). A reservation made under an older key
 * is stale the moment the key moves: it can never publish (its token check fails), so it never
 * blocks the current key from reserving, and its end touches nothing that is not its own.
 *
 * Liveness (tested over the full state × event enumeration): whenever the current key has no
 * completed bootstrap, either a reservation for the current key is in flight, or reserve() for
 * the current key returns Reserve. No state leaves only a reservation that will be rejected.
 */
internal data class BootstrapKey(val identityEpoch: Long, val profileGeneration: Long)

internal sealed interface BootstrapReserve {
    data object Skip : BootstrapReserve
    data class Reserve(val key: BootstrapKey) : BootstrapReserve
}

internal sealed interface BootstrapEnd {
    /** Publish the list, record [BootstrapKey] as completed, set the shared profile id. */
    data object Publish : BootstrapEnd
    /** Give the reservation back; [resetMirror]: no list of this profile generation was ever published. */
    data class Release(val resetMirror: Boolean) : BootstrapEnd
    /** Not this bootstrap's reservation any more: touch nothing. */
    data object Nothing : BootstrapEnd
}

internal object AddonBootstrapRule {
    /** Skip only when the current key already completed or is already in flight. */
    fun reserve(completedFor: BootstrapKey?, holder: BootstrapKey?, current: BootstrapKey): BootstrapReserve =
        if (completedFor == current || holder == current) BootstrapReserve.Skip else BootstrapReserve.Reserve(current)

    fun end(
        reserved: BootstrapKey,
        current: BootstrapKey,
        holder: BootstrapKey?,
        completedFor: BootstrapKey?,
        tokenHolds: Boolean,
    ): BootstrapEnd = when {
        holder != reserved -> BootstrapEnd.Nothing
        reserved == current && tokenHolds -> BootstrapEnd.Publish
        else -> BootstrapEnd.Release(resetMirror = completedFor?.profileGeneration != current.profileGeneration)
    }
}
