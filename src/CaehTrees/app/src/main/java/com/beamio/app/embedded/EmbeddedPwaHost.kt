package com.beamio.app.embedded

import android.content.Context
import android.net.Uri
import android.webkit.WebView
import androidx.webkit.WebViewAssetLoader

/** Local SilentPassUI host: bootstrap bundle, serve via WebViewAssetLoader, OTA daemon. */
class EmbeddedPwaHost(context: Context) {
    private val appContext = context.applicationContext
    val bundleStore = EmbeddedPwaBundleStore(appContext)

    var assetLoader: WebViewAssetLoader? = null
        private set

    private var updateDaemon: EmbeddedPwaUpdateDaemon? = null

    fun bootstrapIfNeeded() {
        bundleStore.bootstrapIfNeeded()
        buildAssetLoaderIfNeeded()
    }

    fun buildAssetLoaderIfNeeded() {
        if (assetLoader != null) return
        assetLoader = WebViewAssetLoader.Builder()
            .setDomain(EmbeddedPwaConstants.ASSET_LOADER_DOMAIN)
            .addPathHandler(
                "/",
                WebViewAssetLoader.InternalStoragePathHandler(appContext, bundleStore.activeDir),
            )
            .build()
    }

    fun startUpdateDaemon(onUpdateAvailable: (currentVer: String, pendingVer: String) -> Unit) {
        if (updateDaemon != null) return
        updateDaemon = EmbeddedPwaUpdateDaemon(bundleStore, onUpdateAvailable).also { it.start() }
    }

    fun checkForUpdatesNow() {
        updateDaemon?.checkNow()
    }

    fun stopUpdateDaemon() {
        updateDaemon?.stop()
        updateDaemon = null
    }

    fun injectVersionGlobals(webView: WebView) {
        val current = escapeJs(bundleStore.activeVersion())
        val pending = escapeJs(bundleStore.pendingUpdateVersion() ?: "")
        val js =
            "(function(){try{" +
                "window.__CT_EMBEDDED_PWA_VER__='$current';" +
                "window.__CT_EMBEDDED_PWA_PENDING_VER__='$pending';" +
                "}catch(e){}})();"
        webView.evaluateJavascript(js, null)
    }

    /**
     * Map `https://beamio.app/app/...` static assets to local loader URLs (PUBLIC_URL=/).
     * API / OG / metadata must bypass via [shouldBypassEmbeddedAssetLoader].
     */
    fun mapBeamioAppUrlToLocal(uri: Uri): Uri? {
        val host = uri.host?.lowercase() ?: return null
        if (host != "beamio.app") return null
        if (shouldBypassEmbeddedAssetLoader(uri)) return null
        var path = uri.path ?: "/"
        when {
            path == "/app" || path == "/app/" -> path = "/index.html"
            path.startsWith("/app/") -> path = path.removePrefix("/app")
        }
        if (path.isEmpty() || path == "/") path = "/index.html"
        return Uri.parse(EmbeddedPwaConstants.ASSET_LOADER_ORIGIN + path).buildUpon()
            .encodedQuery(uri.encodedQuery)
            .fragment(uri.fragment)
            .build()
    }

    /**
     * Network-only beamio.app paths (API, OG, metadata). Must not be served from
     * `silentpass_pwa/active/` — otherwise onboarding hangs waiting on fetch.
     */
    fun shouldBypassEmbeddedAssetLoader(uri: Uri): Boolean {
        val path = uri.path?.trim().orEmpty().ifEmpty { "/" }
        if (path == "/api" || path.startsWith("/api/")) return true
        if (path == "/og" || path.startsWith("/og/")) return true
        if (path == "/metadata" || path.startsWith("/metadata/")) return true
        return false
    }

    private fun escapeJs(raw: String): String =
        raw.replace("\\", "\\\\").replace("'", "\\'")
}
