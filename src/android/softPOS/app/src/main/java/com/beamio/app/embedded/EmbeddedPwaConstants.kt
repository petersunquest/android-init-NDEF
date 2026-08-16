package com.beamio.app.embedded

/**
 * Embedded POS PWA zip is built with POS_PWA_BASE=/ (root asset paths).
 * WebViewAssetLoader serves it from [ASSET_LOADER_DOMAIN] at path `/`.
 */
object EmbeddedPwaConstants {
    const val ASSET_LOADER_DOMAIN = "appassets.androidplatform.net"
    const val ASSET_LOADER_ORIGIN = "https://$ASSET_LOADER_DOMAIN"
    const val REMOTE_UPDATE_MANIFEST = "https://pos.beamio.app/update.json"
    const val REMOTE_BUNDLE_BASE = "https://pos.beamio.app/"
    const val BUNDLE_ASSET_NAME = "BeamioPOS.zip"
    const val ROOT_DIR_NAME = "beamio_pos_pwa"

    val entryUrl: String
        get() = "$ASSET_LOADER_ORIGIN/index.html"

    const val REMOTE_FALLBACK_URL = "https://pos.beamio.app/"
}

data class EmbeddedPwaUpdateInfo(
    val ver: String,
    val filename: String,
)
