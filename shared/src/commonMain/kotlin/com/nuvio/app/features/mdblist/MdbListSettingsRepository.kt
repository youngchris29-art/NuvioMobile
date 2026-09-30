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

    private var hasLoaded = false
    private var observingAccount = false

    private var enabled = false
    private var apiKey = ""
    private var useImdb = true
    private var useTmdb = true
    private var useTomatoes = true
    private var useMetacritic = true
    private var useTrakt = true
    private var useLetterboxd = true
    private var useAudience = true
    private var useMal = true

    fun ensureLoaded() {
        MdbListTracker.ensureLoaded()
        observeAccount()
        if (hasLoaded) return
        loadFromDisk()
    }

    fun onProfileChanged() {
        observeAccount()
        loadFromDisk()
    }

    fun snapshot(): MdbListSettings {
        ensureLoaded()
        return localSettings().withActiveAccount()
    }

    /** Upstream 3f0d07be: no key needed — the connected account can supply ratings. */
    fun setEnabled(value: Boolean) {
        ensureLoaded()
        if (enabled == value) return
        enabled = value
        publish()
        MdbListSettingsStorage.saveEnabled(value)
    }

    fun setApiKey(value: String) {
        ensureLoaded()
        val normalized = value.trim()
        if (apiKey == normalized) return
        apiKey = normalized
        // Upstream 3f0d07be: clearing the override falls back to the account; it no longer
        // turns ratings off.
        publish()
        MdbListSettingsStorage.saveApiKey(normalized)
        MdbListMetadataService.clearCache()
    }

    fun setProviderEnabled(providerId: String, value: Boolean) {
        ensureLoaded()
        when (providerId) {
            MdbListMetadataService.PROVIDER_IMDB -> if (useImdb != value) {
                useImdb = value
                MdbListSettingsStorage.saveUseImdb(value)
            } else return
            MdbListMetadataService.PROVIDER_TMDB -> if (useTmdb != value) {
                useTmdb = value
                MdbListSettingsStorage.saveUseTmdb(value)
            } else return
            MdbListMetadataService.PROVIDER_TOMATOES -> if (useTomatoes != value) {
                useTomatoes = value
                MdbListSettingsStorage.saveUseTomatoes(value)
            } else return
            MdbListMetadataService.PROVIDER_METACRITIC -> if (useMetacritic != value) {
                useMetacritic = value
                MdbListSettingsStorage.saveUseMetacritic(value)
            } else return
            MdbListMetadataService.PROVIDER_TRAKT -> if (useTrakt != value) {
                useTrakt = value
                MdbListSettingsStorage.saveUseTrakt(value)
            } else return
            MdbListMetadataService.PROVIDER_LETTERBOXD -> if (useLetterboxd != value) {
                useLetterboxd = value
                MdbListSettingsStorage.saveUseLetterboxd(value)
            } else return
            MdbListMetadataService.PROVIDER_AUDIENCE -> if (useAudience != value) {
                useAudience = value
                MdbListSettingsStorage.saveUseAudience(value)
            } else return
            MdbListMetadataService.PROVIDER_MAL -> if (useMal != value) {
                useMal = value
                MdbListSettingsStorage.saveUseMal(value)
            } else return
            else -> return
        }
        // Upstream 647e4c09: no cache clear — the ratings cache holds every provider and filters
        // per request, so a provider toggle needs no refetch.
        publish()
    }

    private fun loadFromDisk() {
        hasLoaded = true
        apiKey = MdbListSettingsStorage.loadApiKey().orEmpty().trim()
        enabled = MdbListSettingsStorage.loadEnabled() ?: false
        useImdb = MdbListSettingsStorage.loadUseImdb() ?: true
        useTmdb = MdbListSettingsStorage.loadUseTmdb() ?: true
        useTomatoes = MdbListSettingsStorage.loadUseTomatoes() ?: true
        useMetacritic = MdbListSettingsStorage.loadUseMetacritic() ?: true
        useTrakt = MdbListSettingsStorage.loadUseTrakt() ?: true
        useLetterboxd = MdbListSettingsStorage.loadUseLetterboxd() ?: true
        useAudience = MdbListSettingsStorage.loadUseAudience() ?: true
        useMal = MdbListSettingsStorage.loadUseMal() ?: true
        publish()
    }

    private fun publish() {
        _uiState.value = localSettings().withActiveAccount()
    }

    /**
     * Fork: re-publish when the MDBList account connects, disconnects or switches profile. Started
     * from [ensureLoaded] / [onProfileChanged] (not the object initialiser) so merely referencing this object never
     * initialises [MdbListTracker].
     */
    private fun observeAccount() {
        if (observingAccount) return
        observingAccount = true
        scope.launch {
            // No drop(1): a state change between ensureLoaded() and subscription must not be lost,
            // and an unchanged re-publish is a no-op (StateFlow equality).
            MdbListTracker.auth.state.collect {
                if (hasLoaded) _uiState.value = localSettings().withActiveAccount()
            }
        }
    }

    private fun MdbListSettings.withActiveAccount(): MdbListSettings =
        withAccount(MdbListTracker.auth.state.value, ProfileRepository.activeProfileId)

    private fun localSettings(): MdbListSettings =
        MdbListSettings(
            enabled = enabled,
            apiKey = apiKey,
            useImdb = useImdb,
            useTmdb = useTmdb,
            useTomatoes = useTomatoes,
            useMetacritic = useMetacritic,
            useTrakt = useTrakt,
            useLetterboxd = useLetterboxd,
            useAudience = useAudience,
            useMal = useMal,
        )
}
