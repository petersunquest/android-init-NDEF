package com.beamio.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class V3ListenGateTest {
    /** The canary sequence: watchdog reconnect, then a relay move, then the stale reconnect ends. */
    @Test
    fun relayMoveDuringReconnectDoesNotStickTheFlag() {
        val gate = V3ListenGate()
        val start = gate.gen.incrementAndGet() // first listen
        assertEquals(1, start)
        val reconnect = gate.beginReconnect() // network drop: watchdog reconnect
        assertFalse(gate.canReconnect())
        val moved = gate.relayMoved() // 6 s relay check fires in the same moment
        assertTrue(moved > reconnect)
        gate.finishReconnect(reconnect) // stale reconnect returns (gen mismatch)
        assertTrue("second drop must be able to reconnect", gate.canReconnect())
        // Second drop: the watchdog reconnects again and that one completes normally.
        val again = gate.beginReconnect()
        assertFalse(gate.canReconnect())
        gate.finishReconnect(again)
        assertTrue(gate.canReconnect())
    }

    /** Without clearing on relay move (the old code) the flag stays set: the bug. */
    @Test
    fun oldBehaviourWouldStick() {
        val gate = V3ListenGate()
        val reconnect = gate.beginReconnect()
        gate.gen.incrementAndGet() // relay move that did not clear the flag
        gate.finishReconnect(reconnect)
        assertFalse(gate.canReconnect())
    }

    @Test
    fun newerReconnectIsNotClearedByAnOlderOne() {
        val gate = V3ListenGate()
        val first = gate.beginReconnect()
        val second = gate.beginReconnect()
        gate.finishReconnect(first) // stale
        assertFalse(gate.canReconnect())
        gate.finishReconnect(second)
        assertTrue(gate.canReconnect())
    }

    /** Random interleaving on several threads: once the last listen's work ends, the gate is open. */
    @Test
    fun concurrentMovesAndReconnectsEndOpen() {
        repeat(200) {
            val gate = V3ListenGate()
            val pool = Executors.newFixedThreadPool(4)
            val done = CountDownLatch(40)
            repeat(40) { i ->
                pool.execute {
                    try {
                        if (i % 3 == 0) {
                            gate.relayMoved()
                        } else if (gate.canReconnect()) {
                            val g = gate.beginReconnect()
                            Thread.yield()
                            gate.finishReconnect(g)
                        }
                    } finally {
                        done.countDown()
                    }
                }
            }
            assertTrue(done.await(5, TimeUnit.SECONDS))
            pool.shutdown()
            // A relay move ends the sequence (the move's listen is the live one).
            gate.relayMoved()
            assertTrue(gate.canReconnect())
        }
    }
}
