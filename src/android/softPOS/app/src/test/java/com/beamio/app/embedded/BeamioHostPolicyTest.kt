package com.beamio.app.embedded

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class BeamioHostPolicyTest {
    private val legacyAndConsumerPaths = listOf("/", "/app", "/app/", "/app/?beamiocard=x", "/app-download", "/api/sun", "/sun", "/pos-foo")

    @Test
    fun consumerPagesAreCancelledOnOldAndNewHosts() {
        for (host in BeamioHostPolicy.CONSUMER_HOSTS) {
            for (path in listOf("/", "/app", "/app/", "/app-download", "/api/sun")) {
                assertEquals("$host$path", NavDecision.CANCEL, BeamioHostPolicy.decideMainFrameNavigation(host, path))
            }
        }
    }

    @Test
    fun posPathsOnConsumerHostsAreMappedLocally() {
        for (host in BeamioHostPolicy.CONSUMER_HOSTS) {
            assertEquals(NavDecision.MAP_LOCAL, BeamioHostPolicy.decideMainFrameNavigation(host, "/pos"))
            assertEquals(NavDecision.MAP_LOCAL, BeamioHostPolicy.decideMainFrameNavigation(host, "/pos/"))
            assertEquals(NavDecision.MAP_LOCAL, BeamioHostPolicy.decideMainFrameNavigation(host, "/pos/home"))
        }
    }

    @Test
    fun legacyPosHostIsMappedLocallyAndUnmappedPathsAreCancelled() {
        assertEquals(NavDecision.MAP_LOCAL, BeamioHostPolicy.decideMainFrameNavigation("pos.beamio.app", "/"))
        assertEquals(NavDecision.MAP_LOCAL, BeamioHostPolicy.decideMainFrameNavigation("pos.beamio.app", "/home"))
        assertEquals(NavDecision.CANCEL, BeamioHostPolicy.decideMainFrameNavigation("pos.beamio.app", "/api/getOracle"))
        assertEquals(NavDecision.CANCEL, BeamioHostPolicy.decideMainFrameNavigation("pos.beamio.app", "/og/x"))
    }

    @Test
    fun newPosHostIsMappedLocally() {
        assertEquals(NavDecision.MAP_LOCAL, BeamioHostPolicy.decideMainFrameNavigation("pos.beamio.ca", "/"))
        assertEquals(NavDecision.PASS, BeamioHostPolicy.decideMainFrameNavigation("pos.beamio.ca", "/api/getOracle"))
    }

    @Test
    fun oldDomainNeverBecomesARemoteTarget() {
        for (host in BeamioHostPolicy.LEGACY_HOSTS + BeamioHostPolicy.CONSUMER_HOSTS) {
            for (path in legacyAndConsumerPaths) {
                val decision = BeamioHostPolicy.decideMainFrameNavigation(host, path)
                val target = BeamioHostPolicy.remoteHostFor(decision, host)
                if (target != null) {
                    assertFalse("$host$path must not become a remote target", BeamioHostPolicy.LEGACY_HOSTS.contains(target))
                }
            }
        }
    }

    @Test
    fun unrelatedHostsPassThroughUnchanged() {
        assertEquals(NavDecision.PASS, BeamioHostPolicy.decideMainFrameNavigation("example.com", "/"))
        assertEquals("example.com", BeamioHostPolicy.remoteHostFor(NavDecision.PASS, "example.com"))
        assertNull(BeamioHostPolicy.remoteHostFor(NavDecision.CANCEL, "beamio.app"))
        assertNull(BeamioHostPolicy.remoteHostFor(NavDecision.MAP_LOCAL, "beamio.ca"))
    }
}
