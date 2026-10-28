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
                if (h == "beamio.app" || h == "www.beamio.app") {
                    // Nested `/app-download?…` must become `/app/?…` (parity with iOS unwrap).
                    return unwrapAppDownloadLandingUri(target) ?: target
                }
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
     * Landing `/app-download?target=…/app/…` or invite-only `/app-download?invite=0x…`
     * → HTTPS `/app/?…` so the WebView never loads the marketing SPA.
     */
    fun unwrapAppDownloadLandingUri(url: Uri): Uri? {
        if (!url.scheme.equals("https", ignoreCase = true)) return null
        val host = url.host?.lowercase().orEmpty()
        if (host != "beamio.app" && host != "www.beamio.app") return null
        val path = url.path.orEmpty()
        if (path != "/app-download" && !path.startsWith("/app-download/")) return null

        val outerInvite = agentInviteQueryValue(url)
        val targetRaw = url.getQueryParameter("target")?.trim().orEmpty()
        if (targetRaw.isNotEmpty()) {
            val decoded = Uri.decode(targetRaw)
            val target = Uri.parse(decoded)
            if (!target.scheme.equals("https", ignoreCase = true)) return null
            val th = target.host?.lowercase().orEmpty()
            if (th != "beamio.app" && th != "www.beamio.app") return null
            val tp = target.path.orEmpty()
            if (tp != "/app" && tp != "/app/" && !tp.startsWith("/app/")) return null
            return mergeAgentInviteIfNeeded(target, outerInvite)
        }
        val invite = outerInvite ?: return null
        val base = EmbeddedPwaConstants.REMOTE_FALLBACK_URL.trimEnd('/')
        return Uri.parse("$base/?invite=${Uri.encode(invite)}")
    }

    private fun agentInviteQueryValue(url: Uri): String? {
        val invite =
            url.getQueryParameter("invite")?.trim().orEmpty()
                .ifEmpty { url.getQueryParameter("Invite")?.trim().orEmpty() }
        return if (invite.matches(Regex("^0x[0-9a-fA-F]{40}$"))) invite else null
    }

    private fun mergeAgentInviteIfNeeded(url: Uri, outerInvite: String?): Uri {
        if (outerInvite.isNullOrBlank()) return url
        if (agentInviteQueryValue(url) != null) return url
        return url.buildUpon().appendQueryParameter("invite", outerInvite).build()
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

    /** Agent invite `invite=0x` + 40 hex. Distinct from Discover merchant `ref=`. */
    fun carriesAgentInvite(url: Uri): Boolean {
        val invite =
            url.getQueryParameter("invite")?.trim().orEmpty()
                .ifEmpty { url.getQueryParameter("Invite")?.trim().orEmpty() }
        return invite.matches(Regex("^0x[0-9a-fA-F]{40}$"))
    }

    /**
     * Play Install Referrer payload written by the landing page:
     * `beamio_dl=<urlencoded https://beamio.app/app/?invite=0x…>`
     * or a merchant / coupon `/app/` URL.
     * Returns the inner HTTPS URL only for allowed hosts / `/app` paths that carry
     * an agent invite or a merchant / coupon payload; anything else is ignored.
     */
    fun resolveInstallReferrer(referrer: String?): Uri? {
        val raw = referrer?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val encoded = raw.split('&')
            .firstOrNull { it.startsWith("beamio_dl=") }
            ?.removePrefix("beamio_dl=")
            ?.takeIf { it.isNotBlank() }
            ?: return null
        val decoded = Uri.parse(Uri.decode(encoded))
        if (!decoded.scheme.equals("https", ignoreCase = true)) return null
        val host = decoded.host?.lowercase().orEmpty()
        if (host != "beamio.app" && host != "www.beamio.app") return null
        // Landing may stash `/app-download?invite=…` — unwrap before requiring `/app`.
        val candidate = unwrapAppDownloadLandingUri(decoded) ?: decoded
        val path = candidate.path.orEmpty()
        if (path != "/app" && path != "/app/" && !path.startsWith("/app/")) return null
        return if (carriesAgentInvite(candidate) || carriesMerchantOrCouponPayload(candidate)) {
            candidate
        } else {
            null
        }
    }
}
