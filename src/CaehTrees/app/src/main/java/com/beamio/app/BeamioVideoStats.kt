package com.beamio.app

import android.util.Log
import kotlin.math.abs

/**
 * Call media counters, logged every 2 s as one `[VideoStats]` line while video
 * moves (QA: before/after comparisons). Same fields as iOS `BeamioVideoStats`.
 * Thread-safe.
 */
class BeamioVideoStats {
    class Window {
        // Sender
        var txCap = 0
        var txSent = 0
        var txDropBusy = 0
        var txDropAudio = 0
        var txDropRoute = 0
        var txOk = 0
        var txFail = 0
        var txJpegBytes = 0L
        var txWireBytes = 0L
        var txEncMsSum = 0L
        var txPostMsSum = 0L
        var txPostMsMax = 0L
        var capEncodeMsSum = 0L
        var capEncodeMsMax = 0L
        var capEncodeN = 0
        // Receiver
        var rxIn = 0
        var rxShown = 0
        var rxSuperseded = 0
        var rxBytes = 0L
        var rxLatSum = 0L
        var rxLatN = 0
        var rxLatMin = Long.MAX_VALUE
        var rxLatMax = 0L
        var rxJitterSum = 0L
        var rxJitterN = 0
        // Audio
        var audioTx = 0
        var audioTxWireBytes = 0L
        var audioRx = 0
        var audioUnderrun = 0
        var audioGapSkip = 0
    }

    private val lock = Any()
    private var w = Window()
    private var lastArrivalMs = 0L
    private var lastCaptureMs = 0L
    private var lastFlushMs = System.currentTimeMillis()

    fun update(change: (Window) -> Unit) {
        synchronized(lock) { change(w) }
    }

    fun reset() {
        synchronized(lock) {
            w = Window()
            lastArrivalMs = 0L
            lastCaptureMs = 0L
            lastFlushMs = System.currentTimeMillis()
        }
    }

    /**
     * One received frame with a sender capture time (BJP2). Latency includes the
     * clock offset between the two phones; jitter does not.
     */
    fun noteRxTiming(captureMs: Long, arrivalMs: Long) {
        synchronized(lock) {
            val lat = arrivalMs - captureMs
            w.rxLatSum += lat
            w.rxLatN += 1
            w.rxLatMin = minOf(w.rxLatMin, lat)
            w.rxLatMax = maxOf(w.rxLatMax, lat)
            if (lastArrivalMs > 0 && captureMs > lastCaptureMs) {
                w.rxJitterSum += abs((arrivalMs - lastArrivalMs) - (captureMs - lastCaptureMs))
                w.rxJitterN += 1
            }
            if (captureMs > lastCaptureMs) {
                lastArrivalMs = arrivalMs
                lastCaptureMs = captureMs
            }
        }
    }

    /** Logs and clears the window when 2 s have passed and video moved. */
    fun maybeFlush(tag: String, mode: String, peerCaps: Int) {
        val now = System.currentTimeMillis()
        val s: Window
        val seconds: Double
        synchronized(lock) {
            if (now - lastFlushMs < 2_000L) return
            seconds = (now - lastFlushMs) / 1000.0
            lastFlushMs = now
            s = w
            w = Window()
        }
        if (s.txCap == 0 && s.rxIn == 0) return
        fun avg(sum: Long, n: Int): Long = if (n > 0) sum / n else 0L
        fun fps(n: Int): String = String.format("%.1f", n / seconds.coerceAtLeast(0.1))
        val posts = s.txOk + s.txFail
        val line = listOf(
            "[VideoStats] mode=$mode peerCaps=$peerCaps",
            "tx cap=${s.txCap} sent=${s.txSent} ok=${s.txOk} fail=${s.txFail} fps=${fps(s.txOk)}",
            "drop busy=${s.txDropBusy} audio=${s.txDropAudio} route=${s.txDropRoute}",
            "jpegAvg=${avg(s.txJpegBytes, s.txSent)}B wireAvg=${avg(s.txWireBytes, s.txSent)}B",
            "capEncAvg=${avg(s.capEncodeMsSum, s.capEncodeN)}ms capEncMax=${s.capEncodeMsMax}ms",
            "pgpAvg=${avg(s.txEncMsSum, s.txSent)}ms postAvg=${avg(s.txPostMsSum, posts)}ms postMax=${s.txPostMsMax}ms",
            "| rx in=${s.rxIn} shown=${s.rxShown} superseded=${s.rxSuperseded} fps=${fps(s.rxShown)} bytesAvg=${avg(s.rxBytes, s.rxIn)}B",
            "latAvg=${avg(s.rxLatSum, s.rxLatN)}ms latMin=${if (s.rxLatN > 0) s.rxLatMin else 0}ms latMax=${s.rxLatMax}ms jitterAvg=${avg(s.rxJitterSum, s.rxJitterN)}ms",
            "| audio tx=${s.audioTx} wireAvg=${avg(s.audioTxWireBytes, s.audioTx)}B rx=${s.audioRx} underrun=${s.audioUnderrun} gapSkip=${s.audioGapSkip}",
        ).joinToString(" ")
        Log.i(tag, line)
    }
}
