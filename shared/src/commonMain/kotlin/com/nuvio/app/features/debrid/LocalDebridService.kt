package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamDebridCacheState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

internal data class LocalDebridCachedItem(
    val name: String?,
    val size: Long?,
)

/**
 * One cache-check answer. [cached] holds confirmed hits; a requested hash in [unknown] could not be
 * checked (its follow-up lookup failed), so it is neither a hit nor a confirmed miss. Every other
 * requested hash is a confirmed miss.
 */
internal data class LocalDebridCacheCheck(
    val cached: Map<String, LocalDebridCachedItem>,
    val unknown: Set<String> = emptySet(),
) {
    fun stateFor(hash: String): StreamDebridCacheState =
        when {
            hash in cached -> StreamDebridCacheState.CACHED
            hash in unknown -> StreamDebridCacheState.UNKNOWN
            else -> StreamDebridCacheState.NOT_CACHED
        }

    fun isCached(hash: String): Boolean? =
        when (stateFor(hash)) {
            StreamDebridCacheState.CACHED -> true
            StreamDebridCacheState.NOT_CACHED -> false
            else -> null
        }
}

internal object LocalDebridService {
    suspend fun checkCached(
        account: DebridServiceCredential,
        hashes: List<String>,
    ): LocalDebridCacheCheck? =
        when (account.provider.id) {
            DebridProviders.TORBOX_ID -> checkTorboxCached(account.apiKey, hashes)
            DebridProviders.PREMIUMIZE_ID -> checkPremiumizeCached(account.apiKey, hashes)?.let { LocalDebridCacheCheck(it) }
            else -> null
        }

    suspend fun isCached(account: DebridServiceCredential, hash: String): Boolean? {
        val normalizedHash = hash.trim().lowercase().takeIf { it.isNotBlank() } ?: return null
        return checkCached(account, listOf(normalizedHash))?.isCached(normalizedHash)
    }

    private suspend fun checkTorboxCached(
        apiKey: String,
        hashes: List<String>,
    ): LocalDebridCacheCheck? {
        val normalizedHashes = hashes
            .map { it.trim().lowercase() }
            .filter { it.isNotBlank() }
            .distinct()
        if (normalizedHashes.isEmpty()) return LocalDebridCacheCheck(emptyMap())
        val cached = requestTorboxCached(apiKey, normalizedHashes) ?: return null
        return resolveTorboxAliasMatches(cached, normalizedHashes) { hash ->
            requestTorboxCached(apiKey, listOf(hash))
        }
    }

    private suspend fun requestTorboxCached(
        apiKey: String,
        hashes: List<String>,
    ): Map<String, LocalDebridCachedItem>? =
        try {
            val response = TorboxApiClient.checkCached(apiKey = apiKey, hashes = hashes)
            // BUG-21: a dead token fails this check silently (rows fall back to UNKNOWN), so a
            // definitive auth status is the one place the UI can learn the credential is gone.
            DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, response.status)
            if (!response.isSuccessful) null else parseTorboxCachedAnswer(response.rawBody)
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            null
        }

    private suspend fun checkPremiumizeCached(
        apiKey: String,
        hashes: List<String>,
    ): Map<String, LocalDebridCachedItem>? =
        try {
            val normalizedHashes = hashes
                .map { it.trim().lowercase() }
                .filter { it.isNotBlank() }
                .distinct()
            if (normalizedHashes.isEmpty()) return emptyMap()
            val sources = normalizedHashes.map { hash -> "magnet:?xt=urn:btih:$hash" }
            val response = PremiumizeApiClient.checkCache(apiKey = apiKey, items = sources)
            DebridCredentialHealth.recordHttpStatus(DebridProviders.PREMIUMIZE_ID, response.status)
            val body = response.body
            if (!response.isSuccessful || body?.status.equals("error", ignoreCase = true)) {
                null
            } else {
                normalizedHashes.mapIndexedNotNull { index, hash ->
                    if (body?.response?.getOrNull(index) != true) return@mapIndexedNotNull null
                    hash to LocalDebridCachedItem(
                        name = body.filename?.getOrNull(index),
                        size = body.filesize?.getOrNull(index)?.asLongOrNull(),
                    )
                }.toMap()
            }
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            null
        }
}

