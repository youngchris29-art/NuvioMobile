package com.nuvio.app.features.mdblist

// Fork: resource-free replacement for upstream 425e4d8a/db85d968 `MdbListMessages.kt`, which
// resolves Compose Resources (`Res.string.settings_mdblist_*`) that :shared cannot use. Same
// function names and mapping; the text is upstream's English `strings_mdblist.xml` values.
// Not routed through core.i18n.StringProvider: adding StringKeys would require matching entries in
// composeApp's ComposeResourcesStringProvider and strings.xml, which the fork's composeApp does not
// carry for MDBList yet. tvOS is English-only, so plain English is the faithful result there.

internal fun MdbListAuthError.localizedMdbListMessage(): String = when (this) {
    MdbListAuthError.MISSING_CLIENT_ID -> "MDBList connection is unavailable in this build."
    MdbListAuthError.INVALID_RESPONSE -> MDBLIST_INVALID_RESPONSE_MESSAGE
    MdbListAuthError.INSUFFICIENT_SCOPE ->
        "MDBList did not grant permission to update watch history. Reconnect and allow write access."
    MdbListAuthError.CODE_EXPIRED -> "This code has expired. Try again to get a new code."
    MdbListAuthError.ACCESS_DENIED -> "Connection was declined. Try again to connect your account."
    MdbListAuthError.AUTHORIZATION_REVOKED -> MDBLIST_AUTH_REVOKED_MESSAGE
}

internal fun MdbListSyncError.localizedMdbListMessage(): String = when (this) {
    MdbListSyncError.RATE_LIMIT ->
        "MDBList’s request limit has been reached. Syncing will resume after the limit resets."
    MdbListSyncError.AUTHORIZATION_REVOKED -> MDBLIST_AUTH_REVOKED_MESSAGE
    MdbListSyncError.INVALID_RESPONSE -> MDBLIST_INVALID_RESPONSE_MESSAGE
    MdbListSyncError.UNAVAILABLE -> MDBLIST_UNAVAILABLE_MESSAGE
}

internal fun Throwable.localizedMdbListMessage(): String =
    (this as? MdbListAuthException)?.error?.localizedMdbListMessage()
        ?: toMdbListSyncError().localizedMdbListMessage()

private const val MDBLIST_UNAVAILABLE_MESSAGE = "Could not sync with MDBList. Please try again."
private const val MDBLIST_INVALID_RESPONSE_MESSAGE = "MDBList returned an incomplete response. Please try again."
private const val MDBLIST_AUTH_REVOKED_MESSAGE =
    "Your MDBList connection has expired or been revoked. Connect again to resume syncing."
