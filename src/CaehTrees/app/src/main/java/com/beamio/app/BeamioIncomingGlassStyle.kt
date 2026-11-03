package com.beamio.app

/**
 * Incoming UI when a system page (Settings, permission dialog) hides the
 * overlay glass, and the look of the system incoming cards. Pure values and
 * choices, unit-tested.
 *
 * Hidden overlay, unlocked: open Beamio's full-screen incoming page
 * (IncomingCallActivity, lock-screen layout) over the system page (RC3h, user
 * choice: a transparent top card could not let touches reach the page below —
 * Android 15 touch-opaque activities). Only if it does not show within
 * [GLASS_WINDOW_CONFIRM_MS] (blocked by the system), post the dark system
 * CallStyle card as the fallback.
 */
internal object BeamioIncomingGlassStyle {
    /** Card background: the Glass charcoal (#2C2C2E), opaque — colorized notifications ignore alpha. */
    const val CARD_COLOR: Int = 0xFF2C2C2E.toInt()
    /** Same as @color/incoming_call_decline. */
    const val DECLINE_COLOR: Int = 0xFFD81720.toInt()
    /** Same as @color/incoming_call_answer. */
    const val ANSWER_COLOR: Int = 0xFF0754D9.toInt()

    /** Time for the full-screen page to show before the fallback card is posted. */
    const val GLASS_WINDOW_CONFIRM_MS = 700L

    enum class HiddenOverlayStep {
        /** Open the full-screen incoming page. */
        OPEN_GLASS_WINDOW,
        /** Nothing to do: lock screen (full-screen intent owns it), call closed, or the incoming page already shows. */
        NONE,
    }

    fun hiddenOverlayStep(keyguardLocked: Boolean, callOpen: Boolean, glassWindowVisible: Boolean): HiddenOverlayStep =
        if (!keyguardLocked && callOpen && !glassWindowVisible) HiddenOverlayStep.OPEN_GLASS_WINDOW else HiddenOverlayStep.NONE

    enum class AfterLaunch {
        /** The full-screen page shows this call. */
        DONE,
        /** It did not show (blocked): post the dark CallStyle card. */
        POST_DARK_CALL_STYLE,
        /** Nothing to post: the call ended, or the overlay glass is back on screen. */
        NOTHING,
    }

    fun afterGlassWindowLaunch(windowVisible: Boolean, callOpen: Boolean, overlayVisible: Boolean): AfterLaunch = when {
        !callOpen -> AfterLaunch.NOTHING
        windowVisible -> AfterLaunch.DONE
        overlayVisible -> AfterLaunch.NOTHING
        else -> AfterLaunch.POST_DARK_CALL_STYLE
    }
}
