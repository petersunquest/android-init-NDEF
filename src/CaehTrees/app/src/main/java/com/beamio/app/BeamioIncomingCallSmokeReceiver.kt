package com.beamio.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Debug/install smoke: simulate FCM voiceCall wake / Answer without a browser dial.
 *
 * Clear sticky + wake:
 * adb shell am broadcast -a com.beamio.app.SMOKE_INCOMING_CALL \
 *   -n com.beamio.app/.BeamioIncomingCallSmokeReceiver \
 *   --es beamio.call_id smoke-call --es beamio.session_id smoke-sess
 * (aliases --es callId / --es sessionId also accepted)
 *
 * Answer (same ids; works while IncomingCallActionReceiver is
 * exported=false and cannot be fired from adb):
 * adb shell am broadcast -a com.beamio.app.SMOKE_ANSWER \
 *   -n com.beamio.app/.BeamioIncomingCallSmokeReceiver \
 *   --es beamio.call_id smoke-call --es beamio.session_id smoke-sess
 *
 * Not a BAL proof by itself when fired from shell (uid 2000), but exercises the
 * same showIncomingCallWakeNotification → reportIncoming → CallStyle FSI /
 * completeIncomingUserAction(callAnswered) → InCallActivity path under lock.
 */
class BeamioIncomingCallSmokeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val app = context.applicationContext
        // Prefer canonical extras; accept short adb aliases so shell smoke
        // does not invent a new callId and leave overlay chrome stuck.
        val callId = intent.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID)
            ?.trim()
            .orEmpty()
            .ifBlank { intent.getStringExtra("callId")?.trim().orEmpty() }
            .ifBlank { "smoke-${System.currentTimeMillis()}" }
        val sessionId = intent.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID)
            ?.trim()
            .orEmpty()
            .ifBlank { intent.getStringExtra("sessionId")?.trim().orEmpty() }
            .ifBlank { callId }
        when (action) {
            ACTION_INCOMING -> {
                BeamioTelecomService.forceClearStickyVoiceStateForSmoke(app)
                // QA-only claimedTag — product truth is verify+lookup; this only
                // proves CallStyle/Activity main line refreshes to @tag under lock.
                val claimedTag = intent.getStringExtra(BeamioTelecomService.EXTRA_CLAIMED_TAG)
                    ?.trim()
                    .orEmpty()
                    .ifBlank { intent.getStringExtra("claimedTag")?.trim().orEmpty() }
                val peer = intent.getStringExtra(BeamioTelecomService.EXTRA_CLAIMED_ADDRESS)
                    ?.trim()
                    .orEmpty()
                    .ifBlank { intent.getStringExtra("peerAddress")?.trim().orEmpty() }
                Log.i(
                    TAG,
                    "Smoke incoming wake callIdPresent=${callId.isNotBlank()} " +
                        "claimedTagPresent=${claimedTag.isNotBlank()}",
                )
                if (claimedTag.isNotBlank()) {
                    BeamioTelecomService.showIncomingCallNotification(
                        app,
                        callId = callId,
                        peerAddress = peer,
                        displayName = claimedTag,
                        sessionId = sessionId,
                        claimedTag = claimedTag,
                        claimedAddress = peer,
                    )
                } else {
                    BeamioTelecomService.showIncomingCallWakeNotification(
                        app,
                        callId,
                        sessionId,
                    )
                }
            }
            ACTION_ANSWER -> {
                Log.i(TAG, "Smoke answer callIdPresent=${callId.isNotBlank()}")
                BeamioTelecomService.completeIncomingUserAction(
                    app,
                    "callAnswered",
                    callId,
                    sessionId,
                    fromTelecom = false,
                )
            }
            else -> Log.w(TAG, "Smoke ignored action=$action")
        }
    }

    companion object {
        const val ACTION_INCOMING = "com.beamio.app.SMOKE_INCOMING_CALL"
        const val ACTION_ANSWER = "com.beamio.app.SMOKE_ANSWER"
        /** @deprecated use [ACTION_INCOMING] */
        const val ACTION = ACTION_INCOMING
        private const val TAG = "BeamioVoiceCall"
    }
}
