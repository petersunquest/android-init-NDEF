package com.beamio.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Keys for the Hang Up mailbox fallback: the peer's, never our own. */
class HangupMailboxKeysTest {
    private val callerPgp = "-----BEGIN PGP PUBLIC KEY BLOCK-----caller-user"
    private val callerRoute = "-----BEGIN PGP PUBLIC KEY BLOCK-----caller-route"
    private val calleeKeys = "-----BEGIN PGP PUBLIC KEY BLOCK-----callee-user" to "-----BEGIN PGP PUBLIC KEY BLOCK-----callee-route"

    @Test
    fun calleeUsesTheCallersKeysFromTheOffer() {
        var looked = false
        val k = HangupMailboxKeys.pick(BeamioNativeVoiceSignaling.Role.CALLEE, callerPgp, callerRoute) { looked = true; calleeKeys }
        assertEquals(callerPgp to callerRoute, k)
        assertEquals(false, looked)
    }

    @Test
    fun callerLooksUpTheCalleeAndNeverUsesItsOwnOfferKeys() {
        // A caller's offer holds its own keys: they must not be used.
        val k = HangupMailboxKeys.pick(BeamioNativeVoiceSignaling.Role.DIALER, callerPgp, callerRoute) { calleeKeys }
        assertEquals(calleeKeys, k)
    }

    @Test
    fun missingOrBadKeysGiveNothing() {
        assertNull(HangupMailboxKeys.pick(BeamioNativeVoiceSignaling.Role.DIALER, callerPgp, callerRoute) { null })
        assertNull(HangupMailboxKeys.pick(BeamioNativeVoiceSignaling.Role.CALLEE, "", callerRoute) { calleeKeys })
        assertNull(HangupMailboxKeys.pick(BeamioNativeVoiceSignaling.Role.DIALER, "", "") { "x" to "y" })
    }
}
