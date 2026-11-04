package com.beamio.app

import android.webkit.PermissionRequest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 2026-11-03, Samsung on 1.0.161 test3: the WebView microphone the PWA opened
 * while a call rang stayed open after the call; the camera could not record.
 */
class BeamioWebMicGateTest {
    private val mic = PermissionRequest.RESOURCE_AUDIO_CAPTURE
    private val cam = PermissionRequest.RESOURCE_VIDEO_CAPTURE

    @Test
    fun onlyAConnectedCallTheShellDoesNotOwnIsThePwas() {
        assertTrue(BeamioWebMicGate.pwaCallLive(telecomCallLive = true, nativeCallLive = false))
        // The shell's own call records with its AudioRecord.
        assertFalse(BeamioWebMicGate.pwaCallLive(telecomCallLive = true, nativeCallLive = true))
        // Ringing or idle: nothing is connected.
        assertFalse(BeamioWebMicGate.pwaCallLive(telecomCallLive = false, nativeCallLive = false))
        assertFalse(BeamioWebMicGate.pwaCallLive(telecomCallLive = false, nativeCallLive = true))
    }

    @Test
    fun ringingPrewarmGetsNoMicrophone() {
        val allowed = BeamioWebMicGate.allowedResources(arrayOf(mic), pwaCallLive = false)
        assertArrayEquals(emptyArray<String>(), allowed)
        assertTrue(BeamioWebMicGate.refusesMicrophone(arrayOf(mic), allowed))
    }

    @Test
    fun aPwaCallGetsTheMicrophone() {
        val allowed = BeamioWebMicGate.allowedResources(arrayOf(mic), pwaCallLive = true)
        assertArrayEquals(arrayOf(mic), allowed)
        assertFalse(BeamioWebMicGate.refusesMicrophone(arrayOf(mic), allowed))
    }

    @Test
    fun cameraRequestsAreUnaffected() {
        // QR scan and photos.
        assertArrayEquals(arrayOf(cam), BeamioWebMicGate.allowedResources(arrayOf(cam), pwaCallLive = false))
        assertFalse(BeamioWebMicGate.refusesMicrophone(arrayOf(cam), arrayOf(cam)))
    }

    @Test
    fun cameraPlusMicrophoneKeepsOnlyTheCameraOutsideAPwaCall() {
        val allowed = BeamioWebMicGate.allowedResources(arrayOf(cam, mic), pwaCallLive = false)
        assertArrayEquals(arrayOf(cam), allowed)
        assertTrue(BeamioWebMicGate.refusesMicrophone(arrayOf(cam, mic), allowed))
        assertArrayEquals(arrayOf(cam, mic), BeamioWebMicGate.allowedResources(arrayOf(cam, mic), pwaCallLive = true))
    }
}
