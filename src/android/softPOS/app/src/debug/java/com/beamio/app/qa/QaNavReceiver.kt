package com.beamio.app.qa

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.beamio.app.MainActivity

/**
 * Debug/QA only. `adb shell am broadcast -a com.beamio.app.QA_NAV --es url <https url>` asks the
 * POS WebView to navigate its main frame to <url>; the navigation then goes through the normal
 * shouldOverrideUrlLoading policy. Not compiled into release or store builds.
 */
class QaNavReceiver : BroadcastReceiver() {
    private companion object {
        val ALLOWED_HOSTS = setOf("beamio.app", "www.beamio.app", "pos.beamio.app", "beamio.ca", "www.beamio.ca", "pos.beamio.ca")
    }

    override fun onReceive(context: Context, intent: Intent) {
        val url = intent.getStringExtra("url")?.trim().orEmpty()
        val host = android.net.Uri.parse(url).host?.lowercase().orEmpty()
        // Debug-only allowlist: this receiver is exported for adb, so it only accepts Beamio hosts.
        if (!url.startsWith("https://") || host !in ALLOWED_HOSTS) {
            Log.w("BeamioPOS-QA", "rejected url (https Beamio hosts only)")
            return
        }
        val activity = MainActivity.devActivity
        if (activity == null) {
            Log.w("BeamioPOS-QA", "no active MainActivity")
            return
        }
        Log.i("BeamioPOS-QA", "trigger main-frame navigation to $url")
        activity.devNavigateMainFrame(url)
    }
}
