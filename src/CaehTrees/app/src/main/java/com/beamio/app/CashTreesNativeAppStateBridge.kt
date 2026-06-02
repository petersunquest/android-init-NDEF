package com.beamio.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONObject

/**
 * PWA → Native generic app state (footer badges, launcher icon badge).
 * Mirrors iOS [CashTreesNativeAppStateBridge.swift].
 */
object CashTreesNativeAppStateBridge {
    private const val BADGE_CHANNEL_ID = "app_icon_badge"
    private const val BADGE_NOTIFICATION_ID = 9001

    /** Accepts full bridge payload `{ action, state }` or bare `{ footerBadges, appIconBadge }`. */
    fun applyFromJsonString(context: Context, json: String) {
        val trimmed = json.trim()
        if (trimmed.isEmpty()) return
        try {
            val root = JSONObject(trimmed)
            val state = when {
                root.has("state") && !root.isNull("state") -> root.optJSONObject("state")
                root.has("footerBadges") || root.has("appIconBadge") -> root
                else -> null
            }
            applyFromWebPayload(context, state)
        } catch (_: Exception) {
        }
    }

    fun applyFromWebPayload(context: Context, state: JSONObject?) {
        applyAppIconBadge(context, resolveAppIconBadge(state))
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

    fun applyAppIconBadge(context: Context, count: Int) {
        val safe = count.coerceIn(0, 999)
        ensureBadgeChannel(context)
        val nm = NotificationManagerCompat.from(context)
        if (safe <= 0) {
            nm.cancel(BADGE_NOTIFICATION_ID)
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
}
