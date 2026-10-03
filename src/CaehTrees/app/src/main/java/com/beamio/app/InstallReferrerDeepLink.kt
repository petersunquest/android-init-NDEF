package com.beamio.app

import android.content.Context
import android.net.Uri
import android.util.Log
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener

/**
 * Deferred deep link after a Play Store install.
 *
 * The share landing opens Play with `referrer=beamio_dl=<inner /app/ URL>`. On the first
 * launch of a fresh install we read that referrer once and hand the merchant / coupon URL
 * to the embedded PWA, so onboarding can finish on the merchant detail page.
 */
object InstallReferrerDeepLink {
    private const val TAG = "BeamioInstallReferrer"
    private const val PREFS = "beamio_install_referrer"
    private const val KEY_CHECKED = "checked"

    /** Ignore referrers of old installs (app updated long after install). */
    private const val MAX_INSTALL_AGE_MS = 7L * 24 * 60 * 60 * 1000

    /**
     * Reads the install referrer at most once per install. [onLink] runs on a background
     * thread with the HTTPS `/app/` URL; callers must hop to the main thread.
     */
    fun consumeOnce(context: Context, onLink: (Uri) -> Unit) {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(KEY_CHECKED, false)) return
        if (!isFreshInstall(app)) {
            prefs.edit().putBoolean(KEY_CHECKED, true).apply()
            return
        }
        val client = InstallReferrerClient.newBuilder(app).build()
        try {
            client.startConnection(
                object : InstallReferrerStateListener {
                    override fun onInstallReferrerSetupFinished(responseCode: Int) {
                        try {
                            when (responseCode) {
                                InstallReferrerClient.InstallReferrerResponse.OK -> {
                                    prefs.edit().putBoolean(KEY_CHECKED, true).apply()
                                    val link =
                                        BeamioDeepLink.resolveInstallReferrer(
                                            client.installReferrer.installReferrer,
                                        )
                                    if (link != null) onLink(link)
                                }
                                // Not retryable: nothing will ever be available on this device.
                                InstallReferrerClient.InstallReferrerResponse.FEATURE_NOT_SUPPORTED ->
                                    prefs.edit().putBoolean(KEY_CHECKED, true).apply()
                                // SERVICE_UNAVAILABLE / DEVELOPER_ERROR: retry on next launch.
                                else -> Log.w(TAG, "install referrer unavailable: $responseCode")
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "install referrer read failed", e)
                        } finally {
                            try {
                                client.endConnection()
                            } catch (_: Exception) {
                            }
                        }
                    }

                    override fun onInstallReferrerServiceDisconnected() {
                        // Retry on next launch; never block startup.
                    }
                },
            )
        } catch (e: Exception) {
            Log.w(TAG, "install referrer connect failed", e)
        }
    }

    private fun isFreshInstall(context: Context): Boolean =
        try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            System.currentTimeMillis() - info.firstInstallTime < MAX_INSTALL_AGE_MS
        } catch (_: Exception) {
            false
        }
}
