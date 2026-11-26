package com.nuvio.app.core.identity

import com.nuvio.app.core.auth.AuthState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

class AccountKeyTest {

    @Test
    fun ofMapsTheFourAuthStates() {
        assertEquals(AccountKey.None, AccountKey.of(AuthState.Loading))
        assertEquals(AccountKey.None, AccountKey.of(AuthState.Unauthenticated))
        assertEquals(AccountKey.Account("u1"), AccountKey.of(AuthState.Authenticated("u1", "a@b", isAnonymous = false)))
        assertEquals(AccountKey.Guest("g1"), AccountKey.of(AuthState.Authenticated("g1", null, isAnonymous = true)))
    }

    @Test
    fun storageKeyRoundTrips() {
        listOf(AccountKey.Account("u1"), AccountKey.Guest("g1"), AccountKey.Account("with:colon")).forEach {
            assertEquals(it, AccountKey.parse(it.storageKey()))
        }
        assertEquals("account:u1", AccountKey.Account("u1").storageKey())
        assertEquals("guest:g1", AccountKey.Guest("g1").storageKey())
        assertNull(AccountKey.None.storageKey())
    }

    @Test
    fun malformedKeysParseToNull() {
        assertNull(AccountKey.parse(null))
        assertNull(AccountKey.parse(""))
        assertNull(AccountKey.parse("account:"))
        assertNull(AccountKey.parse("guest:"))
        assertNull(AccountKey.parse("other:x"))
        assertNull(AccountKey.parse("u1"))
    }

    @Test
    fun guestAndAccountWithTheSameIdDiffer() {
        assertNotEquals<AccountKey>(AccountKey.Account("x"), AccountKey.Guest("x"))
        assertNotEquals(AccountKey.Account("x").storageKey(), AccountKey.Guest("x").storageKey())
    }
}
