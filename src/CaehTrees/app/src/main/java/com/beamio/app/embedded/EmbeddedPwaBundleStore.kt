package com.beamio.app.embedded

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.security.DigestInputStream
import java.security.MessageDigest

/** Documents-backed PWA bundle: `active/` (live), `staging/` (downloaded), `backup/` (rollback). */
class EmbeddedPwaBundleStore(context: Context) {
    private val appContext = context.applicationContext
    private val lock = Any()

    val rootDir: File = File(appContext.filesDir, EmbeddedPwaConstants.ROOT_DIR_NAME)
    val activeDir: File = File(rootDir, "active")
    val stagingDir: File = File(rootDir, "staging")
    val backupDir: File = File(rootDir, "backup")

    @Volatile
    private var pendingVersion: String? = readPendingVersionFromStaging()

    fun bootstrapIfNeeded() {
        synchronized(lock) {
            rootDir.mkdirs()
            recoverInterruptedSwapLocked()
            promoteStagingIfNewerLocked()
            val bundledDir = File(rootDir, "bundled")
            if (bundledDir.exists()) {
                bundledDir.deleteRecursively()
            }
            bundledDir.mkdirs()
            val digest = MessageDigest.getInstance("SHA-256")
            appContext.assets.open(EmbeddedPwaConstants.BUNDLE_ASSET_NAME).use { input ->
                DigestInputStream(input, digest).use { hashed ->
                    EmbeddedPwaZip.unzip(hashed, bundledDir)
                }
            }
            val assetHash = digest.digest().joinToString("") { byte -> "%02x".format(byte) }
            if (!hasValidBundle(bundledDir)) {
                bundledDir.deleteRecursively()
                if (hasValidBundle(activeDir)) return
                throw IllegalStateException("Bundled SilentPassUI.zip did not contain index.html")
            }

            val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val lastAssetHash = prefs.getString(KEY_ACTIVATED_ASSET_SHA256, null)
            val activeIsValid = hasValidBundle(activeDir)
            val activeVersion = if (activeIsValid) readUpdateInfo(activeDir)?.ver else null
            val bundledVersion = readUpdateInfo(bundledDir)?.ver
            val contentChanged = assetHash != lastAssetHash
            val versionNewer =
                activeVersion != null &&
                    bundledVersion != null &&
                    isSemverNewer(activeVersion, bundledVersion)
            // Equal semver must still replace when the APK zip bytes changed.
            // A newer OTA (active semver > bundled) is left in place.
            val sameVersionNewBytes =
                activeVersion != null &&
                    bundledVersion != null &&
                    activeVersion == bundledVersion &&
                    contentChanged
            val shouldInstallBundled = !activeIsValid || versionNewer || sameVersionNewBytes
            Log.i(
                TAG,
                "bootstrap active=$activeVersion bundled=$bundledVersion " +
                    "contentChanged=$contentChanged install=$shouldInstallBundled",
            )

            if (!shouldInstallBundled) {
                bundledDir.deleteRecursively()
                return
            }
            if (!replaceActiveWithDirectoryLocked(bundledDir)) {
                bundledDir.deleteRecursively()
                throw IllegalStateException("Failed to activate bundled SilentPassUI.zip")
            }
            prefs.edit().putString(KEY_ACTIVATED_ASSET_SHA256, assetHash).apply()
            Log.i(TAG, "bootstrap activated bundled=$bundledVersion")
        }
    }

    /**
     * Activate an OTA bundle that was downloaded before the process was
     * stopped. This keeps a staged update from waiting for an APK restart.
     */
    private fun promoteStagingIfNewerLocked(): Boolean {
        if (!hasValidBundle(stagingDir)) return false
        val stagedVersion = readUpdateInfo(stagingDir)?.ver ?: return false
        val activeVersion = readUpdateInfo(activeDir)?.ver
        if (activeVersion != null && !isSemverNewer(activeVersion, stagedVersion)) {
            return false
        }
        if (!replaceActiveWithDirectoryLocked(stagingDir)) return false
        pendingVersion = null
        return true
    }

