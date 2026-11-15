package com.beamio.app.qa

import java.net.URI

/**
 * Debug/QA only. Decides whether a QA_NAV broadcast URL may navigate the POS WebView.
 * Exact host match only (no suffix or subdomain matching); https only; anything else is ignored.
 * Pure JVM (java.net.URI) so unit tests run without Robolectric.
 */
object QaNavPolicy {
    /** The Beamio test targets, exactly. Old and new domains. */
    val ALLOWED_HOSTS: Set<String> = setOf(
        "beamio.app", "www.beamio.app", "pos.beamio.app",
        "beamio.ca", "www.beamio.ca", "pos.beamio.ca",
    )

    sealed class Decision {
        data class Accept(val url: String) : Decision()
        data class Ignore(val reason: String) : Decision()
    }

    fun decide(raw: String?): Decision {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return Decision.Ignore("empty url")
        val uri = try {
            URI(text)
        } catch (e: Exception) {
            return Decision.Ignore("unparseable url")
        }
        if (uri.scheme?.lowercase() != "https") return Decision.Ignore("scheme is not https")
        val host = uri.host?.lowercase() ?: return Decision.Ignore("no host")
        if (host !in ALLOWED_HOSTS) return Decision.Ignore("host not allowed")
        return Decision.Accept(uri.toString())
    }
}
