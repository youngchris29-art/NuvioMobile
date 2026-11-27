package com.nuvio.app.features.profiles

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

const val MAX_PROFILES = 6

@Serializable
data class NuvioProfile(
    val id: String = "",
    @SerialName("user_id") val userId: String = "",
    @SerialName("profile_index") val profileIndex: Int = 1,
    val name: String = "",
    @SerialName("avatar_color_hex") val avatarColorHex: String = "#1E88E5",
    @SerialName("avatar_id") val avatarId: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    @SerialName("uses_primary_addons") val usesPrimaryAddons: Boolean = false,
    @SerialName("uses_primary_plugins") val usesPrimaryPlugins: Boolean = false,
    @SerialName("pin_enabled") val pinEnabled: Boolean = false,
    @SerialName("pin_locked_until") val pinLockedUntil: String? = null,
    @SerialName("created_at") val createdAt: String = "",
    @SerialName("updated_at") val updatedAt: String = "",
)

@Serializable
data class ProfilePushPayload(
    @SerialName("profile_index") val profileIndex: Int,
    val name: String,
    @SerialName("avatar_color_hex") val avatarColorHex: String,
    @SerialName("uses_primary_addons") val usesPrimaryAddons: Boolean = false,
    @SerialName("uses_primary_plugins") val usesPrimaryPlugins: Boolean = false,
    @SerialName("avatar_id") val avatarId: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
)

@Serializable
data class PinVerifyResult(
    val unlocked: Boolean = false,
    @SerialName("retry_after_seconds") val retryAfterSeconds: Int = 0,
    val message: String? = null,
)

data class ProfileState(
    val profiles: List<NuvioProfile> = emptyList(),
    val activeProfile: NuvioProfile? = null,
    val isLoaded: Boolean = false,
    val hasEverSelectedProfile: Boolean = false,
    val rememberLastProfileEnabled: Boolean = false,
    /**
     * Fork (scope identity W2, review r5): the account token this list belongs to, stamped where
     * the list is published (the account hook, a pull, a guest edit). A picker row carries it into
     * its SelectRequest, so a row of A's list can never be admitted under B. Null: not stamped.
     */
    val listToken: com.nuvio.app.core.identity.AccountToken? = null,
) {
    /**
     * Fork (W2 review r6 #1/#4): the displayed snapshot's rows, each bound to this list's token.
     * The only thing tvOS renders from and the only thing a row action takes; a row cannot exist
     * without the token of the list it came from (the constructor is internal).
     */
    val displayed: List<DisplayedProfile> get() = profiles.map { DisplayedProfile(it, listToken) }

    /** The displayed row of [slot] in this snapshot, if listed. */
    fun displayedRow(slot: Int): DisplayedProfile? = profiles.firstOrNull { it.profileIndex == slot }?.let { DisplayedProfile(it, listToken) }
}

/**
 * Fork (W2 review r6): a profile row as displayed, with the account token of the list it belongs to.
 * Row identity at admission is the full row (every field, so an empty `updatedAt` cannot make two
 * different rows look alike) plus that token.
 */
class DisplayedProfile internal constructor(
    val profile: NuvioProfile,
    val listToken: com.nuvio.app.core.identity.AccountToken?,
) {
    /** The select request this row makes, or null when its list carries no token (never admitted). */
    fun selectRequest(origin: com.nuvio.app.core.identity.SelectOrigin): com.nuvio.app.core.identity.SelectRequest? =
        listToken?.let { com.nuvio.app.core.identity.SelectRequest(profile.profileIndex, it, origin, profile) }

    override fun equals(other: Any?): Boolean = other is DisplayedProfile && other.profile == profile && other.listToken == listToken
    override fun hashCode(): Int = profile.hashCode() * 31 + (listToken?.hashCode() ?: 0)
}

@Serializable
data class AvatarCatalogItem(
    val id: String,
    @SerialName("display_name") val displayName: String = "",
    @SerialName("storage_path") val storagePath: String = "",
    val category: String = "character",
    @SerialName("sort_order") val sortOrder: Int = 0,
    @SerialName("is_active") val isActive: Boolean = true,
    @SerialName("bg_color") val bgColor: String? = null,
)

fun avatarStorageUrl(storagePath: String): String =
    "${com.nuvio.app.core.network.ServerConfigurationRepository.active.value.backendUrl}/storage/v1/object/public/avatars/$storagePath"

fun normalizedAvatarUrl(url: String?): String? =
    url?.trim()?.takeIf { it.isValidAvatarUrl() }

/// Sanity bound for inline `data:image/...;base64,...` avatars (e.g. custom pictures imported
/// from other Nuvio clients such as the mobile "Xperence" app, which write the encoded image
/// straight into `avatar_url` rather than a Supabase storage URL). Generous enough for a decent
/// profile-photo-sized JPEG/PNG once base64-inflated, but bounded so a malformed/huge value can't
/// bloat sync payloads or the on-device cache indefinitely.
private const val MAX_DATA_URI_AVATAR_LENGTH = 2 * 1024 * 1024

fun String.isValidAvatarUrl(): Boolean {
    val value = trim()
    if (value.any { it.isWhitespace() }) return false
    return when {
        value.startsWith("https://") || value.startsWith("http://") -> value.length <= 2048
        value.startsWith("data:image/") -> value.length <= MAX_DATA_URI_AVATAR_LENGTH
        else -> false
    }
}

fun profileAvatarImageUrl(profile: NuvioProfile, avatar: AvatarCatalogItem?): String? =
    normalizedAvatarUrl(profile.avatarUrl)
        ?: avatar
            ?.storagePath
            ?.takeIf { it.isNotBlank() }
            ?.let(::avatarStorageUrl)
