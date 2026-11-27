package com.nuvio.app.features.profiles

import kotlin.concurrent.Volatile
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.auth.isAnonymous
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.identity.AccountKey
import com.nuvio.app.core.identity.AccountToken
import com.nuvio.app.core.identity.OwedProfilePull
import com.nuvio.app.core.identity.CommitResult
import com.nuvio.app.core.identity.IdentityGate
import com.nuvio.app.core.identity.ProfileIdentityRouterProvider
import com.nuvio.app.core.identity.RowAdmission
import com.nuvio.app.core.identity.RowRejection
import com.nuvio.app.core.identity.Verdict
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import com.nuvio.app.core.sync.putSyncOriginClientId
import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import kotlinx.coroutines.CancellationException
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put

@Serializable
private data class StoredProfilePayload(
    val userId: String,
    val activeProfileIndex: Int = 1,
    val hasEverSelectedProfile: Boolean = false,
    val rememberLastProfileEnabled: Boolean = false,
    val profiles: List<NuvioProfile> = emptyList(),
)

object ProfileRepository {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("ProfileRepository"))
    private val log = Logger.withTag("ProfileRepository")
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val _state = MutableStateFlow(ProfileState())
    val state: StateFlow<ProfileState> = _state.asStateFlow()

    // Review r10: read off the main thread by the source-search store when a request arrives.
    // Fork (scope identity, W2): a changing write asks the router; on tvOS it is accepted only
    // inside a barrier apply or window body (P2). Same-value writes skip the hook.
    @Volatile
    private var activeProfileIndex: Int = 1
        set(value) {
            if (value == field || ProfileIdentityRouterProvider.router.onSlotWrite(field, value)) field = value
        }
    private var loadedCacheForUserId: String? = null

    val activeProfileId: Int get() = activeProfileIndex

    fun setRememberLastProfileEnabled(enabled: Boolean) {
        if (_state.value.rememberLastProfileEnabled == enabled) return

        _state.update { s -> s.copy(rememberLastProfileEnabled = enabled) }
        persist()
    }

    fun loadCachedProfiles(): Boolean {
        val stored = decodeStoredPayload() ?: return false
        loadedCacheForUserId = stored.userId
        applyStoredPayload(stored)
        ProfileLifecycleProvider.coordinator.onProfilesCached()
        return _state.value.profiles.isNotEmpty()
    }

    fun ensureLoaded(userId: String) {
        if (loadedCacheForUserId == userId && _state.value.isLoaded) return

        val stored = decodeStoredPayload()
        loadedCacheForUserId = userId
        if (stored == null) {
            _state.value = ProfileState()
            activeProfileIndex = 1
            return
        }

        if (stored.userId != userId) {
            _state.value = ProfileState()
            activeProfileIndex = 1
            return
        }

        applyStoredPayload(stored)
    }

    fun clearInMemory() {
        loadedCacheForUserId = null
        activeProfileIndex = 1
        _state.value = ProfileState()
    }

    suspend fun pullProfiles() {
        if (AuthRepository.state.value.isAnonymous) {
            if (!_state.value.isLoaded) {
                _state.update { s -> s.copy(isLoaded = true) }
            }
            return
        }
        val accountToken = IdentityGate.currentAccountToken()
        if (accountToken == null) {
            // Fork (W2 review r1 #3): an identity window holds (a sign-in still publishing); the
            // pull is owed to this account and re-issued once the identity opens on it.
            OwedProfilePull.owe(AccountKey.of(AuthRepository.state.value))
            return
        }
        val ticket = AuthRepository.sessionTicket()
        try {
            val result = SupabaseProvider.client.postgrest.rpc("sync_pull_profiles")
            val profiles = result.decodeList<NuvioProfile>()
            val router = ProfileIdentityRouterProvider.router
            // Fork (W2, 8.0.1): published only for the account the pull started under; the block
            // returns the active slot when the new list lacks it (the router requests its removal
            // after the commit).
            router.publishPulledProfiles(profiles, accountToken) {
                val missing = activeProfileIndex.takeIf { slot -> profiles.none { it.profileIndex == slot } }
                _state.update { s -> s.copy(
                    profiles = profiles.sortedBy { it.profileIndex },
                    isLoaded = true,
                    activeProfile = profiles.find { it.profileIndex == activeProfileIndex }
                        ?: router.onActiveSlotMissing(activeProfileIndex, profiles, accountToken),
                    listToken = accountToken,
                ) }
                if (_state.value.activeProfile != null) {
                    activeProfileIndex = _state.value.activeProfile!!.profileIndex
                }
                persist()
                missing
            }
        } catch (e: Throwable) {
            if (AuthRepository.reportSessionError(ticket, e, "Profile pull")) return
            log.e(e) { "Failed to pull profiles" }
            if (!_state.value.isLoaded) {
                _state.update { s -> s.copy(isLoaded = true) }
            }
        }
    }

    // Stage B review r10 findings: the id write and the fan-out below are one profile transition
    // (ActiveProfileProvider.transition), so a source search built or admitted in between is
    // refused instead of mixing this profile's id with the previous one's add-ons or account.
    // Fork (W2): through the router; the default is the line above exactly, tvOS starts a barrier select.
    fun selectProfile(profileIndex: Int) = ProfileIdentityRouterProvider.router.selectProfile(profileIndex, ::selectProfileNow)

    private fun selectProfileNow(profileIndex: Int) {
        activeProfileIndex = profileIndex
        val selectedProfile = _state.value.profiles.find { it.profileIndex == profileIndex }
        _state.update { s -> s.copy(
            activeProfile = selectedProfile,
            hasEverSelectedProfile = selectedProfile != null || s.hasEverSelectedProfile,
        ) }
        // Persistence and the repository fan-out are best-effort side effects of a selection that
        // has already happened. Both run on the caller's thread — on tvOS that is the Swift main
        // thread, where an escaped Kotlin exception aborts the process instead of surfacing as a
        // catchable Swift error, so a single failing repository would make every profile tap a
        // force-close. Degrade to a log and let the user into the app.
        runCatching { persist() }
            .onFailure { log.e(it) { "Failed to persist profile selection $profileIndex" } }
        runCatching { ProfileLifecycleProvider.coordinator.onProfileSelected(profileIndex) }
            .onFailure { log.e(it) { "Profile-select fan-out failed for profile $profileIndex" } }
    }

    /**
     * Fork (scope identity, W2, 8.0.2): the barrier's select. The state lines of [selectProfileNow],
     * a best-effort persist, then the checked fan-out; returns the must-succeed steps that failed.
     */
    internal fun applySelectionChecked(profileIndex: Int): List<String> {
        writeSelection(profileIndex)
        return afterSelectionChecked(profileIndex)
    }

    /** Rule G: the slot and active-profile state write only (one state write, run inside the admission's commit section). */
    internal fun writeSelection(profileIndex: Int) {
        activeProfileIndex = profileIndex
        val selectedProfile = _state.value.profiles.find { it.profileIndex == profileIndex }
        _state.update { s -> s.copy(
            activeProfile = selectedProfile,
            hasEverSelectedProfile = selectedProfile != null || s.hasEverSelectedProfile,
        ) }
    }

    /** After [writeSelection], outside the commit section: a best-effort persist, then the checked fan-out. */
    internal fun afterSelectionChecked(profileIndex: Int): List<String> {
        runCatching { persist() }
            .onFailure { log.e(it) { "Failed to persist profile selection $profileIndex" } }
        return ProfileLifecycleProvider.coordinator.onProfileSelectedChecked(profileIndex)
    }

    /**
     * Fork (W2 review r5, audit #3): the ONE place the displayed list's token is maintained. Called
     * by the account hook (inside the publish window, after ensureLoaded) and after every settle to
     * Open under a new account token (IdentityImmediate.onAccountTokenSettled), so a same-account
     * session change re-stamps the list too. Stamps only a list that belongs to the token's account
     * (the owner it was loaded for); an atomic update, never carrying a stale list.
     */
    internal fun stampListForToken(token: AccountToken) {
        val owner = when (val account = token.account) {
            is AccountKey.Account -> account.userId
            is AccountKey.Guest -> account.guestId
            AccountKey.None -> null
        }
        if (owner == null || loadedCacheForUserId != owner) return
        _state.update { s -> if (s.listToken == token) s else s.copy(listToken = token) }
    }

    /** The settle callback: applied only while [token] is still current (a later settle wins). */
    internal fun stampListIfCurrent(token: AccountToken) {
        IdentityGate.commitAccount(token, "stampList") { stampListForToken(token) }
    }

    /** Fork (W2, 5.2): the active profile was removed remotely; the slot number stays. */
    internal fun applyActiveRemoved() {
        _state.update { s -> s.copy(activeProfile = null) }
    }

    /** Fork (W2, launch restore): whose profile cache is on disk, if any. */
    internal fun cachedPayloadUserId(): String? = decodeStoredPayload()?.userId

    /** Fork (W2, DEBUG knob 0.5): rewrites the cached payload's owner. */
    internal fun debugRewriteCachedOwner(userId: String) {
        val stored = decodeStoredPayload() ?: return
        ProfileStorage.savePayload(json.encodeToString(stored.copy(userId = userId)))
    }

    suspend fun pushProfiles(
        profiles: List<ProfilePushPayload>,
        token: AccountToken? = IdentityGate.currentAccountToken(),
    ) = pushProfilesBuilt(token) { profiles }

    /**
     * Fork (W2, 5.4; review r6 #1, #2): [build] derives the payload list from the CURRENT list.
     * Guest: inside the commit section, so a concurrent edit or delete is never overwritten.
     * Signed in: built just before the RPC, which is dispatched only while [token] holds and with
     * the auth lane held (AuthRepository.dispatchUnderSession). null from [build]: nothing to push.
     */
    private suspend fun pushProfilesBuilt(token: AccountToken?, build: (List<NuvioProfile>) -> List<ProfilePushPayload>?) {
        if (AuthRepository.state.value.isAnonymous) {
            val applied = IdentityGate.commitAccount(token, "pushProfiles") { build(_state.value.profiles)?.let { applyPayloadsLocally(it, token) } }
            if (applied is CommitResult.Rejected) log.w { "Profile edit refused: the account changed (${applied.reason})" }
            return
        }
        val ticket = AuthRepository.sessionTicket()
        try {
            val sent = AuthRepository.dispatchUnderSession(token, "pushProfiles") {
                val payloads = build(_state.value.profiles) ?: return@dispatchUnderSession false
                val params = buildJsonObject {
                    put("p_client_max_profiles", MAX_PROFILES)
                    put("p_profiles", json.encodeToJsonElement(payloads))
                    putSyncOriginClientId()
                }
                pushRpcForTest?.invoke(payloads) ?: SupabaseProvider.client.postgrest.rpc("sync_push_profiles", params)
                true
            }
            if (sent == true && pushRpcForTest == null) pullProfiles()
        } catch (e: Throwable) {
            if (AuthRepository.reportSessionError(ticket, e, "Profile push")) return
            log.e(e) { "Failed to push profiles" }
        }
    }

    private fun NuvioProfile.toPushPayload() = ProfilePushPayload(
        profileIndex = profileIndex,
        name = name,
        avatarColorHex = avatarColorHex,
        usesPrimaryAddons = usesPrimaryAddons,
        usesPrimaryPlugins = usesPrimaryPlugins,
        avatarId = avatarId,
        avatarUrl = avatarUrl,
    )

    suspend fun createProfile(
        name: String,
        avatarColorHex: String,
        avatarId: String? = null,
        avatarUrl: String? = null,
        usesPrimaryAddons: Boolean = false,
    ) = createProfileUnder(IdentityGate.currentAccountToken(), name, avatarColorHex, avatarId, avatarUrl, usesPrimaryAddons)

    /** Fork (W2 review r6): tvOS creates under the token of the list the picker displayed. */
    suspend fun createProfile(
        list: ProfileState,
        name: String,
        avatarColorHex: String,
        avatarId: String? = null,
        avatarUrl: String? = null,
        usesPrimaryAddons: Boolean = false,
    ) {
        val token = list.listToken ?: return
        createProfileUnder(token, name, avatarColorHex, avatarId, avatarUrl, usesPrimaryAddons)
    }

    private suspend fun createProfileUnder(
        token: AccountToken?,
        name: String,
        avatarColorHex: String,
        avatarId: String?,
        avatarUrl: String?,
        usesPrimaryAddons: Boolean,
    ) = pushProfilesBuilt(token) { existing ->
        // r6 #2: the free slot and the list come from the current list (inside the commit for guests).
        val nextIndex = ((1..MAX_PROFILES).toSet() - existing.map { it.profileIndex }.toSet()).minOrNull()
        nextIndex?.let {
            existing.map { profile -> profile.toPushPayload() } + ProfilePushPayload(
                profileIndex = it,
                name = name,
                avatarColorHex = avatarColorHex,
                usesPrimaryAddons = usesPrimaryAddons,
                avatarId = avatarId,
                avatarUrl = avatarUrl,
            )
        }
    }

    suspend fun updateProfile(
        profileIndex: Int,
        name: String,
        avatarColorHex: String,
        avatarId: String? = null,
        avatarUrl: String? = null,
        usesPrimaryAddons: Boolean = false,
    ) = updateProfileUnder(IdentityGate.currentAccountToken(), profileIndex, name, avatarColorHex, avatarId, avatarUrl, usesPrimaryAddons)

    /** Fork (W2 review r6): tvOS edits the displayed row, under the token of the list it came from. */
    suspend fun updateProfile(
        row: DisplayedProfile,
        name: String,
        avatarColorHex: String,
        avatarId: String? = null,
        avatarUrl: String? = null,
        usesPrimaryAddons: Boolean = false,
    ) {
        val token = row.listToken ?: return
        updateProfileUnder(token, row.profile.profileIndex, name, avatarColorHex, avatarId, avatarUrl, usesPrimaryAddons, row.profile)
    }

    /**
     * Review r7: the row rule (RowAdmission) against the list in memory. Called inside the section
     * that acts, after that section checked [token] is the current account token; the list must
     * be that token's list, and the row in the slot the same profile with the same lock state.
     */
    private fun rowRejection(displayed: NuvioProfile, token: AccountToken?): RowRejection? {
        val s = _state.value
        return RowAdmission.decide(displayed, token, s.listToken, s.profiles)?.also {
            log.w { "Profile ${displayed.profileIndex} action refused: $it" }
        }
    }

    private suspend fun updateProfileUnder(
        token: AccountToken?,
        profileIndex: Int,
        name: String,
        avatarColorHex: String,
        avatarId: String?,
        avatarUrl: String?,
        usesPrimaryAddons: Boolean,
        displayed: NuvioProfile? = null,
    ) = pushProfilesBuilt(token) { current ->
        if (current.none { it.profileIndex == profileIndex }) return@pushProfilesBuilt null // deleted meanwhile
        // Review r7: inside the section that writes (guest commit / signed-in lane), before the push.
        if (displayed != null && rowRejection(displayed, token) != null) return@pushProfilesBuilt null
        current.map { profile ->
            if (profile.profileIndex == profileIndex) {
                ProfilePushPayload(
                    profileIndex = profileIndex,
                    name = name,
                    avatarColorHex = avatarColorHex,
                    usesPrimaryAddons = usesPrimaryAddons,
                    avatarId = avatarId,
                    avatarUrl = avatarUrl,
                )
            } else {
                profile.toPushPayload()
            }
        }
    }

    suspend fun deleteProfile(profileIndex: Int) = deleteProfileUnder(profileIndex, IdentityGate.currentAccountToken())

    /**
     * Fork (W2 review r6 #1): tvOS deletes the displayed row, under the token of the list it came
     * from (a row of A's list can never delete in B, however late the PIN check completes).
     */
    suspend fun deleteProfile(row: DisplayedProfile) = deleteProfileUnder(row.profile.profileIndex, row.listToken, row.profile)

    /** Tests only: replaces the verify RPC and its refresh (audit #1/#2); runs under the read-only dispatch. */
    internal var verifyRpcForTest: (suspend (Int, String) -> PinVerifyResult)? = null

    /** Tests only: replaces the profile push RPC (review r7 row-rule tests). */
    internal var pushRpcForTest: (suspend (List<ProfilePushPayload>) -> Unit)? = null

    /** Tests only: replaces the delete RPC (r6 #1 binding tests). */
    internal var deleteRpcForTest: (suspend (Int) -> Unit)? = null

    /** Tests only: runs in a guest delete after the token check, before its commit section (r6 #2). */
    internal var beforeGuestDeleteCommitForTest: () -> Unit = {}

    /** Tests only: whether the session is a guest's, instead of AuthRepository.state (no auth in unit tests). */
    internal var isGuestForTest: Boolean? = null

    private suspend fun deleteProfileUnder(profileIndex: Int, token: AccountToken?, displayed: NuvioProfile? = null) {
        // Fork (W2 review r5 #4): no delete without the account it is for. A window holds (or
        // recovery): refuse before any RPC, so a delete never succeeds remotely while its local
        // tracker cleanup is refused. The user retries from the picker.
        if (token == null) {
            log.w { "Profile delete $profileIndex refused: no account token (identity transition in progress)" }
            return
        }
        val router = ProfileIdentityRouterProvider.router
        if (isGuestForTest ?: AuthRepository.state.value.isAnonymous) {
            beforeGuestDeleteCommitForTest()
            // Fork (W2, 5.3; review r6 #2): the remaining list is computed from the CURRENT list
            // inside the commit section, and that same result drives the cleanup.
            val filtered = IdentityGate.commitAccount(token, "guestDelete") {
                // Review r7: the row rule inside the section, before anything is written.
                if (displayed != null && rowRejection(displayed, token) != null) return@commitAccount null
                val remaining = _state.value.profiles.filter { it.profileIndex != profileIndex }
                ProfilePinCacheStorage.removePayload(profileIndex)
                _state.update { s -> s.copy(
                    profiles = remaining,
                    activeProfile = if (s.activeProfile?.profileIndex == profileIndex) {
                        router.onActiveSlotMissing(profileIndex, remaining, token)
                    } else {
                        s.activeProfile
                    },
                    listToken = token,
                ) }
                if (_state.value.activeProfile != null) {
                    activeProfileIndex = _state.value.activeProfile!!.profileIndex
                }
                persist()
                remaining
            }
            if (filtered is CommitResult.Committed) filtered.value?.let { router.afterProfileDeleted(profileIndex, it, token) }
            return
        }
        val ticket = AuthRepository.sessionTicket()
        try {
            val sent = AuthRepository.dispatchUnderSession(token, "deleteProfile") {
                // Review r7: the row rule with the lane and the account check held, before the RPC.
                if (displayed != null && rowRejection(displayed, token) != null) return@dispatchUnderSession false
                val params = buildJsonObject {
                    put("p_profile_id", profileIndex)
                    putSyncOriginClientId()
                }
                deleteRpcForTest?.invoke(profileIndex) ?: SupabaseProvider.client.postgrest.rpc("sync_delete_profile_data", params)
                true
            }
            if (sent != true) {
                log.w { "Profile delete $profileIndex refused: the account changed before the request" }
                return
            }
            // Only after the server delete succeeded: a failed RPC leaves the profile alive, and
            // wiping its local tracker credentials then would silently disconnect it. Fork (W2):
            // the router also moves the active profile when it was the one deleted (5.3).
            router.afterProfileDeleted(profileIndex, _state.value.profiles.filter { it.profileIndex != profileIndex }, token)
            if (deleteRpcForTest == null) pullProfiles()
        } catch (e: Throwable) {
            if (AuthRepository.reportSessionError(ticket, e, "Profile delete")) return
            log.e(e) { "Failed to delete profile $profileIndex" }
        }
    }

    /**
     * Fork: erase a deleted profile's locally stored tracker data (Trakt/Simkl auth + Simkl sync
     * snapshot + MDBList Keychain tokens, via each registered `TrackingProfileStore`'s
     * `removeStoredProfile`). Profile slots are reused, so without this a NEW profile created in
     * slot [profileIndex] inherited the previous person's connected accounts — and would sync its
     * watch history into them. Upstream's `TrackingProviderRegistry.removeStoredProfiles` had no
     * caller in this fork before this.
     *
     * Registration is forced first: nothing guarantees the tracker objects were touched this
     * session, and an unregistered store would silently keep its data. Never throws (the delete
     * itself already succeeded); a store failure is logged.
     */
    internal fun removeDeletedProfileTrackerData(profileIndex: Int) {
        try {
            ensureTrackingProvidersRegistered()
            TrackingProviderRegistry.removeStoredProfiles(listOf(profileIndex))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            log.e(error) { "Failed to remove local tracker data for deleted profile $profileIndex" }
        }
    }

    suspend fun verifyPin(profileIndex: Int, pin: String): PinVerifyResult =
        verifyPinUnder(profileIndex, pin, null) ?: PinVerifyResult(unlocked = false)

    /**
     * Fork (W2 review r6 #1, audit #1/#2): the displayed row, verified while the token of its list
     * holds for a picker action (Open, or Recovery(FailedApply): the same check admission makes).
     * A refusal is its own outcome ([PinCheck.refused]), never "incorrect PIN". On success the row
     * handed back is the refreshed row of the same list token (the verify's own refresh never
     * makes the select that follows stale), or the displayed row if the list moved on.
     */
    suspend fun verifyPin(row: DisplayedProfile, pin: String): PinCheck {
        if (!IdentityGate.holdsForSelection(row.listToken)) return PinCheck(null, null)
        val result = verifyPinUnder(row.profile.profileIndex, pin, row.listToken) ?: return PinCheck(null, null)
        if (!result.unlocked) return PinCheck(result, null)
        // Review r7: the check authorises the row it verified and nothing else. A replaced row (another
        // id in the slot), a changed lock or another list: refused; the picker shows the current row.
        if (rowRejection(row.profile, row.listToken) != null) return PinCheck(null, null)
        val refreshed = _state.value.displayedRow(row.profile.profileIndex)?.takeIf { it.listToken == row.listToken } ?: row
        return PinCheck(result, refreshed)
    }

    /** [token] null: the legacy (composeApp) call, unbound; else the RPC is read-only-bound to it. null: refused. */
    private suspend fun verifyPinUnder(profileIndex: Int, pin: String, token: AccountToken?): PinVerifyResult? {
        verifyRpcForTest?.let { rpc ->
            val result = AuthRepository.dispatchUnderSession(token, "verifyPin", readOnly = true) { rpc(profileIndex, pin) } ?: return null
            if (result.unlocked) rememberVerifiedPinUnder(token, profileIndex, pin)
            return result
        }
        if (AuthRepository.state.value !is AuthState.Authenticated) {
            return verifyPinLocally(profileIndex, pin)
        }

        return runCatching {
            val params = buildJsonObject {
                put("p_profile_id", profileIndex)
                put("p_pin", pin)
            }
            val result = (if (token == null) SupabaseProvider.client.postgrest.rpc("verify_profile_pin", params)
            else AuthRepository.dispatchUnderSession(token, "verifyPin", readOnly = true) {
                SupabaseProvider.client.postgrest.rpc("verify_profile_pin", params)
            }) ?: return null
            result.decodeSingle<PinVerifyResult>().also { verifyResult ->
                if (verifyResult.unlocked) {
                    // Upstream 5327166f: refresh the cached profile before remembering the PIN so
                    // a server-side profile change since the last pull isn't cached against.
                    pullProfiles()
                    rememberVerifiedPinUnder(token, profileIndex, pin)
                }
            }
        }.getOrElse { e ->
            log.e(e) { "Failed to verify pin" }
            verifyPinLocally(profileIndex, pin)
        }
    }

    /**
     * Audit #6: the offline PIN cache (keyed by slot only, as at base; the account wipe clears it,
     * AccountDataStores "ProfilePinCacheStorage") is written only while [token] is the current
     * account token and the list in memory is that token's, inside its commit section.
     */
    private fun rememberVerifiedPinUnder(token: AccountToken?, profileIndex: Int, pin: String) {
        if (token == null) {
            rememberVerifiedPin(profileIndex = profileIndex, pin = pin)
            return
        }
        IdentityGate.commitAccount(token, "rememberPin") {
            if (_state.value.listToken == token) rememberVerifiedPin(profileIndex = profileIndex, pin = pin)
        }
    }

    suspend fun setPin(profileIndex: Int, pin: String, currentPin: String? = null): PinVerifyResult = setPinUnder(profileIndex, pin, currentPin, null)

    /** Fork (W2 review r6 #1): the displayed row, under the token of its list. */
    suspend fun setPin(row: DisplayedProfile, pin: String, currentPin: String? = null): PinVerifyResult =
        if (row.listToken == null) PinVerifyResult(unlocked = false) else setPinUnder(row.profile.profileIndex, pin, currentPin, row.listToken, row.profile)

    private suspend fun setPinUnder(profileIndex: Int, pin: String, currentPin: String?, token: AccountToken?, displayed: NuvioProfile? = null): PinVerifyResult {
        if (AuthRepository.state.value !is AuthState.Authenticated) {
            return PinVerifyResult(unlocked = false, message = resourceString("Connect to the internet to set a PIN.", StringKey.profile_pin_set_requires_internet))
        }

        return runCatching {
            val params = buildJsonObject {
                put("p_profile_id", profileIndex)
                put("p_pin", pin)
                currentPin?.let { put("p_current_pin", it) }
            }
            // Audit #2: refused (the identity moved): the existing failure message, never "Incorrect PIN".
            rpcBound(token, "setPin", displayed) { SupabaseProvider.client.postgrest.rpc("set_profile_pin", params) }
                ?: return PinVerifyResult(unlocked = false, message = resourceString("Couldn't set PIN. Try again.", StringKey.profile_pin_set_failed))
            pullProfiles()
            rememberVerifiedPinUnder(token, profileIndex, pin)
            PinVerifyResult(unlocked = true)
        }.onFailure { e ->
            log.e(e) { "Failed to set pin" }
        }.getOrElse {
            PinVerifyResult(unlocked = false, message = resourceString("Couldn't set PIN. Try again.", StringKey.profile_pin_set_failed))
        }
    }

    suspend fun clearPin(profileIndex: Int, currentPin: String? = null): PinVerifyResult = clearPinUnder(profileIndex, currentPin, null)

    /** Fork (W2 review r6 #1): the displayed row, under the token of its list. */
    suspend fun clearPin(row: DisplayedProfile, currentPin: String? = null): PinVerifyResult =
        if (row.listToken == null) PinVerifyResult(unlocked = false) else clearPinUnder(row.profile.profileIndex, currentPin, row.listToken, row.profile)

    private suspend fun clearPinUnder(profileIndex: Int, currentPin: String?, token: AccountToken?, displayed: NuvioProfile? = null): PinVerifyResult {
        if (AuthRepository.state.value !is AuthState.Authenticated) {
            return PinVerifyResult(unlocked = false, message = resourceString("Connect to the internet to remove the PIN lock.", StringKey.profile_pin_clear_requires_internet))
        }

        return runCatching {
            val params = buildJsonObject {
                put("p_profile_id", profileIndex)
                currentPin?.let { put("p_current_pin", it) }
            }
            // Audit #2: refused (the identity moved): the existing failure message, never "Incorrect PIN".
            rpcBound(token, "clearPin", displayed) { SupabaseProvider.client.postgrest.rpc("clear_profile_pin", params) }
                ?: return PinVerifyResult(unlocked = false, message = resourceString("Couldn't remove PIN lock. Try again.", StringKey.profile_pin_clear_failed))
            pullProfiles()
            ProfilePinCacheStorage.removePayload(profileIndex)
            PinVerifyResult(unlocked = true)
        }.onFailure { e ->
            log.e(e) { "Failed to clear pin" }
        }.getOrElse {
            PinVerifyResult(unlocked = false, message = resourceString("Couldn't remove PIN lock. Try again.", StringKey.profile_pin_clear_failed))
        }
    }

    suspend fun clearPinWithPassword(profileIndex: Int, accountPassword: String) {
        runCatching {
            val params = buildJsonObject {
                put("p_account_password", accountPassword)
                put("p_profile_id", profileIndex)
            }
            SupabaseProvider.client.postgrest.rpc("clear_profile_pin_with_account_password", params)
            pullProfiles()
            ProfilePinCacheStorage.removePayload(profileIndex)
        }.onFailure { e ->
            log.e(e) { "Failed to clear pin with password" }
        }
    }

    suspend fun pullProfileLocks(): List<ProfileLockState> {
        return runCatching {
            val result = SupabaseProvider.client.postgrest.rpc("sync_pull_profile_locks")
            result.decodeList<ProfileLockState>()
        }.getOrElse { e ->
            log.e(e) { "Failed to pull profile locks" }
            emptyList()
        }
    }

    /** [token] null: unbound legacy call; else [call] only under the held session while [token] holds (null result: refused). */
    /** [displayed] non-null: the row rule runs inside the dispatch section, before the RPC (review r7). */
    private suspend fun <T> rpcBound(token: AccountToken?, site: String, displayed: NuvioProfile? = null, call: suspend () -> T): T? =
        if (token == null) call() else AuthRepository.dispatchUnderSession(token, site) {
            if (displayed != null && rowRejection(displayed, token) != null) null else call()
        }

    private fun applyPayloadsLocally(payloads: List<ProfilePushPayload>, token: AccountToken?) {
        val authState = AuthRepository.state.value as? AuthState.Authenticated ?: return
        val profiles = payloads.map { p ->
            NuvioProfile(
                id = "",
                userId = authState.userId,
                profileIndex = p.profileIndex,
                name = p.name,
                avatarColorHex = p.avatarColorHex,
                avatarId = p.avatarId,
                avatarUrl = p.avatarUrl,
                usesPrimaryAddons = p.usesPrimaryAddons,
                usesPrimaryPlugins = p.usesPrimaryPlugins,
            )
        }.sortedBy { it.profileIndex }
        _state.update { s -> s.copy(
            profiles = profiles,
            isLoaded = true,
            activeProfile = profiles.find { it.profileIndex == activeProfileIndex }
                ?: ProfileIdentityRouterProvider.router.onActiveSlotMissing(activeProfileIndex, profiles, IdentityGate.currentAccountToken()),
            listToken = token,
        ) }
        if (_state.value.activeProfile != null) {
            activeProfileIndex = _state.value.activeProfile!!.profileIndex
        }
        syncPinCache(profiles)
        persist()
    }

    private fun decodeStoredPayload(): StoredProfilePayload? {
        val payload = ProfileStorage.loadPayload().orEmpty().trim()
        if (payload.isEmpty()) return null

        return runCatching {
            json.decodeFromString<StoredProfilePayload>(payload)
        }.getOrNull()
    }

    private fun applyStoredPayload(stored: StoredProfilePayload) {
        val profiles = stored.profiles.sortedBy { it.profileIndex }
        activeProfileIndex = stored.activeProfileIndex
        _state.value = ProfileState(
            profiles = profiles,
            activeProfile = profiles.find { it.profileIndex == activeProfileIndex } ?: profiles.firstOrNull(),
            isLoaded = profiles.isNotEmpty(),
            hasEverSelectedProfile = stored.hasEverSelectedProfile,
            rememberLastProfileEnabled = stored.rememberLastProfileEnabled,
        )
        _state.value.activeProfile?.let { activeProfileIndex = it.profileIndex }
        syncPinCache(profiles)
    }

    private fun rememberVerifiedPin(profileIndex: Int, pin: String) {
        val profile = _state.value.profiles.find { it.profileIndex == profileIndex }
        val salt = generateProfilePinSalt()
        val payload = CachedProfilePinPayload(
            salt = salt,
            digest = hashProfilePin(profileIndex = profileIndex, salt = salt, pin = pin),
            profileUpdatedAt = profile?.updatedAt.orEmpty(),
        )
        ProfilePinCacheStorage.savePayload(profileIndex, json.encodeToString(payload))
    }

    private fun verifyPinLocally(profileIndex: Int, pin: String): PinVerifyResult {
        val profile = _state.value.profiles.find { it.profileIndex == profileIndex }
        if (profile?.pinEnabled != true) {
            return PinVerifyResult(unlocked = true)
        }

        val payload = ProfilePinCacheStorage.loadPayload(profileIndex).orEmpty().trim()
        if (payload.isEmpty()) {
            return PinVerifyResult(
                unlocked = false,
                message = resourceString("This PIN can't be verified offline on this device yet. Connect once and unlock it online first.", StringKey.profile_pin_offline_verification_requires_online),
            )
        }

        val cached = runCatching {
            json.decodeFromString<CachedProfilePinPayload>(payload)
        }.getOrNull() ?: return PinVerifyResult(
            unlocked = false,
            message = resourceString("This PIN can't be verified offline on this device yet. Connect once and unlock it online first.", StringKey.profile_pin_offline_verification_requires_online),
        )

        if (
            cached.profileUpdatedAt.isNotBlank() &&
            profile.updatedAt.isNotBlank() &&
            cached.profileUpdatedAt != profile.updatedAt
        ) {
            ProfilePinCacheStorage.removePayload(profileIndex)
            return PinVerifyResult(
                unlocked = false,
                message = resourceString("This profile PIN changed. Connect once to refresh the lock on this device.", StringKey.profile_pin_changed_requires_refresh),
            )
        }

        val digest = hashProfilePin(profileIndex = profileIndex, salt = cached.salt, pin = pin)
        return if (digest == cached.digest) {
            PinVerifyResult(unlocked = true)
        } else {
            PinVerifyResult(unlocked = false, message = resourceString("Incorrect PIN", StringKey.pin_incorrect))
        }
    }

    private fun syncPinCache(profiles: List<NuvioProfile>) {
        val profilesByIndex = profiles.associateBy { it.profileIndex }
        for (profileIndex in 1..MAX_PROFILES) {
            val profile = profilesByIndex[profileIndex]
            if (profile == null || !profile.pinEnabled) {
                ProfilePinCacheStorage.removePayload(profileIndex)
                continue
            }

            val raw = ProfilePinCacheStorage.loadPayload(profileIndex).orEmpty().trim()
            if (raw.isEmpty()) continue

            val cached = runCatching {
                json.decodeFromString<CachedProfilePinPayload>(raw)
            }.getOrNull() ?: run {
                ProfilePinCacheStorage.removePayload(profileIndex)
                continue
            }

            if (
                cached.profileUpdatedAt.isNotBlank() &&
                profile.updatedAt.isNotBlank() &&
                cached.profileUpdatedAt != profile.updatedAt
            ) {
                ProfilePinCacheStorage.removePayload(profileIndex)
            }
        }
    }

    /** Tests only: puts a list (with its token) in memory. */
    internal fun setStateForTest(state: ProfileState) {
        _state.value = state
    }

    /** Tests only: a list in memory loaded for [owner] (what ensureLoaded records). */
    internal fun setStateForTest(state: ProfileState, owner: String?) {
        loadedCacheForUserId = owner
        _state.value = state
    }

    private fun persist() {
        val authState = AuthRepository.state.value as? AuthState.Authenticated ?: return
        val state = _state.value
        ProfileStorage.savePayload(
            json.encodeToString(
                StoredProfilePayload(
                    userId = authState.userId,
                    activeProfileIndex = activeProfileIndex,
                    hasEverSelectedProfile = state.hasEverSelectedProfile,
                    rememberLastProfileEnabled = state.rememberLastProfileEnabled,
                    profiles = state.profiles,
                ),
            ),
        )
    }
}

@kotlinx.serialization.Serializable
data class ProfileLockState(
    @kotlinx.serialization.SerialName("profile_index") val profileIndex: Int,
    @kotlinx.serialization.SerialName("pin_enabled") val pinEnabled: Boolean = false,
    @kotlinx.serialization.SerialName("pin_locked_until") val pinLockedUntil: String? = null,
)
