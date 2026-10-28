package com.beamio.app

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device acceptance: a second incoming call while the glass window is up
 * must busy-reject and leave the first window in place, without opening
 * the OpenPGP WebView.
 */
@RunWith(AndroidJUnit4::class)
class BusyIncomingGuardTest {
    @Test
    fun secondIncomingLeavesFirstWindowAndDefersDecline() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val stamp = System.currentTimeMillis() / 1000
        val callA = "busy-a-$stamp"
        val sessionA = "s-busy-a-$stamp"
        val callB = "busy-b-$stamp"
        val sessionB = "s-busy-b-$stamp"
        val peerA = "0x945d7c1e8a0b4f6d9c2e1a7b5d3f8c0e4a6b4504"

        BeamioTelecomService.reportIncoming(
            context,
            callA,
            peerA,
            "@rr01",
            sessionA,
            "@rr01",
        )
        // Glass extras use the Telecom id (session when present), not the
        // original offer call id.
        val shown = waitUntil(8_000) {
            IncomingCallActivity.isShowing() &&
                IncomingCallActivity.shownCallKeys().contains(sessionA)
        }
        shot("after-a.png")
        assertTrue(
            "first incoming window did not show; showing=${IncomingCallActivity.isShowing()} keys=${IncomingCallActivity.shownCallKeys()}",
            shown,
        )

        BeamioTelecomService.reportIncoming(
            context,
            callB,
            "0x1111111111111111111111111111111111111111",
            "@other",
            sessionB,
            "@other",
        )
        val rejected = waitUntil(4_000) {
            BeamioTelecomService.wasBusyRejected(callB, sessionB)
        }
        Thread.sleep(800)
        val keys = IncomingCallActivity.shownCallKeys()
        shot("after-b.png")

        assertTrue("second call was not busy-rejected", rejected)
        assertTrue("first window lost session; keys=$keys", keys.contains(sessionA))
        assertFalse("second call replaced the window; keys=$keys", keys.contains(callB))
        assertFalse("second session replaced the window; keys=$keys", keys.contains(sessionB))
        assertTrue("glass window closed after the second call", IncomingCallActivity.isShowing())
    }

    private fun shot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: return
        val dir = instrumentation.targetContext.getExternalFilesDir(null) ?: return
        FileOutputStream(File(dir, name)).use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        bitmap.recycle()
    }

    private fun waitUntil(timeoutMs: Long, probe: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (probe()) return true
            Thread.sleep(200)
        }
        return probe()
    }
}
