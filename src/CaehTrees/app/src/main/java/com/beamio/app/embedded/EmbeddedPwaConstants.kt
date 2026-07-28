package com.beamio.app.embedded

/**
 * Embedded SilentPassUI zip is built with PUBLIC_URL=/ (root asset paths).
 * WebViewAssetLoader serves it from [ASSET_LOADER_DOMAIN] at path `/` — same layout as iOS
 * `cashtrees-local://localhost/`. Do NOT use `https://beamio.app/app/` as the loader entry:
 * index.html references `/static/...`, which would miss `/app/` and 404 on real beamio.app.
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

    /** Remote HTTPS fallback when bundled zip bootstrap fails. */
    const val REMOTE_FALLBACK_URL = "https://beamio.app/app/"
}

data class EmbeddedPwaUpdateInfo(
    val ver: String,
    val filename: String,
)
