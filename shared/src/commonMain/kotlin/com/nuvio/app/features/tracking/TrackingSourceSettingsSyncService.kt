package com.nuvio.app.features.tracking

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.sync.TRACKING_SOURCE_SHARED_SYNC_PLATFORM
import com.nuvio.app.core.sync.putSyncOriginClientId
import com.nuvio.app.features.library.LibrarySourceMode
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.trakt.normalizeTraktContinueWatchingDaysCap
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlin.concurrent.Volatile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
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

private const val PUSH_DEBOUNCE_MS = 1500L

private val trackingSourceJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}

@Serializable
data class SyncTrackingSourcePayload(
    @SerialName("watch_progress_source") val watchProgressSource: String? = null,
    @SerialName("library_source_mode") val librarySourceMode: String? = null,
    @SerialName("continue_watching_days_cap") val continueWatchingDaysCap: Int? = null,
)

@Serializable
private data class SupabaseTrackingSourceSettingsBlob(
    @SerialName("profile_id") val profileId: Int = 0,
    @SerialName("settings_json") val settingsJson: JsonObject? = null,
)

private data class PullToken(
    val userId: String,
    val profileId: Int,
)

/**
 * Snapshot of the shared-namespace settings blob fetched during the most recent [PullToken], kept
 * so the push path can merge against it without a second remote fetch, and so a push whose values
 * already match the server can be skipped outright. Invalidated implicitly: a push under a stale
 * [PullToken] (account/profile switched mid-flight) merges remote-less rather than reading data
 * for the wrong account.
 *
 * Same knowingly-imperfect tradeoff [com.nuvio.app.features.home.HomeCatalogSettingsSyncService]
 * carries: the RPC is replace-style, so another client writing an unknown-to-this-client field
 * BETWEEN this session's pull and a later push has that field overwritten with the cached value.
 * Fetch-before-every-push only shrinks that window, never closes it.
 */
private data class CachedSharedSettings(
    val token: PullToken,
    val settingsJson: JsonObject,
)

internal data class TrackingSourceSelection(
    val watchProgressSource: WatchProgressSource,
    val librarySourceMode: LibrarySourceMode,
    val continueWatchingDaysCap: Int,
)

/**
 * Pure merge of the shared-namespace remote blob with this client's local payload: remote entries
 * first, local overwrites on key collision. Kept top-level (not a member) so it is unit-testable
 * without touching [TrackingSourceSettingsSyncService]'s network/auth state.
 */
internal fun mergeTrackingSourceSettingsJson(
    remoteJson: JsonObject?,
    localJson: JsonObject,
): JsonObject = buildJsonObject {
    remoteJson?.forEach { (key, value) -> put(key, value) }
    localJson.forEach { (key, value) -> put(key, value) }
}

/**
 * Presence-gated decode: only the keys the writing client actually modelled override [local]. A
 * client on an older schema omits a key entirely, and absence must mean "not modelled" rather than
 * "reset to the default". A key that IS present but malformed resolves through the storage
 * decoders' own fallbacks. Returns null when [settingsJson] is not this payload's shape at all.
 */
internal fun decodeTrackingSourceSelectionPreservingLocal(
    settingsJson: JsonObject,
    local: TrackingSourceSelection,
): TrackingSourceSelection? = runCatching {
    val decoded = trackingSourceJson.decodeFromJsonElement(SyncTrackingSourcePayload.serializer(), settingsJson)
    TrackingSourceSelection(
        watchProgressSource = decoded.watchProgressSource
            ?.let { WatchProgressSource.fromStorage(it) }
            ?: local.watchProgressSource,
        librarySourceMode = decoded.librarySourceMode
            ?.let { librarySourceModeFromStorage(it) }
            ?: local.librarySourceMode,
        continueWatchingDaysCap = decoded.continueWatchingDaysCap
            ?.let { normalizeTraktContinueWatchingDaysCap(it) }
            ?: local.continueWatchingDaysCap,
    )
}.getOrNull()

