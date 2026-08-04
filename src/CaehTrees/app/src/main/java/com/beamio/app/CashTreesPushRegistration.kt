package com.beamio.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging
import org.json.JSONObject

/**
 * FCM device token + PWA identity bind (EOA / pgpKeyId).
 * Mirrors iOS [CashTreesPushRegistration.swift].
 */
object CashTreesPushRegistration {
    private const val PREFS = "cashTrees.push"
    private const val KEY_EOA = "boundEoa"
    private const val KEY_PGP = "boundPgpKeyId"
    private const val KEY_TOKEN = "deviceToken"
    const val REQUEST_POST_NOTIFICATIONS = 4411

    /** MainActivity sets this to forward token → `cashtreesandroid` CustomEvent. */
    @Volatile
    var onTokenForWeb: ((token: String) -> Unit)? = null

    @Volatile
    var lastDeviceToken: String? = null
        private set

    @Volatile
    var boundEoa: String? = null
        private set

    @Volatile
    var boundPgpKeyId: String? = null
        private set

    fun hydrateFromPrefs(context: Context) {
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        boundEoa = p.getString(KEY_EOA, null)?.trim()?.takeIf { it.isNotEmpty() }
        boundPgpKeyId = p.getString(KEY_PGP, null)?.trim()?.takeIf { it.isNotEmpty() }
        lastDeviceToken = p.getString(KEY_TOKEN, null)?.trim()?.takeIf { it.isNotEmpty() }
    }

    /** PWA `bindPushIdentity({ eoa, pgpKeyId? })` — JSON string or object fields via bridge. */
    fun bindIdentity(context: Context, eoa: String?, pgpKeyId: String?) {
        hydrateFromPrefs(context)
        val eoaTrim = eoa?.trim().orEmpty()
        val pgpTrim = pgpKeyId?.trim().orEmpty()
        boundEoa = eoaTrim.takeIf { it.isNotEmpty() }
        boundPgpKeyId = pgpTrim.takeIf { it.isNotEmpty() }
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        p.edit()
            .putString(KEY_EOA, boundEoa)
            .putString(KEY_PGP, boundPgpKeyId)
            .apply()
        requestNotificationPermissionIfNeeded(context)
        fetchAndPublishToken(context)
    }

    fun bindIdentityFromJson(context: Context, json: String) {
        try {
            val root = JSONObject(json.trim().ifEmpty { "{}" })
            bindIdentity(
                context,
                root.optString("eoa", "").ifEmpty { null },
                root.optString("pgpKeyId", "").ifEmpty { null },
            )
        } catch (_: Exception) {
            CashTreesWebConsoleRelay.logNative("bindPushIdentity invalid json")
        }
    }

    fun onNewToken(context: Context, token: String) {
        val trimmed = token.trim()
        if (trimmed.isEmpty()) return
        lastDeviceToken = trimmed
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TOKEN, trimmed)
            .apply()
        notifyListeners(context, trimmed)
    }

    fun payloadForWebEvent(deviceToken: String): JSONObject {
        val payload = JSONObject()
            .put("action", "pushDeviceToken")
            .put("deviceToken", deviceToken)
            .put("platform", "android")
            .put("bundleId", "com.beamio.app")
        boundEoa?.let { payload.put("eoa", it) }
        boundPgpKeyId?.let { payload.put("pgpKeyId", it) }
        return payload
    }

    fun fetchAndPublishToken(context: Context) {
        try {
            FirebaseMessaging.getInstance().token
                .addOnSuccessListener { token ->
                    if (!token.isNullOrBlank()) {
                        onNewToken(context, token)
                    }
                }
                .addOnFailureListener { e ->
                    CashTreesWebConsoleRelay.logNative("FCM token failed: ${e.message}")
                }
        } catch (e: Exception) {
            CashTreesWebConsoleRelay.logNative("FCM unavailable: ${e.message}")
        }
    }

    private fun notifyListeners(context: Context, token: String) {
        try {
            onTokenForWeb?.invoke(token)
        } catch (_: Exception) {
        }
    }

    private fun requestNotificationPermissionIfNeeded(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val activity = context as? Activity ?: return
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_POST_NOTIFICATIONS,
        )
    }

    /** Call from MainActivity after POST_NOTIFICATIONS dialog — re-publish FCM token to PWA. */
    fun onPostNotificationsPermissionResult(context: Context, granted: Boolean) {
        if (!granted) {
            CashTreesWebConsoleRelay.logNative("push POST_NOTIFICATIONS denied")
        }
        // FCM token is available regardless; re-emit so PWA can register after user grants.
        fetchAndPublishToken(context)
    }
}
