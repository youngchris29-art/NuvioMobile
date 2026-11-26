package com.nuvio.app.features.mdblist

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

/**
 * Upstream 3f0d07be: ratings go through the connected MDBList account; the personal API key is an
 * override, and the enable toggle no longer needs a key. [uiState] / [snapshot] carry the active
 * profile's connected [MdbListSettings.accountScope].
 *
 * Fork deviation: upstream derives [uiState] with `combine(...).stateIn(scope, Eagerly, ...)`,
 * which publishes asynchronously — a setter followed by `uiState.value` would read the old
 * settings. `ProfileSettingsSync.currentObservedStateSignature()` reads `uiState.value`, so the
 * fork keeps publishing synchronously from every setter and additionally re-publishes on MDBList
 * auth-state changes (connect, disconnect, profile switch) via [observeAccount].
 */
object MdbListSettingsRepository {
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("MdbListSettingsRepository"),
    )
    private val _uiState = MutableStateFlow(MdbListSettings())
    val uiState: StateFlow<MdbListSettings> = _uiState.asStateFlow()

    /**
     * Scope identity W2 fix round: the profile fan-out now loads this repository on
     * Dispatchers.Default (inside the identity barrier's apply), while the Settings setters run on
     * the main thread and the account observer on Default. One lock owns every read and write of
     * [local] and [hasLoaded] and every publication, so the published value always follows the
     * state's own order and no thread reads a half-loaded profile. Storage writes happen inside it
     * too (short, leaf: nothing here takes another lock while holding it).
     */
    private val lock = SynchronizedObject()
    private var hasLoaded = false
    private var observingAccount = false
    private var local = MdbListSettings()

    fun ensureLoaded() {
        MdbListTracker.ensureLoaded()
        observeAccount()
        synchronized(lock) { if (!hasLoaded) loadFromDiskLocked() }
    }

    fun onProfileChanged() {
        observeAccount()
        synchronized(lock) { loadFromDiskLocked() }
    }

    fun snapshot(): MdbListSettings {
        ensureLoaded()
        return synchronized(lock) { local.withActiveAccount() }
    }

    /** Upstream 3f0d07be: no key needed — the connected account can supply ratings. */
    fun setEnabled(value: Boolean) {
        ensureLoaded()
        synchronized(lock) {
            if (local.enabled == value) return
            local = local.copy(enabled = value)
            publishLocked()
            MdbListSettingsStorage.saveEnabled(value)
        }
    }

    fun setApiKey(value: String) {
        ensureLoaded()
        val normalized = value.trim()
        synchronized(lock) {
            if (local.apiKey == normalized) return
            // Upstream 3f0d07be: clearing the override falls back to the account; it no longer
            // turns ratings off.
            local = local.copy(apiKey = normalized)
            publishLocked()
            MdbListSettingsStorage.saveApiKey(normalized)
        }
        MdbListMetadataService.clearCache()
    }

    fun setProviderEnabled(providerId: String, value: Boolean) {
        ensureLoaded()
        synchronized(lock) {
            val l = local
            local = when (providerId) {
                MdbListMetadataService.PROVIDER_IMDB -> if (l.useImdb != value) l.copy(useImdb = value).also { MdbListSettingsStorage.saveUseImdb(value) } else return
                MdbListMetadataService.PROVIDER_TMDB -> if (l.useTmdb != value) l.copy(useTmdb = value).also { MdbListSettingsStorage.saveUseTmdb(value) } else return
                MdbListMetadataService.PROVIDER_TOMATOES -> if (l.useTomatoes != value) l.copy(useTomatoes = value).also { MdbListSettingsStorage.saveUseTomatoes(value) } else return
                MdbListMetadataService.PROVIDER_METACRITIC -> if (l.useMetacritic != value) l.copy(useMetacritic = value).also { MdbListSettingsStorage.saveUseMetacritic(value) } else return
                MdbListMetadataService.PROVIDER_TRAKT -> if (l.useTrakt != value) l.copy(useTrakt = value).also { MdbListSettingsStorage.saveUseTrakt(value) } else return
                MdbListMetadataService.PROVIDER_LETTERBOXD -> if (l.useLetterboxd != value) l.copy(useLetterboxd = value).also { MdbListSettingsStorage.saveUseLetterboxd(value) } else return
                MdbListMetadataService.PROVIDER_AUDIENCE -> if (l.useAudience != value) l.copy(useAudience = value).also { MdbListSettingsStorage.saveUseAudience(value) } else return
                MdbListMetadataService.PROVIDER_MAL -> if (l.useMal != value) l.copy(useMal = value).also { MdbListSettingsStorage.saveUseMal(value) } else return
                else -> return
            }
            // Upstream 647e4c09: no cache clear — the ratings cache holds every provider and filters
            // per request, so a provider toggle needs no refetch.
            publishLocked()
        }
    }

    private fun loadFromDiskLocked() {
        hasLoaded = true
        local = MdbListSettings(
            apiKey = MdbListSettingsStorage.loadApiKey().orEmpty().trim(),
            enabled = MdbListSettingsStorage.loadEnabled() ?: false,
            useImdb = MdbListSettingsStorage.loadUseImdb() ?: true,
            useTmdb = MdbListSettingsStorage.loadUseTmdb() ?: true,
            useTomatoes = MdbListSettingsStorage.loadUseTomatoes() ?: true,
            useMetacritic = MdbListSettingsStorage.loadUseMetacritic() ?: true,
            useTrakt = MdbListSettingsStorage.loadUseTrakt() ?: true,
            useLetterboxd = MdbListSettingsStorage.loadUseLetterboxd() ?: true,
            useAudience = MdbListSettingsStorage.loadUseAudience() ?: true,
            useMal = MdbListSettingsStorage.loadUseMal() ?: true,
        )
        publishLocked()
    }

    private fun publishLocked() {
        _uiState.value = local.withActiveAccount()
    }

    /**
     * Fork: re-publish when the MDBList account connects, disconnects or switches profile. Started
     * from [ensureLoaded] / [onProfileChanged] (not the object initialiser) so merely referencing this object never
     * initialises [MdbListTracker]. W2 fix round: on Default, under [lock] like every other
     * publication (it no longer relies on the main thread for ordering).
     */
    private fun observeAccount() {
        synchronized(lock) {
            if (observingAccount) return
            observingAccount = true
        }
        scope.launch {
            // No drop(1): a state change between ensureLoaded() and subscription must not be lost,
            // and an unchanged re-publish is a no-op (StateFlow equality).
            MdbListTracker.auth.state.collect {
                synchronized(lock) { if (hasLoaded) publishLocked() }
            }
        }
    }

    /** Tests only: forget the loaded state (the observer keeps running). */
    internal fun resetForTest() {
        synchronized(lock) {
            hasLoaded = false
            local = MdbListSettings()
        }
    }

    private fun MdbListSettings.withActiveAccount(): MdbListSettings =
        withAccount(MdbListTracker.auth.state.value, ProfileRepository.activeProfileId)
}
