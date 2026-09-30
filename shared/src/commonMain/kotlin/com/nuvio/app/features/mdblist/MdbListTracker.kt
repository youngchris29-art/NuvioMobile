package com.nuvio.app.features.mdblist

import co.touchlab.kermit.Logger
import com.nuvio.app.core.build.AppVersionConfig
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tracking.TrackingAuthProvider
import com.nuvio.app.features.tracking.TrackingCapability
import com.nuvio.app.features.tracking.TrackingProviderDescriptor
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlin.concurrent.Volatile

/**
 * Flattened, Swift-friendly view of the MDBList account for the tvOS account card (fork-only;
 * upstream's Compose card reads [MdbListAuthState] and [MdbListAccountStatus] directly).
 *
 * @param hasClientId false when the build has no `MDBLIST_CLIENT_ID` — connecting cannot work.
 * @param userCode / [verificationUrl] / [verificationUrlComplete] / [expiresAtEpochMs] describe a
 *   pending device authorization (all null when none is pending). Show [userCode] and
 *   [verificationUrl]; encode [verificationUrlComplete] as the QR code.
 * @param errorKind [MdbListSyncError] name of the last failure, or null.
 * @param authErrorKind [MdbListAuthError] name of the last auth failure (e.g. `ACCESS_DENIED`,
 *   `EXPIRED_TOKEN`), or null. The store's own last auth error is used when the controller has none.
 */
data class MdbListAccountUiState(
    val profileId: Int = 1,
    val hasClientId: Boolean = false,
    val isConnected: Boolean = false,
    val username: String? = null,
    val isSupporter: Boolean = false,
    val userCode: String? = null,
    val verificationUrl: String? = null,
    val verificationUrlComplete: String? = null,
    val expiresAtEpochMs: Long? = null,
    val isBusy: Boolean = false,
    val errorKind: String? = null,
    val authErrorKind: String? = null,
    val revokeFailed: Boolean = false,
) {
    val isAwaitingApproval: Boolean get() = !isConnected && userCode != null
}

/**
 * MDBList as a tracking provider — upstream 0a654ac4/425e4d8a's `MdbListTracker`: account auth,
 * the sync repository (watched history, playback, dropped) and library service, and the
 * watched/progress/library/history/scrobble ports registered in [register].
 *
 * [ratings] (upstream 3f0d07be) serves `MdbListMetadataService`: ratings through the connected
 * account, or the personal API key when one is set.
 *
 * Fork deviations from upstream (each marked inline):
 *  - network engine built lazily, so touching this object on the JVM test target (which has no
 *    Ktor engine) or at app startup never constructs an HttpClient;
 *  - [clearLocalState] is memory-only (the fork's `TrackingProfileStore` contract): the on-disk
 *    erase belongs to `core.account.AccountDataStores` (Keychain service
 *    `com.nuvio.media.mdblist` + file store `MdbListSync` on Apple, `nuvio_mdblist_auth` +
 *    `nuvio_mdblist_sync` on Android);
 *  - fork-local `ensureLoaded(profileId)` override for per-profile credential isolation;
 *  - `…Checked` / safe twins for Swift (see MdbListAccountControllerBridging.kt) and
 *    [accountUiState].
 */
