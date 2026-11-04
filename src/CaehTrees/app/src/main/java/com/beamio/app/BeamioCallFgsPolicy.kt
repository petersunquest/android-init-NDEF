package com.beamio.app

import android.content.pm.ServiceInfo

/**
 * Choices for the call foreground service. Pure, unit-tested.
 *
 * 2026-11-03, Samsung on Release 1.0.160: during a live call the app's
 * microphone was silenced about 5 s after the app left the screen
 * ("App op 27 missing, silencing record"), and every return to MainActivity
 * stopped the call foreground service and its notification.
 */
internal object BeamioCallFgsPolicy {
    /** Android 14 (API 34): foreground service types must be passed to startForeground. */
    const val TYPED_FGS_SDK = 34

    const val PHONE_CALL: Int = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
    const val MICROPHONE: Int = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
    const val SHORT_SERVICE: Int = ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE

    /**
     * Types to try, in order, for the "call in progress" notification.
     *
     * phoneCall alone does not give the process background microphone access;
     * microphone does. Android 14+ refuses the microphone type when the app is
     * in the background (or RECORD_AUDIO is not granted), so the next entry is
     * phoneCall alone, and [needsMicrophoneUpgrade] adds microphone once an
     * app screen is in front again.
     */
    fun ongoingTypes(micGranted: Boolean): IntArray =
        if (micGranted) {
            intArrayOf(PHONE_CALL or MICROPHONE, PHONE_CALL, SHORT_SERVICE)
        } else {
            intArrayOf(PHONE_CALL, SHORT_SERVICE)
        }

    /** Ringing and muted holds: no microphone (nothing records yet, and it fails from an FCM wake). */
    fun ringingTypes(): IntArray = intArrayOf(PHONE_CALL, SHORT_SERVICE)

    fun hasMicrophone(types: Int): Boolean = (types and MICROPHONE) != 0

    /**
     * An app screen came to the front: post the ongoing notification again
     * with the microphone type when the call is in progress and the type is
     * still missing. Before Android 14 the manifest types apply on their own.
     */
    fun needsMicrophoneUpgrade(
        sdk: Int,
        ongoingShown: Boolean,
        currentTypes: Int,
        micGranted: Boolean,
    ): Boolean = sdk >= TYPED_FGS_SDK && ongoingShown && micGranted && !hasMicrophone(currentTypes)

    enum class StaleDismiss {
        /** The incoming window shows: never tear it down. */
        SKIP_GLASS_SHOWING,
        /** The incoming window is being opened. */
        SKIP_PRESENT_IN_FLIGHT,
        /** Telecom still rings an incoming call whose window is pending. */
        SKIP_RINGING,
        /** A call is dialing, connected or on hold: its service and notification stay. */
        SKIP_LIVE_CALL,
        /** Nothing live: drop leftover incoming cards and the service. */
        DISMISS,
    }

    /**
     * MainActivity.onResume clean-up of leftover incoming UI. A live call
     * (Telecom dialing / active / holding, or the native voice call) is never
     * "stale".
     */
    fun staleDismiss(
        glassShowing: Boolean,
        presentInFlight: Boolean,
        ringing: Boolean,
        liveCall: Boolean,
    ): StaleDismiss = when {
        glassShowing -> StaleDismiss.SKIP_GLASS_SHOWING
        presentInFlight -> StaleDismiss.SKIP_PRESENT_IN_FLIGHT
        ringing -> StaleDismiss.SKIP_RINGING
        liveCall -> StaleDismiss.SKIP_LIVE_CALL
        else -> StaleDismiss.DISMISS
    }
}