/**
 * BUG-75: syncs the tracking source preferences under one namespace every platform reads and
 * writes, so switching Trakt→Simkl on the phone reaches the TV.
 *
 * Migration / compatibility:
 * - The platform-scoped profile blob still carries `trakt_settings_payload`, and still applies
 *   first in [com.nuvio.app.core.sync.runOrderedProfileSync]. This service's step runs immediately
 *   after it, so a present shared value always wins over the platform-scoped one.
 * - An old client that only writes its platform blob still propagates: an updated client pulls
 *   that platform value, its push observer sees the changed selection and mirrors it into the
 *   shared namespace. Last writer wins, which is the same rule the platform blob already uses.
 * - Two clients seeding an absent shared blob simultaneously is likewise resolved last-writer-wins;
 *   both seeds are the clients' own current selections, so the loser's next local change re-pushes.
 */
object TrackingSourceSettingsSyncService {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("TrackingSourceSettingsSync"))
    private val log = Logger.withTag("TrackingSourceSettingsSyncService")

    @Volatile
    var isSyncingFromRemote: Boolean = false

    private var observeJob: Job? = null

    @Volatile
    private var completedInitialPull: PullToken? = null

    @Volatile
    private var cachedSharedSettings: CachedSharedSettings? = null

    suspend fun pullFromServer(profileId: Int) {
        runCatching {
            val pullToken = currentPullToken(profileId) ?: return
            TrackingSettingsRepository.ensureLoaded()
            val localSelection = currentSelection()
            val remoteJson = fetchRemoteSettingsJson(profileId)
            cachedSharedSettings = CachedSharedSettings(
                token = pullToken,
                settingsJson = remoteJson ?: buildJsonObject { },
            )

            if (remoteJson == null) {
                // Seed: nothing under the shared namespace yet, so this client's current selection
                // becomes its first value — otherwise the namespace stays empty until someone
                // changes a setting, and a TV that never changes one never publishes anything.
                log.i { "pullFromServer — no remote tracking source settings found; seeding from local" }
                pushToRemote(pullToken, localSelection)
                markInitialPullComplete(pullToken)
                return
            }

            val remoteSelection = decodeTrackingSourceSelectionPreservingLocal(remoteJson, localSelection)
            if (remoteSelection == null) {
                log.w { "pullFromServer — failed to parse remote tracking source settings" }
                markInitialPullComplete(pullToken)
                return
            }

            applyRemoteSelection(remoteSelection)
            log.i { "pullFromServer — applied remote tracking source settings" }
            markInitialPullComplete(pullToken)
        }.onFailure { e ->
            isSyncingFromRemote = false
            log.e(e) { "pullFromServer — FAILED" }
        }
    }

    @OptIn(FlowPreview::class)
    fun startObserving() {
        if (observeJob?.isActive == true) return
        TrackingSettingsRepository.ensureLoaded()
        observeJob = scope.launch {
            TraktSettingsRepository.uiState
                .map { state ->
                    TrackingSourceSelection(
                        watchProgressSource = state.watchProgressSource,
                        librarySourceMode = state.librarySourceMode,
                        continueWatchingDaysCap = state.continueWatchingDaysCap,
                    )
                }
                .distinctUntilChanged()
                .drop(1)
                .debounce(PUSH_DEBOUNCE_MS)
                .collect { selection ->
                    val token = currentPullToken() ?: return@collect
                    // Pushing before the pull lands would publish this device's stale selection
                    // over the account's newer one.
                    if (!hasCompletedInitialPull(token)) {
                        log.d { "push — skipped before initial tracking source pull completed" }
                        return@collect
                    }
                    if (isSyncingFromRemote) return@collect
                    // The apply above emits through this same flow; without this the pull would
                    // echo straight back as a push of the value we just received.
                    if (selection == cachedRemoteSelection(token)) return@collect
                    pushToRemote(token, selection)
                }
        }
    }

    fun clearAccountState() {
        observeJob?.cancel()
        observeJob = null
        completedInitialPull = null
        cachedSharedSettings = null
    }

    private suspend fun pushToRemote(token: PullToken, selection: TrackingSourceSelection) {
        runCatching {
            val jsonElement = mergedSharedPayloadJson(token, selection)

            val params = buildJsonObject {
                put("p_profile_id", token.profileId)
                put("p_platform", TRACKING_SOURCE_SHARED_SYNC_PLATFORM)
                put("p_settings_json", jsonElement)
                putSyncOriginClientId()
            }
            SupabaseProvider.client.postgrest.rpc("sync_push_profile_settings_blob", params)
            cachedSharedSettings = CachedSharedSettings(token = token, settingsJson = jsonElement)
            log.d { "pushToRemote — success" }
        }.onFailure { e ->
            log.e(e) { "pushToRemote — FAILED" }
        }
    }

    private fun currentPullToken(profileId: Int = ProfileRepository.activeProfileId): PullToken? {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) return null
        return PullToken(
            userId = authState.userId,
            profileId = profileId,
        )
    }

    private fun hasCompletedInitialPull(token: PullToken): Boolean =
        completedInitialPull == token

    private fun markInitialPullComplete(token: PullToken) {
        completedInitialPull = token
    }

    private fun currentSelection(): TrackingSourceSelection {
        val state = TrackingSettingsRepository.uiState.value
        return TrackingSourceSelection(
            watchProgressSource = state.watchProgressSource,
            librarySourceMode = state.librarySourceMode,
            continueWatchingDaysCap = state.continueWatchingDaysCap,
        )
    }

    private fun applyRemoteSelection(selection: TrackingSourceSelection) {
        isSyncingFromRemote = true
        try {
            TraktSettingsRepository.applyFromRemoteSync(
                watchProgressSource = selection.watchProgressSource,
                librarySourceMode = selection.librarySourceMode,
                continueWatchingDaysCap = selection.continueWatchingDaysCap,
            )
        } finally {
            isSyncingFromRemote = false
        }
    }

    private suspend fun fetchRemoteSettingsJson(profileId: Int): JsonObject? {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
            put("p_platform", TRACKING_SOURCE_SHARED_SYNC_PLATFORM)
        }
        val result = SupabaseProvider.client.postgrest.rpc("sync_pull_profile_settings_blob", params)
        return result.decodeList<SupabaseTrackingSourceSettingsBlob>().firstOrNull()?.settingsJson
    }

    private fun cachedRemoteSelection(token: PullToken): TrackingSourceSelection? {
        val cached = cachedSharedSettings?.takeIf { it.token == token }?.settingsJson ?: return null
        val decoded = runCatching {
            trackingSourceJson.decodeFromJsonElement(SyncTrackingSourcePayload.serializer(), cached)
        }.getOrNull() ?: return null
        val watchProgressSource = decoded.watchProgressSource ?: return null
        val librarySourceMode = decoded.librarySourceMode ?: return null
        val continueWatchingDaysCap = decoded.continueWatchingDaysCap ?: return null
        return TrackingSourceSelection(
            watchProgressSource = WatchProgressSource.fromStorage(watchProgressSource),
            librarySourceMode = librarySourceModeFromStorage(librarySourceMode),
            continueWatchingDaysCap = normalizeTraktContinueWatchingDaysCap(continueWatchingDaysCap),
        )
    }

    private fun mergedSharedPayloadJson(
        token: PullToken,
        selection: TrackingSourceSelection,
    ): JsonObject {
        val localJson = trackingSourceJson.encodeToJsonElement(
            SyncTrackingSourcePayload.serializer(),
            SyncTrackingSourcePayload(
                watchProgressSource = selection.watchProgressSource.name,
                librarySourceMode = selection.librarySourceMode.name,
                continueWatchingDaysCap = selection.continueWatchingDaysCap,
            ),
        ).jsonObject
        val remoteJson = cachedSharedSettings
            ?.takeIf { cached -> cached.token == token }
            ?.settingsJson
        return mergeTrackingSourceSettingsJson(remoteJson = remoteJson, localJson = localJson)
    }
}
