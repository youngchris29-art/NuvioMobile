package com.nuvio.app.core.sync

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.features.collection.CollectionMobileSettingsRepository
import com.nuvio.app.features.collection.CollectionMobileSettingsStorage
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.debrid.DebridSettingsStorage
import com.nuvio.app.features.details.MetaScreenSettingsStorage
import com.nuvio.app.features.details.MetaScreenSettingsRepository
import com.nuvio.app.features.mdblist.MdbListMetadataService
import com.nuvio.app.features.mdblist.MdbListSettingsStorage
import com.nuvio.app.features.mdblist.MdbListSettingsRepository
import com.nuvio.app.features.notifications.EpisodeReleaseNotificationsRepository
import com.nuvio.app.features.player.PlayerSettingsStorage
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.core.ui.CardDepthStyleRepository
import com.nuvio.app.core.ui.CardDepthStyleStorage
import com.nuvio.app.core.ui.PosterCardStyleRepository
import com.nuvio.app.core.ui.PosterCardStyleStorage
import com.nuvio.app.features.settings.ThemeSettingsStoreProvider
import com.nuvio.app.features.settings.ThemeSettingsRepository
import com.nuvio.app.features.streams.StreamBadgeSettingsRepository
import com.nuvio.app.features.streams.StreamBadgeSettingsStorage
import com.nuvio.app.features.tmdb.TmdbSettingsStorage
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.trakt.TraktCommentsStorage
import com.nuvio.app.features.trakt.TraktCommentsSettings
import com.nuvio.app.features.trakt.TraktSettingsStorage
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.watchprogress.ContinueWatchingPreferencesStorage
import com.nuvio.app.features.watchprogress.ContinueWatchingPreferencesRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlin.concurrent.Volatile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put

private const val PUSH_DEBOUNCE_MS = 1500L

