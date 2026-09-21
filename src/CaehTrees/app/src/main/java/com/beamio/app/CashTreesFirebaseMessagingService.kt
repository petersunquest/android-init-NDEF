package com.beamio.app

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import android.util.Log

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
                "FCM voice call received callIdPresent=${callId.isNotBlank()} " +
                    "sessionIdPresent=${data["sessionId"]?.isNullOrBlank() == false}",
            )
            if (callId.isNotEmpty()) {
                BeamioTelecomService.reportIncoming(
                    applicationContext,
                    callId,
                    data["peerAddress"]?.trim().orEmpty().ifBlank {
                        data["callerEoa"]?.trim().orEmpty()
                    },
                    data["displayName"]?.trim().orEmpty().ifBlank {
                        callId.takeIf { it.isNotBlank() }?.let { "@$it" }
                            ?: data["callerEoa"].orEmpty()
                    },
                    data["sessionId"]?.trim().orEmpty(),
                )
            } else {
                Log.w(TAG, "FCM voice call ignored: missing callId")
            }
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
