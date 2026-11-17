package com.nuvio.app.core.profile

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlin.concurrent.Volatile

/**
 * Compose-free seam giving the shared data layer the active profile id without importing
 * `features.profiles.ProfileRepository` (a top-of-graph god-object that would re-introduce a
 * dependency cycle). Mirrors the established `core.i18n.LocalizedStrings` /
 * `core.build.FeaturePolicyProvider` / `features.addons.AddonProfileProvider` injection pattern.
 *
 * The phone app installs a provider backed by `ProfileRepository` at startup; tvOS leaves the
 * default (single primary profile, id 1).
 */
fun interface ActiveProfileIdProvider {
    fun activeProfileId(): Int
}

object ActiveProfileProvider {
    @Volatile
    var provider: ActiveProfileIdProvider = ActiveProfileIdProvider { 1 }

    /** Current active profile id (profile index), via the installed provider. */
    val activeProfileId: Int get() = provider.activeProfileId()

    private val _transition = MutableStateFlow(ProfileTransition(version = 0L, changing = false))

    /**
     * Stage B review r10 findings: a profile selection is one transition, from the id write to the
     * end of its repository fan-out (the add-ons, the debrid account, …). Between the two, readers
     * can see the new id with the old profile's settings; a source search compares this value
     * instead of trusting a mix. [ProfileTransition.version] moves at both ends.
     */
    val transition: StateFlow<ProfileTransition> = _transition.asStateFlow()

    /** Runs [block] (the id write and the fan-out) as one transition; see [transition]. */
    fun <T> changing(block: () -> T): T {
        _transition.update { ProfileTransition(it.version + 1, changing = true) }
        try {
            return block()
        } finally {
            _transition.update { ProfileTransition(it.version + 1, changing = false) }
        }
    }
}

/** See [ActiveProfileProvider.transition]. */
data class ProfileTransition(val version: Long, val changing: Boolean)