object ProfileSettingsSync {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("ProfileSettingsSync"))
    private val log = Logger.withTag("ProfileSettingsSync")
    private val syncMutex = Mutex()
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Volatile
    private var isApplyingRemoteBlob: Boolean = false

    @Volatile
    private var isServerSyncInFlight: Boolean = false

    @Volatile
    private var skipNextPushSignature: String? = null

    private var observeJob: Job? = null

    fun startObserving() {
        if (observeJob?.isActive == true) return
        ensureRepositoriesLoaded()
        ProviderCredentialSync.startObserving()
        observeLocalChangesAndPush()
    }

    fun clearAccountState() {
        observeJob?.cancel()
        observeJob = null
        skipNextPushSignature = null
        ProviderCredentialSync.clearAccountState()
    }

    suspend fun pull(profileId: Int): Boolean {
        ensureRepositoriesLoaded()
        return syncMutex.withLock {
            if (ProfileRepository.activeProfileId != profileId) {
                log.d { "pull(profileId=$profileId) — skipped because profile is no longer active" }
                return@withLock false
            }
            isServerSyncInFlight = true
            try {
                val localBlob = exportSettingsBlob()
                if (ProfileRepository.activeProfileId != profileId) return@withLock false
                val localSignature = buildSignature(localBlob)

                val remoteJson = fetchRemoteSettingsJson(profileId, SyncPlatformProvider.platform)
                if (ProfileRepository.activeProfileId != profileId) return@withLock false

                if (remoteJson == null) {
                    // BUG-20: no blob under our own namespace yet — one-shot migration seed from
                    // the legacy scope(s) this client used to share with other apps.
                    return@withLock seedFromLegacyPlatformsLocked(profileId)
                }

                isApplyingRemoteBlob = true
                try {
                    val remoteBlob = runCatching {
                        json.decodeFromJsonElement(MobileProfileSettingsBlob.serializer(), remoteJson)
                    }.getOrElse { error ->
                        log.e(error) { "pull(profileId=$profileId) — failed to decode remote settings blob" }
                        return@withLock false
                    }
                    // Compare CREDENTIAL-STRIPPED signatures: the local export is always
                    // sanitized now, so a legacy remote blob still carrying credentials would
                    // never compare equal and every foreground pull would re-apply everything +
                    // fan out onProfileChanged() with nothing changed (Codex round 6). BUT a
                    // legacy blob that matches on everything else must still APPLY once — that
                    // apply is the migration path that imports its credentials (see
                    // preservingLocalProfileCredentials) — so only the credential-free case may
                    // short-circuit.
                    val remoteSignature = buildSignature(withoutBlobCredentials(remoteBlob))
                    if (remoteSignature == localSignature && !blobCarriesCredentials(remoteBlob)) {
                        log.d { "pull(profileId=$profileId) — remote matches local" }
                        return@withLock false
                    }

                    if (ProfileRepository.activeProfileId != profileId) return@withLock false
                    if (!applyRemoteBlob(remoteBlob, remoteJson)) {
                        log.w { "pull(profileId=$profileId) — remote blob has no features object; preserving local" }
                        return@withLock false
                    }
                    skipNextPushSignature = currentObservedStateSignature()
                } finally {
                    isApplyingRemoteBlob = false
                }

                log.i { "pull(profileId=$profileId) — applied remote settings blob" }
                true
            } catch (error: Exception) {
                log.e(error) { "pull(profileId=$profileId) — FAILED" }
                false
            } finally {
                isServerSyncInFlight = false
            }
        }
    }

    private suspend fun fetchRemoteSettingsJson(profileId: Int, platform: String): JsonObject? {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
            put("p_platform", platform)
        }
        val result = SupabaseProvider.client.postgrest.rpc("sync_pull_profile_settings_blob", params)
        return result.decodeList<SettingsBlobResponse>().firstOrNull()?.settingsJson
    }

    /**
     * BUG-20 migration: called (under [syncMutex]) when [SyncPlatformProvider.platform] has no
     * settings blob for this profile yet. Reads each legacy namespace once, applies the first
     * blob found (presence-gated — a foreign-schema blob must not reset settings it doesn't
     * carry), and immediately writes the seeded state to our OWN namespace so later pulls find
     * it there. The legacy scope is never written: other clients keep their blob untouched.
     */
    private suspend fun seedFromLegacyPlatformsLocked(profileId: Int): Boolean {
        for (legacyPlatform in SyncPlatformProvider.legacySettingsPlatforms) {
            val legacyJson = runCatching { fetchRemoteSettingsJson(profileId, legacyPlatform) }
                .getOrElse { error ->
                    log.e(error) { "pull(profileId=$profileId) — legacy '$legacyPlatform' fetch FAILED" }
                    null
                } ?: continue
            if (ProfileRepository.activeProfileId != profileId) return false

            val legacyBlob = runCatching {
                json.decodeFromJsonElement(MobileProfileSettingsBlob.serializer(), legacyJson)
            }.getOrElse { error ->
                log.e(error) { "pull(profileId=$profileId) — failed to decode legacy '$legacyPlatform' blob" }
                continue
            }

            isApplyingRemoteBlob = true
            try {
                if (!applyRemoteBlob(legacyBlob, legacyJson)) {
                    log.w { "pull(profileId=$profileId) — legacy '$legacyPlatform' blob has no features object; skipping" }
                    continue
                }
                skipNextPushSignature = currentObservedStateSignature()
            } finally {
                isApplyingRemoteBlob = false
            }

            // The seeded blob must keep the legacy blob's credentials (see
            // restoringLegacyCredentials): once this push lands, later pulls never consult the
            // legacy namespace again, so a credential-stripped seed would leave the in-memory
            // migration stash as their only copy — one process death away from losing them.
            val export = exportSettingsBlob()
            val seeded = export.copy(
                features = export.features.copy(
                    playerSettings = restoringLegacyCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, export.features.playerSettings, legacyBlob.features.playerSettings),
                    debridSettings = restoringLegacyCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, export.features.debridSettings, legacyBlob.features.debridSettings),
                    tmdbSettings = restoringLegacyCredentials(PROFILE_TMDB_SETTINGS_FEATURE, export.features.tmdbSettings, legacyBlob.features.tmdbSettings),
                    mdbListSettings = restoringLegacyCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, export.features.mdbListSettings, legacyBlob.features.mdbListSettings),
                ),
            )
            runCatching { pushToRemoteLocked(profileId, seeded) }
                .onFailure { error ->
                    // Seed push failed — settings applied locally; the next pull retries the
                    // migration (our namespace is still empty), which is safe to repeat.
                    log.e(error) { "pull(profileId=$profileId) — seed push to '${SyncPlatformProvider.platform}' FAILED" }
                }

            log.i { "pull(profileId=$profileId) — seeded '${SyncPlatformProvider.platform}' settings from legacy '$legacyPlatform'" }
            return true
        }

        log.i { "pull(profileId=$profileId) — no remote settings blob found" }
        return false
    }

    suspend fun pushCurrentProfileToRemote(): Boolean {
        ensureRepositoriesLoaded()
        return syncMutex.withLock {
            runCatching {
                val profileId = ProfileRepository.activeProfileId
                val blob = exportSettingsBlob()
                if (ProfileRepository.activeProfileId != profileId) return@runCatching false
                pushToRemoteLocked(profileId, blob)
                true
            }.onFailure { error ->
                log.e(error) { "pushCurrentProfileToRemote() — FAILED" }
            }.getOrDefault(false)
        }
    }

    @OptIn(FlowPreview::class)
    private fun observeLocalChangesAndPush() {
        val signatureFlows = listOf(
            ThemeSettingsRepository.selectedTheme.map { "theme" },
            ThemeSettingsRepository.amoledEnabled.map { "amoled" },
            ThemeSettingsRepository.liquidGlassNativeTabBarEnabled.map { "liquid_glass_tab_bar" },
            ThemeSettingsRepository.navBarStyle.map { "nav_bar_style" },
            PosterCardStyleRepository.uiState.map { "poster_card_style" },
            CardDepthStyleRepository.uiState.map { "card_depth_style" },
            PlayerSettingsRepository.uiState.map { "player" },
            StreamBadgeSettingsRepository.uiState.map { "stream_badges" },
            DebridSettingsRepository.uiState.map { "debrid" },
            TmdbSettingsRepository.uiState.map { "tmdb" },
            MdbListSettingsRepository.uiState.map { "mdblist" },
            MetaScreenSettingsRepository.uiState.map { "meta" },
            CollectionMobileSettingsRepository.uiState.map { "collection_mobile_settings" },
            ContinueWatchingPreferencesRepository.uiState.map { "continue_watching" },
            TraktSettingsRepository.uiState.map { "trakt_settings" },
            TraktCommentsSettings.enabled.map { "trakt_comments" },
            EpisodeReleaseNotificationsRepository.uiState.map { "episode_release_alerts" },
        )

        observeJob = scope.launch {
            combine(signatureFlows) { currentObservedStateSignature() }
                .drop(1)
                .distinctUntilChanged()
                .debounce(PUSH_DEBOUNCE_MS)
                .collect { signature ->
                    val authState = AuthRepository.state.value
                    if (authState !is AuthState.Authenticated || authState.isAnonymous) return@collect
                    if (isApplyingRemoteBlob || isServerSyncInFlight) return@collect
                    if (signature == skipNextPushSignature) {
                        skipNextPushSignature = null
                        return@collect
                    }
                    pushCurrentProfileToRemote()
                }
        }
    }

    /**
     * One-time cleanup completing the legacy credential migration: rewrites a still
     * credential-bearing remote blob in sanitized form. Without it the carries-credentials
     * bypass in [pull] re-applies the whole blob (and fans out onProfileChanged()) on EVERY
     * foreground sync — `skipNextPushSignature` suppresses exactly the observer push that would
     * otherwise rewrite it (Codex round 9). Called by ProviderCredentialSync ONLY after the
     * staged legacy credentials have been successfully seeded into provider rows — rewriting any
     * earlier would delete the credentials' only remote copy while the seed can still fail
     * (Codex round 10). A failed rewrite is safe: the next pull re-applies + re-stages from the
     * unchanged blob, the (insert-if-absent) re-seed no-ops, and the rewrite is retried.
     */
    internal suspend fun rewriteLegacyBlobSanitized(profileId: Int) {
        syncMutex.withLock {
            if (ProfileRepository.activeProfileId != profileId) return@withLock
            runCatching { pushToRemoteLocked(profileId, exportSettingsBlob()) }
                .onFailure { error ->
                    log.w(error) { "rewriteLegacyBlobSanitized(profileId=$profileId) failed — next pull retries" }
                }
        }
    }

    private suspend fun pushToRemoteLocked(profileId: Int, blob: MobileProfileSettingsBlob) {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
            put("p_platform", SyncPlatformProvider.platform)
            put("p_settings_json", json.encodeToJsonElement(MobileProfileSettingsBlob.serializer(), blob))
            putSyncOriginClientId()
        }
        SupabaseProvider.client.postgrest.rpc("sync_push_profile_settings_blob", params)
        log.d { "pushToRemoteLocked(profileId=$profileId) — success" }
    }

    private fun exportSettingsBlob(): MobileProfileSettingsBlob {
        ensureRepositoriesLoaded()
        return MobileProfileSettingsBlob(
            features = MobileProfileSettingsFeatures(
                themeSettings = ThemeSettingsStoreProvider.store.exportToSyncPayload(),
                posterCardStyleSettingsPayload = PosterCardStyleStorage.loadPayload().orEmpty().trim(),
                cardDepthStyleSettingsPayload = CardDepthStyleStorage.loadPayload().orEmpty().trim(),
                // Provider credentials are stripped here and synced per-provider by
                // ProviderCredentialSync instead — a whole-blob push must never carry them.
                playerSettings = withoutProfileCredentials(
                    PROFILE_PLAYER_SETTINGS_FEATURE,
                    PlayerSettingsStorage.exportToSyncPayload(),
                ),
                streamBadgeSettings = StreamBadgeSettingsStorage.exportToSyncPayload(),
                debridSettings = withoutProfileCredentials(
                    PROFILE_DEBRID_SETTINGS_FEATURE,
                    DebridSettingsStorage.exportToSyncPayload(),
                ),
                tmdbSettings = withoutProfileCredentials(
                    PROFILE_TMDB_SETTINGS_FEATURE,
                    TmdbSettingsStorage.exportToSyncPayload(),
                ),
                mdbListSettings = withoutProfileCredentials(
                    PROFILE_MDBLIST_SETTINGS_FEATURE,
                    MdbListSettingsStorage.exportToSyncPayload(),
                ),
                metaScreenSettingsPayload = MetaScreenSettingsStorage.loadPayload().orEmpty().trim(),
                collectionMobileSettingsPayload = CollectionMobileSettingsStorage.loadPayload().orEmpty().trim(),
                continueWatchingSettingsPayload = ContinueWatchingPreferencesStorage.loadPayload().orEmpty().trim(),
                traktSettingsPayload = TraktSettingsStorage.loadPayload().orEmpty().trim(),
                traktCommentsSettings = TraktCommentsStorage.exportToSyncPayload(),
                notificationsSettings = NotificationsSettingsPayload(
                    episodeReleaseAlertsEnabled = EpisodeReleaseNotificationsRepository.uiState.value.isEnabled,
                ),
            ),
        )
    }

    /**
     * Applies [blob] to local storage, but only the feature blocks actually PRESENT in the raw
     * [remoteJson] (BUG-20): the decoded struct fills absent fields with empty defaults, and
     * blindly applying those wiped every setting the writing client's schema doesn't carry —
     * e.g. upstream's Android TV blob has no card-depth/poster-style payloads, so each of its
     * pushes reset them here. Absence now means "that client doesn't model this" and the local
     * value is preserved.
     *
     * @return false (nothing applied) when [remoteJson] carries no `features` object at all.
     */
    private fun applyRemoteBlob(blob: MobileProfileSettingsBlob, remoteJson: JsonObject): Boolean {
        val rawFeatures = remoteJson["features"] as? JsonObject ?: return false
        fun has(key: String) = rawFeatures.containsKey(key)

        // Legacy-blob credential migration (Codex rounds 4+7): a pre-split blob may still carry
        // credentials. They are STRIPPED from every payload applied below (see
        // preservingLocalProfileCredentials) and staged instead — ProviderCredentialSync applies
        // them only into true voids (no provider row, blank local), so a provider row's
        // clear-tombstone is never resurrected and the staged value never reads as a local edit.
        val legacy = extractLegacyCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, blob.features.playerSettings) +
            extractLegacyCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, blob.features.debridSettings) +
            extractLegacyCredentials(PROFILE_TMDB_SETTINGS_FEATURE, blob.features.tmdbSettings) +
            extractLegacyCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, blob.features.mdbListSettings)
        if (legacy.isNotEmpty()) {
            ProviderCredentialSync.stageLegacyBlobCredentials(ProfileRepository.activeProfileId, legacy)
        }

        if (has("theme_settings")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "theme_settings",
                current = ThemeSettingsStoreProvider.store.exportToSyncPayload(),
                incoming = blob.features.themeSettings,
                apply = { ThemeSettingsStoreProvider.store.replaceFromSyncPayload(blob.features.themeSettings) },
                notifyChanged = { ThemeSettingsRepository.onProfileChanged() },
            )
        }

        if (has("poster_card_style_settings_payload")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "poster_card_style_settings_payload",
                current = PosterCardStyleStorage.loadPayload().orEmpty().trim(),
                incoming = blob.features.posterCardStyleSettingsPayload.trim(),
                apply = { PosterCardStyleStorage.savePayload(blob.features.posterCardStyleSettingsPayload) },
                notifyChanged = { PosterCardStyleRepository.onProfileChanged() },
            )
        }

        if (has("card_depth_style_settings_payload")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "card_depth_style_settings_payload",
                current = CardDepthStyleStorage.loadPayload().orEmpty().trim(),
                incoming = blob.features.cardDepthStyleSettingsPayload.trim(),
                apply = { CardDepthStyleStorage.savePayload(blob.features.cardDepthStyleSettingsPayload) },
                notifyChanged = { CardDepthStyleRepository.onProfileChanged() },
            )
        }

        if (has("player_settings")) {
            // Credentials are owned by ProviderCredentialSync: snapshot the local values BEFORE
            // replaceFromSyncPayload() wipes this feature's keys, then re-assert them over the
            // remote payload. `introdb_api_key` is not part of exportToSyncPayload(), so it is
            // carried separately and written back explicitly.
            val localPlayerSettings = PlayerSettingsStorage.exportToSyncPayload()
            val localIntroDbApiKey = PlayerSettingsStorage.loadIntroDbApiKey()
            PlayerSettingsStorage.replaceFromSyncPayload(
                preservingLocalProfileCredentials(
                    PROFILE_PLAYER_SETTINGS_FEATURE,
                    blob.features.playerSettings,
                    localPlayerSettings,
                ),
            )
            // Blank local = "no credential" (same rule as preservingLocalProfileCredentials):
            // re-saving a blank here would clobber an IntroDB key the replace just imported from
            // a legacy remote blob — the one place that key can come back from on an upgraded
            // fresh install (Codex round 6).
            localIntroDbApiKey?.takeUnless(String::isBlank)?.let(PlayerSettingsStorage::saveIntroDbApiKey)
            PlayerSettingsRepository.onProfileChanged()
        }

        if (has("stream_badge_settings")) {
            StreamBadgeSettingsStorage.replaceFromSyncPayload(blob.features.streamBadgeSettings)
            StreamBadgeSettingsRepository.onProfileChanged()
        }

        if (has("debrid_settings")) {
            DebridSettingsStorage.replaceFromSyncPayload(
                preservingLocalProfileCredentials(
                    PROFILE_DEBRID_SETTINGS_FEATURE,
                    blob.features.debridSettings,
                    DebridSettingsStorage.exportToSyncPayload(),
                ),
            )
            DebridSettingsRepository.onProfileChanged()
        }

        if (has("tmdb_settings")) {
            TmdbSettingsStorage.replaceFromSyncPayload(
                preservingLocalProfileCredentials(
                    PROFILE_TMDB_SETTINGS_FEATURE,
                    blob.features.tmdbSettings,
                    TmdbSettingsStorage.exportToSyncPayload(),
                ),
            )
            TmdbSettingsRepository.onProfileChanged()
        }

        if (has("mdblist_settings")) {
            MdbListSettingsStorage.replaceFromSyncPayload(
                preservingLocalProfileCredentials(
                    PROFILE_MDBLIST_SETTINGS_FEATURE,
                    blob.features.mdbListSettings,
                    MdbListSettingsStorage.exportToSyncPayload(),
                ),
            )
            MdbListMetadataService.clearCache()
            MdbListSettingsRepository.onProfileChanged()
        }

        if (has("meta_screen_settings_payload")) {
            MetaScreenSettingsStorage.savePayload(blob.features.metaScreenSettingsPayload)
            MetaScreenSettingsRepository.onProfileChanged()
        }

        if (has("collection_mobile_settings_payload")) {
            CollectionMobileSettingsStorage.savePayload(blob.features.collectionMobileSettingsPayload)
            CollectionMobileSettingsRepository.onProfileChanged()
        }

        if (has("continue_watching_settings_payload")) {
            ContinueWatchingPreferencesStorage.savePayload(blob.features.continueWatchingSettingsPayload)
            ContinueWatchingPreferencesRepository.onProfileChanged()
        }

        if (has("trakt_settings_payload")) {
            TraktSettingsStorage.savePayload(blob.features.traktSettingsPayload)
            TraktSettingsRepository.onProfileChanged()
        }

        if (has("trakt_comments_settings")) {
            TraktCommentsStorage.replaceFromSyncPayload(blob.features.traktCommentsSettings)
            TraktCommentsSettings.onProfileChanged()
        }

        if (has("notifications_settings")) {
            EpisodeReleaseNotificationsRepository.applyFromSyncEnabled(blob.features.notificationsSettings.episodeReleaseAlertsEnabled)
        }

        return true
    }

    private fun ensureRepositoriesLoaded() {
        ThemeSettingsRepository.ensureLoaded()
        PosterCardStyleRepository.ensureLoaded()
        CardDepthStyleRepository.ensureLoaded()
        PlayerSettingsRepository.ensureLoaded()
        StreamBadgeSettingsRepository.ensureLoaded()
        DebridSettingsRepository.ensureLoaded()
        TmdbSettingsRepository.ensureLoaded()
        MdbListSettingsRepository.ensureLoaded()
        MetaScreenSettingsRepository.ensureLoaded()
        CollectionMobileSettingsRepository.ensureLoaded()
        ContinueWatchingPreferencesRepository.ensureLoaded()
        TraktSettingsRepository.ensureLoaded()
        TraktCommentsSettings.ensureLoaded()
        EpisodeReleaseNotificationsRepository.ensureLoaded()
    }

    private fun buildSignature(blob: MobileProfileSettingsBlob): String =
        json.encodeToString(MobileProfileSettingsBlob.serializer(), blob)

    // The four credential-bearing features, stripped — for signature comparison only (the
    // unstripped blob must still be the one applied, or legacy credentials never migrate).
    private fun withoutBlobCredentials(blob: MobileProfileSettingsBlob): MobileProfileSettingsBlob =
        blob.copy(
            features = blob.features.copy(
                playerSettings = withoutProfileCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, blob.features.playerSettings),
                debridSettings = withoutProfileCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, blob.features.debridSettings),
                tmdbSettings = withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, blob.features.tmdbSettings),
                mdbListSettings = withoutProfileCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, blob.features.mdbListSettings),
            ),
        )

    private fun blobCarriesCredentials(blob: MobileProfileSettingsBlob): Boolean =
        blob.features.playerSettings != withoutProfileCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, blob.features.playerSettings) ||
            blob.features.debridSettings != withoutProfileCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, blob.features.debridSettings) ||
            blob.features.tmdbSettings != withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, blob.features.tmdbSettings) ||
            blob.features.mdbListSettings != withoutProfileCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, blob.features.mdbListSettings)

    private fun currentObservedStateSignature(): String = listOf(
        "theme=${ThemeSettingsRepository.selectedTheme.value.name}",
        "amoled=${ThemeSettingsRepository.amoledEnabled.value}",
        "liquid_glass_tab_bar=${ThemeSettingsRepository.liquidGlassNativeTabBarEnabled.value}",
        "nav_bar_style=${ThemeSettingsRepository.navBarStyle.value.key}",
        "poster_card_style=${PosterCardStyleRepository.uiState.value}",
        "card_depth_style=${CardDepthStyleRepository.uiState.value}",
        "player=${PlayerSettingsRepository.uiState.value}",
        "stream_badges=${StreamBadgeSettingsRepository.uiState.value}",
        "debrid=${DebridSettingsRepository.uiState.value}",
        "tmdb=${TmdbSettingsRepository.uiState.value}",
        "mdblist=${MdbListSettingsRepository.uiState.value}",
        "meta=${MetaScreenSettingsRepository.uiState.value}",
        "collection_mobile_settings=${CollectionMobileSettingsRepository.uiState.value}",
        "continue=${ContinueWatchingPreferencesRepository.uiState.value}",
        "trakt_settings=${TraktSettingsRepository.uiState.value}",
        "trakt_comments=${TraktCommentsSettings.enabled.value}",
        "episode_release_alerts=${EpisodeReleaseNotificationsRepository.uiState.value.isEnabled}",
    ).joinToString(separator = "||")

}

