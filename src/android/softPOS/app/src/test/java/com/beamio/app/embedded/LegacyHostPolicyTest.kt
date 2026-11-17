package com.beamio.app.embedded

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure JVM: the retired beamio.app family is refused; current beamio.ca hosts are not. */
class LegacyHostPolicyTest {
    @Test
    fun retiredBeamioAppAndSubdomainsAreRefused() {
        val hosts = listOf(
            "beamio.app",
            "www.beamio.app",
            "pos.beamio.app",
            "cashtrees.beamio.app",
            "biz.beamio.app",
            "api.beamio.app",
            "BEAMIO.APP",
            "pos.beamio.app.",
        )
        for (h in hosts) assertTrue("$h must be refused", EmbeddedPwaHost.isLegacyHost(h))
    }

    @Test
    fun currentBeamioCaHostsAreAllowed() {
        val hosts = listOf("beamio.ca", "www.beamio.ca", "pos.beamio.ca", "biz.beamio.ca", "api.beamio.ca")
        for (h in hosts) assertFalse("$h must be allowed", EmbeddedPwaHost.isLegacyHost(h))
    }

    @Test
    fun lookalikesAndEmptyHostsAreNotLegacy() {
        val hosts = listOf("evil-beamio.app", "xbeamio.app", "beamio.app.evil.example", "beamio.app@evil.example", "", " ")
        for (h in hosts) assertFalse("'$h' must not match", EmbeddedPwaHost.isLegacyHost(h))
        assertFalse(EmbeddedPwaHost.isLegacyHost(null))
    }
}
