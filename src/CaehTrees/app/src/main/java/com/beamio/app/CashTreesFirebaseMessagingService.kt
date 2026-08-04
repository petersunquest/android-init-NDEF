package com.beamio.app

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
        if (type != "chatBadge" && type != "syncChatBadge") return
        val badgeRaw = data["badge"] ?: data["unread"] ?: return
        val badge = badgeRaw.toIntOrNull()?.coerceIn(0, 999) ?: return
        CashTreesNativeAppStateBridge.applyAppIconBadge(applicationContext, badge)
    }
}