/**
 * H-1B-i no-op suppression: applies [incoming] over [current] and fires [notifyChanged] only when
 * they differ. Every `applyRemoteBlob()` block used to replace-and-fan-out unconditionally on
 * every foreground pull whose feature was PRESENT in the remote blob — including a pull whose
 * payload is byte-identical to what's already stored locally. On tvOS the whole SwiftUI view tree
 * is re-identified by `.id(appTheme.themeName)` on that fan-out (`onProfileChanged()` →
 * `objectWillChange`), so an identical pull minutes after launch caused a full, visible remount
 * (2026-08-22 tester report, doubled hero) — this is defense in depth at the source, alongside the
 * Swift-side guard landed separately.
 *
 * [current] and [incoming] MUST be the exact serialized shape a feature's own
 * `exportToSyncPayload()` produces (a raw [kotlinx.serialization.json.JsonObject] for theme, the
 * raw stored payload string for poster/card-depth) — never fields decoded out of that payload. A
 * writing client on a different schema (e.g. one that doesn't model a given key) still serializes
 * to a payload that differs at this raw level, so it correctly reads as "changed" and applies
 * exactly as before; only a truly byte-identical payload is suppressed.
 */
internal inline fun <T> applyFeatureUnlessUnchanged(
    log: Logger,
    featureName: String,
    current: T,
    incoming: T,
    apply: () -> Unit,
    notifyChanged: () -> Unit,
) {
    if (current == incoming) {
        log.d { "applyRemoteBlob() — '$featureName' payload unchanged; skipping replace + onProfileChanged() (no-op suppression)" }
        return
    }
    apply()
    notifyChanged()
}

