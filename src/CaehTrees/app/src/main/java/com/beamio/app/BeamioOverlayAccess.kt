package com.beamio.app

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log

/**
 * "Appear on top" (SYSTEM_ALERT_WINDOW) decides whether a call that rings
 * while the phone is unlocked and another app is open gets the full-screen
 * incoming page.
 *
 * Without it, Android 14+ blocks the background activity start, and the
 * system shows a full-screen intent only as a heads-up while the phone is in
 * use. The call then rings as a small system card (Samsung, 1.0.161,
 * 2026-11-03: fresh install, permission never granted). With it, the overlay
 * glass shows over apps, and over Settings the full-screen page opens
 * (BAL_ALLOW_SAW_PERMISSION).
 *
 * The APK cannot grant it; the app asks once, and again after a call actually
 * fell back to the small card (at most once a day).
 */
object BeamioOverlayAccess {
    private const val TAG = "BeamioOverlayAccess"
    private const val PREFS = "beamio_overlay_access"
    private const val KEY_ASKED_AT = "askedAt"
    private const val KEY_FALLBACK_AT = "fallbackAt"

    /** Overlay permissions exist from Android 6 (API 23). */
    const val OVERLAY_SDK = 23
    const val REASK_AFTER_FALLBACK_MS = 24L * 60 * 60 * 1000

    fun granted(context: Context): Boolean =
        Build.VERSION.SDK_INT < OVERLAY_SDK || Settings.canDrawOverlays(context.applicationContext)

    /**
     * Pure rule.
     * - [fullScreenIntentReady]: Android 14+ asks for full-screen intent access
     *   first (it is needed on the lock screen); this waits for the next resume.
     * - [callBusy]: never interrupt a ringing or live call.
     * - [askedAt] 0 = never asked. [fallbackAt] 0 = no call fell back.
     */
    fun shouldAsk(
        sdk: Int,
        overlayGranted: Boolean,
        fullScreenIntentReady: Boolean,
        callBusy: Boolean,
        askedAt: Long,
        fallbackAt: Long,
        now: Long,
    ): Boolean {
        if (sdk < OVERLAY_SDK || overlayGranted) return false
        if (!fullScreenIntentReady || callBusy) return false
        if (askedAt <= 0L) return true
        return fallbackAt > askedAt && now - askedAt >= REASK_AFTER_FALLBACK_MS
    }

    fun shouldAskNow(context: Context, fullScreenIntentReady: Boolean, callBusy: Boolean): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return shouldAsk(
            sdk = Build.VERSION.SDK_INT,
            overlayGranted = granted(context),
            fullScreenIntentReady = fullScreenIntentReady,
            callBusy = callBusy,
            askedAt = prefs.getLong(KEY_ASKED_AT, 0L),
            fallbackAt = prefs.getLong(KEY_FALLBACK_AT, 0L),
            now = System.currentTimeMillis(),
        )
    }

    fun markAsked(context: Context) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong(KEY_ASKED_AT, System.currentTimeMillis()).apply()
    }

    /** An unlocked incoming call could not get the full-screen page for lack of the permission. */
    fun noteFallback(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        // Many present attempts per call; one write per minute is enough.
        if (now - prefs.getLong(KEY_FALLBACK_AT, 0L) < 60_000L) return
        prefs.edit().putLong(KEY_FALLBACK_AT, now).apply()
        Log.i(TAG, "Incoming call without overlay access; will ask again after the call")
    }
}
