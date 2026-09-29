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
    const val TMDB = "tmdb"
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

    /**
     * Fork: re-applies locally-pending credential edits over a merged snapshot.
     *
     * Upstream 1854dfc3 removed the push-before-pull retry, which also removed the only thing that
     * carried an edit whose observer push FAILED across the next pull: [mergeRemote] would restore
     * the server's older value and the sync bookkeeping would baseline it, silently losing the
     * edit (and resurrecting a credential the user had cleared offline). `ProviderCredentialSync`
     * records those edits per provider and overlays them here, so the local edit wins over the
     * value the pull returned and can then be pushed on its own.
     *
     * [pending] is provider id → value, where `""` is a pending CLEAR. Providers this snapshot
     * does not carry are ignored. The tie-break is deliberately "local unpushed edit wins": the
     * alternative (server wins) is exactly the data loss this exists to stop.
     */
    fun overlayingPendingEdits(pending: Map<String, String>): ProviderCredentialSnapshot {
        if (pending.isEmpty()) return this
        return copy(
            values = values.map { local ->
                val edit = pending[local.provider] ?: return@map local
                if (edit == local.value) local else local.copy(value = edit)
            },
        )
    }

    /** Fork: the same snapshot narrowed to [providers] — the payload shape for a pending-only push. */
    fun restrictedTo(providers: Set<String>): ProviderCredentialSnapshot =
        copy(values = values.filter { it.provider in providers })

    /**
     * Fork: provider ids whose value differs from [other]'s. A provider [other] does not carry
     * counts as differing.
     *
     * `ProviderCredentialSync` uses this to spot credential edits the user made WHILE a pull was
     * in flight: the merged snapshot is composed against the local state as it was BEFORE the
     * pull suspended, so without this check the apply would write the server's value back over an
     * edit that is seconds old. Deliberately a whole-value diff — no per-field revisions.
     */
    fun providersDifferingFrom(other: ProviderCredentialSnapshot): Set<String> {
        val theirs = other.values.associate { it.provider to it.value }
        return values
            .filterNot { theirs[it.provider] == it.value }
            .mapTo(mutableSetOf()) { it.provider }
    }

    /**
     * Fork: this snapshot with the values for [providers] taken from [from] instead. Providers
     * outside [providers], and providers [from] does not carry, are left alone.
     *
     * Used for the sync BASELINE after a replay push FAILED. The baseline is what the server is
     * believed to hold, which stops being the locally applied state the moment a push does not
     * land: baseline the local value there and the observer's own guard swallows the retry — a
     * later B -> C -> B compares equal to the baseline and returns without pushing, so the server
     * keeps its old value with nothing left to correct it.
     */
    fun replacingValues(from: ProviderCredentialSnapshot, providers: Set<String>): ProviderCredentialSnapshot {
        if (providers.isEmpty()) return this
        val source = from.values.associate { it.provider to it.value }
        return copy(
            values = values.map { local ->
                if (local.provider !in providers) return@map local
                val replacement = source[local.provider] ?: return@map local
                if (replacement == local.value) local else local.copy(value = replacement)
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
