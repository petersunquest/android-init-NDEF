package com.beamio.app

import android.content.Intent

/**
 * Getting back to a call in progress: the Samsung status-bar call pill and the
 * ongoing-call notification both open MainActivity with SHOW_ACTIVE_CALL.
 *
 * 2026-11-03, Samsung on 1.0.161 test2: that intent carried CLEAR_TOP, which
 * destroyed InCallActivity (it sits above MainActivity in the same task);
 * MainActivity then only asked the PWA, which has no screen for a native call.
 * InCallActivity died without minimize(), so the model still said "presented"
 * and the green return pill stayed hidden. The user could not get back to the
 * call.
 */
internal object BeamioActiveCallRoute {
    /** Brings the existing MainActivity forward without finishing what is above it. */
    const val OPEN_MAIN_FLAGS: Int = Intent.FLAG_ACTIVITY_NEW_TASK or
        Intent.FLAG_ACTIVITY_SINGLE_TOP or
        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT

    enum class Target { NATIVE_IN_CALL, PWA }

    /** A call the shell owns goes back to the native call screen; anything else is the PWA's. */
    fun target(nativeCallLive: Boolean): Target =
        if (nativeCallLive) Target.NATIVE_IN_CALL else Target.PWA

    enum class Present { RENDER_IN_PLACE, START }

    /**
     * An InCallActivity that exists but is not resumed (another activity of
     * the task is above it) must be started again so REORDER_TO_FRONT lifts it.
     */
    fun present(instanceAlive: Boolean, instanceResumed: Boolean): Present =
        if (instanceAlive && instanceResumed) Present.RENDER_IN_PLACE else Present.START

    enum class Destroyed { RESTORE_ROUTE, MARK_MINIMIZED, KEEP }

    /**
     * InCallActivity is gone. Call over: restore the audio route. Call still
     * live: keep the route, and when it went away without minimize() mark it
     * minimized so the return pill and the notification can bring it back.
     */
    fun onDestroyed(callLive: Boolean, presented: Boolean, changingConfigurations: Boolean): Destroyed = when {
        !callLive -> Destroyed.RESTORE_ROUTE
        changingConfigurations -> Destroyed.KEEP
        presented -> Destroyed.MARK_MINIMIZED
        else -> Destroyed.KEEP
    }
}
