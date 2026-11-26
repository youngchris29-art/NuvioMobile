package com.nuvio.app.core.identity

import com.nuvio.app.core.auth.AuthState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.time.TimeSource

/** Spec 4.6 (revision 7): the revoke runs before the drain, the apply, the wipe, ensureLoaded and the auth write. */
class RevocationOrderTest {

    private val log = EventLog()
    private lateinit var ops: FakeProfileOps
    private lateinit var revoker: RecordingRevoker
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @BeforeTest
    fun setUp() {
        ops = installDriverFakes(log)
        revoker = RecordingRevoker(log)
        IdentityRevocation.revoker = revoker
    }

    @AfterTest
    fun tearDown() {
        work.cancel()
        resetIdentityForTest()
    }

    @Test
    fun revokePrecedesTheDrainAndTheApply() = runTest {
        withContext(Dispatchers.Default) {
            assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "save", work) { delay(100); log.add("job end") })
            assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
            assertEquals(listOf("revoke ProfileSelect", "job end", "apply 2"), log.all())
        }
    }

    @Test
    fun revokePrecedesTheWipeEnsureLoadedAndTheAuthWrite() {
        IdentityImmediate.onAccountPublished = { log.add("ensureLoaded $it") }
        IdentityImmediate.accountWipe { log.add("wipe") }
        IdentityImmediate.publishAuth(AuthState.Unauthenticated) { log.add("auth write") }
        IdentityImmediate.chainEnded()
        assertEquals(listOf("revoke AccountWipe", "wipe", "ensureLoaded None", "auth write"), log.all())

        // A publish-only chain (sign-in): the revoke precedes ensureLoaded and the write.
        IdentityImmediate.publishAuth(AuthState.Authenticated("user-b", null, isAnonymous = false)) { log.add("auth write B") }
        IdentityImmediate.chainEnded()
        assertEquals(
            listOf("revoke AccountPublished", "ensureLoaded ${accountB}", "auth write B"),
            log.all().drop(4),
        )
    }

    @Test
    fun aSlowRevokerDelaysTheApplyButNeverReordersIt() = runTest {
        withContext(Dispatchers.Default) {
            revoker.onRevoke = {
                val start = TimeSource.Monotonic.markNow()
                while (start.elapsedNow().inWholeMilliseconds < 250) { /* a slow main-thread body */ }
                log.add("revoke body end")
            }
            val start = TimeSource.Monotonic.markNow()
            assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
            assertEquals(listOf("revoke ProfileSelect", "revoke body end", "apply 2"), log.all())
            kotlin.test.assertTrue(start.elapsedNow().inWholeMilliseconds >= 250)
        }
    }
}
