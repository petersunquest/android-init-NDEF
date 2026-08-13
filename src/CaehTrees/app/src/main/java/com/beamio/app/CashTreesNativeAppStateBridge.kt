package com.beamio.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONObject

/**
 * PWA → Native generic app state (footer badges, launcher icon badge, background chat local push).
 * Mirrors iOS [CashTreesNativeAppStateBridge.swift].
 */
object CashTreesNativeAppStateBridge {
    private const val BADGE_CHANNEL_ID = "app_icon_badge"
    private const val CHAT_CHANNEL_ID = "beamio_chat_background"
    private const val BADGE_NOTIFICATION_ID = 9001
    private const val CHAT_NOTIFICATION_ID = 9002

    /**
     * Server-side FCM offline badge (`offlineChatPush.ts` → `android.notification`).
     * The tray entry is created by the FCM SDK, so only these identifiers can cancel it;
     * on Android the launcher badge is derived from active notifications, meaning a stale
     * FCM entry keeps the icon number alive even after [applyAppIconBadge] with 0.
     */
    private const val FCM_OFFLINE_CHANNEL_ID = "beamio_chat_offline"
    private const val FCM_OFFLINE_TAG = "beamio_chat_badge"

    /** Accepts full bridge payload `{ action, state }` or bare `{ footerBadges, appIconBadge }`. */
    fun applyFromJsonString(context: Context, json: String) {
        val trimmed = json.trim()
        if (trimmed.isEmpty()) return
        try {
            val root = JSONObject(trimmed)
            val state = when {
                root.has("state") && !root.isNull("state") -> root.optJSONObject("state")
                root.has("footerBadges") || root.has("appIconBadge") || root.has("backgroundChatNotify") -> root
                else -> null
            }
            applyFromWebPayload(context, state)
        } catch (_: Exception) {
        }
    }

    fun applyFromWebPayload(context: Context, state: JSONObject?) {
        val badge = resolveAppIconBadge(state)
        applyAppIconBadge(context, badge)
        val push = state?.optJSONObject("backgroundChatNotify") ?: return
        val present = if (push.has("present")) push.optBoolean("present", true) else true
        if (!present) return
        val title = push.optString("title", "").trim().ifEmpty { "Beamio" }
        val body = push.optString("body", "").trim().ifEmpty { defaultChatBody(badge) }
        presentBackgroundChatNotification(context, badge, title, body)
    }

    /** Explicit bridge: `{ badge, title?, body? }` */
    fun notifyBackgroundChatFromJson(context: Context, json: String) {
        val trimmed = json.trim()
        if (trimmed.isEmpty()) return
        try {
            val root = JSONObject(trimmed)
            val badge = parseNonNegativeInt(root.opt("badge"))
                ?: parseNonNegativeInt(root.opt("appIconBadge"))
                ?: 0
            val title = root.optString("title", "").trim().ifEmpty { "Beamio" }
            val body = root.optString("body", "").trim().ifEmpty { defaultChatBody(badge) }
            applyAppIconBadge(context, badge)
            presentBackgroundChatNotification(context, badge, title, body)
        } catch (_: Exception) {
        }
    }

    private fun defaultChatBody(badge: Int): String {
        if (badge <= 0) return "New message"
        if (badge == 1) return "1 new message"
        return "$badge new messages"
    }

    private fun resolveAppIconBadge(state: JSONObject?): Int {
        if (state == null) return 0
        parseNonNegativeInt(state.opt("appIconBadge"))?.let { return it }
        state.optJSONObject("footerBadges")?.let { footer ->
            parseNonNegativeInt(footer.opt("chat"))?.let { return it }
        }
        return 0
    }

    private fun parseNonNegativeInt(value: Any?): Int? {
        val n = when (value) {
            null, JSONObject.NULL -> return null
            is Int -> value
            is Long -> value.toInt()
            is Double -> value.toInt()
            is Float -> value.toInt()
            is Number -> value.toInt()
            is String -> value.trim().toDoubleOrNull()?.toInt()
            else -> return null
        } ?: return null
        return n.coerceIn(0, 999)
    }

    /**
     * Drop every offline chat alert that contributes to the launcher badge: the local
     * background notification and the FCM tray entry posted while the app was away.
     * Call on foreground so the badge only reflects the PWA unread count.
     */
    fun clearOfflineChatAlerts(context: Context) {
        val nm = NotificationManagerCompat.from(context)
        nm.cancel(CHAT_NOTIFICATION_ID)
        nm.cancel(FCM_OFFLINE_TAG, 0)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        try {
            manager.activeNotifications.forEach { active ->
                val channel = active.notification?.channelId
                if (channel == FCM_OFFLINE_CHANNEL_ID || active.tag == FCM_OFFLINE_TAG) {
                    nm.cancel(active.tag, active.id)
                }
            }
        } catch (_: Exception) {
        }
    }

    fun applyAppIconBadge(context: Context, count: Int) {
        val safe = count.coerceIn(0, 999)
        ensureBadgeChannel(context)
        val nm = NotificationManagerCompat.from(context)
        if (safe <= 0) {
            nm.cancel(BADGE_NOTIFICATION_ID)
            clearOfflineChatAlerts(context)
            return
        }
        if (!nm.areNotificationsEnabled()) return
        val notification = NotificationCompat.Builder(context, BADGE_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setNumber(safe)
            .setContentTitle("")
            .setContentText("")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .build()
        try {
            nm.notify(BADGE_NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS denied on API 33+ — skip badge, keep PWA state intact.
        }
    }

    private fun presentBackgroundChatNotification(
        context: Context,
        badge: Int,
        title: String,
        body: String,
    ) {
        ensureChatChannel(context)
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return
        val notification = NotificationCompat.Builder(context, CHAT_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setNumber(badge.coerceIn(0, 999))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .build()
        try {
            nm.notify(CHAT_NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
        }
    }

    private fun ensureBadgeChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(BADGE_CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            BADGE_CHANNEL_ID,
            "App icon badge",
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "Silent badge count for unread chat"
            setShowBadge(true)
        }
        manager.createNotificationChannel(channel)
    }

    private fun ensureChatChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHAT_CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHAT_CHANNEL_ID,
            "Chat messages",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Local alerts while Beamio is running in the background"
            setShowBadge(true)
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }
}