@Serializable
private data class MobileProfileSettingsBlob(
    val version: Int = 3,
    val features: MobileProfileSettingsFeatures = MobileProfileSettingsFeatures(),
)

@Serializable
private data class MobileProfileSettingsFeatures(
    @SerialName("theme_settings") val themeSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("poster_card_style_settings_payload") val posterCardStyleSettingsPayload: String = "",
    @SerialName("card_depth_style_settings_payload") val cardDepthStyleSettingsPayload: String = "",
    @SerialName("player_settings") val playerSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("stream_badge_settings") val streamBadgeSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("debrid_settings") val debridSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("tmdb_settings") val tmdbSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("mdblist_settings") val mdbListSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("meta_screen_settings_payload") val metaScreenSettingsPayload: String = "",
    @SerialName("collection_mobile_settings_payload") val collectionMobileSettingsPayload: String = "",
    @SerialName("continue_watching_settings_payload") val continueWatchingSettingsPayload: String = "",
    @SerialName("trakt_settings_payload") val traktSettingsPayload: String = "",
    @SerialName("trakt_comments_settings") val traktCommentsSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("notifications_settings") val notificationsSettings: NotificationsSettingsPayload = NotificationsSettingsPayload(),
)

@Serializable
private data class NotificationsSettingsPayload(
    @SerialName("episode_release_alerts_enabled") val episodeReleaseAlertsEnabled: Boolean = false,
)

@Serializable
private data class SettingsBlobResponse(
    @SerialName("profile_id") val profileId: Int = 0,
    @SerialName("settings_json") val settingsJson: JsonObject? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)
