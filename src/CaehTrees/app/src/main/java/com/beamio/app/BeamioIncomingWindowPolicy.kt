package com.beamio.app

/**
 * Window of [IncomingCallActivity]. Pure choices, unit-tested.
 *
 * Lock screen: opaque full screen (Slide to answer) — unchanged, it must cover
 * the keyguard. Unlocked: only the Glass card at the top on a transparent,
 * non-dimming window, so the page below (e.g. Settings) stays visible and
 * touchable. Before this (RC3d, 2026-11-02 Samsung), the system fired the
 * full-screen intent over Settings and the opaque theme drew a black screen
 * under the card.
 */
internal object BeamioIncomingWindowPolicy {
    enum class Window { OPAQUE_FULL_SCREEN, TRANSPARENT_TOP_CARD }

    fun window(keyguardLocked: Boolean): Window =
        if (keyguardLocked) Window.OPAQUE_FULL_SCREEN else Window.TRANSPARENT_TOP_CARD

    /**
     * Unlocked card: the window is only as tall as the card (set after
     * setContentView — the decor resets a non-floating window to full screen)
     * and touches outside it reach the page below.
     */
    fun passesTouchesOutsideCard(window: Window): Boolean = window == Window.TRANSPARENT_TOP_CARD

    /** Put Home behind the incoming task only for the opaque lock-screen window. */
    fun moveWithHome(window: Window): Boolean = window == Window.OPAQUE_FULL_SCREEN

    /**
     * Unlocked: the overlay glass already shows this call on screen, so a
     * second card from this Activity would stack on it — close the Activity.
     */
    fun skipBecauseOverlayShows(window: Window, overlayOnScreenForThisCall: Boolean): Boolean =
        window == Window.TRANSPARENT_TOP_CARD && overlayOnScreenForThisCall
}
