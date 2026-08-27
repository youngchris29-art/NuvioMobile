package com.nuvio.app.features.home

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.sync.CachedSharedSettings
import com.nuvio.app.core.sync.HOME_CATALOG_SHARED_SYNC_PLATFORM
import com.nuvio.app.core.sync.SettingsPullToken
import com.nuvio.app.core.sync.currentSettingsPullToken
import com.nuvio.app.core.sync.mergeSharedSettingsJson
import com.nuvio.app.core.sync.putSyncOriginClientId
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlin.concurrent.Volatile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

@Serializable
data class SyncCatalogItem(
    @SerialName("addon_id") val addonId: String,
    val type: String,
    @SerialName("catalog_id") val catalogId: String,
    val enabled: Boolean = true,
    val order: Int = 0,
    @SerialName("custom_title") val customTitle: String = "",
    @SerialName("is_collection") val isCollection: Boolean = false,
    @SerialName("collection_id") val collectionId: String = "",
    val key: String = "",
)

@Serializable
data class SyncHomeCatalogPayload(
    @SerialName("show_catalog_type") val showCatalogType: Boolean = true,
    @SerialName("hide_unreleased_content") val hideUnreleasedContent: Boolean = false,
    @SerialName("hide_catalog_underline") val hideCatalogUnderline: Boolean = false,
    @SerialName("hide_discover") val hideDiscover: Boolean = false,
    val items: List<SyncCatalogItem> = emptyList(),
)

@Serializable
private data class SupabaseHomeCatalogSettingsBlob(
    @SerialName("profile_id") val profileId: Int = 1,
    @SerialName("settings_json") val settingsJson: JsonObject = buildJsonObject { },
)

private val homeCatalogJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}

private const val HIDE_UNRELEASED_CONTENT_KEY = "hide_unreleased_content"
private const val SHOW_CATALOG_TYPE_KEY = "show_catalog_type"
private const val HIDE_CATALOG_UNDERLINE_KEY = "hide_catalog_underline"
private const val HIDE_DISCOVER_KEY = "hide_discover"

/**
 * Presence-gated decode: only the toggles the writing client actually modelled override
 * [localPayload]'s values — a client on an older schema omits a key entirely, and absence must
 * mean "not modelled" rather than "reset to the default". Returns null when [settingsJson] is not
 * this payload's shape at all; the caller turns that into a failed sync step. Kept top-level (not
 * a member) so it is unit-testable without touching [HomeCatalogSettingsSyncService]'s
 * network/auth state.
 */
internal fun decodeHomeCatalogPayloadPreservingLocalDefaults(
    settingsJson: JsonObject,
    localPayload: SyncHomeCatalogPayload,
): SyncHomeCatalogPayload? = runCatching {
    val decoded = homeCatalogJson.decodeFromJsonElement(SyncHomeCatalogPayload.serializer(), settingsJson)
    decoded.copy(
        showCatalogType = if (settingsJson.containsKey(SHOW_CATALOG_TYPE_KEY)) {
            decoded.showCatalogType
        } else {
            localPayload.showCatalogType
        },
        hideUnreleasedContent = if (settingsJson.containsKey(HIDE_UNRELEASED_CONTENT_KEY)) {
            decoded.hideUnreleasedContent
        } else {
            localPayload.hideUnreleasedContent
        },
        hideCatalogUnderline = if (settingsJson.containsKey(HIDE_CATALOG_UNDERLINE_KEY)) {
            decoded.hideCatalogUnderline
        } else {
            localPayload.hideCatalogUnderline
        },
        hideDiscover = if (settingsJson.containsKey(HIDE_DISCOVER_KEY)) {
            decoded.hideDiscover
        } else {
            localPayload.hideDiscover
        },
    )
}.getOrNull()

