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
            try {
                appContext.assets.open(EmbeddedPwaConstants.BUNDLE_ASSET_NAME).use { input ->
                    EmbeddedPwaZip.unzip(input, bundledDir)
                }
            } catch (e: Exception) {
                // Asset read/unzip failure must not hide a usable installed bundle: check
                // active (and a complete staged OTA bundle) BEFORE giving up.
                bundledDir.deleteRecursively()
                if (hasValidBundle(activeDir)) return
                if (hasValidBundle(stagingDir)) {
                    promoteStagingToActive()
                    return
                }
                throw e
            }
            if (!hasValidBundle(bundledDir)) {
                bundledDir.deleteRecursively()
                if (hasValidBundle(activeDir)) return
                // Broken bundled asset: adopt a complete staged OTA bundle if one exists.
                if (hasValidBundle(stagingDir)) {
                    promoteStagingToActive()
                    return
                }
                throw IllegalStateException("Bundled BeamioPOS.zip is incomplete (index.html or referenced JS/CSS missing)")
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
                throw IllegalStateException("Failed to activate bundled BeamioPOS.zip")
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
            File(stagingDir, "update.json").writeText(
                JSONObject()
                    .put("ver", expectedVersion)
                    .put("filename", "BeamioPOS-$expectedVersion.zip")
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

    /**
     * A bundle is usable only if index.html exists AND every root-relative .js/.css it
     * references exists. An index.html with a missing script loads as a blank page
     * (black screen) and would never be repaired, since index.html alone looked valid.
     */
    private fun hasValidBundle(dir: File): Boolean {
        val index = File(dir, "index.html")
        if (!index.isFile) return false
        val html = try {
            index.readText()
        } catch (_: Exception) {
            return false
        }
        return ASSET_REF.findAll(html).all { m ->
            File(dir, m.groupValues[1].trimStart('/')).isFile
        }
    }

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
        /** Root-relative script/stylesheet references in the built index.html (POS_PWA_BASE=/). */
        private val ASSET_REF = Regex("""(?:src|href)="(/[^"?#]+\.(?:js|css))"""")

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
