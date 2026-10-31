package com.beamio.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.core.content.ContextCompat

/**
 * Runtime RECORD_AUDIO for native temporary-channel mic uplink.
 *
 * Telecom Answer → [BeamioNativeVoiceSignaling.sendAccept] starts PCM capture
 * without WebView getUserMedia, so the OS never prompts via
 * [android.webkit.PermissionRequest]. Callers must request here and retry
 * capture after grant.
 */
object BeamioVoiceMicPermission {
    private const val TAG = "BeamioVoiceMicPerm"

    fun has(context: Context): Boolean =
        ContextCompat.checkSelfPermission(
            context.applicationContext,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED

    /**
     * If already granted, runs [onAlreadyGranted] immediately.
     * Otherwise launches the system dialog via [launcher].
     */
    fun requestIfNeeded(
        activity: ComponentActivity,
        launcher: ActivityResultLauncher<String>,
        onAlreadyGranted: () -> Unit,
    ) {
        if (activity.isFinishing) return
        if (has(activity)) {
            onAlreadyGranted()
            return
        }
        Log.i(TAG, "requesting RECORD_AUDIO for voice uplink")
        runCatching { launcher.launch(Manifest.permission.RECORD_AUDIO) }
            .onFailure { Log.w(TAG, "launch RECORD_AUDIO failed: ${it.message}") }
    }
}
