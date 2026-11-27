package com.nuvio.app.features.cloud

import com.nuvio.app.core.identity.AccountKey
import com.nuvio.app.core.identity.BarrierState
import com.nuvio.app.core.identity.IdentityEpoch
import com.nuvio.app.core.identity.IdentityRuntime
import com.nuvio.app.core.identity.IdentityScope
import com.nuvio.app.core.identity.eventually
import com.nuvio.app.core.identity.resetIdentityForTest
import com.nuvio.app.features.debrid.DebridProviders
import com.nuvio.app.features.debrid.DebridServiceCredential
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/*
 * Scope identity W3b (spec 9.1.5): every Cloud write, read and return runs on the token captured as
 * the call's first statement. Profile A (slot 1) switches to profile B (slot 2, a new epoch) at the
 * marked point; B's Cloud state in memory is MARKER and must stay untouched; nothing of A reaches
 * the caller.
 */

private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

private val guest = AccountKey.Guest("g")
private val keyA = DebridServiceCredential(DebridProviders.Torbox, "key-of-a")
private val keyB = DebridServiceCredential(DebridProviders.Premiumize, "key-of-b")

private val fileA = CloudLibraryFile(id = "f1", name = "a.mkv")
private val itemA = CloudLibraryItem(providerId = DebridProviders.TORBOX_ID, providerName = "Torbox", id = "1", type = CloudLibraryItemType.Torrent, name = "A item", files = listOf(fileA))
private val listingA = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Torbox, items = listOf(itemA))))
private val MARKER = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Premiumize)))

/** Per-profile Debrid settings; [profile] flips at the switch. */
private class FakeSettings : CloudLibraryRepository.Settings {
    var profile = 1
    val enabled = mutableMapOf(1 to true, 2 to true)
    val credentials = mutableMapOf(1 to listOf(keyA), 2 to listOf(keyB))
    var afterEnabledRead: () -> Unit = {}
    var afterCredentialsRead: () -> Unit = {}

    override fun load() {}
    override fun enabled(): Boolean = enabled.getValue(profile).also { afterEnabledRead() }
    override fun credentials(): List<DebridServiceCredential> = credentials.getValue(profile).also { afterCredentialsRead() }
}

/** Provider calls with a gate per call, recording the credentials each was handed. */
private class FakeBackend : CloudLibraryRepository.Backend {
    val handed = mutableListOf<List<DebridServiceCredential>>()
    var listing: CloudLibraryUiState = listingA
    var gate: CompletableDeferred<Unit>? = null
    var entered = CompletableDeferred<Unit>()

    override suspend fun refresh(credentials: List<DebridServiceCredential>): CloudLibraryUiState {
        handed += credentials
        entered.complete(Unit)
        gate?.await()
        return listing
    }

    override suspend fun resolvePlayback(item: CloudLibraryItem, file: CloudLibraryFile, credentials: List<DebridServiceCredential>): CloudLibraryPlaybackResult {
        handed += credentials
        entered.complete(Unit)
        gate?.await()
        return CloudLibraryPlaybackResult.Success(url = "https://example.invalid/stream")
    }
}

class CloudPublishGateTest {
    private val settings = FakeSettings()
    private val backend = FakeBackend()
    private val lines = MutableStateFlow<List<String>>(emptyList())

