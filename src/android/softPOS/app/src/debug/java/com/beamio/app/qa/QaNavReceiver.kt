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
    override fun onReceive(context: Context, intent: Intent) {
        val url = intent.getStringExtra("url")?.trim().orEmpty()
        if (!url.startsWith("https://")) {
            Log.w("BeamioPOS-QA", "rejected url (https only)")
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
