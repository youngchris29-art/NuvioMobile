package com.nuvio.app.core.auth

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** D1b: trace lines are fixed words only; nothing identifying ever reaches the console. */
class AuthSessionTraceTest {

    private val secrets = listOf("user7f3aSECRET", "guest91bcSECRET", "accessSECRET", "refreshSECRET", "mail@SECRET")

    private fun assertClean(line: String?) {
        if (line == null) return
        secrets.forEach { assertTrue(it !in line, "'$line' carries $it") }
        assertTrue("@" !in line && "http" !in line && "//" !in line, "'$line'")
    }

    private val ticket = AuthTicket(7)

    private val events: List<AuthEvent> = listOf(
        AuthEvent.Boot(guestId = "guest91bcSECRET", owner = "user7f3aSECRET", notice = true),
        AuthEvent.Boot(guestId = "guest91bcSECRET", owner = null, notice = false, ownerUnknown = true, wipePending = true),
        AuthEvent.Boot(guestId = null, owner = null, notice = false),
        AuthEvent.WatchdogFired,
        AuthEvent.ValidationFinished(ticket, SessionVerdict.Valid, "user7f3aSECRET"),
        AuthEvent.ValidationFinished(ticket, SessionVerdict.Unreachable),
        AuthEvent.SessionErrorReported(ticket, SessionErrorKind.DeletedAccount),
        AuthEvent.ResetStarted(ResetKind.SignOut),
        AuthEvent.ResetFinished(ResetKind.ServerSwitch),
        AuthEvent.SessionStartStarted(SessionStartKind.Qr),
        AuthEvent.SessionStartFinished(SessionStartKind.Email, ok = false),
        AuthEvent.GuestChosen("guest91bcSECRET"),
        AuthEvent.WipeFinished(ok = true),
        AuthEvent.GatePassed(AuthOutput.PersistOwner("user7f3aSECRET")),
        AuthEvent.GateFailed(AuthOutput.SaveGuestId("guest91bcSECRET")),
        AuthEvent.GatePassed(AuthOutput.PersistWipePending(false)),
        Snap.Initializing,
        Snap.RefreshFailure,
        Snap.NotAuthenticated(cleared = false),
        Snap.Scaffold,
        Snap.Account("user7f3aSECRET", "mail@SECRET", "accessSECRET", "refreshSECRET", refreshedFrom = "refreshSECRET", restored = true),
        Snap.Account(null, null, "accessSECRET", "refreshSECRET", refreshedFrom = null, restored = true),
    )

    private val outputs: List<AuthOutput> = listOf(
        AuthOutput.Publish(AuthState.Authenticated("user7f3aSECRET", "mail@SECRET", false)),
        AuthOutput.Publish(AuthState.Authenticated("guest91bcSECRET", null, true)),
        AuthOutput.Publish(AuthState.Unauthenticated),
        AuthOutput.Publish(AuthState.Loading),
        AuthOutput.PersistOwner("user7f3aSECRET"),
        AuthOutput.PersistNotice(true),
        AuthOutput.PersistWipePending(true),
        AuthOutput.ShowNotice,
        AuthOutput.HideNotice,
        AuthOutput.SaveGuestId("guest91bcSECRET"),
        AuthOutput.ClearGuestId,
        AuthOutput.WipeAccountData,
        AuthOutput.ClearSupabaseSession,
        AuthOutput.KickSessionRefresh,
        AuthOutput.StartValidation(ticket, "accessSECRET"),
        AuthOutput.Drop("lost session: validation rejected the session"),
        AuthOutput.Drop("lost session: something new user7f3aSECRET"),
        AuthOutput.Drop("boot: guest id guest91bcSECRET is stale, account user7f3aSECRET owns the data"),
        AuthOutput.Drop("wipe: account user7f3aSECRET replaces the previous local data"),
        AuthOutput.Drop("durable write failed: PersistOwner(userId=user7f3aSECRET)"),
        AuthOutput.Drop("gate outcome GatePassed(user7f3aSECRET) does not match the pending gate x"),
        AuthOutput.Drop("anything else user7f3aSECRET"),
    )

    @Test
    fun noLineCarriesATokenEmailIdOrUrl() {
        events.forEach { assertClean(describeEvent(it)) }
        outputs.forEach { assertClean(describeOutput(it)) }
    }

    @Test
    fun theLinesTheRigReadsSayWhatHappened() {
        assertEquals("boot owner=account guest=stale, cleared wipePending=false notice=true", describeEvent(events[0]))
        assertEquals("boot owner=unknown guest=trusted wipePending=true notice=false", describeEvent(events[1]))
        assertEquals("validation Valid (user returned)", describeEvent(events[4]))
        assertEquals("gate passed owner account", describeEvent(events[13]))
        assertEquals("gate failed guest id", describeEvent(events[14]))
        assertEquals("gate passed marker clear", describeEvent(events[15]))
        assertEquals("status RefreshFailure", describeEvent(Snap.RefreshFailure))
        assertEquals("status Authenticated(account source=refresh)", describeEvent(events[20]))
        assertEquals("status Authenticated(account unresolved source=storage)", describeEvent(events[21]))
        assertEquals("publish account", describeOutput(outputs[0]))
        assertEquals("publish guest", describeOutput(outputs[1]))
        assertEquals("publish signed-out", describeOutput(outputs[2]))
        assertEquals("wipe started", describeOutput(AuthOutput.WipeAccountData))
        assertEquals("notice set", describeOutput(AuthOutput.PersistNotice(true)))
        assertEquals("lost reset: validation rejected the session", describeOutput(outputs[15]))
        assertEquals("lost reset", describeOutput(outputs[16]))
        assertEquals("dropped", describeOutput(outputs.last()))
    }
}