    fun activeVersion(): String = readUpdateInfo(activeDir)?.ver ?: "0.0.0"

    fun installDownloadToStaging(zipFile: File, expectedVersion: String) {
        synchronized(lock) {
            if (stagingDir.exists()) {
                stagingDir.deleteRecursively()
            }
            stagingDir.mkdirs()
            zipFile.inputStream().use { input ->
                EmbeddedPwaZip.unzip(input, stagingDir)
            }
            if (!hasValidBundle(stagingDir)) {
                stagingDir.deleteRecursively()
                pendingVersion = null
                throw IllegalStateException("Downloaded bundle missing index.html")
            }
            // Ensure staging carries version metadata for cold-start pending restore.
            File(stagingDir, "update.json").writeText(
                JSONObject()
                    .put("ver", expectedVersion)
                    .put("filename", "SilentPassUI-$expectedVersion.zip")
                    .toString(),
            )
            pendingVersion = expectedVersion
        }
    }

    fun promoteStagingToActive() {
        synchronized(lock) {
            if (!hasValidBundle(stagingDir)) {
                throw IllegalStateException("No staged PWA update")
            }
            if (!replaceActiveWithDirectoryLocked(stagingDir)) {
                throw IllegalStateException("Failed to promote staged PWA update")
            }
            pendingVersion = null
        }
    }

    /**
     * Replace the active bundle without ever deleting it first.
     *
     * Both directories live under the same app-private filesystem, so renameTo
     * is the closest available atomic commit primitive. If the process dies
     * between the two renames, bootstrapIfNeeded() restores backupDir.
     */
    private fun replaceActiveWithDirectoryLocked(candidateDir: File): Boolean {
        if (!hasValidBundle(candidateDir)) return false
        if (backupDir.exists() && !backupDir.deleteRecursively()) return false

        val hadActive = activeDir.exists()
        if (hadActive && !activeDir.renameTo(backupDir)) return false
        if (candidateDir.renameTo(activeDir)) {
            return true
        }

        if (hadActive && !activeDir.exists() && backupDir.exists()) {
            backupDir.renameTo(activeDir)
        }
        return false
    }

    /** Recover a crash after active→backup but before candidate→active. */
    private fun recoverInterruptedSwapLocked() {
        if (!hasValidBundle(activeDir) && hasValidBundle(backupDir)) {
            backupDir.renameTo(activeDir)
        }
    }

    fun pendingUpdateVersion(): String? {
        synchronized(lock) {
            if (pendingVersion == null || !hasValidBundle(stagingDir)) return null
            return pendingVersion
        }
    }

    private fun hasValidBundle(dir: File): Boolean =
        File(dir, "index.html").isFile

    private fun readUpdateInfo(dir: File): EmbeddedPwaUpdateInfo? {
        val file = File(dir, "update.json")
        if (!file.isFile) return null
        return try {
            val json = JSONObject(file.readText())
            EmbeddedPwaUpdateInfo(
                ver = json.getString("ver"),
                filename = json.getString("filename"),
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun readPendingVersionFromStaging(): String? {
        if (!hasValidBundle(stagingDir)) return null
        return readUpdateInfo(stagingDir)?.ver
    }

    companion object {
        private const val TAG = "BeamioEmbeddedPwa"
        private const val PREFS_NAME = "embedded_pwa_bundle"
        private const val KEY_ACTIVATED_ASSET_SHA256 = "activated_asset_sha256"

        fun isSemverNewer(oldVer: String, newVer: String): Boolean {
            val oldParts = oldVer.split('.').map { it.toIntOrNull() ?: 0 }
            val newParts = newVer.split('.').map { it.toIntOrNull() ?: 0 }
            val count = maxOf(oldParts.size, newParts.size)
            for (i in 0 until count) {
                val o = oldParts.getOrElse(i) { 0 }
                val n = newParts.getOrElse(i) { 0 }
                if (n > o) return true
                if (n < o) return false
            }
            return false
        }
    }
}
