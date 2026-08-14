package com.beamio.app.embedded

import android.content.Context
import org.json.JSONObject
import java.io.File

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
            val bundledDir = File(rootDir, "bundled")
            if (bundledDir.exists()) {
                bundledDir.deleteRecursively()
            }
            bundledDir.mkdirs()
            appContext.assets.open(EmbeddedPwaConstants.BUNDLE_ASSET_NAME).use { input ->
                EmbeddedPwaZip.unzip(input, bundledDir)
            }
            if (!hasValidBundle(bundledDir)) {
                bundledDir.deleteRecursively()
                if (hasValidBundle(activeDir)) return
                throw IllegalStateException("Bundled SilentPassUI.zip did not contain index.html")
            }

            val activeIsValid = hasValidBundle(activeDir)
            val activeVersion = if (activeIsValid) readUpdateInfo(activeDir)?.ver else null
            val bundledVersion = readUpdateInfo(bundledDir)?.ver
            val shouldInstallBundled =
                !activeIsValid ||
                    (activeVersion != null &&
                        bundledVersion != null &&
                        isSemverNewer(activeVersion, bundledVersion))

            if (!shouldInstallBundled) {
                bundledDir.deleteRecursively()
                return
            }
            if (activeDir.exists()) {
                activeDir.deleteRecursively()
            }
            if (!bundledDir.renameTo(activeDir)) {
                bundledDir.deleteRecursively()
                throw IllegalStateException("Failed to activate bundled SilentPassUI.zip")
            }
        }
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
            if (backupDir.exists()) {
                backupDir.deleteRecursively()
            }
            if (activeDir.exists()) {
                activeDir.renameTo(backupDir)
            }
            if (!stagingDir.renameTo(activeDir)) {
                throw IllegalStateException("Failed to promote staged PWA update")
            }
            pendingVersion = null
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
