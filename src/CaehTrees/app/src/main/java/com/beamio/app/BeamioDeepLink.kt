package com.beamio.app

import android.net.Uri
import com.beamio.app.embedded.EmbeddedPwaConstants

/**
 * Resolve Consumer `beamio://open?…` deep links to HTTPS `/app/` URLs
 * (parity with iOS `BeamioDeepLink.resolveCustomSchemeURL`).
 */
object BeamioDeepLink {
    fun resolveCustomSchemeToHttps(incoming: Uri): Uri? {
        val scheme = incoming.scheme?.lowercase() ?: return null
        if (scheme != "beamio") return null

        val host = (incoming.host ?: "").lowercase()
        val path = incoming.path ?: ""
        val isOpenRoute =
            host == "open" ||
                (host.isEmpty() && (path.isEmpty() || path == "/" || path == "/open"))
        if (!isOpenRoute) return null

        val targetRaw = incoming.getQueryParameter("target")?.trim().orEmpty()
        if (targetRaw.isNotEmpty()) {
            val decoded = Uri.decode(targetRaw)
            val target = Uri.parse(decoded)
            if (target.scheme?.equals("https", ignoreCase = true) == true) {
                val h = target.host?.lowercase().orEmpty()
                if (h == "beamio.app" || h == "www.beamio.app") return target
            }
        }

        val query = incoming.encodedQuery
        if (query.isNullOrBlank()) {
            return Uri.parse(EmbeddedPwaConstants.REMOTE_FALLBACK_URL)
        }
        // Drop nested target= from passthrough — already handled above when present alone.
        val filtered =
            query
                .split('&')
                .filter { !it.startsWith("target=") }
                .joinToString("&")
        if (filtered.isBlank()) {
            return Uri.parse(EmbeddedPwaConstants.REMOTE_FALLBACK_URL)
        }
        val base = EmbeddedPwaConstants.REMOTE_FALLBACK_URL.trimEnd('/')
        return Uri.parse("$base/?$filtered")
    }
}
