package com.nuvio.app.core.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Pure-function coverage for ProfileSettingsSync's addon-wipe class guard (see
// docs/addon-wipe-investigation-2026-08-28.md). Deliberately does not touch ProfileSettingsSync
// itself — it's a singleton with network/platform dependencies — so this only exercises the
// top-level decision functions the observer delegates to (the pull gate, and the fork's
// echo-marker consumption below).
class ProfileSettingsPushGateTest {
    private val userA = SettingsPullToken(userId = "user-a", profileId = 1)
    private val userAOtherProfile = SettingsPullToken(userId = "user-a", profileId = 2)
    private val userB = SettingsPullToken(userId = "user-b", profileId = 1)

    @Test
    fun `blocks push when neither token exists`() {
        assertFalse(settingsPushAllowed(settledToken = null, currentToken = null))
    }

    @Test
    fun `blocks push when current token is null`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = null))
    }

    @Test
    fun `blocks push when settled token is null`() {
        assertFalse(settingsPushAllowed(settledToken = null, currentToken = userA))
    }

    @Test
    fun `allows push when settled and current tokens match`() {
        assertTrue(settingsPushAllowed(settledToken = userA, currentToken = userA))
    }

    @Test
    fun `blocks push when same user but different profileId`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = userAOtherProfile))
    }

    @Test
    fun `blocks push when same profileId but different userId`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = userB))
    }

    // Fork: the echo marker must suppress the very next emission only — see
    // consumeSettingsSkipMarker's doc for the profile-reselect sequence that left the server stuck
    // on a superseded value when a mismatched marker survived.
    @Test
    fun `no marker never suppresses a push`() {
        val decision = consumeSettingsSkipMarker(marker = null, signature = "S")
        assertFalse(decision.skipPush)
        assertNull(decision.remainingMarker)
    }

    @Test
    fun `a matching marker suppresses one push and then expires`() {
        val decision = consumeSettingsSkipMarker(marker = "S", signature = "S")
        assertTrue(decision.skipPush)
        assertNull(decision.remainingMarker)
    }

    @Test
    fun `a mismatched marker pushes and still expires`() {
        val first = consumeSettingsSkipMarker(marker = "S", signature = "T")
        assertFalse(first.skipPush)
        assertNull(first.remainingMarker)

        // The S that follows must push: with the marker expired it is an ordinary emission, not
        // the echo of a profile reselect that happened two edits ago.
        val second = consumeSettingsSkipMarker(marker = first.remainingMarker, signature = "S")
        assertFalse(second.skipPush)
        assertNull(second.remainingMarker)
    }

    // Fork: the deferred-push path (maybeRetryGatedPush) delegates to gatedPushDecision, the pure
    // decision behind it — these exercise that function directly rather than re-deriving its
    // result through consumeSettingsSkipMarker, which only covers the observer's own call site.
    @Test
    fun `no pending deferred push leaves the marker untouched`() {
        // A settle with no deferred push is not an emission — nothing armed pendingGatedPushSignature,
        // so there is nothing to test the marker against, and the marker must survive for whatever
        // emission arms or consumes it next.
        val decision = gatedPushDecision(pending = null, marker = "S", signature = "T")
        assertFalse(decision.shouldPush)
        assertEquals("S", decision.remainingMarker)
        assertNull(decision.remainingPending)
    }

    @Test
    fun `a deferred push with a mismatched marker pushes and expires both`() {
        // An edit before the first pull settles is held; the pull then applies a blob that leaves
        // the state at T while the marker is still armed with the reselect's S. The mismatch means
        // this deferred push is not the echo, so it must actually spend a push.
        val decision = gatedPushDecision(pending = "T", marker = "S", signature = "T")
        assertTrue(decision.shouldPush)
        assertNull(decision.remainingMarker)
        assertNull(decision.remainingPending)
    }

    @Test
    fun `a deferred push with a matching marker is skipped and expires both`() {
        // The pull applied exactly the state the held emission wanted to push — the server has it
        // already, so the owed push would be a redundant rewrite, and the marker is spent on it.
        val decision = gatedPushDecision(pending = "S", marker = "S", signature = "S")
        assertFalse(decision.shouldPush)
        assertNull(decision.remainingMarker)
        assertNull(decision.remainingPending)
    }
}
