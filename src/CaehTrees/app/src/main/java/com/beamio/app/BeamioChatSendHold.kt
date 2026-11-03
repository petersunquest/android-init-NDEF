package com.beamio.app

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * Keeps the process running while a chat send that the user started is still
 * on its way, and only that long.
 *
 * Leaving the app right after Send used to freeze the process (Samsung freezes
 * a background app within about a second) before the native module had signed,
 * encrypted and posted the message: the page then showed "Failed". Beamio does
 * not run in the background after the user leaves, so this hold only lets a
 * send already in progress finish: it ends at the module's answer for that send
 * or after [MAX_HOLD_MS], whichever comes first.
 *
 * The hold is an expedited job (allowed after the app left the screen, no
 * notification) plus a partial wake lock for the screen-off case.
 */
object BeamioChatSendHold {
    private const val TAG = "BeamioChatSend"
    private const val JOB_ID = 0x5E4D
    /** Upper bound for one send: the module tries up to 4 entries of 8 s each. */
    internal const val MAX_HOLD_MS = 45_000L
    private val SEND_COMMANDS = setOf("send", "sendGroup", "issueGroupRoster", "issueGroupTombstone")

    /** reqId → start time (elapsedRealtime). */
    private val inFlight = ConcurrentHashMap<Int, Long>()
    private val main = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    @Volatile
    internal var runningJob: BeamioChatSendHoldJob? = null

    /** A page command reached the native module. Send commands start the hold. */
    fun onCommand(context: Context, body: JSONObject) {
        val type = body.optString("type", "")
        if (type !in SEND_COMMANDS) return
        val reqId = body.optInt("reqId", 0)
        if (reqId <= 0) return
        val app = context.applicationContext
        inFlight[reqId] = SystemClock.elapsedRealtime()
        Log.i(TAG, "send hold begin type=$type reqId=$reqId inFlight=${inFlight.size}")
        main.post {
            acquireWakeLock(app)
            scheduleJob(app)
        }
        // Never longer than one send can take.
        main.postDelayed({ finish(reqId, "timeout") }, MAX_HOLD_MS)
    }

    /** Every module event on its way to the page: the ack for a held send ends its hold. */
    fun onModuleEvent(payload: JSONObject) {
        if (inFlight.isEmpty()) return
        val event = payload.optJSONObject("event") ?: return
        if (event.optString("type") != "ack") return
        finish(event.optInt("reqId", 0), if (event.optBoolean("ok", false)) "ack" else "ack_error")
    }

    fun hasInFlight(): Boolean {
        prune()
        return inFlight.isNotEmpty()
    }

    private fun finish(reqId: Int, reason: String) {
        if (inFlight.remove(reqId) == null) return
        Log.i(TAG, "send hold end reqId=$reqId reason=$reason inFlight=${inFlight.size}")
        main.post { releaseIfIdle() }
    }

    private fun prune() {
        val now = SystemClock.elapsedRealtime()
        inFlight.entries.removeIf { now - it.value > MAX_HOLD_MS }
    }

    /** Main thread. */
    private fun releaseIfIdle() {
        if (hasInFlight()) return
        wakeLock?.let { lock -> runCatching { if (lock.isHeld) lock.release() } }
        wakeLock = null
        runningJob?.finishHold()
    }

    /** Main thread. */
    private fun acquireWakeLock(context: Context) {
        if (wakeLock?.isHeld == true) return
        val pm = context.getSystemService(PowerManager::class.java) ?: return
        wakeLock = runCatching {
            pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "beamio:chatSend").apply {
                setReferenceCounted(false)
                acquire(MAX_HOLD_MS)
            }
        }.getOrNull()
    }

    /** Main thread. */
    private fun scheduleJob(context: Context) {
        if (runningJob != null) return
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        // Scheduling the same id again would stop a job that is already running.
        if (scheduler.getPendingJob(JOB_ID) != null) return
        val info = JobInfo.Builder(JOB_ID, ComponentName(context, BeamioChatSendHoldJob::class.java))
            .apply { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) setExpedited(true) }
            .build()
        val result = runCatching { scheduler.schedule(info) }
        Log.i(
            TAG,
            "send hold job scheduled=${result.getOrNull() == JobScheduler.RESULT_SUCCESS} " +
                "err=${result.exceptionOrNull()?.message}",
        )
    }
}

/** Does no work itself: it only keeps the process unfrozen while [BeamioChatSendHold] has sends in flight. */
class BeamioChatSendHoldJob : JobService() {
    private var params: JobParameters? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onStartJob(params: JobParameters): Boolean {
        if (!BeamioChatSendHold.hasInFlight()) return false
        this.params = params
        BeamioChatSendHold.runningJob = this
        Log.i("BeamioChatSend", "send hold job running")
        // Safety net: the job never outlives one send.
        main.postDelayed({ finishHold() }, BeamioChatSendHold.MAX_HOLD_MS)
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        clear()
        return false
    }

    /** Main thread. */
    fun finishHold() {
        val p = params ?: return
        clear()
        Log.i("BeamioChatSend", "send hold job finished")
        jobFinished(p, false)
    }

    private fun clear() {
        params = null
        main.removeCallbacksAndMessages(null)
        if (BeamioChatSendHold.runningJob === this) BeamioChatSendHold.runningJob = null
    }
}
