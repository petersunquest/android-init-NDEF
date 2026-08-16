package com.beamio.app.embedded

import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Polls `https://pos.beamio.app/update.json`, downloads newer bundles into `staging/`. */
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
        scheduleNext(0L)
    }

    fun stop() {
        stopped = true
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
            val remote = fetchRemoteUpdateInfo() ?: return
            val current = bundleStore.activeVersion()
            if (!EmbeddedPwaBundleStore.isSemverNewer(current, remote.ver)) return
            val pending = bundleStore.pendingUpdateVersion()
            if (pending == remote.ver) {
                postUpdateAvailable(current, remote.ver)
                return
            }
            downloadAndStage(remote)
            postUpdateAvailable(current, remote.ver)
        } catch (_: Exception) {
            // Untrusted fetch — keep last trusted bundle; no UI wipe.
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
            if (conn.responseCode !in 200..299) return null
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
            if (conn.responseCode !in 200..299) {
                throw IllegalStateException("Download failed: HTTP ${conn.responseCode}")
            }
            val tempZip = File.createTempFile("beamio_pos_staging_", ".zip")
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
        private const val CHECK_INTERVAL_MS = 15L * 60L * 1000L
    }
}
