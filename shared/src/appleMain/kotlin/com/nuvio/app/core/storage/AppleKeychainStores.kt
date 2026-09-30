package com.nuvio.app.core.storage

import com.nuvio.app.core.account.AccountDataStores
import kotlinx.cinterop.ExperimentalForeignApi
import platform.CoreFoundation.CFDictionaryCreateMutable
import platform.CoreFoundation.CFDictionarySetValue
import platform.CoreFoundation.CFRelease
import platform.CoreFoundation.CFStringCreateWithCString
import platform.CoreFoundation.kCFStringEncodingUTF8
import platform.CoreFoundation.kCFTypeDictionaryKeyCallBacks
import platform.CoreFoundation.kCFTypeDictionaryValueCallBacks
import platform.Security.SecItemDelete
import platform.Security.errSecItemNotFound
import platform.Security.errSecSuccess
import platform.Security.kSecAttrService
import platform.Security.kSecClass
import platform.Security.kSecClassGenericPassword
import kotlinx.cinterop.ptr
import co.touchlab.kermit.Logger

/**
 * Sign-out deletion entry point for Keychain-backed credential stores, the Keychain counterpart of
 * [AppleFilePayloadStores]. Both account cleaners — tvOS (TvOsAccountDataCleaner in
 * TvOsProviderInstaller.kt) and iOS (composeApp's PlatformLocalAccountDataCleaner.ios) — call
 * [deleteAll], which deletes every generic-password item of every
 * `AppleKeySpec.Keychain(service)` listed in `core.account.AccountDataStores` (all accounts, so
 * every profile slot at once).
 *
 * Keychain items survive an app delete, which makes a missed wipe worse than for defaults keys.
 * Adding a Keychain-backed store means adding an `AppleKeySpec.Keychain(...)` entry to
 * `AccountDataStores.all`, NOT editing this file.
 */
object AppleKeychainStores {
    private val log = Logger.withTag("AppleKeychainStores")

    fun deleteAll() {
        AccountDataStores.appleKeychainServices().forEach(::deleteService)
    }

    /**
     * Deletes every `kSecClassGenericPassword` item under [service]. A failure is logged, never
     * thrown: this runs inside the account wipe, and one unreadable Keychain must not abort the
     * remaining steps of a sign-out.
     */
    @OptIn(ExperimentalForeignApi::class)
    fun deleteService(service: String) {
        val serviceRef = CFStringCreateWithCString(null, service, kCFStringEncodingUTF8) ?: run {
            log.e { "Unable to encode Keychain service $service" }
            return
        }
        val query = CFDictionaryCreateMutable(
            null,
            0L,
            kCFTypeDictionaryKeyCallBacks.ptr,
            kCFTypeDictionaryValueCallBacks.ptr,
        )
        if (query == null) {
            CFRelease(serviceRef)
            log.e { "Unable to create Keychain query for $service" }
            return
        }
        try {
            CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword)
            CFDictionarySetValue(query, kSecAttrService, serviceRef)
            val status = SecItemDelete(query)
            if (status != errSecSuccess && status != errSecItemNotFound) {
                log.e { "Keychain delete for $service failed (OSStatus $status)" }
            }
        } finally {
            CFRelease(query)
            CFRelease(serviceRef)
        }
    }
}