    @BeforeTest fun setUp() {
        resetIdentityForTest(slot = 1, serial = 1)
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(guest, 1), latestAccount = guest))
        CloudLibraryRepository.resetForTest()
        CloudLibraryRepository.settings = settings
        CloudLibraryRepository.backend = backend
        CloudLibraryRepository.logSink = { line -> lines.update { it + line } }
    }

    @AfterTest fun tearDown() {
        CloudLibraryRepository.resetForTest()
        resetIdentityForTest()
    }

    /** Profile B opens (new slot and epoch); its Cloud state in memory is MARKER. */
    private fun switchToB() {
        IdentityRuntime.setForTest(BarrierState.initial(2).copy(scope = IdentityScope(guest, 2), latestAccount = guest, epoch = IdentityEpoch(2)))
        settings.profile = 2
        CloudLibraryRepository.setStateForTest(MARKER)
    }

    private fun state() = CloudLibraryRepository.uiState.value
    private fun lineCount(text: String) = lines.value.count { text in it }

    @Test
    fun wa_disabledDecisionOfAnotherProfileNeverClearsTheNewState() {
        settings.enabled[1] = false
        settings.afterEnabledRead = { settings.afterEnabledRead = {}; switchToB() }
        CloudLibraryRepository.ensureLoaded()
        assertEquals(MARKER, state())
    }

    @Test
    fun wb_sameViaRefresh() {
        settings.enabled[1] = false
        settings.afterEnabledRead = { settings.afterEnabledRead = {}; switchToB() }
        CloudLibraryRepository.refresh()
        assertEquals(MARKER, state())
    }

    @Test
    fun we_lookupReturnsNotFoundNeverDisabled() = real {
        settings.enabled[1] = false
        settings.afterEnabledRead = { settings.afterEnabledRead = {}; switchToB() }
        val result = CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA))
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, result)
        assertEquals(MARKER, state())
    }

    @Test
    fun wc_switchBeforeTheStartCommitLaunchesNothing() = real {
        settings.afterCredentialsRead = { settings.afterCredentialsRead = {}; switchToB() }
        CloudLibraryRepository.refresh()
        assertFalse(state().isRefreshing)
        assertEquals(MARKER, state())
        delay(100)
        assertEquals(emptyList(), backend.handed, "nothing launched")
    }

    @Test
    fun wd_switchDuringTheRefreshPublishesNothing() = real {
        backend.gate = CompletableDeferred()
        CloudLibraryRepository.refresh()
        backend.entered.await()
        switchToB()
        backend.gate!!.complete(Unit)
        eventually { lineCount("refused site=cloudRefresh stage=commit") == 1 }
        assertEquals(MARKER, state())
    }

    @Test
    fun wj_notConnectedOfTheOldProfileNeverReturned() = real {
        settings.credentials[1] = emptyList()
        settings.afterCredentialsRead = { settings.afterCredentialsRead = {}; switchToB() }
        val result = CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA))
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, result)
    }

    @Test
    fun wf_cachedTargetOfTheOldProfileNeverReturned() = real {
        CloudLibraryRepository.setStateForTest(listingA)
        settings.afterCredentialsRead = {
            settings.afterCredentialsRead = {}
            IdentityRuntime.setForTest(BarrierState.initial(2).copy(scope = IdentityScope(guest, 2), latestAccount = guest, epoch = IdentityEpoch(2)))
            settings.profile = 2 // the cache still holds A's listing
        }
        val result = CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA))
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, result)
        assertEquals(listingA, state(), "the cache was not touched")
    }

    @Test
    fun wgh_freshLookupRefusedDuringTheRefresh() = real {
        backend.gate = CompletableDeferred()
        val lookup = async {
            CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA))
        }
        backend.entered.await()
        switchToB()
        backend.gate!!.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, lookup.await())
        assertEquals(MARKER, state())
    }

    @Test
    fun wi_noUrlStoredWhenTheResolveIsRefused() = real {
        backend.gate = CompletableDeferred()
        val resolve = async { CloudLibraryRepository.resolvePlayback(itemA, fileA) }
        backend.entered.await()
        switchToB()
        CloudLibraryRepository.setStateForTest(listingA) // A's listing back in memory: no URL may join it
        backend.gate!!.complete(Unit)
        assertEquals(CloudLibraryPlaybackResult.Failed(), resolve.await())
        assertEquals(listingA, state())
    }

    @Test
    fun credentials_theStoreIsHandedTheCapturedProfilesKey() = real {
        CloudLibraryRepository.beforeStoreCallForTest = { CloudLibraryRepository.beforeStoreCallForTest = {}; switchToB() }
        CloudLibraryRepository.refresh()
        eventually { lineCount("refused site=cloudRefresh stage=commit") == 1 }
        assertEquals(listOf(listOf(keyA)), backend.handed)
        assertEquals(MARKER, state())
    }

    @Test
    fun configuredProviders_refusedAfterTheCapture() {
        assertEquals(listOf(DebridProviders.Torbox), CloudLibraryRepository.configuredProviders())
        settings.afterCredentialsRead = { settings.afterCredentialsRead = {}; switchToB() }
        assertEquals(emptyList(), CloudLibraryRepository.configuredProviders())
    }

    @Test
    fun hold_aCancelledJobStillMakesOneRefusedAttempt() = real {
        CloudLibraryRepository.debugHoldMs = 300
        CloudLibraryRepository.refresh()
        eventually { lineCount("hold begin") == 1 }
        switchToB()
        CloudLibraryRepository.cancelJobsForTest()
        eventually(timeoutMs = 3_000) { lineCount("stale publish refused site=cloudRefresh") == 1 }
        delay(100)
        assertEquals(1, lineCount("refused site=cloudRefresh stage=commit"))
        assertEquals(1, lineCount("stale publish refused"))
        assertEquals(MARKER, state())
    }

    @Test
    fun keys_fullValueNoKeyInTextAndClearResets() {
        // "Aa" and "BB" have equal String hashes: compared by value they still differ.
        assertEquals("Aa".hashCode(), "BB".hashCode())
        val a = CloudLibraryRepository.CloudConnectionKey("torbox", "Aa")
        val b = CloudLibraryRepository.CloudConnectionKey("torbox", "BB")
        assertNotEquals(a, b)
        assertFalse("Aa" in a.toString())
        assertEquals(
            listOf(CloudLibraryRepository.CloudConnectionKey("premiumize", "y"), CloudLibraryRepository.CloudConnectionKey("torbox", "x")),
            CloudLibraryRepository.keysOf(listOf(DebridServiceCredential(DebridProviders.Torbox, "x"), DebridServiceCredential(DebridProviders.Premiumize, "y"))),
        )
        CloudLibraryRepository.setStateForTest(listingA)
        CloudLibraryRepository.clear()
        assertEquals(CloudLibraryUiState(), state())
        assertTrue(state().providers.isEmpty())
    }
}
