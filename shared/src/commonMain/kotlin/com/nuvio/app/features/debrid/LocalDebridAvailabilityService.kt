package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.AddonStreamGroup
import com.nuvio.app.features.streams.StreamDebridCacheState
import com.nuvio.app.features.streams.StreamDebridCacheStatus
import com.nuvio.app.features.streams.StreamItem

object LocalDebridAvailabilityService {
    fun hasPendingCacheCheck(
        groups: List<AddonStreamGroup>,
        eligibleGroupIds: Set<String>? = null,
    ): Boolean {
        cacheCheckAccount() ?: return false
        return groups
            .filter { group -> eligibleGroupIds == null || group.addonId in eligibleGroupIds }
            .any { group ->
                group.streams.any { stream ->
                    stream.localAvailabilityHash() != null &&
                        stream.debridCacheStatus?.state !in FINAL_CACHE_STATES
                }
            }
    }

    fun markChecking(
        groups: List<AddonStreamGroup>,
        eligibleGroupIds: Set<String>? = null,
    ): List<AddonStreamGroup> {
        val account = cacheCheckAccount() ?: return groups
        return groups.updateAvailabilityStatus(eligibleGroupIds) { stream ->
            if (stream.localAvailabilityHash() == null || stream.debridCacheStatus?.state == StreamDebridCacheState.CACHED) {
                stream
            } else {
                stream.copy(
                    debridCacheStatus = StreamDebridCacheStatus(
                        providerId = account.provider.id,
                        providerName = account.provider.displayName,
                        state = StreamDebridCacheState.CHECKING,
                    ),
                )
            }
        }
    }

    suspend fun annotateCachedAvailability(
        groups: List<AddonStreamGroup>,
        eligibleGroupIds: Set<String>? = null,
    ): List<AddonStreamGroup> {
        val account = cacheCheckAccount() ?: return groups
        val hashes = groups
            .filter { group -> eligibleGroupIds == null || group.addonId in eligibleGroupIds }
            .flatMap { group ->
                group.streams.mapNotNull { stream ->
                    stream.localAvailabilityHash()
                        ?.takeUnless { stream.debridCacheStatus?.state in FINAL_CACHE_STATES }
                }
            }
            .distinct()
        if (hashes.isEmpty()) return groups

        val cached = LocalDebridService.checkCached(account = account, hashes = hashes)
            ?: return groups.updateAvailabilityStatus(eligibleGroupIds) { stream ->
                val hash = stream.localAvailabilityHash()
                if (hash == null) {
                    stream
                } else {
                    stream.copy(
                        debridCacheStatus = StreamDebridCacheStatus(
                            providerId = account.provider.id,
                            providerName = account.provider.displayName,
                            state = StreamDebridCacheState.UNKNOWN,
                        ),
                    )
                }
            }

        return groups.updateAvailabilityStatus(eligibleGroupIds) { stream ->
            val hash = stream.localAvailabilityHash() ?: return@updateAvailabilityStatus stream
            if (stream.debridCacheStatus?.state in FINAL_CACHE_STATES) return@updateAvailabilityStatus stream
            val cachedItem = cached.cached[hash]
            stream.copy(
                debridCacheStatus = StreamDebridCacheStatus(
                    providerId = account.provider.id,
                    providerName = account.provider.displayName,
                    // UNKNOWN (a failed alias re-ask) is not final: the resolver re-checks it.
                    state = cached.stateFor(hash),
                    cachedName = cachedItem?.name,
                    cachedSize = cachedItem?.size,
                ),
            )
        }
    }

    suspend fun isCached(hash: String): Boolean? {
        val account = cacheCheckAccount() ?: return null
        return LocalDebridService.isCached(account, hash)
    }

    /**
     * Identifies the account used for cache checks, without the raw key, so a source search
     * checked with another account or none is not reused (upstream 4c414a5f4). "none" whenever
     * playable links are off or the active resolver has no local cache check.
     */
    fun cacheCheckConfiguration(): String =
        cacheCheckAccount()?.let { account -> "${account.provider.id}:${account.apiKey.hashCode()}" } ?: "none"

    private fun cacheCheckAccount(): DebridServiceCredential? {
        val settings = DebridSettingsRepository.snapshot()
        if (!settings.canResolvePlayableLinks) return null
        return settings.activeResolverCredential
            ?.takeIf { credential -> credential.provider.supports(DebridProviderCapability.LocalTorrentCacheCheck) }
    }
}

private val FINAL_CACHE_STATES = setOf(
    StreamDebridCacheState.CACHED,
    StreamDebridCacheState.NOT_CACHED,
)

fun StreamItem.localAvailabilityHash(): String? =
    infoHash
        ?.trim()
        ?.lowercase()
        ?.takeIf { isInstalledAddonStream && needsLocalDebridResolve && it.isNotBlank() }

private fun List<AddonStreamGroup>.updateAvailabilityStatus(
    eligibleGroupIds: Set<String>?,
    transform: (StreamItem) -> StreamItem,
): List<AddonStreamGroup> =
    map { group ->
        if (eligibleGroupIds != null && group.addonId !in eligibleGroupIds) return@map group
        var changed = false
        val updatedStreams = group.streams.map { stream ->
            val updated = transform(stream)
            if (updated != stream) changed = true
            updated
        }
        if (changed) group.copy(streams = updatedStreams) else group
    }
