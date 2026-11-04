package com.beamio.app

import android.webkit.PermissionRequest

/**
 * Which WebView media requests the shell lets through.
 *
 * 2026-11-03, Samsung on 1.0.161 test3: after calls ended, the Samsung camera
 * could not record ("microphone in use"). The PWA opens the WebView microphone
 * while a call rings (`[voice-mic] prewarm`) and only closes it on its own
 * answer / decline paths. The shell answers, declines and ends calls natively,
 * so that stream stayed open (silenced in the background, never released).
 *
 * The shell records calls with its own AudioRecord. The WebView microphone is
 * only needed for a call the PWA runs itself: a connected Telecom call the
 * shell's call screen does not own. Ringing, idle and native calls get no
 * WebView microphone. Camera requests (QR scan, photos) are unaffected.
 */
internal object BeamioWebMicGate {
    /** A connected call exists in Telecom, and it is not the shell's own call. */
    fun pwaCallLive(telecomCallLive: Boolean, nativeCallLive: Boolean): Boolean =
        telecomCallLive && !nativeCallLive

    /** The resources of [requested] the shell may grant; others are refused. */
    fun allowedResources(requested: Array<String>, pwaCallLive: Boolean): Array<String> =
        requested.filter { res ->
            when (res) {
                PermissionRequest.RESOURCE_VIDEO_CAPTURE -> true
                PermissionRequest.RESOURCE_AUDIO_CAPTURE -> pwaCallLive
                else -> true
            }
        }.toTypedArray()

    fun refusesMicrophone(requested: Array<String>, allowed: Array<String>): Boolean =
        PermissionRequest.RESOURCE_AUDIO_CAPTURE in requested &&
            PermissionRequest.RESOURCE_AUDIO_CAPTURE !in allowed
}
