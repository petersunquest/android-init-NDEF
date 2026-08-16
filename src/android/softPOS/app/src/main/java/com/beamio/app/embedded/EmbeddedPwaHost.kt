package com.beamio.app.embedded

import android.content.Context
import android.net.Uri
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.webkit.WebViewAssetLoader
import java.io.File

/** Local POS PWA host: bootstrap bundle, serve via WebViewAssetLoader, OTA daemon. */
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
                SpaInternalStoragePathHandler(appContext, bundleStore.activeDir),
            )
            .build()
    }

    fun rebuildAssetLoader() {
        assetLoader = null
        buildAssetLoaderIfNeeded()
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
     * Map remote POS URLs to the local loader (PUBLIC_URL=/).
     * API / OG / metadata on beamio.app must bypass.
     */
    fun mapPosUrlToLocal(uri: Uri): Uri? {
        val host = uri.host?.lowercase() ?: return null
        if (shouldBypassEmbeddedAssetLoader(uri)) return null
        var path = uri.path ?: "/"
        when (host) {
            "pos.beamio.app", "pos.conet.network" -> Unit
            "beamio.app", "www.beamio.app" -> {
                when {
                    path == "/pos" || path == "/pos/" -> path = "/index.html"
                    path.startsWith("/pos/") -> path = path.removePrefix("/pos")
                    else -> return null
                }
            }
            else -> return null
        }
        if (path.isEmpty() || path == "/") path = "/index.html"
        return Uri.parse(EmbeddedPwaConstants.ASSET_LOADER_ORIGIN + path).buildUpon()
            .encodedQuery(uri.encodedQuery)
            .fragment(uri.fragment)
            .build()
    }

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

/**
 * [WebViewAssetLoader.InternalStoragePathHandler] plus SPA fallback: extension-less
 * paths (BrowserRouter `/home`) serve `index.html`.
 */
private class SpaInternalStoragePathHandler(
    context: Context,
    directory: File,
) : WebViewAssetLoader.PathHandler {
    private val inner = WebViewAssetLoader.InternalStoragePathHandler(context, directory)

    override fun handle(path: String): WebResourceResponse? {
        inner.handle(path)?.let { return it }
        val last = path.substringAfterLast('/')
        if (!last.contains('.')) {
            return inner.handle("index.html")
        }
        return null
    }
}
