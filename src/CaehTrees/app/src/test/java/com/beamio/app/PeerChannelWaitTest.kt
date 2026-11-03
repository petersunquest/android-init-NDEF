package com.beamio.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The caller now sends `channel ready` before its own listen is up. These check
 * that the callee's first frames are not lost while the caller's channel opens:
 * the relay keeps nothing, so the callee posts them again.
 */
class PeerChannelWaitTest {
    private val notFound = false to PeerChannelWait.NOT_FOUND
    private val accepted = true to ""

    @Test
    fun notFoundIsRetriedUntilTheChannelExists() {
        var t = 0L
        var calls = 0
        val r = PeerChannelWait.post(
            seenBefore = false,
            post = { calls++; if (calls < 6) notFound else accepted },
            sleep = { t += it },
            now = { t },
        )
        assertTrue(r.ok)
        assertEquals(6, r.tries)
        assertEquals(5 * PeerChannelWait.GAP_MS, t)
    }

    @Test
    fun noRetryOnceAFrameWasAccepted() {
        var calls = 0
        val r = PeerChannelWait.post(
            seenBefore = true,
            post = { calls++; notFound },
            sleep = { fail("must not wait") },
            now = { 0L },
        )
        assertFalse(r.ok)
        assertEquals(1, calls)
    }

    @Test
    fun otherErrorsAreNotRetried() {
        var calls = 0
        val r = PeerChannelWait.post(
            seenBefore = false,
            post = { calls++; false to "voice_chunk_auth" },
            sleep = { fail("must not wait") },
            now = { 0L },
        )
        assertFalse(r.ok)
        assertEquals(1, calls)
    }

    @Test
    fun givesUpAfterTheWindow() {
        var t = 0L
        val r = PeerChannelWait.post(seenBefore = false, post = { notFound }, sleep = { t += it }, now = { t })
        assertFalse(r.ok)
        assertTrue(t >= PeerChannelWait.WAIT_MS)
        assertTrue(t <= PeerChannelWait.WAIT_MS + PeerChannelWait.GAP_MS)
    }

    /**
     * Frames every 160 ms from t = 0, the caller's listen opens at `open`, at most
     * 10 posts in flight. Every frame must arrive, the first one within one retry
     * gap of the channel opening.
     */
    @Test
    fun noFrameLostWhileTheCallerListenOpens() {
        for (open in listOf(0L, 500L, 1_000L, 1_400L)) {
            val finishes = mutableListOf<Long>()
            var dropped = 0
            for (i in 0 until 30) {
                val start = i * 160L
                if (finishes.count { it > start } >= 10) {
                    dropped++
                    continue
                }
                var t = start
                val r = PeerChannelWait.post(
                    seenBefore = false,
                    post = { if (t >= open) accepted else notFound },
                    sleep = { t += it },
                    now = { t },
                )
                assertTrue("frame $i open=$open", r.ok)
                finishes += t
            }
            assertEquals("open=$open", 0, dropped)
            assertTrue(finishes[0] <= open + PeerChannelWait.GAP_MS)
        }
    }
}
