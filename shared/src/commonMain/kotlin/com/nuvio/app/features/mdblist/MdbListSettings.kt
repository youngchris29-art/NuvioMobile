package com.nuvio.app.features.mdblist

data class MdbListSettings(
    val enabled: Boolean = false,
    val apiKey: String = "",
    val useImdb: Boolean = true,
    val useTmdb: Boolean = true,
    val useTomatoes: Boolean = true,
    val useMetacritic: Boolean = true,
    val useTrakt: Boolean = true,
    val useLetterboxd: Boolean = true,
    val useAudience: Boolean = true,
    val useMal: Boolean = true,
    /**
     * Upstream 3f0d07be: the connected MDBList account's scope when this profile has one. Runtime
     * only — never persisted, exported to the settings blob, or synced as a provider credential
     * (the account token itself stays in the Keychain, read through [MdbListTracker]).
     */
    val accountScope: MdbListAuthScope? = null,
) {
    val hasApiKey: Boolean
        get() = apiKey.isNotBlank()

    /** Fork alias of [hasApiKey] for Swift: a personal key is set (it overrides the account). */
    val hasPersonalKey: Boolean
        get() = hasApiKey

    /** Fork (Swift-facing): this profile has a connected MDBList account. */
    val isAccountConnected: Boolean
        get() = accountScope != null

    /** Fork (Swift-facing): ratings go through the connected account (connected, no override). */
    val usingAccount: Boolean
        get() = accountScope != null && !hasApiKey

    val hasCredentials: Boolean
        get() = hasApiKey || accountScope != null

    val isActive: Boolean
        get() = enabled && hasCredentials

    internal val credential: MdbListRatingsCredential?
        get() = apiKey.trim().takeIf { it.isNotEmpty() }?.let { MdbListRatingsCredential.ApiKey(it) }
            ?: accountScope?.let { MdbListRatingsCredential.Account(it) }

    internal fun withAccount(state: MdbListAuthState, profileId: Int): MdbListSettings = copy(
        accountScope = state.scope.takeIf { state.isAuthenticated && it.profileId == profileId }
    )

    fun isProviderEnabled(providerId: String): Boolean =
        when (providerId) {
            MdbListMetadataService.PROVIDER_IMDB -> useImdb
            MdbListMetadataService.PROVIDER_TMDB -> useTmdb
            MdbListMetadataService.PROVIDER_TOMATOES -> useTomatoes
            MdbListMetadataService.PROVIDER_METACRITIC -> useMetacritic
            MdbListMetadataService.PROVIDER_TRAKT -> useTrakt
            MdbListMetadataService.PROVIDER_LETTERBOXD -> useLetterboxd
            MdbListMetadataService.PROVIDER_AUDIENCE -> useAudience
            MdbListMetadataService.PROVIDER_MAL -> useMal
            else -> false
        }

    fun enabledProvidersInPriorityOrder(): List<String> =
        MdbListMetadataService.PROVIDER_PRIORITY_ORDER.filter(::isProviderEnabled)

    /**
     * Fork: [accountScope] is left out. `ProfileSettingsSync` fingerprints local settings edits
     * with this string, and a connect/disconnect or profile switch is not a settings edit (the
     * scope never reaches the synced blob), so it must not schedule a settings push.
     */
    override fun toString(): String =
        "MdbListSettings(enabled=$enabled, apiKey=$apiKey, useImdb=$useImdb, useTmdb=$useTmdb, " +
            "useTomatoes=$useTomatoes, useMetacritic=$useMetacritic, useTrakt=$useTrakt, " +
            "useLetterboxd=$useLetterboxd, useAudience=$useAudience, useMal=$useMal)"
}