object MdbListTracker : TrackingAuthProvider {
    private val coroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("MdbListTracker"))
    private val activeProfile = MutableStateFlow(ProfileRepository.activeProfileId)

    private val log = Logger.withTag("MdbListTracker")

    /**
     * Fork wrapper around the platform persistence, two deviations:
     *  - `clear()` is a no-op. The store's only `persistence.clear()` caller is
     *    `MdbListAuthStore.clearAllProfiles()`, which only [clearLocalState] calls, so this keeps
     *    that memory-only — the account wipe erases the Keychain/SharedPreferences itself.
     *  - a failed READ is logged and treated as "not connected" instead of thrown. The store reads
     *    in its constructor, and this object is initialised from `ensureTrackingProvidersRegistered()`
     *    at app startup (Swift main thread on tvOS) and from repository tests: an unreadable
     *    Keychain (e.g. errSecMissingEntitlement in a test executable) must not crash either.
     *    Writes still throw, so a failed connect surfaces through the controller's status.
     *    [failedProfileId] remembers the failure so [ensureLoaded] retries the read (a transient
     *    Keychain error then recovers without a relaunch).
     */
    private object TrackerAuthPersistence : MdbListAuthPersistence {
        @Volatile
        var failedProfileId: Int? = null

        override fun read(profileId: Int): String? = try {
            PlatformMdbListAuthPersistence.read(profileId).also {
                if (failedProfileId == profileId) failedProfileId = null
            }
        } catch (error: Exception) {
            log.w(error) { "MDBList credentials unreadable for profile $profileId; treating as disconnected" }
            failedProfileId = profileId
            null
        }

        override fun write(profileId: Int, value: String?) = PlatformMdbListAuthPersistence.write(profileId, value)
        override fun clear() = Unit
    }

    internal val store = MdbListAuthStore(TrackerAuthPersistence, activeProfile.value)
    private val configuration = MdbListConfiguration(MdbListConfig.CLIENT_ID, AppVersionConfig.VERSION_NAME)

    // Fork: lazy. Upstream builds MdbListNetworkEngine (and so its platform HttpClient) eagerly.
    private val networkEngine by lazy { MdbListNetworkEngine(configuration) }
    private val http = MdbListHttpClient(MdbListHttpEngine { request -> networkEngine.execute(request) })
    val auth = MdbListAuthRepository(http, configuration, store)
    internal val api = MdbListApiClient(http, auth, store)
    internal val ratings = MdbListRatingsClient(api, store)
    val sync = MdbListSyncRepository(PlatformMdbListSyncStorage, store, api, activeProfile, coroutineScope)
    val library = MdbListLibraryService(api, sync, store, activeProfile, coroutineScope)
    private val history = MdbListHistoryService(api, sync)
    private val scrobble = MdbListScrobbleService(api, sync)
    val account = MdbListAccountController(auth, store, coroutineScope, { api.refreshUser(it) })

    private val authenticated = MutableStateFlow(isActiveAndAuthenticated(store.state.value))
    override val isAuthenticated: StateFlow<Boolean> = authenticated.asStateFlow()
    override val accountGeneration: Long get() = store.scope().generation

    override val descriptor = TrackingProviderDescriptor(
        TrackingProviderId.MDBLIST,
        TrackingProviderId.MDBLIST.displayName,
        setOf(
            TrackingCapability.AUTHENTICATION, TrackingCapability.WATCHED_READ, TrackingCapability.WATCHED_WRITE,
            TrackingCapability.PROGRESS_READ, TrackingCapability.PROGRESS_WRITE, TrackingCapability.SCROBBLE,
            TrackingCapability.LIBRARY_READ, TrackingCapability.LIBRARY_WRITE,
        ),
    )
    val writes = MdbListTrackingWrites(sync, history, scrobble)
    val progressProvider = MdbListTrackingProgressProvider(sync, scrobble, store, activeProfile, ::ensureLoaded)
    val watchedProvider = MdbListWatchedSyncAdapter(sync, history, store, activeProfile)
    val libraryProvider = MdbListTrackingLibraryProvider(library, sync, ::ensureLoaded)

    /** Swift-facing account state for the tvOS account card; see [MdbListAccountUiState]. */
    val accountUiState: StateFlow<MdbListAccountUiState> =
        combine(store.state, account.status) { state, status -> accountUiStateOf(state, status) }
            .stateIn(
                coroutineScope,
                SharingStarted.Eagerly,
                accountUiStateOf(store.state.value, account.status.value),
            )

    init {
        coroutineScope.launch {
            store.state.collectLatest { state ->
                authenticated.value = isActiveAndAuthenticated(state)
            }
        }
    }

    fun register() {
        if (TrackingProviderRegistry.authProvider(providerId) === this) return
        TrackingProviderRegistry.register(this)
        TrackingProviderRegistry.registerHistoryWriter(writes)
        TrackingProviderRegistry.registerScrobbler(writes)
        TrackingProviderRegistry.registerProgressProvider(progressProvider)
        TrackingProviderRegistry.registerWatchedProvider(watchedProvider)
        TrackingProviderRegistry.registerLibraryProvider(libraryProvider)
    }

    /** The device flow needs a client id; the build supplies it via `MDBLIST_CLIENT_ID`. */
    fun hasRequiredCredentials(): Boolean = auth.hasRequiredCredentials()

    override fun ensureLoaded() {
        if (activeProfile.value != ProfileRepository.activeProfileId) onProfileChanged()
        retryFailedRead()
        authenticated.value = isActiveAndAuthenticated(store.state.value)
    }

    /** Fork: re-read once per call while the current profile's last credential read failed. */
    private fun retryFailedRead() {
        if (TrackerAuthPersistence.failedProfileId == store.scope().profileId) store.reloadCurrentProfile()
    }

    /**
     * Fork-local (see [TrackingAuthProvider.ensureLoaded]): load exactly [profileId]'s credentials,
     * as `SimklAuthRepository.ensureLoaded(profileId)` does, for the sync spine's explicit-profile
     * pulls.
     */
    override fun ensureLoaded(profileId: Int) {
        if (activeProfile.value != profileId || store.scope().profileId != profileId) {
            selectProfile(profileId)
        }
        retryFailedRead()
        authenticated.value = isActiveAndAuthenticated(store.state.value)
    }

    override fun onProfileChanged() {
        selectProfile(ProfileRepository.activeProfileId)
    }

    private fun selectProfile(profileId: Int) {
        account.stopPolling()
        activeProfile.value = profileId
        store.selectProfile(profileId)
        authenticated.value = isActiveAndAuthenticated(store.state.value)
    }

    /** Memory-only (fork contract, see [TrackerAuthPersistence]); the account wipe erases disk. */
    override fun clearLocalState() {
        account.stopPolling()
        store.clearAllProfiles()
        // Fork: upstream also calls PlatformMdbListSyncStorage.clearAll() here. In the fork the
        // disk payload is erased by the account wipe (AccountDataStores "PlatformMdbListSyncStorage");
        // the sync repository and library service drop their in-memory state themselves when the
        // store's auth state turns unauthenticated (their auth-state collectors clear what they
        // published).
        authenticated.value = false
    }

    override fun removeStoredProfile(profileId: Int) {
        // Fork: logged, not thrown — this runs inside the registry's profile-removal fan-out.
        try {
            store.removeProfile(profileId)
        } catch (error: Exception) {
            log.e(error) { "Failed to remove MDBList credentials for profile $profileId" }
        }
        coroutineScope.launch {
            try {
                // Fork: no scope check. This deletes ANOTHER profile's file; tying it to the
                // current store scope let a profile switch or generation bump before the launch
                // ran cancel the removal and leave the deleted slot's snapshot on disk.
                PlatformMdbListSyncStorage.remove(profileId) {}
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                log.e(error) { "Failed to remove MDBList sync cache for profile $profileId" }
            }
        }
    }

    private fun isActiveAndAuthenticated(state: MdbListAuthState): Boolean =
        state.scope.profileId == activeProfile.value && state.isAuthenticated

    private fun accountUiStateOf(state: MdbListAuthState, status: MdbListAccountStatus): MdbListAccountUiState {
        // The controller's status belongs to one scope; once the store has moved on (profile
        // switch, connect/disconnect generation bump) only its busy/error flags for the SAME
        // profile are still meaningful.
        val statusApplies = status.scope?.profileId == state.scope.profileId
        val session = state.session.takeIf { !state.isAuthenticated }
        return MdbListAccountUiState(
            profileId = state.scope.profileId,
            hasClientId = configuration.clientId.isNotBlank(),
            isConnected = state.isAuthenticated,
            username = state.user?.username,
            isSupporter = state.user?.isSupporter == true,
            userCode = session?.userCode,
            verificationUrl = session?.verificationUri,
            verificationUrlComplete = session?.verificationUriComplete,
            expiresAtEpochMs = session?.expiresAtEpochMs,
            isBusy = statusApplies && status.isBusy,
            errorKind = status.error?.takeIf { statusApplies }?.name,
            authErrorKind = (status.authError?.takeIf { statusApplies } ?: state.error)?.name,
            revokeFailed = statusApplies && status.revokeFailed,
        )
    }
}
