package com.beamio.app

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
import android.util.Log
import org.json.JSONObject

/**
 * Can pushes reach this app while it is not running?
 *
 * When the user force-stops Beamio, or the phone puts it in Samsung "Deep
 * sleeping apps" (or Android's "Restricted" battery mode), Google Play services
 * cannot deliver the FCM broadcast (`result=CANCELLED`): no message notification
 * and no incoming call until Beamio is opened again. The app cannot work around
 * this; it can only notice it on the next open and tell the user how to fix it.
 *
 * Checked when MainActivity resumes; the PWA shows the banner. Nothing leaves
 * the device.
 */
object BeamioDeliveryHealth {
    private const val TAG = "BeamioDeliveryHealth"
    private const val PREFS = "beamio_delivery_health"
    private const val KEY_DISMISSED_STOP = "dismissedForceStop"

    data class Report(
        /** User or system restricted background use (Android "Restricted", Samsung deep sleep). */
        val backgroundRestricted: Boolean,
        /** This process started after a force stop the user has not dismissed yet. */
        val forceStopped: Boolean,
        val vendor: String,
        val standbyBucket: Int,
        val ignoringBatteryOptimizations: Boolean,
        /** Stable id of the force stop, for [dismissForceStop]. */
        val forceStopKey: String,
    ) {
        val needsAttention: Boolean get() = backgroundRestricted || forceStopped

        fun toJson(): JSONObject = JSONObject()
            .put("action", "deliveryHealth")
            .put("backgroundRestricted", backgroundRestricted)
            .put("forceStopped", forceStopped)
            .put("vendor", vendor)
            .put("standbyBucket", standbyBucket)
            .put("ignoringBatteryOptimizations", ignoringBatteryOptimizations)
            .put("needsAttention", needsAttention)
    }

    fun check(context: Context): Report {
        val app = context.applicationContext
        val am = app.getSystemService(ActivityManager::class.java)
        val restricted = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            runCatching { am?.isBackgroundRestricted == true }.getOrDefault(false)
        val bucket = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            runCatching {
                app.getSystemService(android.app.usage.UsageStatsManager::class.java)?.appStandbyBucket ?: 0
            }.getOrDefault(0)
        } else {
            0
        }
        val ignoring = runCatching {
            app.getSystemService(android.os.PowerManager::class.java)
                ?.isIgnoringBatteryOptimizations(app.packageName) == true
        }.getOrDefault(false)
        val stopKey = forceStopKey(app, am)
        val dismissed = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_DISMISSED_STOP, "")
        val report = Report(
            backgroundRestricted = restricted,
            forceStopped = stopKey.isNotEmpty() && stopKey != dismissed,
            vendor = Build.MANUFACTURER.orEmpty().trim().lowercase(),
            standbyBucket = bucket,
            ignoringBatteryOptimizations = ignoring,
            forceStopKey = stopKey,
        )
        Log.i(
            TAG,
            "restricted=$restricted forceStop=${stopKey.isNotEmpty()} shown=${report.forceStopped} " +
                "bucket=$bucket ignoringOpt=$ignoring vendor=${report.vendor}",
        )
        return report
    }

    /** The user closed the force-stop notice: do not show it again for this stop. */
    fun dismissForceStop(context: Context) {
        val app = context.applicationContext
        val key = forceStopKey(app, app.getSystemService(ActivityManager::class.java))
        if (key.isEmpty()) return
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_DISMISSED_STOP, key).apply()
    }

    /**
     * Non-empty when the current process started after a force stop.
     * Android 15+: [android.app.ApplicationStartInfo.wasForceStopped] of the newest
     * cold start (cold-start records carry pid 0 on Android 17 / One UI 9). On
     * One UI 9 that flag stays true on later cold starts after one force stop
     * (a background kill, then the launcher), so a true flag is checked against
     * the last exit of the main process. The exit record alone decides on
     * Android 11–14: a user request whose description names a stop rather than
     * Recents ("remove task") or a background kill. The newest exit record is
     * often the WebView sandbox process, so filter by process name.
     */
    private fun forceStopKey(context: Context, am: ActivityManager?): String {
        am ?: return ""
        // Wall-clock second this process started: one key per process.
        val processKey = (System.currentTimeMillis() -
            (android.os.SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime())) / 1000
        val exitKey = lastExitForceStopKey(context, am)
        if (Build.VERSION.SDK_INT >= 35) {
            val start = runCatching {
                am.getHistoricalProcessStartReasons(10).firstOrNull {
                    it.startType == android.app.ApplicationStartInfo.START_TYPE_COLD &&
                        (it.pid == 0 || it.pid == Process.myPid())
                }
            }.getOrNull()
            if (start != null) return combineForceStop(start.wasForceStopped(), exitKey, processKey)
        }
        return combineForceStop(null, exitKey, processKey)
    }

    /**
     * Last exit of the main process (not this one): "exit:<ms>" when it was a
     * force stop, "" when it was something else, null when there is no record
     * (or before Android 11).
     */
    private fun lastExitForceStopKey(context: Context, am: ActivityManager): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val exit = runCatching {
            am.getHistoricalProcessExitReasons(context.packageName, 0, 10).firstOrNull {
                it.processName == context.packageName && it.pid != Process.myPid()
            }
        }.getOrNull() ?: return null
        return if (exitWasForceStop(exit.reason == ApplicationExitInfo.REASON_USER_REQUESTED, exit.description)) {
            "exit:${exit.timestamp}"
        } else {
            ""
        }
    }

    /** A user-requested exit that names a stop: not Recents ("remove task") and not "kill background". */
    internal fun exitWasForceStop(userRequested: Boolean, description: String?): Boolean {
        if (!userRequested) return false
        val d = description.orEmpty().lowercase()
        if (d.contains("remove task") || d.contains("kill background")) return false
        return d.contains("stop")
    }

    /**
     * [startForceStopped]: the newest cold start's flag (null when unknown).
     * [exitKey]: [lastExitForceStopKey]. The exit record wins when both exist,
     * and its key stays the same for one stop, so "Got it" covers later starts too.
     */
    internal fun combineForceStop(startForceStopped: Boolean?, exitKey: String?, processKey: Long): String =
        when (startForceStopped) {
            false -> ""
            true -> exitKey ?: "start:$processKey"
            null -> exitKey.orEmpty()
        }

    /**
     * Opens the setting that lets Beamio receive pushes again. Samsung: the
     * "Never sleeping apps" list (developer.samsung.com/mobile/app-management.html,
     * activity_type 0 sleeping / 1 deep sleeping / 2 never sleeping). Elsewhere, or
     * when that screen is missing: the app's info page (Battery → Unrestricted).
     * Returns which screen opened.
     */
    fun openFixSettings(activity: Activity): String {
        if (Build.MANUFACTURER.equals("samsung", ignoreCase = true)) {
            val samsung = Intent("com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY")
                .setPackage("com.samsung.android.lool")
                .putExtra("activity_type", 2)
                // Device care may already be open on another list (its task comes
                // to the front and ignores activity_type); start it fresh.
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            try {
                activity.startActivity(samsung)
                return "samsungNeverSleeping"
            } catch (e: ActivityNotFoundException) {
                Log.i(TAG, "Samsung app list not available; app info instead")
            } catch (e: SecurityException) {
                Log.w(TAG, "Samsung app list refused: ${e.message}")
            }
        }
        return try {
            activity.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null)),
            )
            "appDetails"
        } catch (e: Exception) {
            Log.w(TAG, "app info screen failed: ${e.message}")
            "none"
        }
    }
}
