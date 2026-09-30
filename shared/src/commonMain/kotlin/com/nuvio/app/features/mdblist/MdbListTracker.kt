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
 * MDBList as a tracking provider — upstream 0a654ac4's `MdbListTracker`, AUTH/ACCOUNT SURFACE ONLY
 * (phase 5.1). Upstream's object also owns the sync repository, library service, history and
 * scrobble services and the tracking ports built on them; those land in phase 5.2 (see the
 * `TODO(F5.2)` markers). Until then the descriptor advertises [TrackingCapability.AUTHENTICATION]
 * alone, so the registry never routes watched/progress/library/scrobble work to MDBList.
 *
 * Fork deviations from upstream (each marked inline):
 *  - network engine built lazily, so touching this object on the JVM test target (which has no
 *    Ktor engine) or at app startup never constructs an HttpClient;
 *  - [clearLocalState] is memory-only (the fork's `TrackingProfileStore` contract): the on-disk
 *    erase belongs to `core.account.AccountDataStores` (Keychain service
 *    `com.nuvio.media.mdblist` on Apple, `nuvio_mdblist_auth` on Android);
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
     */
    private object TrackerAuthPersistence : MdbListAuthPersistence {
        override fun read(profileId: Int): String? = try {
            PlatformMdbListAuthPersistence.read(profileId)
        } catch (error: Exception) {
            log.w(error) { "MDBList credentials unreadable for profile $profileId; treating as disconnected" }
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
    // TODO(F5.2): ratings client, sync repository, library service, history/scrobble services.
    val account = MdbListAccountController(auth, store, coroutineScope, { api.refreshUser(it) })

    private val authenticated = MutableStateFlow(isActiveAndAuthenticated(store.state.value))
    override val isAuthenticated: StateFlow<Boolean> = authenticated.asStateFlow()
    override val accountGeneration: Long get() = store.scope().generation

    // TODO(F5.2): upstream also advertises WATCHED_READ/WRITE, PROGRESS_READ/WRITE, SCROBBLE and
    // LIBRARY_READ/WRITE — add them together with the ports registered in [register].
    override val descriptor = TrackingProviderDescriptor(
        TrackingProviderId.MDBLIST,
        TrackingProviderId.MDBLIST.displayName,
        setOf(TrackingCapability.AUTHENTICATION),
    )

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
        // TODO(F5.2): registerHistoryWriter / registerScrobbler (MdbListTrackingWrites),
        // registerProgressProvider, registerWatchedProvider, registerLibraryProvider.
    }

    /** The device flow needs a client id; the build supplies it via `MDBLIST_CLIENT_ID`. */
    fun hasRequiredCredentials(): Boolean = auth.hasRequiredCredentials()

    override fun ensureLoaded() {
        if (activeProfile.value != ProfileRepository.activeProfileId) onProfileChanged()
        authenticated.value = isActiveAndAuthenticated(store.state.value)
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
        // TODO(F5.2): upstream also calls PlatformMdbListSyncStorage.clearAll() here; in the fork
        // the sync storage's in-memory state resets here and its disk payload joins
        // AccountDataStores instead.
        authenticated.value = false
    }

    override fun removeStoredProfile(profileId: Int) {
        // Fork: logged, not thrown — this runs inside the registry's profile-removal fan-out.
        try {
            store.removeProfile(profileId)
        } catch (error: Exception) {
            log.e(error) { "Failed to remove MDBList credentials for profile $profileId" }
        }
        // TODO(F5.2): upstream also removes the profile's PlatformMdbListSyncStorage payload.
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
