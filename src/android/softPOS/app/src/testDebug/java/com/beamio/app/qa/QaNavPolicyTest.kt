package com.beamio.app.qa

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QaNavPolicyTest {
    private fun assertIgnored(raw: String?) {
        val d = QaNavPolicy.decide(raw)
        assertTrue("expected ignore for $raw but was $d", d is QaNavPolicy.Decision.Ignore)
    }

    @Test
    fun acceptsExactTestHosts() {
        for (host in QaNavPolicy.ALLOWED_HOSTS) {
            val d = QaNavPolicy.decide("https://$host/app/")
            assertTrue("$host must be accepted", d is QaNavPolicy.Decision.Accept)
        }
    }

    @Test
    fun acceptsUpperCaseHostAsSameHost() {
        val d = QaNavPolicy.decide("https://BEAMIO.APP/app/")
        assertEquals("https://BEAMIO.APP/app/", (d as QaNavPolicy.Decision.Accept).url)
    }

    @Test
    fun ignoresOtherHostsAndLookalikes() {
        assertIgnored("https://evil.example/")
        assertIgnored("https://beamio.app.evil.example/")
        assertIgnored("https://evil-beamio.app/")
        assertIgnored("https://cashtrees.beamio.app/")
        assertIgnored("https://biz.beamio.app/biz/")
        assertIgnored("https://api.beamio.ca/")
    }

    @Test
    fun userinfoTrickUsesRealHost() {
        // The host is evil.example; beamio.app is only userinfo.
        assertIgnored("https://beamio.app@evil.example/")
    }

    @Test
    fun ignoresNonHttpsAndBadInput() {
        assertIgnored("http://beamio.app/app/")
        assertIgnored("beamio.app/app/")
        assertIgnored("")
        assertIgnored(null)
        assertIgnored("https://")
        assertIgnored("not a url with spaces")
    }
}
