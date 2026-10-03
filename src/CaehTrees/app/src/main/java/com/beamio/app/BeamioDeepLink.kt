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

    /**
     * True when an `https://beamio.app/app/?…` URL carries a merchant card, coupon claim
     * or redeem payload (parity with iOS `urlCarriesMerchantOrCouponPayload` and the
     * homepage `isMeaningfulConsumerAppDeepLink`). A bare `beamiocard` is a merchant link.
     */
    fun carriesMerchantOrCouponPayload(url: Uri): Boolean {
        fun param(vararg names: String): String {
            for (name in names) {
                val v = url.getQueryParameter(name)?.trim().orEmpty()
                if (v.isNotEmpty()) return v
            }
            return ""
        }
        if (param("beamiocard", "Beamiocard").isEmpty()) return false
        if (param("redeemcode", "Redeemcode").isNotEmpty()) return true
        val couponId = param("couponId", "couponid")
        if (couponId.isNotEmpty()) {
            val claim = param("claim").lowercase()
            return claim.isEmpty() || claim == "open" || claim == "1" || claim == "true"
        }
        // Merchant link: `discover=open|1|true`, or no `discover` at all.
        val discover = param("discover").lowercase()
        return discover.isEmpty() || discover == "open" || discover == "1" || discover == "true"
    }

    /**
     * Play Install Referrer payload written by the landing page:
     * `beamio_dl=<urlencoded https://beamio.app/app/?beamiocard=…&ref=…>`.
     * Returns the inner HTTPS URL only for allowed hosts / `/app` paths that carry a
     * merchant or coupon payload; anything else is ignored.
     */
    fun resolveInstallReferrer(referrer: String?): Uri? {
        val raw = referrer?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val encoded = raw.split('&')
            .firstOrNull { it.startsWith("beamio_dl=") }
            ?.removePrefix("beamio_dl=")
            ?.takeIf { it.isNotBlank() }
            ?: return null
        val candidate = Uri.parse(Uri.decode(encoded))
        if (!candidate.scheme.equals("https", ignoreCase = true)) return null
        val host = candidate.host?.lowercase().orEmpty()
        if (host != "beamio.app" && host != "www.beamio.app") return null
        val path = candidate.path.orEmpty()
        if (path != "/app" && path != "/app/" && !path.startsWith("/app/")) return null
        return if (carriesMerchantOrCouponPayload(candidate)) candidate else null
    }
}
