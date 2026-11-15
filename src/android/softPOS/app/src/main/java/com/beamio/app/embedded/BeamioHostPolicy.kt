package com.beamio.app.embedded

/**
 * Pure navigation policy for WebView main-frame loads (no android.net.Uri, so JVM unit tests run
 * without Robolectric). Hosts are matched exactly; paths are compared in lower case.
 *
 * - CANCEL: consumer Beamio pages and legacy/unmapped beamio.app / pos.beamio.app paths. The
 *   navigation is cancelled locally; nothing is requested from the old or consumer domain.
 * - MAP_LOCAL: POS paths on POS hosts (old and new), served from the embedded assets.
 * - PASS: any other host (not a Beamio POS/consumer host), left to the WebView as before.
 */
enum class NavDecision { CANCEL, MAP_LOCAL, PASS }

object BeamioHostPolicy {
    /** Consumer Beamio hosts (old and new). Never loaded in the POS WebView. */
    val CONSUMER_HOSTS: Set<String> = setOf("beamio.ca", "www.beamio.ca", "beamio.app", "www.beamio.app")

    /** POS hosts that are mapped to the embedded assets. Old pos.beamio.app is included. */
    val POS_HOSTS: Set<String> = setOf("pos.beamio.ca", "pos.beamio.app", "pos.conet.network")

    /** Legacy hosts: any request to these would reach the old domain. */
    val LEGACY_HOSTS: Set<String> = setOf("beamio.app", "www.beamio.app", "pos.beamio.app")

    private val BYPASS_PREFIXES = listOf("/api", "/og", "/metadata")

    fun isPosPath(path: String): Boolean = path == "/pos" || path == "/pos/" || path.startsWith("/pos/")

    private fun isBypassPath(path: String): Boolean =
        BYPASS_PREFIXES.any { p -> path == p || path.startsWith("$p/") }

    fun decideMainFrameNavigation(host: String, path: String): NavDecision {
        val h = host.lowercase()
        val p = path.lowercase().ifEmpty { "/" }
        return when {
            h in CONSUMER_HOSTS -> if (isPosPath(p)) NavDecision.MAP_LOCAL else NavDecision.CANCEL
            h == "pos.beamio.app" -> if (isBypassPath(p)) NavDecision.CANCEL else NavDecision.MAP_LOCAL
            h == "pos.beamio.ca" || h == "pos.conet.network" ->
                if (isBypassPath(p)) NavDecision.PASS else NavDecision.MAP_LOCAL
            else -> NavDecision.PASS
        }
    }

    /**
     * The host a request would be sent to for this decision, or null when nothing is requested.
     * Used by tests to assert that no legacy-domain request target can arise.
     */
    fun remoteHostFor(decision: NavDecision, host: String): String? =
        if (decision == NavDecision.PASS) host.lowercase() else null
}
