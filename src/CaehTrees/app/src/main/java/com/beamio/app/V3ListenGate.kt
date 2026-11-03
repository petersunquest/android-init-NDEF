package com.beamio.app

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Voice listen generation and the watchdog's "reconnect in flight" flag.
 *
 * Every new voice listen (start, reconnect, relay move) takes a new generation;
 * an older listen sees a different generation and stops. The watchdog starts a
 * reconnect only while no reconnect is in flight. A reconnect superseded by a
 * relay move can no longer clear the flag itself (its generation is stale), so
 * the move clears it. Without that the flag stayed set and the call never
 * reconnected again (canary 2026-11-02, network switch).
 */
internal class V3ListenGate {
    val gen = AtomicInteger(0)
    val reconnectInFlight = AtomicBoolean(false)

    /** Watchdog may start a reconnect now. */
    fun canReconnect(): Boolean = !reconnectInFlight.get()

    /** Watchdog reconnect starts: flag set, new generation. */
    fun beginReconnect(): Int {
        reconnectInFlight.set(true)
        return gen.incrementAndGet()
    }

    /** That reconnect's work ended (opened and closed, failed, or superseded). */
    fun finishReconnect(reconnectGen: Int) {
        if (reconnectGen == gen.get()) reconnectInFlight.set(false)
    }

    /** Relay moved: the new listen replaces any reconnect in flight. */
    fun relayMoved(): Int {
        val next = gen.incrementAndGet()
        reconnectInFlight.set(false)
        return next
    }
}
