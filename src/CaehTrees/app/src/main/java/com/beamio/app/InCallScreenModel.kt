package com.beamio.app

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Shell-answered call state for the unlocked in-call page (iOS [BeamioInCallScreenModel]).
 *
 * Only calls the native glass answered are tracked here. PWA-dialed calls keep
 * the WebView call UI. Minimize finishes [InCallActivity] while [live] stays true
 * so the green return pill / ongoing notification can bring the screen back.
 */
object InCallScreenModel {
    private val liveFlag = AtomicBoolean(false)
    private val presentedFlag = AtomicBoolean(false)
    private val mutedFlag = AtomicBoolean(false)
    private val speakerFlag = AtomicBoolean(false)
    /** False while an outgoing call is still ringing (dialer, before Accept). */
    private val connectedFlag = AtomicBoolean(true)
    private val state = AtomicReference(State())

    data class State(
        val callId: String = "",
        val sessionId: String = "",
        /** Verified @BeamioTag; empty when lookup has not produced one. */
        val tag: String = "",
        val address: String = "",
        val answeredAtMs: Long = 0L,
    )

    fun isLive(): Boolean = liveFlag.get()

    fun isPresented(): Boolean = presentedFlag.get()

    fun isMuted(): Boolean = mutedFlag.get()

    fun isSpeakerOn(): Boolean = speakerFlag.get()

    fun isConnected(): Boolean = connectedFlag.get()

    /**
     * Dialer inside the native shell: show the call screen as soon as the call
     * is placed ("Calling…"); [markConnected] starts the timer on Accept.
     */
    fun beginOutgoing(callId: String, sessionId: String, address: String) {
        val previous = state.get()
        val sameLiveCall = liveFlag.get() && callId.isNotBlank() && previous.callId == callId
        // Keep the tag a prepared screen already looked up for this peer.
        val preparedTag = if (
            liveFlag.get() && previous.callId.isBlank() &&
            previous.address.equals(address.trim(), ignoreCase = true)
        ) previous.tag else ""
        preparedId.set("")
        begin(callId, sessionId, tag = preparedTag, address = address, presentImmediately = true)
        if (!sameLiveCall) {
            connectedFlag.set(false)
            BeamioCallTonePlayer.resetForNewDial()
        }
    }

    /** The PWA's `prepareSystemCall` id while the screen waits for `startSystemCall`. */
    private val preparedId = AtomicReference("")
    private val cancelledPrepareIds = java.util.Collections.synchronizedSet(LinkedHashSet<String>())

    /**
     * Dial pressed: show "Calling…" at once while the PWA still builds the
     * offer. [beginOutgoing] later fills in the real call ids.
     */
    fun beginPrepared(prepareId: String, address: String) {
        begin(callId = "", sessionId = "", tag = "", address = address, presentImmediately = true)
        // begin() keeps old ids when the new ones are blank; a prepared screen has none.
        state.set(state.get().copy(callId = "", sessionId = ""))
        connectedFlag.set(false)
        BeamioCallTonePlayer.resetForNewDial()
        preparedId.set(prepareId.trim())
        android.util.Log.i("BeamioInCall", "prepared outgoing screen")
    }

    /** True while the screen is shown for a dial that has no call ids yet. */
    fun isPrepared(): Boolean {
        if (!liveFlag.get()) return false
        val current = state.get()
        return current.callId.isBlank() && current.sessionId.isBlank()
    }

    /**
     * End a prepared screen. [prepareId] blank means "whatever is prepared".
     * Returns true when a prepared screen was closed.
     */
    fun cancelPrepared(prepareId: String = ""): Boolean {
        val want = prepareId.trim()
        val current = preparedId.get()
        if (!isPrepared()) return false
        if (want.isNotEmpty() && current.isNotEmpty() && want != current) return false
        val id = want.ifEmpty { current }
        if (id.isNotEmpty()) {
            cancelledPrepareIds.add(id)
            synchronized(cancelledPrepareIds) {
                while (cancelledPrepareIds.size > 20) cancelledPrepareIds.remove(cancelledPrepareIds.first())
            }
        }
        preparedId.set("")
        end()
        return true
    }

    /** The user hung up while this dial was still being prepared. */
    fun wasPrepareCancelled(prepareId: String): Boolean =
        prepareId.isNotBlank() && cancelledPrepareIds.contains(prepareId.trim())

    /** Dialer: the callee accepted. Returns true when this changed the state. */
    fun markConnected(callId: String): Boolean {
        if (!liveFlag.get() || connectedFlag.get()) return false
        val current = state.get()
        if (callId.isNotBlank() && current.callId.isNotBlank() && callId != current.callId) return false
        connectedFlag.set(true)
        BeamioCallTonePlayer.stopRingback("connected")
        state.set(current.copy(answeredAtMs = System.currentTimeMillis()))
        android.util.Log.i("BeamioInCall", "outgoing connected callId=${current.callId.take(12)}")
        return true
    }

    fun snapshot(): State = state.get()

    fun matches(callId: String, sessionId: String): Boolean {
        if (!liveFlag.get()) return false
        val current = state.get()
        val keys = listOf(callId, sessionId).map { it.trim() }.filter { it.isNotEmpty() }
        if (keys.isEmpty()) return true
        val liveKeys = listOf(current.callId, current.sessionId).map { it.trim() }.filter { it.isNotEmpty() }
        return keys.any { liveKeys.contains(it) }
    }

