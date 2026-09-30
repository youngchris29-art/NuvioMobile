package com.nuvio.app.features.mdblist

// Fork note: minimal subset of upstream's MdbListSyncState.kt / MdbListSyncModels.kt that the
// auth/account layer depends on. When the sync phase ports those files verbatim, delete the
// matching declarations here (MdbListSyncError, toMdbListSyncError, MdbListDecodingException).

enum class MdbListSyncError { UNAVAILABLE, INVALID_RESPONSE, RATE_LIMIT, AUTHORIZATION_REVOKED }

class MdbListDecodingException : Exception("MDBList returned an incomplete response")

fun Throwable.toMdbListSyncError(): MdbListSyncError = when {
    this is MdbListAuthException -> MdbListSyncError.AUTHORIZATION_REVOKED
    this is MdbListDecodingException -> MdbListSyncError.INVALID_RESPONSE
    this is MdbListApiException && status == 429 -> MdbListSyncError.RATE_LIMIT
    else -> MdbListSyncError.UNAVAILABLE
}
