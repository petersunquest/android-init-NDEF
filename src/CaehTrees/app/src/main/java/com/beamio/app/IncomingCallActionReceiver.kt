package com.beamio.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Handles Decline / Answer from [NotificationCompat.CallStyle] action buttons.
 * Runs even when MainActivity is not in the foreground.
 */
class IncomingCallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return
        val callId = intent.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
        val sessionId = intent.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
        if (callId.isBlank()) {
            Log.w(TAG, "Ignoring call action without callId")
            return
        }
        val action = when (intent.action) {
            BeamioTelecomService.ACTION_ANSWER -> "callAnswered"
            BeamioTelecomService.ACTION_DECLINE -> "callRejected"
            BeamioTelecomService.ACTION_HANGUP -> "callEnded"
            BeamioTelecomService.ACTION_MUTE -> {
                Log.i(TAG, "CallStyle action=mute")
                BeamioTelecomService.silenceIncomingWindow(
                    context.applicationContext,
                    callId,
                    sessionId,
                )
                return
            }
            else -> return
        }
        Log.i(TAG, "CallStyle action=$action callIdPresent=true")
        BeamioTelecomService.completeIncomingUserAction(
            context.applicationContext,
            action,
            callId,
            sessionId,
            fromTelecom = false,
        )
    }

    companion object {
        private const val TAG = "BeamioVoiceCall"
    }
}
