package com.nuvio.app.core.sync

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

internal const val PROVIDER_API_KEY_FIELD = "api_key"
internal const val PROVIDER_CLIENT_ID_FIELD = "client_id"

internal object ProviderCredentialIds {
    const val MDBLIST = "mdblist"
    const val ANIMESKIP = "animeskip"
    const val INTRODB = "introdb"

    fun debrid(providerId: String): String = "debrid:$providerId"
}

internal data class ProviderCredentialValue(
    val provider: String,
    val field: String,
    val value: String,
) {
    fun credentialJson(): JsonObject = buildJsonObject {
        put(field, value.trim())
    }
}

internal data class ProviderCredentialSnapshot(
    val profileId: Int,
    val values: List<ProviderCredentialValue>,
) {
    init {
        require(values.map(ProviderCredentialValue::provider).distinct().size == values.size)
    }

    /**
     * Applies [rows] over this snapshot. A provider the server does NOT return is CLEARED
     * (upstream 1854dfc3: an automatic pull must propagate a deletion instead of resurrecting the
     * local copy on the next push). The lookup is lowercased on both sides — before the same
     * commit only the remote key was, so a mixed-case local provider id never matched its row.
     *
     * [clearWhenAbsent] lets the caller exempt providers that can never HAVE a remote row —
     * see `ProviderCredentialSync.BACKEND_UNSUPPORTED_PROVIDERS`. Default `{ true }` keeps
     * upstream's behaviour for every other caller (and for the ported upstream tests).
     */
    fun mergeRemote(
        rows: List<SupabaseProviderCredential>,
        clearWhenAbsent: (String) -> Boolean = { true },
    ): ProviderCredentialSnapshot {
        val remoteByProvider = rows.associateBy { it.provider.lowercase() }
        return copy(
            values = values.map { local ->
                val remote = remoteByProvider[local.provider.lowercase()]
                    ?: return@map if (clearWhenAbsent(local.provider)) local.copy(value = "") else local
                val element = remote.credentialJson[local.field] as? JsonPrimitive
                    ?: error("Invalid credential payload for ${local.provider}")
                val value = element.contentOrNull
                    ?: error("Invalid credential value for ${local.provider}")
                local.copy(value = value.trim())
            },
        )
    }
}

// Fork: upstream deleted this with its seed RPC; the fork's legacy-blob seed pipeline still
// gates on it.
internal fun shouldSeedProviderCredentials(
    snapshot: ProviderCredentialSnapshot,
    rows: List<SupabaseProviderCredential>,
): Boolean {
    val remoteProviders = rows.mapTo(mutableSetOf()) { row -> row.provider.lowercase() }
    return snapshot.values.any { credential -> credential.provider.lowercase() !in remoteProviders }
}

@Serializable
internal data class SupabaseProviderCredential(
    val provider: String,
    @SerialName("credential_json") val credentialJson: JsonObject,
    @SerialName("updated_at") val updatedAt: String? = null,
)
