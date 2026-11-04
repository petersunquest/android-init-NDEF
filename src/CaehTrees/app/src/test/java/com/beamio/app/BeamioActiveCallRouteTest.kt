package com.beamio.app

import android.content.Intent
import com.beamio.app.BeamioActiveCallRoute.Destroyed
import com.beamio.app.BeamioActiveCallRoute.Present
import com.beamio.app.BeamioActiveCallRoute.Target
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 2026-11-03, Samsung on 1.0.161 test2: tapping the status-bar call pill
 * during a call landed on the PWA home with no call screen and no return pill.
 */
class BeamioActiveCallRouteTest {
    private val flags = BeamioActiveCallRoute.OPEN_MAIN_FLAGS

    @Test
    fun openMainNeverClearsTheTaskAboveIt() {
        // CLEAR_TOP finished InCallActivity, which sits above MainActivity.
        assertEquals(0, flags and Intent.FLAG_ACTIVITY_CLEAR_TOP)
        assertEquals(0, flags and Intent.FLAG_ACTIVITY_CLEAR_TASK)
    }

    @Test
    fun openMainReusesTheExistingMainActivity() {
        // Without REORDER_TO_FRONT a second singleTop MainActivity would stack on the call screen.
        assertTrue(flags and Intent.FLAG_ACTIVITY_REORDER_TO_FRONT != 0)
        assertTrue(flags and Intent.FLAG_ACTIVITY_SINGLE_TOP != 0)
        assertTrue(flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }

    @Test
    fun aShellCallGoesToTheNativeScreen() {
        assertEquals(Target.NATIVE_IN_CALL, BeamioActiveCallRoute.target(nativeCallLive = true))
        assertEquals(Target.PWA, BeamioActiveCallRoute.target(nativeCallLive = false))
    }

    @Test
    fun aHiddenCallScreenIsStartedAgain() {
        // MainActivity reordered above it: rendering in place would stay invisible.
        assertEquals(Present.START, BeamioActiveCallRoute.present(instanceAlive = true, instanceResumed = false))
        assertEquals(Present.START, BeamioActiveCallRoute.present(instanceAlive = false, instanceResumed = false))
        assertEquals(Present.RENDER_IN_PLACE, BeamioActiveCallRoute.present(instanceAlive = true, instanceResumed = true))
    }

    @Test
    fun callScreenGoneMidCallCountsAsMinimized() {
        // The test2 case: destroyed while "presented", call still live.
        assertEquals(Destroyed.MARK_MINIMIZED, BeamioActiveCallRoute.onDestroyed(callLive = true, presented = true, changingConfigurations = false))
        // The Minimize button already marked it.
        assertEquals(Destroyed.KEEP, BeamioActiveCallRoute.onDestroyed(callLive = true, presented = false, changingConfigurations = false))
        // Rotation or similar recreates it at once.
        assertEquals(Destroyed.KEEP, BeamioActiveCallRoute.onDestroyed(callLive = true, presented = true, changingConfigurations = true))
    }

    @Test
    fun callOverRestoresTheAudioRoute() {
        assertEquals(Destroyed.RESTORE_ROUTE, BeamioActiveCallRoute.onDestroyed(callLive = false, presented = true, changingConfigurations = false))
        assertEquals(Destroyed.RESTORE_ROUTE, BeamioActiveCallRoute.onDestroyed(callLive = false, presented = false, changingConfigurations = false))
    }
}
