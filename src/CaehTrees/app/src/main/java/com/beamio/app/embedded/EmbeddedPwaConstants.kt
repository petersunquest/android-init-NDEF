package com.beamio.app.embedded

/**
 * Embedded SilentPassUI zip is built with PUBLIC_URL=/ (root asset paths).
 * Keep the Android-local origin stable. Existing wallet data belongs to this origin;
 * changing it to beamio.app would make IndexedDB/PouchDB look like a new account.
 */
object EmbeddedPwaConstants {
    const val ASSET_LOADER_DOMAIN = "appassets.androidplatform.net"
    const val ASSET_LOADER_ORIGIN = "https://$ASSET_LOADER_DOMAIN"
    const val REMOTE_UPDATE_MANIFEST = "https://beamio.app/app/update.json"
    const val REMOTE_BUNDLE_BASE = "https://beamio.app/app/"
    const val BUNDLE_ASSET_NAME = "SilentPassUI.zip"
    const val ROOT_DIR_NAME = "silentpass_pwa"

    val entryUrl: String
        get() = "$ASSET_LOADER_ORIGIN/index.html"

    /** Legacy constant retained for compatibility; normal startup must never use it. */
    const val REMOTE_FALLBACK_URL = "https://beamio.app/app/"
}

data class EmbeddedPwaUpdateInfo(
    val ver: String,
    val filename: String,
)
