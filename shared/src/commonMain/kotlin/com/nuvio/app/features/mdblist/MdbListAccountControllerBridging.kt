package com.nuvio.app.features.mdblist

import kotlinx.coroutines.CancellationException

/*
 * Fork-only Swift bridging for the tvOS MDBList account card (MdbListAccountController.kt is the
 * verbatim upstream port and stays untouched). Kotlin extensions on a Kotlin class export to
 * Objective-C as a category, so Swift calls these as methods:
 * `try await MdbListTracker.shared.account.connectChecked()`.
 *
 * Why twins at all: a Kotlin exception crossing into Swift from a function WITHOUT `@Throws`
 * aborts the process (see `TmdbMetadataService.fetchPreviewEnrichmentChecked`), and the
 * controller's scope checks throw `CancellationException` whenever the account changed under the
 * caller (profile switch, a connect/disconnect that already bumped the generation). Every twin
 * acts on the store's CURRENT scope — the ObjC export drops Kotlin default arguments, so Swift
 * could not pass one anyway.
 */

/**
 * Starts (or resumes a still-valid) device authorization and begins polling in the background.
 * Returns the verification URL (for the QR code), or null when already connected or when the
 * start failed — the failure is published on [MdbListAccountController.status] /
 * [MdbListTracker.accountUiState]. Throws only when the account changed mid-call.
 */
@Throws(Throwable::class)
suspend fun MdbListAccountController.connectChecked(): String? = connect()

/**
 * Revokes the tokens and clears this profile's MDBList account. A failed revoke still disconnects
 * locally and surfaces as `revokeFailed`. Throws only when the account changed mid-call.
 */
@Throws(Throwable::class)
suspend fun MdbListAccountController.disconnectChecked() {
    disconnect()
}

/**
 * Restarts polling for a pending device authorization (e.g. the card reappeared, or the app came
 * back to the foreground). Returns the verification URL, or null when nothing is pending or the
 * account changed. Never throws.
 */
fun MdbListAccountController.resumePollingSafely(): String? = try {
    resumePolling()
} catch (_: CancellationException) {
    null
}

/**
 * Abandons a pending device authorization. Returns false (and does nothing) if the account
 * changed before the call landed. Never throws.
 */
fun MdbListAccountController.cancelSafely(): Boolean = try {
    cancel()
    true
} catch (_: CancellationException) {
    false
}

/**
 * Re-reads the connected account's MDBList user (username, supporter flag, rate limits) into the
 * store, which republishes [MdbListTracker.accountUiState]. Throws on network/auth failure or when
 * the account changed mid-call.
 */
@Throws(Throwable::class)
suspend fun MdbListTracker.refreshUserChecked(): MdbListUser = api.refreshUser()