    fun begin(
        callId: String,
        sessionId: String,
        tag: String,
        address: String,
        presentImmediately: Boolean = true,
    ) {
        val previous = state.get()
        val sameLiveCall = liveFlag.get() &&
            callId.isNotBlank() &&
            previous.callId == callId
        val normalizedTag = tag.trim().let { raw ->
            when {
                raw.isBlank() -> ""
                raw.startsWith("@") -> raw
                else -> "@$raw"
            }
        }
        val next = State(
            callId = callId.ifBlank { previous.callId },
            sessionId = sessionId.ifBlank { previous.sessionId },
            tag = when {
                normalizedTag.isNotEmpty() -> normalizedTag
                sameLiveCall -> previous.tag
                else -> ""
            },
            address = when {
                address.isNotBlank() -> address.trim()
                sameLiveCall -> previous.address
                else -> ""
            },
            answeredAtMs = if (sameLiveCall && previous.answeredAtMs > 0L) {
                previous.answeredAtMs
            } else {
                System.currentTimeMillis()
            },
        )
        state.set(next)
        if (!sameLiveCall) {
            connectedFlag.set(true)
            mutedFlag.set(false)
            speakerFlag.set(false)
            BeamioNativeVoiceChannel.setCaptureMuted(false)
        }
        liveFlag.set(true)
        if (presentImmediately) {
            presentedFlag.set(true)
        }
        android.util.Log.i(
            "BeamioInCall",
            "begin callId=${next.callId.take(12)} tag=${next.tag.ifBlank { "-" }} " +
                "same=${if (sameLiveCall) "yes" else "no"}",
        )
    }

    /**
     * Apply a later verified `@BeamioTag` (and optional wallet) onto the live
     * InCall session without resetting the elapsed timer. Used when Answer
     * races ahead of BeamioTag lookup (iOS identity refresh parity).
     */
    fun updateVerifiedIdentity(
        callId: String,
        sessionId: String,
        tag: String,
        address: String = "",
    ): Boolean {
        if (!matches(callId, sessionId)) return false
        val normalizedTag = tag.trim().let { raw ->
            when {
                raw.isBlank() -> ""
                raw.startsWith("@") -> raw
                else -> "@$raw"
            }
        }
        val nextAddress = address.trim()
        while (true) {
            val previous = state.get()
            if (!liveFlag.get()) return false
            val next = previous.copy(
                tag = when {
                    normalizedTag.isNotEmpty() -> normalizedTag
                    else -> previous.tag
                },
                address = when {
                    nextAddress.isNotBlank() -> nextAddress
                    else -> previous.address
                },
            )
            if (next.tag == previous.tag && next.address == previous.address) {
                return false
            }
            if (state.compareAndSet(previous, next)) {
                android.util.Log.i(
                    "BeamioInCall",
                    "updateVerifiedIdentity callId=${next.callId.take(12)} " +
                        "tag=${next.tag.ifBlank { "-" }}",
                )
                return true
            }
        }
    }

    fun end(callId: String = "") {
        val current = state.get()
        if (!liveFlag.get()) return
        if (callId.isNotBlank() && current.callId.isNotBlank() && callId != current.callId) return
        if (speakerFlag.get()) {
            // Speaker route is owned by InCallActivity; clear flag only.
            speakerFlag.set(false)
        }
        liveFlag.set(false)
        presentedFlag.set(false)
        connectedFlag.set(true)
        BeamioCallTonePlayer.stopRingback("ended")
        BeamioCallTonePlayer.resetForNewDial()
        mutedFlag.set(false)
        BeamioNativeVoiceChannel.setCaptureMuted(false)
        state.set(State())
        android.util.Log.i("BeamioInCall", "end callId=${callId.take(12)}")
    }

    fun presentIfLive() {
        if (!liveFlag.get() || presentedFlag.get()) return
        presentedFlag.set(true)
        android.util.Log.i("BeamioInCall", "present on activation callId=${state.get().callId.take(12)}")
    }

    fun minimize() {
        presentedFlag.set(false)
    }

    fun syncMuted(value: Boolean) {
        mutedFlag.set(value)
        BeamioNativeVoiceChannel.setCaptureMuted(value)
    }

    fun toggleMute(): Boolean {
        val next = !mutedFlag.get()
        mutedFlag.set(next)
        BeamioNativeVoiceChannel.setCaptureMuted(next)
        return next
    }

    fun toggleSpeaker(): Boolean {
        val next = !speakerFlag.get()
        speakerFlag.set(next)
        return next
    }

    fun setSpeakerOn(value: Boolean) {
        speakerFlag.set(value)
    }

    /** Title line: prefer @BeamioTag, then short address, then product fallback. */
    fun titleLine(fallback: String = "Beamio call"): String {
        val current = state.get()
        if (current.tag.isNotBlank()) return current.tag
        if (current.address.isNotBlank()) {
            return BeamioVoiceOfferIdentity.shortAddress(current.address)
                .ifBlank { current.address }
        }
        return fallback
    }
}
