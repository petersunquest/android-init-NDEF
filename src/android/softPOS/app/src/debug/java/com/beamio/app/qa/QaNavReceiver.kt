package com.beamio.app.qa

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.beamio.app.MainActivity

/**
 * Debug/QA only. `adb shell am broadcast -a com.beamio.app.QA_NAV --es url <https url>` asks the
 * POS WebView to navigate its main frame to <url>; the navigation then goes through the normal
 * shouldOverrideUrlLoading policy. URLs outside QaNavPolicy.ALLOWED_HOSTS are ignored and logged.
 */
class QaNavReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (val decision = QaNavPolicy.decide(intent.getStringExtra("url"))) {
            is QaNavPolicy.Decision.Ignore -> {
                Log.w("BeamioPOS-QA", "ignored QA_NAV: ${decision.reason}")
            }
            is QaNavPolicy.Decision.Accept -> {
                val activity = MainActivity.devActivity
                if (activity == null) {
                    Log.w("BeamioPOS-QA", "no active MainActivity")
                    return
                }
                Log.i("BeamioPOS-QA", "trigger main-frame navigation to ${decision.url}")
                activity.devNavigateMainFrame(decision.url)
            }
        }
    }
}
