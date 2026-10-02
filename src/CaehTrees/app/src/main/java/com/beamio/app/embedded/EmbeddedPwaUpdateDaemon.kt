package com.beamio.app.embedded

import android.util.Log
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Polls `https://beamio.app/app/update.json`, downloads newer bundles into `staging/`. */
class EmbeddedPwaUpdateDaemon(
    private val bundleStore: EmbeddedPwaBundleStore,
    private val onUpdateAvailable: (currentVer: String, pendingVer: String) -> Unit,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val checkInFlight = AtomicBoolean(false)
    @Volatile
    private var stopped = false

    fun start() {
        stopped = false
        Log.i(TAG, "OTA daemon started manifest=${EmbeddedPwaConstants.REMOTE_UPDATE_MANIFEST}")
        scheduleNext(0L)
    }

    fun stop() {
        stopped = true
        Log.i(TAG, "OTA daemon stopped")
        mainHandler.removeCallbacksAndMessages(null)
    }

    fun checkNow() {
        scheduleNext(0L)
    }

    private fun scheduleNext(delayMs: Long) {
        if (stopped) return
        mainHandler.postDelayed({
            if (stopped) return@postDelayed
            executor.execute {
                try {
                    performCheck()
                } finally {
                    if (!stopped) {
                        mainHandler.post { scheduleNext(CHECK_INTERVAL_MS) }
                    }
                }
            }
        }, delayMs)
    }

    private fun performCheck() {
        if (!checkInFlight.compareAndSet(false, true)) return
        try {
            Log.i(TAG, "OTA check begin active=${bundleStore.activeVersion()} pending=${bundleStore.pendingUpdateVersion() ?: ""}")
            val remote = fetchRemoteUpdateInfo() ?: run {
                Log.w(TAG, "OTA manifest unavailable")
                return
            }
            val current = bundleStore.activeVersion()
            Log.i(TAG, "OTA manifest ver=${remote.ver} filename=${remote.filename} active=$current")
            if (!EmbeddedPwaBundleStore.isSemverNewer(current, remote.ver)) {
                Log.i(TAG, "OTA no newer version")
                return
            }
            val pending = bundleStore.pendingUpdateVersion()
            if (pending == remote.ver) {
                Log.i(TAG, "OTA staged version still pending=$pending")
                postUpdateAvailable(current, remote.ver)
                return
            }
            Log.i(TAG, "OTA downloading version=${remote.ver}")
            downloadAndStage(remote)
            Log.i(TAG, "OTA staged version=${remote.ver}")
            postUpdateAvailable(current, remote.ver)
        } catch (error: Exception) {
            // Untrusted fetch — keep last trusted bundle; no UI wipe.
            Log.e(TAG, "OTA check failed type=${error.javaClass.simpleName} message=${error.message}", error)
        } finally {
            checkInFlight.set(false)
        }
    }

    private fun fetchRemoteUpdateInfo(): EmbeddedPwaUpdateInfo? {
        val conn = (URL(EmbeddedPwaConstants.REMOTE_UPDATE_MANIFEST).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 30_000
            readTimeout = 30_000
            useCaches = false
            setRequestProperty("Cache-Control", "no-cache")
        }
        return try {
            val responseCode = conn.responseCode
            Log.i(TAG, "OTA manifest response=$responseCode")
            if (responseCode !in 200..299) return null
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val json = JSONObject(body)
            EmbeddedPwaUpdateInfo(
                ver = json.getString("ver"),
                filename = json.getString("filename"),
            )
        } finally {
            conn.disconnect()
        }
    }

    private fun downloadAndStage(remote: EmbeddedPwaUpdateInfo) {
        val downloadUrl = EmbeddedPwaConstants.REMOTE_BUNDLE_BASE + remote.filename
        val conn = (URL(downloadUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 30_000
            readTimeout = 120_000
            useCaches = false
            setRequestProperty("Cache-Control", "no-cache")
        }
        try {
            val responseCode = conn.responseCode
            Log.i(TAG, "OTA download response=$responseCode url=$downloadUrl")
            if (responseCode !in 200..299) {
                throw IllegalStateException("Download failed: HTTP $responseCode")
            }
            val tempZip = File.createTempFile("silentpass_staging_", ".zip")
            try {
                conn.inputStream.use { input ->
                    tempZip.outputStream().use { output -> input.copyTo(output) }
                }
                bundleStore.installDownloadToStaging(tempZip, remote.ver)
            } finally {
                tempZip.delete()
            }
        } finally {
            conn.disconnect()
        }
    }

    private fun postUpdateAvailable(current: String, pending: String) {
        mainHandler.post { onUpdateAvailable(current, pending) }
    }

    companion object {
        private const val TAG = "BeamioEmbeddedPwa"
        private const val CHECK_INTERVAL_MS = 15L * 60L * 1000L
    }
}