object HomeCatalogSettingsSyncService {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("HomeCatalogSettingsSync"))
    private val log = Logger.withTag("HomeCatalogSettingsSyncService")

    @Volatile
    var isSyncingFromRemote: Boolean = false

    private var pushJob: Job? = null

    @Volatile
    private var completedInitialPull: SettingsPullToken? = null

    @Volatile
    private var cachedSharedSettings: CachedSharedSettings? = null

    // Token of a local edit whose push was skipped because the initial pull for that token had
    // not completed. Consumed by pullFromServer's malformed-blob branch, which lets the edit win
    // and repair the blob; cleared once a pull for the token completes. Session-scoped like
    // [completedInitialPull]; the token's userId keeps it inert across account switches.
    @Volatile
    private var localEditAwaitingInitialPull: SettingsPullToken? = null

    suspend fun pullFromServer(profileId: Int) {
        val pullToken = currentSettingsPullToken(profileId) ?: return
        val localPayload = HomeCatalogSettingsRepository.exportToSyncPayload()
        // A fetch failure propagates so runOrderedProfileSync records this step as failed and
        // the full pull is retried, instead of the sync being stamped fresh with the remote
        // catalog settings silently unapplied (same rule as TrackingSourceSettingsSyncService).
        val remoteBlob = fetchRemoteBlob(profileId)
        cachedSharedSettings = CachedSharedSettings(
            token = pullToken,
            settingsJson = remoteBlob?.settingsJson ?: buildJsonObject { },
        )

        if (remoteBlob == null) {
            log.i { "pullFromServer — no remote home catalog settings found; preserving local" }
            markInitialPullComplete(pullToken)
            return
        }

        val remotePayload = decodeHomeCatalogPayloadPreservingLocalDefaults(remoteBlob.settingsJson, localPayload)
        if (remotePayload == null) {
            // Same rule as TrackingSourceSettingsSyncService: with no local edit pending, a
            // malformed blob fails the step — marking it successful would leave the stale local
            // settings active and suppress the retry that a recorded failure earns. A local edit
            // that raced the incomplete initial pull may instead win and repair the blob: its
            // push re-encodes every payload key over the malformed values. Without that escape
            // the step would wedge, because pushes stay gated on this pull completing and
            // nothing on this device could ever rewrite the blob.
            if (localEditAwaitingInitialPull != pullToken) {
                error("failed to parse remote home catalog settings")
            }
            log.w { "pullFromServer — remote home catalog settings malformed; repairing from the raced local edit" }
            markInitialPullComplete(pullToken)
            if (!pushToRemote(pullToken)) {
                // Keep the edit owed so the retried step attempts the repair again.
                localEditAwaitingInitialPull = pullToken
                error("pushing the raced local home catalog edit over the malformed remote blob failed")
            }
            return
        }

        if (remotePayload.items.isEmpty()) {
            log.i { "pullFromServer — remote has empty items, preserving local catalog order" }
            applyRemotePayload(remotePayload)
            markInitialPullComplete(pullToken)
            return
        }

        applyRemotePayload(remotePayload)
        log.i { "pullFromServer — applied ${remotePayload.items.size} items from remote" }
        markInitialPullComplete(pullToken)
    }

    fun triggerPush() {
        val requestedToken = currentSettingsPullToken()
        if (requestedToken == null || !hasCompletedInitialPull(requestedToken)) {
            // Every call here is a genuine local mutation (applyFromRemote never triggers a
            // push), so a skip means a local edit raced the incomplete initial pull — remember
            // it so that pull can repair a malformed remote blob with it. Deliberately NOT
            // edit-wins overall: unlike the tracking-source twin, a well-formed remote payload
            // still applies over the raced edit (home's pull is remote-wins).
            if (requestedToken != null) localEditAwaitingInitialPull = requestedToken
            log.d { "triggerPush — skipped before initial home catalog pull completed" }
            return
        }
        pushJob?.cancel()
        pushJob = scope.launch {
            delay(500)
            if (isSyncingFromRemote) return@launch
            if (currentSettingsPullToken() != requestedToken) return@launch
            pushToRemote(requestedToken)
        }
    }

    private suspend fun pushToRemote(token: SettingsPullToken): Boolean =
        runCatching {
            val payload = HomeCatalogSettingsRepository.exportToSyncPayload()
            val jsonElement = mergedSharedPayloadJson(token, payload)

            val params = buildJsonObject {
                put("p_profile_id", token.profileId)
                put("p_platform", HOME_CATALOG_SHARED_SYNC_PLATFORM)
                put("p_settings_json", jsonElement)
                putSyncOriginClientId()
            }
            SupabaseProvider.client.postgrest.rpc("sync_push_home_catalog_settings", params)
            cachedSharedSettings = CachedSharedSettings(token = token, settingsJson = jsonElement)
            log.d { "pushToRemote — success" }
        }.fold(
            onSuccess = { true },
            onFailure = { e ->
                if (e is kotlinx.coroutines.CancellationException) throw e
                log.e(e) { "pushToRemote — FAILED" }
                false
            },
        )

    private fun hasCompletedInitialPull(token: SettingsPullToken): Boolean =
        completedInitialPull == token

    private fun markInitialPullComplete(token: SettingsPullToken) {
        completedInitialPull = token
        if (localEditAwaitingInitialPull == token) localEditAwaitingInitialPull = null
    }

    private fun applyRemotePayload(
        payload: SyncHomeCatalogPayload,
    ) {
        isSyncingFromRemote = true
        try {
            HomeCatalogSettingsRepository.applyFromRemote(payload)
        } finally {
            isSyncingFromRemote = false
        }
    }

    private suspend fun fetchRemoteBlob(
        profileId: Int,
    ): SupabaseHomeCatalogSettingsBlob? {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
            put("p_platform", HOME_CATALOG_SHARED_SYNC_PLATFORM)
        }
        val result = SupabaseProvider.client.postgrest.rpc("sync_pull_home_catalog_settings", params)
        return result.decodeList<SupabaseHomeCatalogSettingsBlob>().firstOrNull()
    }

    private fun mergedSharedPayloadJson(
        token: SettingsPullToken,
        payload: SyncHomeCatalogPayload,
    ): JsonObject {
        val localJson = homeCatalogJson.encodeToJsonElement(SyncHomeCatalogPayload.serializer(), payload).jsonObject
        val remoteJson = cachedSharedSettings
            ?.takeIf { cached -> cached.token == token }
            ?.settingsJson
        return mergeSharedSettingsJson(remoteJson = remoteJson, localJson = localJson)
    }
}
