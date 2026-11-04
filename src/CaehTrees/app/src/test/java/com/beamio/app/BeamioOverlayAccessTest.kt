package com.beamio.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 2026-11-03, Samsung on 1.0.161 (fresh install): a call ringing over Settings
 * showed the small system card, because "Appear on top" was never granted and
 * the app never asked for it.
 */
class BeamioOverlayAccessTest {
    private val day = BeamioOverlayAccess.REASK_AFTER_FALLBACK_MS
    private val t0 = 1_800_000_000_000L

    private fun ask(
        sdk: Int = 36,
        granted: Boolean = false,
        fsiReady: Boolean = true,
        busy: Boolean = false,
        askedAt: Long = 0L,
        fallbackAt: Long = 0L,
        now: Long = t0,
    ) = BeamioOverlayAccess.shouldAsk(sdk, granted, fsiReady, busy, askedAt, fallbackAt, now)

    @Test
    fun firstOpenWithoutPermissionAsks() {
        assertTrue(ask())
    }

    @Test
    fun grantedOrTooOldNeverAsks() {
        assertFalse(ask(granted = true))
        assertFalse(ask(granted = true, fallbackAt = t0, askedAt = t0 - 2 * day))
        assertFalse(ask(sdk = 22))
    }

    @Test
    fun neverDuringARingingOrLiveCall() {
        assertFalse(ask(busy = true))
        assertFalse(ask(busy = true, askedAt = t0 - 2 * day, fallbackAt = t0 - day))
    }

    @Test
    fun fullScreenIntentAccessComesFirst() {
        // Android 14+ opens that settings page on the same resume.
        assertFalse(ask(fsiReady = false))
    }

    @Test
    fun askedOnceStaysQuietWithoutAFallback() {
        assertFalse(ask(askedAt = t0 - 30 * day))
        // A fallback from before the last ask does not count.
        assertFalse(ask(askedAt = t0 - 2 * day, fallbackAt = t0 - 3 * day))
    }

    @Test
    fun asksAgainAfterACallFellBackAtMostOnceADay() {
        assertTrue(ask(askedAt = t0 - day, fallbackAt = t0 - 60_000L))
        assertFalse(ask(askedAt = t0 - day + 1, fallbackAt = t0 - 60_000L))
    }
}
