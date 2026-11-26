package com.nuvio.app.core.auth

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

import co.touchlab.kermit.Logger
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.account.AccountDataCleanerProvider
import com.nuvio.app.core.identity.IdentityBarrier
import com.nuvio.app.core.identity.IdentityImmediate
import com.nuvio.app.core.identity.TransitionKind
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.functions.functions
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

private const val KEY_SIGNED_OUT_NOTICE = AuthMarkerKeys.SIGNED_OUT_NOTICE
private const val SIGNED_OUT_NOTICE_FALLBACK = "You have been signed out of Nuvio. Please sign in again."

/**
 * The app's auth surface. Every session decision lives in the pure reducer (AuthSessionModel); the
 * driver (AuthSessionDriver) feeds it events under one lane and runs its outputs against
 * [RealAuthEffects] below. Each public function here only brackets one library call with its
 * events. Design: docs/batch-upstream-ports-spec-auth.md.
 */
object AuthRepository {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("AuthRepository"))
    private val log = Logger.withTag("AuthRepository")

    private val _state = MutableStateFlow<AuthState>(AuthState.Loading)
    val state: StateFlow<AuthState> = _state.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    // Fork: the lost-session notice on its own flow, so the tvOS Welcome screen can show it without
    // also showing sign-in/sign-out errors. [error] still carries it too (composeApp's AuthScreen,
    // as upstream). Raised only by the model's ShowNotice output; cleared by HideNotice and clearError.
    private val _signedOutNotice = MutableStateFlow<String?>(null)
    val signedOutNotice: StateFlow<String?> = _signedOutNotice.asStateFlow()

    private var initialized = false

    // Created on first use, so touching [state] or [error] (tests, previews) never builds a client.
    private val driver: AuthSessionDriver by lazy { AuthSessionDriver(RealAuthEffects, scope) }

    private fun boot(): AuthEvent.Boot = AuthEvent.Boot(
        guestId = AuthStorage.loadAnonymousUserId(),
        owner = AuthStorage.loadAccountOwner(),
        notice = AuthStorage.loadFlag(KEY_SIGNED_OUT_NOTICE),
        ownerUnknown = !AuthStorage.isAccountOwnerRecorded(),
        wipePending = AuthStorage.loadAccountWipePending(),
    )

    fun initialize() {
        if (initialized) return
        initialized = true
        driver.start(
            boot = boot(),
            status = { SupabaseProvider.client.auth.sessionStatus },
            collectDelay = debugSessionRestoreStall(),
        )
    }

    /**
     * Step 1 of a server switch (see ServerConnectionController.switchServer): drop the current
     * session and every piece of account-scoped local state, BEFORE the new server is saved.
     * Returns failure if any step threw; the controller then aborts the switch.
     *
     * Fork: runs the FULL account-data wipe (same semantics as signOut()). Upstream only clears the
     * session here; on this fork the wipe is what erases per-profile payloads, sync cursors,
     * provider credentials and Trakt/Simkl tokens — nothing from server A may sync into server B.
     */
    internal suspend fun prepareForServerSwitch(): Result<Unit> = withContext(Dispatchers.Default) {
        _error.value = null
        driver.prepareForServerSwitch()
            .onFailure { e -> log.e(e) { "Server-switch preparation did not complete cleanly" } }
    }

    /**
     * Step 3 of a server switch (after SupabaseProvider.reset()): drop the collector and watchdog
     * that captured the previous client and boot again against the new one. Observers of [state]
     * keep working — same StateFlow instance.
     */
    internal suspend fun reinitialize() {
        initialized = true
        driver.restart(
            boot = boot(),
            status = { SupabaseProvider.client.auth.sessionStatus },
            collectDelay = debugSessionRestoreStall(),
        )
    }

    /** Taken BEFORE a request whose failure may be reported with [reportSessionError]. */
    internal fun sessionTicket(): AuthTicket = driver.currentTicket()

    /**
     * A sync request taken under [ticket] failed. Returns true when the report cleared the session
     * (a deleted account): the caller stops. A report about an older session does nothing (I2).
     */
    internal suspend fun reportSessionError(ticket: AuthTicket, error: Throwable, source: String): Boolean {
        val kind = error.sessionErrorKind()
        if (kind != SessionErrorKind.Other) log.w(error) { "$source failed: $kind" }
        return driver.reportSessionError(ticket, kind)
    }

    /** QR sign-in (TvLoginRepository.exchange): imports the approved session under the lane. */
    // Fork (W2, 8.0.5): every Swift-started auth call hops to Default first, so its window bodies run off Main.
    internal suspend fun importTvLoginSession(accessToken: String, refreshToken: String) = withContext(Dispatchers.Default) {
        driver.importTvLoginTokens(accessToken, refreshToken).getOrThrow()
    }

    /** QR sign-in scaffolding: an anonymous library session, started under the lane. */
    internal suspend fun ensureTvLoginScaffold() = withContext(Dispatchers.Default) {
        driver.ensureTvLoginScaffold().getOrThrow()
    }

    @OptIn(ExperimentalUuidApi::class)
    fun signInAnonymously() {
        _error.value = null
        driver.chooseGuest(Uuid.random().toString())
    }

    suspend fun signUpWithEmail(email: String, password: String): Result<Unit> = withContext(Dispatchers.Default) {
        _error.value = null
        driver.signUpWithEmail(email, password).onFailure { e ->
            log.e(e) { "Email sign-up failed" }
            _error.value = e.safeAuthErrorDescription()
                ?: resourceString("Sign-up failed", StringKey.auth_sign_up_failed)
        }
    }

    suspend fun signInWithEmail(email: String, password: String): Result<Unit> = withContext(Dispatchers.Default) {
        _error.value = null
        driver.signInWithEmail(email, password).onFailure { e ->
            log.e(e) { "Email sign-in failed" }
            _error.value = e.safeAuthErrorDescription()
                ?: resourceString("Sign-in failed", StringKey.auth_sign_in_failed)
        }
    }

    // Fork (W2, 5.5): a draining barrier begins before the reset, so the gate closes before the
    // wipe or the gate flip.
    suspend fun signOut(): Result<Unit> = withContext(Dispatchers.Default) {
        _error.value = null
        IdentityBarrier.accountReset(TransitionKind.SignOut) { driver.signOut() }.onFailure { failure ->
            log.e(failure) { "Sign-out did not complete cleanly; all local cleanup steps were attempted" }
            _error.value = failure.message
                ?: resourceString("Sign out failed", StringKey.auth_sign_out_failed)
        }
    }

    suspend fun deleteAccount(): Result<Unit> = withContext(Dispatchers.Default) {
        _error.value = null
        IdentityBarrier.accountReset(TransitionKind.DeleteAccount) { driver.deleteAccount() }.onFailure { e ->
            log.e(e) { "Account deletion failed" }
            _error.value = e.message ?: resourceString("Account deletion failed", StringKey.auth_account_deletion_failed)
        }
    }

    /**
     * Fork (scope identity, W2, rule B): re-publishes the auth state on screen through the identity
     * window, inside the auth lane, and ends the chain. Swift calls it while the barrier is in
     * Recovery(FailedPublish); a successful publish clears it (B18).
     */
    suspend fun retryIdentityRecovery(): Result<Unit> = withContext(Dispatchers.Default) {
        driver.inChain { RealAuthEffects.publish(_state.value) }
            .onFailure { e -> log.e(e) { "Identity recovery retry failed" } }
    }

    fun clearError() {
        _error.value = null
        _signedOutNotice.value = null
    }

    private fun signedOutNoticeText(): String =
        resourceString(SIGNED_OUT_NOTICE_FALLBACK, StringKey.auth_notice_signed_out)

    /** One body per model output (spec 3d and 5d); no decisions here. */
    private object RealAuthEffects : AuthEffects {
        override fun publish(state: AuthState) {
            IdentityImmediate.publishAuth(state) { _state.value = state }
        }

        override fun serialChanging() = IdentityImmediate.serialChanging()

        override fun chainEnded() = IdentityImmediate.chainEnded()

        override fun persistOwner(userId: String?) {
            check(AuthStorage.saveAccountOwner(userId)) { "account owner was not durably written" }
        }

        override fun persistNotice(pending: Boolean) = AuthStorage.saveFlag(KEY_SIGNED_OUT_NOTICE, pending)

        override fun persistWipePending(pending: Boolean) {
            check(AuthStorage.saveAccountWipePending(pending)) { "wipe marker was not durably written" }
        }

        override fun showNotice() {
            val notice = signedOutNoticeText()
            _error.value = notice
            _signedOutNotice.value = notice
        }

        override fun hideNotice() {
            val notice = _signedOutNotice.value
            _signedOutNotice.value = null
            if (notice != null) _error.compareAndSet(notice, null)
        }

        override fun saveGuestId(guestId: String) {
            check(AuthStorage.saveAnonymousUserIdDurably(guestId)) { "guest id was not durably written" }
        }

        // Reports durability so a failed clear reaches the reset's result (round 8).
        override fun clearGuestId() {
            check(AuthStorage.clearAnonymousUserIdDurably()) { "guest id clear was not durably written" }
        }

        // Fork: through the AccountDataCleanerProvider seam (the one AccountDataStores registry).
        override fun wipeAccountData() = IdentityImmediate.accountWipe { AccountDataCleanerProvider.cleaner.wipe() }

        override suspend fun clearSupabaseSession() = SupabaseProvider.client.auth.clearSession()

        override suspend fun kickSessionRefresh() = SupabaseProvider.client.auth.startAutoRefreshForCurrentSession()

        override suspend fun checkUser(accessToken: String): String? =
            SupabaseProvider.client.auth.retrieveUser(accessToken).id.takeIf { it.isNotBlank() }

        override fun log(message: String) = log.i { message }

        // D1b: stdout, so the rig's console stream shows it; debug builds only.
        override fun trace(line: String) {
            if (authSessionTraceEnabled()) println("[AuthSession] $line")
        }

        override suspend fun signInWithEmail(email: String, password: String) {
            SupabaseProvider.client.auth.signInWith(Email) {
                this.email = email
                this.password = password
            }
        }

        override suspend fun signUpWithEmail(email: String, password: String) {
            SupabaseProvider.client.auth.signUpWith(Email) {
                this.email = email
                this.password = password
            }
        }

        override suspend fun signOutRemote() = SupabaseProvider.client.auth.signOut()

        override suspend fun deleteAccountRemote() {
            SupabaseProvider.client.functions.invoke("delete-account")
        }

        override suspend fun importTvLoginTokens(accessToken: String, refreshToken: String) =
            SupabaseProvider.client.auth.importAuthToken(
                accessToken = accessToken,
                refreshToken = refreshToken,
                retrieveUser = true,
                autoRefresh = true,
            )

        override suspend fun ensureTvLoginScaffold() {
            val auth = SupabaseProvider.client.auth
            if (auth.currentUserOrNull() != null && auth.currentAccessTokenOrNull() != null) return
            auth.signInAnonymously()
        }
    }

    private fun Throwable.safeAuthErrorDescription(): String? =
        findCause<AuthRestException>()
            ?.errorDescription
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: findCause<RestException>()
                ?.description
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
}
