package com.beamio.app

import com.beamio.app.BeamioIncomingGlassStyle.AfterLaunch
import com.beamio.app.BeamioIncomingGlassStyle.HiddenOverlayStep
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * RC3e (2026-11-02, user): over Settings, open Beamio's own Glass window
 * instead of a system card; the dark CallStyle card only if it cannot show.
 */
class BeamioIncomingGlassStyleTest {
    @Test
    fun colorsMatchTheGlassWindow() {
        // Opaque: colorized notifications ignore alpha.
        assertEquals(0xFF, BeamioIncomingGlassStyle.CARD_COLOR ushr 24)
        assertEquals(0xFF2C2C2E.toInt(), BeamioIncomingGlassStyle.CARD_COLOR)
        // @color/incoming_call_decline and @color/incoming_call_answer.
        assertEquals(0xFFD81720.toInt(), BeamioIncomingGlassStyle.DECLINE_COLOR)
        assertEquals(0xFF0754D9.toInt(), BeamioIncomingGlassStyle.ANSWER_COLOR)
    }

    @Test
    fun hiddenOverlayOpensTheGlassWindowWhenUnlocked() {
        assertEquals(
            HiddenOverlayStep.OPEN_GLASS_WINDOW,
            BeamioIncomingGlassStyle.hiddenOverlayStep(keyguardLocked = false, callOpen = true, glassWindowVisible = false),
        )
    }

    @Test
    fun nothingOnTheLockScreenForAClosedCallOrWhenAWindowShows() {
        // Lock screen: the full-screen intent opens the opaque window; behavior unchanged.
        assertEquals(HiddenOverlayStep.NONE, BeamioIncomingGlassStyle.hiddenOverlayStep(true, true, false))
        // Answered / declined / ended / muted.
        assertEquals(HiddenOverlayStep.NONE, BeamioIncomingGlassStyle.hiddenOverlayStep(false, false, false))
        // A Glass window already shows: never a second card.
        assertEquals(HiddenOverlayStep.NONE, BeamioIncomingGlassStyle.hiddenOverlayStep(false, true, true))
    }

    @Test
    fun afterLaunchTheFallbackCardOnlyWhenTheWindowDidNotShow() {
        assertEquals(AfterLaunch.DONE, BeamioIncomingGlassStyle.afterGlassWindowLaunch(true, true, false))
        // Blocked by the system: dark CallStyle card.
        assertEquals(AfterLaunch.POST_DARK_CALL_STYLE, BeamioIncomingGlassStyle.afterGlassWindowLaunch(false, true, false))
        // The call ended meanwhile: nothing.
        assertEquals(AfterLaunch.NOTHING, BeamioIncomingGlassStyle.afterGlassWindowLaunch(false, false, false))
        assertEquals(AfterLaunch.NOTHING, BeamioIncomingGlassStyle.afterGlassWindowLaunch(true, false, false))
        // The overlay is back on screen (user left Settings): it is the card.
        assertEquals(AfterLaunch.NOTHING, BeamioIncomingGlassStyle.afterGlassWindowLaunch(false, true, true))
    }
}
