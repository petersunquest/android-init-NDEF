package com.beamio.app

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Offline chat badge via FCM.
 * Server sends notification + data when badge > 0 so background/killed apps still
 * get a system tray entry + `notification_count` (launcher badge). Foreground
 * delivery hits [onMessageReceived] and we apply a silent local badge notification.
 */
class CashTreesFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        CashTreesPushRegistration.onNewToken(applicationContext, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val type = data["type"]?.trim().orEmpty()
        Log.i(
            TAG,
            "FCM received type=${type.ifBlank { "<empty>" }} keys=${data.keys.sorted()}",
        )
        if (type == "voiceCall" || type == "beamioVoiceCall") {
            val callId = data["callId"]?.trim().orEmpty()
            Log.i(
                TAG,
                "FCM voice wake received callIdPresent=${callId.isNotBlank()} " +
                    "sessionIdPresent=${data["sessionId"]?.isNullOrBlank() == false}",
            )
            val sessionId = data["sessionId"]?.trim().orEmpty()
            // Mailbox is the wake source. Post a native full-screen call surface
            // immediately, even when the Consumer process/activity was killed.
            // Only opaque call/session handles cross this boundary; caller
            // identity must come from the PWA's verified mailbox message.
            BeamioTelecomService.showIncomingCallWakeNotification(
                applicationContext,
                callId,
                sessionId,
            )
            // FCM is only a wake signal. It does not contain caller identity
            // and must never make the native side pull/decrypt a voice offer.
            return
        }
        if (type != "chatBadge" && type != "syncChatBadge") return
        val badgeRaw = data["badge"] ?: data["unread"] ?: return
        val badge = badgeRaw.toIntOrNull()?.coerceIn(0, 999) ?: return
        CashTreesNativeAppStateBridge.applyAppIconBadge(applicationContext, badge)
    }

    private companion object {
        const val TAG = "BeamioVoiceCall"
    }
}
