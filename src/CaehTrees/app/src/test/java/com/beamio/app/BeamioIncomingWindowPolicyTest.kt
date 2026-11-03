package com.beamio.app

import com.beamio.app.BeamioIncomingWindowPolicy.Window
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * RC3e (2026-11-02, user): over Settings the incoming card showed on a black
 * full screen (opaque Activity started by the full-screen intent). Unlocked
 * now uses a transparent top-card window; the lock screen stays opaque.
 */
class BeamioIncomingWindowPolicyTest {
    @Test
    fun lockScreenStaysOpaqueFullScreen() {
        assertEquals(Window.OPAQUE_FULL_SCREEN, BeamioIncomingWindowPolicy.window(keyguardLocked = true))
    }

    @Test
    fun unlockedIsATransparentTopCard() {
        assertEquals(Window.TRANSPARENT_TOP_CARD, BeamioIncomingWindowPolicy.window(keyguardLocked = false))
    }

    @Test
    fun hiddenOverlayOpensTheFullScreenPageWhenUnlocked() {
        // RC3h (user): over Settings, the full-screen Beamio page with Decline, not a top card.
        assertEquals(
            Window.OPAQUE_FULL_SCREEN,
            BeamioIncomingWindowPolicy.window(keyguardLocked = false, fullScreenRequested = true),
        )
        assertEquals(
            Window.OPAQUE_FULL_SCREEN,
            BeamioIncomingWindowPolicy.window(keyguardLocked = true, fullScreenRequested = true),
        )
    }

    @Test
    fun overlaySuppressedOnlyUnderTheUnlockedFullScreenPage() {
        // The page covers Settings, so the overlay would show on top: keep it out of sight.
        assertTrue(BeamioIncomingWindowPolicy.suppressOverlayWhileShown(keyguardLocked = false, fullScreenRequested = true))
        // Lock screen: the overlay cannot draw there anyway; no change to that path.
        assertFalse(BeamioIncomingWindowPolicy.suppressOverlayWhileShown(keyguardLocked = true, fullScreenRequested = true))
        // Unlocked top card (other entries): no suppression.
        assertFalse(BeamioIncomingWindowPolicy.suppressOverlayWhileShown(keyguardLocked = false, fullScreenRequested = false))
    }

    @Test
    fun onlyTheUnlockedCardLetsTouchesThroughOutsideIt() {
        // RC3f E7a (2026-11-02): taps on Settings outside the card did nothing.
        assertTrue(BeamioIncomingWindowPolicy.passesTouchesOutsideCard(Window.TRANSPARENT_TOP_CARD))
        // Lock screen: the full-screen window keeps every touch (Slide to answer).
        assertFalse(BeamioIncomingWindowPolicy.passesTouchesOutsideCard(Window.OPAQUE_FULL_SCREEN))
    }

    @Test
    fun homeGoesBehindOnlyTheLockScreenWindow() {
        assertTrue(BeamioIncomingWindowPolicy.moveWithHome(Window.OPAQUE_FULL_SCREEN))
        // Home under a transparent card would hide the page the user was on.
        assertFalse(BeamioIncomingWindowPolicy.moveWithHome(Window.TRANSPARENT_TOP_CARD))
    }

    @Test
    fun neverTwoCards() {
        // Overlay already shows this call: the Activity card would stack on it.
        assertTrue(BeamioIncomingWindowPolicy.skipBecauseOverlayShows(Window.TRANSPARENT_TOP_CARD, true))
        // Over Settings the overlay is hidden: the Activity card is the one shown.
        assertFalse(BeamioIncomingWindowPolicy.skipBecauseOverlayShows(Window.TRANSPARENT_TOP_CARD, false))
        // Lock screen: the overlay cannot draw there; always show the Activity.
        assertFalse(BeamioIncomingWindowPolicy.skipBecauseOverlayShows(Window.OPAQUE_FULL_SCREEN, true))
    }
}