/**
 * Decodes a 2xx TorBox `checkcached` body. `null` means the answer could not be read (blank or
 * invalid JSON, no envelope object, `success: false`, a `data` of an unexpected shape or with an
 * entry that is not an item object): a failed
 * lookup, never a confirmed miss. A readable envelope whose `data` is null, `{}` or `[]` is a valid
 * "none of these are cached" answer and yields an empty map.
 */
internal fun parseTorboxCachedAnswer(rawBody: String): Map<String, LocalDebridCachedItem>? {
    if (rawBody.isBlank()) return null
    val envelope = try {
        DebridApiJson.json.parseToJsonElement(rawBody)
    } catch (_: Exception) {
        return null
    } as? JsonObject ?: return null
    if ((envelope["success"] as? JsonPrimitive)?.booleanOrNull == false) return null
    return when (val data = envelope["data"]) {
        null, JsonNull -> emptyMap()
        // format=object: { "<hash>": { name, size, ... } }
        // Any value that is not an item object makes the whole answer unreadable.
        is JsonObject -> buildMap {
            for ((hash, value) in data) {
                if (value !is JsonObject) return null
                put(hash.lowercase(), value.toCachedItem())
            }
        }
        // A list-shaped answer: [ { hash, name, size, ... } ]
        is JsonArray -> buildMap {
            for (entry in data) {
                val hash = ((entry as? JsonObject)?.get("hash") as? JsonPrimitive)?.contentOrNull
                    ?.trim()?.lowercase()?.takeIf { it.isNotBlank() }
                    ?: return null
                put(hash, entry.toCachedItem())
            }
        }
        else -> null
    }
}

private fun JsonElement.toCachedItem(): LocalDebridCachedItem {
    val item = this as? JsonObject
    return LocalDebridCachedItem(
        name = (item?.get("name") as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull,
        size = item?.get("size").asLongOrNull(),
    )
}

private fun kotlinx.serialization.json.JsonElement?.asLongOrNull(): Long? {
    val primitive = this as? JsonPrimitive ?: return null
    return primitive.longOrNull ?: primitive.content.toLongOrNull()
}

/**
 * TorBox matches hashes through its alternative-hash index and answers with the
 * canonical hash as key, so an alias hit would otherwise read as a cache miss.
 *
 * [fetchCached] re-asks one hash; `null` or a throw means that lookup failed (HTTP error,
 * 429, timeout), and the hash is reported as unknown rather than as a confirmed miss, so
 * the resolver re-checks it at play time. An empty answer is a confirmed miss.
 */
internal suspend fun resolveTorboxAliasMatches(
    cached: Map<String, LocalDebridCachedItem>,
    requestedHashes: List<String>,
    fetchCached: suspend (String) -> Map<String, LocalDebridCachedItem>?,
): LocalDebridCacheCheck {
    if (cached.keys.all { it in requestedHashes }) return LocalDebridCacheCheck(cached)
    // One requested hash: every returned entry can only be its match.
    if (requestedHashes.size == 1) {
        val item = cached.values.firstOrNull() ?: return LocalDebridCacheCheck(cached)
        return LocalDebridCacheCheck(mapOf(requestedHashes.single() to item))
    }
    val resolved = cached.toMutableMap()
    val unknown = mutableSetOf<String>()
    val matches = coroutineScope {
        requestedHashes
            .filter { it !in resolved }
            .map { hash ->
                async {
                    val answer = try {
                        fetchCached(hash)
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                        null
                    }
                    hash to answer
                }
            }
            .awaitAll()
    }
    matches.forEach { (hash, answer) ->
        when {
            answer == null -> unknown += hash
            else -> answer.values.firstOrNull()?.let { resolved[hash] = it }
        }
    }
    return LocalDebridCacheCheck(resolved, unknown)
}
