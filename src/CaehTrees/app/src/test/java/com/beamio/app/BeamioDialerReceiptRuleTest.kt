package com.beamio.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dialer: no `voice_call_ringing_v1` after five ringback rings ends the call as Unreachable. */
class BeamioDialerReceiptRuleTest {
    @Test
    fun fiveRingsOfTheLocalRingback() {
        // CEPT 1 s on / 4 s off, as the browser and iOS: 25 s.
        assertEquals(25_000L, BeamioDialerReceiptRule.unreachableAfterMs("de"))
        assertEquals(25_000L, BeamioDialerReceiptRule.unreachableAfterMs("cn"))
        assertEquals(25_000L, BeamioDialerReceiptRule.unreachableAfterMs(""))
        assertEquals(25_000L, BeamioDialerReceiptRule.unreachableAfterMs(null))
        // ANSI 2 s on / 4 s off: 30 s.
        assertEquals(30_000L, BeamioDialerReceiptRule.unreachableAfterMs("CA"))
        assertEquals(30_000L, BeamioDialerReceiptRule.unreachableAfterMs("us"))
        // Short 3 s cycles (15 s) stay at the 20 s floor, within a few seconds of 25 s.
        assertEquals(20_000L, BeamioDialerReceiptRule.unreachableAfterMs("jp"))
        assertEquals(20_000L, BeamioDialerReceiptRule.unreachableAfterMs("gb"))
        assertEquals(20_000L, BeamioDialerReceiptRule.unreachableAfterMs("hk"))
    }

    @Test
    fun alwaysAfterTheEightSecondNoticeAndBeforeTheRingWindow() {
        for (country in listOf("", "us", "ca", "jp", "gb", "au", "hk", "de", "fr")) {
            val ms = BeamioDialerReceiptRule.unreachableAfterMs(country)
            assertTrue(country, ms > BeamioNativeVoiceSignaling.PEER_WAKE_TIMEOUT_MS)
            assertTrue(country, ms < 60_000L)
        }
    }

    @Test
    fun endsOnlyWhileRingingWithoutReceipt() {
        assertTrue(BeamioDialerReceiptRule.endsUnreachable(stillRinging = true, rang = false))
        // A receipt before the five rings: keep ringing until accept / decline / 60 s.
        assertFalse(BeamioDialerReceiptRule.endsUnreachable(stillRinging = true, rang = true))
        // Accepted, declined, hung up or timed out already: nothing to end.
        assertFalse(BeamioDialerReceiptRule.endsUnreachable(stillRinging = false, rang = false))
        assertFalse(BeamioDialerReceiptRule.endsUnreachable(stillRinging = false, rang = true))
    }

    @Test
    fun timerCountsFromTheOffersCreation() {
        assertEquals(23_800L, BeamioDialerReceiptRule.delayMs(100_000L, 101_200L, 25_000L))
        assertEquals(0L, BeamioDialerReceiptRule.delayMs(100_000L, 130_000L, 25_000L))
    }
}
