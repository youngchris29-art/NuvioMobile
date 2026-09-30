package com.nuvio.app.core.storage

import co.touchlab.kermit.Logger
import com.nuvio.app.core.account.AccountDataStores
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.ptr
import platform.CoreFoundation.CFDictionaryCreateMutable
import platform.CoreFoundation.CFDictionarySetValue
import platform.CoreFoundation.CFRelease
import platform.CoreFoundation.CFStringCreateWithCString
import platform.CoreFoundation.kCFStringEncodingUTF8
import platform.CoreFoundation.kCFTypeDictionaryKeyCallBacks
import platform.CoreFoundation.kCFTypeDictionaryValueCallBacks
import platform.Foundation.NSUserDefaults
import platform.Security.SecItemDelete
import platform.Security.errSecItemNotFound
import platform.Security.errSecSuccess
import platform.Security.kSecAttrService
import platform.Security.kSecClass
import platform.Security.kSecClassGenericPassword

/**
 * Sign-out deletion entry point for Keychain-backed credential stores, the Keychain counterpart of
 * [AppleFilePayloadStores]. Both account cleaners — tvOS (TvOsAccountDataCleaner in
 * TvOsProviderInstaller.kt) and iOS (composeApp's PlatformLocalAccountDataCleaner.ios) — call
 * [deleteAll], which deletes every generic-password item of every
 * `AppleKeySpec.Keychain(service)` listed in `core.account.AccountDataStores` (all accounts, so
 * every profile slot at once).
 *
 * Keychain items survive an app delete, which makes a missed wipe worse than for defaults keys
 * (see [deleteAllIfFreshInstall] for the reinstall half). Adding a Keychain-backed store means
 * adding an `AppleKeySpec.Keychain(...)` entry to `AccountDataStores.all`, NOT editing this file.
 */
object AppleKeychainStores {
    private val log = Logger.withTag("AppleKeychainStores")

    /**
     * Global (NOT profile-scoped) NSUserDefaults sentinel for [deleteAllIfFreshInstall].
     *
     * Deliberately NOT registered in `AccountDataStores`: the registry's Apple keys are exactly what
     * a sign-out wipe erases, and a wiped sentinel would make the NEXT launch treat a signed-in
     * device as a fresh install and delete the Keychain credentials the user connected after
     * signing back in. It must survive sign-out; only an app delete (which removes the defaults
     * domain) clears it.
     */
    internal const val INSTALL_SENTINEL_KEY = "keychain_install_generation"
    private const val INSTALL_SENTINEL_VALUE = 1L

    fun deleteAll() {
        AccountDataStores.appleKeychainServices().forEach(::deleteService)
    }

    /**
     * Fork: reinstall guard. Keychain generic passwords (even `…ThisDeviceOnly`) are NOT removed
     * when the app is deleted, but NSUserDefaults are. So after a delete + reinstall — routine for
     * sideloading testers — profile 1 would come back connected to the PREVIOUS install's MDBList
     * account, and once MDBList sync lands it would push that profile's watch data there. When the
     * defaults sentinel is absent this launch is a fresh install (or the first launch of the build
     * that introduced this guard, which predates any Keychain store, so nothing live is lost):
     * delete every registered Keychain service, then write the sentinel.
     *
     * Must run before anything touches a Keychain-backed store (tvOS: first thing in
     * `installTvOsSharedProviders()`, ahead of `ensureTrackingProvidersRegistered()`). Idempotent;
     * never throws. Returns true when it wiped.
     */
    fun deleteAllIfFreshInstall(): Boolean {
        val defaults = NSUserDefaults.standardUserDefaults
        if (defaults.objectForKey(INSTALL_SENTINEL_KEY) != null) return false
        log.i { "No $INSTALL_SENTINEL_KEY sentinel: fresh install, clearing Keychain stores left by a previous install" }
        try {
            deleteAll()
        } catch (error: Exception) {
            // deleteService already logs per-service failures; this only guards the registry read.
            log.e(error) { "Fresh-install Keychain wipe failed" }
        }
        // Written even after a failed delete: retrying on every launch would later delete tokens
        // the user connected in THIS install.
        defaults.setInteger(INSTALL_SENTINEL_VALUE, forKey = INSTALL_SENTINEL_KEY)
        return true
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
