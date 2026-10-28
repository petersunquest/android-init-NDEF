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
        BeamioGuardianRoster.kick(this)
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
            if (BeamioTelecomService.wasBusyRejected(callId, sessionId)) return
            // Claim or busy-reject before any encryption WebView. A second call
            // must not open OpenPgp while the first glass window is up.
            BeamioTelecomService.showIncomingCallWakeNotification(
                applicationContext,
                callId,
                sessionId,
            )
            if (BeamioTelecomService.wasBusyRejected(callId, sessionId)) return
            // Prefetch offerArmor → sessionKey BEFORE CallStyle so Decline can
            // AES-encrypt voice_call_reject_v1 (same race as iOS PushKit).
            // FCM stays opaque (no caller identity in push); resolve upgrades title.
            if (callId.isNotBlank()) {
                BeamioVoiceOfferIdentity.scheduleResolveDelayed(
                    applicationContext,
                    callId,
                    sessionId,
                    delayMs = 0L,
                ) { identity ->
                    // Upgrade the same small incoming window to @BeamioTag.
                    val tag = identity.beamioTag.orEmpty()
                    val display = tag.ifBlank { identity.shortAddress }
                    BeamioTelecomService.showIncomingCallNotification(
                        applicationContext,
                        callId = identity.callId,
                        peerAddress = identity.callerEoa,
                        displayName = display,
                        sessionId = identity.sessionId,
                        claimedTag = tag,
                        claimedAddress = identity.callerEoa,
                    )
                }
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
